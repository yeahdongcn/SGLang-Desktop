#!/usr/bin/env bash
# Materialize the currently validated Apple Silicon development environment as
# two immediately usable Desktop runtime entries. This is a local trial helper,
# not the reproducible release builder.
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly OMNI_VENV="${SGLANG_OMNI_VENV:-$REPO_ROOT/../sglang-omni/.venv-apple}"
readonly SGLANG_SOURCE="${SGLANG_SOURCE_DIR:-/tmp/sglang-v0.5.16-apple/python}"
readonly OMNI_SOURCE="${SGLANG_OMNI_SOURCE_DIR:-$REPO_ROOT/../sglang-omni}"
readonly APP_DATA="${SGLANG_DESKTOP_DATA_DIR:-$HOME/Library/Application Support/SGLang Desktop}"
readonly RUNTIME_ROOT="$APP_DATA/runtimes"
readonly SHARED_ROOT="$RUNTIME_ROOT/trial-shared-apple"
readonly CORE_ROOT="$RUNTIME_ROOT/sglang-trial-apple"
readonly OMNI_ROOT="$RUNTIME_ROOT/sglang-omni-pr1730-trial-apple"

[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] || {
  printf 'This trial runtime is for Apple Silicon macOS only.\n' >&2
  exit 1
}
[[ -x "$OMNI_VENV/bin/python" ]] || { printf 'Missing venv: %s\n' "$OMNI_VENV" >&2; exit 1; }
[[ -d "$OMNI_VENV/lib/python3.12/site-packages" ]] || { printf 'Missing site-packages.\n' >&2; exit 1; }
[[ -d "$SGLANG_SOURCE/sglang" ]] || { printf 'Missing SGLang source: %s\n' "$SGLANG_SOURCE" >&2; exit 1; }
[[ -d "$OMNI_SOURCE/sglang_omni" ]] || { printf 'Missing Omni source: %s\n' "$OMNI_SOURCE" >&2; exit 1; }

if [[ -e "$SHARED_ROOT" || -e "$CORE_ROOT" || -e "$OMNI_ROOT" ]]; then
  printf 'Trial runtimes already exist under %s; leaving them unchanged.\n' "$RUNTIME_ROOT"
  exit 0
fi

readonly PYTHON_HOME="$(cd -- "$(dirname -- "$(readlink "$OMNI_VENV/bin/python")")/.." && pwd -P)"
mkdir -p "$RUNTIME_ROOT" "$SHARED_ROOT" "$CORE_ROOT/bin" "$OMNI_ROOT/bin"

printf 'Copying relocatable CPython…\n'
ditto "$PYTHON_HOME" "$SHARED_ROOT/python"

printf 'Copying preinstalled Python packages…\n'
mkdir -p "$SHARED_ROOT/packages"
rsync -a --delete \
  --exclude='*.pth' \
  --exclude='__editable*' \
  "$OMNI_VENV/lib/python3.12/site-packages/" "$SHARED_ROOT/packages/"

# The source venv uses editable installs. Materialize those two projects into
# the shared package directory so the trial runtime does not depend on the
# checkout path or editable finder files.
rsync -a --delete "$SGLANG_SOURCE/sglang/" "$SHARED_ROOT/packages/sglang/"
rsync -a --delete "$OMNI_SOURCE/sglang_omni/" "$SHARED_ROOT/packages/sglang_omni/"
rsync -a --delete "$OMNI_SOURCE/sglang_omni_router/" "$SHARED_ROOT/packages/sglang_omni_router/"

write_wrapper() {
  local destination="$1"
  local module="$2"
  cat >"$destination" <<SH
#!/usr/bin/env bash
set -Eeuo pipefail
readonly RUNTIME_ROOT="\$(cd -- "\$(dirname -- "\${BASH_SOURCE[0]}")/../../trial-shared-apple" && pwd -P)"
export PYTHONNOUSERSITE=1
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="\$RUNTIME_ROOT/packages"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if [[ -d /opt/homebrew/opt/ffmpeg@7/lib ]]; then
  export DYLD_LIBRARY_PATH="/opt/homebrew/opt/ffmpeg@7/lib\${DYLD_LIBRARY_PATH:+:\$DYLD_LIBRARY_PATH}"
fi
exec "\$RUNTIME_ROOT/python/bin/python3" -s -m $module "\$@"
SH
  chmod +x "$destination"
}

cat >"$CORE_ROOT/bin/sglang" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
readonly RUNTIME_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../trial-shared-apple" && pwd -P)"
export PYTHONNOUSERSITE=1
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$RUNTIME_ROOT/packages"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if [[ -d /opt/homebrew/opt/ffmpeg@7/lib ]]; then
  export DYLD_LIBRARY_PATH="/opt/homebrew/opt/ffmpeg@7/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
fi
exec "$RUNTIME_ROOT/python/bin/python3" -s -c 'from sglang.cli.main import main; main()' "$@"
SH
chmod +x "$CORE_ROOT/bin/sglang"
write_wrapper "$OMNI_ROOT/bin/sgl-omni" "sglang_omni.cli"

cat >"$CORE_ROOT/runtime.json" <<JSON
{
  "schemaVersion": 1,
  "id": "sglang-trial-apple",
  "displayName": "SGLang · Apple Silicon preinstalled trial runtime",
  "engine": "sglang",
  "version": "trial",
  "platform": "macos",
  "architecture": "arm64",
  "minimumMacOSVersion": "14.0",
  "channel": "local",
  "distribution": "localVirtualEnvironment",
  "artifactKind": "complete",
  "entrypoint": "bin/sglang",
  "capabilities": ["qwen3-0.6b", "mlx", "torch-mps"]
}
JSON
cat >"$OMNI_ROOT/runtime.json" <<JSON
{
  "schemaVersion": 1,
  "id": "sglang-omni-pr1730-trial-apple",
  "displayName": "SGLang-Omni PR #1730 · Apple Silicon preinstalled trial runtime",
  "engine": "sglang-omni",
  "version": "pr-1730",
  "platform": "macos",
  "architecture": "arm64",
  "minimumMacOSVersion": "14.0",
  "channel": "preview",
  "distribution": "localVirtualEnvironment",
  "artifactKind": "complete",
  "entrypoint": "bin/sgl-omni",
  "capabilities": ["qwen3-asr-0.6b-4bit", "mlx", "torch-mps"]
}
JSON

cat >"$RUNTIME_ROOT/README-trial.txt" <<TXT
These trial runtimes were materialized from:
  SGLang v0.5.16 source: $SGLANG_SOURCE
  SGLang-Omni source: $OMNI_SOURCE
  Python environment: $OMNI_VENV

They are intended for local testing and use Homebrew FFmpeg 7 when available.
Stable Desktop releases will replace this with signed, self-contained archives.
TXT

printf 'Trial runtimes installed under: %s\n' "$RUNTIME_ROOT"
