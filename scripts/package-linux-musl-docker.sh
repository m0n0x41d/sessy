#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT/dist"
PLATFORM="${PLATFORM:-linux/amd64}"
IMAGE="${IMAGE:-ocaml/opam:alpine-3.20-ocaml-5.4}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sessy-linux-dist.XXXXXX")"

default_version() {
  git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || printf 'dev'
}

VERSION="${1:-$(default_version)}"

mkdir -p "$DIST_DIR"
chmod 0777 "$STAGING_DIR"

docker run \
  --rm \
  --platform "$PLATFORM" \
  --env OPAMYES=1 \
  --volume "$ROOT:/src:ro" \
  --volume "$STAGING_DIR:/dist" \
  --workdir /src \
  "$IMAGE" \
  sh -lc "
    set -euo pipefail
    WORK_DIR=/home/opam/work

    sudo apk add --no-cache file linux-headers rsync

    mkdir -p \"\$WORK_DIR\"
    rsync -a /src/ \"\$WORK_DIR\"/
    cd \"\$WORK_DIR\"

    opam repository set-url default https://opam.ocaml.org \
      || opam repository add default https://opam.ocaml.org
    opam update
    opam switch create sessy-static \
      --packages=ocaml-variants.5.4.0+options,ocaml-option-musl,ocaml-option-static
    eval \"\$(opam env --switch=sessy-static --set-switch)\"

    opam install . --deps-only --with-test
    opam exec -- dune build @runtest
    VERSION=\"$VERSION\" opam exec -- ./scripts/package-linux-musl.sh \"$VERSION\"

    cp -R dist/. /dist/
  "

cp -R "$STAGING_DIR"/. "$DIST_DIR"/
