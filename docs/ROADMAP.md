# Roadmap

Updated on 2026-10-26 with native protected JSON import acceptance and QA launch isolation checks for the unreleased increments. Checked baseline items describe existing implementation or historical release verification; new verification is recorded separately below and in SESSION_STATUS. See [SESSION_STATUS.md](SESSION_STATUS.md) for evidence and partial-completion details.

The selected direction is approved agent use of sensitive data without exposing raw values to the agent. Typed card/recovery-code storage and controlled HTTPS field submission now exist in the working tree; restricted traditional browser login and recovery continuation also exist; real-provider sign-in validation and browser checkout remain open. See [PRODUCT.md](PRODUCT.md) for requirements and exclusions.

## P0 — public alpha gate

- [x] Swift/SwiftUI macOS app skeleton
- [x] Keychain secret storage
- [x] project grouping
- [x] `.env` import
- [x] `.p8`, `.pem`, JSON import
- [x] Claude Code MCP adapter
- [x] Codex MCP adapter
- [x] native Allow / Deny flow
- [x] local authenticated broker
- [x] request freshness/replay guard
- [x] protected temp-file delivery
- [x] provider presets
- [x] `akb doctor`
- [x] development installer and release packaging scripts
- [x] CI, protocol smoke tests, static secret checks
- [x] real macOS compile/runtime verification
- [x] real Claude Code end-to-end approval run
- [x] real Codex end-to-end approval run
- [x] signing/notarization with a real Apple Developer identity
- [x] dedicated security contact (GitHub private vulnerability reporting)
- [x] install from a download: notarized universal app (Apple silicon and Intel), Move to Applications, agent connections that survive moving or updating the app
- [x] English and Traditional Chinese interface
- [x] broker accepts only AgentKeyBox's own signed helper and `akb`
- [x] encrypted backups that open without AgentKeyBox, and Remove Keys from Files
- [x] agent guard: Claude Code deny rules and `AGENTS.md`/`CLAUDE.md` instructions, never loosening the user's rules

## Implemented after the original MVP

- [x] session approvals (same agent session, project, key, and listed host or exact command; 8-hour limit); HTTP scope does not distinguish method, path, or body
- [x] credential edit flow
- [x] menu-bar experience
- [x] active-session count and **Ask Every Time** in Settings and the menu bar
- [x] App Store Connect / Supabase bundle metadata, validation, and grouping
- [x] generic HTTPS broker with header substitution, host review, no redirects, and bounded/redacted responses
- [x] missing-credential prompt (`request_credential`) with local entry and dashboard links

The HTTP broker is not a set of provider-specific action adapters. Read/write/delete/payment semantics and operation-scoped HTTP grants remain future work. Existing provider presets and bundles are local metadata features, not provider account-management connectors.


## UI / UX productization

The product direction is described in [`UI_DIRECTION.md`](UI_DIRECTION.md). Status for 0.4.0:

- [x] project-centric main navigation
- [x] drag-and-drop `.env`, `.p8`, `.pem`, and JSON import (a whole project folder, or single files)
- [x] guided first-run onboarding (drop a project folder; one Set Up confirmation)
- [x] Claude Code / Codex connection inside onboarding and Settings
- [x] remove simulation/debug controls from production builds
- [x] simplified approval prompt with expandable command details
- [x] first-class file credential cards
- [x] provider-aware credential bundles
- [x] first-run, empty-project, and empty-history states
- [ ] finish human-readable error handling (some errors still show system text)

Next: watch a new vibe coder install and set up the app without help, and fix where they get stuck. The goal is not simply to make the interface prettier. The goal is to make secrets infrastructure disappear behind a workflow that a vibe coder can understand immediately.

## Selected work — protected submission and browser increments, unreleased

### Controlled use of more sensitive-data types

