open Sessy_domain

let read_file = Fs.read_file
let list_dir = Fs.list_dir
let file_exists = Fs.file_exists
let expand_home = Fs.expand_home
let detect_git_root = Fs.detect_git_root
let spawn = Process.spawn
let exec_replace = Process.exec_replace
let print_cmd = Process.print_cmd
let load_config () = Config_loader.load_config () |> fst
let load_config_from_paths = Config_loader.load_config_from_paths

let parse_error_message = function
  | Invalid_json value -> value
  | Missing_field value -> "missing field: " ^ value
  | Invalid_format value -> value

let warning_for_source source_path message =
  Printf.sprintf "%s: %s" source_path message

let load_source source =
  let source_path = source.history_path |> expand_home in

  if not (file_exists source_path) then ([], [])
  else
    match read_file source_path with
    | Error (`Io_error message) ->
        ([], [ warning_for_source source_path message ])
    | Ok raw -> (
        let module Adapter =
          (val Sessy_adapter.adapter_for_tool source.tool
              : Sessy_adapter.SOURCE)
        in
        Adapter.parse_history raw |> function
        | Ok sessions -> (sessions, [])
        | Error error ->
            ([], [ warning_for_source source_path (parse_error_message error) ])
        )

let load_sessions config =
  config.sources
  |> List.fold_left
       (fun (all_sessions, warnings) source ->
         let sessions, source_warnings = load_source source in

         (all_sessions @ sessions, warnings @ source_warnings))
       ([], [])

let print_warnings warnings = warnings |> List.iter prerr_endline
let print_output text = if String.equal text "" then () else print_endline text

type launch_request =
  | Last_request
  | Session_request of Session_id.t

let config_error_message = function
  | File_not_found path -> Printf.sprintf "file not found: %s" path
  | Parse_failed message -> message
  | Invalid_value (field, message) -> Printf.sprintf "%s: %s" field message

let session_not_found_message session_id =
  session_id |> Session_id.to_string |> Printf.sprintf "session not found: %s"

let lookup_launch config tool =
  config.launches
  |> List.find_map (fun (candidate, launch) ->
         if Tool.equal candidate tool then Some launch else None)
  |> function
  | Some launch -> Ok launch
  | None ->
      tool
      |> Tool.to_string
      |> Printf.sprintf "missing launch template for %s"
      |> Result.error

let lookup_source config tool =
  config.sources
  |> List.find_opt (fun source -> Tool.equal source.tool tool)

let string_contains text pattern =
  let text_length = String.length text in
  let pattern_length = String.length pattern in

  let rec loop index =
    if pattern_length = 0 then true
    else if index + pattern_length > text_length then false
    else
      let suffix = String.sub text index (text_length - index) in

      if String.starts_with ~prefix:pattern suffix then true
      else loop (index + 1)
  in

  loop 0

let path_is_directory path =
  try Sys.is_directory path with Sys_error _ -> false

let detail_roots source =
  [ source.sessions_path; source.projects_path ]
  |> List.filter_map Fun.id
  |> List.map expand_home
  |> List.sort_uniq String.compare

let detail_name_matches session_id name =
  let session_id = session_id |> Session_id.to_string in

  [
    name;
    Filename.basename name;
  ]
  |> List.exists (fun candidate ->
         String.equal candidate session_id
         || String.equal candidate (session_id ^ ".jsonl")
         || String.equal candidate (session_id ^ ".json")
         || string_contains candidate session_id)

let rec detail_candidate_paths root session_id =
  if not (file_exists root) then []
  else if not (path_is_directory root) then [ root ]
  else
    match list_dir root with
    | Error (`Io_error _) -> []
    | Ok entries ->
        entries
        |> List.concat_map (fun entry ->
               let path = Filename.concat root entry in

               if path_is_directory path then detail_candidate_paths path session_id
               else if detail_name_matches session_id entry then [ path ]
               else [])

