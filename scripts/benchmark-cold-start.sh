#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
OUTPUT="$(mktemp "${TMPDIR:-/tmp}/sessy-bench.XXXXXX")"
OS="$(uname -s)"
ARCH="$(uname -m)"

cleanup() {
  rm -f "$OUTPUT"
}

trap cleanup EXIT

default_binary() {
  case "$OS" in
    Darwin)
      printf '%s\n' "$ROOT/dist/sessy-darwin-$ARCH/sessy"
      ;;
    Linux)
      printf '%s\n' "$ROOT/dist/sessy-linux-$ARCH-musl/sessy"
      ;;
    *)
      printf '%s\n' "$ROOT/_build/default/bin/main.exe"
      ;;
  esac
}

BINARY="${1:-$(default_binary)}"

cd "$ROOT"

if [[ ! -x "$BINARY" ]]; then
  dune build --profile release ./bin/main.exe
  BINARY="$ROOT/_build/default/bin/main.exe"
fi

printf 'benchmarking %s list --json\n' "$BINARY"

for run in 1 2 3; do
  printf 'run %s\n' "$run"
  /usr/bin/time -p "$BINARY" list --json >"$OUTPUT"
done

wc -c "$OUTPUT"