- [x] typed protected payloads, safe agent-visible references, old-metadata compatibility, revision binding, and format-2 encrypted backups
- [x] recovery-code text/file import and replacement, reservation persisted before send, issued/used/needs-review states, and conservative backup restore
- [x] structured card storage and per-use approval bound to exact stored HTTPS URL, POST, encoding, field map, and item revision; no CVV or payment semantics
- [x] controlled endpoint-submission executor with fixed outcomes, no response-body/header/redirect output, no browser insertion, and synthetic reflection/redirect tests
- [x] implement a controlled local traditional-HTML login/task slice: protected login items, private WKWebView, native per-use approvals, constrained text/link tools, session ownership/expiry, and local termination
- [x] add a local-command controlled-browser entry point for agents without persistent stdio MCP, with session/project binding and fixed output/error boundaries
- [x] test a public demo website login with production TLS and preflight GitHub's login form without sending credentials; neither establishes GitHub sign-in/2FA compatibility
- [x] isolated native App + Keychain + normal local authentication + MCP allowed-path acceptance on a public demo website, including protected-page read and close/rejection afterwards
- [x] isolated native MCP denial and real-deadline timeout for login/card/recovery requests; pending-slot rejection through MCP and CLI; native CLI login denial and zero remaining browser sessions
- [x] isolated native CLI approved login/read, session/project ownership, stale-link rejection, and closing a browser while navigation approval is pending; cancel the matching prompt and release the approval slot without a new decision
- [x] implement restricted same-origin recovery-code continuation through MCP/CLI, a separate approval, exact stored endpoint binding, reservation before fill/POST, fixed challenge output and synthetic WebKit tests
- [x] add repeatable isolated native recovery QA with a profile-scoped loopback certificate pin, synthetic Keychain read-back statuses, receiving-server counts, and MCP/CLI allow/deny/timeout/pending-close assertions; release excludes all QA-only paths
- [x] isolated native MCP/CLI login reaches the fixed challenge, then separately approved recovery reaches the verified result; ordered server evidence confirms durable reservation before each unique code POST
- [x] isolated ad-hoc native recovery continuation end-to-end: MCP/CLI success, denial, actual 120-second timeout, pending-close, authenticated selected-item edit, cancellation during LocalAuthentication, and same-profile crash/restart after durable receipt; zero remaining browser sessions
- [x] distinguish native approval timeout/pending approval from unknown transport outcomes without returning arbitrary diagnostics; acceptance must match the exact native history decision
- [x] prepare and locally install Developer ID signed 0.4.5 with existing provisioning/Keychain entitlements, verified helper and 0.4.4 rollback; no notarization/publication
- [x] signed local 0.4.5 + data-protection Keychain + native-approved public-demo login/read/close through installed MCP; expected protected-page marker, exact history, closed-read rejection, zero sessions and disposable-item cleanup (2026-10-27)
- [ ] signed release sensitive-use acceptance and real private-account compatibility; extend beyond static same-origin forms only after validating every new observation path
  - The signed public-demo login slice passed. Signed card/recovery endpoint use with production PKI and real private-account/GitHub/checkout workflows remain open; the candidate is not notarized or published.
- [x] block new types from generic HTTP, commands, environment/temp-file delivery, and `akb run`; recognize protected JSON envelopes before generic import
- [x] cancel the selected item's pending endpoint approval/authentication on native edit/delete, preserve already-started operation outcomes, and guard against late asynchronous decision completion; add storage lifecycle drivers and real encrypted typed-backup regression coverage
- [x] isolated native endpoint pending-edit/authentication cancellation, real interrupted card save/restart, approved mismatch rejection, code-status editing/replacement and encrypted backup export/wrong-password/duplicate-import/restore acceptance; retain conservative restored statuses
- [x] complete native original/renamed protected-JSON reimport through the file picker, exact scoped Keychain readback and opened-backup/original-file exposure review
- [x] reject QA app launches without their matching profile UUID before production vault/helper/broker access; cover Launch Services reopening without the runner environment
- [x] isolated native `submit_sensitive_fields` success and abnormal outcomes: selected card fields in form/JSON, code receipt/HTTP rejection/blocked redirect/lost response, and same-profile crash/restart after durable receipt; exactly one POST per approval, no reflected output or automatic code reuse

