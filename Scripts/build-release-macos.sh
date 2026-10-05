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

# App icon (regenerate with assets/brand/generate-app-iconset-macos.sh) and the brand images the
# UI loads at runtime from Contents/Resources/Brand.
cp assets/brand/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/Brand"
cp -R assets/brand/credential-types assets/brand/menu-bar assets/brand/ui "$APP/Contents/Resources/Brand/"
find "$APP/Contents/Resources/Brand" -name '*.svg' -delete

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>AgentKeyBox</string>
  <key>CFBundleExecutable</key><string>AgentKeyBox</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
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

# Signing modes:
# - AGENTKEYBOX_CODESIGN_IDENTITY + AGENTKEYBOX_PROVISIONING_PROFILE: team-signed with the
#   keychain-access-groups entitlement, so secrets live in the data protection keychain behind
#   Touch ID and one approval costs exactly one prompt. macOS kills an app that claims this
#   entitlement without an embedded provisioning profile, so both are required.
# - AGENTKEYBOX_CODESIGN_IDENTITY only: team-signed without keychain entitlements (legacy keychain).
# - neither: ad-hoc signed (legacy keychain; macOS re-prompts for the login password per rebuild).
if [[ -n "${AGENTKEYBOX_CODESIGN_IDENTITY:-}" ]]; then
  SIGN=(codesign --force --options runtime --timestamp --sign "$AGENTKEYBOX_CODESIGN_IDENTITY")
  "${SIGN[@]}" "$APP/Contents/Helpers/agentkeybox-mcp" "$APP/Contents/Helpers/akb"

  if [[ -n "${AGENTKEYBOX_PROVISIONING_PROFILE:-}" ]]; then
    TEAM_ID="$(security find-certificate -c "$AGENTKEYBOX_CODESIGN_IDENTITY" -p \
      | openssl x509 -noout -subject | sed -nE 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/p')"
    if [[ -z "$TEAM_ID" ]]; then
      echo "Could not determine the team ID of $AGENTKEYBOX_CODESIGN_IDENTITY." >&2
      exit 1
    fi
    cp "$AGENTKEYBOX_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
    ENTITLEMENTS="dist/AgentKeyBox.entitlements"
    cat > "$ENTITLEMENTS" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.application-identifier</key><string>$TEAM_ID.dev.agentkeybox.app</string>
  <key>com.apple.developer.team-identifier</key><string>$TEAM_ID</string>
  <key>keychain-access-groups</key><array><string>$TEAM_ID.dev.agentkeybox</string></array>
</dict>
</plist>
ENT
    "${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP"
  else
    echo "warning: AGENTKEYBOX_PROVISIONING_PROFILE not set; using the legacy keychain." >&2
    "${SIGN[@]}" "$APP"
  fi
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
