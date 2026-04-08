# Spec and build

## Configuration
- **Artifacts Path**: {@artifacts_path} → `.zenflow/tasks/{task_id}`

---

## Agent Instructions

Ask the user questions when anything is unclear or needs their input. This includes:
- Ambiguous or incomplete requirements
- Technical decisions that affect architecture or user experience
- Trade-offs that require business context

Do not make assumptions on important decisions — get clarification first.

---

## Workflow Steps

### [x] Step: Technical Specification
<!-- chat-id: 668b5f5b-d9e2-475c-bca0-9466721f71e8 -->

Assess the task's difficulty, as underestimating it leads to poor outcomes.
- easy: Straightforward implementation, trivial bug fix or feature
- medium: Moderate complexity, some edge cases or caveats to consider
- hard: Complex logic, many caveats, architectural considerations, or high-risk changes

Create a technical specification for the task that is appropriate for the complexity level:
- Review the existing codebase architecture and identify reusable components.
- Define the implementation approach based on established patterns in the project.
- Identify all source code files that will be created or modified.
- Define any necessary data model, API, or interface changes.
- Describe verification steps using the project's test and lint commands.

Save the output to `{@artifacts_path}/spec.md` with:
- Technical context (language, dependencies)
- Implementation approach
- Source code structure changes
- Data model / API / interface changes
- Verification approach

If the task is complex enough, create a detailed implementation plan based on `{@artifacts_path}/spec.md`:
- Break down the work into concrete tasks (incrementable, testable milestones)
- Each task should reference relevant contracts and include verification steps
- Replace the Implementation step below with the planned tasks

Rule of thumb for step size: each step should represent a coherent unit of work (e.g., implement a component, add an API endpoint, write tests for a module). Avoid steps that are too granular (single function).

Important: unit tests must be part of each implementation task, not separate tasks. Each task should implement the code and its tests together, if relevant.

Save to `{@artifacts_path}/plan.md`. If the feature is trivial and doesn't warrant this breakdown, keep the Implementation step below as is.

---

Detailed implementation plan derived from `.context/implementation-plan.md` and `{@artifacts_path}/spec.md`.

For every step below:
- Apply minimum sufficient FPF.
- Use the `h-reason` skill for non-mechanical decisions, especially boundary choices, data-format mapping, runtime integration, and packaging trade-offs.
- Keep unit tests inside the same step as the implementation they verify.

### [ ] Step: Foundation scaffold and live-format validation
<!-- chat-id: 23c89a1d-8362-458a-8b0c-a0cd51c8c3aa -->

- Scope: T0.1-T0.4 from `.context/implementation-plan.md`.
- Do: create `.ocamlformat`, `dune-project`, `sessy.opam`, the initial dune directory structure, stub libraries, and `.gitignore`; verify the OCaml toolchain and install dependencies; inspect live Claude and Codex files and create sanitized fixtures.
- Invariants: no production logic before the scaffold exists; dune dependencies must match the architecture; fixture formats must be evidence-based, not guessed.
- Verify: `ocaml --version`, `dune --version`, `opam install . --deps-only`, `dune build`, and fixture parse sanity checks.
- Evidence: live history inspection confirmed Claude history currently uses `display`/`project`/`timestamp`/`sessionId?` and Codex history uses `session_id`/`ts`/`text`; sanitized fixtures were created from those observed shapes.
- Blocked: the scaffold currently builds only after omitting `minttea`, so this step is not accepted yet.
- Runtime evidence: published `minttea 0.0.2` fails on the local OCaml 5.4.1 environment because it pins `riot 0.0.5` (`ocaml < 5.3`).
- Runtime evidence: upstream `minttea` tag `0.0.3` and current `main` still fail on OCaml 5.4 here through the `riot -> config -> ppxlib < 0.36` chain, even when tested in isolated temporary switches with pinned sources.
- Next decision required: either approve an updated runtime/package choice in the architecture, or produce a verified pinned package set that restores `minttea` without lowering the OCaml 5.4 floor.

### [x] Step: Domain kernel
<!-- chat-id: c6d13a50-8260-4c66-aca3-780a9dce6618 -->

- Scope: T1.1-T1.4.
- Do: implement `Sessy_domain` types, opaque `Session_id`, launch/config types, and domain error vocabulary; add the public `.mli`.
- Invariants: Layer 0 contains vocabulary only, not business logic or IO; invalid states should be made inexpressible in the type system.
- Verify: `dune build` plus direct tests for `Session_id` and representative record construction.

### [x] Step: Core config, search, and launch logic
<!-- chat-id: b9bdcf8d-ad0e-4085-a776-0d49ec77d8d6 -->

