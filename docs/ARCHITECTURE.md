# Architecture — AgentKeyBox

## 1. Goal

AgentKeyBox is a **local-first macOS credential wallet and approval broker for AI coding agents**.

The MVP validates one interaction:

```text
agent needs credential
        ↓
AgentKeyBox shows context
        ↓
user approves or denies
        ↓
approved local operation runs
```

The architecture deliberately avoids accounts, hosted databases, cloud secret storage, and team policy systems.

## 2. Technology stack

- Language: Swift 6
- UI: SwiftUI
- Platform: macOS 14+
- Secret storage: macOS Keychain (`Security.framework`)
- Local authentication: Touch ID, falling back to the login password, through `LocalAuthentication`
- Agent protocol: stdio MCP
- Local broker: authenticated Unix-domain socket at `~/Library/Application Support/AgentKeyBox/broker.sock` (owner-only `0700` directory)
- Metadata: local JSON snapshot with owner-only permissions where supported
- Backend: none

## 3. Process architecture

```text
┌──────────────────────┐
│ Claude Code / Codex  │
└──────────┬───────────┘
           │ stdio MCP
           ▼
┌──────────────────────┐
│  agentkeybox-mcp     │
│                      │
│  no raw secret value │
└──────────┬───────────┘
           │ authenticated Unix-socket request
           ▼
┌──────────────────────────────────────┐
│ AgentKeyBox.app                      │
│                                      │
│ Project resolver                     │
│ Approval UI                          │
│ Keychain access                      │
│ Approved command runner              │
│ Output redaction                     │
└──────────┬───────────────────────────┘
           │
           ▼
┌──────────────────────┐
│   macOS Keychain     │
└──────────────────────┘
```

The MCP process receives credential metadata, approval outcome, exit code, and redacted output. The app does not intentionally return the raw credential to MCP.

## 4. Agent adapter layer

AgentKeyBox integrates with **agent hosts**, not model names.

```text
ClaudeCodeAdapter ─┐
                   ├── MCP helper ──→ normalized BrokerRequest
CodexAdapter ──────┘
```

`AgentAdapter` currently supports:

- installation detection
- MCP registration
- integration status checks

P0 adapters:

- Claude Code
- OpenAI Codex

Planned adapters:

- Cursor
- Google Antigravity / Gemini CLI lineage
- GitHub Copilot
- Cline
- Roo Code
- Windsurf

## 5. Secret storage

Raw values are stored under a dedicated Keychain service.

Team-signed builds (signing identity + provisioning profile, see `Scripts/build-release-macos.sh`) use the **data protection keychain**:

```text
kSecUseDataProtectionKeychain = true
kSecAttrAccessControl         = WhenUnlockedThisDeviceOnly + .userPresence
access group                  = <TEAM_ID>.dev.agentkeybox
```

Every secret read therefore requires Touch ID or the login password. The approval prompt's authenticated `LAContext` is passed to the read (`kSecUseAuthenticationContext`), so one approval costs exactly one prompt. Access is bound to the team's access group rather than a per-build code signature, so rebuilding or updating the app never triggers keychain password dialogs. Items created by older builds in the legacy keychain are migrated on first read.

Ad-hoc / unsigned development builds cannot use the data protection keychain (`errSecMissingEntitlement`) and fall back to the legacy file-based keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Its access control is tied to the exact build, so macOS asks for the login password after each rebuild. The app shows which mode is active.

Metadata is stored separately and contains only fields such as:

```text
id
label
service
projectID
environment
kind
createdAt
updatedAt
```

Metadata must never contain secret bytes.

Supported credential kinds:

- API key
- token
- environment-variable value
- `.p8`
- `.pem`
- JSON credential

## 6. Secret delivery modes

### Environment

For UTF-8 credentials such as API keys:

```text
Keychain value
    ↓ approval
approved process environment variable
```

Binary/non-UTF-8 data is rejected in this mode rather than silently Base64-encoded.

### Protected temporary file

For tools that expect credential files:

```text
Keychain bytes
    ↓
0700 temporary directory
    ↓
0600 credential file
    ↓
file path injected via environment variable
    ↓
approved process exits
    ↓
temporary directory deleted
```

This is the intended delivery mode for many `.p8`, `.pem`, and service-account JSON workflows.

## 7. Project identity

Credential visibility is either:

- global, or
- bound to a configured local project root.

Path resolution standardizes and resolves symlinks. A request is considered inside a project when the request path equals the project root or is a descendant path separated by `/`.

This avoids simple prefix confusion such as:

```text
/project
/project-malicious
```

being treated as the same scope.

