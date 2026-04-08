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

let string_contains text pattern =
  let text_length = String.length text in
  let pattern_length = String.length pattern in

  let rec loop index =
    if pattern_length = 0 then true
    else if index + pattern_length > text_length then false
    else
      let suffix = String.sub text index (text_length - index) in

      if String.starts_with ~prefix:pattern suffix then true
      else loop (index + 1)
  in

  loop 0

let check_contains label text pattern =
  check bool label true (string_contains text pattern)

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

let check_ranked_session_ids label expected ranked_sessions =
  ranked_sessions
  |> List.map (fun ranked -> ranked.session)
  |> check_session_ids label expected

let require_ranked label session_id ranked_sessions =
  ranked_sessions
  |> List.find_opt (fun ranked ->
      String.equal session_id (Session_id.to_string ranked.session.id))
  |> require_some label

let fixture_path name =
  let rec search_from directory remaining =
    if remaining < 0 then None
    else
      let candidate =
        Filename.concat directory (Filename.concat "fixtures" name)
      in
      let parent = Filename.dirname directory in

      if Sys.file_exists candidate then Some candidate
      else if String.equal parent directory then None
      else search_from parent (remaining - 1)
  in

  let explicit_candidates =
    [
      Sys.getenv_opt "DUNE_SOURCEROOT"
      |> Option.map (fun root ->
          Filename.concat root (Filename.concat "fixtures" name));
      Some (Filename.concat (Sys.getcwd ()) (Filename.concat "fixtures" name));
      Some
        (Filename.concat
           (Filename.dirname Sys.executable_name)
           (Filename.concat "fixtures" name));
    ]
    |> List.filter_map Fun.id
  in
  let fallback_roots =
    [ Sys.getcwd (); Filename.dirname Sys.executable_name ]
  in

  explicit_candidates |> List.find_opt Sys.file_exists |> function
  | Some path -> path
  | None -> (
      fallback_roots |> List.find_map (fun directory -> search_from directory 8)
      |> function
      | Some path -> path
      | None -> fail ("missing fixture: " ^ name))

let read_fixture name =
  In_channel.with_open_bin (fixture_path name) In_channel.input_all

let with_temp_file contents run =
  let path = Filename.temp_file "sessy-config-" ".toml" in

  Out_channel.with_open_bin path (fun channel -> output_string channel contents);

  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> run path)

let rec remove_path path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      path |> Sys.readdir
      |> Array.iter (fun entry -> entry |> Filename.concat path |> remove_path);
      Unix.rmdir path)
    else Sys.remove path

let with_temp_dir run =
  let path = Filename.temp_file "sessy-test-" "" in

  Sys.remove path;
  Unix.mkdir path 0o700;

  Fun.protect ~finally:(fun () -> remove_path path) (fun () -> run path)

let with_env_value name value run =
  let original = Sys.getenv_opt name in

  Unix.putenv name value;

  let restore () =
    match original with
    | Some original -> Unix.putenv name original
    | None -> Unix.putenv name ""
  in

  Fun.protect ~finally:restore run

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

let wait_for_pid_with_timeout pid timeout_seconds =
  let deadline = Unix.gettimeofday () +. timeout_seconds in

  let rec loop () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ when Unix.gettimeofday () < deadline ->
        let _ready, _write, _except = Unix.select [] [] [] 0.01 in
        loop ()
    | 0, _ ->
        Unix.kill pid Sys.sigkill;
        let _pid, status = Unix.waitpid [] pid in

        Error status
    | _, status -> Ok status
  in

  loop ()

let lookup_launch config tool =
  config.launches
  |> List.find_map (fun (candidate, launch) ->
      if Tool.equal candidate tool then Some launch else None)
  |> require_some "expected launch template"

