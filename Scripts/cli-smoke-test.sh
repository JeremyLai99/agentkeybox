#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN_DIR="$(swift build --show-bin-path)"
AKB="$BIN_DIR/akb"
MCP_PATH="$($AKB helper-path)"
[[ -x "$MCP_PATH" ]]
$AKB doctor --json | grep -q '"mcp-helper"'
