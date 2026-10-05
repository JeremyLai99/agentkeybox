# Changelog

## Unreleased

### Added

- `http_request` MCP tool: AgentKeyBox performs one approved HTTPS request with the credential placed in a header via `{{secret}}`. Enforces https, per-credential allowed hosts (prefilled from provider presets), header-only placement, no redirects, a timeout, and a redacted, size-limited response.
- `akb run [--only …] -- <command>`: one Touch ID approval, then the command runs in your terminal with the project's secrets in its environment — a drop-in replacement for `.env` files for dev servers.
- `request_credential` MCP tool: when a credential is missing, the user enters it in an AgentKeyBox prompt (with a link to the provider's dashboard) instead of pasting it into chat; the agent receives only the new credential ID.
- Credentials record their environment variable name and allowed hosts; `list_credentials` returns both.

### Fixed

- Approved-command output is captured through a bounded pipe and redacted before truncation (no unbounded temp file, no leaked secret prefix at the size limit).
- Secrets cannot be injected into reserved variables (PATH, HOME, DYLD_*, LD_*, NODE_OPTIONS, …); variable names must be ASCII.
- The risk warning recognizes versioned interpreters, bun/deno, launchers such as env/xargs, package runners that execute project scripts, and executables inside the project.
- `.env` import lets the user choose entries (likely secrets preselected) and updates existing credentials instead of duplicating them.
- A corrupt metadata file is moved aside instead of being overwritten by the next save.
- Approval and credential prompts appear in their own floating panel, so they still show when the main window is closed.
- Approval prompts show one argument per line with control and bidi characters escaped, and scroll instead of pushing the buttons off-screen.
- Simulation buttons are compiled into debug builds only.
- Fixed two Swift 6 compile errors that prevented the macOS broker client/server from building.
- Moved the local broker from TCP port 49321 (bound on all interfaces) to an owner-only Unix-domain socket; removed the bypassable string-based loopback check.
- The MCP helper now fails immediately with "AgentKeyBox is not running" instead of waiting for the full timeout.
- The approval timeout no longer fires after the user approves, so a slow approved command is no longer reported as an approval timeout after it already ran.
- Concurrent broker requests can no longer both claim the single approval slot and leak a pending continuation.
- `.env` and key-file imports now ask which project the credentials belong to instead of using the first project.
- Raised the broker client timeout to cover the approval wait plus command execution.
- Added Unix-socket broker round-trip, auth, and app-not-running tests.
- Approval confirmation now uses Touch ID with login-password fallback. The biometrics-only policy reported "not enrolled" on a real Mac with Touch ID set up, so approvals were silently granted on a single click.
- The app now finds agent CLIs installed outside the minimal Finder PATH (e.g. `~/.npm-global/bin`) by consulting the login-shell PATH and common install locations, and passes that PATH to agent CLI child processes. "Connect Claude Code" previously reported "Not installed" when launched from Finder.
- Agent CLI lookup now searches directories in a deterministic order.
- A Touch ID / password prompt is now dismissed when its approval times out, instead of staying on screen with nothing behind it.
- Team-signed builds store secrets in the data protection keychain with user presence required, and reuse the approval's Touch ID authentication to read them: one approval now costs one prompt instead of Touch ID followed by repeated keychain password dialogs. Legacy-keychain items are migrated on first read; unsigned development builds keep using the legacy keychain.
- Removed the "Require Touch ID" toggle; every approval now requires Touch ID or the login password.
- `Scripts/build-release-macos.sh` can embed a provisioning profile and sign with keychain entitlements (`AGENTKEYBOX_PROVISIONING_PROFILE`), and signs helpers separately instead of using `--deep`.

## 0.3.0 — pre-alpha

- Hardened reusable approval identity with exact executable/argument binding.
- Added best-effort SIGKILL escalation for timed-out direct child commands.
- Added `make check` / `Scripts/check-all.sh` and implementation-status documentation.

- Added Claude Code + Codex stdio MCP integration.
- Added local authenticated broker and native approval flow.
- Kept raw secrets inside the AgentKeyBox app process during approved command execution.
- Added request timestamp/replay protection and broker size limits.
- Added process timeout, minimal inherited environment, output truncation, and expanded direct-value redaction.
- Added protected temporary-file secret delivery for `.p8`, `.pem`, and JSON workflows.
- Added project-scope path resolution and provider presets.
- Added optional Touch ID confirmation when available.
- Added `akb doctor`, `akb connect`, macOS install/package scripts, CI, and static security checks.
- Expanded core test suite.
