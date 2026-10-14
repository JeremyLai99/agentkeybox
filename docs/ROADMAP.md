# Roadmap

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
- [ ] real Claude Code end-to-end approval run (approvals verified through the MCP helper; not yet from a Claude Code session)
- [ ] real Codex end-to-end approval run
- [x] signing/notarization with a real Apple Developer identity
- [x] dedicated security contact (GitHub private vulnerability reporting)
- [x] install from a download: notarized universal app (Apple silicon and Intel), Move to Applications, agent connections that survive moving or updating the app
- [x] English and Traditional Chinese interface

## P1 — usability validation

- [ ] Cursor adapter
- [ ] Antigravity / Gemini CLI adapter
- [x] narrowly scoped session approvals ("don't ask again during this session"; same agent session, key, and listed host or exact command; 8-hour limit)
- [x] credential edit flow
- [ ] search/filter
- [x] menu-bar experience
- [x] richer App Store Connect credential bundle metadata
- [x] safer provider-specific HTTP operations


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
- [ ] human-readable error and empty states (empty states done; some errors still show system text)

Next: watch a new vibe coder install and set up the app without help, and fix where they get stuck. The goal is not simply to make the interface prettier. The goal is to make secrets infrastructure disappear behind a workflow that a vibe coder can understand immediately.

## P2 — only after usage validates the workflow

- [ ] GitHub Copilot
- [ ] Cline
- [ ] Roo Code
- [ ] Windsurf
- [ ] encrypted multi-Mac sync
- [ ] mobile approval companion
- [ ] team sharing / policy controls


---

## Credential Lifecycle / Provider Connectors

AgentKeyBox may expand beyond storing and approving existing credentials into helping users acquire and manage credentials when an AI coding agent needs them.

### Product idea

When an agent requests a capability and no matching credential exists, AgentKeyBox can:

1. detect that the credential is missing
2. identify the relevant provider
3. determine whether the provider supports credential creation programmatically
4. ask the user for explicit approval
5. either:
   - create the credential through an official provider API, or
   - guide the user through the provider's official creation flow
6. save the resulting credential immediately into AgentKeyBox
7. make it available to the approved agent workflow
8. later support rotation and revocation where the provider allows it

```text
Agent needs capability
        ↓
Credential exists?
   ┌────┴────┐
  Yes        No
   ↓          ↓
Approve    Provider connector
and use       ↓
          Can create automatically?
          ┌─────────┴─────────┐
         Yes                  No
          ↓                    ↓
    Ask user approval     Guide user through
          ↓               official provider flow
    Create + store              ↓
          └──────────┬──────────┘
                     ↓
                  Use safely
```

### Long-term lifecycle

```text
Create / Acquire
      ↓
Store
      ↓
Approve / Use
      ↓
Rotate
      ↓
Revoke
```

### Security principle

AI agents may request a capability, but they must not independently decide to create or grant themselves high-privilege credentials.

AgentKeyBox should translate the requested task into the smallest reasonable credential scope and require human approval before credential creation or privilege escalation.

### Provider connector model

Each provider connector should know:

- how credentials are created
- whether creation can be automated through an official API
- required permissions/scopes
- relevant metadata
- expiration rules
- rotation support
- revocation support
- whether interactive login / MFA is required

Potential future connectors include:

- GitHub
- Stripe
- Supabase
- OpenAI
- Apple App Store Connect
- Cloudflare
- Vercel
- Firebase / Google Cloud

Provider support must be verified against official provider APIs and security requirements before implementation.

### Roadmap placement

This is **not part of the initial MVP**.

It becomes a priority only after AgentKeyBox validates the core behavior:

> Agent requests credential access → user approves → workflow continues more easily than copy/paste.

After that validation, the first lifecycle experiment should support **one provider only**, chosen based on:

- clear official API support
- common usage among AI-first developers
- low risk of privilege escalation
- measurable reduction in setup friction