Claude Code provides `CLAUDE_PROJECT_DIR` to local stdio MCP servers. The current Codex prototype falls back to the MCP process current working directory unless `AGENTKEYBOX_PROJECT_PATH` is supplied. Codex project-path behavior remains an explicit real-Mac verification item.

## 8. Local broker security

The app creates a random per-install broker token at:

```text
~/Library/Application Support/AgentKeyBox/broker-token
```

Intended permissions:

- directory: `0700`
- token: `0600`

Each `BrokerRequest` also contains:

- random request UUID
- issue timestamp

The broker rejects:

- missing/wrong auth tokens
- requests outside the freshness window
- replayed request IDs
- oversized input

The broker listens only on a Unix-domain socket inside the owner-only support directory, so it is never reachable from the network, other macOS users cannot connect to it, and no other process can squat on a well-known TCP port to impersonate it.

This prevents accidental unauthenticated local use, but does not protect against malware already executing as the same macOS user.

## 9. Approval model

Current UI exposes:

- Allow Once
- Deny

The core also contains session/project approval primitives for experimentation, but persistent approval UX is intentionally not exposed yet.

Any future reusable grant is bound to:

- agent
- project path
- credential
- exact executable path and argument array
- environment variable
- delivery mode
- session ID where applicable

A prior grant should not silently authorize a different generic command.

## 10. Command execution boundary

`run_with_secret` accepts an **absolute executable path**, argument array, environment variable name, purpose, and delivery mode.

AgentKeyBox:

- verifies the executable exists
- validates the environment-variable name
- uses the project directory as the process working directory
- passes only a small allowlist of inherited environment variables
- enforces a default 60-second timeout
- escalates a timed-out direct child from termination to `SIGKILL` if needed
- limits captured output to 128 KiB
- deletes temporary secret files after execution

The approval UI flags high-risk categories such as:

- shells/interpreters
- network tools
- inline code flags
- explicit network URLs

## 11. Redaction

Captured output is scanned for direct representations of the approved secret including:

- raw UTF-8 value
- percent-encoded value
- JSON-escaped direct value
- Base64
- lower/upper hex

These checks reduce accidental echoing. They are **not** a data-loss-prevention boundary: an approved process can transform, split, hash, encrypt, or transmit a credential.

## 12. Threat model

### In scope

- accidental paste into AI chat
- AgentKeyBox logging raw secrets
- plaintext metadata storage of raw secrets
- project path confusion
- stale/replayed broker requests
- accidental environment inheritance to child processes
- long-running approved processes
- direct/raw secret echoes in captured output
- accidental leftover temporary credential files

### Out of scope for current alpha

- malware with user-level access
- root compromise
- malicious kernel/system extensions
- compromised Keychain
- malicious dependencies running with the user account
- an approved command intentionally exfiltrating transformed secret material
- physical attacks against an unlocked machine

## 13. Local authentication

When enabled, every approval requires device-owner authentication (`.deviceOwnerAuthentication`): Touch ID when available, otherwise the macOS login password. Only a Mac with no local authentication configured at all falls back to the native approval dialog alone.

This is separate from Keychain storage and should not be described as making approved commands sandboxed.

## 14. Diagnostics

The `akb` CLI provides:

```text
akb doctor
akb status
akb connect claude
akb connect codex
akb connect all
akb helper-path
```

Doctor checks:

- platform
- MCP helper discovery
- broker-token initialization
- broker responsiveness on macOS
- Claude Code installation/configuration
- Codex installation/configuration

## 15. Build and distribution

SwiftPM builds three executables:

```text
AgentKeyBox
agentkeybox-mcp
akb
```

`Scripts/build-release-macos.sh` assembles a minimal `.app` bundle, embeds the MCP helper/CLI, performs ad-hoc signing by default, zips the bundle, and emits a SHA-256 checksum.

A real public binary still requires:

- Developer ID signing
- notarization
- real-Mac launch testing

## 16. No-backend rule

The MVP has:

- no account
- no hosted database
- no remote AgentKeyBox API
- no cloud sync
- no hosted credential storage
- no billing backend

A backend should only be introduced if usage validates demand for encrypted multi-device sync, mobile approval, or teams. If sync is ever added, secret encryption must occur client-side before secret material leaves the Mac.

## 17. Remaining architecture questions

The codebase intentionally leaves these unresolved until real usage:

- whether generic command execution should survive beyond alpha or be replaced by provider-specific HTTP/proxy capabilities
- the most trustworthy Codex project-root signal
- how session approvals should be represented in UX
- whether file credentials should eventually use dedicated provider bundles instead of generic temp files
