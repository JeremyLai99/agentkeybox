# Agent Integration

AgentKeyBox uses one local **stdio MCP server** for both Claude Code and Codex.

The MCP helper does not receive raw credential values. It asks the AgentKeyBox macOS app to perform an approved operation locally.

## Build

```bash
swift build
```

Find the built binaries with:

```bash
swift build --show-bin-path
```

The directory contains both:

```text
AgentKeyBox
agentkeybox-mcp
```

During development, run `AgentKeyBox` first so it can create the local broker authentication token and listen for requests.

## Claude Code

```bash
claude mcp add --scope user \
  --env AGENTKEYBOX_AGENT_ID=claude-code \
  --env "AGENTKEYBOX_AGENT_NAME=Claude Code" \
  --transport stdio \
  agentkeybox -- /absolute/path/to/agentkeybox-mcp
```

Verify:

```bash
claude mcp list
```

Claude Code provides `CLAUDE_PROJECT_DIR` to local stdio MCP servers. AgentKeyBox uses that value as the trusted project path when available.

Start a new Claude Code session after installation.

## Codex

```bash
codex mcp add agentkeybox \
  --env AGENTKEYBOX_AGENT_ID=codex \
  --env AGENTKEYBOX_AGENT_NAME=Codex \
  -- /absolute/path/to/agentkeybox-mcp
```

Verify:

```bash
codex mcp list
```

Start a new Codex session after installation. The prototype uses the MCP process working directory as Codex's project path unless `AGENTKEYBOX_PROJECT_PATH` is explicitly supplied.

## MCP tools

### `list_credentials`

Takes no secret-bearing input. It returns only credential IDs and non-secret metadata that are global or bound to the current project.

### `run_with_secret`

Input shape:

```json
{
  "credential_id": "UUID",
  "env_var": "STRIPE_SECRET_KEY",
  "command": "/usr/bin/curl",
  "args": ["https://example.com"],
  "purpose": "Test the Stripe integration"
}
```

Flow:

```text
agent
  ↓ MCP tool call
agentkeybox-mcp
  ↓ authenticated localhost request (no secret)
AgentKeyBox.app
  ↓ native Allow / Deny prompt
Keychain
  ↓ secret injected inside app process
approved child process
  ↓ exact/raw + common encoded forms redacted
agentkeybox-mcp
  ↓
agent
```

The app must be running. An approval automatically expires after two minutes.

## Local broker authentication

On first launch, AgentKeyBox creates a random broker token at:

```text
~/Library/Application Support/AgentKeyBox/broker-token
```

The file is owner-readable/writable only (`0600`). The MCP helper reads this token before calling the localhost broker. It is **not** an API credential and never leaves the machine.

This is a guardrail against unrelated local callers, not a defense against malware running as the same macOS user.

## Prototype security boundary

The raw secret is not returned to the MCP process and is not intentionally written to logs. Command output is redacted for the raw secret plus common direct encodings (Base64, percent-encoding, and hex).

However, an approved child process can still deliberately transmit or transform the secret. `run_with_secret` is therefore a workflow prototype, not a final containment mechanism. A future safer path is provider-specific HTTP/proxy operations with host constraints.
