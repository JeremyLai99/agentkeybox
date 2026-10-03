#!/usr/bin/env bash
set -euo pipefail
rm -rf "$HOME/Applications/AgentKeyBox.app"
rm -f "$HOME/.local/bin/agentkeybox-mcp" "$HOME/.local/bin/akb"
echo "Removed AgentKeyBox app and local CLI binaries. Keychain items and Application Support metadata were left intact intentionally."
