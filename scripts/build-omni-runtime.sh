#!/usr/bin/env bash
# Build a preinstalled, relocatable SGLang-Omni Apple Silicon runtime archive.
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly PBS_RELEASE="20260211"
readonly PYTHON_VERSION="3.12.12"
readonly PBS_ARCHIVE="cpython-${PYTHON_VERSION}+${PBS_RELEASE}-aarch64-apple-darwin-install_only.tar.gz"
readonly PBS_SHA256="20d98bd10cf59e3c16dc4e44b57be351b250fc1089e95b2839f440f79413ed47"
readonly PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}/${PBS_ARCHIVE//+/%2B}"
readonly PBS_ARCHIVE_PATH="${SGLANG_PBS_ARCHIVE_PATH:-}"
readonly PBS_EXPECTED_SHA256="${SGLANG_PBS_SHA256:-$PBS_SHA256}"
readonly PBS_VERSION_LABEL="${SGLANG_PBS_VERSION:-$PYTHON_VERSION}"
readonly SGLANG_SOURCE="${SGLANG_SOURCE_DIR:-$HOME/.cache/sglang-omni/sglang-v0.5.16}"
readonly OMNI_SOURCE="${SGLANG_OMNI_SOURCE_DIR:-$REPO_ROOT/../sglang-omni}"
readonly OUTPUT_ROOT="${SGLANG_RUNTIME_OUTPUT_DIR:-$REPO_ROOT/artifacts/runtimes}"
readonly RUNTIME_VERSION="${SGLANG_RUNTIME_VERSION:-0.1.0-apple.1}"
readonly RUNTIME_CHANNEL="${SGLANG_RUNTIME_CHANNEL:-nightly}"
readonly RUNTIME_NAME="sglang-omni-${RUNTIME_VERSION}-macos-arm64"
readonly FINAL_ARCHIVE="$OUTPUT_ROOT/${RUNTIME_NAME}.tar.gz"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  printf 'Runtime builds require Apple Silicon macOS.\n' >&2
  exit 1
fi
command -v uv >/dev/null 2>&1 || {
  printf 'The build machine requires a pinned uv installation.\n' >&2
  exit 1
}
command -v pkg-config >/dev/null 2>&1 || {
  printf 'The build machine requires pkg-config to build PyAV.\n' >&2
  exit 1
}
for source in "$SGLANG_SOURCE" "$OMNI_SOURCE"; do
  if [[ "$(git -C "$source" rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]]; then
    printf 'Expected a Git checkout: %s\n' "$source" >&2
    exit 1
  fi
  if [[ -n "$(git -C "$source" status --porcelain)" ]]; then
    printf 'Runtime source checkout must be clean: %s\n' "$source" >&2
    exit 1
  fi
done

readonly SGLANG_COMMIT="$(git -C "$SGLANG_SOURCE" rev-parse HEAD)"
readonly OMNI_COMMIT="$(git -C "$OMNI_SOURCE" rev-parse HEAD)"
readonly UV_VERSION="$(uv --version | awk '{print $2}')"
readonly WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sglang-omni-runtime.XXXXXX")"
readonly STAGE_ROOT="$WORK_ROOT/$RUNTIME_NAME"
readonly SGLANG_STAGE="$WORK_ROOT/sglang-source"
readonly OMNI_STAGE="$WORK_ROOT/omni-source"
readonly DEPENDENCY_OVERRIDES="$WORK_ROOT/dependency-overrides.txt"

cleanup() {
  rm -rf -- "$WORK_ROOT"
}
trap cleanup EXIT

mkdir -p \
  "$STAGE_ROOT/bin" \
  "$STAGE_ROOT/packages" \
  "$STAGE_ROOT/metadata" \
  "$STAGE_ROOT/licenses" \
  "$SGLANG_STAGE" \
  "$OMNI_STAGE" \
  "$OUTPUT_ROOT"

readonly PBS_DOWNLOAD="$WORK_ROOT/$PBS_ARCHIVE"
if [[ -n "$PBS_ARCHIVE_PATH" ]]; then
  [[ -f "$PBS_ARCHIVE_PATH" ]] || {
    printf 'PBS archive does not exist: %s\n' "$PBS_ARCHIVE_PATH" >&2
    exit 1
  }
  cp "$PBS_ARCHIVE_PATH" "$PBS_DOWNLOAD"
else
  curl --fail --location --retry 5 --output "$PBS_DOWNLOAD" "$PBS_URL"
fi
printf '%s  %s\n' "$PBS_EXPECTED_SHA256" "$PBS_DOWNLOAD" | shasum -a 256 --check
tar -xzf "$PBS_DOWNLOAD" -C "$WORK_ROOT"
mv "$WORK_ROOT/python" "$STAGE_ROOT/python"

git -C "$SGLANG_SOURCE" archive --format=tar HEAD | tar -xf - -C "$SGLANG_STAGE"
git -C "$OMNI_SOURCE" archive --format=tar HEAD | tar -xf - -C "$OMNI_STAGE"
install -m 644 "$SGLANG_STAGE/python/pyproject_other.toml" "$SGLANG_STAGE/python/pyproject.toml"

# The v0.5.16 MPS extra pins cache-dit 1.2.3 while the Omni application pins
# 1.3.0. The runtime builder resolves both projects together, so record the
# deliberate compatibility decision instead of allowing an arbitrary resolver
# choice. This file becomes part of build provenance below.
printf 'cache-dit==1.3.0\n' >"$DEPENDENCY_OVERRIDES"

"$SCRIPT_DIR/build-ffmpeg-runtime.sh" "$STAGE_ROOT/ffmpeg"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export PKG_CONFIG_PATH="$STAGE_ROOT/ffmpeg/lib/pkgconfig"
export DYLD_LIBRARY_PATH="$STAGE_ROOT/ffmpeg/lib"
SGLANG_BUILD_RUST_EXTS=none uv pip install \
  --python "$STAGE_ROOT/python/bin/python3" \
  --target "$STAGE_ROOT/packages" \
  --overrides "$DEPENDENCY_OVERRIDES" \
  --prerelease=allow \
  "$SGLANG_STAGE/python[all_mps]" \
  "$OMNI_STAGE"

# FFmpeg libraries use @rpath install names. Put their runtime location on the
# relocatable CPython executable's loader path, then restore its signature.
readonly PYTHON_REAL_BIN="$(realpath "$STAGE_ROOT/python/bin/python3")"
if ! otool -l "$PYTHON_REAL_BIN" | grep -F '@executable_path/../../ffmpeg/lib' >/dev/null; then
  install_name_tool -add_rpath '@executable_path/../../ffmpeg/lib' "$PYTHON_REAL_BIN"
fi
codesign --force --sign - "$PYTHON_REAL_BIN"

install -m 755 "$REPO_ROOT/runtime/runtime_doctor.py" "$STAGE_ROOT/metadata/runtime_doctor.py"

cat >"$STAGE_ROOT/bin/sgl-omni" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
readonly RUNTIME_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export PYTHONNOUSERSITE=1
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$RUNTIME_ROOT/packages"
export PATH="$RUNTIME_ROOT/ffmpeg/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export DYLD_LIBRARY_PATH="$RUNTIME_ROOT/ffmpeg/lib"
exec "$RUNTIME_ROOT/python/bin/python3" -s -m sglang_omni.cli "$@"
SH

cat >"$STAGE_ROOT/bin/runtime-doctor" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
readonly RUNTIME_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export PYTHONNOUSERSITE=1
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$RUNTIME_ROOT/packages"
export PATH="$RUNTIME_ROOT/ffmpeg/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export DYLD_LIBRARY_PATH="$RUNTIME_ROOT/ffmpeg/lib"
exec "$RUNTIME_ROOT/python/bin/python3" -s "$RUNTIME_ROOT/metadata/runtime_doctor.py" "$@"
SH
chmod +x "$STAGE_ROOT/bin/sgl-omni" "$STAGE_ROOT/bin/runtime-doctor"

STAGE_ROOT="$STAGE_ROOT" "$STAGE_ROOT/python/bin/python3" -s <<'PY'
import importlib.metadata
import json
import os
from pathlib import Path

root = Path(os.environ["STAGE_ROOT"])
package_path = root / "packages"
distributions = sorted(
    (
        (dist.metadata.get("Name") or "unknown", dist.version)
        for dist in importlib.metadata.distributions(path=[package_path])
    ),
    key=lambda item: item[0].lower(),
)
(root / "metadata" / "packages.txt").write_text(
    "".join(f"{name}=={version}\n" for name, version in distributions),
    encoding="utf-8",
)
PY

cat >"$STAGE_ROOT/runtime.json" <<JSON
{
  "schemaVersion": 1,
  "id": "sglang-omni-apple-stable",
  "displayName": "SGLang-Omni Apple Runtime",
  "engine": "sglang-omni",
  "version": "$RUNTIME_VERSION",
  "platform": "macos",
  "architecture": "arm64",
  "minimumMacOSVersion": "14.0",
  "channel": "$RUNTIME_CHANNEL",
  "distribution": "prebuilt",
  "artifactKind": "complete",
  "sourceCommit": "$OMNI_COMMIT",
  "containsNativeCode": true,
  "entrypoint": "bin/sgl-omni",
  "defaultArguments": ["serve"],
  "capabilities": ["openai-api", "qwen3-asr", "mlx", "torch-mps"],
  "components": {
    "python": "$PBS_VERSION_LABEL",
    "pythonBuildStandalone": "$PBS_RELEASE",
    "uvBuilder": "$UV_VERSION",
    "ffmpeg": "7.1.5",
    "sglangCommit": "$SGLANG_COMMIT",
    "sglangOmniCommit": "$OMNI_COMMIT"
  }
}
JSON

cat >"$STAGE_ROOT/metadata/build-provenance.json" <<JSON
{
  "builder": "SGLang-Desktop",
  "runtimeVersion": "$RUNTIME_VERSION",
  "pythonBuildStandaloneArchive": "$PBS_ARCHIVE",
  "pythonBuildStandaloneSHA256": "$PBS_EXPECTED_SHA256",
  "sglangCommit": "$SGLANG_COMMIT",
  "sglangOmniCommit": "$OMNI_COMMIT",
  "uvVersion": "$UV_VERSION",
  "dependencyOverrides": ["cache-dit==1.3.0"]
}
JSON

"$STAGE_ROOT/bin/sgl-omni" --help >/dev/null
"$STAGE_ROOT/bin/runtime-doctor" >"$STAGE_ROOT/metadata/doctor-build.json"

find "$STAGE_ROOT" -type f \( -name '*.so' -o -name '*.dylib' \) \
  -exec codesign --force --sign - {} \;

tar -czf "$FINAL_ARCHIVE" -C "$WORK_ROOT" "$RUNTIME_NAME"
shasum -a 256 "$FINAL_ARCHIVE" >"$FINAL_ARCHIVE.sha256"
printf 'Built runtime archive: %s\n' "$FINAL_ARCHIVE"
