# sessy — Implementation Plan

Decision: OCaml 5 + minttea (dec-20260408-001).
Architecture: `.context/architecture.md`.
PRD: `.context/prd.md`.

## How to use this plan

Each task is atomic. Do one task, verify acceptance, commit, move on.
Tasks are ordered bottom-up: domain types → core logic → adapters → index → CLI → TUI → distribution.
The first E2E vertical slice lands at **T5.8** (`sessy list --json` works end-to-end).

Every task lists:
- **Do:** what to implement
- **Invariants:** architectural rules that MUST NOT be violated during this task
- **Accept:** how to verify the task is done (спецификация приёмки)
- **Depends:** which prior tasks must be complete

---

## Phase 0: Foundation

### T0.1 — Create dune-project and opam manifest

**Do:** Create `dune-project` with OCaml ≥5.2, package definition, and dependency list. Create `.ocamlformat` with `profile = default`. Create `.gitignore` for `_build/`, `*.install`.

**Invariants:**
- No code yet. Only build system scaffolding.
- Use exact dependency specs from architecture.md § Dune build files.

**Accept:** `dune build` runs without errors (on an empty project). `opam install . --deps-only` installs all dependencies.

**Depends:** nothing

---

### T0.2 — Create directory structure and stub libraries

**Do:** Create all directories from architecture.md § Project structure. In each `lib/<layer>/`, create its `dune` file and an empty `.ml` file so dune recognizes the library. Create `bin/dune` and `bin/main.ml` with a trivial `let () = ()`. Create `test/dune`.

**Invariants:**
- Dependency graph must match architecture.md exactly:
  - `sessy_domain` depends on nothing
  - `sessy_core` depends on `sessy_domain` only
  - `sessy_adapter` depends on `sessy_domain`, `sessy_core`, `yojson`
  - `sessy_index` depends on `sessy_domain`, `sessy_core`
  - `sessy_ui` depends on `sessy_domain`, `sessy_core`, `sessy_index`
  - `sessy_shell` depends on all libraries + external deps
- No skip-level dependencies. If you're tempted to add one, the architecture is wrong.

**Accept:** `dune build` compiles. `dune exec sessy` runs and exits cleanly.

**Depends:** T0.1

---

### T0.3 — Verify toolchain and dependencies

**Do:** Ensure OCaml 5.4+, dune 3.16+, and all opam dependencies install correctly. Run `ocaml --version`, `dune --version`. Run `opam install yojson ppx_yojson_conv otoml eio_main minttea alcotest`. Document actual installed versions.

**Invariants:**
- OCaml version ≥ 5.2 (for effect handlers / Eio compatibility)
- All deps from architecture.md must resolve

**Accept:** `dune build` succeeds. `opam list --installed` shows all required packages.

**Depends:** T0.1

---

### T0.4 — Create test fixtures

**Do:** Inspect actual Claude Code and Codex history files on the local machine. Create realistic test fixtures in `fixtures/`:
- `fixtures/claude_history.jsonl` — 5–10 sample entries based on real format
- `fixtures/codex_history.jsonl` — 5–10 sample entries based on real format
- `fixtures/config.toml` — sample config matching architecture.md format

**Invariants:**
- Fixtures must reflect ACTUAL file formats (inspect `~/.claude/history.jsonl` and `~/.codex/history.jsonl`). Do not guess formats — read real files.
- No real session content / sensitive data in fixtures. Sanitize IDs and paths.
- If Codex is not installed, note it and create best-effort fixture from codedash source code docs.

**Accept:** Fixture files exist and contain valid JSON/JSONL/TOML. Can be parsed by `jq` (JSONL) and a TOML validator.

**Depends:** T0.2

---

## Phase 1: Domain Kernel (Layer 0)

### T1.1 — Define tool type and Session_id module

**Do:** In `lib/domain/sessy_domain.ml`, define:
- `type tool = Claude | Codex` with compare, equal, to_string
- `module Session_id` with opaque type `t`, `of_string` (rejects empty), `to_string`, `short` (first 8 chars), `equal`, `compare`

**Invariants:**
- LAYER 0 IS TYPES ONLY. No business logic, no IO, no parsing.
- `Session_id.t` is opaque — outside code cannot construct it without `of_string`.
- `tool` is a closed sum type — no `| Other of string` escape hatch.

**Accept:** `dune build` compiles. In utop/test: `Session_id.of_string "" = None`, `Session_id.of_string "abc" = Some _`, `Session_id.short (... "abcdefghij") = "abcdefgh"`.

**Depends:** T0.2

---

### T1.2 — Define session and search types