let read_detail_session source session_id path =
  match read_file path with
  | Error (`Io_error _) -> None
  | Ok raw -> (
      let module Adapter =
        (val Sessy_adapter.adapter_for_tool source.tool : Sessy_adapter.SOURCE)
      in

      match Adapter.parse_detail raw with
      | Ok detail when Session_id.equal detail.id session_id -> Some detail
      | Ok _ | Error _ -> None)

let merge_optional preferred fallback =
  match preferred with
  | Some _ -> preferred
  | None -> fallback

let merge_text preferred fallback =
  if String.equal preferred "" then fallback else preferred

let merge_session base detail =
  {
    base with
    cwd = merge_text detail.cwd base.cwd;
    title = merge_optional detail.title base.title;
    first_prompt = merge_optional detail.first_prompt base.first_prompt;
    project_key = merge_optional detail.project_key base.project_key;
    model = merge_optional detail.model base.model;
    updated_at = Float.max base.updated_at detail.updated_at;
  }

let hydrate_session_detail ~config (session : session) =
  match lookup_source config session.tool with
  | None -> session
  | Some source ->
      detail_roots source
      |> List.find_map (fun root ->
             detail_candidate_paths root session.id
             |> List.find_map (read_detail_session source session.id))
      |> function
      | Some detail -> merge_session session detail
      | None -> session

let launch_session ~cwd (session : session) : session =
  if String.equal session.cwd "" then { session with cwd } else session

let apply_launch_mode launch_mode launch =
  match launch_mode with
  | Sessy_ui.Default -> launch
  | Sessy_ui.Dry_run -> { launch with exec_mode = Print }

let expand_launch_cmd ~config ~launch_mode (session : session) =
  match lookup_launch config session.tool with
  | Error _ as error -> error
  | Ok launch ->
      Sessy_core.expand_template session None launch
      |> Result.map (apply_launch_mode launch_mode)
      |> Result.map_error config_error_message

let prepare_launch_cmd ~config ~launch_mode ~cwd (session : session) =
  let hydrated = hydrate_session_detail ~config session in
  let launched = launch_session ~cwd hydrated in

  expand_launch_cmd ~config ~launch_mode launched

let repo_scope repo_root =
  repo_root
  |> Option.map (fun _ -> Repo)
  |> Option.value ~default:Cwd

let empty_query scope = { text = ""; scope; tool_filter = None; mode = Meta }

let select_last_session ~config ~index ~cwd ~repo_root ~now =
  let hydrated_index =
    index
    |> Sessy_index.all_sessions
    |> List.map (hydrate_session_detail ~config)
    |> Sessy_index.build
  in
  let primary_scope = repo_scope repo_root in
  let primary_results =
    Sessy_index.search hydrated_index (empty_query primary_scope) ~now ~cwd
      ~repo_root
    |> List.map (fun ranked -> ranked.session)
  in

  match primary_results with
  | first :: _ -> Some first
  | [] ->
      Sessy_index.search hydrated_index (empty_query All) ~now ~cwd ~repo_root
      |> List.map (fun ranked -> ranked.session)
      |> function
      | first :: _ -> Some first
      | [] -> None

let resolve_index_session ~index (session_id : Session_id.t) =
  Sessy_index.find_by_id index session_id |> function
  | Some session -> Ok session
  | None -> Error (session_not_found_message session_id)

let resolve_preview ~config ~index ~session_id ~cwd =
  session_id
  |> resolve_index_session ~index
  |> Result.map (fun session ->
         let detail_session = session |> hydrate_session_detail ~config in
         let launch =
           detail_session
           |> launch_session ~cwd
           |> expand_launch_cmd ~config ~launch_mode:Sessy_ui.Default
         in

         ({ session = detail_session; launch } : Sessy_ui.preview))

let resolve_launch_cmd ~config ~index ~(request : launch_request) ~launch_mode
    ~cwd ~repo_root ~now =
  let selected_session =
    match request with
    | Last_request -> (
        match select_last_session ~config ~index ~cwd ~repo_root ~now with
        | Some session -> Ok session
        | None -> Error "no sessions available")
    | Session_request session_id -> resolve_index_session ~index session_id
  in

  match selected_session with
  | Ok session -> prepare_launch_cmd ~config ~launch_mode ~cwd session
  | Error _ as error -> error

type doctor_status = Ok_status | Warn_status
type doctor_check = { status : doctor_status; label : string; detail : string }

let make_check status label detail = { status; label; detail }
let status_label = function Ok_status -> "ok" | Warn_status -> "warn"

let format_check check =
  Printf.sprintf "[%s] %s: %s"
    (status_label check.status)
    check.label check.detail

let path_check label path =
  if file_exists path then make_check Ok_status label path
  else make_check Warn_status label ("not found: " ^ path)

let option_path_checks label path =
  path |> Option.map expand_home
  |> Option.map (path_check label)
  |> Option.to_list

let find_executable name =
  let path_entries =
    Sys.getenv_opt "PATH" |> Option.value ~default:""
    |> String.split_on_char ':'
    |> List.filter (fun entry -> not (String.equal entry ""))
  in

  path_entries
  |> List.find_map (fun entry ->
      let candidate = Filename.concat entry name in

      try
        Unix.access candidate [ Unix.X_OK ];
        Some candidate
      with Unix.Unix_error _ -> None)

type loaded_state = {
  config : config;
  config_warnings : string list;
  session_warnings : string list;
  index : Sessy_index.t;
}

let combined_warnings state =
  state.config_warnings @ state.session_warnings

let warning_summary warnings =
  match warnings with
  | [] -> None
  | [ warning ] -> Some warning
  | first :: _ ->
      Some
        (Printf.sprintf "%d warnings; first: %s" (List.length warnings) first)

let load_runtime_state ~config_paths =
  let config, config_warnings = load_config_from_paths config_paths in
  let sessions, session_warnings = load_sessions config in
  let index = sessions |> Sessy_index.build in

  { config; config_warnings; session_warnings; index }

let describe_unix_error error function_name argument =
  Printf.sprintf "%s(%s): %s" function_name argument (Unix.error_message error)

let wait_for_pid pid =
  match Unix.waitpid [] pid with
  | _, Unix.WEXITED 0 -> Ok ()
  | _, Unix.WEXITED code ->
      Error (Printf.sprintf "process exited with status %d" code)
  | _, Unix.WSIGNALED signal ->
      Error (Printf.sprintf "process killed by signal %d" signal)
  | _, Unix.WSTOPPED signal ->
      Error (Printf.sprintf "process stopped by signal %d" signal)

let run_command_with_input program arguments input =
  let argv = Array.of_list (program :: arguments) in
  let read_fd, write_fd = Unix.pipe () in

  try
    let pid =
      Unix.create_process program argv read_fd Unix.stdout Unix.stderr
    in

    Unix.close read_fd;

    let output_channel = Unix.out_channel_of_descr write_fd in

    output_string output_channel input;
    close_out output_channel;

    wait_for_pid pid
  with Unix.Unix_error (error, function_name, argument) ->
    Error (describe_unix_error error function_name argument)

let run_command program arguments =
  let command =
    {
      argv = (program, arguments);
      cwd = Sys.getcwd ();
      exec_mode = Spawn;
      display = String.concat " " (program :: arguments);
    }
  in

  spawn command |> Result.map_error (function `Exec_error message -> message)