let fixture_runtime_config () =
  {
    Sessy_core.default_config with
    sources =
      [
        {
          tool = Claude;
          history_path = fixture_path "claude_history.jsonl";
          projects_path = Some (fixture_path "claude_detail.jsonl");
          sessions_path = Some (fixture_path "claude_detail.jsonl");
        };
        {
          tool = Codex;
          history_path = fixture_path "codex_history.jsonl";
          projects_path = None;
          sessions_path = Some (fixture_path "codex_detail.jsonl");
        };
      ];
  }

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
    "minimal templates stay non-empty" ("codex", []) minimal_launch.argv;
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
    (match
       Sessy_core.expand_template session_without_project None invalid_template
     with
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
    ranked |> require_ranked "expected recency-only result" "recent-1"
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
  let target = make_session ~cwd:"/tmp/target" ~updated_at:2_000. "target-1" in
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
    [ target_ranked ] |> Sessy_core.sort_ranked
    |> require_ranked "expected target in single-result sort" "target-1"
  in
  let ranked_with_neighbor =
    [ target_ranked; neighbor_ranked ]
    |> Sessy_core.sort_ranked
    |> require_ranked "expected target in multi-result sort" "target-1"
  in

  check (float 0.000_001) "score is stable across result sets"
    ranked_alone.score ranked_with_neighbor.score

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

let test_claude_history_adapter () =
  let raw = read_fixture "claude_history.jsonl" in
  let sessions =
    match Sessy_adapter.Claude.parse_history raw with
    | Ok sessions -> sessions
    | Error _ -> fail "expected Claude history fixture to parse"
  in
  let first_session =
    match sessions with
    | first_session :: _ -> first_session
    | [] -> fail "expected Claude fixture sessions"
  in

  check int "missing session ids are skipped" 5 (List.length sessions);
  check string "first Claude id" "414afc11-2e5d-43c2-bdcb-02842e4686ec"
    (Session_id.to_string first_session.id);
  check bool "Claude tool tagged" true (Tool.equal Claude first_session.tool);
  check (option string) "Claude title"
    (Some "List recent sessy tasks and show the repo-local ones first.")
    first_session.title;
  check string "Claude cwd" "/Users/example/Repos/projects/sessy"
    first_session.cwd;
  check (float 0.000_001) "Claude timestamp normalized to seconds"
    1_775_634_717.07 first_session.updated_at

let test_claude_history_adapter_skips_malformed_lines () =
  let raw = read_fixture "claude_history.jsonl" ^ "\n{definitely-not-json}\n" in

  match Sessy_adapter.Claude.parse_history raw with
  | Ok sessions ->
      check int "malformed Claude line skipped" 5 (List.length sessions)
  | Error _ -> fail "malformed Claude lines should not poison valid entries"

let test_claude_detail_adapter () =
  let raw = read_fixture "claude_detail.jsonl" in
  let session =
    match Sessy_adapter.Claude.parse_detail raw with
    | Ok session -> session
    | Error _ -> fail "expected Claude detail sample to parse"
  in

  check string "Claude detail id" "81eb3289-6ac2-4ec3-bd85-fae85aae82ce"
    (Session_id.to_string session.id);
  check (option string) "Claude detail first prompt"
    (Some "Inspect the adapter format using the live Claude transcript shape.")
    session.first_prompt;
  check (option string) "Claude detail model" (Some "claude-opus-4-6")
    session.model;
  check string "Claude detail cwd" "/Users/example/Repos/projects/sessy"
    session.cwd;
  check (float 0.000_001) "Claude detail timestamp" 1_774_566_488.593
    session.updated_at

let test_codex_history_adapter () =
  let raw = read_fixture "codex_history.jsonl" in
  let sessions =
    match Sessy_adapter.Codex.parse_history raw with
    | Ok sessions -> sessions
    | Error _ -> fail "expected Codex history fixture to parse"
  in
  let first_session =
    match sessions with
    | first_session :: _ -> first_session
    | [] -> fail "expected Codex fixture sessions"
  in

  check int "Codex history lines preserved" 6 (List.length sessions);
  check string "first Codex id" "01999f1e-084e-77d3-9b2d-5a2692a779d5"
    (Session_id.to_string first_session.id);
  check bool "Codex tool tagged" true (Tool.equal Codex first_session.tool);
  check (option string) "Codex title"
    (Some
       "Generate an OCaml project scaffold for sessy with dune, opam, and \
        fixture directories.")
    first_session.title;
  check string "Codex cwd stays empty without hydration" "" first_session.cwd;
  check (float 0.000_001) "Codex timestamp stays in seconds" 1_759_311_173.
    first_session.updated_at

let test_codex_history_adapter_skips_malformed_lines () =
  let raw = read_fixture "codex_history.jsonl" ^ "\n{\"session_id\":42}\n" in

  match Sessy_adapter.Codex.parse_history raw with
  | Ok sessions ->
      check int "malformed Codex line skipped" 6 (List.length sessions)
  | Error _ -> fail "malformed Codex lines should not poison valid entries"

let test_codex_detail_adapter () =
  let raw = read_fixture "codex_detail.jsonl" in
  let session =
    match Sessy_adapter.Codex.parse_detail raw with
    | Ok session -> session
    | Error _ -> fail "expected Codex detail sample to parse"
  in

  check string "Codex detail id" "01999f1e-084e-77d3-9b2d-5a2692a779d5"
    (Session_id.to_string session.id);
  check (option string) "Codex detail first prompt"
    (Some "Generate an OCaml contributor guide for the repository.")
    session.first_prompt;
  check (option string) "Codex detail model" (Some "gpt-5-codex") session.model;
  check string "Codex detail cwd" "/Users/example/Repos/projects/sessy"
    session.cwd;
  check (float 0.000_001) "Codex detail timestamp" 1_759_311_173.164
    session.updated_at

let test_adapter_dispatch () =
  let module Claude_adapter =
    (val Sessy_adapter.adapter_for_tool Claude : Sessy_adapter.SOURCE)
  in
  let module Codex_adapter =
    (val Sessy_adapter.adapter_for_tool Codex : Sessy_adapter.SOURCE)
  in
  check bool "Claude dispatch" true (Tool.equal Claude Claude_adapter.tool);
  check bool "Codex dispatch" true (Tool.equal Codex Codex_adapter.tool);
  check int "all adapters exposed" 2 (List.length Sessy_adapter.all_adapters)

let test_index_build_search_and_refresh () =
  let original_sessions =
    [
      make_session ~cwd:"/repo" ~updated_at:100. "dup-1";
      make_session ~cwd:"/repo" ~updated_at:200. "dup-1";
      make_session ~cwd:"/repo/lib" ~updated_at:150. "repo-1";
      make_session ~cwd:"/elsewhere" ~updated_at:300. "other-1";
    ]
  in
  let index = Sessy_index.build original_sessions in
  let query = { text = ""; scope = Repo; tool_filter = None; mode = Meta } in
  let refreshed =
    Sessy_index.refresh index
      [ make_session ~cwd:"/repo/fresh" ~updated_at:400. "fresh-1" ]
  in
  let duplicate =
    Sessy_index.find_by_id index (require_session_id "dup-1")
    |> require_some "expected deduplicated session"
  in
  let ranked =
    Sessy_index.search index query ~now:500. ~cwd:"/repo"
      ~repo_root:(Some "/repo")
  in

  check int "deduplicated index count" 3 (Sessy_index.count index);
  check_session_ids "all sessions keep recency order"
    [ "other-1"; "dup-1"; "repo-1" ]
    (Sessy_index.all_sessions index);
  check (float 0.000_001) "most recent duplicate kept" 200. duplicate.updated_at;
  check_ranked_session_ids "search coordinates scope filter and ranking"
    [ "dup-1"; "repo-1" ] ranked;
  check int "refresh replaces contents" 1 (Sessy_index.count refreshed);
  check_session_ids "refresh keeps only new contents" [ "fresh-1" ]
    (Sessy_index.all_sessions refreshed)

let test_cli_parse_dispatch_and_format () =
  let cwd_session =
    make_session ~updated_at:60. ~title:"Fix ranking" ~cwd:"/repo/worktree"
      "abc12345zz"
  in
  let newer_other_session =
    make_session ~updated_at:90. ~title:"Other repo" ~cwd:"/other" "def67890yy"
  in
  let index = Sessy_index.build [ newer_other_session; cwd_session ] in
  let list_commands =
    Sessy_ui.dispatch (Sessy_ui.List_sessions Sessy_ui.Json) index
      Sessy_core.default_config ~cwd:"/repo/worktree"
  in
  let resume_commands =
    Sessy_ui.dispatch
      (Sessy_ui.Resume_id (cwd_session.id, Sessy_ui.Dry_run))
      index Sessy_core.default_config ~cwd:"/repo/worktree"
  in
  let last_commands =
    Sessy_ui.dispatch (Sessy_ui.Resume_last Sessy_ui.Dry_run) index
      Sessy_core.default_config ~cwd:"/repo/worktree"
  in
  let preview_commands =
    Sessy_ui.dispatch (Sessy_ui.Preview_session cwd_session.id) index
      Sessy_core.default_config ~cwd:"/repo/worktree"
  in
  let picker_commands =
    Sessy_ui.dispatch Sessy_ui.Open_picker index Sessy_core.default_config
      ~cwd:"/repo/worktree"
  in
  let plain = Sessy_ui.format_session_plain ~now:120. cwd_session in
  let json = Sessy_ui.format_session_json cwd_session in
  let preview =
    {
      Sessy_ui.session = cwd_session;
      launch =
        Ok
          {
            argv = ("claude", [ "--resume"; "abc12345zz" ]);
            cwd = "/repo/worktree";
            exec_mode = Spawn;
            display = "claude --resume abc12345zz";
          };
    }
  in
  let parsed_resume =
    Sessy_ui.parse_cli [ "resume"; "abc12345zz"; "--dry-run" ]
    |> require_ok "expected resume command to parse"
  in

  check bool "default cli action opens picker" true
    (match Sessy_ui.parse_cli [] with
    | Ok Sessy_ui.Open_picker -> true
    | Ok
        ( Sessy_ui.List_sessions _ | Sessy_ui.Resume_last _
        | Sessy_ui.Resume_id _ | Sessy_ui.Preview_session _ | Sessy_ui.Doctor )
    | Error _ ->
        false);
  check bool "list parses to plain output" true
    (match Sessy_ui.parse_cli [ "list" ] with
    | Ok (Sessy_ui.List_sessions Sessy_ui.Plain) -> true
    | Ok
        ( Sessy_ui.Open_picker
        | Sessy_ui.List_sessions Sessy_ui.Json
        | Sessy_ui.Resume_last _ | Sessy_ui.Resume_id _
        | Sessy_ui.Preview_session _ | Sessy_ui.Doctor )
    | Error _ ->
        false);
  check bool "list --json parses to json output" true
    (match Sessy_ui.parse_cli [ "list"; "--json" ] with
    | Ok (Sessy_ui.List_sessions Sessy_ui.Json) -> true
    | Ok
        ( Sessy_ui.Open_picker
        | Sessy_ui.List_sessions Sessy_ui.Plain
        | Sessy_ui.Resume_last _ | Sessy_ui.Resume_id _
        | Sessy_ui.Preview_session _ | Sessy_ui.Doctor )
    | Error _ ->
        false);
  check bool "last --dry-run parses" true
    (match Sessy_ui.parse_cli [ "last"; "--dry-run" ] with
    | Ok (Sessy_ui.Resume_last Sessy_ui.Dry_run) -> true
    | Ok _ | Error _ -> false);
  check bool "resume --dry-run parses" true
    (match parsed_resume with
    | Sessy_ui.Resume_id (session_id, Sessy_ui.Dry_run) ->
        String.equal "abc12345zz" (Session_id.to_string session_id)
    | Sessy_ui.Resume_id (_, Sessy_ui.Default) -> false
    | Sessy_ui.Open_picker | Sessy_ui.List_sessions _ | Sessy_ui.Resume_last _
    | Sessy_ui.Preview_session _ | Sessy_ui.Doctor ->
        false);
  check bool "preview parses" true
    (match Sessy_ui.parse_cli [ "preview"; "abc12345zz" ] with
    | Ok (Sessy_ui.Preview_session session_id) ->
        String.equal "abc12345zz" (Session_id.to_string session_id)
    | Ok _ | Error _ -> false);
  check bool "doctor parses" true
    (match Sessy_ui.parse_cli [ "doctor" ] with
    | Ok Sessy_ui.Doctor -> true
    | Ok _ | Error _ -> false);
  check bool "unsupported flag stays an error" true
    (match Sessy_ui.parse_cli [ "preview"; "abc12345zz"; "--dry-run" ] with
    | Error _ -> true
    | Ok _ -> false);
  check bool "unknown commands stay errors" true
    (match Sessy_ui.parse_cli [ "status" ] with
    | Error _ -> true
    | Ok _ -> false);
  check bool "list dispatch prints sessions" true
    (match list_commands with
    | [ Sessy_ui.Print_sessions (sessions, Sessy_ui.Json) ] ->
        session_ids sessions = [ "def67890yy"; "abc12345zz" ]
    | _ -> false);
  check bool "resume dispatch emits dry-run launch" true
    (match resume_commands with
    | [ Sessy_ui.Resolve_resume (session_id, Sessy_ui.Dry_run) ] ->
        String.equal "abc12345zz" (Session_id.to_string session_id)
    | _ -> false);
  check bool "last prefers cwd sessions over newer global ones" true
    (match last_commands with
    | [ Sessy_ui.Resolve_last Sessy_ui.Dry_run ] -> true
    | _ -> false);
  check bool "preview dispatch includes session and launch" true
    (match preview_commands with
    | [ Sessy_ui.Resolve_preview session_id ] ->
        String.equal "abc12345zz" (Session_id.to_string session_id)
    | _ -> false);
  check bool "doctor dispatch requests a report" true
    (match
       Sessy_ui.dispatch Sessy_ui.Doctor index Sessy_core.default_config
         ~cwd:"/repo/worktree"
     with
    | [ Sessy_ui.Run_doctor ] -> true
    | _ -> false);
  check bool "open picker stays a non-error placeholder" true
    (match picker_commands with
    | [ Sessy_ui.Print_notice message ] ->
        String.equal "interactive mode requires the shell runtime" message
    | _ -> false);
  check string "preview formatting shows launch preview"
    "id: abc12345zz\n\
     tool: claude\n\
     cwd: /repo/worktree\n\
     project: -\n\
     model: -\n\
     title: Fix ranking\n\
     first prompt: -\n\
     last activity: 1m ago\n\
     launch: claude --resume abc12345zz"
    (Sessy_ui.format_preview ~now:120. preview);
  check string "plain formatting includes short id and age"
    "[claude] abc12345 Fix ranking /repo/worktree 1m ago" plain;
  check string "json formatting includes id" "abc12345zz"
    (match json with
    | `Assoc fields -> (
        match List.assoc_opt "id" fields with
        | Some (`String value) -> value
        | Some _ | None -> fail "expected id field")
    | _ -> fail "expected session json object")

