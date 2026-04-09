open Alcotest
open Sessy_domain

let require_session_id value =
  value |> Session_id.of_string |> function
  | Some session_id -> session_id
  | None -> fail "expected a non-empty session id"

let require_some label option_value =
  option_value |> function Some value -> value | None -> fail label

let require_ok label result_value =
  result_value |> function Ok value -> value | Error _ -> fail label

let with_temp_file contents run =
  let path = Filename.temp_file "sessy-config-" ".toml" in

  Out_channel.with_open_bin path (fun channel -> output_string channel contents);

  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> run path)

let contains_substring ~needle haystack =
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in

  let rec loop index =
    if needle_length = 0 then true
    else if index + needle_length > haystack_length then false
    else if String.sub haystack index needle_length = needle then true
    else loop (index + 1)
  in

  loop 0

let make_session ?(tool = Codex) ?(cwd = "/tmp/project") id =
  {
    id = require_session_id id;
    tool;
    title = Some "Launch profile identity";
    first_prompt = Some "Check profile resolution";
    cwd;
    project_key = Some "sessy";
    model = Some "gpt-5";
    updated_at = 1_700_000_000.;
    is_active = false;
  }

let test_cross_tool_extends_falls_back_to_section_identity () =
  let has_cross_tool_warning warning =
    warning
    |> contains_substring
         ~needle:"cross-tool extends=\"codex\" is unsupported; expected claude"
    && warning |> contains_substring ~needle:"profiles.claude.fast.extends"
  in
  let raw_config =
    {|
[profiles.codex.fast]
argv_append = ["--profile", "codex-fast"]

[profiles.claude.fast]
extends = "codex"
argv_append = ["--profile", "claude-fast"]
|}
  in

  with_temp_file raw_config (fun path ->
      let loaded_config, warnings =
        Sessy_shell.load_config_from_paths [ path ]
      in
      let config =
        {
          loaded_config with
          sources = [];
          launches =
            [
              ( Codex,
                {
                  argv_template =
                    ("codex", [ "resume"; "{{profile}}"; "{{id}}" ]);
                  cwd_policy = `Session;
                  default_exec_mode = Spawn;
                } );
            ];
        }
      in
      let session = make_session "01999f1e-084e-77d3-9b2d-5a2692a779d5" in
      let index = Sessy_index.build [ session ] in
      let codex_profiles =
        config.profiles
        |> List.filter (fun profile -> Tool.equal profile.base_tool Codex)
      in
      let claude_profiles =
        config.profiles
        |> List.filter (fun profile -> Tool.equal profile.base_tool Claude)
      in
      let codex_fast =
        codex_profiles
        |> List.find_opt (fun profile -> String.equal profile.name "fast")
        |> require_some "expected codex fast profile"
      in
      let claude_fast =
        claude_profiles
        |> List.find_opt (fun profile -> String.equal profile.name "fast")
        |> require_some "expected claude fast profile"
      in
      let command =
        Sessy_shell.resolve_launch_cmd ~config ~index
          ~request:(Sessy_shell.Session_request session.id) ~active_profile:None
          ~launch_mode:Sessy_ui.Dry_run ~cwd:"/tmp/fallback" ~repo_root:None
          ~now:1_900_000_000.
        |> require_ok "expected codex launch to resolve deterministically"
      in

      check int "one Codex profile remains visible to Codex runtime" 1
        (List.length codex_profiles);
      check int "cross-tool extends stays in Claude section" 1
        (List.length claude_profiles);
      check (list string) "Codex profile keeps its args"
        [ "--profile"; "codex-fast" ]
        codex_fast.argv_append;
      check (list string) "Claude section keeps its own args"
        [ "--profile"; "claude-fast" ]
        claude_fast.argv_append;
      check
        (pair string (list string))
        "Codex launch resolves against Codex fast only"
        ( "codex",
          [
            "resume";
            "fast";
            "01999f1e-084e-77d3-9b2d-5a2692a779d5";
            "--profile";
            "codex-fast";
          ] )
        command.argv;
      check bool "cross-tool extends warning recorded" true
        (warnings |> List.exists has_cross_tool_warning))

let () =
  run "config loader profile identity"
    [
      ( "profiles",
        [
          test_case "cross-tool extends falls back to section identity" `Quick
            test_cross_tool_extends_falls_back_to_section_identity;
        ] );
    ]
