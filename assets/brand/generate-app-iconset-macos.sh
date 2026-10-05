#!/usr/bin/env bash
# Regenerates AppIcon.appiconset and AppIcon.icns from the brand masters.
# Run after changing agentkeybox-app-icon.png or the app-icon SVGs, and commit the results.
set -euo pipefail

BRAND="$(cd "$(dirname "$0")" && pwd)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This generator uses AppKit and iconutil and must run on macOS." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"

swift "$BRAND/render-app-icon.swift" "$BRAND" "$ICONSET"
iconutil --convert icns "$ICONSET" --output "$BRAND/AppIcon.icns"

# Keep the asset-catalog copy in sync; its Contents.json uses the same file names.
find "$BRAND/AppIcon.appiconset" -name '*.png' -delete
cp "$ICONSET"/*.png "$BRAND/AppIcon.appiconset/"

echo "Generated $BRAND/AppIcon.icns and $BRAND/AppIcon.appiconset"