let make_tui_model () =
  let config = { Sessy_core.default_config with default_scope = All } in
  let current =
    make_session ~updated_at:60. ~title:"Fix ranking" ~cwd:"/repo/worktree"
      "abc12345zz"
  in
  let other =
    make_session ~tool:Codex ~updated_at:90. ~title:"Other repo" ~cwd:"/other"
      "def67890yy"
  in
  let index = Sessy_index.build [ other; current ] in
  let model =
    Sessy_ui.init index config ~cwd:"/repo/worktree" ~repo_root:(Some "/repo")
      ~now:120.
      ~terminal:{ Sessy_ui.width = 120; height = 18 }
      ~notice:None
  in

  (model, current, other)

let make_tui_preview session =
  let hydrated_session =
    {
      session with
      cwd = "/hydrated/worktree";
      first_prompt = Some "Hydrated preview prompt";
    }
  in

  {
    Sessy_ui.session = hydrated_session;
    launch =
      Ok
        {
          argv = ("claude", [ "--resume"; "abc12345zz" ]);
          cwd = hydrated_session.cwd;
          exec_mode = Spawn;
          display = "claude --resume abc12345zz";
        };
  }

let test_tui_update_behaviour () =
  let model, current, other = make_tui_model () in
  let preview = current |> make_tui_preview in
  let model_with_preview, preview_load_cmd =
    Sessy_ui.update model (Sessy_ui.Preview_loaded (Some preview))
  in
  let filtered_model, filtered_cmd =
    Sessy_ui.update model (Sessy_ui.Query_changed "Other")
  in
  let moved_model, moved_cmd =
    Sessy_ui.update model (Sessy_ui.Cursor_moved 1)
  in
  let preview_cleared_model, _ =
    Sessy_ui.update model_with_preview (Sessy_ui.Cursor_moved 1)
  in
  let preview_model, preview_cmd =
    Sessy_ui.update model Sessy_ui.Preview_toggled
  in
  let copy_model, copy_cmd =
    Sessy_ui.update moved_model Sessy_ui.Copy_requested
  in
  let open_model, open_cmd =
    Sessy_ui.update moved_model Sessy_ui.Open_directory_requested
  in
  let reload_model, reload_cmd =
    Sessy_ui.update model Sessy_ui.Reload_requested
  in
  let launch_model, launch_cmd =
    Sessy_ui.update model Sessy_ui.Session_selected
  in
  let quit_model, quit_cmd = Sessy_ui.update model Sessy_ui.Quit in

  check int "init searches across both sessions" 2 (List.length model.results);
  check bool "query keeps the matching session visible" true
    (filtered_model.results
    |> List.exists (fun ranked ->
        String.equal "def67890yy" (Session_id.to_string ranked.session.id)));
  check bool "query change stays pure" true
    (match filtered_cmd with Sessy_ui.Noop -> true | _ -> false);
  check bool "preview load stays pure" true
    (match preview_load_cmd with Sessy_ui.Noop -> true | _ -> false);
  check string "preview load caches hydrated cwd" "/hydrated/worktree"
    ( model_with_preview.preview |> require_some "expected loaded preview"
    |> fun preview -> preview.session.cwd );
  check int "cursor move selects second session" 1 moved_model.cursor;
  check bool "cursor move stays pure" true
    (match moved_cmd with Sessy_ui.Noop -> true | _ -> false);
  check bool "cursor move clears cached preview" true
    (Option.is_none preview_cleared_model.preview);
  check bool "preview toggles off" false preview_model.preview_visible;
  check bool "preview toggle stays pure" true
    (match preview_cmd with Sessy_ui.Noop -> true | _ -> false);
  check bool "copy request clears notices" true
    (Option.is_none copy_model.notice);
  check bool "copy request emits selected id" true
    (match copy_cmd with
    | Sessy_ui.Copy_to_clipboard session_id ->
        String.equal session_id (Session_id.to_string other.id)
    | _ -> false);
  check bool "open request clears notices" true
    (Option.is_none open_model.notice);
  check bool "open request resolves selected session in shell" true
    (match open_cmd with
    | Sessy_ui.Resolve_open_directory session_id ->
        Session_id.equal session_id other.id
    | _ -> false);
  check string "reload request sets status text" "reloading sessions..."
    (reload_model.notice |> require_some "expected reload notice");
  check bool "reload request emits command" true
    (match reload_cmd with Sessy_ui.Reload_index -> true | _ -> false);
  check bool "session selection resolves in shell" true
    (match launch_cmd with
    | Sessy_ui.Resolve_resume (session_id, Sessy_ui.Default) ->
        Session_id.equal session_id current.id
    | _ -> false);
  check bool "launch clears notice" true (Option.is_none launch_model.notice);
  check bool "quit exits" true
    (match quit_cmd with Sessy_ui.Exit -> true | _ -> false);
  check bool "quit clears notice" true (Option.is_none quit_model.notice)

