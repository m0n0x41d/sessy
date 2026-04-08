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

type cmd =
  | Launch of launch_cmd
  | Print_notice of string
  | Print_sessions of session list * output_format
  | Print_preview of preview
  | Run_doctor
  | Print_error of string

type parsed_args = {
  dry_run : bool;
  json : bool;
  positionals : string list;
  unknown_flags : string list;
}

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
                  |> Result.map (fun session_id ->
                      let launch_mode =
                        if args.dry_run then Dry_run else Default
                      in

                      Resume_id (session_id, launch_mode))
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
                  |> Result.map (fun session_id -> Preview_session session_id)
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

let selected_profile_name config active_profile =
  match active_profile with
  | Some _ as profile_name -> profile_name
  | None -> config.selected_profile

let lookup_profile (config : config) active_profile tool =
  Option.bind
    (selected_profile_name config active_profile)
    (fun profile_name ->
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

let select_last_session index ~cwd =
  let sessions = Sessy_index.all_sessions index in
  let cwd_session =
    sessions
    |> List.find_opt (fun (session : session) -> String.equal session.cwd cwd)
  in

  match cwd_session with
  | Some _ as found -> found
  | None -> ( match sessions with first :: _ -> Some first | [] -> None)

let session_not_found_message session_id =
  session_id |> Session_id.to_string |> Printf.sprintf "session not found: %s"

let dispatch action index config ~cwd =
  match action with
  | Open_picker -> [ Print_notice "interactive mode is not implemented yet" ]
  | List_sessions output_format ->
      [ Print_sessions (Sessy_index.all_sessions index, output_format) ]
  | Resume_last launch_mode -> (
      match select_last_session index ~cwd with
      | None -> [ Print_error "no sessions available" ]
      | Some session -> (
          match prepare_launch launch_mode config None session with
          | Ok launch -> [ Launch launch ]
          | Error message -> [ Print_error message ]))
  | Resume_id (session_id, launch_mode) -> (
      match Sessy_index.find_by_id index session_id with
      | None -> [ Print_error (session_not_found_message session_id) ]
      | Some session -> (
          match prepare_launch launch_mode config None session with
          | Ok launch -> [ Launch launch ]
          | Error message -> [ Print_error message ]))
  | Preview_session session_id -> (
      match Sessy_index.find_by_id index session_id with
      | None -> [ Print_error (session_not_found_message session_id) ]
      | Some session ->
          let launch = session |> launch_for_session config None in

          [ Print_preview { session; launch } ])
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
