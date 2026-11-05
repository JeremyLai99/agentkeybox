# Security Policy

AgentKeyBox is experimental security-adjacent software. It has **not** undergone an independent security audit and should not yet be treated as a hardened production secrets platform.

## Reporting a vulnerability

Please do not open a public GitHub issue for a vulnerability that could expose credentials.

Report it privately through GitHub instead: open the repository's **Security** tab and click **Report a vulnerability** (or go to <https://github.com/JeremyLai99/agentkeybox/security/advisories/new>). Only the maintainers see the report. Please include:

- affected version / commit
- reproduction steps
- expected and observed behavior
- impact
- any proof-of-concept that does not expose third-party secrets

We will reply in the report, work on a fix with you there, and publish an advisory once a fixed release is available.

## Current security boundaries

AgentKeyBox's product goal is approved agent use of sensitive data without exposing raw values to the agent/model. The current alpha reduces accidental leakage through Keychain storage, local approval, app-executed HTTP requests, and redacted command output. That goal must not be presented as an already-enforced guarantee across every current execution mode.

The current alpha includes:

- Keychain-backed secret storage; team-signed builds with the provisioning profile use the data protection keychain with user presence required for reads; opted-in session grants reuse the approved authentication context
- owner-only local metadata/token files where supported
- authenticated broker on an owner-only Unix-domain socket; team-signed builds also check the code signature of every caller, so only AgentKeyBox's own signed helper and `akb` can connect, and only `akb` can ask for `akb run` secrets. A coding agent with a shell can read the broker token, but a script it writes cannot use it
- request freshness and replay rejection
- project-scoped credential visibility
- approval timeout
- command execution timeout with best-effort termination / direct-child kill escalation
- output-size limits
- common direct secret-representation redaction
- Touch ID / login-password confirmation for interactive approvals; eligible session requests can skip the prompt until the grant expires or is cleared
- protected temporary-file delivery for file credentials
- app-executed HTTPS requests with header substitution, destination review, no redirects, timeouts, and bounded/redacted responses
- session grants bound to agent session, project, credential, and listed HTTP host or exact command, with an eight-hour maximum

An HTTP host list is an approval boundary: unlisted hosts trigger a warning and default to Deny, but the user can explicitly allow them. Same-host session grants do not restrict methods, paths, or request bodies. **Ask Every Time** clears local grants, not remote tokens or access already granted elsewhere.

Approval history records decisions. It does not prove that every approved operation completed successfully.

## Backups

Backups are AES-256 encrypted macOS disk images (`.dmg`, made with `hdiutil`) that contain every project, key's metadata, and key value. The image is created encrypted and filled while mounted under an owner-only folder, hidden from Finder and excluded from Spotlight; the finished backup is a compressed read-only copy made from the encrypted device, so the keys are never written to disk unencrypted; the password reaches `hdiutil` on standard input, never as an argument. Exporting requires Touch ID or the login password. A backup is only as strong as its password: the app requires at least 12 characters.

Anyone with the password can open a backup without AgentKeyBox (double-click, enter the password), by design: users are never locked in. Files copied out of the opened image are plaintext; the README inside says so.

A backup records the keys as they were when it read them, and an export stops if a key changes while its values are read. "Remove Keys from Files" is available only after a backup that covers every key of the project as it is now, empties only values identical to the stored keys (leaving a name alone if any assignment of it differs), and moves key files to the Trash rather than deleting them.

## Explicit non-goals

The current alpha does not defend against:

- malware running as the same macOS user
- root compromise
- a compromised macOS Keychain
- malicious or compromised dependencies with user privileges
- an approved command that intentionally exfiltrates or transforms a credential
- full descendant-process containment after an approved command spawns subprocesses
- physical access to an already-unlocked Mac

`run_with_secret` is an approval-oriented workflow prototype, not a cryptographic sandbox.