let test_tui_view_rendering () =
  let model, _, _ = make_tui_model () in
  let preview_model, _ =
    Sessy_ui.update model
      (Sessy_ui.Preview_loaded
         (Some
            {
              Sessy_ui.session =
                make_session ~updated_at:60. ~title:"Fix ranking"
                  ~first_prompt:"Hydrated preview prompt"
                  ~cwd:"/hydrated/worktree" "abc12345zz";
              launch =
                Ok
                  {
                    argv = ("claude", [ "--resume"; "abc12345zz" ]);
                    cwd = "/hydrated/worktree";
                    exec_mode = Spawn;
                    display = "claude --resume abc12345zz";
                  };
            }))
  in
  let wide = Sessy_ui.view preview_model in
  let narrow_model, _ =
    Sessy_ui.update preview_model
      (Sessy_ui.Window_resized { Sessy_ui.width = 80; height = 18 })
  in
  let narrow = Sessy_ui.view narrow_model in
  let help_model, _ = Sessy_ui.update preview_model Sessy_ui.Help_toggled in
  let help_view = Sessy_ui.view help_model in

  check_contains "wide view shows preview title" wide "Preview";
  check_contains "wide view shows launch preview" wide
    "launch: claude --resume abc12345zz";
  check_contains "wide view uses hydrated preview cwd" wide "/hydrated/worktree";
  check_contains "wide view shows query placeholder" wide "<type to filter>";
  check bool "narrow view hides preview pane" false
    (contains_substring ~needle:"launch: claude --resume abc12345zz" narrow);
  check_contains "help toggle shows shortcuts overlay" help_view "Shortcuts:"

