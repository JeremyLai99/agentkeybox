# AgentKeyBox

[繁體中文說明](README.zh-TW.md)

**AgentKeyBox is a local-first credential wallet for AI coding agents.**

Store developer secrets once, organize them by project, and let Claude Code or Codex request access only when needed.

> **AI asks. You approve.**

AgentKeyBox is an experimental macOS utility for vibe coders, indie developers, and AI-first builders who do not want API keys scattered across `.env` files, notes, downloads, shell history, or chat windows.

## Install

**You need:** macOS 14 (Sonoma) or later on any Mac (Apple silicon or Intel), and Claude Code or Codex. Touch ID is optional; without it, macOS asks for your login password instead.

1. Download `AgentKeyBox-<version>-macOS.zip` from the [latest release](https://github.com/JeremyLai99/agentkeybox/releases/latest).
2. Double-click the zip, then open **AgentKeyBox**. macOS asks whether to open an app downloaded from the internet; choose **Open**. The app is signed with a Developer ID and notarized by Apple.
3. If a banner says AgentKeyBox isn't in your Applications folder yet, click **Move to Applications**. It moves itself there and reopens.
4. Drag your project folder onto the window (or click **Choose Folder…**). AgentKeyBox shows the keys it found in `.env` files and key files (`.p8`, `.pem`, service-account JSON), with real secrets already checked. Click **Set Up**: the keys move into your Keychain, your files stay where they are, unignored `.env` files can be added to `.gitignore`, and Claude Code / Codex are connected if installed.
5. Start a **new** Claude Code or Codex session in that project. When the agent needs a key, AgentKeyBox asks you; click **Allow Once** and touch Touch ID.

The interface follows your macOS language (English or Traditional Chinese). Change it in **Settings › Language**.

To check the download, compare `shasum -a 256 AgentKeyBox-<version>-macOS.zip` with the `.sha256` file published next to it.

### Update

Download the new version, open it, and click **Move to Applications**. The older copy goes to the Trash. Your projects, keys, and agent connections are kept: keys live in your Keychain, and agents use a helper at a fixed path that each version refreshes when it starts.

### Uninstall

1. In AgentKeyBox, right-click each project and choose **Remove Project…**. This deletes its keys from your Keychain. Delete any **Global keys** the same way (right-click a key › **Delete…**). Deleting only the app would leave the keys in your Keychain.
2. Disconnect your coding agents:

   ```bash
   claude mcp remove --scope user agentkeybox
   codex mcp remove agentkeybox
   ```

3. Quit AgentKeyBox (menu bar icon › **Quit AgentKeyBox**) and move it from Applications to the Trash.
4. Remove its local settings and helper:

   ```bash
   rm -rf ~/Library/Application\ Support/AgentKeyBox
   defaults delete dev.agentkeybox.app
   ```

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
- Touch ID (or login password) confirmation for every approval
- protected temporary-file delivery for file credentials
- command timeout and output-size limits
- raw/common-encoding output redaction
- broker authentication, freshness checks, and replay protection
- `akb doctor` and one-command agent setup
- provider bundles: an App Store Connect key with its Key ID and Issuer ID, a Supabase key with its project URL, shown as one card
- "don't ask again during this session" for repeated identical requests
- English and Traditional Chinese interface

## Build from source

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

For a team-signed build that keeps secrets in the data protection keychain behind Touch ID (one prompt per approval, no keychain password dialogs after rebuilds), provide a signing identity and a macOS provisioning profile for `dev.agentkeybox.app`:

```bash
AGENTKEYBOX_CODESIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)" \
AGENTKEYBOX_PROVISIONING_PROFILE=/path/to/AgentKeyBox.provisionprofile \
./Scripts/build-release-macos.sh
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
akb run [--only VAR1,VAR2] -- <command> [args…]
akb helper-path
```

`akb doctor` checks the MCP helper, local broker initialization, and Claude Code / Codex configuration.

### `akb run` — replace your `.env` file

```bash
akb run -- npm run dev
```

After one Touch ID approval in AgentKeyBox, `akb` replaces itself with your command, with every text secret of the current project folder in its environment (or only `--only` names). The command keeps your terminal, so dev servers, prompts, and Ctrl-C work normally, and there is no timeout. Because the secrets are handed to your process, AgentKeyBox cannot redact its output; the approval prompt says so and shows the exact command. File credentials (`.p8`, `.pem`, JSON) are skipped.

## MCP tools

### `list_credentials`

Returns only non-secret metadata visible to the current project, including each credential's environment variable name and allowed hosts.

### `http_request` — preferred for provider APIs

AgentKeyBox sends one HTTPS request itself, after approval, and returns the status and redacted body. The agent puts `{{secret}}` where the credential belongs:

```json
{
  "credential_id": "UUID",
  "method": "GET",
  "url": "https://api.stripe.com/v1/balance",
  "headers": { "Authorization": "Bearer {{secret}}" },
  "purpose": "Check the Stripe test balance"
}
```

Rules, enforced before the user is even asked:

- https only; no credentials in the URL
- `{{secret}}` only in header values, never in the URL or body
- the host must match the credential's allowed hosts (provider presets prefill them, e.g. `api.stripe.com`, `*.supabase.co`); credentials without an allowlist are flagged in the prompt
- redirects are not followed, so the credential header is never replayed elsewhere
- 30-second timeout, 128 KiB response limit, secret redacted from the response

Unlike `run_with_secret`, no local process or shell is involved, so common API calls no longer need a high-risk shell command.

### `request_credential`

When `list_credentials` does not show what the project needs, the agent calls `request_credential` with the variable name (e.g. `STRIPE_SECRET_KEY`). AgentKeyBox opens a prompt with a link to the provider's dashboard where the user pastes the key. It is saved in the Keychain for the current project (adding the project folder if needed), and the agent receives only the new `credential_id`.

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
  agentkeybox -- "$HOME/Library/Application Support/AgentKeyBox/bin/agentkeybox-mcp"
```

Verify with:

```bash
claude mcp get agentkeybox
```

The helper at that fixed path is copied from the app each time AgentKeyBox starts, so the connection survives moving or updating the app; a connected agent that still points elsewhere is re-registered automatically.

Claude Code supplies `CLAUDE_PROJECT_DIR` to local stdio MCP servers; AgentKeyBox uses it to scope project credentials.

## Connect Codex

The app includes a **Connect Codex** action. Equivalent command:

```bash
codex mcp add agentkeybox \
  --env AGENTKEYBOX_AGENT_ID=codex \
  --env AGENTKEYBOX_AGENT_NAME=Codex \
  -- "$HOME/Library/Application Support/AgentKeyBox/bin/agentkeybox-mcp"
```

Verify with:

```bash
codex mcp get agentkeybox --json
```

Codex starts the MCP helper in the session's working directory, which AgentKeyBox uses as the project path unless `AGENTKEYBOX_PROJECT_PATH` is supplied. Verified with Codex 0.160.

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

**Experimental alpha.** Verified on a real Mac: Keychain storage behind Touch ID, the approval prompt, session approvals, Developer ID signing and notarization, and installing from a download. Also verified end to end with real Claude Code and Codex sessions.

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

The interface is project-centric and import-first: drop a project folder, confirm once, and approve requests in plain language. Technical details stay behind progressive disclosure so users do not need to understand secrets-management infrastructure.

See [`docs/UI_DIRECTION.md`](docs/UI_DIRECTION.md) for the design direction.


## Brand direction

The current visual identity uses the **Key in a Box + Agent** concept: the box represents controlled local storage, the key represents developer credentials, and the agent represents AI coding agents that must request access.

See [`docs/BRAND.md`](docs/BRAND.md) for the visual rationale, color tokens, icon geometry, UI translation rules, and future asset requirements. The selected raster reference lives at [`assets/brand/agentkeybox-app-icon.png`](assets/brand/agentkeybox-app-icon.png).
