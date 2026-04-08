open Sessy_domain

let option_or_empty value = value |> Option.value ~default:""

let replace_literal ~pattern ~replacement value =
  let pattern_length = String.length pattern in
  let value_length = String.length value in
  let buffer = Buffer.create value_length in

  let rec loop index =
    if index >= value_length then ()
    else if
      pattern_length > 0
      && index + pattern_length <= value_length
      && String.sub value index pattern_length = pattern
    then (
      Buffer.add_string buffer replacement;
      loop (index + pattern_length))
    else (
      Buffer.add_char buffer value.[index];
      loop (index + 1))
  in

  loop 0;
  Buffer.contents buffer

let session_placeholders session =
  [
    ("{{id}}", Session_id.to_string session.id);
    ("{{tool}}", Tool.to_string session.tool);
    ("{{cwd}}", session.cwd);
    ("{{project}}", option_or_empty session.project_key);
    ("{{title}}", option_or_empty session.title);
  ]

let substitute_placeholder session value =
  session_placeholders session
  |> List.fold_left
       (fun current (pattern, replacement) ->
         current |> replace_literal ~pattern ~replacement)
       value

let substitute_profile profile value =
  profile
  |> Option.map (fun selected ->
      value |> replace_literal ~pattern:"{{profile}}" ~replacement:selected.name)
  |> Option.value ~default:value

let append_profile_args profile argv =
  argv
  |> fun current ->
  match profile with
  | None -> current
  | Some selected -> current @ selected.argv_append

let expand_arg session profile value =
  value
  |> substitute_placeholder session
  |> substitute_profile profile

let resolve_cwd (session : session) cwd_policy =
  match cwd_policy with `Session -> session.cwd | `Current -> "."

let resolve_exec_mode profile template =
  match profile with
  | None -> template.default_exec_mode
  | Some selected ->
      selected.exec_mode_override
      |> Option.value ~default:template.default_exec_mode

let argv_elements (head, tail) =
  head :: tail

let is_shell_safe_char = function
  | 'a' .. 'z'
  | 'A' .. 'Z'
  | '0' .. '9'
  | '/'
  | '.'
  | '_'
  | '-'
  | ':'
  | '='
  | ','
  | '+'
  | '@'
  | '%'
  | '^' ->
      true
  | _ -> false

let requires_shell_quotes value =
  value = ""
  || not (String.for_all is_shell_safe_char value)

let quote_display_arg value =
  value
  |> fun current ->
  if requires_shell_quotes current then
    current
    |> replace_literal ~pattern:"'" ~replacement:"'\"'\"'"
    |> Printf.sprintf "'%s'"
  else current

let render_display argv =
  argv
  |> argv_elements
  |> List.map quote_display_arg
  |> String.concat " "

let incompatible_profile_error (session : session) (profile : profile) =
  Invalid_value
    ( "profile.base_tool",
      Printf.sprintf
        "profile %s targets %s but session %s uses %s"
        profile.name
        (Tool.to_string profile.base_tool)
        (Session_id.to_string session.id)
        (Tool.to_string session.tool) )

let resolve_profile (session : session) (profile : profile option) =
  profile
  |> function
  | None -> Ok None
  | Some selected when Tool.equal selected.base_tool session.tool ->
      Ok (Some selected)
  | Some selected -> Error (incompatible_profile_error session selected)

let invalid_program_error value =
  Invalid_value
    ("launch_template.argv_template", Printf.sprintf "program is blank: %S" value)

let validate_program value =
  value
  |> String.trim
  |> String.length
  |> function
  | 0 -> Error (invalid_program_error value)
  | _ -> Ok value

let expand_argv_template session profile argv_template =
  let head, tail = argv_template in
  let expanded_head =
    head
    |> expand_arg session profile
  in
  let expanded_tail =
    tail
    |> List.map (expand_arg session profile)
    |> append_profile_args profile
  in

  expanded_head
  |> validate_program
  |> Result.map (fun valid_head -> (valid_head, expanded_tail))

let expand_template session profile template =
  profile
  |> resolve_profile session
  |> fun resolved_profile ->
  Result.bind resolved_profile (fun compatible_profile ->
      template.argv_template
      |> expand_argv_template session compatible_profile
      |> Result.map (fun argv ->
             {
               argv;
               cwd = resolve_cwd session template.cwd_policy;
               exec_mode = resolve_exec_mode compatible_profile template;
               display = render_display argv;
             }))
