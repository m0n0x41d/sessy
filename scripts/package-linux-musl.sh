#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
OS="$(uname -s)"
ARCH="$(uname -m)"

default_version() {
  git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || printf 'dev'
}

VERSION="${1:-$(default_version)}"
DIST_DIR="$ROOT/dist"
PACKAGE_DIR="$DIST_DIR/sessy-linux-$ARCH-musl"
ARCHIVE_PATH="$DIST_DIR/sessy-${VERSION}-linux-${ARCH}-musl.tar.gz"
TARGET_PATH="$PACKAGE_DIR/sessy"

if [[ "$OS" != "Linux" ]]; then
  printf 'package-linux-musl.sh must run on Linux, got %s\n' "$OS" >&2
  exit 1
fi

rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR"

cd "$ROOT"

dune build --profile release ./bin/main.exe

cp "$ROOT/_build/default/bin/main.exe" "$TARGET_PATH"
strip --strip-unneeded "$TARGET_PATH" 2>/dev/null || true

"$TARGET_PATH" list --json >/dev/null
file "$TARGET_PATH"

LDD_OUTPUT="$(ldd "$TARGET_PATH" 2>&1 || true)"

printf '%s\n' "$LDD_OUTPUT"

if [[ "$LDD_OUTPUT" != *"not a dynamic executable"* ]] \
  && [[ "$LDD_OUTPUT" != *"statically linked"* ]]; then
  printf 'expected a static Linux binary, but ldd reported a dynamic executable\n' >&2
  exit 1
fi

tar -C "$DIST_DIR" -czf "$ARCHIVE_PATH" "$(basename "$PACKAGE_DIR")"
ls -lh "$TARGET_PATH" "$ARCHIVE_PATH"
