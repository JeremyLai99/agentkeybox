#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN_DIR="$(swift build --show-bin-path)"
MCP="$BIN_DIR/agentkeybox-mcp"

OUTPUT="$({
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke-test","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
} | "$MCP")"

printf '%s\n' "$OUTPUT"

grep -q '"name":"AgentKeyBox"' <<<"$OUTPUT"
grep -q '"name":"list_credentials"' <<<"$OUTPUT"
grep -q '"name":"run_with_secret"' <<<"$OUTPUT"

LINE_COUNT="$(printf '%s\n' "$OUTPUT" | grep -c '^{' || true)"
[[ "$LINE_COUNT" -eq 2 ]] || { echo "Expected exactly 2 JSON-RPC responses; got $LINE_COUNT" >&2; exit 1; }
