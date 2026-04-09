# sessy

`sessy` is a terminal-native session picker and launcher for Claude Code and Codex.

It stays in the shell: no browser, no server, no network round-trips, and a single binary per platform.

## Install

CI produces two release archives:

- `sessy-<version>-darwin-arm64.tar.gz`
- `sessy-<version>-linux-x86_64-musl.tar.gz`

Extract the archive for your platform, move `sessy` onto your `PATH`, then verify the install:

```sh
tar -xzf sessy-<version>-darwin-arm64.tar.gz
install -m 0755 sessy-darwin-arm64/sessy /usr/local/bin/sessy
sessy doctor
```

You can also build from source with opam:

```sh
opam install . --deps-only --with-test
opam exec -- dune build --profile release ./bin/main.exe
install -m 0755 _build/default/bin/main.exe "$(opam var bin)/sessy"
```

## Quick Start

If Claude Code or Codex already use their default local storage paths, `sessy` works without extra configuration.

```sh
sessy
sessy last
sessy list --json
```

Useful follow-ups:

- `sessy resume <id>` resumes a specific session.
- `sessy preview <id>` shows the hydrated metadata and launch command.
- `sessy doctor` checks config, source paths, parser health, and tool binaries.
- `sessy last --dry-run` prints the exact command instead of launching it.

## Configuration

Sessy reads configuration from:

- `~/.config/sessy/config.toml`
- `./.sessy.toml`

No config is required if you use the default Claude Code and Codex paths. A small override looks like this:

```toml
[ui]
scope = "repo"
preview = true
```

The full example config lives in [fixtures/config.toml](fixtures/config.toml).

## Release Surface

- macOS packages are native single-file binaries for the runner architecture. They do not require OCaml or opam on the destination machine.
- Linux packages target `x86_64` with a musl static build path.
- CI builds, tests, packages, and uploads both archives on every push and pull request.

## Contributors

The product architecture is documented in [.context/architecture.md](.context/architecture.md).
