# Sessy Technical Specification

## Complexity

`hard`

Why this is hard:
- The repository is effectively greenfield. Only context and task artifacts exist today.
- The product spans multiple abstraction levels: build scaffold, pure domain/core logic, two file-format adapters, an immutable index, CLI flows, TUI runtime integration, and release packaging.
- Claude and Codex storage formats are external and may drift, so adapter design-time assumptions must be converted into runtime evidence before parser contracts are frozen.

## Problem Frame

- Target system: `sessy`, a terminal-native session switcher and launcher for Claude Code and Codex.
- Enabling system: dune/opam scaffold, fixtures, tests, CI, and release packaging needed to build confidence in the target system.
- Source of truth for the implementation shape:
  - `.context/prd.md` defines product scope and non-goals.
  - `.context/architecture.md` defines the layered architecture, dependency graph, ranking model, config format, and testing strategy.
  - `.context/implementation-plan.md` defines the bottom-up task order and acceptance criteria.
  - `.context/slideument.md` reinforces the operating loop of problem framing, multi-criteria acceptance, variant comparison, and evidence after action.
- FPF operating rules for implementation:
  - Treat this specification as design-time guidance, not proof.
  - Keep target-system concerns separate from enabling-system concerns.
  - Land small reversible milestones and gather evidence at each acceptance gate.
  - Use the `h-reason` skill for non-mechanical choices, especially adapter field mapping, Minttea boundary design, and packaging trade-offs.

## Technical Context

- Repository state: only `.context`, `.haft`, `.zenflow`, and git metadata exist. No OCaml source tree is present yet.
- Language/runtime target: OCaml 5.2+ with dune 3.16+ and opam-managed dependencies.
- Planned dependencies from `.context/architecture.md`:
  - `yojson`
  - `ppx_yojson_conv`
  - `otoml`
  - `eio_main`
  - `minttea`
  - `alcotest`
- External inputs:
  - `~/.claude/history.jsonl`
  - `~/.claude/projects/...`
  - `~/.claude/sessions/...`
  - `~/.codex/history.jsonl`
  - `~/.codex/sessions/...`
  - `~/.config/sessy/config.toml`
  - `./.sessy.toml`
- First meaningful user-visible milestone: `sessy list --json` works end-to-end against real local history files after the CLI vertical slice.
- Explicit v1 non-goals: browser UI, dashboards, replay, analytics, and adapters beyond Claude and Codex.

## Implementation Approach

1. Start with scaffold and evidence.
   Create the dune/opam project skeleton, test layout, and fixtures first. Before adapter logic is locked in, inspect real local Claude and Codex files and sanitize representative fixtures. This converts the storage-format assumption into evidence.

2. Build from the functional core outward.
   Follow the architecture's bottom-up order: Layer 0 domain types, Layer 1 pure transformations, Layer 2 pure adapters, Layer 3 immutable index, Layer 4 pure UI logic, Layer 5 effect shell.

3. Keep one abstraction level per layer.
   Layers 0 through 4 stay pure. Layer 5 is the only IO boundary. Dune dependencies must follow the declared graph with no skip-level access.

4. Encode invariants in types.
   Use closed variants for `tool`, `scope`, `search_mode`, and `exec_mode`; opaque `Session_id.t`; and non-empty argv as `string * string list`.

5. Ship the first vertical slice before the TUI.
   Treat the CLI path as the first end-to-end product: parse fixtures and live history, build the index, support `list --json`, `preview`, `resume`, `last`, and `doctor`, and verify the launch command engine with dry-run support.

6. Keep the runtime shell thin.
   Minttea and process spawning belong in Layer 5 only. If runtime APIs differ from the current architecture sketch, adapt the shell bridge rather than leaking effects into pure layers.

7. Add tests with each milestone, not at the end.
   Follow the architecture test strategy: E2E for the main pipeline first, then adapter parsing, then unit tests for pure logic.

8. Normalize library facades early.
   The architecture and context plan reference several `.mli`-only public facades such as `sessy_core`, `sessy_adapter`, `sessy_ui`, and `sessy_shell`. Default implementation choice: add matching `.ml` facade modules or explicit dune handling for interface-only modules before the build grows, so the module graph stays ordinary and explicit.

## Source Code Structure Changes

Planned repository additions and modifications:

- Repository root
  - `.gitignore`
  - `.ocamlformat`
  - `dune-project`
  - `sessy.opam`
  - `README.md`
  - `.github/workflows/ci.yml`

- Executable entrypoint
  - `bin/dune`
  - `bin/main.ml`

- Layer 0: domain
  - `lib/domain/dune`
  - `lib/domain/sessy_domain.ml`
  - `lib/domain/sessy_domain.mli`

