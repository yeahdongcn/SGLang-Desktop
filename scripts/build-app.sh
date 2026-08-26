#!/usr/bin/env bash
# Build a local Apple Silicon SGLang Desktop .app bundle.
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly APP_NAME="SGLang Desktop.app"
readonly VERSION="${SGLANG_DESKTOP_VERSION:-0.1.0}"
readonly BUILD_NUMBER="${SGLANG_DESKTOP_BUILD_NUMBER:-1}"
readonly SIGN_IDENTITY="${SGLANG_DESKTOP_SIGN_IDENTITY:--}"
readonly OUTPUT_ROOT="${SGLANG_DESKTOP_OUTPUT_DIR:-$REPO_ROOT/artifacts}"
readonly APP_ROOT="$OUTPUT_ROOT/$APP_NAME"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  printf 'SGLang Desktop currently builds only on Apple Silicon macOS.\n' >&2
  exit 1
fi

cd "$REPO_ROOT"
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf -- "$APP_ROOT"
mkdir -p "$APP_ROOT/Contents/MacOS" "$APP_ROOT/Contents/Resources"
install -m 755 "$BIN_DIR/SGLangDesktop" "$APP_ROOT/Contents/MacOS/SGLangDesktop"
install -m 644 "$REPO_ROOT/Packaging/Info.plist" "$APP_ROOT/Contents/Info.plist"
if [[ -d "$BIN_DIR/SGLangDesktop_SGLangDesktopApp.bundle" ]]; then
  ditto "$BIN_DIR/SGLangDesktop_SGLangDesktopApp.bundle" \
    "$APP_ROOT/Contents/Resources/SGLangDesktop_SGLangDesktopApp.bundle"
fi

if command -v rsvg-convert >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  ICONSET="$OUTPUT_ROOT/SGLangDesktop.iconset"
  mkdir -p "$ICONSET"
  ICON_SOURCE="$REPO_ROOT/Sources/SGLangDesktopApp/Resources/sglang-logo-square.svg"
  for size in 16 32 128 256 512; do
    rsvg-convert -w "$size" -h "$size" "$ICON_SOURCE" -o "$ICONSET/icon_${size}x${size}.png"
    doubled=$((size * 2))
    rsvg-convert -w "$doubled" -h "$doubled" "$ICON_SOURCE" -o "$ICONSET/icon_${size}x${size}@2x.png"
  done
  iconutil -c icns "$ICONSET" -o "$APP_ROOT/Contents/Resources/SGLangDesktop.icns"
  rm -rf -- "$ICONSET"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_ROOT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_ROOT/Contents/Info.plist"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP_ROOT"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_ROOT"
fi

codesign --verify --strict --verbose=2 "$APP_ROOT"
printf 'Built %s\n' "$APP_ROOT"
