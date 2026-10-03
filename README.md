# AgentKeyBox

**AgentKeyBox is a local-first credential wallet for AI coding agents.**

Store developer secrets once, organize them by project, and let Claude Code or Codex request access only when needed.

> **AI asks. You approve.**

AgentKeyBox is an experimental macOS utility for vibe coders, indie developers, and AI-first builders who do not want API keys scattered across `.env` files, notes, downloads, shell history, or chat windows.

## What it does

```text
Claude Code / Codex
        ↓ MCP
agentkeybox-mcp
        ↓ authenticated local broker
AgentKeyBox.app
        ↓ native approval
macOS Keychain
        ↓
approved local process
        ↓ redacted result
AI agent
```

The MCP helper never receives the raw credential. AgentKeyBox reads the value from Keychain only after approval and injects it into the approved process.

This is still **not a hard sandbox**: a command you approve can deliberately transmit or transform a credential. The approval UI therefore shows the command and highlights high-risk shells, interpreters, and network tools.

## Current alpha scope

- macOS 14+
- Swift + SwiftUI
- macOS Keychain secret storage
- local-only; no account and no backend
- Claude Code integration
- OpenAI Codex integration
- project-scoped credentials
- API keys and tokens
- `.env` import
- `.p8`, `.pem`, and JSON credential import
- provider presets for common developer services
- native Allow / Deny approval flow
- Touch ID confirmation when available
- protected temporary-file delivery for file credentials
- command timeout and output-size limits
- raw/common-encoding output redaction
- broker authentication, freshness checks, and replay protection
- `akb doctor` and one-command agent setup

## Quick development start

```bash
swift build
swift test
./Scripts/mcp-smoke-test.sh
./Scripts/cli-smoke-test.sh
./Scripts/security-static-check.sh
```

On a Mac:

```bash
./Scripts/install-dev-macos.sh
open "$HOME/Applications/AgentKeyBox.app"
~/.local/bin/akb doctor
~/.local/bin/akb connect all
```

You can also run the SwiftPM development executable directly:

```bash
./Scripts/run-dev-macos.sh
```

## CLI

```text
akb doctor [--json]
akb status [--json]
akb connect claude
akb connect codex
akb connect all
akb helper-path
```

`akb doctor` checks the MCP helper, local broker initialization, and Claude Code / Codex configuration.

## MCP tools

### `list_credentials`

Returns only non-secret metadata visible to the current project.

### `run_with_secret`

Requests approval for one process execution.

Example conceptual input:

```json
{
  "credential_id": "UUID",
  "env_var": "STRIPE_SECRET_KEY",
  "command": "/usr/bin/curl",
  "args": ["https://example.com"],
  "purpose": "Test the Stripe integration",
  "delivery": "environment"
}
```

`delivery` can be:

- `environment` — inject UTF-8 secret text directly into the named environment variable.
- `tempFile` — write the credential to a protected `0600` temporary file, inject that file path into the environment variable, and delete the file after execution. This is useful for `.p8`, `.pem`, and JSON credentials.

## Connect Claude Code

The app includes a **Connect Claude Code** action. Equivalent command:

```bash
claude mcp add --scope user \
  --env AGENTKEYBOX_AGENT_ID=claude-code \
  --env "AGENTKEYBOX_AGENT_NAME=Claude Code" \
  --transport stdio \
  agentkeybox -- /absolute/path/to/agentkeybox-mcp
```

Verify with:

```bash
claude mcp get agentkeybox
```

Claude Code supplies `CLAUDE_PROJECT_DIR` to local stdio MCP servers; AgentKeyBox uses it to scope project credentials.

## Connect Codex

The app includes a **Connect Codex** action. Equivalent command:

```bash
codex mcp add agentkeybox \
  --env AGENTKEYBOX_AGENT_ID=codex \
  --env AGENTKEYBOX_AGENT_NAME=Codex \
  -- /absolute/path/to/agentkeybox-mcp
```

Verify with:

```bash
codex mcp get agentkeybox --json
```

The current Codex prototype uses the MCP server process working directory as the project path unless `AGENTKEYBOX_PROJECT_PATH` is explicitly supplied. This assumption still needs real-Mac end-to-end verification.

## Provider presets

The current catalog includes:

- OpenAI
- Anthropic
- Stripe
- Supabase
- GitHub
- Google / Gemini
- Firebase
- Apple App Store Connect
- Vercel
- Resend
- Cloudflare

Presets are convenience metadata only; they do not send credentials to those providers.

## Security model

AgentKeyBox currently protects against common accidental leakage patterns:

- raw secret values are stored in Keychain, not metadata files
- metadata and broker-token files are owner-only where supported
- broker requests require a random per-install token
- broker requests carry an ID and timestamp and are rejected if stale or replayed
- one generic command approval expires after two minutes if unanswered
- approved commands time out after 60 seconds by default
- only a small allowlist of inherited environment variables is passed to approved child processes
- output is truncated and common direct secret representations are redacted
- project path matching avoids simple path-prefix confusion

AgentKeyBox does **not** claim to defend against malware or a malicious process already running as the same macOS user. See [SECURITY.md](SECURITY.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Repository layout

```text
Sources/
├── AgentKeyBoxApp/       SwiftUI macOS app and approval UI
├── AgentKeyBoxCore/      models, Keychain, broker, security, adapters
├── AgentKeyBoxMCP/       stdio MCP server used by coding agents
└── AgentKeyBoxCLI/       akb doctor/connect CLI

Tests/
└── AgentKeyBoxCoreTests/

Scripts/
├── run-dev-macos.sh
├── install-dev-macos.sh
├── uninstall-dev-macos.sh
├── build-release-macos.sh
├── notarize-release-macos.sh
├── check-all.sh
├── mcp-smoke-test.sh
├── cli-smoke-test.sh
└── security-static-check.sh
```


## Repository checks

Before a commit or alpha build, run:

```bash
make check
```

This runs formatter lint when available, a warnings-as-errors build, unit tests, MCP and CLI smoke tests, static secret/logging checks, and shell syntax validation.

See [`docs/SESSION_STATUS.md`](docs/SESSION_STATUS.md) for the exact boundary between what is already verified and what still requires a real Mac.


## Status

**Experimental / pre-alpha.** The core and MCP protocol can be tested in this repository, but the native SwiftUI/Keychain/broker path still requires a real macOS end-to-end run before public alpha release.

The product hypothesis is simple:

> Can AI credential access feel as obvious as a normal macOS permission prompt?

## Agent roadmap

**P0:** Claude Code, Codex  
**P1:** Cursor, Google Antigravity / Gemini CLI lineage  
**P2:** GitHub Copilot, Cline, Roo Code, Windsurf

AgentKeyBox integrates with the **agent host**, not a specific underlying model. Claude, GPT, Gemini, or Grok may run inside different coding environments.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security reports should follow [SECURITY.md](SECURITY.md) rather than public issues.

## License

Apache License 2.0. See [LICENSE](LICENSE).



## Product design direction

The current SwiftUI interface is an engineering prototype. The intended public product is project-centric, import-first, and uses progressive disclosure so users do not need to understand secrets-management infrastructure.

See [`docs/UI_DIRECTION.md`](docs/UI_DIRECTION.md) for the planned onboarding, project view, credential cards, approval prompts, and public-alpha UX.
