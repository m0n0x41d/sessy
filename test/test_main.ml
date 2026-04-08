open Alcotest
open Sessy_domain

let require_session_id value =
  value
  |> Session_id.of_string
  |> function
  | Some session_id -> session_id
  | None -> fail "expected a non-empty session id"

let test_session_id_validation () =
  check bool "empty id rejected" false (Option.is_some (Session_id.of_string ""));

  let session_id = require_session_id "abcdefghij" in

  check bool "tool equality" true (Tool.equal Claude Claude);
  check bool "tool inequality" false (Tool.equal Claude Codex);
  check string "tool string" "claude" (Tool.to_string Claude);
  check string "full session id" "abcdefghij" (Session_id.to_string session_id);
  check string "short session id" "abcdefgh" (Session_id.short session_id)

let test_domain_record_construction () =
  let session_id = require_session_id "codex-session-1234" in

  let session =
    {
      id = session_id;
      tool = Codex;
      title = Some "Fix ranking regression";
      first_prompt = Some "Review the failing matcher tests";
      cwd = "/tmp/sessy";
      project_key = Some "sessy";
      model = Some "gpt-5";
      updated_at = 1_712_345_678.0;
      is_active = true;
    }
  in

  let launch =
    {
      argv = ("codex", [ "resume"; Session_id.to_string session.id ]);
      cwd = session.cwd;
      exec_mode = Spawn;
      display = "codex resume codex-session-1234";
    }
  in

  let config =
    {
      default_scope = Repo;
      preview = true;
      sources =
        [
          {
            tool = Codex;
            history_path = "~/.codex/history.jsonl";
            projects_path = None;
            sessions_path = Some "~/.codex/sessions";
          };
        ];
      launches =
        [
          ( Codex,
            {
              argv_template = [ "codex"; "resume"; "{{id}}" ];
              cwd_policy = `Session;
              default_exec_mode = Spawn;
            } );
        ];
      profiles =
        [
          {
            name = "fast";
            base_tool = Codex;
            argv_append = [ "--profile"; "fast" ];
            exec_mode_override = Some Print;
          };
        ];
    }
  in

  check bool "session active" true session.is_active;
  check string "launch executable" "codex" (fst launch.argv);
  check int "single source configured" 1 (List.length config.sources)

let () =
  run
    "sessy"
    [
      ( "domain",
        [
          test_case "session_id validation" `Quick test_session_id_validation;
          test_case
            "representative domain records compile"
            `Quick
            test_domain_record_construction;
        ] );
    ]
