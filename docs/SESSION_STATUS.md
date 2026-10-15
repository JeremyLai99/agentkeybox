# AgentKeyBox implementation status

This file distinguishes what is implemented and testable in the repository from what still requires a real macOS machine.

## Implemented in the repository

### Core product path

- native Swift/SwiftUI macOS application target
- local-only architecture; no backend/account/cloud database
- macOS Keychain secret storage implementation
- project and credential metadata persistence separated from secret bytes
- `.env` import
- `.p8`, `.pem`, and JSON credential import
- common provider presets
- project-scoped credential visibility
- MCP helper shared by Claude Code and Codex
- `list_credentials` MCP tool exposing metadata only
- `run_with_secret` MCP tool
- native Allow Once / Deny approval state
- Touch ID (or login password) confirmation for every approval
- protected temporary-file delivery for file credentials
- environment-variable delivery for UTF-8 credentials
- output capture limits and common secret redaction
- access-history metadata without raw secret values

### Local broker hardening

- per-install random broker token
- owner-only token/metadata file permissions where supported
- owner-only Unix-domain socket client/server design (no TCP listener)
- request UUID and timestamp freshness checks
- replay protection
- request and response size limits
- approval timeout
- exact executable + argument binding for reusable approval primitives

### Developer/alpha tooling

- `akb doctor`
- `akb connect claude`
- `akb connect codex`
- `akb connect all`
- MCP protocol smoke test
- CLI smoke test
- static secret/logging checks
- one-command `make check`
- GitHub Actions for macOS and Linux
- macOS developer installer/uninstaller
- macOS release-bundle builder
- synthetic demo project
- security/contribution/roadmap/release documentation

## Verified in this execution environment

The shared Swift core, CLI, MCP server, protocol smoke tests, and static checks can be built and exercised here.

The final verification command is:

```bash
make check
```

## Verified on a real Mac

As of 0.4.0 (see [`RELEASE_CHECKLIST.md`](RELEASE_CHECKLIST.md) for the evidence):

- the SwiftUI app, Keychain storage behind Touch ID, and the Unix-socket broker
- approval prompts, denial, and "don't ask again during this session"
- Developer ID signing, notarization, and installing from a quarantined download
- the universal build's x86_64 slice under Rosetta
- real Claude Code and Codex sessions: registration, listing, approvals, denial, and redacted output; Codex's project path comes from its working directory
- the agent guard: Claude Code and Codex, started in the project, decline to read `.env` and key files
- encrypted backups: export, opening the `.dmg` in Finder, Remove Keys from Files, and import after removing the project
- approval timeout: an unanswered prompt ends after 2 minutes with `Approval timed out.` and is recorded in the access history

## Still open

- a real Intel Mac

Follow `docs/MACOS_TEST.md` for the remaining gate.

## Alpha boundary

AgentKeyBox reduces accidental secret exposure. It is not a sandbox or a DLP system. If the user explicitly approves a malicious executable, that executable can use or exfiltrate the credential it receives. This must remain explicit in public-alpha messaging.
