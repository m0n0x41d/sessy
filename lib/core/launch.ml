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

let render_display argv =
  argv
  |> argv_elements
  |> String.concat " "

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

  (expanded_head, expanded_tail)

let expand_template session profile template =
  let argv =
    template.argv_template
    |> expand_argv_template session profile
  in

  {
    argv;
    cwd = resolve_cwd session template.cwd_policy;
    exec_mode = resolve_exec_mode profile template;
    display = render_display argv;
  }