let first_available_command candidates =
  candidates
  |> List.find_map (fun (name, arguments) ->
         name |> find_executable |> Option.map (fun path -> (path, arguments)))

let copy_to_clipboard text =
  let candidates =
    [
      ("pbcopy", []);
      ("wl-copy", []);
      ("xclip", [ "-selection"; "clipboard" ]);
      ("xsel", [ "--clipboard"; "--input" ]);
    ]
  in

  match first_available_command candidates with
  | None -> Error "no clipboard command available"
  | Some (program, arguments) ->
      text
      |> run_command_with_input program arguments
      |> Result.map (fun () -> Some "copied session id to clipboard")

let open_directory path =
  let candidates = [ ("open", [ path ]); ("xdg-open", [ path ]) ] in

  match first_available_command candidates with
  | None -> Error "no directory opener available"
  | Some (program, arguments) ->
      arguments
      |> run_command program
      |> Result.map (fun () -> Some ("opened " ^ path))

let tool_check tool =
  let label = tool |> Tool.to_string |> Printf.sprintf "tool %s" in

  tool |> Tool.to_string |> find_executable |> function
  | Some path -> make_check Ok_status label path
  | None -> make_check Warn_status label "not found in PATH"

let source_path_checks source =
  let tool_name = source.tool |> Tool.to_string in
  let history_path = source.history_path |> expand_home in

  [ path_check (Printf.sprintf "source %s history" tool_name) history_path ]
  @ option_path_checks
      (Printf.sprintf "source %s projects" tool_name)
      source.projects_path
  @ option_path_checks
      (Printf.sprintf "source %s sessions" tool_name)
      source.sessions_path