- Layer 1: core
  - `lib/core/dune`
  - `lib/core/config_merge.ml`
  - `lib/core/launch.ml`
  - `lib/core/fuzzy.ml`
  - `lib/core/rank.ml`
  - `lib/core/sessy_core.ml`
  - `lib/core/sessy_core.mli`

- Layer 2: adapters
  - `lib/adapter/dune`
  - `lib/adapter/source.ml`
  - `lib/adapter/source.mli`
  - `lib/adapter/claude.ml`
  - `lib/adapter/codex.ml`
  - `lib/adapter/sessy_adapter.ml`
  - `lib/adapter/sessy_adapter.mli`

- Layer 3: index
  - `lib/index/dune`
  - `lib/index/sessy_index.ml`
  - `lib/index/sessy_index.mli`

- Layer 4: UI
  - `lib/ui/dune`
  - `lib/ui/model.ml`
  - `lib/ui/update.ml`
  - `lib/ui/view.ml`
  - `lib/ui/cli.ml`
  - `lib/ui/sessy_ui.ml`
  - `lib/ui/sessy_ui.mli`

- Layer 5: shell
  - `lib/shell/dune`
  - `lib/shell/fs.ml`
  - `lib/shell/process.ml`
  - `lib/shell/runtime.ml`
  - `lib/shell/config_loader.ml`
  - `lib/shell/sessy_shell.ml`
  - `lib/shell/sessy_shell.mli`

- Tests and fixtures
  - `test/dune`
  - `test/core/...`
  - `test/adapter/...`
  - `test/e2e/...`
  - `fixtures/claude_history.jsonl`
  - `fixtures/codex_history.jsonl`
  - `fixtures/config.toml`

## Data Model, API, and Interface Changes

- Domain model
  - Introduce typed concepts for `tool`, `Session_id`, `session`, `query`, `match_kind`, `ranked`, `launch_cmd`, `profile`, `source_config`, and `config`.
  - Keep invalid states unrepresentable where possible.

- Core interfaces
  - `Sessy_core` exposes pure config resolution, template expansion, fuzzy matching, ranking, and filtering.
  - Ranking follows the additive signal model from `.context/architecture.md`, including current directory, repo, active status, ID prefix, substring, fuzzy match, and recency decay.

- Adapter interface
  - Define a pure `SOURCE` contract that parses file contents, not paths.
  - Provide Claude and Codex adapters plus tool-to-adapter dispatch.

- Index interface
  - Provide an immutable search index that deduplicates sessions, coordinates filtering/ranking, and exposes lookup by typed session ID.

- UI interface
  - CLI surface for `sessy`, `sessy list`, `sessy list --json`, `sessy last`, `sessy resume <id>`, `sessy preview <id>`, `sessy doctor`, and `sessy reindex`.
  - TUI model with pure `init`, `update`, and `view` semantics and side-effect commands encoded as data.

- Config surface
  - TOML-based config layers: built-in defaults, user config, project config, optional profile, and CLI overrides.
  - Launch commands remain argv-based, not shell-string based.

- External compatibility note
  - There is no stable public API to preserve yet. This is the first implementation, so interface clarity matters more than backward compatibility.

## Verification Approach

- Toolchain and scaffold verification
  - Confirm `.gitignore` covers generated artifacts before build-producing commands.
  - Run `ocaml --version`.
  - Run `dune --version`.
  - Run `opam install . --deps-only`.
  - Run `dune build`.

- Formatting and static checks
  - Add `.ocamlformat` and use `dune fmt` once the scaffold exists.
  - Keep `.mli` abstraction barriers compiling at each phase.

- Phase-level automated verification
  - `dune test` for E2E, adapter, and pure-core checks.
  - Fixture-based validation for Claude and Codex parsing.
  - Ranking tests covering empty-query behavior and signal ordering.
  - Launch assembly tests covering placeholder substitution and profile overrides.

- End-to-end CLI verification
  - `dune exec sessy -- list --json`
  - `dune exec sessy -- preview <session-id>`
  - `dune exec sessy -- last --dry-run`
  - `dune exec sessy -- resume <session-id> --dry-run`
  - `dune exec sessy -- doctor`

- Manual TUI verification
  - `dune exec sessy --`
  - Validate filtering, cursor movement, preview toggle, quit, and launch behavior.

- Release verification
  - `time dune exec sessy -- list --json` against representative local history.
  - CI build and test on macOS and Linux.

## Risks and Required Runtime Validation

- Real Claude and Codex storage formats may differ from the context examples. T0.4 must inspect live files before finalizing adapter field mapping.
- Minttea's actual API surface may differ from the architecture sketch. Keep the adaptation inside Layer 5.
- Static linking on macOS and Linux may need platform-specific build adjustments not visible yet from the current repository state.
- The context plan assumes public facade modules that are not fully enumerated in the architecture tree. Resolve this explicitly in the scaffold phase to avoid churn later.
