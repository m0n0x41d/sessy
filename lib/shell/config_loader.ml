open Sessy_domain

type warnings = string list

let tool_name = Tool.to_string
let default_tool_order = [ Claude; Codex ]

let warning path message =
  Printf.sprintf "%s: %s" path message

let lookup_source tool sources =
  sources |> List.find_opt (fun source -> Tool.equal source.tool tool)

let lookup_launch tool launches =
  launches |> List.find_opt (fun (candidate, _) -> Tool.equal candidate tool)

let replace_source sources source =
  let rec loop acc = function
    | [] -> (source :: acc) |> List.rev
    | current :: tail when Tool.equal current.tool source.tool ->
        List.rev_append acc (source :: tail)
    | current :: tail -> loop (current :: acc) tail
  in

  loop [] sources

let replace_launch launches tool launch =
  let rec loop acc = function
    | [] -> ((tool, launch) :: acc) |> List.rev
    | (current_tool, _) :: tail when Tool.equal current_tool tool ->
        List.rev_append acc ((tool, launch) :: tail)
    | current :: tail -> loop (current :: acc) tail
  in

  loop [] launches

let replace_profile profiles profile =
  let rec loop acc = function
    | [] -> (profile :: acc) |> List.rev
    | current :: tail
      when Tool.equal current.base_tool profile.base_tool
           && String.equal current.name profile.name ->
        List.rev_append acc (profile :: tail)
    | current :: tail -> loop (current :: acc) tail
  in

  loop [] profiles

let find_string toml path = Otoml.find_opt toml Otoml.get_string path
let find_bool toml path = Otoml.find_opt toml Otoml.get_boolean path

let find_string_list toml path =
  Otoml.find_opt toml (Otoml.get_array Otoml.get_string) path

let parse_scope = function
  | "cwd" -> Ok Cwd
  | "repo" -> Ok Repo
  | "all" -> Ok All
  | value -> Error (Printf.sprintf "unsupported scope %S" value)

let parse_cwd_policy = function
  | "session" -> Ok `Session
  | "current" -> Ok `Current
  | value -> Error (Printf.sprintf "unsupported cwd_policy %S" value)

let parse_exec_mode = function
  | "spawn" -> Ok Spawn
  | "exec" -> Ok Exec
  | "print" -> Ok Print
  | value -> Error (Printf.sprintf "unsupported exec_mode %S" value)

let update_ui path base toml warnings =
  let default_scope, warnings =
    match find_string toml [ "ui"; "scope" ] with
    | None -> (base.default_scope, warnings)
    | Some value -> (
        match value |> String.lowercase_ascii |> parse_scope with
        | Ok scope -> (scope, warnings)
        | Error message -> (base.default_scope, warning path message :: warnings))
  in
  let preview =
    find_bool toml [ "ui"; "preview" ]
    |> Option.value ~default:base.preview
  in

  ({ base with default_scope; preview }, warnings)

let update_sources _path base toml warnings =
  default_tool_order
  |> List.fold_left
       (fun (config, warnings) tool ->
         match lookup_source tool config.sources with
         | None -> (config, warnings)
         | Some current -> (
             match
               Otoml.path_exists toml [ "sources"; tool_name tool ]
             with
             | false -> (config, warnings)
             | true ->
                 let source_path = [ "sources"; tool_name tool ] in
                 let history =
                   find_string toml (source_path @ [ "history" ])
                   |> Option.value ~default:current.history_path
                 in
                 let projects_path =
                   match find_string toml (source_path @ [ "projects" ]) with
                   | Some value -> Some value
                   | None -> current.projects_path
                 in
                 let sessions_path =
                   match find_string toml (source_path @ [ "sessions" ]) with
                   | Some value -> Some value
                   | None -> current.sessions_path
                 in
                 let source =
                   {
                     tool;
                     history_path = history;
                     projects_path;
                     sessions_path;
                   }
                 in
                 ({ config with sources = replace_source config.sources source }, warnings)))
       (base, warnings)

