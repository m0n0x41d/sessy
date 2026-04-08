# sessy — Functional Architecture (OCaml 5)

## Design principles

1. **Core-first, layered.** Domain types are the gravitational center. Logic grows outward.
2. **Pure core / thin effect shell.** Layers 0–4 are pure. Layer 5 is the only place with IO.
3. **Elm Architecture for TUI.** `update : model -> msg -> model * cmd` is a pure function. The runtime drives it.
4. **Module signatures as abstraction barriers.** Every layer boundary has an `.mli`. Implementation is hidden.
5. **Make illegal states inexpressible.** Newtypes, sum types, private modules. No stringly-typed domain concepts.
6. **Pipeline composition.** `|>` everywhere. One operation per line. Primary value flows left-to-right.

## Domain pipeline

```
[Disk: JSONL/TOML]
  → parse (raw string → typed session)
  → index (sessions from N sources → unified collection)
  → search (query → ranked results)
  → select (user picks one via TUI or CLI)
  → launch (session × profile → execvp)
```

The TUI wraps `search → select` as an interactive loop.

---

## Layer hierarchy

```
┌─────────────────────────────────────────┐
│  LAYER 5: Shell (effects)               │  Eio, process spawn, terminal IO
│  LAYER 4: Interaction (state machine)   │  Elm Architecture, CLI dispatch
│  LAYER 3: Collection (index + search)   │  Unified index, ranking coordination
│  LAYER 2: Adapters (source protocols)   │  Claude-specific, Codex-specific parsing
│  LAYER 1: Core (pure transformations)   │  Ranking, assembly, config merge
│  LAYER 0: Domain (algebraic types)      │  Session, Query, LaunchCmd, Config
└─────────────────────────────────────────┘
```

**Dependency rule:** Each layer depends on the layer directly below it.
**Exception:** Layer 0 (Domain) is the kernel — visible to all layers as shared vocabulary.

---

### LAYER 0: Domain Kernel — `sessy_domain`

**What it is:** Algebraic types that express the domain vocabulary. No functions, no logic. Just types.

**Concepts:**
- Session (the primary entity)
- Tool (Claude | Codex)
- Query, Scope, SearchMode
- LaunchCmd, ExecMode, Profile
- Config, SourceConfig

**Key types:**

```ocaml
(* Tool — closed sum type, not a string *)
type tool = Claude | Codex

(* Opaque session ID — constructor validates non-empty *)
module Session_id : sig
  type t
  val of_string : string -> t option
  val to_string : t -> string
  val short : t -> string          (* first 8 chars for list display *)
  val equal : t -> t -> bool
  val compare : t -> t -> int
end

(* The primary domain entity *)
type session = {
  id : Session_id.t;
  tool : tool;
  title : string option;
  first_prompt : string option;
  cwd : string;
  project_key : string option;
  model : string option;
  updated_at : float;
  is_active : bool;
}

(* Search *)
type scope = Cwd | Repo | All
type search_mode = Meta | Deep

type query = {
  text : string;
  scope : scope;
  tool_filter : tool option;
  mode : search_mode;
}

(* How a match was classified *)
type match_kind =
  | Exact_cwd
  | Same_repo
  | Active
  | Id_prefix
  | Substring
  | Fuzzy
  | Recency

type ranked = {
  session : session;
  score : float;
  match_kind : match_kind;
}

(* Launch *)
type exec_mode = Spawn | Exec | Print

type launch_cmd = {
  argv : string * string list;   (* non-empty by construction: head * tail *)
  cwd : string;
  exec_mode : exec_mode;
  display : string;              (* human-readable for dry-run *)
}

(* Config *)
type source_config = {
  tool : tool;
  history_path : string;
  projects_path : string option;
  sessions_path : string option;
}

type launch_template = {
  argv_template : string * string list;
  cwd_policy : [ `Session | `Current ];
  default_exec_mode : exec_mode;
}

type profile = {
  name : string;
  base_tool : tool;
  argv_append : string list;
  exec_mode_override : exec_mode option;
}

type config = {
  default_scope : scope;
  preview : bool;
  selected_profile : string option;
  sources : source_config list;
  launches : (tool * launch_template) list;
  profiles : profile list;
}

(* Errors — sum types, never exceptions *)
type parse_error =
  | Invalid_json of string
  | Missing_field of string
  | Invalid_format of string

type config_error =
  | File_not_found of string
  | Parse_failed of string
  | Invalid_value of string * string
```

