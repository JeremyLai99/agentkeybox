#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "AgentKeyBox installation requires macOS." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
./Scripts/build-release-macos.sh

APP_DEST="$HOME/Applications/AgentKeyBox.app"
BIN_DEST="$HOME/.local/bin"
mkdir -p "$HOME/Applications" "$BIN_DEST"
rm -rf "$APP_DEST"
cp -R "dist/AgentKeyBox.app" "$APP_DEST"
cp "dist/bin/agentkeybox-mcp" "$BIN_DEST/agentkeybox-mcp"
cp "dist/bin/akb" "$BIN_DEST/akb"
chmod +x "$BIN_DEST/agentkeybox-mcp" "$BIN_DEST/akb"

cat <<MSG
Installed:
  $APP_DEST
  $BIN_DEST/agentkeybox-mcp
  $BIN_DEST/akb

Next:
  open "$APP_DEST"
  "$BIN_DEST/akb" doctor
  "$BIN_DEST/akb" connect all
MSG
