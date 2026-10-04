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
- optional local biometric confirmation when macOS supports it
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

## Requires a real Mac

These items rely on macOS-only frameworks or locally installed agent applications and therefore cannot be truthfully validated in this execution environment:

- SwiftUI application target type-check/runtime on macOS
- real Keychain read/write behavior
- Touch ID prompt behavior
- Network.framework broker runtime behavior
- `.app` code signing/notarization with a real Developer ID
- Claude Code end-to-end MCP registration/request flow
- Codex end-to-end MCP registration/request flow
- confirmation of Codex MCP working-directory/project-path behavior
- final native approval-sheet UX and focus behavior

Follow `docs/MACOS_TEST.md` for the remaining gate.

## Alpha boundary

AgentKeyBox reduces accidental secret exposure. It is not a sandbox or a DLP system. If the user explicitly approves a malicious executable, that executable can use or exfiltrate the credential it receives. This must remain explicit in public-alpha messaging.
