# macOS End-to-End Test

This is a repeatable macOS runtime procedure. Many checks were already completed for 0.4.0; see [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) for dated evidence. A physical Intel Mac run and the through-app replay/temp-file scenarios identified there remain unverified. The 2026-10-22 documentation reconciliation did not rerun these checks.

## 1. Build and install

```bash
./Scripts/install-dev-macos.sh
open "$HOME/Applications/AgentKeyBox.app"
~/.local/bin/akb doctor
```

Expected:

- AgentKeyBox launches
- local broker reports ready
- broker-auth is initialized
- MCP helper path is detected

## 2. Keychain smoke test

In the app:

1. Add a project folder.
2. Add a synthetic API key such as `akb-test-not-real`.
3. Quit and reopen AgentKeyBox.
4. Confirm metadata remains visible.
5. Delete the credential and confirm the operation succeeds.

Do not use a production credential for the first smoke test.

## 3. `.env` import

Create a disposable file:

```text
OPENAI_API_KEY=not-a-real-key
STRIPE_SECRET_KEY="not-a-real-stripe-key"
```

Import it and confirm provider labels are inferred.

## 4. File credential delivery

Create a synthetic `.p8` text file and import it.

Use `run_with_secret` with `delivery=tempFile` and an approved test script that checks the injected path exists. Confirm the path no longer exists after the command finishes.

## 5. Claude Code

```bash
~/.local/bin/akb connect claude
claude mcp get agentkeybox
```

Start Claude Code in the demo project and ask it to list AgentKeyBox credentials.

Then ask it to run the absolute path to:

```text
Examples/demo-project/verify-secret.sh
```

with `DEMO_API_KEY`.

Verify:

- native approval sheet appears
- project path is correct
- Deny prevents execution
- Allow Once executes
- Touch ID (or the password prompt on Macs without Touch ID) appears for interactive approvals; eligible requests covered by an explicitly enabled session grant reuse its context
- secret itself is not returned in MCP output

## 6. Codex

```bash
~/.local/bin/akb connect codex
codex mcp get agentkeybox --json
```

Start Codex in the demo project and repeat the same flow.

Pay particular attention to the project path. If Codex launches global MCP servers with a working directory different from the current repository, update the adapter strategy rather than weakening project scoping.

## 7. Risk warning

Request a synthetic run using `/usr/bin/curl` or `/bin/sh` and confirm the approval UI shows a high-risk warning.

Deny the request; no real credential or network destination is needed.

## 8. Timeout

Trigger an approval and leave it unanswered. Confirm the agent receives an approval-timeout error rather than hanging indefinitely.

## 8a. Approved work runs with the panel closed

**Native acceptance pending.** Claude and the user should run this in their approved isolated native test setup, using a disposable project and synthetic key. The implementation/testing session did not launch or install the app, sign/package it, or read the user's Keychain or normal AgentKeyBox profile.

1. Select **Ask Every Time** so the request requires an interactive approval. From an already connected agent, call `run_with_secret` with the synthetic key's `credential_id`, `env_var: "DEMO_API_KEY"`, `command: "/bin/sleep"`, and `args: ["30"]`. This introduces a visible delay without sending data or printing the key.
2. Before approval, confirm the panel is visible, the menu offers **Review**, and the main status row identifies the request as awaiting access. Choose **Allow Once** and leave Touch ID/password authentication pending briefly: the approval panel must remain visible and the request must not start.
3. Complete authentication. After initial checks pass, the panel must disappear promptly, without waiting for the 30-second command. The agent must still be waiting for its result. The menu bar menu and main status row must show **Running: <agent> using <item>…** / **正在執行：<agent> 使用 <項目>…**, with no Review action or pending badge for that request.
4. Switch projects, close/reopen the main window, and open the menu during execution. Progress must remain available, and none of these actions may reopen the approval panel. Check that progress contains no secret, command/arguments, URL/query string or output.
5. While the first command is running, submit a second protected request from another connected helper/session. It must receive `Another AgentKeyBox approval is already pending.` or the equivalent localized busy result, without displaying another approval panel. The first request must remain unaffected.
6. After the command exits, confirm the agent receives the ordinary command result (exit code 0, empty output), only once. Both UI surfaces replace progress with the existing **Approved request completed.** message. A new protected request must now be able to show an approval panel.
7. Repeat with `args: ["65"]` to exceed the runner's current 60-second execution timeout. The panel must still close after approval; the agent receives the existing execution-timeout error and the UI shows the existing failure message. This must not be reported as an approval timeout.
8. Separately deny a request, cancel Touch ID, and leave an unanswered approval for its 120-second timeout. Each must close through its existing terminal path, show no running status afterward, and allow the next request. Cancelling authentication must not run the command.

