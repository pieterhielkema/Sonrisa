#!/bin/bash
# Download the CEF binary distribution into third_party/cef and build the
# libcef_dll_wrapper static library. Required once after a fresh clone.
# Note: stock CEF has no H.264/AAC — for those, build a codec-enabled
# framework with scripts/build_cef_codecs.sh and swap it into Release/.
set -euo pipefail

CEF_VERSION="151.3.24+g2384915+chromium-151.0.7922.174"
PLATFORM="macosarm64"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/third_party/cef"

if [ -d "$DEST/Release" ]; then
  echo "third_party/cef already present — delete it first to re-fetch."
  exit 0
fi

NAME="cef_binary_${CEF_VERSION}_${PLATFORM}_minimal"
URL="https://cef-builds.spotifycdn.com/$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "${NAME}.tar.bz2")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading CEF ${CEF_VERSION} (~250 MB)..."
curl -fL --progress-bar -o "$TMP/cef.tar.bz2" "$URL"

mkdir -p "$DEST"
tar -xjf "$TMP/cef.tar.bz2" -C "$DEST" --strip-components 1

echo "Building libcef_dll_wrapper..."
cmake -S "$DEST" -B "$DEST/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DPROJECT_ARCH=arm64 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 > /dev/null
cmake --build "$DEST/build" --target libcef_dll_wrapper -j "$(sysctl -n hw.ncpu)" | tail -2

echo "Done. Open Sonrisa.xcodeproj and build."
