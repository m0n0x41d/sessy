open Sessy_domain

type output_format =
  | Plain
  | Json

type cli_action =
  | Open_picker
  | List_sessions of output_format

type cmd =
  | Print_sessions of session list * output_format
  | Print_error of string

let parse_cli = function
  | [] -> Ok Open_picker
  | [ "list" ] -> Ok (List_sessions Plain)
  | [ "list"; "--json" ] -> Ok (List_sessions Json)
  | command :: _ -> Error ("unknown command: " ^ command)

let dispatch action index _config ~cwd:_ =
  match action with
  | Open_picker ->
      [ Print_error "interactive mode is not implemented yet" ]
  | List_sessions output_format ->
      [ Print_sessions (Sessy_index.all_sessions index, output_format) ]

let relative_age ~now updated_at =
  let age_seconds =
    now -. updated_at
    |> Float.max 0.
    |> int_of_float
  in

  let minute = 60 in
  let hour = 60 * minute in
  let day = 24 * hour in

  if age_seconds < minute then Printf.sprintf "%ds ago" age_seconds
  else if age_seconds < hour then Printf.sprintf "%dm ago" (age_seconds / minute)
  else if age_seconds < day then Printf.sprintf "%dh ago" (age_seconds / hour)
  else Printf.sprintf "%dd ago" (age_seconds / day)

let title_or_placeholder (session : session) =
  session.title
  |> Option.value ~default:"(untitled)"

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
      session.title |> Option.map (fun value -> `String value)
      |> Option.value ~default:`Null );
    ( "first_prompt",
      session.first_prompt |> Option.map (fun value -> `String value)
      |> Option.value ~default:`Null );
    ("cwd", `String session.cwd);
    ( "project_key",
      session.project_key |> Option.map (fun value -> `String value)
      |> Option.value ~default:`Null );
    ( "model",
      session.model |> Option.map (fun value -> `String value)
      |> Option.value ~default:`Null );
    ("updated_at", `Float session.updated_at);
    ("is_active", `Bool session.is_active);
  ]

let format_session_json (session : session) =
  `Assoc (session_json_fields session)

let format_sessions ~now output_format sessions =
  match output_format with
  | Plain ->
      sessions
      |> List.map (format_session_plain ~now)
      |> String.concat "\n"
  | Json ->
      sessions
      |> List.map format_session_json
      |> fun values -> `List values
      |> Yojson.Safe.to_string
