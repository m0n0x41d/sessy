open Sessy_domain

type output_format = Plain | Json
type launch_mode = Default | Dry_run

type cli_action =
  | Open_picker
  | List_sessions of output_format
  | Resume_last of launch_mode
  | Resume_id of Session_id.t * launch_mode
  | Preview_session of Session_id.t
  | Doctor

type preview = { session : session; launch : (launch_cmd, string) result }

type terminal = {
  width : int;
  height : int;
}

type model = {
  index : Sessy_index.t;
  config : config;
  query : query;
  results : ranked list;
  cursor : int;
  preview_visible : bool;
  help_visible : bool;
  active_profile : string option;
  cwd : string;
  repo_root : string option;
  now : float;
  terminal : terminal;
  notice : string option;
}

type reload_snapshot = {
  index : Sessy_index.t;
  config : config;
  now : float;
  warning : string option;
}

type cmd =
  | Launch of launch_cmd
  | Copy_to_clipboard of string
  | Open_directory of string
  | Reload_index
  | Exit
  | Noop
  | Print_notice of string
  | Print_sessions of session list * output_format
  | Print_preview of preview
  | Resolve_last of launch_mode
  | Resolve_resume of Session_id.t * launch_mode
  | Resolve_preview of Session_id.t
  | Run_doctor
  | Print_error of string

type msg =
  | Query_changed of string
  | Cursor_moved of int
  | Scope_toggled
  | Tool_filter_toggled
  | Search_mode_toggled
  | Preview_toggled
  | Help_toggled
  | Session_selected
  | Copy_requested
  | Open_directory_requested
  | Reload_requested
  | Reload_finished of reload_snapshot
  | Notice_set of string option
  | Window_resized of terminal
  | Quit

type parsed_args = {
  dry_run : bool;
  json : bool;
  positionals : string list;
  unknown_flags : string list;
}

let minimum_terminal_width = 60
let minimum_terminal_height = 12
let preview_threshold_width = 100
let ansi_reset = "\027[0m"
let ansi_bold = "\027[1m"
let ansi_dim = "\027[2m"
let ansi_inverse = "\027[7m"

let style style text =
  [ style; text; ansi_reset ] |> String.concat ""

let empty_args =
  { dry_run = false; json = false; positionals = []; unknown_flags = [] }

let classify_arg parsed argument =
  match argument with
  | "--dry-run" -> { parsed with dry_run = true }
  | "--json" -> { parsed with json = true }
  | value when String.starts_with ~prefix:"--" value ->
      { parsed with unknown_flags = parsed.unknown_flags @ [ value ] }
  | value -> { parsed with positionals = parsed.positionals @ [ value ] }

let parse_args argv = argv |> List.fold_left classify_arg empty_args
let format_flag_list flags = flags |> String.concat ", "

let error_unknown_flags flags =
  flags |> format_flag_list |> Printf.sprintf "unknown flag: %s"

let error_unsupported_flag command flag =
  Printf.sprintf "%s does not support %s" command flag

let parse_session_id value =
  value |> Session_id.of_string |> function
  | Some session_id -> Ok session_id
  | None -> Error "session id must be non-empty"

let parse_cli = function
  | [] -> Ok Open_picker
  | command :: argv -> (
      let args = argv |> parse_args in

      if args.unknown_flags <> [] then
        Error (error_unknown_flags args.unknown_flags)
      else
        match command with
        | "list" ->
            if args.dry_run then
              Error (error_unsupported_flag "list" "--dry-run")
            else if args.positionals <> [] then
              Error "list does not accept positional arguments"
            else if args.json then Ok (List_sessions Json)
            else Ok (List_sessions Plain)
        | "last" ->
            if args.json then Error (error_unsupported_flag "last" "--json")
            else if args.positionals <> [] then
              Error "last does not accept positional arguments"
            else if args.dry_run then Ok (Resume_last Dry_run)
            else Ok (Resume_last Default)
        | "resume" -> (
            if args.json then Error (error_unsupported_flag "resume" "--json")
            else
              match args.positionals with
              | [ session_id ] ->
                  session_id |> parse_session_id
                  |> Result.map (fun parsed ->
                         let launch_mode =
                           if args.dry_run then Dry_run else Default
                         in

                         Resume_id (parsed, launch_mode))
              | [] -> Error "resume requires a session id"
              | _ -> Error "resume accepts exactly one session id")
        | "preview" -> (
            if args.dry_run then
              Error (error_unsupported_flag "preview" "--dry-run")
            else if args.json then
              Error (error_unsupported_flag "preview" "--json")
            else
              match args.positionals with
              | [ session_id ] ->
                  session_id |> parse_session_id
                  |> Result.map (fun parsed -> Preview_session parsed)
              | [] -> Error "preview requires a session id"
              | _ -> Error "preview accepts exactly one session id")
        | "doctor" ->
            if args.dry_run then
              Error (error_unsupported_flag "doctor" "--dry-run")
            else if args.json then
              Error (error_unsupported_flag "doctor" "--json")
            else if args.positionals <> [] then
              Error "doctor does not accept positional arguments"
            else Ok Doctor
        | unknown -> Error ("unknown command: " ^ unknown))

