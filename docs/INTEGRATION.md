# Agent Integration

AgentKeyBox uses a local **stdio MCP server**, with automatic setup for Claude Code and Codex. The unreleased `akb browser` CLI also exposes the controlled browser to agents that can execute local commands. See [AGENT_COMPATIBILITY.md](AGENT_COMPATIBILITY.md) for commands, ownership, and the dated product-by-product evidence. A generic protocol entry point is not evidence that a specific cloud product has been integrated.

The MCP interface is designed to exchange credential references and results instead of raw values. It asks the AgentKeyBox macOS app to perform an approved operation locally. Generic command output still has the disclosure limits described below.

## Build

```bash
swift build
```

Find the built binaries with:

```bash
swift build --show-bin-path
```

The directory contains:

```text
AgentKeyBox
agentkeybox-mcp
akb
```

During development, run `AgentKeyBox` first so it can create the local broker authentication token and listen for requests.

## Claude Code

```bash
claude mcp add --scope user \
  --env AGENTKEYBOX_AGENT_ID=claude-code \
  --env "AGENTKEYBOX_AGENT_NAME=Claude Code" \
  --transport stdio \
  agentkeybox -- /absolute/path/to/agentkeybox-mcp
```

Verify:

```bash
claude mcp list
```

Claude Code provides `CLAUDE_PROJECT_DIR` to local stdio MCP servers. AgentKeyBox uses that value as the trusted project path when available.

Start a new Claude Code session after installation.

## Codex

```bash
codex mcp add agentkeybox \
  --env AGENTKEYBOX_AGENT_ID=codex \
  --env AGENTKEYBOX_AGENT_NAME=Codex \
  -- /absolute/path/to/agentkeybox-mcp
```

Verify:

```bash
codex mcp list
```

Start a new Codex session after installation. Codex starts the MCP helper in the session's working directory, which AgentKeyBox uses as the project path unless `AGENTKEYBOX_PROJECT_PATH` is supplied (verified with Codex 0.160).

## MCP tools

### `http_request`

Preferred for provider HTTPS APIs. AgentKeyBox performs the request itself; the credential is placed into header values containing `{{secret}}`. HTTPS and header-only placement are required, and redirects are refused. Listed hosts follow the ordinary approval flow; unlisted hosts show a warning with Deny as default but can be explicitly allowed. Credentials without a host list are labeled unrestricted. See the [README](../README.md) for limits.

Eligible requests can use an opted-in session grant. For HTTP this is scoped to the same agent session, project, credential, and listed host, not method/path/body. This generic broker is implemented; provider-specific action authorization is not.

### `request_credential`

Asks the user to enter a missing credential in AgentKeyBox. Waits up to 10 minutes so the user can create the key in the provider's dashboard. Returns only the new credential's metadata.

### `list_credentials`

Takes no secret-bearing input. It returns only credential IDs and non-secret metadata that are global or bound to the current project.

The `settings` column lists non-secret values that go with a key, for example `ASC_KEY_ID` and `ASC_ISSUER_ID` for an App Store Connect key, or `SUPABASE_URL` for a Supabase key. `run_with_secret` sets them as environment variables under these names next to the key; `akb run` does the same for the keys it reveals.

### `run_with_secret`

Input shape:

```json
{
  "credential_id": "UUID",
  "env_var": "STRIPE_SECRET_KEY",
  "command": "/usr/bin/curl",
  "args": ["https://example.com"],
  "purpose": "Test the Stripe integration"
}
```

Flow:

```text
agent
  ↓ MCP tool call
agentkeybox-mcp
  ↓ authenticated Unix-socket request (no secret)
AgentKeyBox.app
  ↓ native Allow / Deny prompt
Keychain
  ↓ secret injected inside app process
approved child process
  ↓ exact/raw + common encoded forms redacted
agentkeybox-mcp
  ↓
agent
```

The app must be running; if it is not, the tool fails immediately with "AgentKeyBox is not running". An unanswered approval automatically expires after two minutes.

## Local broker authentication

On first launch, AgentKeyBox creates a random broker token at:

```text
~/Library/Application Support/AgentKeyBox/broker-token
```

The file is owner-readable/writable only (`0600`). The MCP helper reads this token before calling the broker over its owner-only Unix-domain socket (`broker.sock` in the same directory). It is **not** an API credential and never leaves the machine.

