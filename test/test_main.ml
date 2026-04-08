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

let make_session ?(tool = Claude) ?title ?first_prompt ?(cwd = "/tmp")
    ?project_key ?model ?(updated_at = 0.) ?(is_active = false) id =
  {
    id = require_session_id id;
    tool;
    title;
    first_prompt;
    cwd;
    project_key;
    model;
    updated_at;
    is_active;
  }

let ranked_ids ranked_sessions =
  ranked_sessions
  |> List.map (fun ranked -> Session_id.to_string ranked.session.id)

let session_ids sessions =
  sessions |> List.map (fun session -> Session_id.to_string session.id)

let check_ranked_ids label expected ranked_sessions =
  check (list string) label expected (ranked_ids ranked_sessions)

let check_session_ids label expected sessions =
  check (list string) label expected (session_ids sessions)

let require_ranked label session_id ranked_sessions =
  ranked_sessions
  |> List.find_opt (fun ranked ->
         String.equal session_id (Session_id.to_string ranked.session.id))
  |> require_some label

let test_session_id_validation () =
  check bool "empty id rejected" false
    (Option.is_some (Session_id.of_string ""));

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
              argv_template = ("codex", [ "resume"; "{{id}}" ]);
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

let test_default_config_and_merge () =
  let default_config = Sessy_core.default_config in
  let empty_override =
    { default_config with sources = []; launches = []; profiles = [] }
  in
  let user_override =
    {
      default_scope = All;
      preview = false;
      sources =
        [
          {
            tool = Claude;
            history_path = "/tmp/custom-claude-history.jsonl";
            projects_path = Some "/tmp/custom-claude-projects";
            sessions_path = Some "/tmp/custom-claude-sessions";
          };
        ];
      launches =
        [
          ( Claude,
            {
              argv_template = ("claude", [ "--continue" ]);
              cwd_policy = `Current;
              default_exec_mode = Exec;
            } );
        ];
      profiles =
        [
          {
            name = "unsafe";
            base_tool = Claude;
            argv_append = [ "--dangerously-skip-permissions" ];
            exec_mode_override = Some Print;
          };
        ];
    }
  in
  let merged_empty = Sessy_core.merge_config default_config empty_override in
  let resolved = Sessy_core.resolve_config [ user_override ] in

  check bool "default preview enabled" true default_config.preview;
  check int "two default sources" 2 (List.length default_config.sources);
  check int "two default launch templates" 2
    (List.length default_config.launches);
  check int "empty override keeps sources"
    (List.length default_config.sources)
    (List.length merged_empty.sources);
  check int "empty override keeps launches"
    (List.length default_config.launches)
    (List.length merged_empty.launches);
  check int "override source count" 1 (List.length resolved.sources);
  check int "override profile count" 1 (List.length resolved.profiles);
  check bool "override preview applied" false resolved.preview;

  match resolved.default_scope with
  | All -> ()
  | Cwd | Repo -> fail "expected All scope after override"

let test_launch_expansion () =
  let session =
    make_session ~cwd:"/tmp/sessy" ~project_key:"sessy" ~title:"Fix ranking"
      "abc123"
  in
  let session_without_project =
    make_session ~cwd:"/tmp/sessy" ~title:"Fix ranking" "abc124"
  in
  let profile =
    Some
      {
        name = "unsafe";
        base_tool = Claude;
        argv_append = [ "--dangerously-skip-permissions" ];
        exec_mode_override = Some Print;
      }
  in
  let template =
    {
      argv_template =
        ( "claude",
          [
            "--resume";
            "{{id}}";
            "--project";
            "{{project}}";
            "--title";
            "{{title}}";
            "--cwd";
            "{{cwd}}";
            "{{profile}}";
            "{{custom}}";
          ] );
      cwd_policy = `Session;
      default_exec_mode = Spawn;
    }
  in
  let current_template =
    {
      argv_template = ("codex", [ "resume"; "{{id}}" ]);
      cwd_policy = `Current;
      default_exec_mode = Exec;
    }
  in
  let minimal_template =
    {
      argv_template = ("codex", []);
      cwd_policy = `Session;
      default_exec_mode = Spawn;
    }
  in
  let invalid_template =
    {
      argv_template = ("{{project}}", [ "--resume"; "{{id}}" ]);
      cwd_policy = `Session;
      default_exec_mode = Spawn;
    }
  in
  let mismatched_profile =
    Some
      {
        name = "codex-fast";
        base_tool = Codex;
        argv_append = [ "--profile"; "fast" ];
        exec_mode_override = Some Exec;
      }
  in
  let launch =
    Sessy_core.expand_template session profile template
    |> require_ok "expected valid launch template to expand"
  in
  let current_launch =
    Sessy_core.expand_template session None current_template
    |> require_ok "expected current launch template to expand"
  in
  let minimal_launch =
    Sessy_core.expand_template session None minimal_template
    |> require_ok "expected minimal launch template to expand"
  in

  check string "session cwd policy" "/tmp/sessy" launch.cwd;
  check bool "profile overrides exec mode" true
    (match launch.exec_mode with Print -> true | Spawn | Exec -> false);
  check string "program preserved" "claude" (fst launch.argv);
  check (list string) "expanded args"
    [
      "--resume";
      "abc123";
      "--project";
      "sessy";
      "--title";
      "Fix ranking";
      "--cwd";
      "/tmp/sessy";
      "unsafe";
      "{{custom}}";
      "--dangerously-skip-permissions";
    ]
    (snd launch.argv);
  check string "dry-run display"
    "claude --resume abc123 --project sessy --title 'Fix ranking' --cwd \
     /tmp/sessy unsafe '{{custom}}' --dangerously-skip-permissions"
    launch.display;
  check
    (pair string (list string))
    "minimal templates stay non-empty"
    ("codex", [])
    minimal_launch.argv;
  check
    (pair string (list string))
    "current template expands correctly"
    ("codex", [ "resume"; "abc123" ])
    current_launch.argv;
  check string "current cwd policy uses dot" "." current_launch.cwd;
  check bool "default exec mode preserved" true
    (match current_launch.exec_mode with
    | Exec -> true
    | Spawn | Print -> false);
  check bool "blank program is rejected" true
    (match Sessy_core.expand_template session_without_project None invalid_template with
    | Error (Invalid_value ("launch_template.argv_template", _)) -> true
    | Ok _ | Error _ -> false);
  check bool "mismatched profile is rejected" true
    (match Sessy_core.expand_template session mismatched_profile template with
    | Error (Invalid_value ("profile.base_tool", _)) -> true
    | Ok _ | Error _ -> false)

let test_fuzzy_matching () =
  let subsequence_score =
    Sessy_core.fuzzy_score ~pattern:"fxb" ~haystack:"fooXbar"
  in
  let empty_score =
    Sessy_core.fuzzy_score ~pattern:"" ~haystack:"anything"
    |> require_some "expected empty patterns to match"
  in
  let consecutive_score =
    Sessy_core.fuzzy_score ~pattern:"foo" ~haystack:"foobar"
    |> require_some "expected consecutive match to score"
  in
  let scattered_score =
    Sessy_core.fuzzy_score ~pattern:"fbr" ~haystack:"foobar"
    |> require_some "expected scattered match to score"
  in

  check bool "subsequence matches" true (Option.is_some subsequence_score);
  check bool "non-match returns none" true
    (Option.is_none (Sessy_core.fuzzy_score ~pattern:"zzz" ~haystack:"foobar"));
  check (float 0.000_001) "empty pattern score" 1. empty_score;
  check bool "consecutive bonus wins" true (consecutive_score > scattered_score)

let test_rank_empty_query_orders_by_context_and_recency () =
  let now = 5_000. in
  let query = { text = ""; scope = All; tool_filter = None; mode = Meta } in
  let sessions =
    [
      make_session ~cwd:"/outside/old" ~updated_at:1_000.
        ~title:"Old external session" "old-1";
      make_session ~cwd:"/work/sessy/lib" ~updated_at:3_000.
        ~title:"Repo session" "repo-1";
      make_session ~cwd:"/outside/recent" ~updated_at:2_500.
        ~title:"Recent external session" "recent-1";
      make_session ~cwd:"/work/sessy" ~updated_at:4_000. ~is_active:true
        ~title:"Exact active session" "exact-1";
    ]
  in
  let ranked =
    sessions
    |> List.filter_map
         (Sessy_core.rank query ~now ~cwd:"/work/sessy"
            ~repo_root:(Some "/work/sessy"))
    |> Sessy_core.sort_ranked
  in
  let recency_ranked =
    ranked
    |> require_ranked "expected recency-only result" "recent-1"
  in

  check_ranked_ids "empty query uses context then recency"
    [ "exact-1"; "repo-1"; "recent-1"; "old-1" ]
    ranked;
  check bool "recency-only results are labeled as recency" true
    (match recency_ranked.match_kind with
    | Recency -> true
    | Exact_cwd | Same_repo | Active | Id_prefix | Substring | Fuzzy -> false)

let test_rank_text_signals () =
  let now = 5_000. in
  let query = { text = "rank"; scope = All; tool_filter = None; mode = Meta } in
  let substring_session =
    make_session ~cwd:"/tmp/sub" ~updated_at:2_000. ~title:"ranking notes"
      "sub-1"
  in
  let fuzzy_session =
    make_session ~cwd:"/tmp/fuzzy" ~updated_at:2_000. ~title:"r-x-a-n-k notes"
      "fuzzy-1"
  in
  let ranked =
    [ fuzzy_session; substring_session ]
    |> List.filter_map
         (Sessy_core.rank query ~now ~cwd:"/nowhere" ~repo_root:None)
    |> Sessy_core.sort_ranked
  in

  check_ranked_ids "substring beats fuzzy" [ "sub-1"; "fuzzy-1" ] ranked;
  check bool "unmatched query rejected" true
    (Option.is_none
       (Sessy_core.rank query ~now ~cwd:"/nowhere" ~repo_root:None
          (make_session ~cwd:"/tmp/none" ~title:"other text" "none-1")))

let test_rank_id_prefix_kind () =
  let now = 5_000. in
  let query = { text = "abc"; scope = All; tool_filter = None; mode = Meta } in
  let ranked =
    make_session ~cwd:"/elsewhere" "abc123"
    |> Sessy_core.rank query ~now ~cwd:"/nowhere" ~repo_root:None
    |> require_some "expected id prefix match"
  in

  check bool "id prefix is best signal" true
    (match ranked.match_kind with
    | Id_prefix -> true
    | Exact_cwd | Same_repo | Active | Substring | Fuzzy | Recency -> false)

let test_rank_score_is_independent_of_result_set () =
  let now = 10_000. in
  let query = { text = ""; scope = All; tool_filter = None; mode = Meta } in
  let target =
    make_session ~cwd:"/tmp/target" ~updated_at:2_000. "target-1"
  in
  let neighbor =
    make_session ~cwd:"/tmp/neighbor" ~updated_at:9_000. "neighbor-1"
  in
  let target_ranked =
    target
    |> Sessy_core.rank query ~now ~cwd:"/elsewhere" ~repo_root:None
    |> require_some "expected target to rank"
  in
  let neighbor_ranked =
    neighbor
    |> Sessy_core.rank query ~now ~cwd:"/elsewhere" ~repo_root:None
    |> require_some "expected neighbor to rank"
  in
  let ranked_alone =
    [ target_ranked ]
    |> Sessy_core.sort_ranked
    |> require_ranked "expected target in single-result sort" "target-1"
  in
  let ranked_with_neighbor =
    [ target_ranked; neighbor_ranked ]
    |> Sessy_core.sort_ranked
    |> require_ranked "expected target in multi-result sort" "target-1"
  in

  check (float 0.000_001) "score is stable across result sets" ranked_alone.score
    ranked_with_neighbor.score

let test_filtering () =
  let sessions =
    [
      make_session ~cwd:"/work/sessy" ~tool:Claude "cwd-1";
      make_session ~cwd:"/work/sessy/lib" ~tool:Codex "repo-1";
      make_session ~cwd:"/work/sessy-other" ~tool:Claude "sibling-1";
      make_session ~cwd:"/outside/repo" ~tool:Codex "other-1";
    ]
  in

  check_session_ids "cwd filter is exact" [ "cwd-1" ]
    (Sessy_core.filter_scope Cwd ~cwd:"/work/sessy"
       ~repo_root:(Some "/work/sessy") sessions);
  check_session_ids "repo filter keeps only repo members" [ "cwd-1"; "repo-1" ]
    (Sessy_core.filter_scope Repo ~cwd:"/work/sessy"
       ~repo_root:(Some "/work/sessy") sessions);
  check_session_ids "repo filter degrades to all without root"
    [ "cwd-1"; "repo-1"; "sibling-1"; "other-1" ]
    (Sessy_core.filter_scope Repo ~cwd:"/work/sessy" ~repo_root:None sessions);
  check_session_ids "tool filter keeps codex only" [ "repo-1"; "other-1" ]
    (Sessy_core.filter_tool (Some Codex) sessions)

let () =
  run "sessy"
    [
      ( "domain",
        [
          test_case "session_id validation" `Quick test_session_id_validation;
          test_case "representative domain records compile" `Quick
            test_domain_record_construction;
        ] );
      ( "core",
        [
          test_case "config defaults and merge" `Quick
            test_default_config_and_merge;
          test_case "launch expansion" `Quick test_launch_expansion;
          test_case "fuzzy matching" `Quick test_fuzzy_matching;
          test_case "empty query ranking" `Quick
            test_rank_empty_query_orders_by_context_and_recency;
          test_case "text ranking signals" `Quick test_rank_text_signals;
          test_case "id prefix ranking" `Quick test_rank_id_prefix_kind;
          test_case "rank scores stay set-independent" `Quick
            test_rank_score_is_independent_of_result_set;
          test_case "scope and tool filters" `Quick test_filtering;
        ] );
    ]