Protected endpoint submission returns transport outcomes; the separate controlled browser now maintains private local login sessions and constrained page/link access. Restricted traditional recovery forms now have a separate approved continuation; GitHub authentication/recovery compatibility and checkout automation remain incomplete. Storage/import alone does not complete these features. A normal browser autofill followed by an agent-readable page is insufficient. Local integration work is in scope; provider-side payment or account-management services are not.

### Agent compatibility selected on 2026-10-24

- [x] verify official interfaces for dots / ChatGPT Work, Meta Muse, Grok Bot and Claude Duet, recording evidence and uncertainty in [AGENT_COMPATIBILITY.md](AGENT_COMPATIBILITY.md)
- [x] provide the `akb browser` local CLI path without exporting credentials, cookies, or scripts
- [ ] in-product acceptance on each new host; the user currently has only Codex and Claude Code, so the other products have no account-level test evidence
- [ ] resolve pure-cloud transport and provider-browser integration separately; no remote MCP service, public tunnel, connector submission or partner integration is implemented

### Approval precision and usability

- [ ] add operation/resource constraints for supported local execution paths; do not infer safety from HTTP method or the agent's purpose text alone
- [ ] credential search/filter
- [ ] observe a new user's setup and approval flow, then address demonstrated usability issues

## Earlier backlog — unimplemented, not selected for this work

- Cursor adapter
- Antigravity / Gemini CLI adapter
- GitHub Copilot, Cline, Roo Code, and Windsurf adapters
- persistent **Always Allow for Project** (session controls are already implemented)
- credential notes and further provider metadata beyond the current bundles
- optional multi-device sync, mobile approval, and team features

Standalone plaintext `.env` export is not implemented. The existing encrypted backup already contains human-readable `.env` / `env.txt` copies; its recovery use case does not require adding a new plaintext-export feature. New export paths must preserve the intended agent boundary.

## Removed from the selected direction

The earlier **Credential Lifecycle / Provider Connectors** proposal is superseded by the 2026-10-22 scope decision. Do not schedule provider-side credential creation, OAuth account connectors, GitHub App token issuance/permission management, automatic rotation/revocation, card issuance, payment processing, or provider-enforced spending limits as the next phase.

Keep existing provider presets, dashboard links, manually supplied credentials, and approved HTTP calls. Importing a GitHub recovery-code file and using a card through a controlled local workflow do not imply building the excluded services.

## Validation still open

- A real Intel Mac run remains unverified; Rosetta coverage is recorded separately.
- Broker replay rejection and `.p8` temporary-file cleanup have historical unit-test evidence, but their through-app scenarios remain unverified in the release checklist.
- Native browser allowed-path and login/card/recovery refusal/timeout now have isolated ad-hoc App/MCP evidence. Restricted browser recovery also passed native MCP/CLI success, separate approval, edit/authentication cancellation and durable reservation across a real QA process restart. Native CLI approved login/read/close, denial, ownership/stale-link rejection and pending-navigation cancellation also passed. Seven protected-field endpoint cases passed native approval, exact selected-field receipt, fixed outcomes and reservation retention across rejected/redirected/lost responses and restart. Endpoint authentication cancellation, pending edits, real interrupted saves, native code replacement and encrypted backup/restore also passed on 2026-10-26. Four original/renamed protected JSON imports, exact synthetic Keychain readback and exposure review passed on 2026-10-26. Developer ID signed local 0.4.5 public-demo login/read/close passed with the data-protection Keychain on 2026-10-27; its disposable item was removed and original metadata restored byte-identically. Successful readable follow, real provider workflows, and signed card/recovery use with production PKI remain open. The public demo's Logout link leads to another password form, which current observation policy intentionally refuses.

Use [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) for historical evidence and [MACOS_TEST.md](MACOS_TEST.md) for repeatable runtime checks. This documentation reconciliation does not check off those remaining tests.
