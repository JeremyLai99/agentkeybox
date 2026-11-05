# Architecture — AgentKeyBox

## 1. Goal

AgentKeyBox is a **local-first macOS system for approved agent use of sensitive data**. Its target is to let an agent complete the approved task while keeping raw values outside the agent/model's readable context.

Reconciled with 0.4.0 source on 2026-10-22. The released baseline supports developer credentials. The working tree additionally implements typed cards/recovery codes and an experimental controlled HTTPS field-submission path; a second unreleased increment implements a restricted local traditional-form browser workflow. See [PRODUCT.md](PRODUCT.md).

The intended interaction is:

```text
agent requests an operation using an item reference
        ↓
AgentKeyBox shows context
        ↓
user approves or denies
        ↓
controlled local operation uses the sensitive value
        ↓
agent receives an outcome without the raw value
```

The architecture deliberately avoids accounts, hosted databases, cloud secret storage, and team policy systems.

Current command execution does not fully enforce this target: an approved process receives the secret and can disclose it. HTTP substitution stays inside the app, but redaction alone does not contain arbitrary responses or independent agent observation tools. Keep these boundaries explicit when describing implemented behavior.

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
│ HTTPS request executor               │
│ Approved command runner              │
│ Output redaction                     │
└──────────┬───────────────────────────┘
           │
           ▼
