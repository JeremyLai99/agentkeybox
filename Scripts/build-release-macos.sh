#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Release app packaging requires macOS." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
rm -rf dist
mkdir -p dist

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="dist/AgentKeyBox.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "dist/bin"

cp "$BIN_DIR/AgentKeyBox" "$APP/Contents/MacOS/AgentKeyBox"
cp "$BIN_DIR/agentkeybox-mcp" "$APP/Contents/Helpers/agentkeybox-mcp"
cp "$BIN_DIR/akb" "$APP/Contents/Helpers/akb"
cp "$BIN_DIR/agentkeybox-mcp" "dist/bin/agentkeybox-mcp"
cp "$BIN_DIR/akb" "dist/bin/akb"
chmod +x "$APP/Contents/MacOS/AgentKeyBox" "$APP/Contents/Helpers/agentkeybox-mcp" "$APP/Contents/Helpers/akb" dist/bin/*

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>AgentKeyBox</string>
  <key>CFBundleExecutable</key><string>AgentKeyBox</string>
  <key>CFBundleIdentifier</key><string>dev.agentkeybox.app</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>AgentKeyBox</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3.0</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHumanReadableCopyright</key><string>AgentKeyBox contributors</string>
</dict>
</plist>
PLIST

if [[ -n "${AGENTKEYBOX_CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --deep --sign "$AGENTKEYBOX_CODESIGN_IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi

ZIP="dist/AgentKeyBox-0.3.0-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(
  cd dist
  shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256"
)

echo "Built $ZIP"
