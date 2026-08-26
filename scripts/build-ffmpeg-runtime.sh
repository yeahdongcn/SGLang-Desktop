#!/usr/bin/env bash
# Build relocatable, LGPL FFmpeg 7 shared libraries for TorchCodec.
set -Eeuo pipefail
IFS=$'\n\t'

readonly FFMPEG_VERSION="7.1.5"
readonly FFMPEG_SHA256="de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f"
readonly FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"

if [[ $# -ne 1 ]]; then
  printf 'Usage: %s OUTPUT_PREFIX\n' "$0" >&2
  exit 2
fi
if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  printf 'FFmpeg runtime builds require Apple Silicon macOS.\n' >&2
  exit 1
fi

readonly OUTPUT_PREFIX="$1"
case "$OUTPUT_PREFIX" in
  ""|/|"$HOME")
    printf 'Refusing unsafe output prefix: %s\n' "$OUTPUT_PREFIX" >&2
    exit 1
    ;;
esac

readonly WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sglang-ffmpeg-runtime.XXXXXX")"
cleanup() {
  rm -rf -- "$WORK_ROOT"
}
trap cleanup EXIT

readonly ARCHIVE="$WORK_ROOT/ffmpeg.tar.xz"
curl --fail --location --retry 5 --output "$ARCHIVE" "$FFMPEG_URL"
printf '%s  %s\n' "$FFMPEG_SHA256" "$ARCHIVE" | shasum -a 256 --check
tar -xJf "$ARCHIVE" -C "$WORK_ROOT"

readonly SOURCE_DIR="$WORK_ROOT/ffmpeg-$FFMPEG_VERSION"
readonly CPU_COUNT="$(sysctl -n hw.ncpu)"
mkdir -p "$OUTPUT_PREFIX"

cd "$SOURCE_DIR"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
./configure \
  --prefix="$OUTPUT_PREFIX" \
  --arch=arm64 \
  --cc=clang \
  --enable-shared \
  --disable-static \
  --disable-programs \
  --disable-doc \
  --disable-debug \
  --disable-network \
  --disable-autodetect \
  --disable-iconv \
  --install-name-dir='@rpath'
make -j "$CPU_COUNT"
make install

find "$OUTPUT_PREFIX/lib" -type f -name '*.dylib' -exec codesign --force --sign - {} \;

if find "$OUTPUT_PREFIX/lib" -type f -name '*.dylib' -print0 \
  | xargs -0 otool -L \
  | grep -E '/opt/homebrew|/usr/local|sglang-ffmpeg-runtime'; then
  printf 'FFmpeg bundle contains a non-relocatable dependency.\n' >&2
  exit 1
fi

mkdir -p "$OUTPUT_PREFIX/licenses"
install -m 644 "$SOURCE_DIR/LICENSE.md" "$OUTPUT_PREFIX/licenses/FFmpeg-LICENSE.md"
install -m 644 "$SOURCE_DIR/COPYING.LGPLv2.1" "$OUTPUT_PREFIX/licenses/COPYING.LGPLv2.1"