let test_shell_fs_and_config_loader () =
  let raw =
    fixture_path "claude_history.jsonl"
    |> Sessy_shell.read_file
    |> require_ok "expected fixture file to be readable"
  in
  let home = Sys.getenv "HOME" in
  let config, warnings =
    Sessy_shell.load_config_from_paths [ fixture_path "config.toml" ]
  in
  let unsafe_profile =
    config.profiles
    |> List.find_opt (fun profile ->
        Tool.equal profile.base_tool Claude
        && String.equal profile.name "unsafe")
    |> require_some "expected unsafe Claude profile"
  in

  check bool "fixture file is non-empty" true (String.length raw > 0);
  check string "home expansion preserves suffix" (home ^ "/.claude")
    (Sessy_shell.expand_home "~/.claude");
  check int "valid fixture config has no warnings" 0 (List.length warnings);
  check bool "fixture config keeps preview enabled" true config.preview;
  check int "fixture config loads two sources" 2 (List.length config.sources);
  check int "fixture config loads two profiles" 2 (List.length config.profiles);
  check (list string) "Claude unsafe profile args"
    [ "--dangerously-skip-permissions" ]
    unsafe_profile.argv_append

let test_shell_fs_preserves_tilde_without_home () =
  with_env_value "HOME" "" (fun () ->
      check string "tilde path stays unchanged without HOME"
        "~/.claude/history.jsonl"
        (Sessy_shell.expand_home "~/.claude/history.jsonl"))

