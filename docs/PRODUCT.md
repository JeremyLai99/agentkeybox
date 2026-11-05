# Product — AgentKeyBox

Product direction confirmed on 2026-10-22. Implementation status distinguishes the released 0.4.0 baseline, the unreleased protected-field submission increment, and remaining requirements. See [ROADMAP.md](ROADMAP.md) for priorities and [SESSION_STATUS.md](SESSION_STATUS.md) for evidence.

## 1. Product thesis

**Let agents complete tasks with sensitive data you approve, while keeping the raw values out of the agent/model's readable context.**

The agreed product direction in Traditional Chinese:

> 讓 agent 在你的核准下使用敏感資料完成任務，同時不讓 agent 讀取到原始資料，降低外流風險。新增資料種類，就是擴大 agent 能協助完成的任務。

AgentKeyBox stores sensitive values locally, receives an agent's request to perform an operation, obtains the user's approval, and uses those values inside a controlled execution path. The agent receives a result it can use to continue the task.

The intended destination may need the data: a selected website may receive card details, or an account's login flow may receive a recovery code. The protection goal is to keep raw values out of model context, chat history, agent-readable tool output, and other observation paths available to the agent.

This is a product requirement, not a claim that every current execution mode already enforces it. Generic approved commands receive raw secrets and can disclose them. The current HTTP broker keeps substitution inside the app, but response redaction is not a complete data-loss-prevention system. Current limitations remain explicit in [SECURITY.md](../SECURITY.md).

## 2. Target user

Initial users are vibe coders, indie developers, solo founders, and AI-first builders using Claude Code or Codex. They want agents to finish useful work without pasting sensitive values into conversations or leaving them scattered across project files.

API keys and private-key files remain the implemented starting point. Credit cards and account recovery codes extend the kinds of tasks agents can complete. Their primary purpose is approved agent use; personal viewing or copying alone does not satisfy this product direction.

Keep setup and approvals understandable without requiring users to learn MCP, credential injection, or policy-engine terminology.

## 3. User problem

Current workarounds include copying keys into `.env`, terminal sessions, downloads, notes, or chat. They create repeated setup work and leave copies the agent may be able to read.

Broader sensitive-data workflows add two problems:

- users cannot easily distinguish approving one operation from handing over reusable access;
- hiding a value in the app does not prevent the agent from reading it later through a command, browser field, screenshot, or tool result.

AgentKeyBox must connect storage, meaningful approval, controlled execution, and safe results into one workflow.

## 4. Intended workflow

```text
Agent requests an operation using a stored item's reference
        ↓
AgentKeyBox shows the item, action, destination, and scope
        ↓
User approves or denies
        ↓ approval
Controlled local executor uses only the required fields
        ↓
Agent receives a result without raw sensitive values
        ↓
Agent continues the task
```

The execution path must match the approved action. A purpose string supplied by the agent is an explanation, not evidence that a request is safe.

For each new workflow, identify how the agent could observe values before, during, and after execution. If that boundary cannot be enforced, do not silently fall back to returning the value, injecting it into an arbitrary command, or asking the user to paste it into chat.

## 5. Implemented baseline — 0.4.0 source

- SwiftUI macOS app, local Keychain storage, no hosted backend or account.
- Project/global organization; create, edit, and delete credentials.
- API keys, tokens, environment values, `.p8`, `.pem`, and JSON credential storage.
- Project-folder scanning, `.env` selection/import, and supported credential-file import.
- Claude Code and Codex MCP registration and connection status.
- `list_credentials`, `request_credential`, `http_request`, and `run_with_secret`.
- Native approval, denial, timeout, and local authentication.
- Opt-in session approvals: same agent session, project, credential, and listed HTTP host or exact command; up to eight hours. HTTP grants do not distinguish methods, paths, or body contents.
- Active-session count and **Ask Every Time** in Settings and the menu bar. Persistent **Always Allow for Project** is not exposed.
- Type-aware credential cards, edit forms, setup/empty states, English and Traditional Chinese UI.
- Provider presets and local bundle metadata for App Store Connect and Supabase.
- Persistent access history recording approval decisions; it is not a full operation-success audit.
- Encrypted backup export/import, independently readable backup contents, and **Remove Keys from Files** after a covering backup.
- Agent guard configuration/instructions, signed-caller checks, replay protection, timeouts, and bounded/redacted output.

These were previously split between MVP and future-feature sections. Their presence in source does not imply every scenario has been retested; see [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) for historical runtime evidence.

## 6. Sensitive-data types — first increment implemented, unreleased