**Do:** In `sessy_domain.ml`, add:
- `type session` record (id, tool, title, first_prompt, cwd, project_key, model, updated_at, is_active)
- `type scope = Cwd | Repo | All`
- `type search_mode = Meta | Deep`
- `type query` record (text, scope, tool_filter, mode)
- `type match_kind = Exact_cwd | Same_repo | Active | Id_prefix | Substring | Fuzzy | Recency`
- `type ranked` record (session, score, match_kind)

**Invariants:**
- All fields use domain types, never raw strings for typed concepts.
- `title`, `first_prompt`, `project_key`, `model` are `string option` — absence is explicit.
- `updated_at` is `float` (Unix timestamp) — not a string, not an int.

**Accept:** Types compile. Can construct a session value in a test.

**Depends:** T1.1

---

### T1.3 — Define launch and config types

**Do:** In `sessy_domain.ml`, add:
- `type exec_mode = Spawn | Exec | Print`
- `type launch_cmd` (argv as `string * string list`, cwd, exec_mode, display)
- `type launch_template` (`argv_template` as `string * string list`, cwd_policy, default_exec_mode)
- `type profile` (name, base_tool, argv_append, exec_mode_override)
- `type source_config` (tool, history_path, projects_path, sessions_path)
- `type config` (default_scope, preview, sources, launches, profiles)

**Invariants:**
- `launch_cmd.argv` is `string * string list` — tuple guarantees non-empty by construction. No runtime check needed.
- `launch_template.argv_template` is also `string * string list` so the program slot stays non-empty before expansion.
- `cwd_policy` is a polymorphic variant `` [`Session | `Current] `` — not a string.
- Config types do NOT know how to parse TOML. They are the target, not the parser.

**Accept:** Types compile. Can construct a `launch_cmd` and a `config` in a test.

**Depends:** T1.2

---

### T1.4 — Define error types and write .mli

**Do:** Add error types:
- `type parse_error = Invalid_json of string | Missing_field of string | Invalid_format of string`
- `type config_error = File_not_found of string | Parse_failed of string | Invalid_value of string * string`

Write `sessy_domain.mli` that exports all types and the `Session_id` module signature. This is the public API of Layer 0.

**Invariants:**
- Error types are sum types, not exceptions. NEVER use `raise` in Layers 0–4.
- The `.mli` is the abstraction barrier. Everything not in `.mli` is private.
- `Session_id.t` representation must be HIDDEN in the `.mli`.

**Accept:** `dune build` compiles with `.mli` in place. Other libraries can `open Sessy_domain` and use types but cannot construct `Session_id.t` without `of_string`.

**Depends:** T1.3

---

## Phase 2: Core Logic (Layer 1)

### T2.1 — Implement config merging

**Do:** Create `lib/core/config_merge.ml`:
- `val default_config : config` — built-in defaults matching PRD §10.4
- `val merge_config : config -> config -> config` — second overrides first, field by field
- `val resolve_config : config list -> config` — `List.fold_left merge_config default_config`

**Invariants:**
- Pure functions only. No IO, no file reads. Config merging operates on domain types.
- Layer 1 depends ONLY on Layer 0 (`sessy_domain`). No yojson, no otoml here.
- Merge semantics: for scalar fields, later wins. For list fields (sources, profiles), later replaces (not appends).

**Accept:** Unit test: `resolve_config [default; user_override]` produces expected merged config. Test that empty override doesn't change defaults.

**Depends:** T1.4

---

### T2.2 — Implement template expansion and launch assembly

**Do:** Create `lib/core/launch.ml`:
- `val substitute_placeholder : session -> string -> string` — replace `{{id}}`, `{{tool}}`, `{{cwd}}`, `{{project}}`, `{{title}}` in a single argv element
- `val expand_template : session -> profile option -> launch_template -> (launch_cmd, config_error) result` — full pipeline: substitute all placeholders, append profile args, validate the expanded program, and build `launch_cmd`

