#!/bin/bash
#
# embed_cef.sh — makes the built Sonrisa.app CEF-ready.
#
# CEF on macOS requires a helper .app for its sub-processes (renderer, GPU, ...)
# and expects the Chromium framework at Contents/Frameworks. This script:
#   1. Compiles the helper executable (once; rebuilt when helper_main.mm changes).
#   2. Creates "Sonrisa Helper.app" bundles inside the built app.
#   3. Symlinks the Chromium framework into Contents/Frameworks (dev setup —
#      swap the symlink for a copy when distributing).
#
# Intended to run as an Xcode "Run Script" build phase (uses BUILT_PRODUCTS_DIR
# etc.), but can also be run manually:
#   scripts/embed_cef.sh /path/to/Sonrisa.app

set -euo pipefail

SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CEF_DIR="$SRCROOT/third_party/cef"
FRAMEWORK_SRC="$CEF_DIR/Release/Chromium Embedded Framework.framework"
WRAPPER_LIB="$CEF_DIR/build/libcef_dll_wrapper/libcef_dll_wrapper.a"
HELPER_SRC="$SRCROOT/helper/helper_main.mm"
HELPER_BIN_CACHE="$SRCROOT/helper/build/Sonrisa Helper"

# Locate the built app: Xcode env vars, or first argument for manual runs.
if [[ -n "${BUILT_PRODUCTS_DIR:-}" && -n "${WRAPPER_NAME:-}" ]]; then
  APP_PATH="$BUILT_PRODUCTS_DIR/$WRAPPER_NAME"
else
  APP_PATH="${1:?usage: embed_cef.sh /path/to/Sonrisa.app}"
fi

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"

# --- 1. Build the helper executable (cached) --------------------------------
mkdir -p "$(dirname "$HELPER_BIN_CACHE")"
AUTOFILL_HDR="$SRCROOT/Sonrisa/CEF/AutofillScript.h"
JSONVIEWER_HDR="$SRCROOT/Sonrisa/CEF/JSONViewerScript.h"
if [[ ! -f "$HELPER_BIN_CACHE" || "$HELPER_SRC" -nt "$HELPER_BIN_CACHE" || "$WRAPPER_LIB" -nt "$HELPER_BIN_CACHE" || "$AUTOFILL_HDR" -nt "$HELPER_BIN_CACHE" || "$JSONVIEWER_HDR" -nt "$HELPER_BIN_CACHE" ]]; then
  echo "embed_cef: compiling Sonrisa Helper"
  # -DNDEBUG: must match the Release-built wrapper .a's DCHECK state, or
  # CEF refcount object layouts differ between the helper TU and the .a.
  clang++ -std=gnu++20 -ObjC++ -fobjc-arc -O2 -DNDEBUG -arch arm64 \
    -I "$CEF_DIR" \
    -o "$HELPER_BIN_CACHE" \
    "$HELPER_SRC" \
    "$WRAPPER_LIB" \
    -framework Cocoa -framework IOSurface
fi

# --- 2. Create the helper app bundles ---------------------------------------
# The plain helper handles every sub-process type; the (GPU), (Renderer),
# (Plugin) and (Alerts) variants exist because Chromium probes for them by
# name and each can carry different entitlements.
make_helper() {
  local suffix="$1"                       # e.g. "" or " (GPU)"
  local name="Sonrisa Helper${suffix}"
  local bundle="$FRAMEWORKS_DIR/${name}.app"
  local bundle_id_suffix
  bundle_id_suffix=$(echo "$suffix" | tr -d ' ()' | tr '[:upper:]' '[:lower:]')

  mkdir -p "$bundle/Contents/MacOS"
  cp "$HELPER_BIN_CACHE" "$bundle/Contents/MacOS/${name}"

  cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>${name}</string>
  <key>CFBundleIdentifier</key><string>com.timodogroup.Sonrisa.helper${bundle_id_suffix:+.$bundle_id_suffix}</string>
  <key>CFBundleName</key><string>${name}</string>
  <key>CFBundleDisplayName</key><string>${name}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSFileQuarantineEnabled</key><false/>
  <key>LSUIElement</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

  codesign --force --sign - "$bundle" 2>/dev/null
}

make_helper ""
make_helper " (GPU)"
make_helper " (Renderer)"
make_helper " (Plugin)"
make_helper " (Alerts)"

# --- 3. Link the Chromium framework into the bundle -------------------------
FRAMEWORK_DST="$FRAMEWORKS_DIR/Chromium Embedded Framework.framework"
if [[ ! -e "$FRAMEWORK_DST" ]]; then
  ln -s "$FRAMEWORK_SRC" "$FRAMEWORK_DST"
fi

echo "embed_cef: done → $APP_PATH"