The token alone is not enough for a team-signed AgentKeyBox: the broker reads the caller's audit token and accepts only processes signed by the same team as AgentKeyBox's helper (`agentkeybox-mcp`) or CLI (`akb`); `akb run` requests are accepted only from `akb`. A coding agent that reads the token cannot use it from its own scripts. Development builds without a team signature skip this check.

This is a guardrail against other local callers, not a defense against malware running as the same macOS user.

## Current execution boundary

Raw values are not intentionally returned as MCP credential results or written to logs. Command output is redacted for the raw secret plus common direct encodings (Base64, percent-encoding, and hex).

An approved child process can still deliberately transmit or transform the secret. `run_with_secret` is therefore not a containment mechanism. The already-implemented `http_request` avoids handing the credential to a generic child process, but neither response redaction nor host review guarantees isolation from every possible agent observation path. The separate `akb run` CLI intentionally hands raw values to a process and leaves its output unredacted.

## Protected-field submission — unreleased

Add a **Credit card** or **Recovery codes** item through **Add Item** in a project or Global keys. Enter values only in the native app. For recovery codes, paste newline-separated codes or import a plain-text file without headings; importing does not delete the original file or clear the clipboard. Give the item a non-secret label and configure an exact HTTPS submission destination. An empty destination keeps it stored but unavailable for submission. The destination has no query, fragment, user information, or placeholders; only the native editor can change it.

`list_credentials` lists cards with `use=submit_sensitive_fields` and code sets with `use=submit_sensitive_fields,browser_recover`, plus the configured `submission_url`. No raw fields or code list is returned. The tools `http_request`, `run_with_secret` (including temporary files), and `akb run` cannot deliver these types. `request_credential` still creates developer credentials only.

Call `submit_sensitive_fields` with:

| Argument | Meaning |
| --- | --- |
| `credential_id` | Item UUID returned by `list_credentials` |
| `fields` | 1–40 string-valued fields; names use ASCII letters/digits/`_-.[]`, at most 100 characters; values at most 4,096 UTF-8 bytes; total keys/values at most 32 KiB |
| `encoding` | `form` (default, URL-encoded) or `json` (flat string object) |
| `purpose` | Agent's reason for the user to review, not an enforcement rule |

A sensitive field must be a **whole value** from this list:

- `{{card.number}}`
- `{{card.cardholder}}`
- `{{card.expiration_month}}` (two digits)
- `{{card.expiration_year}}` (four digits)
- `{{recovery.code}}` (exactly one occurrence in a recovery-code request)

At least one sensitive field is required. Other fields are literal non-secret task data. Mixed/interpolated/unknown placeholders and placeholders for a different item type are rejected. No URL, custom header, cookie, or browser session argument is supported. The request always uses POST.

Synthetic request example; the item ID below is illustrative, not a real credential:

```json
{
  "credential_id": "00000000-0000-0000-0000-000000000001",
  "fields": {
    "card_number": "{{card.number}}",
    "expiration_month": "{{card.expiration_month}}",
    "expiration_year": "{{card.expiration_year}}",
    "order_reference": "synthetic-order"
  },
  "encoding": "json",
  "purpose": "Submit selected fields for the reviewed synthetic order"
}
```

Each request shows item, exact destination, encoding, and all fields in native approval; Deny is the default and no session grant is offered. Changing the item while approval is pending invalidates that request. Recovery codes are saved as `issued` before any networking and stay unavailable after errors, rejection, redirects, or lost responses. The user reviews their status in the native editor; there is no MCP status-reset tool.

Only a fixed `outcome` is returned: `received` (2xx), `rejected` (4xx/5xx), `redirectBlocked` (3xx), or `unknown`. It is not confirmation of login or payment success. No response body, headers, redirect URL, or network diagnostics are returned. Do not automatically retry; consult the destination when an operation's result is uncertain.

This is an experimental endpoint-submission path, not browser checkout or GitHub sign-in automation. It does not share browser cookies, execute page scripts, handle CSRF/3DS, or supply CVV. The user must trust the endpoint and confirm that it accepts this request format. Endpoint behavior cannot be inferred from an HTTP method or an agent's reason. No provider-side OAuth, credential issuance/revocation, or payment-management service is introduced. See [SECURITY.md](../SECURITY.md) for the boundary and remaining observation risks.


