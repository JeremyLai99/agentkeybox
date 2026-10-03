# Product — AgentKeyBox

## 1. Product thesis

AI coding agents increasingly need access to external services such as OpenAI, Stripe, Supabase, GitHub, Firebase, and Apple developer infrastructure.

Today, many users solve this by copying credentials into `.env` files, terminal sessions, project folders, or directly into AI conversations.

The hypothesis behind AgentKeyBox is:

> If credential access becomes a simple local approval flow, vibe coders will prefer it over manually copying secrets.

AgentKeyBox is not primarily a storage product.

Its core value is:

> **Store once. Let agents ask. Approve when needed.**

---

## 2. Target user

Primary user:

- vibe coder
- indie developer
- solo founder
- AI-first builder
- developer who uses Claude Code, Codex, or similar coding agents

The user is technical enough to work with API keys, but may not understand or care about:

- RBAC
- secret brokering
- environment injection
- sidecars
- credential rotation systems
- enterprise IAM

The product should therefore hide infrastructure terminology whenever possible.

---

## 3. User problem

Typical current workflow:

```text
Claude:
"I need STRIPE_SECRET_KEY."

User:
opens Stripe
copies key
opens terminal / .env / chat
pastes key
continues
```

Problems:

- secrets become scattered
- users forget where credentials came from
- secrets may enter chat history or logs
- `.env` files may be committed accidentally
- users have no consistent way to approve or deny agent access
- repeated setup creates friction

---

## 4. Desired workflow

```text
Claude Code or Codex needs STRIPE_SECRET_KEY
        ↓
AgentKeyBox detects/request receives
        ↓
Native macOS prompt

Your coding agent wants to use:

Stripe
Project: MyApp

[ Allow Once ]
[ Allow for Session ]
[ Deny ]
        ↓
Task continues
```

The user should not need to understand how the credential is delivered.

---

## 5. MVP scope

### P0 — must have

- macOS app
- local credential storage
- macOS Keychain integration
- create/edit/delete credential
- project grouping
- text secret support
- `.p8`, `.pem`, JSON credential support
- `.env` import
- Claude Code integration
- OpenAI Codex integration
- agent request → approval prompt
- Allow Once
- Deny
- basic access history without storing secret values

### P1 — useful after core works

- Allow for Session
- Always Allow for Project
- menu bar UI
- auto-detect project folder
- searchable credentials
- service templates:
  - OpenAI
  - Stripe
  - Supabase
  - GitHub
  - Apple App Store Connect
- `.env` export
- secret metadata:
  - label
  - service
  - project
  - environment
  - notes

### Not in MVP

- cloud sync
- accounts
- mobile app
- Windows
- Linux GUI
- teams
- shared vaults
- billing
- enterprise admin
- SSO
- compliance reporting
- automatic key rotation
- hosted proxy infrastructure

---

## 6. UX principles

### Principle 1 — no security jargon

Avoid:

- credential brokering
- policy engine
- RBAC
- secret injection
- runtime identity

Prefer:

- "Claude wants to use Stripe"
- "Allow once"
- "Always allow for this project"

### Principle 2 — setup should take minutes, not documentation

Desired onboarding:

```text
Install AgentKeyBox
↓
Import .env or add key
↓
Connect Claude Code or Codex
↓
Done
```

### Principle 3 — approval must explain context

Approval UI should show:

- requesting agent
- credential/service
- project
- environment if known
- requested action if available

### Principle 4 — deny must be safe

If the user denies access:

- credential is not exposed
- agent receives a clear failure
- no fallback should silently reveal the secret

---

## 7. Success criteria

The first release should measure:

- installation → first saved credential completion
- installation → Claude Code connection completion
- percentage of users completing first approval
- repeat approvals per active user
- number of imported credentials
- most requested integrations
- number of users asking for Cursor / Antigravity CLI / Copilot / Cline / Roo / Windsurf support

Qualitative validation matters more than scale at this stage.

Strong signal examples:

- users use the approval flow repeatedly
- users request support for more agents
- users ask for sync or multi-device support
- users recommend the tool without being prompted
- users describe the tool as easier than their current `.env` workflow

---

## 8. Product hypothesis to validate

The MVP is not trying to prove that secret storage is useful.

That is already established.

The MVP is trying to prove:

> **AI credential approval can become a default interaction pattern for non-expert developers.**

If users still prefer copy/paste after trying AgentKeyBox, the product thesis is weak.

If approval feels natural and users want support across more tools, the concept is worth expanding.

---

## 9. Positioning

Working positioning:

**AgentKeyBox**
> Keys for your AI agents, under your control.

Alternative:

> AI asks. You approve.

The product should be presented as a developer utility, not an enterprise security platform.


---

## 10. Agent support strategy

AgentKeyBox should support **agent hosts**, not model brands.

A model such as Claude, GPT, Gemini, or Grok may be used through different coding environments. The integration boundary should therefore be the coding agent/runtime that requests access.

### P0 — launch targets

- Claude Code
- OpenAI Codex

These two should share the same user-facing approval experience even if their technical integrations differ.

### P1

- Cursor
- Google Antigravity CLI / Gemini CLI lineage

### P2

- GitHub Copilot
- Cline
- Roo Code
- Windsurf

The product should avoid agent-specific UI unless necessary. A request should always normalize into the same conceptual object:

```text
Agent request
- agent
- project
- credential
- purpose
- scope
```

This keeps the product understandable even as support expands.


---

## 10. UI / UX direction

The current interface is a functional prototype, not the intended final product experience.

The long-term UI should be:

- project-centric rather than vault-centric
- import-first rather than form-first
- native macOS in interaction style
- human-readable by default with technical details progressively disclosed
- explicit about file credentials such as `.p8`, `.pem`, and service-account JSON
- focused on the approval moment: who is asking, what they need, which project, and why

Detailed interaction and screen direction lives in:

[`docs/UI_DIRECTION.md`](UI_DIRECTION.md)
