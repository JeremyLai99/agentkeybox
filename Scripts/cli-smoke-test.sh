#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN_DIR="${AGENTKEYBOX_BIN_DIR:-$(swift build --show-bin-path)}"
AKB="$BIN_DIR/akb"
MCP_PATH="$($AKB helper-path)"
[[ -x "$MCP_PATH" ]]
$AKB doctor --json | grep -q '"mcp-helper"'

# These paths never contact the native app or read credentials.
$AKB browser help | grep -q 'clientSessionID'
check_invalid_browser() {
  local result
  set +e
  result="$($AKB browser "$@" 2>&1)"
  local status=$?
  set -e
  [[ "$status" -eq 2 ]]
  [[ "$result" == *"Invalid browser arguments"* ]]
  [[ "$result" != *"DO_NOT_ECHO_THIS"* ]]
}
check_invalid_browser login --credential DO_NOT_ECHO_THIS
check_invalid_browser read --session invalid --browser invalid
check_invalid_browser list --password DO_NOT_ECHO_THIS
check_invalid_browser follow --session invalid --browser invalid --url DO_NOT_ECHO_THIS

check_invalid_browser recover --session invalid --browser invalid --credential invalid --code DO_NOT_ECHO_THIS