Repeat the successful transition for a synthetic slow HTTP request, protected endpoint submission, browser login/follow/recovery and an environment request where available. An environment request is complete when AgentKeyBox returns the approved environment; the app does not track the lifetime of the caller's terminal process. The UI execution ID does not change that boundary.

For revocation regression checks, use separate disposable fixtures for each case:

- During approval/authentication or a deliberately delayed secret read, edit/delete the selected item or remove its project. Existing cancellation/version checks must prevent an operation that has not started. Do not interpret disappearance of the panel as proof that a POST or command has started.
- After a command, HTTP operation or protected submission actually starts, edit/delete the item, remove its project, or select **Ask Every Time**. Preserve the existing actual outcome instead of suggesting a retry for an already-started side effect. For recovery codes, retain the existing issued/reserved state.
- During browser login/follow/recovery, use **End Browser Access** and repeat with item/project removal. A matching pending approval must cancel; an already-started operation must retain the existing operation-failure handling, discard stale page results and never suggest re-signing in as a harmless retry. Progress must clear and the panel must not reappear.

Record the build commit, language, operation, before/after-authentication timing, both UI statuses, first and concurrent request outcomes, and whether the next approval works. Do not capture real credentials or response content as evidence.

Automated verification for implementation commit `9363d25` (2026-11-13):

- `swift test --scratch-path .build-test -Xswiftc -warnings-as-errors`: 231 tests, 2 opt-in live tests skipped, 0 failures.
- `swift test --scratch-path .build-rtest -c release -Xswiftc -warnings-as-errors`: 220 tests, the same 2 live tests skipped, 0 failures. Both configurations pass all 10 new presentation tests.
- `swift build --disable-sandbox --scratch-path .build-release -c release -Xswiftc -warnings-as-errors`: passed. SwiftPM reported inaccessible user cache configuration/security directories; no Swift compiler warnings or errors remained.
- `AGENTKEYBOX_BIN_DIR=$PWD/.build-release/release Scripts/mcp-smoke-test.sh`: passed (11 responses, including 9 expected validation errors; no native app request).
- `Scripts/check-release-qa-strings.sh .build-release/release`: passed for all three executables. `python3 -B Scripts/test-browser-acceptance-client.py`: 25 tests passed. `Scripts/security-static-check.sh`: passed.
- Strict `swift-format` lint on the five changed Swift files: passed, with zero new issues. The three existing files also have zero baseline issues at `dfd167c`; no unrelated formatting was changed.

The two skipped tests require `AGENTKEYBOX_LIVE_BROWSER_TESTS=1` and contact the public demo/GitHub. Automated presentation and existing revocation tests do not verify native Touch ID dismissal timing or the app's floating panel; the native steps above remain required. Build directories `.build-test`, `.build-rtest`, and `.build-release` are intentionally left untracked for Claude to remove after handoff; no shared DerivedData or `.xcresult` was created.

## 9. Release packaging

Before packaging, scan the directory containing all three release executables (no app launch,
Keychain access or signing is required):

```bash
swift build --disable-sandbox --scratch-path .build-release -c release -Xswiftc -warnings-as-errors
Scripts/check-release-qa-strings.sh .build-release/release
python3 -B Scripts/test-release-qa-strings.py
```

The scanner requires `AgentKeyBox`, `agentkeybox-mcp`, and `akb`; a missing executable or a
QA marker in UTF-8/UTF-16 exits nonzero. It covers the profile selector/path/domain, both
fixture configuration names, pinned browser class, interruption hook and QA window/label
strings. Run it again on each architecture's binaries when producing a universal release.

```bash
./Scripts/build-release-macos.sh
```

Confirm:

- `dist/AgentKeyBox.app` launches
- embedded `Contents/Helpers/agentkeybox-mcp` is executable
- embedded `Contents/Helpers/akb` is executable
- release ZIP exists
- SHA-256 file matches

## 10. For each new public binary

Build with a real Developer ID identity/provisioning profile and notarize the ZIP/app. These capabilities and a 0.4.0 release were already verified; repeat the applicable checks for a new binary and record new evidence in `docs/RELEASE_CHECKLIST.md` without relabeling old results as a fresh run.

