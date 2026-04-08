open Alcotest
open Sessy_domain

let require_session_id value =
  value |> Session_id.of_string |> function
  | Some session_id -> session_id
  | None -> fail "expected a non-empty session id"

let make_session ?title ?project_key id =
  {
    id = require_session_id id;
    tool = Codex;
    title;
    first_prompt = Some "Check profile placeholder behavior";
    cwd = "/tmp/sessy";
    project_key;
    model = Some "gpt-5";
    updated_at = 1_700_000_000.;
    is_active = false;
  }

let test_profile_placeholder_requires_selected_profile () =
  let session =
    make_session ~title:"Launch placeholder regression" ~project_key:"sessy"
      "profile-missing-1"
  in
  let template =
    {
      argv_template = ("codex", [ "resume"; "{{profile}}"; "{{id}}" ]);
      cwd_policy = `Session;
      default_exec_mode = Spawn;
    }
  in

  let result = Sessy_core.expand_template session None template in

  check bool "missing profile is rejected" true
    (match result with
    | Error (Invalid_value ("launch_template.argv_template", _)) -> true
    | Ok _ | Error _ -> false)

let test_session_data_with_profile_literal_is_not_reinterpreted () =
  let literal_title = "literal {{profile}} title" in
  let session =
    make_session ~title:literal_title ~project_key:"sessy" "profile-literal-1"
  in
  let template =
    {
      argv_template = ("codex", [ "resume"; "{{title}}" ]);
      cwd_policy = `Session;
      default_exec_mode = Spawn;
    }
  in

  let result = Sessy_core.expand_template session None template in

  match result with
  | Ok launch_cmd ->
      check (list string) "session data is preserved verbatim"
        [ "resume"; literal_title ]
        (launch_cmd.argv |> snd)
  | Error _ ->
      fail "session data should not be reinterpreted as template syntax"

let () =
  run "launch profile placeholder"
    [
      ( "launch",
        [
          test_case "missing active profile returns config error" `Quick
            test_profile_placeholder_requires_selected_profile;
          test_case "session data containing {{profile}} stays literal" `Quick
            test_session_data_with_profile_literal_is_not_reinterpreted;
        ] );
    ]