let update_launches path base toml warnings =
  default_tool_order
  |> List.fold_left
       (fun (config, warnings) tool ->
         match lookup_launch tool config.launches with
         | None -> (config, warnings)
         | Some (_, current) ->
             let launch_path = [ "launch"; tool_name tool ] in
             if not (Otoml.path_exists toml launch_path) then (config, warnings)
             else
               let argv_template, warnings =
                 match find_string_list toml (launch_path @ [ "argv" ]) with
                 | Some (head :: tail) -> ((head, tail), warnings)
                 | Some [] ->
                     ( current.argv_template,
                       warning path "launch argv must be non-empty" :: warnings )
                 | None -> (current.argv_template, warnings)
               in
               let cwd_policy, warnings =
                 match find_string toml (launch_path @ [ "cwd_policy" ]) with
                 | None -> (current.cwd_policy, warnings)
                 | Some value -> (
                     match value |> String.lowercase_ascii |> parse_cwd_policy with
                     | Ok value -> (value, warnings)
                     | Error message ->
                         (current.cwd_policy, warning path message :: warnings))
               in
               let default_exec_mode, warnings =
                 match find_string toml (launch_path @ [ "exec_mode" ]) with
                 | None -> (current.default_exec_mode, warnings)
                 | Some value -> (
                     match value |> String.lowercase_ascii |> parse_exec_mode with
                     | Ok value -> (value, warnings)
                     | Error message ->
                         ( current.default_exec_mode,
                           warning path message :: warnings ))
               in
               let launch =
                 { argv_template; cwd_policy; default_exec_mode }
               in

               ( { config with launches = replace_launch config.launches tool launch },
                 warnings ))
       (base, warnings)

let update_profiles path base toml warnings =
  default_tool_order
  |> List.fold_left
       (fun (config, warnings) tool ->
         let profiles_path = [ "profiles"; tool_name tool ] in

         if not (Otoml.path_exists toml profiles_path) then (config, warnings)
         else
           match Otoml.find_result toml Otoml.get_table profiles_path with
           | Error message -> (config, warning path message :: warnings)
           | Ok profile_entries ->
               profile_entries
               |> List.fold_left
                    (fun (config, warnings) (profile_name, profile_toml) ->
                      let base_tool, warnings =
                        match Otoml.find_opt profile_toml Otoml.get_string [ "extends" ] with
                        | Some value when String.equal (String.lowercase_ascii value) "codex" ->
                            (Codex, warnings)
                        | Some value when String.equal (String.lowercase_ascii value) "claude" ->
                            (Claude, warnings)
                        | Some value ->
                            let warning_message =
                              Printf.sprintf
                                "profile %s has unsupported extends=%S"
                                profile_name value
                            in
                            (tool, warning path warning_message :: warnings)
                        | None -> (tool, warnings)
                      in
                      let argv_append =
                        Otoml.find_opt profile_toml
                          (Otoml.get_array Otoml.get_string)
                          [ "argv_append" ]
                        |> Option.value ~default:[]
                      in
                      let exec_mode_override, warnings =
                        match
                          Otoml.find_opt profile_toml Otoml.get_string [ "exec_mode" ]
                        with
                        | None -> (None, warnings)
                        | Some value -> (
                            match
                              value |> String.lowercase_ascii |> parse_exec_mode
                            with
                            | Ok value -> (Some value, warnings)
                            | Error message ->
                                (None, warning path message :: warnings))
                      in
                      let profile =
                        { name = profile_name; base_tool; argv_append; exec_mode_override }
                      in

                      ( { config with profiles = replace_profile config.profiles profile },
                        warnings ))
                    (config, warnings))
       (base, warnings)

let apply_toml path base toml =
  let config, warnings = update_ui path base toml [] in
  let config, warnings = update_sources path config toml warnings in
  let config, warnings = update_launches path config toml warnings in
  let config, warnings = update_profiles path config toml warnings in

  (config, warnings |> List.rev)

let parse_file path base =
  match Fs.read_file path with
  | Error (`Io_error message) -> (base, [ warning path message ])
  | Ok raw -> (
      match Otoml.Parser.from_string_result raw with
      | Ok toml -> apply_toml path base toml
      | Error message -> (base, [ warning path message ]))

let load_config_from_paths paths =
  let initial = Sessy_core.default_config in

  paths
  |> List.fold_left
       (fun (config, warnings, layers) path ->
         let expanded = Fs.expand_home path in

         if not (Fs.file_exists expanded) then (config, warnings, layers)
         else
           let updated, parse_warnings = parse_file expanded config in

           (updated, warnings @ parse_warnings, updated :: layers))
       (initial, [], [])
  |> fun (_config, warnings, layers) ->
  (Sessy_core.resolve_config (layers |> List.rev), warnings)

let default_paths () =
  [
    "~/.config/sessy/config.toml";
    Filename.concat (Sys.getcwd ()) ".sessy.toml";
  ]

let load_config () = load_config_from_paths (default_paths ())
