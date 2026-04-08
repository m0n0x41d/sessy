open Sessy_domain

let option_or_empty value = value |> Option.value ~default:""
let profile_placeholder = "{{profile}}"

let session_placeholders =
  [
    ("{{id}}", fun session -> Session_id.to_string session.id);
    ("{{tool}}", fun session -> Tool.to_string session.tool);
    ("{{cwd}}", fun session -> session.cwd);
    ("{{project}}", fun session -> option_or_empty session.project_key);
    ("{{title}}", fun session -> option_or_empty session.title);
  ]

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

let find_placeholder_end value start_index =
  let max_index = String.length value - 1 in

  let rec loop index =
    if index >= max_index then None
    else if value.[index] = '}' && value.[index + 1] = '}' then Some (index + 2)
    else loop (index + 1)
  in

  loop (start_index + 2)

let session_placeholder_value session placeholder =
  session_placeholders
  |> List.find_map (fun (pattern, render) ->
      if String.equal pattern placeholder then Some (render session) else None)

let profile_placeholder_value profile value =
  match profile with
  | Some selected -> Ok selected.name
  | None ->
      Error
        (Invalid_value
           ( "launch_template.argv_template",
             Printf.sprintf "template requires an active profile for %S" value
           ))

let placeholder_value session profile value placeholder =
  if String.equal placeholder profile_placeholder then
    profile_placeholder_value profile value
  else
    placeholder
    |> session_placeholder_value session
    |> Option.value ~default:placeholder
    |> Result.ok

let expand_arg session profile value =
  let value_length = String.length value in
  let buffer = Buffer.create value_length in

  let rec loop index =
    if index >= value_length then Ok (Buffer.contents buffer)
    else if
      index + 1 < value_length && value.[index] = '{' && value.[index + 1] = '{'
    then
      index |> find_placeholder_end value |> function
      | None ->
          Buffer.add_char buffer value.[index];
          loop (index + 1)
      | Some end_index ->
          let placeholder = String.sub value index (end_index - index) in

          Result.bind (placeholder_value session profile value placeholder)
            (fun replacement ->
              Buffer.add_string buffer replacement;
              loop end_index)
    else (
      Buffer.add_char buffer value.[index];
      loop (index + 1))
  in

  loop 0

let append_profile_args profile argv =
  argv |> fun current ->
  match profile with
  | None -> current
  | Some selected -> current @ selected.argv_append

let collect_results items =
  let collect accumulated current =
    Result.bind accumulated (fun collected ->
        current |> Result.map (fun item -> item :: collected))
  in

  items |> List.rev |> List.fold_left collect (Ok [])

let resolve_cwd (session : session) cwd_policy =
  match cwd_policy with `Session -> session.cwd | `Current -> "."

let resolve_exec_mode profile template =
  match profile with
  | None -> template.default_exec_mode
  | Some selected ->
      selected.exec_mode_override
      |> Option.value ~default:template.default_exec_mode

let argv_elements (head, tail) = head :: tail

let is_shell_safe_char = function
  | 'a' .. 'z'
  | 'A' .. 'Z'
  | '0' .. '9'
  | '/' | '.' | '_' | '-' | ':' | '=' | ',' | '+' | '@' | '%' | '^' ->
      true
  | _ -> false

let requires_shell_quotes value =
  value = "" || not (String.for_all is_shell_safe_char value)

let quote_display_arg value =
  value |> fun current ->
  if requires_shell_quotes current then
    current
    |> replace_literal ~pattern:"'" ~replacement:"'\"'\"'"
    |> Printf.sprintf "'%s'"
  else current

let render_display argv =
  argv |> argv_elements |> List.map quote_display_arg |> String.concat " "

let incompatible_profile_error (session : session) (profile : profile) =
  Invalid_value
    ( "profile.base_tool",
      Printf.sprintf "profile %s targets %s but session %s uses %s" profile.name
        (Tool.to_string profile.base_tool)
        (Session_id.to_string session.id)
        (Tool.to_string session.tool) )

let resolve_profile (session : session) (profile : profile option) =
  profile |> function
  | None -> Ok None
  | Some selected when Tool.equal selected.base_tool session.tool ->
      Ok (Some selected)
  | Some selected -> Error (incompatible_profile_error session selected)

let invalid_program_error value =
  Invalid_value
    ( "launch_template.argv_template",
      Printf.sprintf "program is blank: %S" value )

let validate_program value =
  value |> String.trim |> String.length |> function
  | 0 -> Error (invalid_program_error value)
  | _ -> Ok value

let expand_argv_template session profile argv_template =
  let head, tail = argv_template in
  let expanded_head = head |> expand_arg session profile in
  let expanded_tail =
    tail
    |> List.map (expand_arg session profile)
    |> collect_results
    |> Result.map (append_profile_args profile)
  in

  Result.bind expanded_head validate_program |> fun validated_head ->
  Result.bind validated_head (fun valid_head ->
      expanded_tail |> Result.map (fun valid_tail -> (valid_head, valid_tail)))

let expand_template session profile template =
  profile |> resolve_profile session |> fun resolved_profile ->
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
