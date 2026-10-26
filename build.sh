#!/bin/bash
# Builds "Facet.app" in the project folder.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift not found. Please run first:  xcode-select --install"
  exit 1
fi

echo "→ Compiling (release)…"
if ! swift build -c release; then
  echo "→ Cleaning build cache and retrying…"
  rm -rf .build
  swift build -c release
fi

echo "→ Creating app icon…"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Icon/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d Icon/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done

APP="Facet.app"
rm -rf "$APP" PhotoMesh.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/Facet" "$APP/Contents/MacOS/Facet"
cp Info.plist "$APP/Contents/Info.plist"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
touch "$APP"   # refresh the Finder/Dock icon cache

echo "✓ Done: $(pwd)/$APP"
open "$APP"