## 11. Open at Login and macOS session restoration

AgentKeyBox opts out of macOS session restoration with `NSApplication.disableRelaunchOnLogin()` once per process. Login startup is controlled by `SMAppService.mainApp`; opening the app for an agent request remains a separate preference. Apple recommends this opt-out for apps with another launch mechanism: [disableRelaunchOnLogin](https://developer.apple.com/documentation/appkit/nsapplication/disablerelaunchonlogin()).

Run these checks with the updated app installed in Applications. Save other work before logging out or restarting. These checks require a real login cycle and have not been executed for this fix.

1. Turn off both startup options in AgentKeyBox Settings, then quit and reopen the app. Confirm Open at Login remains off and AgentKeyBox is absent from macOS's Open at Login list.
2. Leave AgentKeyBox running, log out with **Reopen windows when logging back in** checked, and log back in. AgentKeyBox must not reopen, including in the menu bar.
3. Open AgentKeyBox manually and turn Open at Login on. Approve it in System Settings if requested. Repeat the login cycle with window reopening unchecked. AgentKeyBox must start in the menu bar through its login item.
4. In that same app process, turn Open at Login off again. Repeat step 2; changing the toggle must not reenable macOS session restoration.
5. With Open at Login off, enable opening when a coding agent needs a key, quit AgentKeyBox, and make an explicit `list_credentials` request. The app must still open in the menu bar. Disable that separate preference, quit again, and repeat the request; it must report that the app is not running without opening it.

Restore the user's preferred startup settings after testing.

### 2026-10-22 investigation and source validation

- The affected Mac's saved `TALAppsToRelaunchAtLogin` list contained `dev.agentkeybox.app` at `/Applications/AgentKeyBox.app`. This identifies a session-restoration route independent of the app's login-item toggle; it does not establish that every reported launch used this route.
- `swift build --product AgentKeyBox -Xswiftc -warnings-as-errors` passed using isolated scratch and cache directories.
- `git diff --check` passed. Strict `swift-format` lint still reports 53 pre-existing findings in `AgentKeyBoxApp.swift`; comparing against the original file with line offsets accounted for confirmed no added findings.
- No installed app was replaced, no unit tests were run for this lifecycle-only change, and no logout/restart behavior was verified. The runtime checks above remain pending.


## 12. Protected-field submission increment — native transport acceptance passed

Automated coverage and exact native evidence are recorded in [SESSION_STATUS.md](SESSION_STATUS.md). Isolated native refusal, real-deadline timeout and pending-slot rejection passed using section 14's fixtures. On 2026-10-24, seven endpoint cases also passed normal native approval/authentication, form/JSON selected-field submission, code reservation before receipt, rejection/redirect/lost-response handling and same-profile crash/restart. On 2026-10-26, endpoint authentication cancellation/pending-edit, native status editing/code replacement, real interrupted save/restart, approved mismatch rejection and encrypted backup export/wrong-password/duplicate-import/restore also passed. Four original/renamed protected JSON files also passed native file-picker import and exact scoped synthetic Keychain readback on 2026-10-26; both imported code sets retained one Used and seven Needs review entries. Use a disposable test project and synthetic values only, with a compatible HTTPS fixture you control. Do not use a real card, account recovery code, checkout, or GitHub session.

1. **Add Item → Credit card**: enter a synthetic card number, holder, month/year, and safe label. With no destination configured, listing must show it as unavailable for submission; commands, generic HTTP, temp files, and `akb run` must never receive it. Repeat for a recovery-code set imported from a plain-text file.
2. Configure an exact test URL in the native editor. Request `submit_sensitive_fields` with selected placeholders and literal task fields. Confirm approval shows the item, exact POST URL, encoding, and complete fields, with Deny as default and no session option. Deny and unanswered timeout must leave the fixture untouched and all codes available.
3. Allow with Touch ID/password. The fixture should receive only the selected card fields or one code. The agent receives only the fixed outcome. Return raw and encoded values in body/headers/Location; none may appear in MCP output, app status, or access history. A redirect must not produce a second request.
4. Submit two broker requests concurrently: only one may hold the app's approval slot. For codes, save-before-send must prevent selecting the same entry. A lost response, 4xx, redirect, restart, or interrupted send must not automatically restore availability. Verify local correction requires authentication and explicit confirmation.
5. Edit the item while approval is pending: the prior request must fail without sending. Verify a metadata/payload revision mismatch after an interrupted edit blocks use and backup. Restore or recreate such an item from known data; do not silently pair mismatched fields.
6. Replace a code set containing previously issued entries: matching values retain their status. Export/import a backup into an isolated profile: used entries stay used; all other restored entries need review. Existing item IDs must be skipped. Reimport exported structured JSON under its original and a renamed filename: it must stay a protected item, with no submission destination inherited from the filename.
7. Verify new native forms and approval layout in English/Traditional Chinese, including many recovery codes and long field values. Imported original files/clipboard and decrypted backup copies remain outside the executor's protection; remove only test data created by this run.

These checks do not establish browser checkout or GitHub login support. That requires a separate local integration and verification of its DOM/script, screenshot, accessibility, log, and subsequent-read boundaries.

For repeatable native endpoint acceptance, start the isolated runner and invoke the client in another terminal:

```bash
Scripts/run-browser-acceptance-macos.sh --submission
python3 -B Scripts/submission-acceptance-client.py PROFILE_UUID --case card-form
```

Use the UUID printed by the runner. Run the seven cases sequentially in the same profile: `card-form`, `card-json`, `code-received`, `code-rejected`, `code-redirect`, `code-unknown`, then `code-restart`. Every case requires its own Allow Once and normal human Touch ID/login-password authentication. The final case kills only the verified isolated QA process after durable receipt, then requires a new boot, preserved Keychain status, an exact unknown-result error and a responding restarted broker. It does not reset or reuse issued codes.

This mode seeds a synthetic card and eight codes; its local HTTPS server checks exact fields and records only validation flags/code ordinals. Responses deliberately reflect synthetic values in bodies/headers/Location; the agent must receive only fixed outcomes, and redirects must not produce another request. A client timeout, accidental refusal, missing reservation or extra POST fails acceptance. The DEBUG transport pins only this profile's exact leaf certificate/loopback destination and otherwise uses the real submission implementation. Nothing is added to system trust, release builds exclude the fixture, and this does not establish production-PKI or team-signed Keychain acceptance. Quit the QA app when done; the runner removes its own accounts/profile/preferences and stops the server. A custom prebuilt DEBUG directory may be supplied with `AGENTKEYBOX_BIN_DIR`.

Signed Keychain editing acceptance **must be repeated for the 2026-11-13 review fixes**. The earlier signed normal-path result remains historical evidence; it does not validate the new pending-commit behavior. Ad-hoc QA cannot validate this path. Claude and the user should use a team-signed, entitled local test build and a dedicated synthetic service/item; do not use unrelated production credentials. A signed test harness or debugger-controlled test build is needed to stop at the operation boundaries (the release app has no fault-injection controls):

1. Confirm `usesDataProtectionKeychain == true`. Create a synthetic login/card and a two-code recovery set, then edit and read them through ordinary native approval/authentication. Count prompts: replacement/repair must add **zero** prompts beyond the existing authenticated read. Inspect both slots' accessibility/user-presence policy; both must retain the original protection.
2. Stop/restart after each successful replacement mutation: pending add, primary delete, primary add, pending delete. Also force each add/delete to fail. Initial pending-add failure must report save failure, restore the old project/allowed hosts/revision and leave the old value. After successful pending add, force primary-add failure: save must report success and retain the new metadata; read must recover the new value whether primary is old, missing or identical. Test ordinary key project/host edits and protected payload revisions separately. Never expose values in logs.
3. With pending left over, attempt another save before repair: it must fail without changing pending. Authenticate a read to repair, then save again; only the newest value may be read. Cancel pending authentication: the error must propagate without reading old primary. Fail a repair operation: pending remains authoritative and readable; another save remains blocked until repair succeeds.
4. Reserve a synthetic recovery code, including a stopped process between Keychain and metadata writes. No POST may occur until both writes succeed. A mismatch must reject use; a successfully submitted code remains issued after restart and cannot be submitted again. Verify the next successful reservation has a fresh revision. Repeat for standalone submission and browser recovery continuation with an authorized synthetic receiver.
5. Delete the disposable item and verify primary and `.pending` are absent; failed cleanup must be reported. Remove only this test's artifacts and record prompt counts, interruption point, fixed results, receipt counts and non-secret revision/status evidence. Do not infer provider task success from transport receipt.

Additional native review-fix acceptance (not executed in the automated pass):

1. With a debugger-controlled synthetic test build, pause only the Keychain worker thread at `readSecret` before returning to the main actor. For HTTP, command and terminal environment requests separately, edit the item, move it to another project, change its allowed hosts, delete it, or choose Ask Every Time while the read is pending. Resume the worker. Expect the localized `Credential changed. Request approval again.` result, zero receiver requests, no command launch and no environment response. For two-key environments, change the first key while the second is being read. Repeat with no mutation as a positive control.
2. Start a fresh `Scripts/run-browser-acceptance-macos.sh --submission` profile only when native testing is authorized. Set up a disposable project inside that profile with agent-file protection enabled; change language and export a synthetic backup. Expect `guard-rules.json` inside the profile and settings in its UUID preference domain; the normal installation's guard/preferences/helper/registration/login-item state must be unchanged.
3. In that same fresh profile, run `python3 -B Scripts/submission-acceptance-client.py PROFILE_UUID --case card-form` and export/inspect a backup while all three fixtures exist. Remove only **QA — Disposable removal project**, then repeat card-form and export/inspect another backup. Each run must show one separately approved POST, fixed result and no reflected value; backup inspection must accept exactly two cards before removal and one afterward, with one recovery-code set in both. The offline allowlist regression separately proves unknown items fail. Human authentication remains mandatory; clean up only this profile's artifacts after recording evidence.

Additional endpoint/storage lifecycle checks use the same runner:

```bash
python3 -B Scripts/storage-acceptance-client.py PROFILE_UUID --case auth-cancel
python3 -B Scripts/storage-acceptance-client.py PROFILE_UUID --case edit-pending
python3 -B Scripts/storage-acceptance-client.py PROFILE_UUID --case remove-project-pending
python3 -B Scripts/storage-acceptance-client.py PROFILE_UUID --case interrupt-edit
python3 -B Scripts/storage-acceptance-client.py PROFILE_UUID --case revision-blocked
```

Before ending that fresh QA profile, Claude can separately verify CLI registration refusal: invoke its DEBUG `akb connect all` with the matching `AGENTKEYBOX_QA_ID`, once without `--helper` and once with the profile's helper path. Both must exit nonzero with the localized QA-registration error before any helper/adapter action; the installed helper and agent-registration files must retain their pre-test hashes. This CLI check was not executed in the automated verification pass.

- `auth-cancel`: allow the synthetic code request, wait for the client to observe native authentication, then cancel Touch ID/password. Do not authenticate. The exact denial result, no new history decision, unchanged metadata/statuses, zero POSTs and a freed approval slot are required.
- `remove-project-pending` (passed natively on 2026-11-13): start a fresh `--submission` QA profile. Its dedicated **QA — Disposable removal project** / **QA — 可移除測試專案** contains a synthetic card; the driver uses that project's path. Run the case, wait for `OBSERVED: native approval slot is pending`, leave the request unapproved, then remove that project in the App. Within 5 seconds of persisted removal, the request must fail with the exact fixed error. The driver requires removal of exactly that project and its items, no new approval decision, zero POSTs or code-status changes, a freed approval slot, and a responding broker. The runner cleans up the additional synthetic Keychain account on exit. Run this once per fresh profile.
- `edit-pending`: first open and authenticate the native card editor, append ` (edited)` to its label, then start the client. Leave the request unapproved and save the editor with normal authentication. The waiting request must finish promptly without a decision or POST; the new revision, unchanged destination and consistent Keychain read-back must be verified.
- `interrupt-edit`: first unlock the native card editor and append ` (edited)` again. Start the client before saving. A DEBUG-only, one-shot hook pauses for at most ten seconds after metadata is saved but before Keychain is updated. The client checks this exact phase, kills only the verified QA PID and requires a same-profile restart with only the card revision mismatched. If the client fails to interrupt, the ordinary transaction rolls back after the bounded wait and the case fails.
- `revision-blocked`: after that interrupted save, allow/authenticate a card submission. It must fail without a POST. Also try native backup export to a fresh QA destination: the revision mismatch must prevent an image from being written. These checks do not repair the item or silently join mismatched data.

For native replacement/backup checks, first issue one synthetic code with `code-received`, then mark another Used through the authenticated editor and its confirmation. Import the same eight known fixture codes from a test text file: a new generation must preserve both non-available statuses. Export a backup inside the QA profile using the explicitly synthetic password `akb-synthetic-backup-42!`. `Scripts/inspect-submission-backup.py PROFILE_UUID /private/tmp/akb-qa-PROFILE_UUID/qa-backup.dmg` checks the real encrypted format-2 image, exact known values/revisions/statuses and protected JSON files instead of environment exports, then unmounts it. The password is only a public test fixture, never suitable for real data.

Import the backup through native Settings, checking that existing IDs are skipped without changing statuses. After the interrupted-card checks, remove only the two disposable QA items and import the valid backup again: the card must be consistent, Used codes must remain Used and every other code must Need review. Retain the synthetic original file until its exposure is inspected, then remove it with this run's QA artifacts. These native storage and backup steps passed on 2026-10-26 as recorded in SESSION_STATUS; that evidence is separate from the automated backup tests. Original/renamed protected JSON reimport also passed: use **Add Item → Import File…** to select each file separately, verify the protected kind and absence of inherited destination/injection settings, then check stored code statuses. Import leaves source files readable; remove only the known disposable originals/copies after exposure review.


## Controlled browser acceptance (unreleased)

Automated evidence: [SESSION_STATUS.md](SESSION_STATUS.md) and `BrowserTests.swift` (real WebKit with synthetic loopback HTTPS). Isolated ad-hoc native App/MCP allowed-path, denial, timeout and pending-slot rejection passed on 2026-10-24, alongside public-site checks. Native CLI approved login/read/close, denial, session/project ownership, stale-link rejection and pending-navigation cancellation also passed. These do not complete the team-signed secret-use, authentication/edit interruption or private-account scenarios below.

1. Add a Website login item using a controlled HTTPS QA website whose certificate macOS already trusts. Use synthetic credentials, a traditional same-origin POST form, and a repeatable account landing page. Confirm only label/website/reference appear in `list_credentials`.
2. Request `browser_login`. Confirm the prompt shows the actual POST destination, account label and agent/project, with no session-grant checkbox. Deny once and let one request time out; verify no POST was made. On a fresh request, allow using Touch ID/login password and confirm the task can read the protected account page without either login value or cookies appearing in tool output/history.
3. Use `browser_follow` with a returned link ID. Verify a separate destination approval, rejection of a stale link ID, and inability to navigate to another origin. Verify a second helper/project cannot read or close the session.
4. During approval, local authentication, submission and page reading, use End Browser Access. Verify the pending prompt closes and no late callback restores access. Repeat by editing/deleting the login, and verify the app's session count returns to zero on expiry/closure.
5. Verify the private page is absent from screen capture/accessibility/inspection surfaces; external browser tools cannot attach. Never expose a hidden debug browser or enable arbitrary evaluation to work around an unsupported website.
6. Restart the app; old session IDs must fail. Check that JavaScript login, SSO, OTP, password-reset/multiple-password forms, cross-origin redirects, downloads and unsupported content fail without returning secret-bearing page data. Checkout remains unsupported. Restricted recovery continuation has a separate native gate below; synthetic WebKit coverage alone does not complete it.

### Restricted browser recovery continuation — isolated native acceptance passed

Use a disposable login/code set and a trusted HTTPS fixture with a traditional form-encoded POST recovery form, one text input named `recovery_code` or `recovery-code`, and a repeatable landing GET. The existing section 14 `.invalid` fixtures are refusal-only and cannot validate this flow. Set the code item's exact submission destination to the recovery form action. Do not use a real GitHub account or real recovery codes.

1. Approve login and confirm only fixed `recoveryCodeRequired` text is returned, with no challenge-page content or links. A wrong destination, wrong project or wrong owner must never submit a code.
2. Request `browser_recover` (or CLI `browser recover`) with the stored code-set UUID. Confirm a new native prompt names the original login, selected set and actual POST action; Deny is default and no session grant exists. Deny and real 120-second timeout must leave the code available and make zero code POSTs.
3. On a new login/challenge, approve and authenticate. Verify one reservation is durable before the receiving server sees one POST, then verify the fixture's authenticated marker without login values, code or cookies in tool output. `pageReady` alone is insufficient evidence.
4. Edit/delete the selected code set while its approval is pending; interrupt authentication; terminate the browser during submission. Confirm cancellation, no stale approval, and no observation or late reopening. Once reserved, failure/restart must retain `issued`; before reservation, cancellation must not consume a code.
5. Exercise storage failure, repeated challenge and cross-origin redirect. Persistence failure must send nothing; the other uncertain outcomes must retain the reservation and never trigger another code automatically. Clear only this run's synthetic items/profiles afterward.

On 2026-10-24, isolated ad-hoc native App/MCP/CLI acceptance passed success, denial, the actual 120-second timeout, pending-close, native authenticated rename during pending approval, cancellation while LocalAuthentication was pending, and crash/restart after durable server receipt. Settings showed zero remaining browser sessions. Detailed profiles/results and failed accidental-approval attempts are in [SESSION_STATUS.md](SESSION_STATUS.md). Storage failure, repeated challenge and cross-origin rejection have real-WebKit test evidence; this is not team-signed secret-use, production-PKI or GitHub acceptance.

For repeatable native recovery acceptance without hosting a remote test website:

```sh
Scripts/run-browser-acceptance-macos.sh --recovery
python3 -B Scripts/recovery-acceptance-client.py PROFILE_UUID
```

The runner starts a loopback-only HTTPS fixture and creates a one-day certificate. Only its DEBUG QA browser trusts that exact certificate at the configured loopback host/port; nothing is installed in system trust. The ad-hoc QA app uses an isolated legacy Keychain. This is not production-PKI or team-signed Keychain acceptance. The runner still requires native approvals and normal Touch ID/login-password authentication.

The client first requests login. Approve and authenticate, then type `START` in its terminal to request the separate recovery operation. Approve and authenticate again for the default allowed case. Acceptance requires fixed `recoveryCodeRequired` output before code use, one matching history event per approval, durable Keychain read-back status before exactly one server POST, the fixture's verified result marker, redacted output/history, and a closed session afterward. The fixture has four synthetic codes. Later allowed cases use the next available code; never reset an issued code. The server ledger must show ordered unique code indices with durable reservation before every POST.

`--expect denied` or `--expect timeout` applies to the **second**, recovery prompt; the initial login still needs approval/authentication. For timeout leave that second prompt untouched for 120 seconds. `--transport cli --expect close-pending` proves the recovery prompt is pending through the broker, then automatically closes the same browser and requires immediate failure, no new approval decision, no additional reservation or code POSTs. `--transport cli` is also supported for allowed/refusal cases. A transport error or an accidental approval fails acceptance.

`--transport cli --expect close-auth` waits for the exact native pending request and the DEBUG LocalAuthentication phase, then closes that browser before authentication completes. Click Allow Once only when instructed, without completing Touch ID/password. `--expect edit-pending` requires opening the native recovery editor after login, appending ` (edited)` to its label, then saving after the pending recovery request starts; normal edit authentication still applies. `--expect restart-submitting` holds the server response after durable receipt, kills only the verified QA PID, restarts the same profile, and requires persisted statuses, a responding broker and rejection of the old browser.

The profile's `recovery-statuses.json` contains only synthetic-code statuses read back by the QA app. `server-event.reservation` records whether that persisted status existed when the POST arrived; `server-event.recovery` counts requests. `server-event.ledger` contains only code indices, durable-before-POST and duplicate flags. `recovery-auth-phase` records only pending/ended, while `recovery-boot-id` changes after Keychain readback on each app start. These are local test evidence, not agent tools or production output. Quit the QA app after recording results; the runner stops its server and deletes only its exact fixture accounts, directory and preferences. Never change the runner while it is active.

## 14. Repeatable isolated native browser acceptance

**Signed local acceptance, 2026-10-27:** the installed Developer ID signed **0.4.5** app and signed MCP helper passed one explicitly authorized public-demo login using a disposable item in the data-protection Keychain. Native approval/authentication completed; login and constrained read both contained the Secure Area marker, and read renewed link IDs. Close succeeded, later read was rejected, and native Settings showed zero sessions with End Browser Access disabled. Exactly one matching `allowOnce` history event was recorded; metadata was unchanged during use and known raw/common encoded fixture values were absent from observations/history. The item was deleted through the native app; the original two credentials/project metadata returned byte-identically. Evidence: `dist/local-storage-acceptance/validation/signed-login.json` and [SESSION_STATUS.md](SESSION_STATUS.md#signed-local-045-public-demo-login-acceptance--2026-10-27). This covers signed public-demo login/read/close only; signed card/recovery use, real private accounts, readable follow, notarization and publication remain separate gates.

Run `Scripts/run-browser-acceptance-macos.sh` on a Mac. It uses a private scratch build unless `AGENTKEYBOX_BIN_DIR` points to a matching DEBUG build. Do not reuse a release helper. It prints a UUID profile and opens **AgentKeyBox QA**, seeded with the public demo account from [The Internet login page](https://the-internet.herokuapp.com/login), a synthetic card, and two synthetic recovery codes. Card/code destinations use the reserved `.invalid` domain and are for refusal tests only. This is an ad-hoc test build, not validation of production signing/data-protection Keychain entitlements.

From another terminal in the same project:

```sh
/usr/bin/python3 Scripts/browser-acceptance-client.py PROFILE_UUID
```

Replace `PROFILE_UUID` with the UUID printed by the runner. In the native QA prompt, review the public destination, allow once, and complete the normal local authentication prompt yourself. The client checks the protected page, reads it, closes it, and verifies a subsequent read fails. It does not automate human authentication.

For refusal checks, choose the exact case and leave authentication untouched:

```sh
python3 -B Scripts/browser-acceptance-client.py PROFILE_UUID --expect denied
python3 -B Scripts/browser-acceptance-client.py PROFILE_UUID --expect timeout
python3 -B Scripts/browser-acceptance-client.py PROFILE_UUID --kind card --expect denied
python3 -B Scripts/browser-acceptance-client.py PROFILE_UUID --kind card --expect timeout
python3 -B Scripts/browser-acceptance-client.py PROFILE_UUID --kind recovery --expect denied
python3 -B Scripts/browser-acceptance-client.py PROFILE_UUID --kind recovery --expect timeout
```

Choose Deny only for `denied`; leave each `timeout` prompt untouched for the real 120-second deadline. The client requires a tool error plus exactly one matching **new** native history event (`deny` or `timedOut`, matching agent label/item/project). A timeout additionally requires the fixed `Approval timed out.` response and measured duration. The fixtures' metadata must be unchanged. Connection/preflight errors and accidental approval now **fail** the requested case; an accidentally approved browser is closed. Card/recovery allowed-path runs are deliberately refused by the driver.

While a known QA prompt is still waiting, run `--expect busy` from a second terminal. It must return the exact pending-approval message within 15 seconds without a new history decision; confirm the first prompt remains unchanged. This probe is valid only while another request is pending. The `.invalid` fixtures do not provide receiving-server evidence or demonstrate card/recovery success or reservation persistence.

`python3 -B Scripts/test-browser-acceptance-client.py` runs the offline regression checks against false-positive acceptance results and fixture-value reflection. It is also part of `Scripts/check-all.sh`.

For native CLI checks, add `--transport cli` to a login case above (or the default allowed case). The driver invokes separate CLI processes with the original session/project handles and checks the same native history. For manual CLI checks, set `AGENTKEYBOX_QA_ID=PROFILE_UUID` and use the exact QA CLI path printed by the runner; never mix it with the installed helper. `browser list` must contain only the public demo login. Use `akb browser help` for the login/read/follow/close arguments and maintain the same project.

To test ownership, stale links and cancellation of a pending navigation:

```sh
python3 -B Scripts/browser-acceptance-client.py PROFILE_UUID --transport cli --flow close-pending
```

Allow the **QA login** and complete normal local authentication. The driver checks protected content and verifies that a different session/project cannot read, follow or close the browser, while its original owner still can read it. It also rejects an old link ID after a new read, without creating a prompt. When the terminal asks for `START`, enter it and leave the upcoming **QA 終止測試** prompt unanswered. The driver confirms the exact broker pending-approval response, closes that same browser automatically, and requires the waiting call to fail within ten seconds with no new approval decision. It then checks that later reads fail, the approval slot is free and metadata is unchanged. Confirm native Settings shows zero browser sessions and no remaining prompt.

Accidental approval or failure to observe a pending request fails this case. The driver terminates its outstanding CLI children on exit. The public demo exposes Logout as its only supported same-origin link; Logout returns to a password form that the current observation policy refuses. This fixture therefore does not prove successful native readable navigation. Successful follow and revocation during an in-flight navigation are covered by the synthetic WebKit runtime fixture instead.

Quit the QA app to clean up its unique data directory, bundle, preferences and three exact fixture Keychain items. No existing app, agent config or login item is installed/changed. Do not edit a shell script while it is still running; stop it before changing the runner. Record evidence before deleting the test build/logs. The script prints the removed directory and size.

Opt-in live WebKit checks use real system TLS and no Keychain:

```sh
AGENTKEYBOX_LIVE_BROWSER_TESTS=1 swift test --filter LiveBrowserTests
```

These checks contact the public demonstration website and GitHub's unauthenticated login page. They run no GitHub authentication or 2FA/recovery-code submission. The full test suite skips these network-dependent checks by default.
