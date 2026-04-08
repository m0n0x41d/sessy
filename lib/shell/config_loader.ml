open Sessy_domain

type warnings = string list
type scoped_profile = { section_tool : tool; profile : profile }

type loader_state = {
  config : config;
  scoped_profiles : scoped_profile list;
}

let tool_name = Tool.to_string
let default_tool_order = [ Claude; Codex ]
let warning path message = Printf.sprintf "%s: %s" path message

let field_warning path field message =
  field |> Otoml.string_of_path
  |> Printf.sprintf "%s: %s" message
  |> warning path

let lookup_source tool sources =
  sources |> List.find_opt (fun source -> Tool.equal source.tool tool)

let lookup_launch tool launches =
  launches |> List.find_opt (fun (candidate, _) -> Tool.equal candidate tool)

let replace_source sources source =
  let rec loop acc = function
    | [] -> source :: acc |> List.rev
    | current :: tail when Tool.equal current.tool source.tool ->
        List.rev_append acc (source :: tail)
    | current :: tail -> loop (current :: acc) tail
  in

  loop [] sources

let replace_launch launches tool launch =
  let rec loop acc = function
    | [] -> (tool, launch) :: acc |> List.rev
    | (current_tool, _) :: tail when Tool.equal current_tool tool ->
        List.rev_append acc ((tool, launch) :: tail)
    | current :: tail -> loop (current :: acc) tail
  in

  loop [] launches

let replace_scoped_profile scoped_profiles scoped_profile =
  let rec loop acc = function
    | [] -> scoped_profile :: acc |> List.rev
    | current :: tail
      when Tool.equal current.section_tool scoped_profile.section_tool
           && String.equal current.profile.name scoped_profile.profile.name ->
        List.rev_append acc (scoped_profile :: tail)
    | current :: tail -> loop (current :: acc) tail
  in

  loop [] scoped_profiles

let fallback_profile tool profile_name =
  {
    name = profile_name;
    base_tool = tool;
    argv_append = [];
    exec_mode_override = None;
  }

let current_profile_for_section tool profile_name scoped_profiles =
  scoped_profiles
  |> List.find_opt (fun scoped_profile ->
         Tool.equal scoped_profile.section_tool tool
         && String.equal scoped_profile.profile.name profile_name)
  |> Option.map (fun scoped_profile -> scoped_profile.profile)

let materialize_profiles scoped_profiles =
  scoped_profiles
  |> List.map (fun scoped_profile -> scoped_profile.profile)

let with_config state config = { state with config }

let with_scoped_profiles state scoped_profiles =
  let config =
    {
      state.config with
      profiles = scoped_profiles |> materialize_profiles;
    }
  in

  { config; scoped_profiles }

let scoped_profile_of_profile profile =
  {
    section_tool = profile.base_tool;
    profile;
  }

let find_optional toml accessor field =
  if not (Otoml.path_exists toml field) then Ok None
  else field |> Otoml.find_result toml accessor |> Result.map Option.some

let find_string toml field = find_optional toml Otoml.get_string field
let find_bool toml field = find_optional toml Otoml.get_boolean field

let find_string_list toml field =
  find_optional toml (Otoml.get_array Otoml.get_string) field

let keep_on_error path field fallback warnings result =
  match result with
  | Ok None -> (fallback, warnings)
  | Ok (Some value) -> (value, warnings)
  | Error message -> (fallback, field_warning path field message :: warnings)

let keep_optional_string path field fallback warnings toml =
  match find_string toml field with
  | Ok None -> (fallback, warnings)
  | Ok (Some value) -> (Some value, warnings)
  | Error message -> (fallback, field_warning path field message :: warnings)

let keep_string path field fallback warnings toml =
  find_string toml field |> keep_on_error path field fallback warnings

let keep_bool path field fallback warnings toml =
  find_bool toml field |> keep_on_error path field fallback warnings