**Inexpressible in this layer:**
- A session without a tool (tool is required in the record)
- An empty Session_id (constructor rejects via `option`)
- A launch command with empty argv (tuple `string * string list` guarantees head)
- A tool that isn't Claude or Codex (closed sum type)
- An unclassified match (match_kind is exhaustive)

**What this layer does NOT do:**
- No functions, no parsing, no IO
- No business logic — just vocabulary

**Depends on:** nothing

---

### LAYER 1: Core Logic — `sessy_core`

**What it is:** Pure functions that transform domain types. The computational heart.

**Concepts:**
- Ranking (query × session → score)
- Launch assembly (session × profile → command)
- Config merging (layers → resolved config)
- Template expansion (template × session → argv)

**Key signatures:**

```ocaml
(** Ranking — implements PRD §9.2 ranking policy *)
val rank :
  query ->
  now:float ->
  cwd:string ->
  repo_root:string option ->
  session ->
  ranked option
(** Returns None if session doesn't match at all.
    Ranking priority:
    1. exact cwd match
    2. same git repo/worktree
    3. active/running session
    4. exact session-id prefix match
    5. exact substring in title/snippet/path
    6. fuzzy match
    7. recency decay *)

val sort_ranked : ranked list -> ranked list
(** Stable sort only. Scores are already fully computed by [rank]. *)

(** Launch assembly *)
val expand_template :
  session ->
  profile option ->
  launch_template ->
  (launch_cmd, config_error) result
(** Pure: substitutes placeholders {{id}}, {{tool}}, {{cwd}} etc.
    Returns either a fully resolved argv or a config error. *)

(** Config merging — fold over layers *)
val merge_config : config -> config -> config
(** Left-biased merge: second overrides first *)

val resolve_config : config list -> config
(** resolve [builtin; user; project; cli] = final config *)

(** Filtering *)
val filter_scope : scope -> cwd:string -> repo_root:string option -> session list -> session list
val filter_tool : tool option -> session list -> session list

(** Fuzzy matching — thin wrapper over matching algorithm *)
val fuzzy_score : pattern:string -> haystack:string -> float option
```

**Operational semantics:**

```
rank(q, now, session) =
  let signals = compute_signals(q, session) in
  let admitted = signals <> [] || q.text = "" in
  if not admitted then None
  else Some { session; score = aggregate(signals) + recency_bonus(now, session.updated_at); match_kind = best_signal_or_recency(signals) }

expand_template(session, profile, tmpl) =
  tmpl.argv_template
  |> expand_argv_template session profile
  |> build_launch_cmd tmpl.cwd_policy tmpl.default_exec_mode session

resolve_config(layers) =
  List.fold_left merge_config default_config layers
```

**Inexpressible in this layer:**
- Side effects (no IO signatures, no Eio dependency)
- Non-determinism (all functions are pure: same input → same output)
- Invalid ranking order (sort_ranked guarantees the policy)
- Unresolved known placeholders (`{{profile}}` must resolve or return an error)

**Depends on:** Layer 0 (Domain)

---

### LAYER 2: Source Adapters — `sessy_adapter`

**What it is:** Source-specific parsing logic. Each adapter knows HOW to turn a specific tool's file format into domain types. Adapters receive raw strings (file contents), not file handles — they are pure.

**Concepts:**
- SOURCE module signature (the adapter contract)
- Claude-specific JSONL parsing
- Codex-specific JSONL parsing
- Session detail hydration (lazy, from transcript files)

**Key signatures:**

```ocaml
(** The adapter contract — a module signature *)
module type SOURCE = sig
  val tool : tool
  val parse_history : string -> (session list, parse_error) result
  (** Parse a history.jsonl file contents into sessions *)

  val parse_detail : string -> (session, parse_error) result
  (** Parse a session detail file for preview hydration *)
end

module Claude : SOURCE
(** Parses ~/.claude/history.jsonl format.
    Knows about project keys and session IDs. *)

module Codex : SOURCE
(** Parses ~/.codex/history.jsonl format.
    Knows about date-organized session dirs. *)
```