The working tree now stores typed cards and recovery-code sets and supports `submit_sensitive_fields`: one approved POST to an exact HTTPS URL set by the user in the native editor. It accepts only whole-field placeholders and literal task data; it returns a fixed transport outcome, never upstream response content. Cards and code sets are blocked from command injection, temporary-file delivery, generic HTTP, and `akb run`.

The endpoint-submission increment does not implement browser sessions, website checkout, GitHub login, or provider-specific interpretation of an operation. The separate browser increment below adds a narrower traditional-form flow. Users must configure a compatible submission endpoint. It can establish that an endpoint received a request, not that a payment or login succeeded. The intended next usability step remains a local integration with a verified observation boundary, without provider-management services.

Implemented storage: card number/cardholder/expiration (no CVV); text/file import of code sets; authenticated native editing; reservation persisted before submission; manual status corrections; replacement preserving matching-code history; restore marking non-used codes as needing review. Old payload-free metadata remains readable; backups containing these types use format 2.

Isolated ad-hoc native MCP acceptance has passed seven endpoint cases: selected card fields in form/JSON, code receipt/rejection/blocked redirect/lost response, and durable reservation across process restart. Each required separate native approval and local authentication, exactly one POST and fixed model-readable output. These results establish the synthetic endpoint flow, not provider task success. Endpoint pending-edit/authentication cancellation, native interrupted-save/replacement/backup, production PKI and team-signed protected-secret use remain separate gates in [ROADMAP.md](ROADMAP.md).

The requirements below remain the acceptance target for complete task workflows:

### Website login — second increment, unreleased (2026-10-23)

The native **Website login** editor stores username/password in a protected Keychain envelope and a public HTTPS sign-in page in metadata. The user does not configure a POST endpoint or selectors. An app-owned, offscreen WKWebView inspects a traditional same-origin form before showing the actual submission destination in a native approval prompt. Authentication and a metadata/payload revision check precede use.

After submission, the credential-bearing browser is discarded; same-site cookies are carried internally to a fresh non-persistent browser. Agents can read bounded page text and follow opaque same-site link references. Every link navigation requires a separate approval because GET can also change server state. No arbitrary scripts, selectors, form editing, screenshots, raw DOM, cookies, or storage API is exposed. Browser access is bound to the originating helper session, agent and project, expires after 15 minutes, and can be ended from Settings/menu bar. Editing/deleting the login invalidates its browser access.

This deliberately supports ordinary HTML POST sign-in with a single username field and a single password field, followed by a repeatable HTML landing-page GET. A supported recovery-code challenge can continue through a separate approved operation, as described below. Website JavaScript is disabled. JS applications, cross-origin SSO, TOTP, credit-card checkout, and generic browser interaction remain unsupported. `pageReady` describes an available page, not verified authentication; the agent must interpret the resulting page as untrusted task data. The destination website and local user session remain trusted; this is not a defense against same-user malware or a site that publishes credentials elsewhere.

### Browser recovery-code continuation — unreleased

After login, a traditional same-origin POST form with one text input named `recovery_code` or `recovery-code` returns only the fixed `recoveryCodeRequired` state, with no website content or links. Other enabled fields must be hidden or submit/button controls; JavaScript and unsupported challenge forms remain blocked.

The agent selects a stored code set through `browser_recover` or `akb browser recover`. Its native-configured submission destination must exactly match the form's actual HTTPS POST action. A new approval identifies the login, selected code set and destination. After authentication and revision checks, AKB saves one code as `issued` before inserting or submitting it. Persistence failure sends nothing; failed submission, uncertain results and app interruption never make an issued code automatically available again. A second challenge closes the session instead of trying another code.

After submission, the filled browser is discarded and same-site cookies move privately into a fresh browser before constrained observation resumes. Synthetic WebKit tests and isolated ad-hoc native MCP/CLI approval, local authentication, Keychain reservation and verified-page checks cover this flow. Real GitHub recovery and team-signed secret-use validation remain unverified. Local `issued` status does not prove the website consumed the code.

### Credit cards

- Store structured card number, cardholder name, and expiration fields in protected storage. Any additional sensitive fields need an explicit design before inclusion.
- Let an agent identify a card by a safe reference and request a specific operation without receiving its raw fields.
- Show the target website and operation in the approval. Where an operation includes submitting a payment, show the available amount/currency/payee information and bind approval to that submission; filling a form does not grant unlimited future payment authority.
- Use a controlled local execution path for the approved fields. Direct browser filling requires a local integration that also handles agent-readable DOM, scripts, screenshots, accessibility output, and logs.
- Return a sanitized outcome. Do not claim card values are hidden from the agent if another available tool can read them back.

This does not require building a card issuer, payment processor, spending-limit service, or payment-provider partnership. Existing websites remain the destination; the local execution and observation boundary is the engineering work to validate.

