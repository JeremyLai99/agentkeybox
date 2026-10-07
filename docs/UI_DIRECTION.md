# UI / UX Direction — AgentKeyBox

## Purpose

AgentKeyBox should not feel like an enterprise secrets manager or developer administration console.

The long-term product direction is:

> **A simple macOS utility that feels closer to Apple Keychain or 1Password than to DevOps infrastructure.**

The user should understand the product without knowing terms such as RBAC, credential brokering, secret injection, policy engine, runtime identity, or MCP.

The core interaction remains:

> **Import once → organize by project → AI asks → user approves.**

---

## 1. Information architecture

The product should become **project-centric**, not credential-centric.

Primary hierarchy:

```text
Projects
└── MyApp
    ├── Stripe
    ├── Supabase
    ├── Apple App Store Connect
    └── OpenAI
```

A credential still exists as an independent object internally, but the default UI should answer:

> "What keys does this project use?"

rather than:

> "What secrets are stored in this vault?"

### Main application structure

Recommended macOS layout:

```text
┌──────────────────────┬───────────────────────────────────┐
│ Projects             │ MyApp                             │
│                      │                                   │
│ MyApp                │ Credentials                       │
│ Side Project         │ Stripe · Production               │
│ Test Project         │ Supabase · Production             │
│                      │ Apple · AuthKey_ABC123.p8          │
│                      │ OpenAI · Development               │
│                      │                                   │
│                      │ AI Agents                         │
│                      │ Claude Code    Connected ✓         │
│                      │ Codex          Connected ✓         │
└──────────────────────┴───────────────────────────────────┘
```

---

## 2. Onboarding

The first-run experience should avoid configuration-heavy screens.

### Step 1 — explain value

```text
Welcome to AgentKeyBox

Keep your developer keys in one place
and let coding agents ask before using them.

[ Get Started ]
```

### Step 2 — import existing credentials

```text
Where are your keys now?

[ Import .env ]
[ Drop credential files ]
[ Add one manually ]
```

Supported drag-and-drop targets should include:

- `.env`
- `.env.local`
- `.p8`
- `.pem`
- `.json`
- other supported credential files

### Step 3 — connect agents

```text
Connect your coding agents

Claude Code     [ Connect ]
Codex           [ Connect ]

✓ Local only
✓ No cloud account required
```

### Step 4 — ready state

```text
You're ready.

AgentKeyBox will ask before a connected
coding agent uses one of your credentials.
```

The onboarding goal is to reach a usable state without requiring the user to read documentation or edit configuration files manually.

---

## 3. Import-first UX

AgentKeyBox should prefer **import and recognition** over forms.

Preferred entry points:

```text
[ Import .env ]
[ Drop credential files ]
[ Add manually ]
```

When a user drops a known credential file, AgentKeyBox should attempt to identify its type and propose metadata automatically.

Example:

```text
AuthKey_ABC123.p8
        ↓

Apple App Store Connect Key

Project
[ MyApp ▼ ]

Key ID
[ ABC123 ]

Issuer ID
[ optional ]

[ Save Securely ]
```

Manual forms remain available, but should not be the default experience.

---

## 4. Credential cards

Different credential types should feel like first-class objects rather than generic text rows.

### API key

```text
Stripe

Production
••••••••••••••••

Used by
Claude Code · 3 times
Codex · 1 time
```

### File credential

```text
 App Store Connect

MyApp Distribution
AuthKey_X7KD91.p8

Key ID
X7KD91

Issuer ID
••••••••-••••-••••

Used by
Claude Code
Codex
Fastlane
```

Potential metadata varies by provider.

Examples:

- service
- environment
- project
- key ID
- issuer ID
- team ID
- expiration
- last used
- created date
- file type

Raw secret values should remain hidden by default.

---

## 5. Approval experience

Approval is the product's main interaction and should feel like a native macOS permission prompt.

### Default view

```text
Claude Code wants to use

Stripe
MyApp · Production

For
Create a test checkout session

[ Details ]

[Deny]                 [ Allow Once ]
```

The default view should answer only:

1. Who is asking?
2. Which credential?
3. Which project?
4. Why?

### Technical details

Technical information should be collapsed by default:

```text
Details

Command
/usr/bin/node checkout.js

Working directory
~/Projects/MyApp

Delivery
STRIPE_SECRET_KEY
```

### Elevated-risk requests

If command analysis identifies higher-risk behavior, the UI should explicitly surface it.

Example:

```text
⚠ Review this request

Claude Code wants to run a command
that can make network requests while
using your Stripe production credential.

[ Review Command ]

[Deny]                     [ Allow ]
```

The user should not be forced to interpret raw shell commands unless the request is unusual or risky.

---

## 6. Agent connection UX

Agent connection belongs primarily in onboarding and settings, not as the dominant home-screen experience.

### Settings

```text
Coding Agents

Claude Code        Connected ✓
Codex              Connected ✓
Cursor             Coming soon
Antigravity CLI    Planned
```

Development-only actions such as:

- Simulate Claude Request
- Simulate Codex Request
- broker debug controls

must not appear in production UI.

They should be compiled only for debug/development builds or placed behind a developer mode.

---

## 7. Provider-aware UX

Provider presets should evolve beyond autofilling labels.

AgentKeyBox should eventually recognize provider-specific credential bundles.

Examples:

### Apple App Store Connect

```text
Credential bundle
- .p8 private key
- Key ID
- Issuer ID
- Team ID
```

### Supabase

```text
Credential bundle
- Project URL
- anon/public key
- service role key
```

### Firebase / Google

```text
Credential bundle
- service account JSON
- project ID
- client email
```

The product should represent the thing the user recognizes ("App Store Connect credential") rather than expose every field as an unrelated secret.

---

## 8. Menu bar direction

After the main workflow is validated, AgentKeyBox should support a lightweight menu bar experience.

Potential menu:

```text
AgentKeyBox
──────────────
No pending requests

Recent
Claude Code → Stripe · Allowed
Codex → OpenAI · Allowed

Open AgentKeyBox
Lock Vault
```

Pending agent requests should be accessible quickly without requiring the main window to remain open.

---

## 9. Interaction principles

### Human language first

Prefer:

- "Claude Code wants to use Stripe"
- "Allow once"
- "Always allow for MyApp"
- "Import credential files"

Avoid exposing implementation language unless the user asks for details.

### Progressive disclosure

Simple information first; technical/security details second.

### Secure defaults without ceremony

The safest reasonable behavior should usually require fewer decisions, not more.

### File credentials are first-class

`.p8`, `.pem`, and service-account JSON files should not be treated as edge cases.

### Project context is primary

Most approvals and credential organization should be tied to the project the user is actively building.

---

## 10. UI roadmap

### Current prototype

The existing UI is intentionally functional and engineering-oriented.

It currently validates:

- project grouping
- credential creation/import
- agent connection
- approval flow
- access history

### Public alpha UI target

Before wider public alpha:

- [x] project-centric primary navigation
- [x] drag-and-drop import
- [x] guided first-run onboarding
- [x] agent connection moved into onboarding/settings
- [x] production UI removes simulation/debug controls
- [x] simplified approval sheet with expandable technical details
- [ ] dedicated file credential cards
- [ ] empty states and human-readable errors
- [x] credential edit view

### After workflow validation

- [ ] menu bar experience
- [ ] session/project approval management UI
- [ ] richer provider bundles
- [ ] search/filter
- [ ] credential lifecycle / provider connector UI
- [ ] optional sync and multi-device surfaces

---

## 11. Design validation question

The UI should ultimately answer one question:

> **Can a developer who understands what an API key is—but does not understand secrets infrastructure—use AgentKeyBox correctly without reading documentation?**

If the answer is no, the UX is still too technical.


---

## 12. Brand consistency

UI implementation should follow [`BRAND.md`](BRAND.md).

Key constraints:

- use **Key in a Box + Agent** as the primary visual language
- use **AgentKey Blue** as the primary brand accent
- reserve **Electric Cyan** for active/request states and small interaction highlights
- keep the application UI flatter and quieter than the dimensional app icon
- preserve rounded, approachable, macOS-native geometry
- the agent represents a requester, not the owner of the credential
- prefer SF Symbols for ordinary controls instead of creating unnecessary custom icons