let test_shell_config_loader_invalid_types_fall_back () =
  let raw =
    {|
[ui]
preview = "yes"

[sources.claude]
history = false

[launch.claude]
argv = "claude --resume {{id}}"

[profiles.claude.unsafe]
argv_append = "skip"
|}
  in

  with_temp_file raw (fun path ->
      let config, warnings = Sessy_shell.load_config_from_paths [ path ] in
      let claude_source =
        config.sources
        |> List.find_opt (fun source -> Tool.equal source.tool Claude)
        |> require_some "expected Claude source"
      in
      let claude_launch = lookup_launch config Claude in
      let unsafe_profile =
        config.profiles
        |> List.find_opt (fun profile ->
            Tool.equal profile.base_tool Claude
            && String.equal profile.name "unsafe")
        |> require_some "expected unsafe Claude profile"
      in

      check bool "preview falls back to default" true config.preview;
      check string "history path falls back to default"
        "~/.claude/history.jsonl" claude_source.history_path;
      check
        (pair string (list string))
        "launch argv falls back to default"
        ("claude", [ "--resume"; "{{id}}" ])
        claude_launch.argv_template;
      check (list string) "profile args fall back to empty list" []
        unsafe_profile.argv_append;
      check bool "invalid preview warning recorded" true
        (warnings |> List.exists (contains_substring ~needle:"ui.preview"));
      check bool "invalid launch argv warning recorded" true
        (warnings
        |> List.exists (contains_substring ~needle:"launch.claude.argv")))

let test_shell_profile_override_preserves_prior_values_on_invalid_input () =
  let base_config =
    {|
[profiles.claude.unsafe]
argv_append = ["--dangerously-skip-permissions"]
|}
  in
  let invalid_override = {|
[profiles.claude.unsafe]
argv_append = "skip"
|} in

  with_temp_file base_config (fun base_path ->
      with_temp_file invalid_override (fun override_path ->
          let config, warnings =
            Sessy_shell.load_config_from_paths [ base_path; override_path ]
          in
          let unsafe_profile =
            config.profiles
            |> List.find_opt (fun profile ->
                Tool.equal profile.base_tool Claude
                && String.equal profile.name "unsafe")
            |> require_some "expected unsafe Claude profile"
          in

          check (list string) "invalid override preserves base argv append"
            [ "--dangerously-skip-permissions" ]
            unsafe_profile.argv_append;
          check bool "invalid profile override warning recorded" true
            (warnings
            |> List.exists
                 (contains_substring
                    ~needle:"profiles.claude.unsafe.argv_append"))))

let test_shell_profile_override_stays_scoped_to_section_tool () =
  let base_config =
    {|
[profiles.codex.fast]
argv_append = ["--profile", "fast"]
|}
  in
  let invalid_override = {|
[profiles.claude.fast]
argv_append = "skip"
|} in

  with_temp_file base_config (fun base_path ->
      with_temp_file invalid_override (fun override_path ->
          let config, warnings =
            Sessy_shell.load_config_from_paths [ base_path; override_path ]
          in
          let codex_fast =
            config.profiles
            |> List.find_opt (fun profile ->
                Tool.equal profile.base_tool Codex
                && String.equal profile.name "fast")
            |> require_some "expected codex fast profile"
          in
          let claude_fast =
            config.profiles
            |> List.find_opt (fun profile ->
                Tool.equal profile.base_tool Claude
                && String.equal profile.name "fast")
            |> require_some "expected claude fast profile"
          in

          check (list string) "codex profile stays untouched"
            [ "--profile"; "fast" ] codex_fast.argv_append;
          check (list string) "claude profile falls back to empty args" []
            claude_fast.argv_append;
          check bool "section-scoped warning recorded" true
            (warnings
            |> List.exists
                 (contains_substring ~needle:"profiles.claude.fast.argv_append")
            )))

let test_shell_load_sessions_is_tolerant () =
  let config =
    {
      (fixture_runtime_config ()) with
      sources =
        [
          {
            tool = Claude;
            history_path = fixture_path "config.toml";
            projects_path = None;
            sessions_path = None;
          };
          {
            tool = Codex;
            history_path = fixture_path "codex_history.jsonl";
            projects_path = None;
            sessions_path = None;
          };
        ];
    }
  in
  let sessions, warnings = Sessy_shell.load_sessions config in

  check bool "one bad source emits a warning" true (List.length warnings > 0);
  check bool "the good source still contributes sessions" true
    (sessions
    |> List.exists (fun (session : session) -> Tool.equal session.tool Codex))

let test_shell_resolve_launch_hydrates_codex_detail () =
  let config = fixture_runtime_config () in
  let sessions, warnings = Sessy_shell.load_sessions config in
  let index = Sessy_index.build sessions in
  let session_id = require_session_id "01999f1e-084e-77d3-9b2d-5a2692a779d5" in
  let command =
    Sessy_shell.resolve_launch_cmd ~config ~index
      ~request:(Sessy_shell.Session_request session_id) ~active_profile:None
      ~launch_mode:Sessy_ui.Dry_run ~cwd:"/tmp/fallback"
      ~repo_root:(Some "/Users/example/Repos/projects/sessy")
      ~now:1_900_000_000.
    |> require_ok "expected Codex launch to resolve"
  in

  check int "fixture load still has no warnings" 0 (List.length warnings);
  check
    (pair string (list string))
    "Codex launch argv keeps the native resume contract"
    ("codex", [ "resume"; "01999f1e-084e-77d3-9b2d-5a2692a779d5" ])
    command.argv;
  check string "Codex launch uses hydrated detail cwd"
    "/Users/example/Repos/projects/sessy" command.cwd;
  check bool "dry-run forces print mode" true
    (match command.exec_mode with Print -> true | Spawn | Exec -> false)

