# UI / UX Direction — AgentKeyBox

## Purpose

Reconciled with 0.4.0 source on 2026-10-22. Existing surfaces and planned changes are distinguished below. Wireframes, names, IDs, and usage counts in this document are illustrative design examples, not exact screenshots or measured usage.

The product goal is **approved agent use of sensitive data without exposing raw values to the agent**. New credit-card and recovery-code experiences must include a controlled use path; masked storage and personal copy buttons alone do not complete them. See [PRODUCT.md](PRODUCT.md).

AgentKeyBox should not feel like an enterprise secrets manager or developer administration console.

The long-term product direction is:

> **A simple macOS utility that feels closer to Apple Keychain or 1Password than to DevOps infrastructure.**

The user should understand the product without knowing terms such as RBAC, credential brokering, secret injection, policy engine, runtime identity, or MCP.

The core interaction remains:

> **Import → organize → agent requests an operation → user approves → AgentKeyBox uses the data → agent receives a safe result.**

---

## 1. Information architecture

The implemented app is **project-centric**, with a Global keys section for shared credentials. Preserve that structure while evaluating how new account/card items fit the tasks that use them.

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

Illustrative layout (implemented navigation uses a project/global sidebar, cards, and agent connection controls in setup/Settings):

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

The current onboarding starts with dropping/choosing a project folder, scanning supported files, and one Set Up confirmation that can also connect installed agents. The steps below describe the information users need, not four additional screens still waiting to be built.

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
[ required for this credential ]

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

The current default view answers:

1. Who is asking?
2. Which credential?
3. Which project?
4. Why?

HTTP prompts also show the destination. Agent-provided purpose text is labeled **Agent's reason** and quoted. Eligible unflagged requests offer **Don't ask again during this session**; for HTTP this currently covers a listed host, not a single API action. The unreleased card/recovery-code prompt shows an exact POST destination and complete field map, defaults to Deny, and offers no session grant. Browser sign-in and restricted recovery continuation now have separate native prompts; payment semantics remain future work.

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

App Store Connect and Supabase bundles already group a key with local companion metadata, validate required fields, and display those fields in one card/editor. This does not require provider-side account management. The scopes below distinguish implemented fields from possible extensions.

### Apple App Store Connect

```text
Credential bundle
- .p8 private key
- Key ID
- Issuer ID
```

Implemented. Team ID is not a current preset field.

### Supabase

```text
Credential bundle
- Project URL
- anon/public key
- service role key
```

Implemented grouping/validation through `ProviderCatalog`, `ProviderBundles`, and `ProjectScanner`.

### Firebase / Google

```text
Credential bundle
- service account JSON
- project ID
- client email
```

Partial: service-account JSON import and a label inferred from its project ID exist. A structured project-ID/client-email bundle editor is not implemented; the block above is an unselected extension idea.

The product should represent the thing the user recognizes ("App Store Connect credential") rather than expose every field as an unrelated secret.

---

## 8. Menu bar direction

The lightweight menu bar is implemented. It shows pending requests, recent decisions, active-session count and **Ask Every Time**, plus Open and Quit actions.

Illustrative current menu:

```text
AgentKeyBox
──────────────
No pending requests

Recent
Claude Code → Stripe · Allowed
Codex → OpenAI · Allowed

Open AgentKeyBox
Ask Every Time (when session grants exist)
Quit AgentKeyBox
```

Pending requests can be reopened from the menu, and approval panels work with the main window closed. **Lock Vault** from the old sketch is not an implemented action.

---

## 9. Interaction principles

### Human language first

Prefer:

- "Claude Code wants to use Stripe"
- "Allow once"
- "Don't ask again during this session"
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

### Implemented baseline

The current project-centric UI includes setup, cards, editing, approvals, Settings, and a menu bar. It is beyond the original engineering-only prototype; remaining usability work should be based on observed problems.

It currently validates:

- project grouping
- credential creation/import
- agent connection
- approval flow
- access history

### Previously planned and now implemented

Confirmed in the 0.4.0 source:

- [x] project-centric primary navigation
- [x] drag-and-drop import
- [x] guided first-run onboarding
- [x] agent connection moved into onboarding/settings
- [x] production UI removes simulation/debug controls
- [x] simplified approval sheet with expandable technical details
- [x] type-aware file credential cards with metadata/attention states
- [x] first-run, empty-project, and empty-history states
- [x] credential edit view
- [x] menu bar with pending requests and recent decisions
- [x] session approval checkbox, active-session count, and **Ask Every Time**
- [x] App Store Connect / Supabase bundles

### Selected follow-up work

- [ ] complete human-readable errors (some paths still show system text)
- [ ] search/filter
- [x] native card and recovery-code import/edit surfaces with safe agent-visible references (unreleased)
- [x] per-use exact-endpoint/field-map approvals and fixed transport outcomes; task-specific outcomes remain future work
- [x] recovery-code reservation, issued/used/needs-review states, local corrections, and whole-set replacement
- [ ] validate local execution and all agent observation paths before advertising agent support

Persistent project approvals, additional provider fields, and sync/multi-device surfaces remain unimplemented, unselected backlog. Provider-side credential lifecycle/connectors are excluded from the selected direction. See [ROADMAP.md](ROADMAP.md).

### New sensitive-data interactions — current increment and remaining target

The working tree adds **Add Item → Credit card / Recovery codes**, native protected-field forms, paste/file code import, and a user-configured exact submission URL. Card number/cardholder use secure fields; recovery-code values are never listed, only numbered entries and local status. Editing existing items authenticates, and changing code status also requires a deliberate confirmation. No personal copy/export-to-agent button is added. The interface distinguishes standalone endpoint submission from browser recovery continuation. For a recovery set, the destination must exactly match the trusted form action; issued codes are not automatically retried. Checkout automation is unsupported.

The remaining complete-task target is:

For a card, the agent requests use by reference. The approval identifies the selected card, target, fields, and action without showing the full value to the agent. If submitting a payment is part of that action, bind the approval to its transaction details. Return success, failure, or a request for user intervention without raw fields. Ordinary page filling is insufficient if the agent can read the field, page scripts, accessibility tree, or screenshots afterward.

For a recovery-code set, show the account and locally recorded status. An approved login/recovery operation reserves one code for controlled use. Display **outcome unknown** when submission cannot be confirmed; copying, issuing, or submitting a code does not by itself prove it was consumed. User corrections and whole-set replacement remain local actions, with no promise of remote synchronization.

Manual viewing/copying can be auxiliary user actions. The defining experience remains completing an agent-requested task without returning the sensitive values to the agent.

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


## Website login and private browser (unreleased, 2026-10-23)

Add Item now includes **Website login**. The native form asks for a safe name, project, sign-in page, username and password; it does not ask users to discover form selectors or a submission endpoint. The name and website are public metadata. Username/password use secure inputs and authenticated editing.

A browser login prompt names the selected item and the actual same-origin submission destination. It explains that the agent can subsequently read account-page text, offers no standing approval, and defaults to Deny. Each same-site link navigation has a separate approval because navigation may affect account data. Settings shows the number of private browser sessions and End Browser Access; the menu bar also offers termination while sessions exist.

The browser has no visible webpage or arbitrary browser-control interface. A supported traditional recovery form returns fixed `recoveryCodeRequired` text with no website content or links. Its new approval names the website login, selected recovery set and actual POST destination, defaults to Deny, and explains reservation before submission and no automatic reuse. Unsupported JS/SSO/TOTP/challenge forms show a bounded error. Do not present `pageReady` as proof of authentication, `issued` as confirmed consumption, or local termination as logout/revocation on every device. Later browser/payment UX must retain these approval and observation boundaries.