- Scope: T2.1-T2.5.
- Do: implement pure config resolution, placeholder expansion, fuzzy matching, ranking, and filtering; expose the core public API.
- Invariants: Layer 1 stays pure; ranking follows the additive signal model from the architecture; launch commands are argv-based, not shell-string based.
- Verify: `dune test` for config merge, template expansion, ranking order, empty-query behavior, and filters.
- Evidence: `lib/core/` now contains the Layer 1 modules for config merge, launch assembly, fuzzy matching, ranking, and the public `Sessy_core` facade.
- Evidence: `dune build` and `dune test` both pass with the new acceptance coverage in `test/test_main.ml`.

### [x] Step: Source adapters
<!-- chat-id: 3b6a63c8-e041-4bc8-8e6d-244b23a59bdf -->

- Scope: T3.1-T3.4.
- Do: define the `SOURCE` contract, implement Claude and Codex parsers over string input, and expose adapter dispatch.
- Invariants: adapters stay pure and degrade gracefully on malformed lines; upstream storage differences must be resolved against live fixtures, not assumptions.
- Verify: fixture-based adapter tests for both tools, including malformed-line resilience.
- Evidence: `lib/adapter/` now contains the private `Source` contract, shared decode helpers, Claude and Codex parsers, and the public `Sessy_adapter` facade with tool dispatch.
- Evidence: live detail inspection confirmed Claude transcript lines carry top-level `sessionId`/`cwd`/`timestamp` with nested `message.content`, while Codex transcript lines use top-level `timestamp` and nested `payload.id`/`payload.cwd`/`payload.content`.
- Evidence: `dune build` and `dune test` both pass with fixture-backed coverage for history parsing, malformed-line skipping, detail hydration, and adapter dispatch.

### [x] Step: Index and first CLI vertical slice
<!-- chat-id: d030d253-2428-43d6-b136-4d97c340cfea -->

- Scope: T4.1-T5.8.
- Do: implement the immutable index; add CLI action parsing and dispatch for the initial read path; add shell filesystem/config/process wrappers; wire `main` so `sessy list --json` works end-to-end; add the first E2E pipeline test.
- Invariants: the index coordinates core behavior rather than re-implementing it; shell code is thin and contains all effects; one broken source must not block the other.
- Verify: `dune test`, `dune exec sessy -- list --json`, and the first E2E fixture pipeline.
- Evidence: `lib/index/sessy_index.ml` and `lib/index/sessy_index.mli` now provide immutable build/search/find/refresh behavior with dedup-by-id and Layer 1 ranking coordination.
- Evidence: `lib/ui/sessy_ui.ml` and `lib/ui/sessy_ui.mli` now provide the initial pure CLI read-path surface for `sessy` and `sessy list --json`, plus plain/JSON formatting.
- Evidence: `lib/shell/` now contains thin filesystem, config-loader, and process wrappers; `Sessy_shell.run` loads config, tolerantly loads source histories, builds the index, parses CLI args, and executes read-path commands.
- Evidence: `test/test_main.ml` now covers index semantics, CLI parsing/dispatch/formatting, shell config/source loading, and a fixture-backed E2E pipeline from source files to JSON output and launch expansion.
- Runtime evidence: `dune build`, `dune test`, and `dune exec sessy -- list --json` all succeed on the current machine.

### [ ] Step: CLI resume, preview, and diagnostics

- Scope: T5.9-T5.11.
- Do: implement `sessy last`, `sessy resume <id>`, `sessy preview <id>`, `sessy doctor`, and dry-run support.
- Invariants: session lookup failures become user-facing errors, not crashes; dry-run prints the exact argv-derived command; doctor stays read-only.
- Verify: `dune exec sessy -- last --dry-run`, `dune exec sessy -- resume <id> --dry-run`, `dune exec sessy -- preview <id>`, and `dune exec sessy -- doctor`.

### [ ] Step: TUI interaction layer

- Scope: T6.1-T6.6.
- Do: implement immutable TUI model/msg/cmd types, pure `init` and `update`, pure view rendering, the Minttea runtime bridge, preview pane, and the remaining keybindings.
- Invariants: Layers 0-4 remain pure; Layer 5 alone translates TUI commands into effects; preview layout must degrade gracefully on narrow terminals.
- Verify: unit tests for update behavior plus manual `dune exec sessy --` checks for filtering, preview toggle, copy, reload, quit, and launch.

### [ ] Step: Packaging, benchmarking, and release surface

- Scope: T7.1-T7.5.
- Do: measure cold-start latency, build release binaries for macOS and Linux, add CI, and write the user-facing README.
- Invariants: release automation must exercise the same build and test paths used locally; benchmark evidence must be measured, not predicted.
- Verify: `time dune exec sessy -- list --json`, platform build checks, CI green runs, and README-driven install sanity checks.
