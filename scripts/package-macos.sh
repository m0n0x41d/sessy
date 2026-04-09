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
PACKAGE_DIR="$DIST_DIR/sessy-darwin-$ARCH"
ARCHIVE_PATH="$DIST_DIR/sessy-${VERSION}-darwin-${ARCH}.tar.gz"
TARGET_PATH="$PACKAGE_DIR/sessy"

if [[ "$OS" != "Darwin" ]]; then
  printf 'package-macos.sh must run on macOS, got %s\n' "$OS" >&2
  exit 1
fi

rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR"

cd "$ROOT"

dune build --profile release ./bin/main.exe

cp "$ROOT/_build/default/bin/main.exe" "$TARGET_PATH"
strip -x "$TARGET_PATH" 2>/dev/null || true

"$TARGET_PATH" list --json >/dev/null
otool -L "$TARGET_PATH"

tar -C "$DIST_DIR" -czf "$ARCHIVE_PATH" "$(basename "$PACKAGE_DIR")"
ls -lh "$TARGET_PATH" "$ARCHIVE_PATH"