**Invariants:**
- Pure function: session × profile × template → result. No IO.
- Argv is assembled as a list, NEVER as a shell string (PRD §10.5).
- Unknown placeholders are left as-is (don't error on `{{custom}}`).
- Profile's `argv_append` is appended AFTER template expansion.
- `{{profile}}` is a known placeholder. If the template references it without an active profile, return `Error (Invalid_value ...)` instead of passing a literal placeholder through.
- `display` field is generated from the argv-derived command preview for dry-run output.

**Accept:** Unit test: given a session with id "abc123", tool Claude, template `("claude", ["--resume"; "{{id}}"])`, profile with `argv_append = ["--dangerously-skip-permissions"]` → produces `Ok launch_cmd` with `argv = ("claude", ["--resume"; "abc123"; "--dangerously-skip-permissions"])`. Unit test: a template containing `{{profile}}` with no active profile returns `Error (Invalid_value ...)`.

**Depends:** T1.4

---

### T2.3 — Implement fuzzy matching

**Do:** Create `lib/core/fuzzy.ml`:
- `val fuzzy_score : pattern:string -> haystack:string -> float option` — returns None if no match, Some score (0.0–1.0) if match
- Start with a simple subsequence matcher (pattern chars appear in order in haystack). Score = matched_chars / haystack_length, with bonuses for consecutive matches and word-boundary matches.

**Invariants:**
- Pure function. No state, no IO.
- Case-insensitive matching.
- Empty pattern matches everything with score 1.0.
- This is a v1 implementation. Can be replaced with a proper algorithm (Smith-Waterman, etc.) later without changing the interface.

**Accept:** Unit tests:
- `fuzzy_score ~pattern:"fxb" ~haystack:"fooXbar" = Some _` (subsequence match)
- `fuzzy_score ~pattern:"zzz" ~haystack:"foobar" = None`
- `fuzzy_score ~pattern:"" ~haystack:"anything" = Some 1.0`
- Score for "foo" in "foobar" > score for "fbr" in "foobar" (consecutive match bonus)

**Depends:** T1.4

---

### T2.4 — Implement ranking algorithm

**Do:** Create `lib/core/rank.ml`:
- Internal: `type signal = { weight : float; match_kind : match_kind }`
- Internal: individual signal checkers (`check_exact_cwd`, `check_same_repo`, etc.)
- Internal: `recency_bonus : float -> float` — exponential decay with ~1 week half-life
- `val rank : query -> now:float -> cwd:string -> repo_root:string option -> session -> ranked option`
- `val sort_ranked : ranked list -> ranked list`

Follow the scoring specification from architecture.md § Ranking algorithm.

**Invariants:**
- Pure functions. No IO, no global state.
- When `query.text = ""`, skip text-matching signals (id_prefix, substring, fuzzy). Return context-based ranking only (cwd, repo, active, recency).
- `rank` computes the full additive score, including recency, against caller-supplied `now`.
- `sort_ranked` uses `List.stable_sort` — preserves order for equal scores and does not mutate scores.
- Score is additive. Each signal contributes independently.
- `rank` returns `None` when no signals fire AND query text is non-empty (session doesn't match).
- Empty-query sessions admitted only by recency use `match_kind = Recency`.

**Accept:** Unit tests with known sessions:
- Session in current cwd + active + recent → highest score
- Session in same repo but different cwd → lower than exact cwd
- Session matching by fuzzy only → lowest text-match score
- Empty query → all sessions returned, sorted by context + recency
- Query "abc" with session id "abc123" → Id_prefix match
- The same ranked session keeps the same score regardless of what other ranked sessions are present in the result set.

**Depends:** T2.3

---

### T2.5 — Implement filtering functions and write .mli

**Do:** In `lib/core/`, add filter functions (can be in rank.ml or a separate filters.ml):
- `val filter_scope : scope -> cwd:string -> repo_root:string option -> session list -> session list`
- `val filter_tool : tool option -> session list -> session list`

Write `sessy_core.mli` exporting all public functions from rank, launch, config_merge, fuzzy.

**Invariants:**
- `filter_scope Cwd` keeps sessions where `session.cwd = cwd`.
- `filter_scope Repo` keeps sessions where `session.cwd` starts with `repo_root` (if repo_root is Some).
- `filter_scope All` keeps everything.
- `filter_tool None` keeps everything. `filter_tool (Some Claude)` keeps only Claude sessions.
- `.mli` hides internal signal types. Public `rank` includes `now`, and `expand_template` returns `result` rather than silently producing invalid commands.
- `.mli` hides internal signal types. Public `rank` includes `now`, and `expand_template` returns `result` rather than silently producing invalid commands.

**Accept:** `dune build` with `.mli`. Unit tests for each filter variant.

**Depends:** T2.4, T2.2, T2.1

---

## Phase 3: Adapters (Layer 2)

### T3.1 — Define SOURCE module type

**Do:** Create `lib/adapter/source.mli`:
```ocaml
module type SOURCE = sig
  val tool : Sessy_domain.tool
  val parse_history : string -> (Sessy_domain.session list, Sessy_domain.parse_error) result
  val parse_detail : string -> (Sessy_domain.session, Sessy_domain.parse_error) result
end
```

**Invariants:**
- SOURCE receives `string` (file contents), NOT file paths. Adapters are pure.
- Layer 2 depends on Layer 0 (types) and Layer 1 (core). Nothing else.
- No `open Unix` or file system calls in adapter code.

**Accept:** Module type compiles.

**Depends:** T1.4

---

### T3.2 — Implement Claude adapter

**Do:** Create `lib/adapter/claude.ml` implementing `SOURCE`:
- `parse_history`: split JSONL by lines, parse each line with Yojson, extract session fields, build session records. Skip unparseable lines (graceful degradation).
- `parse_detail`: parse a session detail JSONL to extract first/last messages for preview.

**Invariants:**
- Adapter receives string content, never reads files.
- Use `ppx_yojson_conv` or manual Yojson.Safe pattern matching — pick one approach and stick with it.
- Individual line parse failures are collected and logged, not fatal. Return all successfully parsed sessions.
- Field mapping must match real Claude history format from fixtures (T0.4).

**Accept:** Fixture-based test: `Claude.parse_history (read fixture)` → list of sessions with correct fields. Verify: id, tool=Claude, title, cwd, updated_at. Test with a line containing malformed JSON → that line skipped, others parsed.

**Depends:** T3.1, T0.4

---

### T3.3 — Implement Codex adapter

**Do:** Create `lib/adapter/codex.ml` implementing `SOURCE`:
- Same contract as Claude adapter but for Codex JSONL format.
- Handle Codex-specific field names (e.g., `session_id` vs `sessionId`, ISO timestamp vs Unix millis).

**Invariants:**
- Same as T3.2: pure, graceful degradation, fixture-based.
- No coupling to Claude adapter. Each adapter is independent.
- If Codex is not installed on dev machine, use best-effort fixture and document uncertainty.

**Accept:** Fixture-based test: `Codex.parse_history (read fixture)` → sessions with tool=Codex. Same resilience test as Claude.

**Depends:** T3.1, T0.4

---

### T3.4 — Write sessy_adapter.mli

**Do:** Create public interface for the adapter library. Export `SOURCE` module type, `Claude` module, `Codex` module. Add:
- `val adapter_for_tool : tool -> (module SOURCE)` — dispatch by tool type.
- `val all_adapters : (module SOURCE) list`

**Invariants:**
- .mli is the abstraction barrier. Internal JSON parsing details are hidden.
- No Layer 3+ types leak into the adapter interface.

**Accept:** `dune build` with .mli. Other libraries can use `Sessy_adapter.Claude.parse_history`.

**Depends:** T3.2, T3.3

---

## Phase 4: Index (Layer 3)

### T4.1 — Implement index build and search

**Do:** Create `lib/index/sessy_index.ml`:
- `type t` (opaque — internally a session list, possibly with Map by id)
- `val empty : t`
- `val build : session list -> t` — store sessions, deduplicate by id (keep most recent)
- `val search : t -> query -> now:float -> cwd:string -> repo_root:string option -> ranked list` — pipeline: filter → rank → sort
- `val count : t -> int`
- `val all_sessions : t -> session list`
- `val refresh : t -> session list -> t`
- `val find_by_id : t -> Session_id.t -> session option`

**Invariants:**
- Index is immutable. `refresh` returns a new index.
- `search` delegates to `Sessy_core.filter_scope`, `filter_tool`, `rank`, `sort_ranked` — it coordinates, doesn't re-implement.
- Layer 3 receives `now` from its caller; it does not read time directly if it remains pure.
- No IO. Index receives pre-parsed sessions.
- Layer 3 depends on Layer 0 + Layer 1. NOT on Layer 2 (adapters).

**Accept:** Test: build index from fixture sessions → search with query → verify result order matches ranking spec. Test: `find_by_id` returns correct session. Test: `refresh` replaces contents.

**Depends:** T2.5

---

### T4.2 — Write sessy_index.mli

**Do:** Write public interface. `type t` is opaque. Export `build`, `search`, `find_by_id`, `count`, `all_sessions`, `refresh`.

**Invariants:**
- Internal representation hidden behind opaque type.
- No session mutation possible through the public API.

**Accept:** `dune build` with .mli.

**Depends:** T4.1

---

## Phase 5: CLI Path — First E2E Vertical Slice

### T5.1 — Implement CLI argument parsing

**Do:** Create `lib/ui/cli.ml`:
- `type cli_action` sum type (Open_picker, Resume_last, Resume_id, List_sessions, Preview_session, Doctor, Reindex, Edit_config)
- `type output_format = Plain | Json`
- `val parse_cli : string list -> (cli_action, string) result`

Parse argv manually (no external arg-parsing library needed for this surface). Match on first positional argument.

**Invariants:**
- Pure function: `string list -> result`. No IO, no side effects.
- Layer 4 depends on Layer 0 + Layer 3. No shell/IO dependencies.
- Unknown commands produce `Error "unknown command: ..."`, never crash.

**Accept:** Unit tests:
- `parse_cli [] = Ok Open_picker`
- `parse_cli ["list"] = Ok (List_sessions Plain)`
- `parse_cli ["list"; "--json"] = Ok (List_sessions Json)`
- `parse_cli ["resume"; "abc123"] = Ok (Resume_id ...)`
- `parse_cli ["last"] = Ok Resume_last`
- `parse_cli ["preview"; "abc123"] = Ok (Preview_session ...)`
- `parse_cli ["doctor"] = Ok Doctor`
- `parse_cli ["unknown"] = Error _`

**Depends:** T1.4

---

### T5.2 — Implement CLI dispatch

**Do:** In `lib/ui/cli.ml`, add:
- `val dispatch : cli_action -> Sessy_index.t -> config -> cwd:string -> cmd list`
- For `List_sessions fmt` → produce `Print_sessions (sessions, fmt)` cmd
- For `Preview_session id` → find session in index, produce `Print_preview session` cmd
- For `Resume_id id` → find session, expand template, produce either `Launch launch_cmd` or `Print_error ...`
- For `Resume_last` → find most recent session for current cwd, produce either `Launch` or `Print_error ...`
- For `Doctor` → produce `Print_doctor diagnostics` cmd

**Invariants:**
- Pure function. Returns `cmd list` (data), not effects.
- Uses `Sessy_index.find_by_id`, `Sessy_core.expand_template`.
- Session not found → return `[Print_error "session not found: ..."]`, not crash.
- Launch template expansion errors become user-facing `Print_error ...`, not crashes.

**Accept:** Unit tests with constructed index + config → verify correct cmd output for each action.

**Depends:** T5.1, T4.1, T2.2

---

### T5.3 — Implement JSON/plain output formatting

**Do:** In `lib/ui/` (new file `format.ml` or in cli.ml):
- `val format_session_plain : session -> string` — one-line format: `[tool] short_id title cwd updated_ago`
- `val format_session_json : session -> Yojson.Safe.t` — JSON object
- `val format_sessions : output_format -> session list -> string` — format all sessions

**Invariants:**
- Pure functions. String in, string out.
- Plain format matches PRD §8.2 list row layout.
- JSON output must be valid JSON — use Yojson, don't hand-build strings.
- Relative time display ("5m ago", "2h ago", "3d ago") needs current time as parameter, not `Unix.gettimeofday()`.

**Accept:** Test: format 3 sessions as Plain → readable one-line-per-session output. Format as JSON → valid JSON array.

**Depends:** T1.4

---

### T5.4 — Implement shell filesystem operations

**Do:** Create `lib/shell/fs.ml`:
- `val read_file : string -> (string, [`Io_error of string]) result`
- `val list_dir : string -> (string list, [`Io_error of string]) result`
- `val file_exists : string -> bool`
- `val expand_home : string -> string` (replace leading `~` with `HOME`)

**Invariants:**
- THIS IS LAYER 5. Side effects are expected here.
- Wrap all potential exceptions in immediate `try ... with` → return `Result`.
- `expand_home` uses `Sys.getenv "HOME"`, not hardcoded paths.
- These functions are thin wrappers. No business logic.

**Accept:** `read_file` on a fixture returns file contents. `read_file` on nonexistent file returns `Error`. `expand_home "~/.claude"` → `/Users/<user>/.claude`.

**Depends:** T0.2

---

### T5.5 — Implement TOML config loader

**Do:** Create `lib/shell/config_loader.ml`:
- `val load_config : unit -> config` — read config files, parse TOML, convert to domain types, merge layers.
- Config resolution: built-in defaults → `~/.config/sessy/config.toml` (if exists) → `./.sessy.toml` (if exists).
- Use OTOML to parse TOML. Map TOML tables to domain `config` type.

**Invariants:**
- This is Layer 5 (IO). TOML parsing is effectful (reads files).
- Missing config files are OK — use defaults. Don't error.
- Invalid config values → log warning, use default for that field.
- The built-in default config is defined in Layer 1 (`Config_merge.default_config`). This function just reads files and calls `Core.resolve_config`.

**Accept:** With no config files → returns `default_config`. With fixture config.toml → returns correctly merged config. Invalid TOML → falls back to defaults with warning.

**Depends:** T5.4, T2.1

---

### T5.6 — Implement shell process operations

**Do:** Create `lib/shell/process.ml`:
- `val spawn : launch_cmd -> (unit, [`Exec_error of string]) result` — fork+exec child process
- `val exec_replace : launch_cmd -> unit` — `Unix.execvp`, replaces current process
- `val print_cmd : launch_cmd -> unit` — print command to stdout (dry-run)

**Invariants:**
- Layer 5. Side effects expected.
- Build argv from `launch_cmd.argv` tuple: `let (head, tail) = cmd.argv in head :: tail`.
- Change cwd to `launch_cmd.cwd` before exec.
- `spawn` waits for child to exit. `exec_replace` never returns.

**Accept:** `print_cmd` outputs the expected command string. `spawn` with `echo hello` works. `exec_replace` tested manually (replaces process).

**Depends:** T1.4

---

### T5.7 — Wire main.ml — the first E2E

**Do:** In `bin/main.ml`, implement `Shell.run`:
1. Load config (T5.5)
2. Read history files via fs (T5.4)
3. Parse via adapters (T3.2, T3.3)
4. Build index (T4.1)
5. Parse CLI args (T5.1)
6. Dispatch (T5.2)
7. Execute commands (T5.6)

For now, only support CLI actions (no TUI yet).

**Invariants:**
- `main.ml` is thin — it calls `Shell.run ()`, which orchestrates.
- The shell connects layers but doesn't contain domain logic.
- Adapter failures for one source don't prevent others from loading (graceful degradation from architecture.md § Error handling).
- Get `cwd` and `repo_root` from environment at startup (T5.4 + `detect_git_root`).

**Accept:** `dune exec sessy -- list --json` outputs sessions from real local history files as JSON. If no sessions found, outputs empty array `[]`. If no history files exist, outputs `[]` with no error.

**Depends:** T5.1–T5.6, T4.1, T3.2–T3.4

---

### T5.8 — First E2E test

**Do:** Create `test/e2e/` with an end-to-end test:
1. Read fixture JSONL → parse via Claude adapter → build index → search → verify ranking
2. Expand template for found session → verify launch_cmd argv
3. Format sessions as JSON → verify valid JSON output

This tests the full pipeline: fixtures → adapter → index → search → ranking → launch assembly → output.

**Invariants:**
- E2E tests exercise the pipeline through multiple layers.
- Tests use fixture files, not live data.
- No mocks. Adapters are pure (string → result), so they're tested directly with fixture strings.

**Accept:** `dune test` passes. Pipeline produces correct output for fixture data.

**Depends:** T5.7

---

### T5.9 — Implement `sessy last` and `sessy resume <id>`

**Do:** Wire the `Resume_last` and `Resume_id` CLI actions:
- `Resume_last`: find most recent session for current cwd (or any if none in cwd), expand template, spawn.
- `Resume_id id`: find session by id in index, expand template, spawn.
- Add `--dry-run` flag to CLI parsing. When set, use `Print` exec mode.

**Invariants:**
- Session not found → print error, exit 1. Don't crash.
- `--dry-run` shows the exact command that WOULD be executed.
- Launch uses profile from config, or no profile when the selected template does not require one.
- If a launch template requires `{{profile}}` and no profile is active, print a user-facing error instead of spawning.

**Accept:** `sessy last --dry-run` prints the resume command for the most recent session. `sessy resume abc123 --dry-run` prints the command for that session. Without `--dry-run`, actually spawns the process (test manually).

**Depends:** T5.7

---

### T5.10 — Implement `sessy preview <id>`

**Do:** Wire the `Preview_session` CLI action:
- Find session in index
- Display: full session id, tool, cwd, project, model, title, first prompt, last activity, launch command preview
- Format matches PRD §8.2 right preview pane content

**Invariants:**
- Plain text output to stdout. No TUI required.
- Shows the exact launch command that would be used (via `expand_template`), or a user-facing launch error if template expansion fails.

**Accept:** `sessy preview abc123` shows formatted session details. Session not found → error message.

**Depends:** T5.7

---

### T5.11 — Implement `sessy doctor`

**Do:** Wire the `Doctor` CLI action. Check:
- Config file locations (exists / not found)
- Source paths (history files exist / not found)
- Adapters can parse history files without errors
- Tools are installed (`which claude`, `which codex`)
- Session counts per source

**Invariants:**
- Doctor is diagnostic, read-only. Never modifies anything.
- Output is human-readable, one check per line with status.

**Accept:** `sessy doctor` outputs diagnostic info. Missing sources show warning, not error.

**Depends:** T5.7

---

## Phase 6: TUI

### T6.1 — Define TUI model and msg types

**Do:** Create `lib/ui/model.ml` with `type model` record, `type msg` sum type, and `type cmd` sum type, exactly as specified in architecture.md § Layer 4.

**Invariants:**
- Model is immutable. No mutable fields.
- `cmd` is DATA describing effects, not effects themselves.
- `msg` is a closed sum type — every possible user action is a named variant.

**Accept:** Types compile.

**Depends:** T4.2

---

### T6.2 — Implement init and update functions

**Do:** Create `lib/ui/update.ml`:
- `val init : Sessy_index.t -> config -> cwd:string -> repo_root:string option -> model`
- `val update : model -> msg -> model * cmd`

Implement all msg handlers per architecture.md § Operational semantics. Key behaviors:
- `Query_changed` → re-search index, reset cursor to 0
- `Session_selected` → expand template, return `Launch`
- `Scope_toggled` → cycle Cwd → Repo → All, re-search
- `Tool_filter_toggled` → cycle None → Some Claude → Some Codex → None, re-search
- `Preview_toggled` → flip preview_visible
- `Quit` → return `Exit`

**Invariants:**
- `update` is PURE. It returns `(model, cmd)`. It NEVER does IO.
- Every msg handler is exhaustive — the compiler enforces this via pattern matching.
- After any state change that affects results, re-run `Index.search`.
- Cursor is clamped to `0..List.length results - 1`.

**Accept:** Unit tests:
- `update model (Query_changed "foo")` → results re-computed, cursor = 0
- `update model Session_selected` → produces `Launch cmd` with correct argv
- `update model Scope_toggled` → scope cycles, results re-computed
- `update model Quit` → produces `Exit`

**Depends:** T6.1, T4.1, T2.2

---

### T6.3 — Implement basic view rendering

**Do:** Create `lib/ui/view.ml`:
- `val view : model -> string` — render the full TUI as a string

Start with basic rendering:
- Header line: query text, scope badge, tool filter badge
- Session list: one line per result (tool icon, title/prompt, short id, path, time ago)
- Footer: keybinding hints

No preview pane yet — add in T6.5.

**Invariants:**
- `view` is PURE. model → string. No IO, no terminal escape codes computation side effects.
- Use ANSI escape codes for styling (bold, colors) directly in string output — Minttea renders raw strings.
- Highlight the cursor row (invert colors).
- Truncate long lines to terminal width (pass width as model field or parameter).

**Accept:** Given a model with 3 results, `view model` produces a readable multi-line string with header, 3 session rows (cursor on first), and footer.

**Depends:** T6.2

---

### T6.4 — Integrate with Minttea runtime

**Do:** Create `lib/shell/runtime.ml`:
- Bridge between our pure Layer 4 (model/update/view) and Minttea's runtime.
- Implement the `Minttea.App` module type wrapping our types.
- Map Minttea key events to our `msg` type.
- Map our `cmd` type to Minttea commands (`Cmd.quit`, `Cmd.none`, etc.).
- Wire `Shell.run` to start TUI when `Open_picker` action is dispatched.

**Invariants:**
- This is Layer 5. The bridge is the ONLY place where our pure `cmd` type gets translated into actual side effects.
- Our `update` function stays pure — the impure wrapping happens here.
- Minttea owns the event loop. We don't manage terminal state manually.

**Accept:** `sessy` (no args) opens the TUI. Session list is visible. Typing filters results. Pressing Esc quits. Pressing Enter on a session runs the resume command.

**Depends:** T6.3, T5.7

---

### T6.5 — Add preview pane

**Do:** Extend `view.ml` to render a preview pane when `model.preview_visible = true`:
- Split terminal horizontally: left = session list (~60%), right = preview (~40%)
- Preview content: full session id, tool, cwd, model, title, first/last message, launch command
- Toggle with `Tab` (already in msg type)

**Invariants:**
- `view` remains pure. Layout is string computation.
- Preview uses data already in the model — no lazy loading yet.
- Respect terminal width. If too narrow, hide preview automatically.

**Accept:** Press Tab → preview appears/disappears. Preview shows correct session details for cursor position. Resizing terminal adjusts layout.

**Depends:** T6.4

---

### T6.6 — Add keybindings: copy, scope, filter, reload

**Do:** Map remaining keybindings from PRD §8.2:
- `Ctrl-Y` → `Copy_to_clipboard (Session_id.to_string selected.id)` cmd
- `Ctrl-O` → `Open_directory selected.cwd` cmd
- `Ctrl-S` → `Scope_toggled` msg
- `Ctrl-T` → `Tool_filter_toggled` msg
- `Ctrl-F` → `Search_mode_toggled` msg
- `Ctrl-R` → `Reload_index` cmd
- `?` → show help overlay

Implement clipboard copy and directory open in Shell (Layer 5).

**Invariants:**
- Key mapping happens in the Minttea bridge (Layer 5 runtime.ml) → produces msg.
- The update function in Layer 4 handles msg purely.
- Clipboard: use `pbcopy` on macOS, `xclip`/`xsel` on Linux. Shell implementation.

**Accept:** Each keybinding works as specified. Copy puts session ID in system clipboard. Help overlay shows all shortcuts.

**Depends:** T6.4

---

## Phase 7: Polish and Distribution

### T7.1 — Cold start benchmark

**Do:** Benchmark `time sessy list --json` with real session data. Measure wall-clock time from process start to output complete.

**Invariants:**
- Acceptance threshold: <200ms (hard constraint from decision dec-20260408-001).
- Prediction: <50ms (from decision predictions).
- Measure on Apple Silicon Mac with representative session count.

**Accept:** `time sessy list --json` consistently under 200ms. Record actual measurement as evidence in Haft.

**Depends:** T5.7

---

### T7.2 — Static binary build for macOS

**Do:** Configure dune for static linking on macOS. Build for arm64 (native) and x86_64 (if feasible). Test that binary runs without OCaml/opam installed.

**Invariants:**
- Single binary, no runtime dependencies.
- Binary should work on a clean macOS install.

**Accept:** Copy binary to a different machine (or Docker container) → runs and produces output.

**Depends:** T5.7

---

### T7.3 — Static binary build for Linux

**Do:** Set up Linux static build using musl. Docker-based or cross-compilation. Build for x86_64.

**Invariants:**
- Static binary with musl — no glibc dependency.
- Must run on any modern Linux x86_64.

**Accept:** Binary runs in a minimal Alpine/Debian Docker container without OCaml installed.

**Depends:** T5.7

---

### T7.4 — CI setup

**Do:** Create GitHub Actions workflow:
- Build on macOS (arm64)
- Build on Linux (x86_64, musl static)
- Run tests on both platforms
- Produce release artifacts

**Invariants:**
- CI matches the build configurations that produce the release binaries.
- Tests must pass on both platforms.

**Accept:** Push to main → CI builds and tests pass → artifacts downloadable.

**Depends:** T7.2, T7.3

---

### T7.5 — README and installation

**Do:** Write README.md with:
- One-line description
- Installation (binary download, cargo-like opam install)
- Quick start (basic usage examples)
- Configuration (link to config format)
- Architecture overview (link to .context/architecture.md for contributors)

**Invariants:**
- README is for USERS, not developers. Keep it concise.
- Show the 3 most important commands: `sessy`, `sessy last`, `sessy list --json`.

**Accept:** Someone can install and use sessy by following the README.

**Depends:** T7.4

---

## Phase summary

| Phase | Tasks | What ships | First user-visible output |
|-------|-------|------------|--------------------------|
| 0 | T0.1–T0.4 | Build system, fixtures | `dune build` works |
| 1 | T1.1–T1.4 | Domain types | Types compile |
| 2 | T2.1–T2.5 | Core logic + tests | Pure functions tested |
| 3 | T3.1–T3.4 | Adapters + tests | Parse real history files |
| 4 | T4.1–T4.2 | Index + tests | Searchable collection |
| **5** | **T5.1–T5.11** | **CLI works E2E** | **`sessy list --json` → real sessions** |
| 6 | T6.1–T6.6 | TUI picker works | Interactive session picker |
| 7 | T7.1–T7.5 | Release-ready | Downloadable binary |

**Critical milestone:** After Phase 5, sessy is usable as a CLI tool. The TUI (Phase 6) adds polish but isn't required for basic recall + resume.

---

## Architectural invariants checklist (for every task)

Before marking any task complete, verify:

- [ ] **No IO in Layers 0–4.** If you added a file read or print in domain/core/adapter/index/ui — move it to Shell.
- [ ] **No skip-level dependencies.** Check dune files — each library depends only on its declared deps.
- [ ] **No stringly-typed domain concepts.** Session IDs, tools, scopes, exec modes are all typed.
- [ ] **No exceptions for control flow.** All errors use `Result`. Only Layer 5 may `try ... with` external calls.
- [ ] **No mutable state.** All data structures are immutable. New values returned, never mutated.
- [ ] **Module signatures (.mli) present** for every library. Implementation details hidden.
- [ ] **Pipeline style.** Data flows top-to-bottom with `|>`. One operation per line.
- [ ] **Tests exist for pure logic.** Every Core/Adapter/Index function has at least one test.