let config_error_message = function
  | File_not_found path -> Printf.sprintf "file not found: %s" path
  | Parse_failed message -> message
  | Invalid_value (field, message) -> Printf.sprintf "%s: %s" field message

let lookup_launch (config : config) tool =
  config.launches
  |> List.find_map (fun (candidate, launch) ->
         if Tool.equal candidate tool then Some launch else None)
  |> function
  | Some launch -> Ok launch
  | None ->
      tool |> Tool.to_string
      |> Printf.sprintf "missing launch template for %s"
      |> Result.error

let lookup_profile (config : config) active_profile tool =
  Option.bind active_profile (fun profile_name ->
      config.profiles
      |> List.find_opt (fun profile ->
             String.equal profile.name profile_name
             && Tool.equal profile.base_tool tool))

let launch_for_session (config : config) active_profile (session : session) =
  match lookup_launch config session.tool with
  | Error _ as error -> error
  | Ok launch ->
      let profile =
        session.tool |> lookup_profile config active_profile
      in

      launch
      |> Sessy_core.expand_template session profile
      |> Result.map_error config_error_message

let apply_launch_mode launch_mode launch =
  match launch_mode with
  | Default -> launch
  | Dry_run -> { launch with exec_mode = Print }

let prepare_launch launch_mode config active_profile session =
  session |> launch_for_session config active_profile
  |> Result.map (apply_launch_mode launch_mode)

let preview_for_session config active_profile session =
  { session; launch = session |> launch_for_session config active_profile }

let dispatch action index _config ~cwd:_ =
  match action with
  | Open_picker -> [ Print_notice "interactive mode requires the shell runtime" ]
  | List_sessions output_format ->
      [ Print_sessions (Sessy_index.all_sessions index, output_format) ]
  | Resume_last launch_mode -> [ Resolve_last launch_mode ]
  | Resume_id (session_id, launch_mode) ->
      [ Resolve_resume (session_id, launch_mode) ]
  | Preview_session session_id -> [ Resolve_preview session_id ]
  | Doctor -> [ Run_doctor ]

let relative_age ~now updated_at =
  let age_seconds = now -. updated_at |> Float.max 0. |> int_of_float in
  let minute = 60 in
  let hour = 60 * minute in
  let day = 24 * hour in

  if age_seconds < minute then Printf.sprintf "%ds ago" age_seconds
  else if age_seconds < hour then Printf.sprintf "%dm ago" (age_seconds / minute)
  else if age_seconds < day then Printf.sprintf "%dh ago" (age_seconds / hour)
  else Printf.sprintf "%dd ago" (age_seconds / day)

let title_or_placeholder (session : session) =
  session.title |> Option.value ~default:"(untitled)"

let format_session_plain ~now (session : session) =
  Printf.sprintf "[%s] %s %s %s %s"
    (Tool.to_string session.tool)
    (Session_id.short session.id)
    (title_or_placeholder session)
    session.cwd
    (relative_age ~now session.updated_at)