let keep_string_list path field fallback warnings toml =
  find_string_list toml field |> keep_on_error path field fallback warnings

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
    | Ok None -> (base.default_scope, warnings)
    | Ok (Some value) -> (
        match value |> String.lowercase_ascii |> parse_scope with
        | Ok scope -> (scope, warnings)
        | Error message -> (base.default_scope, warning path message :: warnings)
        )
    | Error message ->
        ( base.default_scope,
          field_warning path [ "ui"; "scope" ] message :: warnings )
  in
  let preview, warnings =
    toml |> keep_bool path [ "ui"; "preview" ] base.preview warnings
  in

  ({ base with default_scope; preview }, warnings)

let update_sources path base toml warnings =
  default_tool_order
  |> List.fold_left
       (fun (config, warnings) tool ->
         match lookup_source tool config.sources with
         | None -> (config, warnings)
         | Some current -> (
             match Otoml.path_exists toml [ "sources"; tool_name tool ] with
             | false -> (config, warnings)
             | true ->
                 let source_path = [ "sources"; tool_name tool ] in
                 let history, warnings =
                   toml
                   |> keep_string path
                        (source_path @ [ "history" ])
                        current.history_path warnings
                 in
                 let projects_path, warnings =
                   toml
                   |> keep_optional_string path
                        (source_path @ [ "projects" ])
                        current.projects_path warnings
                 in
                 let sessions_path, warnings =
                   toml
                   |> keep_optional_string path
                        (source_path @ [ "sessions" ])
                        current.sessions_path warnings
                 in
                 let source =
                   {
                     tool;
                     history_path = history;
                     projects_path;
                     sessions_path;
                   }
                 in
                 ( { config with sources = replace_source config.sources source },
                   warnings )))
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
               let current_argv =
                 current.argv_template |> fun (head, tail) -> head :: tail
               in
               let argv_template, warnings =
                 match
                   keep_string_list path (launch_path @ [ "argv" ]) current_argv
                     warnings toml
                 with
                 | [], warnings ->
                     ( current.argv_template,
                       warning path "launch argv must be non-empty" :: warnings
                     )
                 | head :: tail, warnings -> ((head, tail), warnings)
               in
               let cwd_policy, warnings =
                 match find_string toml (launch_path @ [ "cwd_policy" ]) with
                 | Ok None -> (current.cwd_policy, warnings)
                 | Ok (Some value) -> (
                     match
                       value |> String.lowercase_ascii |> parse_cwd_policy
                     with
                     | Ok value -> (value, warnings)
                     | Error message ->
                         (current.cwd_policy, warning path message :: warnings))
                 | Error message ->
                     ( current.cwd_policy,
                       field_warning path
                         (launch_path @ [ "cwd_policy" ])
                         message
                       :: warnings )
               in
               let default_exec_mode, warnings =
                 match find_string toml (launch_path @ [ "exec_mode" ]) with
                 | Ok None -> (current.default_exec_mode, warnings)
                 | Ok (Some value) -> (
                     match
                       value |> String.lowercase_ascii |> parse_exec_mode
                     with
                     | Ok value -> (value, warnings)
                     | Error message ->
                         ( current.default_exec_mode,
                           warning path message :: warnings ))
                 | Error message ->
                     ( current.default_exec_mode,
                       field_warning path
                         (launch_path @ [ "exec_mode" ])
                         message
                       :: warnings )
               in
               let launch = { argv_template; cwd_policy; default_exec_mode } in

               ( {
                   config with
                   launches = replace_launch config.launches tool launch;
                 },
                 warnings ))
       (base, warnings)