**How adapters stay pure:**

```
Claude.parse_history(raw_jsonl_string)
  → split into lines
  → parse each line as JSON (Yojson)
  → extract fields into session record
  → return (session list, parse_error) result

The Shell (Layer 5) reads the file, the Adapter parses the string.
```

**Inexpressible in this layer:**
- File system access (adapters receive strings, not paths)
- Cross-adapter coupling (Claude module doesn't import Codex module)
- Knowledge of TUI, index, or ranking
- Any awareness of how sessions will be displayed or launched

**Depends on:** Layer 1 (Core) for shared parse utilities, Layer 0 (Domain) for types

---

### LAYER 3: Collection — `sessy_index`

**What it is:** The unified session collection. Merges sessions from all adapters into one searchable index. Coordinates ranking.

**Concepts:**
- Index (the in-memory collection)
- Search (query → ranked results using Layer 1's ranking)
- Refresh (rebuild or update index)

**Key signatures:**

```ocaml
(** The index — immutable, rebuilt on refresh *)
type t

val empty : t
val build : session list -> t
(** Build index from a flat session list (already parsed by adapters) *)

val search : t -> query -> now:float -> cwd:string -> repo_root:string option -> ranked list
(** Execute search: filter by scope/tool, rank each session, sort results.
    Delegates to Core.rank and Core.sort_ranked. *)

val count : t -> int
val all_sessions : t -> session list

val refresh : t -> session list -> t
(** Replace index contents. Returns new index. *)
```

**Operational semantics:**

```
search(index, query, ~now, ~cwd, ~repo_root) =
  index
  |> all_sessions
  |> filter_tool query.tool_filter
  |> filter_scope query.scope ~cwd ~repo_root
  |> List.filter_map (rank query ~now ~cwd ~repo_root)
  |> sort_ranked
```

This is a pipeline. Each step is a pure function from Layer 1.

**Inexpressible in this layer:**
- Source-specific details (doesn't know about Claude vs Codex file formats)
- IO / file access
- UI concerns (doesn't know about TUI rendering)
- Mutable state (index is immutable; refresh returns new index)

**Depends on:** Layer 1 (Core) for ranking/filtering, Layer 0 (Domain) for types

---

### LAYER 4: Interaction — `sessy_ui`

**What it is:** The state machine for user interaction. Two sub-modules: TUI (Elm Architecture) and CLI (command dispatch). Both are pure — they produce commands (data descriptions of effects), never execute them.

**Concepts:**
- Model (TUI state)
- Msg (events/actions)
- Cmd (effect descriptions — data, not effects)
- View (model → rendered output)
- CLI dispatch (args → action)

**TUI — Elm Architecture:**

```ocaml
(** TUI state — immutable *)
type model = {
  index : Index.t;
  config : config;
  query : query;
  results : ranked list;
  cursor : int;
  preview_visible : bool;
  active_profile : string option;
  cwd : string;
  repo_root : string option;
}

(** Events — closed sum type *)
type msg =
  | Key of key
  | Query_changed of string
  | Scope_toggled
  | Tool_filter_toggled
  | Search_mode_toggled
  | Profile_changed of string
  | Session_selected
  | Preview_toggled
  | Reload_requested
  | Quit

(** Commands — descriptions of effects, NOT effects themselves *)
type cmd =
  | Launch of launch_cmd
  | Copy_to_clipboard of string
  | Open_directory of string
  | Reload_index
  | Exit
  | Noop

(** Pure state transition *)
val init : Index.t -> config -> cwd:string -> repo_root:string option -> model

val update : model -> msg -> model * cmd
(** THE central function. Pure: takes state + event, returns new state + command.
    The runtime (Layer 5) executes the command. *)

val view : model -> Minttea.view
(** Pure rendering: model → TUI output.
    No side effects. Minttea runtime handles actual terminal writes. *)
```

**CLI dispatch:**

```ocaml
(** CLI actions — what the user asked for via command-line args *)
type cli_action =
  | Open_picker                           (* sessy *)
  | Open_picker_fzf                       (* sessy --ui=fzf *)
  | Resume_last                           (* sessy last *)
  | Resume_id of Session_id.t             (* sessy resume <id> *)
  | List_sessions of output_format        (* sessy list [--json] *)
  | Preview_session of Session_id.t       (* sessy preview <id> *)
  | Doctor                                (* sessy doctor *)
  | Reindex                               (* sessy reindex *)
  | Edit_config                           (* sessy config edit *)

type output_format = Plain | Json | Tsv

val parse_cli : string list -> (cli_action, string) result
(** Pure: parse argv into a CLI action. *)

val dispatch : cli_action -> Index.t -> config -> cmd list
(** Pure: given action + state, produce commands for the shell to execute. *)
```

**Operational semantics of update:**

```
update(model, Query_changed text) =
  let query = { model.query with text } in
  let results = Index.search model.index query ~now:model.now ~cwd:model.cwd ~repo_root:model.repo_root in
  ({ model with query; results; cursor = 0 }, Noop)

update(model, Session_selected) =
  match List.nth_opt model.results model.cursor with
  | None -> (model, Noop)
  | Some { session; _ } ->
    let template = lookup_launch model.config session.tool in
    let profile = Option.bind model.active_profile (lookup_profile model.config) in
    match Core.expand_template session profile template with
    | Ok cmd -> (model, Launch cmd)
    | Error _ -> (model, Noop)
```

**Inexpressible in this layer:**
- Direct IO (update returns commands, never calls execvp or reads files)
- Invalid state transitions (msg type constrains actions exhaustively)
- Unranked display (results always pass through Index.search → Core.sort_ranked)
- Raw file paths or JSON in the model (only domain types)

**Depends on:** Layer 3 (Index) for search, Layer 1 (Core) for launch assembly, Layer 0 (Domain) for types

---

### LAYER 5: Effect Shell — `sessy_shell`

**What it is:** The thin imperative boundary. Reads files, spawns processes, drives the TUI event loop. The ONLY layer with side effects (Eio).

**Concepts:**
- File system operations
- Process execution (spawn, exec-replace)
- TUI runtime (Minttea event loop driving Layer 4's pure state machine)
- Wiring (connects all layers together)

**Key signatures:**

```ocaml
(** File system — all effectful *)
val read_file : string -> (string, [`Io_error of string]) result
val list_dir : string -> (string list, [`Io_error of string]) result
val file_exists : string -> bool
val expand_home : string -> string

(** Process execution *)
val spawn : launch_cmd -> (unit, [`Exec_error of string]) result
val exec_replace : launch_cmd -> (unit, [`Exec_error of string]) result
val print_cmd : launch_cmd -> unit      (* dry-run: print command *)

(** Environment *)
val get_cwd : unit -> string
val detect_git_root : string -> string option
val is_process_running : int -> bool

(** Orchestration — the main entry point *)
val run : unit -> unit
```

**How the shell orchestrates (main.ml):**

```
run () =
  (* 1. Load config: read files, merge layers *)
  let config = load_config () in

  (* 2. Load sessions: read history files via adapters *)
  let sessions =
    config.sources
    |> List.map (fun src ->
      let raw = read_file (expand_home src.history_path) in
      let adapter = match src.tool with Claude -> Claude | Codex -> Codex in
      Result.bind raw adapter.parse_history)
    |> collect_results
    |> List.concat
  in

  (* 3. Build index *)
  let index = Index.build sessions in

  (* 4. Parse CLI args and dispatch *)
  match Ui.parse_cli (Array.to_list Sys.argv) with
  | Ok (Open_picker) -> print_notice "interactive mode is not implemented yet"
  | Ok (List_sessions fmt) -> print_sessions index fmt
  | Ok (Resume_id id) -> exec_resume index config id
  | ...

  (* 5. TUI loop (Minttea drives it): *)
  (* Minttea calls Ui.update on each event *)
  (* Minttea calls Ui.view to render *)
  (* Shell executes Ui.cmd results (Launch, Copy, Exit) *)
```

**Inexpressible in this layer:**
- Domain logic (no ranking, no parsing, no config merging — delegates to Layers 1–4)
- Pure computation (this layer is ONLY for effects)
- Business rules (the shell doesn't decide WHAT to do, only HOW to execute)

**Depends on:** All layers (wiring point). But only calls their public APIs through `.mli` signatures.

---

## Compilation chain — from user action to OS

### Example 1: User types "foo" in search bar

```
[Terminal] keypress 'f', 'o', 'o'
  → [Layer 5: Minttea runtime] captures input, constructs msg
  → [Layer 4: Ui.update] model (Query_changed "foo")
    → [Layer 3: Index.search] index query ~cwd ~repo_root
      → [Layer 1: Core.filter_scope] Cwd ~cwd sessions → filtered
      → [Layer 1: Core.rank] query session → ranked option (for each)
      → [Layer 1: Core.sort_ranked] ranked list → sorted
    ← ranked list
  ← (new_model, Noop)
  → [Layer 4: Ui.view] new_model
  ← rendered TUI output
  → [Layer 5: Minttea runtime] writes to terminal
```

### Example 2: User presses Enter on a session

```
[Terminal] keypress Enter
  → [Layer 5: Minttea runtime] constructs msg
  → [Layer 4: Ui.update] model Session_selected
    → [Layer 1: Core.expand_template] session profile template
      → [Layer 0] substitutes {{id}} → "abc123", {{tool}} → "claude"
    ← launch_cmd { argv = ("claude", ["--resume"; "abc123"]); cwd = "/repo"; exec_mode = Spawn; ... }
  ← (model, Launch launch_cmd)
  → [Layer 5: Shell] matches on Launch cmd
    → [Layer 5: Shell.spawn] launch_cmd
      → [OS] execvp("claude", ["claude"; "--resume"; "abc123"])
```

### Example 3: `sessy list --json`

```
[OS] argv = ["sessy"; "list"; "--json"]
  → [Layer 5: Shell.run]
    → [Layer 4: Cli.parse_cli] ["list"; "--json"] → Ok (List_sessions Json)
    → [Layer 5] load sessions (read files → adapters → index)
    → [Layer 4: Cli.dispatch] (List_sessions Json) index config
      → [Layer 3: Index.all_sessions] index → session list
    ← cmd list: [Print_json sessions]
    → [Layer 5] Yojson.Safe.to_string sessions → stdout
```

---

## Project structure

```
sessy/
├── dune-project
├── sessy.opam
├── bin/
│   ├── dune                    # (executable (name main) (libraries sessy_shell))
│   └── main.ml                 # Entry point: Shell.run ()
├── lib/
│   ├── domain/                 # LAYER 0
│   │   ├── dune                # (library (name sessy_domain))
│   │   ├── sessy_domain.ml     # All domain types
│   │   └── sessy_domain.mli    # Public type signatures
│   ├── core/                   # LAYER 1
│   │   ├── dune                # (library (name sessy_core) (libraries sessy_domain))
│   │   ├── rank.ml             # Ranking algorithm
│   │   ├── launch.ml           # Template expansion + launch assembly
│   │   ├── config_merge.ml     # Config layer merging
│   │   ├── fuzzy.ml            # Fuzzy matching
│   │   └── sessy_core.mli      # Public API
│   ├── adapter/                # LAYER 2
│   │   ├── dune                # (library (name sessy_adapter) (libraries sessy_domain sessy_core yojson))
│   │   ├── source.mli          # SOURCE module type
│   │   ├── claude.ml           # Claude Code adapter
│   │   ├── codex.ml            # Codex adapter
│   │   └── sessy_adapter.mli
│   ├── index/                  # LAYER 3
│   │   ├── dune                # (library (name sessy_index) (libraries sessy_domain sessy_core))
│   │   ├── sessy_index.ml      # Index type + search coordination
│   │   └── sessy_index.mli
│   ├── ui/                     # LAYER 4
│   │   ├── dune                # (library (name sessy_ui) (libraries sessy_domain sessy_core sessy_index))
│   │   ├── model.ml            # TUI model type
│   │   ├── update.ml           # Pure update function
│   │   ├── view.ml             # Pure view rendering
│   │   ├── cli.ml              # CLI arg parsing + dispatch
│   │   └── sessy_ui.mli
│   └── shell/                  # LAYER 5
│       ├── dune                # (library (name sessy_shell) (libraries sessy_domain sessy_ui sessy_adapter sessy_index eio otoml minttea))
│       ├── fs.ml               # File system operations
│       ├── process.ml          # Process spawn/exec
│       ├── runtime.ml          # TUI event loop driver
│       ├── config_loader.ml    # Read + parse config files
│       └── sessy_shell.mli
├── test/
│   ├── core/                   # Unit tests for pure ranking, assembly, config merge
│   ├── adapter/                # Fixture-based tests (sample JSONL → sessions)
│   └── e2e/                    # Full pipeline tests
└── fixtures/
    ├── claude_history.jsonl     # Sample Claude history
    ├── codex_history.jsonl      # Sample Codex history
    └── config.toml              # Sample config
```

---

## Dependency graph (dune libraries)

```
sessy_domain ← sessy_core ← sessy_adapter
                           ← sessy_index ← sessy_ui ← sessy_shell ← main
```

```
sessy_domain:   (libraries)
sessy_core:     (libraries sessy_domain)
sessy_adapter:  (libraries sessy_domain sessy_core yojson ppx_yojson_conv)
sessy_index:    (libraries sessy_domain sessy_core)
sessy_ui:       (libraries sessy_domain sessy_core sessy_index)
sessy_shell:    (libraries sessy_domain sessy_ui sessy_adapter sessy_index eio otoml minttea)
```

External dependencies:
- **minttea** — TUI framework (Elm Architecture)
- **yojson + ppx_yojson_conv** — JSON parsing with deriving
- **otoml** — TOML config parsing
- **eio** — Direct-style IO (OCaml 5 effect handlers)

---

## Testing strategy (per CLAUDE.md priority)

1. **E2E first**: Parse real Claude/Codex history fixtures → build index → search → verify ranking order → verify launch command assembly
2. **Adapter tests**: Feed sample JSONL strings → verify parsed session fields
3. **Core unit tests**: Ranking function with known inputs → verify score ordering. Config merge with known layers → verify resolution. Template expansion → verify argv.
4. **No mocks needed**: Adapters are pure (string → result), Core is pure, Index is pure. Only Shell touches IO — and Shell is thin enough to test via E2E.

---

## Config file format (TOML)

```toml
[ui]
scope = "repo"        # default scope: cwd | repo | all
preview = true
profile = "fast"

[sources.claude]
history = "~/.claude/history.jsonl"
projects = "~/.claude/projects"
sessions = "~/.claude/sessions"

[sources.codex]
history = "~/.codex/history.jsonl"
sessions = "~/.codex/sessions"

[launch.claude]
argv = ["claude", "--resume", "{{id}}"]
cwd_policy = "session"
exec_mode = "spawn"

[launch.codex]
argv = ["codex", "resume", "{{id}}"]
cwd_policy = "session"
exec_mode = "spawn"

[profiles.claude.unsafe]
extends = "claude"
argv_append = ["--dangerously-skip-permissions"]

[profiles.codex.fast]
extends = "codex"
argv_append = ["--profile", "fast"]
```

Config resolution order: built-in defaults → `~/.config/sessy/config.toml` → `./.sessy.toml` → CLI flags. The selected launch profile is carried in resolved config as `ui.profile`.

---

## Ranking algorithm specification (PRD §9.2)

The ranking function computes a composite score from independent signals.
Each signal is a separate pure function. Signals are combined additively.

### Signal definitions

```
Signal              Weight    Condition                                  match_kind
─────────────────── ──────    ─────────────────────────────────────────  ──────────
exact_cwd           10000     session.cwd = current_cwd                 Exact_cwd
same_repo            5000     session.cwd starts with repo_root         Same_repo
active_session       3000     session.is_active = true                  Active
id_prefix            2000     query.text is prefix of session.id        Id_prefix
substring            1000     query.text is substring of                Substring
                              title|first_prompt|cwd|project_key
fuzzy_match           500     fuzzy_score(query.text, searchable) > 0   Fuzzy
                              (scaled by fuzzy_score 0.0–1.0)
recency_decay         0–200   200 * exp(-age_hours / 168)               Recency if
                              decays over ~1 week half-life             no other signal
```

### Scoring pipeline

```ocaml
(* Each signal is independently computed *)
type signal = {
  weight : float;
  match_kind : match_kind;
}

let compute_signals query ~cwd ~repo_root session =
  [ check_exact_cwd cwd session
  ; check_same_repo repo_root session
  ; check_active session
  ; check_id_prefix query.text session.id
  ; check_substring query.text session
  ; check_fuzzy query.text session
  ]
  |> List.filter_map Fun.id

let aggregate signals =
  signals
  |> List.map (fun s -> s.weight)
  |> List.fold_left (+.) 0.0

let best_signal signals =
  match signals with
  | [] -> Recency
  | _ ->
      signals
      |> List.sort (fun a b -> Float.compare b.weight a.weight)
      |> List.hd
      |> fun s -> s.match_kind

let rank query ~now ~cwd ~repo_root session =
  let signals = compute_signals query ~cwd ~repo_root session in
  let base = aggregate signals in
  let recency = recency_bonus ~now session.updated_at in
  { session; score = base +. recency; match_kind = best_signal signals }

let sort_ranked ranked =
  ranked
  |> List.stable_sort (fun left right -> Float.compare right.score left.score)
```

### Empty query behavior

When `query.text = ""`, skip id_prefix/substring/fuzzy signals. The result is all sessions ranked by: exact_cwd > same_repo > active > recency. Sessions admitted only by the recency term use `match_kind = Recency`. This gives the "just opened sessy, show me what's relevant" default.

### Searchable fields (metadata tier)

For substring and fuzzy matching, concatenate:
- `Session_id.to_string session.id`
- `Option.value ~default:"" session.title`
- `Option.value ~default:"" session.first_prompt`
- `session.cwd`
- `Option.value ~default:"" session.project_key`

---

## Error handling strategy

### Principle: Result everywhere, exceptions nowhere

All errors use `(value, error) result`. No exceptions in Layers 0–4.
Layer 5 (Shell) wraps external calls that may throw in immediate `try ... with`.

### Error types per layer

```
Layer 0: parse_error, config_error          — domain error vocabulary
Layer 1: uses Layer 0 errors, no new types  — transforms never fail on valid domain types
Layer 2: (session list, parse_error) result — adapters may fail to parse
Layer 3: no errors                          — index operations always succeed on valid data
Layer 4: (cli_action, string) result        — CLI parsing may fail with user-facing message
Layer 5: [`Io_error of string]              — IO operations may fail
```

### Error propagation

```ocaml
(* Pattern: bind through results in pipelines *)
let load_sessions config =
  config.sources
  |> List.map (fun src ->
    read_file (expand_home src.history_path)       (* Layer 5: may fail *)
    |> Result.map (adapter_for src.tool).parse_history  (* Layer 2: may fail *)
    |> Result.join)                                (* flatten Result(Result(...)) *)
  |> partition_results                              (* collect oks, log errors *)
```

### Graceful degradation

- If one adapter fails (e.g., Codex not installed → no history file), log warning, proceed with other sources.
- If config file is missing, use built-in defaults.
- If a single JSONL line fails to parse, skip it, parse the rest.
- Never crash on bad data. Partial results are better than no results.

---

## Adapter data format specifications

### Claude Code history.jsonl

Source: `~/.claude/history.jsonl`

Each line is a JSON object:
```json
{
  "sessionId": "abc123-def456-...",
  "projectKey": "/Users/foo/Repos/project",
  "displayTitle": "Fix the login bug",
  "lastModified": 1712345678000,
  "model": "claude-sonnet-4-20250514"
}
```

Session detail: `~/.claude/projects/<PROJECT_KEY_HASH>/<SESSION_ID>.jsonl`
Each line is a conversation turn (user/assistant message).

Active sessions: `~/.claude/sessions/<SESSION_ID>.json` — PID file.

### Codex history.jsonl

Source: `~/.codex/history.jsonl`

Each line is a JSON object:
```json
{
  "session_id": "rollout-abc123-...",
  "cwd": "/Users/foo/Repos/project",
  "prompt": "Fix the login bug",
  "timestamp": "2025-04-05T12:34:56Z",
  "model": "codex-1"
}
```

Session detail: `~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-...jsonl`

**Important:** These formats are observed from codedash source code and may change. Adapter paths are overrideable via config. First real task is to inspect actual files on the user's machine and adjust.

---

## Minttea integration pattern

Minttea implements the Elm Architecture (TEA). Our Layer 4 maps directly to it.

### Minttea's contract

```ocaml
(* Minttea expects this module signature *)
module type App = sig
  type model
  type msg

  val init : unit -> model * msg Cmd.t
  val update : msg -> model -> model * msg Cmd.t
  val view : model -> string
end
```

### Our adapter (in Layer 5: runtime.ml)

```ocaml
(* Bridge between our pure Layer 4 and Minttea's runtime *)
module Sessy_app = struct
  type model = Ui.Model.t
  type msg = Ui.Msg.t

  let init () =
    let index = (* loaded by shell before TUI starts *) in
    let config = (* loaded by shell *) in
    let model = Ui.init index config ~cwd ~repo_root in
    (model, Cmd.none)

  let update msg model =
    let model', cmd = Ui.update model msg in
    (* Convert our cmd to Minttea side effects *)
    let minttea_cmd = match cmd with
      | Ui.Noop -> Cmd.none
      | Ui.Exit -> Cmd.quit
      | Ui.Launch launch_cmd ->
        Cmd.quit_with (fun () -> Shell.Process.spawn launch_cmd)
      | Ui.Copy_to_clipboard text ->
        Cmd.exec (fun () -> Shell.clipboard_copy text)
      | _ -> Cmd.none
    in
    (model', minttea_cmd)

  let view model = Ui.view model
end

let run_tui index config =
  let app = Minttea.app (module Sessy_app) in
  Minttea.start app
```

### Key invariant

Our `Ui.update` is pure — it returns `(model, cmd)` where `cmd` is data.
The Minttea adapter in Layer 5 translates `cmd` data into actual Minttea side-effect commands.
This preserves testability: we can test `Ui.update` without a terminal.

---

## Dune build files

### dune-project (root)

```lisp
(lang dune 3.16)
(name sessy)
(generate_opam_files true)

(package
 (name sessy)
 (synopsis "Terminal-native AI session switcher for Claude Code and Codex")
 (depends
  (ocaml (>= 5.2))
  (dune (>= 3.16))
  (yojson (>= 2.1))
  (ppx_yojson_conv (>= 0.17))
  (otoml (>= 1.0))
  (eio_main (>= 1.0))
  (minttea (>= 0.0.2))
  (alcotest (and (>= 1.7) :with-test))))
```

### bin/dune

```lisp
(executable
 (name main)
 (public_name sessy)
 (libraries sessy_shell))
```

### lib/domain/dune

```lisp
(library
 (name sessy_domain)
 (public_name sessy.domain))
```

### lib/core/dune

```lisp
(library
 (name sessy_core)
 (public_name sessy.core)
 (libraries sessy_domain))
```

### lib/adapter/dune

```lisp
(library
 (name sessy_adapter)
 (public_name sessy.adapter)
 (libraries sessy_domain sessy_core yojson)
 (preprocess (pps ppx_yojson_conv)))
```

### lib/index/dune

```lisp
(library
 (name sessy_index)
 (public_name sessy.index)
 (libraries sessy_domain sessy_core))
```

### lib/ui/dune

```lisp
(library
 (name sessy_ui)
 (public_name sessy.ui)
 (libraries sessy_domain sessy_core sessy_index))
```

### lib/shell/dune

```lisp
(library
 (name sessy_shell)
 (public_name sessy.shell)
 (libraries sessy_domain sessy_ui sessy_adapter sessy_index
            eio_main otoml minttea))
```

### test/dune

```lisp
(test
 (name test_main)
 (libraries sessy_domain sessy_core sessy_adapter sessy_index sessy_ui
            alcotest)
 (preprocess (pps ppx_yojson_conv)))
```