`akb run` hands secrets to a process in your terminal and does not redact its output. A coding agent with a shell can start `akb run` too; the approval prompt shows the exact command, flags commands that would print the keys back, and asks you to allow only commands you started yourself.

## Protected-field submission — unreleased

The working tree implements `creditCard` and `recoveryCodes` as versioned Keychain payloads. Agent-visible metadata carries only the reference, label, type, scope, and user-configured submission URL; it excludes their injection variable, settings, raw fields, and code status/value list. The native editor warns that its label and URL are visible to agents.

`submit_sensitive_fields` requires a separate Allow Once decision and local authentication. The approval shows the exact stored HTTPS URL, POST, encoding, and all field placeholders/literal values. The item update timestamp is checked again after authentication and Keychain reading; metadata/payload revision UUIDs must match, so an interrupted edit cannot submit mismatched data. No session grant or host override is available. Generic HTTP, command/environment/temp-file delivery, and `akb run` reject or omit these types.

The dedicated ephemeral transport uses no saved cookies, HTTP credentials, or cache, refuses redirects and non-TLS authentication challenges, and cancels response-body delivery. Only `received`, `rejected`, `redirectBlocked`, or `unknown` crosses the broker; headers, redirect destinations, bodies (including transformed reflections), and network error details do not. These outcomes reflect HTTP transport, not verified payment/login success. The app does not retry submissions automatically.

Protected MCP tools and the browser CLI distinguish two fixed native pre-execution failures: another approval is already pending, or the native approval deadline expired. Only these exact broker messages are allowlisted. A client/network timeout or disconnect is not an approval timeout: it may occur after submission and retains the unknown-result warning. Arbitrary broker diagnostics remain suppressed.

Recovery-code reservation is saved synchronously before networking while the broker's approval slot remains held. A failed save sends nothing; a crash or uncertain network result does not release the reservation. The native editor can change status after authentication and confirmation. Restoring a backup marks every non-used code `needsReview`; reimporting matching codes into a set preserves their prior status.

This boundary is limited to the app's submission channel. The intended endpoint receives the fields and must be trusted: it could publish them somewhere an agent can separately read. The app cannot prevent that, hide data from same-user malware, intercept access granted directly to cloud bots, or protect original imported files and clipboard contents. The native editor is a user-controlled surface, not an agent sandbox. Encrypted backup export remains a user-authenticated recovery operation; mounted/decrypted copies are not protected from the same user.

Browser masking/autofill alone is insufficient if the agent can read DOM values, execute page scripts, inspect screenshots/accessibility output, or read the data afterward. An intended destination may receive necessary fields, but the agent/model should receive only a sanitized outcome. The local integration must demonstrate that separation before claiming support.