let test_shell_resolve_launch_uses_single_profile_for_cli () =
  let session = make_session ~tool:Codex ~cwd:"/tmp/project" "profile-cli-1" in
  let config =
    {
      Sessy_core.default_config with
      sources = [];
      launches =
        [
          ( Codex,
            {
              argv_template = ("codex", [ "resume"; "{{profile}}"; "{{id}}" ]);
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
            exec_mode_override = None;
          };
        ];
    }
  in
  let index = Sessy_index.build [ session ] in
  let command =
    Sessy_shell.resolve_launch_cmd ~config ~index
      ~request:(Sessy_shell.Session_request session.id) ~active_profile:None
      ~launch_mode:Sessy_ui.Dry_run ~cwd:"/tmp/fallback" ~repo_root:None
      ~now:1_900_000_000.
    |> require_ok "expected CLI launch to resolve a single configured profile"
  in

  check
    (pair string (list string))
    "CLI launch expands profile placeholder and additive args"
    ("codex", [ "resume"; "fast"; "profile-cli-1"; "--profile"; "fast" ])
    command.argv

let test_shell_resolve_preview_hydrates_detail () =
  let config = fixture_runtime_config () in
  let sessions, _warnings = Sessy_shell.load_sessions config in
  let index = Sessy_index.build sessions in
  let session_id = require_session_id "01999f1e-084e-77d3-9b2d-5a2692a779d5" in
  let preview =
    Sessy_shell.resolve_preview ~config ~index ~session_id ~cwd:"/tmp/fallback"
      ~active_profile:None
    |> require_ok "expected preview to resolve"
  in

  check string "preview hydrates cwd from Codex detail"
    "/Users/example/Repos/projects/sessy" preview.session.cwd;
  check string "preview hydrates model from Codex detail" "gpt-5-codex"
    (preview.session.model |> require_some "expected model");
  check string "preview hydrates first prompt from Codex detail"
    "Generate an OCaml contributor guide for the repository."
    (preview.session.first_prompt |> require_some "expected first prompt");
  check bool "preview launch remains available after hydration" true
    (match preview.launch with
    | Ok command ->
        String.equal "codex resume 01999f1e-084e-77d3-9b2d-5a2692a779d5"
          command.display
    | Error _ -> false)

let test_shell_resolve_last_prefers_repo_ranking () =
  let config = Sessy_core.default_config in
  let repo_session = make_session ~cwd:"/repo/lib" ~updated_at:100. "repo-1" in
  let global_session =
    make_session ~cwd:"/outside" ~updated_at:500. "other-1"
  in
  let index = Sessy_index.build [ global_session; repo_session ] in
  let command =
    Sessy_shell.resolve_launch_cmd ~config ~index
      ~request:Sessy_shell.Last_request ~active_profile:None
      ~launch_mode:Sessy_ui.Dry_run ~cwd:"/repo/app" ~repo_root:(Some "/repo")
      ~now:1_000.
    |> require_ok "expected last command to resolve"
  in

  check
    (pair string (list string))
    "last uses repo-aware ranking instead of newest global session"
    ("claude", [ "--resume"; "repo-1" ])
    command.argv

let test_shell_copy_to_clipboard_delivers_eof () =
  let original_path = Sys.getenv_opt "PATH" |> Option.value ~default:"" in

  with_temp_dir (fun directory ->
      let script_path = Filename.concat directory "pbcopy" in
      let output_path = Filename.concat directory "clipboard.txt" in
      let path_value = String.concat ":" [ directory; original_path ] in

      Out_channel.with_open_bin script_path (fun channel ->
          output_string channel "#!/bin/sh\ncat > \"$SESSY_CLIPBOARD_OUT\"\n");
      Unix.chmod script_path 0o755;

      with_env_value "PATH" path_value (fun () ->
          with_env_value "SESSY_CLIPBOARD_OUT" output_path (fun () ->
              match Unix.fork () with
              | 0 ->
                  let exit_code =
                    match Sessy_shell.copy_to_clipboard "session-123\n" with
                    | Ok _ -> 0
                    | Error _ -> 1
                  in

                  Stdlib.exit exit_code
              | pid -> (
                  match wait_for_pid_with_timeout pid 1.0 with
                  | Ok (Unix.WEXITED 0) ->
                      check string "clipboard helper receives complete stdin"
                        "session-123\n"
                        (In_channel.with_open_bin output_path
                           In_channel.input_all)
                  | Ok status ->
                      fail
                        (Printf.sprintf
                           "clipboard helper exited unexpectedly: %s"
                           (match status with
                           | Unix.WEXITED code -> Printf.sprintf "exit %d" code
                           | Unix.WSIGNALED signal ->
                               Printf.sprintf "signal %d" signal
                           | Unix.WSTOPPED signal ->
                               Printf.sprintf "stopped %d" signal))
                  | Error _ -> fail "clipboard helper timed out waiting for EOF"
                  ))))

let test_doctor_report () =
  let config = fixture_runtime_config () in
  let report =
    Sessy_shell.doctor_report
      ~config_paths:
        [ fixture_path "config.toml"; "/tmp/sessy-missing-config.toml" ]
      ~config ~config_warnings:[ "fixture warning" ]
  in

  check_contains "doctor includes existing config path" report "[ok] config: ";
  check_contains "doctor includes missing config path" report
    "[warn] config: not found: /tmp/sessy-missing-config.toml";
  check_contains "doctor includes config warnings" report
    "[warn] config warning: fixture warning";
  check_contains "doctor parses Claude fixtures" report
    "[ok] source claude parse: 5 sessions";
  check_contains "doctor parses Codex fixtures" report
    "[ok] source codex parse: 6 sessions";
  check_contains "doctor includes tool checks" report "tool claude:";
  check_contains "doctor includes both tool checks" report "tool codex:"

let test_shell_run_once_open_picker_requires_tty () =
  let exit_status =
    Sessy_shell.run_once ~argv:[] ~config_paths:[] ~cwd:"/tmp" ~now:0.
  in

  check int "bare sessy reports missing tty in tests" 1 exit_status

let test_shell_exec_replace_reports_errors () =
  let command =
    {
      argv = ("sessy-command-that-does-not-exist", []);
      cwd = "/tmp";
      exec_mode = Exec;
      display = "sessy-command-that-does-not-exist";
    }
  in

  check bool "exec_replace returns structured exec error" true
    (match Sessy_shell.exec_replace command with
    | Error (`Exec_error _) -> true
    | Ok () -> false)

let test_e2e_fixture_pipeline () =
  let config = fixture_runtime_config () in
  let sessions, warnings = Sessy_shell.load_sessions config in
  let index = Sessy_index.build sessions in
  let query = { text = ""; scope = All; tool_filter = None; mode = Meta } in
  let ranked =
    Sessy_index.search index query ~now:1_900_000_000.
      ~cwd:"/Users/example/Repos/projects/sessy"
      ~repo_root:(Some "/Users/example/Repos/projects/sessy")
  in
  let selected = ranked |> List.hd |> fun ranked -> ranked.session in
  let launch =
    Sessy_core.expand_template selected None
      (lookup_launch config selected.tool)
    |> require_ok "expected launch expansion from fixture result"
  in
  let json_output =
    match Sessy_ui.parse_cli [ "list"; "--json" ] with
    | Error message -> fail message
    | Ok action -> (
        match
          Sessy_ui.dispatch action index config
            ~cwd:"/Users/example/Repos/projects/sessy"
        with
        | [ Sessy_ui.Print_sessions (sessions, output_format) ] ->
            Sessy_ui.format_sessions ~now:1_900_000_000. output_format sessions
        | _ -> fail "expected a printable session list")
  in

  check int "fixture load yields no warnings" 0 (List.length warnings);
  check int "fixture pipeline deduplicates to nine sessions" 9
    (Sessy_index.count index);
  check_ranked_session_ids "repo-local sessions rank first in e2e search"
    [
      "2f10b8a3-c44c-4cc2-b2f9-48d2541e8b1a";
      "d7bdb0a1-4d0c-46cb-9e8d-6af40aa8fd9f";
      "414afc11-2e5d-43c2-bdcb-02842e4686ec";
    ]
    (ranked |> List.filteri (fun index _ -> index < 3));
  check
    (pair string (list string))
    "launch template expands for selected fixture session"
    ("claude", [ "--resume"; "2f10b8a3-c44c-4cc2-b2f9-48d2541e8b1a" ])
    launch.argv;
  check int "json output contains every indexed session" 9
    (match Yojson.Safe.from_string json_output with
    | `List values -> List.length values
    | _ -> fail "expected json array output")

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
      ( "adapter",
        [
          test_case "Claude history fixture parsing" `Quick
            test_claude_history_adapter;
          test_case "Claude history malformed line resilience" `Quick
            test_claude_history_adapter_skips_malformed_lines;
          test_case "Claude detail parsing" `Quick test_claude_detail_adapter;
          test_case "Codex history fixture parsing" `Quick
            test_codex_history_adapter;
          test_case "Codex history malformed line resilience" `Quick
            test_codex_history_adapter_skips_malformed_lines;
          test_case "Codex detail parsing" `Quick test_codex_detail_adapter;
          test_case "adapter dispatch" `Quick test_adapter_dispatch;
        ] );
      ( "index",
        [
          test_case "build search and refresh" `Quick
            test_index_build_search_and_refresh;
        ] );
      ( "ui",
        [
          test_case "cli parse dispatch and format" `Quick
            test_cli_parse_dispatch_and_format;
          test_case "tui update behaviour" `Quick test_tui_update_behaviour;
          test_case "tui view rendering" `Quick test_tui_view_rendering;
        ] );
      ( "shell",
        [
          test_case "filesystem and config loader" `Quick
            test_shell_fs_and_config_loader;
          test_case "expand_home keeps tilde without HOME" `Quick
            test_shell_fs_preserves_tilde_without_home;
          test_case "invalid config types fall back with warnings" `Quick
            test_shell_config_loader_invalid_types_fall_back;
          test_case "invalid profile override keeps prior values" `Quick
            test_shell_profile_override_preserves_prior_values_on_invalid_input;
          test_case "profile fallback stays section-scoped" `Quick
            test_shell_profile_override_stays_scoped_to_section_tool;
          test_case "source loading stays tolerant" `Quick
            test_shell_load_sessions_is_tolerant;
          test_case "resolve launch hydrates Codex detail" `Quick
            test_shell_resolve_launch_hydrates_codex_detail;
          test_case "CLI launch uses a single configured profile" `Quick
            test_shell_resolve_launch_uses_single_profile_for_cli;
          test_case "resolve preview hydrates detail" `Quick
            test_shell_resolve_preview_hydrates_detail;
          test_case "resolve last prefers repo ranking" `Quick
            test_shell_resolve_last_prefers_repo_ranking;
          test_case "clipboard helper closes stdin on exec" `Quick
            test_shell_copy_to_clipboard_delivers_eof;
          test_case "doctor report" `Quick test_doctor_report;
          test_case "bare sessy requires tty in tests" `Quick
            test_shell_run_once_open_picker_requires_tty;
          test_case "exec_replace reports errors" `Quick
            test_shell_exec_replace_reports_errors;
        ] );
      ("e2e", [ test_case "fixture pipeline" `Quick test_e2e_fixture_pipeline ]);
    ]
