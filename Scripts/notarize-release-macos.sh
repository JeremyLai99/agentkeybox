#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Notarization requires macOS." >&2
  exit 1
fi

: "${AGENTKEYBOX_NOTARY_PROFILE:?Set AGENTKEYBOX_NOTARY_PROFILE to an xcrun notarytool keychain profile.}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="dist/AgentKeyBox.app"
ZIP="dist/AgentKeyBox-0.3.0-macOS.zip"
SUBMIT_ZIP="dist/AgentKeyBox-0.3.0-notarization.zip"

if [[ ! -d "$APP" ]]; then
  echo "Missing $APP. Build a Developer ID signed app first with Scripts/build-release-macos.sh." >&2
  exit 1
fi

if ! codesign --verify --deep --strict "$APP"; then
  echo "The app does not have a valid signature." >&2
  exit 1
fi

SIGNING_AUTHORITY="$(codesign -dv --verbose=2 "$APP" 2>&1 | awk -F= '/^Authority=/{print $2; exit}')"
if [[ -z "$SIGNING_AUTHORITY" ]]; then
  echo "No Developer ID signing authority found. Rebuild with AGENTKEYBOX_CODESIGN_IDENTITY." >&2
  exit 1
fi

echo "Submitting notarization artifact signed by: $SIGNING_AUTHORITY"
rm -f "$SUBMIT_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$SUBMIT_ZIP"
xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$AGENTKEYBOX_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

rm -f "$SUBMIT_ZIP" "$ZIP" "$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(
  cd dist
  shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256"
)

echo "Notarized and stapled: $ZIP"