Recovery-code status is local knowledge: issuance is not confirmed consumption, and restoring a backup cannot establish that a code is still valid. Provider-side credential management, payment processing, and issuer spending controls are outside the selected scope. See [PRODUCT.md](docs/PRODUCT.md) and [ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Secrets in issues and logs

Never attach real API keys, private keys, `.p8` files, service-account JSON, or production `.env` files to an issue. Use synthetic credentials in reproductions.


## Controlled browser boundary (unreleased)

Website-login items use protected envelopes and are blocked from command/environment/temp-file, generic HTTP and protected-field submission routes. The native user sets the sign-in page; the app discovers and shows the actual same-origin POST destination before approval. A fresh private WKWebView handles login, with website JavaScript disabled and no agent observation while credentials are present. After full navigation the credential-bearing view/history/storage is discarded; only same-site cookies move internally to a fresh ephemeral browser. Failure, remaining password/OTP fields, unsupported recovery forms, cross-origin redirects or process termination prevent observation and close the session. A supported recovery form returns only fixed `recoveryCodeRequired` text and no links. `browser_recover` requires a new native approval bound to the login, exact selected code-set metadata and its configured POST endpoint. The selected code is persisted as `issued` before any DOM fill or POST; failed persistence sends nothing and uncertain results never release an issued code. The filled view is discarded again before observation; a repeated challenge closes the session without another attempt.

The supported agent interface returns bounded page text and opaque links. It has no arbitrary URL/script/selector/input/DOM/screenshot/cookie/storage/export interface. The view is offscreen, unattached to a window, and not inspectable. Login and cookie values and common encodings receive additional output redaction; this is not a general solution to malicious-site secret transformation. The selected destination and scripts/data it supplies remain a trust boundary, even though page JavaScript is disabled here. A compromised Mac/same-user process, native-editor automation, originals or decrypted backups remain outside this protection.

Every sign-in and every subsequent link navigation requires native approval; link GETs are not assumed side-effect-free. Sessions are bound to agent/helper-session/project, have a 15-minute lifetime, and can be ended locally. The native Stop action works during a pending or executing request; closure wins over late callbacks. The app does not claim authority over what the agent does through other integrations after independently signing in.

Runtime tests use a synthetic loopback HTTPS site, an ephemeral test-only certificate pin and real WebKit. The production TLS path retains system verification. They cover a restricted same-origin traditional recovery-code form, including private challenge suppression, reservation-before-send, failed persistence, stale/swapped metadata, cross-origin redirects, repeated challenges, reflection filtering and closure during submission. They do not establish compatibility with GitHub, JavaScript-heavy sites, SSO, TOTP or checkout, and do not substitute for signed native approval/Touch ID verification of recovery continuation.

The unreleased `akb browser` CLI uses these same browser actions. It returns only explicit page/metadata/handle fields, never the broker's raw-environment response. It has no secret-input, arbitrary-URL or script argument. Independent CLI processes resume with an opaque client session ID and the same project; these handles do not provide isolation from a compromised process running as the same macOS user. Its native label identifies the local AKB CLI, not an authenticated agent vendor. No public HTTP endpoint or cloud relay is enabled. A provider's support for MCP or another vault integration is not evidence that AKB can safely fill that provider's browser.

An isolated DEBUG native QA profile seeds synthetic credentials into a distinct Keychain service, uses separate broker/token/metadata/preferences/history paths, and skips automatic agent installation and login registration. The public demo uses normal system TLS. Optional recovery QA instead uses a loopback-only fixture with a profile-bound port and exact per-run leaf-certificate pin, evaluated only for that challenge without changing system trust. Only its seeded login can select that browser. Release builds exclude the selector, pin/config, seed values and status-export code. The QA app still runs normal approval/local authentication; its legacy Keychain read-back exports only the four known synthetic codes' statuses to the private QA directory, allowing the fixture server to verify reservation before POST. The ad-hoc native acceptance result is recorded separately from production TLS and team-signed release verification in `docs/SESSION_STATUS.md`.

Optional `--submission` QA applies the same isolation to the real protected-field transport. Its DEBUG certificate pin is restricted to the two seeded card/code IDs and exact profile-bound loopback destinations. It seeds eight synthetic codes and exports statuses only after validating their known values in its isolated legacy Keychain. The receiver logs validation flags and ordinals, never raw request bodies. Native acceptance passed selected form/JSON fields, fixed received/rejected/redirect-blocked/unknown outcomes, no redirect follow-up or credential/cookie reuse, and durable reservations across response loss and same-profile process restart. This evidence does not establish native endpoint edit/authentication cancellation, backup/interrupted-save, production PKI, team-signed Keychain use or provider task success. Release executables exclude this fixture and retain system certificate validation.

Storage lifecycle QA additionally exports phase/revision-match/generation metadata without raw values. Its one-shot interruption hook is restricted to the synthetic card, pauses only between metadata and Keychain writes, and falls back to the ordinary rollback path after ten seconds unless the verified QA process is terminated. The native approval and local authenticator remain mandatory. These hooks are absent from release executables; their availability does not count as passing native cancellation/edit/backup acceptance.
