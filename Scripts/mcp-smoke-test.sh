#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN_DIR="${AGENTKEYBOX_BIN_DIR:-$(swift build --show-bin-path)}"
MCP="$BIN_DIR/agentkeybox-mcp"

OUTPUT="$({
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke-test","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"submit_sensitive_fields","arguments":{"credential_id":"00000000-0000-0000-0000-000000000001","fields":{"code":12}}}}' \
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"submit_sensitive_fields","arguments":{"credential_id":"00000000-0000-0000-0000-000000000001","fields":{"code":"{{recovery.code}}"},"url":"https://example.com/override"}}}' \
    '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"submit_sensitive_fields","arguments":{"credential_id":"00000000-0000-0000-0000-000000000001","fields":{"code":"{{recovery.code}}"},"encoding":12}}}' \
    '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"browser_login","arguments":{"credential_id":"00000000-0000-0000-0000-000000000001","url":"https://example.com/override"}}}' \
    '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"browser_read","arguments":{"browser_session_id":"not-a-uuid"}}}' \
    '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"browser_follow","arguments":{"browser_session_id":"00000000-0000-0000-0000-000000000001"}}}' \
    '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"browser_close","arguments":{"browser_session_id":"00000000-0000-0000-0000-000000000001","script":"document.cookie"}}}' \
    '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"browser_recover","arguments":{"browser_session_id":"00000000-0000-0000-0000-000000000001"}}}' \
    '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"browser_recover","arguments":{"browser_session_id":"00000000-0000-0000-000000000001","credential_id":"00000000-0000-0000-0000-000000000002","code":"DO_NOT_ECHO_THIS"}}}'
} | "$MCP")"

printf '%s\n' "$OUTPUT"

grep -q '"name":"AgentKeyBox"' <<<"$OUTPUT"
grep -q '"name":"list_credentials"' <<<"$OUTPUT"
grep -q '"name":"run_with_secret"' <<<"$OUTPUT"
grep -q '"name":"http_request"' <<<"$OUTPUT"
grep -q '"name":"request_credential"' <<<"$OUTPUT"
grep -q '"name":"submit_sensitive_fields"' <<<"$OUTPUT"

LINE_COUNT="$(printf '%s\n' "$OUTPUT" | grep -c '^{' || true)"
[[ "$LINE_COUNT" -eq 11 ]] || { echo "Expected exactly 11 JSON-RPC responses; got $LINE_COUNT" >&2; exit 1; }
# These malformed protected submissions are rejected before opening/contacting the app.
ERROR_COUNT="$(printf '%s\n' "$OUTPUT" | grep -c '"isError":true' || true)"
[[ "$ERROR_COUNT" -eq 9 ]] || { echo "Expected 9 protected-tool validation errors; got $ERROR_COUNT" >&2; exit 1; }
grep -q 'Field values must be strings' <<<"$OUTPUT"
grep -q 'The destination is set only in AgentKeyBox' <<<"$OUTPUT"
grep -q 'encoding must be form or json' <<<"$OUTPUT"

for tool in browser_login browser_read browser_follow browser_recover browser_close; do
  grep -q "\"name\":\"$tool\"" <<<"$OUTPUT"
done
grep -q 'URLs, scripts, selectors and secret values are not accepted' <<<"$OUTPUT"

! grep -q DO_NOT_ECHO_THIS <<<"$OUTPUT"
