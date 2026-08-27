#!/bin/bash
# Build CEF with proprietary codecs (H.264/AAC) for macOS arm64.
# Produces a minimal binary distrib to swap into third_party/cef/Release.
# Usage: caffeinate -i bash scripts/build_cef_codecs.sh
# Rebuild for a new CEF version: update CEF_BRANCH/CEF_COMMIT below
# (find them at https://cef-builds.spotifycdn.com — commit is the g<hash> part).
set -euo pipefail

CEF_BRANCH=7922
CEF_COMMIT=2384915   # CEF 151.3.24 (chromium 151.0.7922.174)
ROOT="$HOME/cef-codec-build"
MIN_FREE_GB=12

mkdir -p "$ROOT"
cd "$ROOT"

if [ ! -d depot_tools ]; then
  git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
fi
export PATH="$ROOT/depot_tools:$PATH"

curl -fsSL -o automate-git.py \
  https://bitbucket.org/chromiumembedded/cef/raw/master/tools/automate/automate-git.py

# Non-official build (no LTO): machine has 16 GB RAM.
export GN_DEFINES="proprietary_codecs=true ffmpeg_branding=Chrome is_official_build=false symbol_level=0 blink_symbol_level=0 v8_symbol_level=0 enable_dsyms=false"
export CEF_ARCHIVE_FORMAT=tar.bz2

# Disk guard: abort the build before the machine runs dry.
(
  while true; do
    free_gb=$(df -g "$ROOT" | awk 'NR==2 {print $4}')
    echo "$(date '+%F %T') disk guard: ${free_gb} GB free" >> "$ROOT/disk.log"
    if [ "$free_gb" -lt "$MIN_FREE_GB" ]; then
      echo "$(date '+%F %T') DISK GUARD TRIPPED: ${free_gb} GB < ${MIN_FREE_GB} GB — killing build" \
        | tee -a "$ROOT/disk.log" > "$ROOT/DISK_GUARD_TRIPPED"
      pkill -f automate-git.py || true
      pkill -f autoninja || true
      pkill -x ninja || true
      exit 1
    fi
    sleep 60
  done
) &
GUARD_PID=$!
trap 'kill $GUARD_PID 2>/dev/null || true' EXIT

python3 automate-git.py \
  --download-dir="$ROOT/chromium_git" \
  --branch="$CEF_BRANCH" \
  --checkout="$CEF_COMMIT" \
  --arm64-build \
  --no-debug-build \
  --minimal-distrib \
  --force-build

echo "BUILD DONE"
ls -lh "$ROOT"/chromium_git/chromium/src/cef/binary_distrib/*.tar.bz2 2>/dev/null || true