### Recovery-code sets

- Import a user-supplied file or text into a set associated with a service and account. GitHub recovery codes are the first concrete use case.
- Allow the agent to request use of one code for an approved recovery/login operation. The controlled executor consumes the selected value without returning it to the agent.
- Track availability, reservation, issued/uncertain outcome, and confirmed use so concurrent requests cannot select the same code. Issuing or submitting a code is not proof of successful consumption.
- Support user-confirmed status corrections and whole-set replacement. Do not automatically return an uncertain code to the available pool.
- Treat status as local knowledge. Use or regeneration outside AgentKeyBox may invalidate it; restoring an old backup must not silently present stale codes as confirmed available.
- Keep backup recovery independent of the account the codes recover.

GitHub documents that recovery codes are single-use and generating a new set invalidates the previous set. Importing and managing a locally supplied set does not require a GitHub connector. [GitHub recovery documentation](https://docs.github.com/en/authentication/securing-your-account-with-two-factor-authentication-2fa/configuring-two-factor-authentication-recovery-methods).

### Shared acceptance criteria

Before either type is advertised as supported for agent use:

1. Denial and timeout prevent use; approval is bound to the selected item, destination, and operation.
2. Raw fields never appear in metadata, agent-visible requests/results, logs, errors, or observation paths the integration claims to protect.
3. Sensitive operations cannot bypass the controlled executor through `run_with_secret`, `akb run`, exports, or unrestricted browsing tools.
4. Use synthetic values to exercise success, failure, cancellation, retry, and attempted read-back. Recovery codes also require concurrent-use and stale-backup cases.
5. Backups, migration, and local status accurately represent the new data types.

## 7. Scope decisions

### Included direction

- Local sensitive-data storage and approved use by agents.
- Controlled local execution/delivery, including evaluating a local browser integration.
- User-driven import, replacement, deletion, backup, and recovery-code status management.
- More precise operation approval where the local executor can enforce it.

### Excluded from the selected roadmap

- Provider-side credential creation, OAuth account connectors, and automated token rotation/revocation.
- GitHub App installation/token issuance or remote permission management.
- Card issuance, virtual-card infrastructure, payment processing, provider-enforced spending limits, and payment partnerships.
- A promise to intercept permissions already granted directly to an unrelated cloud agent service.

Existing provider presets, dashboard links, and approved HTTP requests remain supported. These exclusions concern new provider-management integrations, not ordinary use of an existing credential against its intended service.

Cloud sync, accounts, mobile approval, teams, Windows/Linux GUI, enterprise administration, and compliance reporting remain outside the selected local feature work. Earlier backlog ideas require a separate scope decision before implementation.

Claude Code and Codex are the tested agents. Hosted agent products that cannot be tested end to end are not documented as usable, and vendor MCP support or a partnership is not evidence of a working AgentKeyBox integration. Any future support must identify the execution surface: a local MCP client, an agent calling the local `akb browser` CLI, a future authenticated remote bridge, or an integration with a provider-owned browser. The last two are not implemented.

## 8. UX principles

- **Approval explains use:** who is asking, which item, which destination, which action, and how long/repeatedly it is allowed.
- **Import supports the task:** recognize supported files and group related fields; do not require secret values in chat.
- **Display masking is one layer:** the execution and observation paths must preserve the same protection.
- **Denial is final for that request:** return a useful failure without a secret-bearing fallback.
- **Broader use needs a new decision:** avoid silently expanding an existing approval to unrelated actions.
- **State uncertainty is visible:** an unknown operation result or local recovery-code count must not look remotely verified.

See [UI_DIRECTION.md](UI_DIRECTION.md) for current surfaces and planned interactions.

## 9. Success criteria

Validate whether users can complete real agent-assisted tasks without manually disclosing sensitive values:

- installation → stored item → connected agent → first completed approved operation;
- repeated successful use without pasting raw values into chat;
- users understand the action and scope before approving;
- denied/expired requests stop cleanly;
- synthetic-data checks confirm values stay outside the agent's observation paths for supported workflows;
- new data types enable useful tasks through controlled execution, beyond storage alone.

These are validation goals, not claims of current analytics or measured results.

## 10. Positioning and agent support

**AgentKeyBox**
> AI asks. You approve. AgentKeyBox uses the sensitive data for the task.

The product goal is approved use without exposing raw values to the agent. Public descriptions must distinguish this goal from the current generic-command boundary.

Integrate with agent hosts, not model brands. Claude Code and Codex are implemented. Cursor and Antigravity/Gemini CLI remain candidates; GitHub Copilot, Cline, Roo Code, and Windsurf remain unimplemented backlog items. Agent-host adapters are separate from the provider-management integrations excluded above.
