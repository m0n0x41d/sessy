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

let execute_cmd ~now ~config_paths ~config ~config_warnings = function
  | Sessy_ui.Launch command -> command |> execute_launch
  | Sessy_ui.Print_notice message ->
      message |> print_output;
      0
  | Sessy_ui.Print_sessions (sessions, output_format) ->
      sessions |> Sessy_ui.format_sessions ~now output_format |> print_output;
      0
  | Sessy_ui.Print_preview preview ->
      preview |> Sessy_ui.format_preview ~now |> print_output;
      0
  | Sessy_ui.Run_doctor ->
      doctor_report ~config_paths ~config ~config_warnings |> print_output;
      0
  | Sessy_ui.Print_error message ->
      prerr_endline message;
      1

let execute_cmds ~now ~config_paths ~config ~config_warnings commands =
  commands
  |> List.map (execute_cmd ~now ~config_paths ~config ~config_warnings)
  |> List.fold_left Int.max 0

let commands_need_sessions = function
  | Sessy_ui.Doctor | Sessy_ui.Open_picker -> false
  | Sessy_ui.List_sessions _ | Sessy_ui.Resume_last _ | Sessy_ui.Resume_id _
  | Sessy_ui.Preview_session _ ->
      true

let run_once ~argv ~config_paths ~cwd ~now =
  argv |> Sessy_ui.parse_cli |> function
  | Error message ->
      prerr_endline message;
      1
  | Ok action ->
      let config, config_warnings =
        config_paths |> Config_loader.load_config_from_paths
      in

      if commands_need_sessions action then (
        let sessions, session_warnings = load_sessions config in
        let index = sessions |> Sessy_index.build in
        let warnings = config_warnings @ session_warnings in

        print_warnings warnings;

        Sessy_ui.dispatch action index config ~cwd
        |> execute_cmds ~now ~config_paths ~config ~config_warnings)
      else
        Sessy_ui.dispatch action Sessy_index.empty config ~cwd
        |> execute_cmds ~now ~config_paths ~config ~config_warnings

let run () =
  let exit_status =
    Eio_main.run (fun _env ->
        run_once
          ~argv:(Sys.argv |> Array.to_list |> List.tl)
          ~config_paths:(Config_loader.default_paths ())
          ~cwd:(Sys.getcwd ()) ~now:(Unix.gettimeofday ()))
  in

  exit exit_status