let session_json_fields (session : session) =
  [
    ("id", `String (Session_id.to_string session.id));
    ("short_id", `String (Session_id.short session.id));
    ("tool", `String (Tool.to_string session.tool));
    ( "title",
      session.title
      |> Option.map (fun value -> `String value)
      |> Option.value ~default:`Null );
    ( "first_prompt",
      session.first_prompt
      |> Option.map (fun value -> `String value)
      |> Option.value ~default:`Null );
    ("cwd", `String session.cwd);
    ( "project_key",
      session.project_key
      |> Option.map (fun value -> `String value)
      |> Option.value ~default:`Null );
    ( "model",
      session.model
      |> Option.map (fun value -> `String value)
      |> Option.value ~default:`Null );
    ("updated_at", `Float session.updated_at);
    ("is_active", `Bool session.is_active);
  ]

let format_session_json (session : session) =
  `Assoc (session_json_fields session)

let preview_value value = value |> Option.value ~default:"-"

let preview_launch_line preview =
  preview.launch |> function
  | Ok command -> "launch: " ^ command.display
  | Error message -> "launch error: " ^ message

let format_preview ~now preview =
  let session = preview.session in

  [
    "id: " ^ Session_id.to_string session.id;
    "tool: " ^ Tool.to_string session.tool;
    "cwd: " ^ session.cwd;
    "project: " ^ preview_value session.project_key;
    "model: " ^ preview_value session.model;
    "title: " ^ preview_value session.title;
    "first prompt: " ^ preview_value session.first_prompt;
    "last activity: " ^ relative_age ~now session.updated_at;
    preview_launch_line preview;
  ]
  |> String.concat "\n"

let format_sessions ~now output_format sessions =
  match output_format with
  | Plain ->
      sessions |> List.map (format_session_plain ~now) |> String.concat "\n"
  | Json ->
      sessions |> List.map format_session_json |> fun values ->
      `List values |> Yojson.Safe.to_string

let clamp_int minimum maximum value =
  value |> Int.max minimum |> Int.min maximum

let normalize_terminal terminal =
  {
    width = terminal.width |> Int.max minimum_terminal_width;
    height = terminal.height |> Int.max minimum_terminal_height;
  }

let default_query config =
  {
    text = "";
    scope = config.default_scope;
    tool_filter = None;
    mode = Meta;
  }

let search_results index query ~now ~cwd ~repo_root =
  Sessy_index.search index query ~now ~cwd ~repo_root

let clamp_cursor cursor results =
  match results |> List.length with
  | 0 -> 0
  | count -> cursor |> clamp_int 0 (count - 1)

let with_results model results =
  { model with results; cursor = clamp_cursor model.cursor results }

let rerun_search model =
  search_results model.index model.query ~now:model.now ~cwd:model.cwd
    ~repo_root:model.repo_root
  |> with_results model

let init index config ~cwd ~repo_root ~now ~terminal ~notice =
  let query = config |> default_query in
  let terminal = terminal |> normalize_terminal in
  let results = search_results index query ~now ~cwd ~repo_root in

  {
    index;
    config;
    query;
    results;
    cursor = 0;
    preview_visible = config.preview;
    help_visible = false;
    active_profile = None;
    cwd;
    repo_root;
    now;
    terminal;
    notice;
  }

let scope_label = function
  | Cwd -> "cwd"
  | Repo -> "repo"
  | All -> "all"

let tool_filter_label = function
  | None -> "all"
  | Some tool -> Tool.to_string tool

let search_mode_label = function
  | Meta -> "meta"
  | Deep -> "deep"

let cycle_scope = function
  | Cwd -> Repo
  | Repo -> All
  | All -> Cwd

let cycle_tool_filter = function
  | None -> Some Claude
  | Some Claude -> Some Codex
  | Some Codex -> None

let cycle_search_mode = function
  | Meta -> Deep
  | Deep -> Meta

let profile_still_exists config active_profile =
  match active_profile with
  | None -> None
  | Some profile_name ->
      config.profiles
      |> List.exists (fun profile -> String.equal profile.name profile_name)
      |> function
      | true -> Some profile_name
      | false -> None

let selected_ranked (model : model) : ranked option =
  List.nth_opt model.results model.cursor

let selected_session (model : model) : session option =
  match selected_ranked model with
  | Some ranked -> Some ranked.session
  | None -> None

let selected_preview (model : model) : preview option =
  match selected_session model with
  | Some session ->
      Some (preview_for_session model.config model.active_profile session)
  | None -> None

let with_notice model notice =
  { model with notice }

let update_query model text =
  {
    model with
    query = { model.query with text };
    cursor = 0;
    notice = None;
  }
  |> rerun_search

let update_scope model =
  {
    model with
    query = { model.query with scope = cycle_scope model.query.scope };
    cursor = 0;
    notice = None;
  }
  |> rerun_search

let update_tool_filter model =
  {
    model with
    query =
      {
        model.query with
        tool_filter = cycle_tool_filter model.query.tool_filter;
      };
    cursor = 0;
    notice = None;
  }
  |> rerun_search

let update_search_mode model =
  let mode = model.query.mode |> cycle_search_mode in
  let notice =
    match mode with
    | Meta -> None
    | Deep -> Some "deep search is metadata-backed in this build"
  in

  {
    model with
    query = { model.query with mode };
    cursor = 0;
    notice;
  }
  |> rerun_search

let update_cursor model delta =
  let maximum =
    model.results |> List.length |> fun count -> Int.max 0 (count - 1)
  in

  { model with cursor = model.cursor + delta |> clamp_int 0 maximum; notice = None }

let update_session_selected model =
  match model |> selected_session with
  | None -> (with_notice model (Some "no session selected"), Noop)
  | Some session -> (
      match prepare_launch Default model.config model.active_profile session with
      | Ok launch -> ({ model with notice = None }, Launch launch)
      | Error message -> (with_notice model (Some message), Noop))

let update_copy_requested model =
  match model |> selected_session with
  | None -> (with_notice model (Some "no session selected"), Noop)
  | Some session ->
      let text = session.id |> Session_id.to_string in

      ({ model with notice = None }, Copy_to_clipboard text)

let update_open_directory_requested model =
  match model |> selected_session with
  | None -> (with_notice model (Some "no session selected"), Noop)
  | Some session -> ({ model with notice = None }, Open_directory session.cwd)

let update_reload_finished model snapshot =
  let active_profile =
    profile_still_exists snapshot.config model.active_profile
  in

  {
    model with
    index = snapshot.index;
    config = snapshot.config;
    now = snapshot.now;
    active_profile;
    notice = snapshot.warning;
  }
  |> rerun_search

let update model = function
  | Query_changed text -> (update_query model text, Noop)
  | Cursor_moved delta -> (update_cursor model delta, Noop)
  | Scope_toggled -> (update_scope model, Noop)
  | Tool_filter_toggled -> (update_tool_filter model, Noop)
  | Search_mode_toggled -> (update_search_mode model, Noop)
  | Preview_toggled ->
      ({ model with preview_visible = not model.preview_visible; notice = None }, Noop)
  | Help_toggled ->
      ({ model with help_visible = not model.help_visible; notice = None }, Noop)
  | Session_selected -> update_session_selected model
  | Copy_requested -> update_copy_requested model
  | Open_directory_requested -> update_open_directory_requested model
  | Reload_requested -> ({ model with notice = Some "reloading sessions..." }, Reload_index)
  | Reload_finished snapshot -> (update_reload_finished model snapshot, Noop)
  | Notice_set notice -> (with_notice model notice, Noop)
  | Window_resized terminal ->
      ({ model with terminal = terminal |> normalize_terminal }, Noop)
  | Quit -> ({ model with notice = None }, Exit)

let rec take count values =
  match (count, values) with
  | count, _ when count <= 0 -> []
  | _, [] -> []
  | count, head :: tail -> head :: take (count - 1) tail

let rec drop count values =
  match (count, values) with
  | count, values when count <= 0 -> values
  | _, [] -> []
  | count, _ :: tail -> drop (count - 1) tail

let lines_of_count count =
  count |> Int.max 0 |> fun lines -> List.init lines (fun _ -> "")

let truncate width text =
  let ellipsis = "..." in

  if width <= 0 then ""
  else if String.length text <= width then text
  else if width <= String.length ellipsis then String.sub ellipsis 0 width
  else
    let prefix_length = width - String.length ellipsis in

    String.sub text 0 prefix_length ^ ellipsis

let pad width text =
  let text = text |> truncate width in
  let padding = width - String.length text |> Int.max 0 in

  text ^ String.make padding ' '

let query_display text =
  if String.equal text "" then "<type to filter>" else text

let header_lines model =
  [
    Printf.sprintf "sessy  query: %s" (query_display model.query.text);
    Printf.sprintf "scope:%s  tool:%s  mode:%s  profile:%s  results:%d"
      (scope_label model.query.scope)
      (tool_filter_label model.query.tool_filter)
      (search_mode_label model.query.mode)
      (model.active_profile |> Option.value ~default:"-")
      (List.length model.results);
  ]

let footer_lines model =
  match model.help_visible with
  | false ->
      [
        "Enter resume | Tab preview | Ctrl-Y copy | Ctrl-O open | Ctrl-S scope | Ctrl-T tool | Ctrl-F deep | Ctrl-R reload | ? help | Esc quit";
      ]
  | true ->
      [
        "Shortcuts: Enter resume | Up/Down move | Tab preview | Ctrl-Y copy id | Ctrl-O open cwd";
        "Scope/tool/mode: Ctrl-S cycle scope | Ctrl-T cycle tool | Ctrl-F toggle deep | Ctrl-R reload | ? hide help | Esc quit";
      ]

let notice_lines model =
  model.notice
  |> Option.map (fun message -> [ "notice: " ^ message ])
  |> Option.value ~default:[]

let row_text (model : model) (ranked : ranked) =
  let session = ranked.session in
  let marker = if session.is_active then "*" else " " in

  Printf.sprintf "%s [%s] %s %s %s %s"
    marker
    (Tool.to_string session.tool)
    (Session_id.short session.id)
    (title_or_placeholder session)
    session.cwd
    (relative_age ~now:model.now session.updated_at)

let viewport_start total_rows visible_rows cursor =
  let maximum_start = total_rows - visible_rows |> Int.max 0 in
  let desired = cursor - (visible_rows / 2) in

  desired |> clamp_int 0 maximum_start

let list_lines model width height =
  let total_rows = List.length model.results in
  let start = viewport_start total_rows height model.cursor in
  let visible = model.results |> drop start |> take height in

  match visible with
  | [] ->
      let placeholder = "No sessions match the current query." |> pad width in

      placeholder :: lines_of_count (height - 1)
  | rows ->
      let rendered =
        rows
        |> List.mapi (fun offset ranked ->
               let index = start + offset in
               let text = row_text model ranked |> pad width in

               if Int.equal index model.cursor then text |> style ansi_inverse
               else text)
      in

      rendered @ lines_of_count (height - List.length rendered)

let preview_lines (model : model) width height =
  let title = "Preview" |> pad width |> style ansi_bold in
  let body =
    match selected_preview model with
    | Some preview ->
        preview
        |> format_preview ~now:model.now
        |> String.split_on_char '\n'
        |> List.map (pad width)
    | None -> [ "No session selected." |> pad width ]
  in

  (title :: body) |> take height |> fun lines ->
  lines @ lines_of_count (height - List.length lines)

let render_single_pane model width body_height =
  list_lines model width body_height

let render_split_panes model width body_height =
  let left_width = ((width * 3) / 5) - 2 |> Int.max 30 in
  let right_width = width - left_width - 3 |> Int.max 20 in
  let left = list_lines model left_width body_height in
  let right = preview_lines model right_width body_height in

  List.map2 (fun left_line right_line -> left_line ^ " | " ^ right_line) left right

let preview_enabled model =
  model.preview_visible && model.terminal.width >= preview_threshold_width

let body_lines model body_height =
  if preview_enabled model then
    render_split_panes model model.terminal.width body_height
  else render_single_pane model model.terminal.width body_height

let view model =
  let width = model.terminal.width in
  let header =
    model |> header_lines
    |> List.map (pad width)
    |> function
    | [] -> []
    | first :: tail -> (first |> style ansi_bold) :: tail
  in
  let footer =
    model |> footer_lines
    |> List.map (pad width)
    |> List.map (style ansi_dim)
  in
  let notices = model |> notice_lines |> List.map (pad width) in
  let reserved =
    List.length header + List.length footer + List.length notices
  in
  let body_height = model.terminal.height - reserved |> Int.max 3 in
  let body = body_lines model body_height in

  header
  @ body
  @ notices
  @ footer
  |> String.concat "\n"