let update_profiles path state toml warnings =
  default_tool_order
  |> List.fold_left
       (fun (state, warnings) tool ->
         let profiles_path = [ "profiles"; tool_name tool ] in

         if not (Otoml.path_exists toml profiles_path) then (state, warnings)
         else
           match Otoml.find_result toml Otoml.get_table profiles_path with
           | Error message -> (state, warning path message :: warnings)
           | Ok profile_entries ->
               profile_entries
               |> List.fold_left
                    (fun (state, warnings) (profile_name, profile_toml) ->
                      let current_profile =
                        state.scoped_profiles
                        |> current_profile_for_section tool profile_name
                        |> Option.value
                             ~default:(fallback_profile tool profile_name)
                      in
                      let extends_field =
                        [ "profiles"; tool_name tool; profile_name; "extends" ]
                      in
                      let base_tool, warnings =
                        match find_string profile_toml [ "extends" ] with
                        | Ok (Some value)
                          when String.equal
                                 (String.lowercase_ascii value)
                                 "codex" ->
                            (Codex, warnings)
                        | Ok (Some value)
                          when String.equal
                                 (String.lowercase_ascii value)
                                 "claude" ->
                            (Claude, warnings)
                        | Ok (Some value) ->
                            let warning_message =
                              Printf.sprintf
                                "profile %s has unsupported extends=%S"
                                profile_name value
                            in
                            ( current_profile.base_tool,
                              warning path warning_message :: warnings )
                        | Ok None -> (current_profile.base_tool, warnings)
                        | Error message ->
                            ( current_profile.base_tool,
                              field_warning path extends_field message
                              :: warnings )
                      in
                      let argv_append_field =
                        [
                          "profiles";
                          tool_name tool;
                          profile_name;
                          "argv_append";
                        ]
                      in
                      let argv_append, warnings =
                        match
                          find_string_list profile_toml [ "argv_append" ]
                        with
                        | Ok None -> (current_profile.argv_append, warnings)
                        | Ok (Some value) -> (value, warnings)
                        | Error message ->
                            ( current_profile.argv_append,
                              field_warning path argv_append_field message
                              :: warnings )
                      in
                      let exec_mode_override, warnings =
                        match find_string profile_toml [ "exec_mode" ] with
                        | Ok None ->
                            (current_profile.exec_mode_override, warnings)
                        | Ok (Some value) -> (
                            match
                              value |> String.lowercase_ascii |> parse_exec_mode
                            with
                            | Ok value -> (Some value, warnings)
                            | Error message ->
                                ( current_profile.exec_mode_override,
                                  warning path message :: warnings ))
                        | Error message ->
                            let exec_mode_field =
                              [
                                "profiles";
                                tool_name tool;
                                profile_name;
                                "exec_mode";
                              ]
                            in
                            ( current_profile.exec_mode_override,
                              field_warning path exec_mode_field message
                              :: warnings )
                      in
                      let profile =
                        {
                          name = profile_name;
                          base_tool;
                          argv_append;
                          exec_mode_override;
                        }
                      in
                      let scoped_profile = { section_tool = tool; profile } in
                      let scoped_profiles =
                        replace_scoped_profile state.scoped_profiles
                          scoped_profile
                      in
                      let state = with_scoped_profiles state scoped_profiles in

                      (state, warnings))
                    (state, warnings))
       (state, warnings)

let apply_toml path state toml =
  let config, warnings = update_ui path state.config toml [] in
  let state = with_config state config in
  let config, warnings = update_sources path state.config toml warnings in
  let state = with_config state config in
  let config, warnings = update_launches path state.config toml warnings in
  let state = with_config state config in
  let state, warnings = update_profiles path state toml warnings in

  (state, warnings |> List.rev)

let parse_file path state =
  match Fs.read_file path with
  | Error (`Io_error message) -> (state, [ warning path message ])
  | Ok raw -> (
      match Otoml.Parser.from_string_result raw with
      | Ok toml -> apply_toml path state toml
      | Error message -> (state, [ warning path message ]))

let load_config_from_paths paths =
  let initial_config = Sessy_core.default_config in
  let initial =
    {
      config = initial_config;
      scoped_profiles =
        initial_config.profiles
        |> List.map scoped_profile_of_profile;
    }
  in

  paths
  |> List.fold_left
       (fun (state, warnings, layers) path ->
         let expanded = Fs.expand_home path in

         if not (Fs.file_exists expanded) then (state, warnings, layers)
         else
           let updated, parse_warnings = parse_file expanded state in

           (updated, warnings @ parse_warnings, updated.config :: layers))
       (initial, [], [])
  |> fun (_config, warnings, layers) ->
  (Sessy_core.resolve_config (layers |> List.rev), warnings)

let default_paths () =
  [
    "~/.config/sessy/config.toml"; Filename.concat (Sys.getcwd ()) ".sessy.toml";
  ]

let load_config () = load_config_from_paths (default_paths ())
