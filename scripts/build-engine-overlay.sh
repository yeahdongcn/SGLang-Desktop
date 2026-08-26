#!/usr/bin/env bash
# Build a small pure-Python engine overlay for an already published base.
#
# This intentionally does not resolve dependencies. The base compatibility
# lock is supplied by the caller and must already contain every native/runtime
# dependency needed by the overlay.
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly OMNI_SOURCE="${SGLANG_OMNI_SOURCE_DIR:-$REPO_ROOT/../sglang-omni}"
readonly SGLANG_SOURCE="${SGLANG_SOURCE_DIR:-}"
readonly BASE_RUNTIME_ID="${SGLANG_BASE_RUNTIME_ID:-}"
readonly COMPATIBILITY_ID="${SGLANG_COMPATIBILITY_ID:-}"
readonly OUTPUT_ROOT="${SGLANG_OVERLAY_OUTPUT_DIR:-$REPO_ROOT/artifacts/overlays}"
readonly OVERLAY_VERSION="${SGLANG_OVERLAY_VERSION:-$(git -C "$OMNI_SOURCE" rev-parse --short HEAD)}"
readonly WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sglang-engine-overlay.XXXXXX")"
readonly OVERLAY_ROOT="$WORK_ROOT/sglang-omni-overlay-$OVERLAY_VERSION-macos-arm64"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  printf 'Overlay builds require Apple Silicon macOS.\n' >&2
  exit 1
fi
[[ -n "$BASE_RUNTIME_ID" && -n "$COMPATIBILITY_ID" ]] || {
  printf 'Set SGLANG_BASE_RUNTIME_ID and SGLANG_COMPATIBILITY_ID.\n' >&2
  exit 1
}
sources=("$OMNI_SOURCE")
if [[ -n "$SGLANG_SOURCE" ]]; then
  sources+=("$SGLANG_SOURCE")
fi
for source in "${sources[@]}"; do
  [[ "$(git -C "$source" rev-parse --is-inside-work-tree 2>/dev/null || true)" == "true" ]] || {
    printf 'Expected a Git checkout: %s\n' "$source" >&2
    exit 1
  }
  [[ -z "$(git -C "$source" status --porcelain)" ]] || {
    printf 'Overlay source checkout must be clean: %s\n' "$source" >&2
    exit 1
  }
done

cleanup() { rm -rf -- "$WORK_ROOT"; }
trap cleanup EXIT
mkdir -p "$OVERLAY_ROOT/packages" "$OVERLAY_ROOT/metadata"

readonly OMNI_COMMIT="$(git -C "$OMNI_SOURCE" rev-parse HEAD)"
readonly SGLANG_COMMIT="${SGLANG_SOURCE:+$(git -C "$SGLANG_SOURCE" rev-parse HEAD)}"
readonly BUILD_ROOT="$WORK_ROOT/build"
mkdir -p "$BUILD_ROOT"

build_wheel() {
  local source="$1"
  local package="$2"
  local pretend_version="$3"
  local project_root="$WORK_ROOT/$package"
  mkdir -p "$project_root"
  git -C "$source" archive --format=tar HEAD | tar -xf - -C "$project_root"
  if [[ "$package" == "sglang" ]]; then
    cp "$project_root/python/pyproject_other.toml" "$project_root/python/pyproject.toml"
    project_root="$project_root/python"
  fi
  SETUPTOOLS_SCM_PRETEND_VERSION="$pretend_version" \
    uv build --wheel --out-dir "$BUILD_ROOT/$package" "$project_root"
}

build_wheel "$OMNI_SOURCE" "sglang-omni" "$OVERLAY_VERSION"
if [[ -n "$SGLANG_SOURCE" ]]; then
  build_wheel "$SGLANG_SOURCE" "sglang" "$OVERLAY_VERSION"
fi
find "$BUILD_ROOT" -type f -name '*.whl' -exec cp {} "$OVERLAY_ROOT/packages/" \;

cat >"$OVERLAY_ROOT/runtime.json" <<JSON
{
  "schemaVersion": 1,
  "id": "sglang-omni-overlay",
  "displayName": "SGLang-Omni Engine Overlay",
  "engine": "sglang-omni",
  "version": "$OVERLAY_VERSION",
  "platform": "macos",
  "architecture": "arm64",
  "minimumMacOSVersion": "14.0",
  "channel": "nightly",
  "distribution": "prebuilt",
  "artifactKind": "engineOverlay",
  "baseRuntimeID": "$BASE_RUNTIME_ID",
  "compatibilityID": "$COMPATIBILITY_ID",
  "sourceCommit": "$OMNI_COMMIT",
  "containsNativeCode": false,
  "entrypoint": "bin/sgl-omni",
  "capabilities": ["openai-api", "qwen3-asr"]
}
JSON

cat >"$OVERLAY_ROOT/metadata/provenance.json" <<JSON
{
  "sglangCommit": "${SGLANG_COMMIT:-}",
  "sglangOmniCommit": "$OMNI_COMMIT",
  "baseRuntimeID": "$BASE_RUNTIME_ID",
  "compatibilityID": "$COMPATIBILITY_ID"
}
JSON

mkdir -p "$OVERLAY_ROOT/bin"
cat >"$OVERLAY_ROOT/bin/sgl-omni" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
readonly OVERLAY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
printf 'This overlay must be materialized by SGLang Desktop with its compatible base runtime.\n' >&2
exit 78
SH
chmod +x "$OVERLAY_ROOT/bin/sgl-omni"

mkdir -p "$OUTPUT_ROOT"
readonly ARCHIVE="$OUTPUT_ROOT/$(basename "$OVERLAY_ROOT").tar.gz"
tar -czf "$ARCHIVE" -C "$WORK_ROOT" "$(basename "$OVERLAY_ROOT")"
shasum -a 256 "$ARCHIVE" >"$ARCHIVE.sha256"
printf 'Built engine overlay: %s\n' "$ARCHIVE"
