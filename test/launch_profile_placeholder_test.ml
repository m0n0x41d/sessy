open Alcotest
open Sessy_domain

let require_session_id value =
  value
  |> Session_id.of_string
  |> function
  | Some session_id -> session_id
  | None -> fail "expected a non-empty session id"

let make_session id =
  {
    id = require_session_id id;
    tool = Codex;
    title = Some "Launch placeholder regression";
    first_prompt = Some "Check profile placeholder behavior";
    cwd = "/tmp/sessy";
    project_key = Some "sessy";
    model = Some "gpt-5";
    updated_at = 1_700_000_000.;
    is_active = false;
  }

let test_profile_placeholder_requires_selected_profile () =
  let session = make_session "profile-missing-1" in
  let template =
    {
      argv_template = ("codex", [ "resume"; "{{profile}}"; "{{id}}" ]);
      cwd_policy = `Session;
      default_exec_mode = Spawn;
    }
  in

  let result =
    Sessy_core.expand_template session None template
  in

  check bool "missing profile is rejected" true
    (match result with
    | Error (Invalid_value ("launch_template.argv_template", _)) -> true
    | Ok _ | Error _ -> false)

let () =
  run
    "launch profile placeholder"
    [
      ( "launch",
        [
          test_case
            "missing active profile returns config error"
            `Quick
            test_profile_placeholder_requires_selected_profile;
        ] );
    ]