## Controlled browser — unreleased

Add a **Website login** item in the native app, entering a non-secret label, the HTTPS sign-in page, username and password. The sign-in URL may not contain credentials, query parameters or a fragment. Username/password stay in Keychain; `list_credentials` returns only the item reference, label, kind and public sign-in URL. Login items are rejected by developer tools and `submit_sensitive_fields`.

| MCP tool | Arguments | Result |
| --- | --- | --- |
| `browser_login` | `credential_id`, optional `purpose` | Native sign-in approval, then `BrowserPage` |
| `browser_read` | `browser_session_id` | Fresh constrained page text and link IDs |
| `browser_follow` | `browser_session_id`, `link_id`, optional `purpose` | Separate native navigation approval, then a new page |
| `browser_recover` | `browser_session_id`, `credential_id`, optional `purpose` | Separate recovery-code approval, persist one issued code, submit privately, then a new page |
| `browser_close` | `browser_session_id` | Ends this local browser session |

A `BrowserPage` contains `sessionID`, `status`, `origin`, `title`, `text`, and `links` (`id`, `text`). Use its `sessionID` as `browser_session_id` on later calls. `status: "pageReady"` means the browser can expose the resulting page; it is not a claim that authentication succeeded. Page text is untrusted website content, not instructions. `status: "recoveryCodeRequired"` instead returns fixed AKB text and an empty link list, never challenge-page content. The synthetic integration test verifies its own session cookie and protected account page, but arbitrary websites require their own compatibility checks.

Use link IDs from the latest returned page; each read replaces the previous link set. Agents cannot override URLs, supply selectors/scripts, retrieve raw DOM/screenshots/cookies/storage, fill arbitrary fields, or export the logged-in session to another browser. A different helper session, agent or project cannot use the reference. Keep using these tools to continue the task. Ordinary external browser tools cannot attach to this session.

This increment supports same-origin traditional HTML POST login with one username and one password field, form-encoded data and a repeatable HTML landing-page GET, plus the restricted recovery continuation below. Existing hidden form fields (such as CSRF tokens) remain inside the browser. It disables website JavaScript and denies cross-origin/frame navigation, downloads and unsupported content. It does not support JS login, SSO, TOTP, checkout or form-driven account changes. Same-site links may still have side effects, so every navigation has a separate approval and local authentication.

Sessions expire after 15 minutes, at most four can be active, and none survive app restart. The user can end all of them in Settings or the menu bar; editing/deleting an item also invalidates its browser access. Ending a session destroys its local browser/cookies; it does not revoke server-side sessions or sign out other devices. Do not automatically retry an uncertain sign-in. No provider-side account/payment connector is involved.

### Continuing a recovery-code challenge

1. In the native **Recovery codes** editor, set the exact HTTPS submission destination to the trusted website's recovery form action. It must match the actual action, not merely its domain or the challenge-page URL. An agent cannot choose or override it. `list_credentials` advertises `use=submit_sensitive_fields,browser_recover` for code sets; `akb browser list` returns them in `recoveryCodeSets` alongside `logins`.
2. When login/read returns `recoveryCodeRequired`, use the same browser and client session with the selected code-set UUID. MCP calls `browser_recover`; local CLI callers use the command below. No raw code, field map or URL is accepted.
3. The user separately approves the login/code-set/destination combination and completes normal local authentication. AKB persists one code as `issued` before filling or posting it, then discards the filled browser and resumes constrained observation with private same-site cookies.

```sh
akb browser recover --session CLIENT_SESSION_UUID --browser BROWSER_UUID --credential RECOVERY_ITEM_UUID --project /absolute/project/path --purpose 'Complete the approved recovery challenge'
```

These UUIDs are illustrative placeholders. The current form must contain one visible, enabled, writable text input named exactly `recovery_code` or `recovery-code`, in a same-origin form-encoded POST form without action/method/target overrides or other enabled non-hidden input fields. Hidden CSRF fields remain private. A repeated challenge, redirect outside the origin, unsupported page or uncertain result closes the browser; the issued code stays unavailable. Never automatically retry another code or reset its status. This is not verified GitHub support. Isolated ad-hoc native MCP/CLI recovery success has passed. Team-signed secret use and real-provider acceptance remain release gates.
