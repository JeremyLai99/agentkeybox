#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BRAND="$ROOT/assets/brand"
SRC="$BRAND/agentkeybox-app-icon.png"
DST="$BRAND/AppIcon.appiconset"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This generator uses macOS sips and must run on macOS." >&2
  exit 1
fi

[[ -f "$SRC" ]] || { echo "Missing $SRC" >&2; exit 1; }
mkdir -p "$DST"

# Pixel-aware small variants: do not downscale the detailed master here.
cp "$BRAND/app-icon/AppIcon-Tiny-16.png" "$DST/icon_16x16.png"
cp "$BRAND/app-icon/AppIcon-Tiny-32.png" "$DST/icon_16x16@2x.png"
cp "$BRAND/app-icon/AppIcon-Tiny-32.png" "$DST/icon_32x32.png"
cp "$BRAND/app-icon/AppIcon-Simplified-64.png" "$DST/icon_32x32@2x.png"

# Larger variants use the approved primary artwork.
sips -z 128 128 "$SRC" --out "$DST/icon_128x128.png" >/dev/null
sips -z 256 256 "$SRC" --out "$DST/icon_128x128@2x.png" >/dev/null
cp "$DST/icon_128x128@2x.png" "$DST/icon_256x256.png"
sips -z 512 512 "$SRC" --out "$DST/icon_256x256@2x.png" >/dev/null
cp "$DST/icon_256x256@2x.png" "$DST/icon_512x512.png"
sips -z 1024 1024 "$SRC" --out "$DST/icon_512x512@2x.png" >/dev/null

echo "Generated macOS AppIcon set at $DST"