let source_parse_check source =
  let tool_name = source.tool |> Tool.to_string in
  let history_path = source.history_path |> expand_home in
  let label = Printf.sprintf "source %s parse" tool_name in

  if not (file_exists history_path) then
    make_check Warn_status label "skipped; history file missing"
  else
    match read_file history_path with
    | Error (`Io_error message) -> make_check Warn_status label message
    | Ok raw -> (
        let module Adapter =
          (val Sessy_adapter.adapter_for_tool source.tool
              : Sessy_adapter.SOURCE)
        in
        Adapter.parse_history raw |> function
        | Ok sessions ->
            sessions |> List.length
            |> Printf.sprintf "%d sessions"
            |> make_check Ok_status label
        | Error error ->
            error |> parse_error_message |> make_check Warn_status label)

let doctor_checks ~config_paths ~config ~config_warnings =
  let config_checks =
    config_paths |> List.map expand_home |> List.map (path_check "config")
  in
  let warning_checks =
    config_warnings |> List.map (make_check Warn_status "config warning")
  in
  let source_checks =
    config.sources
    |> List.concat_map (fun source ->
        source |> source_path_checks |> fun checks ->
        checks @ [ source |> source_parse_check ])
  in
  let tool_checks = [ Claude; Codex ] |> List.map tool_check in

  config_checks @ warning_checks @ source_checks @ tool_checks

let doctor_report ~config_paths ~config ~config_warnings =
  doctor_checks ~config_paths ~config ~config_warnings
  |> List.map format_check |> String.concat "\n"

let execute_launch command =
  match command.exec_mode with
  | Print ->
      print_cmd command;
      0
  | Spawn -> (
      match spawn command with
      | Ok () -> 0
      | Error (`Exec_error message) ->
          prerr_endline message;
          1)
  | Exec -> (
      match exec_replace command with
      | Ok () -> 0
      | Error (`Exec_error message) ->
          prerr_endline message;
          1)

let execute_cmd ~index ~cwd ~repo_root ~now ~config_paths ~config
    ~config_warnings = function
  | Sessy_ui.Launch command -> command |> execute_launch
  | Sessy_ui.Copy_to_clipboard _
  | Sessy_ui.Open_directory _
  | Sessy_ui.Reload_index
  | Sessy_ui.Exit
  | Sessy_ui.Noop ->
      prerr_endline "unexpected interactive command reached the CLI shell";
      1
  | Sessy_ui.Print_notice message ->
      message |> print_output;
      0
  | Sessy_ui.Print_sessions (sessions, output_format) ->
      sessions |> Sessy_ui.format_sessions ~now output_format |> print_output;
      0
  | Sessy_ui.Print_preview preview ->
      preview |> Sessy_ui.format_preview ~now |> print_output;
      0
  | Sessy_ui.Resolve_last launch_mode -> (
      match
        resolve_launch_cmd ~config ~index ~request:Last_request ~launch_mode ~cwd
          ~repo_root ~now
      with
      | Ok command -> command |> execute_launch
      | Error message ->
          prerr_endline message;
          1)
  | Sessy_ui.Resolve_resume (session_id, launch_mode) -> (
      match
        resolve_launch_cmd ~config ~index
          ~request:(Session_request session_id)
          ~launch_mode ~cwd ~repo_root ~now
      with
      | Ok command -> command |> execute_launch
      | Error message ->
          prerr_endline message;
          1)
  | Sessy_ui.Resolve_preview session_id -> (
      match resolve_preview ~config ~index ~session_id ~cwd with
      | Ok preview ->
          preview |> Sessy_ui.format_preview ~now |> print_output;
          0
      | Error message ->
          prerr_endline message;
          1)
  | Sessy_ui.Run_doctor ->
      doctor_report ~config_paths ~config ~config_warnings |> print_output;
      0
  | Sessy_ui.Print_error message ->
      prerr_endline message;
      1

let execute_cmds ~index ~cwd ~repo_root ~now ~config_paths ~config
    ~config_warnings commands =
  commands
  |> List.map
       (execute_cmd ~index ~cwd ~repo_root ~now ~config_paths ~config
          ~config_warnings)
  |> List.fold_left Int.max 0

let commands_need_sessions = function
  | Sessy_ui.Doctor | Sessy_ui.Open_picker -> false
  | Sessy_ui.List_sessions _ | Sessy_ui.Resume_last _ | Sessy_ui.Resume_id _
  | Sessy_ui.Preview_session _ ->
      true

let interactive_notice state =
  state |> combined_warnings |> warning_summary

let interactive_reload_snapshot ~config_paths () =
  let state = load_runtime_state ~config_paths in

  Ok
    {
      Sessy_ui.index = state.index;
      config = state.config;
      now = Unix.gettimeofday ();
      warning = interactive_notice state;
    }

let run_picker ~config_paths ~cwd ~repo_root ~now =
  if not (Unix.isatty Unix.stdin && Unix.isatty Unix.stdout) then (
    prerr_endline "interactive mode requires a TTY";
    1)
  else
    let state = load_runtime_state ~config_paths in
    let handlers : Runtime.handlers =
      {
        copy_to_clipboard;
        open_directory;
        reload_snapshot = interactive_reload_snapshot ~config_paths;
      }
    in

    match
      Runtime.run ~index:state.index ~config:state.config ~cwd ~repo_root ~now
        ~notice:(interactive_notice state) ~handlers
    with
    | `Exit -> 0
    | `Launch command -> command |> execute_launch

let run_once ~argv ~config_paths ~cwd ~now =
  argv |> Sessy_ui.parse_cli |> function
  | Error message ->
      prerr_endline message;
      1
  | Ok Sessy_ui.Open_picker ->
      run_picker ~config_paths ~cwd ~repo_root:(detect_git_root cwd) ~now
  | Ok action ->
      if commands_need_sessions action then (
        let state = load_runtime_state ~config_paths in
        let warnings = state |> combined_warnings in

        print_warnings warnings;

        Sessy_ui.dispatch action state.index state.config ~cwd
        |> execute_cmds ~index:state.index ~cwd ~repo_root:(detect_git_root cwd)
             ~now ~config_paths ~config:state.config
             ~config_warnings:state.config_warnings)
      else
        let config, config_warnings = load_config_from_paths config_paths in

        Sessy_ui.dispatch action Sessy_index.empty config ~cwd
        |> execute_cmds ~index:Sessy_index.empty ~cwd ~repo_root:(detect_git_root cwd)
             ~now ~config_paths ~config ~config_warnings

let run () =
  let exit_status =
    Eio_main.run (fun _env ->
        run_once
          ~argv:(Sys.argv |> Array.to_list |> List.tl)
          ~config_paths:(Config_loader.default_paths ())
          ~cwd:(Sys.getcwd ()) ~now:(Unix.gettimeofday ()))
  in

  exit exit_status