┌──────────────────────┐
│   macOS Keychain     │
└──────────────────────┘
```

The MCP process receives credential metadata, approval outcome, and either command results or an HTTP status and redacted body. The app does not intentionally return the raw credential to MCP. The separately approved `akb run` path hands raw values to the CLI and its child process; it is outside any guarantee that the agent cannot read values.

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

Unimplemented adapter backlog (not part of the selected sensitive-data work):

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

Secret reads require a valid user-presence authentication context. The approval prompt's authenticated `LAContext` is passed to the read (`kSecUseAuthenticationContext`), avoiding a second prompt for that read. Opt-in session grants reuse the context for eligible requests until revoked or expired. Access is bound to the team's access group rather than a per-build code signature. Items created by older builds in the legacy keychain are migrated on first read.

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

`CredentialMetadata.settings` and `CredentialSummary.settings` are visible to agents and can be injected next to a key. They are only for non-secret companion values, such as App Store Connect IDs and a Supabase project URL. Never extend these dictionaries with full card numbers or recovery codes. Sensitive structured fields belong in protected payloads.

Supported credential kinds:

- API key
- token
- environment-variable value
- `.p8`
- `.pem`
- JSON credential

## 6. Secret delivery modes

### App-executed HTTPS request — implemented

`http_request` validates the request, obtains approval (or an eligible session grant), reads the credential in the app, substitutes `{{secret}}` in header values, and sends the request itself.

- HTTPS only; no URL credentials or secret placeholders in URL/body.
- Host classification against the credential's list: listed, unrestricted, or unlisted. An unlisted destination prompts with a warning and Deny as default; a deliberate approval may allow it and optionally remember the host. The list is not an unconditional deny rule.
- No redirects or shared cookie storage; default 30-second timeout and 128 KiB returned-body limit.
- Common representations of the credential are redacted before truncation.

This is a generic HTTP executor with provider host presets, not provider-specific read/write/payment operations. See [HTTPRequestBroker.swift](../Sources/AgentKeyBoxCore/HTTPRequestBroker.swift).

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

Claude Code provides `CLAUDE_PROJECT_DIR` to local stdio MCP servers. Codex starts the MCP helper in the session's working directory, which AgentKeyBox uses as the project path unless `AGENTKEYBOX_PROJECT_PATH` is supplied; verified with Codex 0.160.

## 8. Local broker security

Team-signed builds verify each caller: the broker reads the connecting process's audit token from the socket and checks that it is AgentKeyBox's own helper or `akb`, validly signed by the same team. Only `akb` may make `akb run` requests, which return raw secrets.


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
- an optional **Don't ask again during this session** checkbox for eligible, unflagged requests
- active-session count and **Ask Every Time** in Settings and the menu bar

Session grants are in memory, expire after at most eight hours, and reuse the original authentication context. A new MCP helper session or app restart requires approval again. **Ask Every Time** clears local grants; it does not revoke credentials at the service.

Every session grant is bound to:

- agent
- project path
- credential
- helper session ID
- commands: exact executable path, argument array, environment variable, and delivery mode
- HTTP: the same listed host; method, path, headers, and body are not part of the grant scope

Unlisted/unrestricted HTTP hosts and `akb run` are ineligible. The UI does not offer session grants on flagged requests. Persistent project-wide approval is not implemented; enum cases do not constitute an exposed feature.

This is invocation/host scoping, not semantic operation isolation. A command can execute changed scripts, and a same-host HTTP grant can cover different actions permitted by the underlying credential. Future controlled workflows need operation/resource binding. See [ApprovalEngine.swift](../Sources/AgentKeyBoxCore/ApprovalEngine.swift) and [ApprovalPresentation.swift](../Sources/AgentKeyBoxCore/ApprovalPresentation.swift).

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

Interactive approvals use device-owner authentication (`.deviceOwnerAuthentication`): Touch ID when available, otherwise the macOS login password. There is no user-facing toggle to disable it. Eligible session requests reuse the approved authentication context. `LocalAuthenticator` returns no context when `canEvaluatePolicy` reports local authentication unavailable; the Keychain access policy still applies to the subsequent read.

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

`Scripts/build-release-macos.sh` assembles the `.app`, embeds helpers and production assets, supports universal builds and Developer ID signing with a provisioning profile, and emits a ZIP/checksum. Ad-hoc signing remains the development default. `Scripts/notarize-release-macos.sh` submits, staples, validates, and repackages a Developer ID build.

Developer ID signing, notarization, downloaded-app launch, and Rosetta execution were already verified for 0.4.0 in [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md). They are release checks to repeat for new binaries, not unimplemented next-phase capabilities. A physical Intel Mac run remains open.

## 16. No-backend rule

The MVP has:

- no account
- no hosted database
- no remote AgentKeyBox API
- no cloud sync
- no hosted credential storage
- no billing backend

The selected credit-card and recovery-code work keeps this local architecture. Provider-side credential creation, OAuth account connectors, automatic rotation/revocation, GitHub App token issuance, card issuance, and payment/spending-control services are excluded from the selected direction. Existing HTTP calls, dashboard links, and local provider presets remain in scope. Earlier sync/mobile/team ideas are unselected backlog, not prerequisites for this work.

## 17. Protected-field submission — unreleased

`SensitivePayload.swift` owns version-1 Keychain envelopes for cards and recovery-code sets. `CredentialMetadata` holds an optional exact `submissionURL` and `payloadRevision` UUID. No raw card fields, code list, or remaining-code count is metadata. Old developer-credential metadata decodes without those optional fields. `CredentialSummary` omits injection variables, settings, and allowed-host lists for the new types.

`SensitiveItemView` provides native creation/editing, text/file code import, and per-entry local status. Editing existing data authenticates separately from a pending broker approval. Each edit gets a fresh payload revision, written in both metadata and the payload. Revision mismatch after a partial save fails closed for use and backup; recreate/restore the affected item rather than silently pairing stale data with a new destination. Recognized exported envelopes cannot fall back to generic JSON credentials, even after renaming the file; malformed or future envelopes are rejected.

The MCP tool `submit_sensitive_fields` maps to broker action `submitSensitiveFields` and approval kind `sensitiveSubmission`. The app validates the stored exact HTTPS endpoint and bounded fields before showing approval. The POST, encoding, full placeholder/literal field map, item, and destination are fixed by that request; the credential's update timestamp is checked again after approval and Keychain reading. Deny is the default. Session grants and host overrides are unavailable.

`SensitiveSubmissionPolicy` substitutes only whole-field placeholders and produces a form-encoded or flat JSON POST. It does not accept arbitrary headers, URLs, browser state, or programs. The app rejects controlled types on generic HTTP, command, temp-file and environment delivery paths; generic executors also reject protected envelopes that were previously misclassified. `SensitiveSubmissionExecutor` checks payload revision before preparing any request.

The existing main-actor approval slot stays reserved throughout approval, authentication, reservation, and execution. A second broker request cannot enter during that period. Before a recovery-code request can reach networking, the executor synchronously saves the selected entry as `issued` in Keychain and updates metadata. Failed persistence aborts. Restart, network error, rejection, or redirect never releases it. The code set is not remotely synchronized; `used` and corrections require local authenticated input. Replacing a set preserves status for matching values. Backup restore marks all non-used entries `needsReview`.

A dedicated ephemeral URLSession has no cookie store, credential store, or cache, retains normal TLS trust evaluation, cancels other authentication challenges, and declines redirects. Response-body delivery is cancelled at the headers. Only a fixed `SensitiveSubmissionOutcome` enum leaves the executor; the broker/MCP return no upstream strings, encoded reflections, response URLs, or network diagnostics. The app does not retry automatically. `received` means HTTP 2xx, not proven payment/login success.

The intended endpoint receives selected fields and must be trusted; AgentKeyBox cannot stop it from publishing them to another agent-readable channel. This workflow never inserts values into a browser DOM or executes an agent-supplied program. It does not protect original imported files, clipboard contents, decrypted backup copies, native editing from same-user automation, or a compromised user session. See [SECURITY.md](../SECURITY.md).

## 18. Remaining design work

- Complete native app/MCP verification of the browser and restricted recovery continuation described below. Validate new observation paths before adding JavaScript applications, TOTP, other challenge forms, or checkout. Endpoint submission alone does not complete those tasks.
- Define task-specific outcomes and operation constraints; HTTP method and an agent's reason do not establish transaction semantics.
- Complete native GUI/Touch ID, through-app denial/timeout, concurrent request, and crash/restart validation for the new path before release.
- Keep generic-command compatibility and existing file delivery distinct from the controlled path.
- Preserve the selected scope: no provider-side OAuth, token lifecycle, GitHub App management, payment processing, or spending-limit service.


## Controlled browser increment (2026-10-23, unreleased)

`BrowserPolicy.swift` owns HTTPS origin rules, helper/agent/project ownership, bounded session lifetime and the synchronous observation lease. `BrowserScripts.swift` contains only app-authored, isolated-world scripts. `ControlledBrowser.swift` owns the private WKWebViews, navigation policy, cookie handoff and fixed diagnostics. The app handles item visibility, native approval, authentication, revision binding, and the maximum of four active sessions. MCP carries references and constrained page results only.

Flow:

1. `browser_login(credential_id)` creates a fresh non-persistent browser and visits only the user-stored HTTPS sign-in page. No credential is read during preflight. Page JavaScript, scripts, media, stylesheets, XHR/raw subresources and popups are disabled/blocked; child-frame navigation is denied.
2. An app-owned script in `WKContentWorld` requires exactly one username candidate and one password field in the same ordinary POST form, with an exact same-origin action and no action query/fragment, target override, OTP/new-password field, or submit-button overrides. The native approval names this actual POST destination; agents cannot provide selectors, URLs or JavaScript.
3. The app revalidates metadata and payload revision after approval/authentication. The lease closes observation before filling. The app uses argument-bound `callAsyncJavaScript`, native input setters and native form submission; it does not execute page handlers. Cross-origin/non-HTTPS navigation, unsupported content, errors and process termination fail closed. Production TLS uses system trust; the runtime-test subclass pins a newly generated test certificate without changing system trust.
4. After a full document navigation, the old browser, history and storage are discarded. Only same-site cookies are copied internally to a new ephemeral browser, which GETs the landing page. A supported recovery form produces only a fixed challenge state; remaining password/OTP or unsupported recovery inputs prevent page observation. This requires a repeatable landing URL; JS and arbitrary multi-step/one-use landing flows are outside this increment.
5. `browser_read` exposes bounded text and same-origin links with fresh UUIDs. It does not expose HTML/attributes/form values/frames/scripts/cookies/storage/response headers, actual link URLs or an evaluation/screenshot API. Login and cookie values and common encodings are additionally redacted, with capture-boundary handling. This redaction is defense in depth, not a guarantee against an intentionally reflecting destination.
6. `browser_follow` resolves a current link UUID internally, binds its URL to a new native approval, then returns another constrained page. Every follow is separately approved; no standing grant is created. `browser_close`, native End Browser Access, item edit/delete, process exit or 15-minute expiry invalidate local access. Closed leases cannot be reopened by a late callback. Native termination also dismisses any pending browser prompt.

The WKWebView is never attached to a window, so it has no rendered screen or attached accessibility surface for the agent. Inspectability is disabled. This controls the supported MCP observation channel; it does not protect against process-memory inspection, same-user automation of the native editor, decrypted backups, or a compromised OS. A trusted destination receives the submitted values by design. Account actions performed elsewhere by an agent are not governed by this browser.

Reference decisions: 1Password's [published Claude integration](https://support.1password.com/1password-claude-security/) demonstrates pausing observation around fill/submission; its [platform announcement](https://1password.com/blog/1password-for-ai-agents) says safeguards vary by integration. This implementation chooses an app-owned browser with website JavaScript disabled rather than assuming an arbitrary external browser will cooperate. WebKit's [WKWebView API](https://developer.apple.com/documentation/webkit/wkwebview) and [inspectability guidance](https://webkit.org/blog/13936/enabling-the-inspection-of-web-content-in-apps/) describe the underlying native surface; they do not by themselves establish an agent security boundary.

### Restricted recovery continuation (2026-10-24)

`BrowserRecoveryPolicy` validates the selected recovery item's exact stored HTTPS endpoint against the discovered same-origin action and persists a revision-bound `issued` reservation before returning a code internally. The existing native approval slot and Keychain payload format are reused; no new service, dependency or credential schema is needed.

The lease transitions from `recoveryRequired` to `awaitingRecoveryApproval` and then `authenticating`. The core binds the exact selected metadata; the app rechecks project visibility, item revision and login ownership around authentication. Editing/deleting the selected code set cancels its pending browser approval. Deny, timeout, local termination and failed persistence never submit a code. Once persisted, an uncertain result keeps the reservation.

App-owned isolated-world scripts recognize only a traditional form-encoded POST with one visible writable text input named `recovery_code` or `recovery-code`, hidden fields and optional submit/button controls. The agent receives a fixed `recoveryCodeRequired` response, not the page's challenge text, action or links. `browser_recover` accepts only browser/item references and an optional purpose. After native approval it fills and submits privately, destroys the filled view and repeats the cookie handoff before observation. A repeated challenge fails closed without a second code attempt. Login, submitted-code and cookie reflections plus common encodings are filtered from output; the trusted-destination limitation still applies.

Keeping this step in the app-owned browser preserves the existing private cookie/CSRF state. The standalone endpoint submitter cannot continue that browser session, and arbitrary agent-directed form filling would expand the observation and authorization surface. The tradeoff is deliberately narrow form compatibility and a repeatable landing GET. Synthetic WebKit coverage does not establish native approval end-to-end or GitHub compatibility.

### Local command adapter and host compatibility

`BrowserAgentInvocation` maps `akb browser` commands into the same broker actions. It rejects unknown/duplicate arguments, raw URL/script/selector/credential-value fields, invalid UUIDs and relative project paths. A login creates a fresh client session UUID; later CLI processes use it with the browser UUID and original project. The `recover` command adds a stored recovery-item UUID and maps to the same separately approved browser action; listing includes safe `recoveryCodeSets` references. `BrowserAgentResult` whitelists page/metadata/handle fields rather than serializing `BrokerResponse`, which also supports the unrelated raw-environment path for `akb run`. Errors are fixed diagnostics. The fixed `akb-browser` identity names the AKB binary entry point and is not vendor authentication.

This adds no server port or remote authentication surface. A caller must execute the helper or CLI on the same Mac and pass the existing broker peer policy. [AGENT_COMPATIBILITY.md](AGENT_COMPATIBILITY.md) separates official host interfaces, implementation and in-product evidence. Pure-cloud transports and injecting credentials into a provider-owned browser require additional work and are not implied by this adapter.

`DevelopmentProfile` is a DEBUG-only runtime selector for isolated native acceptance. The app, helper and CLI share a UUID-named temporary broker/token directory; only the app uses the profile's separate Keychain service and metadata/history paths. Release builds cannot read the selector. The QA runner uses an independent bundle/preferences domain, refuses release helpers, skips connection installation/login registration, and cleans up only its own fixture. Normal native approval and authentication remain mandatory.

The optional `--recovery` runner mode adds `DevelopmentRecoveryFixture`, compiled only in DEBUG on macOS. It accepts a profile-bound configuration, a high loopback port, and a per-run certificate. Only the exact seeded login can create its browser. The challenge handler pins the exact leaf, host and port and still evaluates hostname/validity against that scoped anchor; it never changes system trust. Production browsers and public-demo QA retain system TLS. The local fixture was chosen because the public demo has no recovery form and a remotely deployed fixture would require external hosting. This proves the app/approval/Keychain/browser flow, not public PKI or release Keychain entitlements.

This QA mode reads back only its four known synthetic recovery values from the isolated legacy Keychain and exports statuses to its private profile directory. The server records whether `issued` was persisted before each POST. It logs no raw request fields. Existing fixture storage is preserved on relaunch instead of re-seeding consumed codes. Config, pinning, synthetic values and status-export code must all be absent from release executables; malformed fixture configuration fails closed. The acceptance client validates exact native history plus fixed challenge output, server counts and status evidence, and requires human local authentication.

The recovery QA fixture now seeds four synthetic codes and records an ordinal-only server ledger, rejecting duplicate use. DEBUG-only authentication phase and fresh-boot markers let acceptance distinguish cancellation during LocalAuthentication from a transport failure, and confirm that a restarted app re-read issued statuses from Keychain. These markers neither grant authentication nor change approval decisions. The runner restarts the same isolated profile only when its test client explicitly arms the one-shot restart flag; it never resets the payload.

The mutually exclusive `--submission` mode adds `DevelopmentSubmissionFixture` for native endpoint acceptance. Only the two seeded card/code item IDs and their exact configured loopback destinations can select its DEBUG-only transport pin. The real `SensitiveSubmissionTransport` still performs encoding, POST, redirect rejection and response suppression; only certificate handling for that profile is scoped to its exact leaf/host/port. A real-network test checks both positive pinning and rejection by the production transport, a wrong destination and a different valid certificate. All fixture code and paths are excluded from release builds.

Submission QA seeds one synthetic card and eight codes into the isolated legacy Keychain. A read-back validates the known values but exports only statuses; the server records field/content-type/privacy validation flags, code ordinal and whether reservation preceded POST. The client validates exactly one new native decision and receipt, fixed outcomes, metadata invariants and no reflected values. Its crash case holds the response after receipt, terminates only the verified QA process, and requires a fresh Keychain-backed boot plus a responding broker without another POST. Existing stored state is retained on relaunch. This verifies native endpoint execution through MCP; the browser CLI does not acquire a new endpoint-submission command.

Native protected edits now invalidate the matching pending endpoint approval/authentication, as well as its browser access. Deletion applies the same invalidation after metadata removal succeeds. An executing-submission request ID distinguishes a pending authentication wait from an already-started operation: editing cannot cancel a POST that has already left the app or relabel its outcome as an unused credential. Existing timestamp/revision checks still guard the read/preparation phase.

DEBUG submission QA additionally records authentication phase, payload-revision match flags and recovery generation, without values. A one-shot synthetic-card hook exposes the actual gap between metadata commit and Keychain save to a verified-process crash driver. It is bounded to ten seconds and falls back to the existing rollback path if no crash occurs. Neither this hook nor the phase/storage evidence exists in release builds. Native backup acceptance uses the real Settings UI and encrypted disk-image implementation; a separate fixture-only inspector validates known contents without printing payloads.
