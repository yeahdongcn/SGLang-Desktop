#!/usr/bin/env bash
# Extract a runtime to a fresh path and prove that no build path is required.
set -Eeuo pipefail
IFS=$'\n\t'

if [[ $# -ne 1 || ! -f "$1" ]]; then
  printf 'Usage: %s RUNTIME_ARCHIVE\n' "$0" >&2
  exit 2
fi

readonly ARCHIVE="$(cd -- "$(dirname -- "$1")" && pwd -P)/$(basename -- "$1")"
readonly VERIFY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sglang-runtime-relocated.XXXXXX")"
cleanup() {
  rm -rf -- "$VERIFY_ROOT"
}
trap cleanup EXIT

tar -xzf "$ARCHIVE" -C "$VERIFY_ROOT"
ROOT_COUNT="$(find "$VERIFY_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
if [[ "$ROOT_COUNT" != "1" ]]; then
  printf 'Expected exactly one top-level runtime directory.\n' >&2
  exit 1
fi

readonly RUNTIME_ROOT="$(find "$VERIFY_ROOT" -mindepth 1 -maxdepth 1 -type d -print -quit)"
"$RUNTIME_ROOT/bin/sgl-omni" --help >/dev/null
"$RUNTIME_ROOT/bin/runtime-doctor"

if grep -R -I -l -E '/Users/|/private/var/folders/|/opt/homebrew' \
  "$RUNTIME_ROOT/bin" "$RUNTIME_ROOT/runtime.json"; then
  printf 'Relocated runtime contains a forbidden build-machine path.\n' >&2
  exit 1
fi

printf 'Relocation verified: %s\n' "$RUNTIME_ROOT"
