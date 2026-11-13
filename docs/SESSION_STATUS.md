# AgentKeyBox implementation status

## Agent scope decision — 2026-11-05

dots / ChatGPT Work, Meta Muse (including Muse Code), Grok Bot and Claude Duet cannot be tested here, so they were removed from user-facing documentation and `docs/AGENT_COMPATIBILITY.md` was deleted. The `akb browser` command reference moved to [INTEGRATION.md](INTEGRATION.md). Later sections mentioning these products are historical records, not support claims.

## Native and signed acceptance of the merge-blocker fixes — 2026-11-13 (unreleased)

Branch `feat/protected-items-browser` at `991c831`. The user completed every Touch ID prompt; only synthetic data was used.

| Check | Environment | Result |
| --- | --- | --- |
| `remove-project-pending` | Ad-hoc QA `--submission`, profile `C5DF69D5-42DD-4AA1-9E74-65BB45B332D6` | **Passed.** Removing **QA — 可移除測試專案** while its card request waited closed the prompt; exact result/history, zero POST or reservation change, responsive broker. |
| `code-received` | Same profile | **Passed** on the second run: one `allowOnce`, one exact-fields POST, durable reservation before POST, rotated payload revision and matching metadata, no reflected secrets or cookies. The first run's transport also passed, but the driver failed its history match because the app records `/tmp/...` while the driver compared `Path.cwd().resolve()` (`/private/tmp/...`). Run the drivers from a directory without a symlinked prefix. |
| Browser recovery, MCP allowed | Ad-hoc QA `--recovery`, profile `5BA46A7E-1508-402B-AD5F-D2063556D300` | **Passed.** Approved login returned only the fixed challenge; the separate approval made one durable reservation before one POST; no synthetic secret in output/history; session closed. |
| Signed Keychain normal path | Developer ID signed arm64 build of `991c831` installed in `/Applications`, data-protection Keychain | **Passed.** Adding a six-code synthetic item needed no Touch ID. Unlock: one Touch ID, all codes read back. Saving a rename: one Touch ID (edit authentication), then readback after a second unlock showed the new name and all six codes. Deleting it restored `metadata.json` and `access-log.json` byte-identically. The fixed-path MCP helper matches the installed bundle. |

Not covered natively: interruption and failure injection between the pending and primary Keychain writes (release builds have no hooks; unit tests only) and QA `akb connect` refusal. Both QA runners removed their profiles (173,224 KiB for the submission profile). The previous 0.4.5 app is kept at `dist/local-protected-items/previous-AgentKeyBox.app` for rollback.

## Merge-blocker fixes — 2026-11-05 (unreleased)

Implemented in the `feat/protected-items-browser` verification worktree, based on `aab7b5d`. No App launch/installation, production vault/Keychain/token access, native acceptance, signing, notarization or publication was performed in this pass. Historical native results below remain historical evidence; they do not validate these new binaries.

| Fix | Commit | Result and regression evidence |
| --- | --- | --- |
| P1 text filtering | `1e557c6` | Body and link text share bounded per-text-node visibility filtering. `testPageAndLinkTextExcludeInvisibleAndBlockedDescendants` covers hidden/script/textarea/display-none/visibility-hidden/collapse descendants plus hidden body text and preserved visible labels through real WebKit. Browser policy/runtime subset: 21 tests, 0 failures. |
| P1 project revocation | `b3d938e` | Persist project removal, revoke every removed item, then delete Keychain values. App checks browser ownership/current metadata again after awaited page operations. `testRevocationDuringReadDiscardsLatePage` and existing `testRevocationDuringFollowDiscardsLatePageAndClosesOnce` reject late pages; `ProtectedAccessRevocationTests` covers all matching login browsers, a pending recovery browser, unrelated items, and preservation of started submission outcomes. Related runtime/revocation/localization subset: 24 tests, 0 failures. |
| P1 Keychain replacement | `8df2a51` | Approach **b**: insert-only protected pending copy, replace primary, then remove pending; authenticated reads repair pending first. Approach **a**, `SecItemUpdate`, was rejected because save callers do not carry a grant and updating user-presence items may add authentication. Mutation contexts disallow UI, while accessibility and user-presence flags remain unchanged; legacy operations retain their existing implementation. Eight `RecoverableSecretReplacementTests` cover add/delete failures, interruption after each mutation, pending-only/old-primary/same-primary recovery, repair/authentication failure, stale pending protection, deletion and stale recovery revisions. Related replacement/recovery/submission/runtime subset: 41 tests, 0 failures. |
| P2 QA registration | `08628af` | `akb connect` invokes a Core guard before helper installation and adapter calls, returns a localized error/nonzero exit in QA, and keeps release behavior. `testQAProfileRejectsAgentRegistrationAndNormalProfileAllowsIt` plus profile/localization subset: 9 tests, 0 failures. The CLI command itself was not executed. |

Recovery reservations now rotate payload revisions for both endpoint and browser use. The app persists the issued payload and matching metadata before sending. Interrupted metadata/secret writes fail closed; no recovery path silently reuses an older available-code payload. Read repair can return the latest authenticated pending value even if cleanup fails; another write stays blocked until repair succeeds. A partially committed edit/reservation may therefore require native recovery of a revision mismatch rather than silently rolling back code history.

Other removal paths were inspected individually and left unchanged:

- `importBackup` (original line ~635): removes only newly imported IDs after metadata-save failure. It is synchronous on the main actor; no broker request can obtain those IDs before rollback.
- `addCredential` (original line ~830): rolls back one newly generated ID in the same synchronous call after persistence fails; no protected request/browser can exist for it.
- `storeEnvSecrets` (original line ~951): removes only just-added environment-variable IDs without a suspension point; existing IDs are not removed. No additional protected revocation is needed.

Final automated verification (same source state as the four repair commits; subsequent changes are documentation only):

| Command / check | Actual result |
| --- | --- |
| `swift build --disable-sandbox --scratch-path .build-debug -Xswiftc -warnings-as-errors` | Exit 0; 10.33 seconds. |
| `swift test --scratch-path .build-test -Xswiftc -warnings-as-errors` | Exit 0; **184 tests, 2 skipped, 0 failures**; 36.110 seconds for the full suite. Both skips are opt-in LiveBrowserTests, which remained disabled. |
| `swift build --disable-sandbox --scratch-path .build-release -c release -Xswiftc -warnings-as-errors` | Exit 0; 31.91 seconds. |
| `AGENTKEYBOX_BIN_DIR=$PWD/.build-release/release Scripts/mcp-smoke-test.sh` | Exit 0; **11 JSON-RPC responses**, including **9 expected validation errors** rejected before contacting the App. |
| `python3 -B Scripts/test-browser-acceptance-client.py` | **24 tests, 0 failures**. Includes exact project-removal/cancellation evidence and fresh reservation-revision requirements for endpoint/browser drivers. |
| `Scripts/security-static-check.sh` | Exit 0; both hardcoded-secret and unsafe logging/persistence checks passed. |
| `bash -n Scripts/run-browser-acceptance-macos.sh` | Exit 0; **1 modified shell file**. Only parsed, never executed. |
| `xcrun swift-format lint --strict` on changed Swift files | **17 files; 0 new diagnostics, 0 remaining pre-existing diagnostics**. |
| Aggregate whitespace check | `git diff --check HEAD~4` passed with the final documentation working changes included; the corresponding post-documentation-commit check is `git diff --check HEAD~5`. |
| Release QA exclusion | `strings -a` / `grep -F`, supplemented by raw UTF-8 checks: **3 executables × 13 markers = 39 checks, 0 matches**. |

The 13 excluded markers were `AGENTKEYBOX_QA_ID`, `recovery-fixture.json`, `submission-fixture.json`, `PinnedRecoveryFixtureBrowser`, `interrupt-card-save`, `removal-project`, `remove-project-pending`, both new English QA project/card labels, both Traditional Chinese labels, and the English/Traditional Chinese QA registration error. No release executable was launched except the MCP helper's validated smoke-test input.

The sandboxed builds each reported SwiftPM's two user-cache accessibility warnings; Swift compilation still passed warnings-as-errors. An initial combined edit/test invocation failed at manifest sandbox setup; the standalone, authorized `swift test` invocation succeeded. Initial combined git stage/commit commands could not create the shared worktree index lock; separate permitted git commands succeeded. No code/test failure remains.

**Native/signed acceptance remains unverified:** run the fresh-profile `remove-project-pending` procedure and signed Keychain interruption/prompt-count checklist in [MACOS_TEST.md](MACOS_TEST.md). The new fixture is a dedicated DEBUG/QA project and card; its exact synthetic account is included in runner cleanup. The driver requires cancellation within **5 seconds** of persisted removal, no new approval decision or POST, unchanged code statuses, a released approval slot and a responding broker. Existing native submission and browser recovery cases also need to exercise the newly advancing reservation revision. The signed public-demo login/read/close result below remains valid historical evidence; signed card/recovery submission, browser recovery continuation and the changed Keychain replacement have not been validated here.

Build cleanup is delegated to Claude as requested. Retained scratch directories: `.build-debug` **157,628 KiB**, `.build-test` **268,900 KiB**, `.build-release` **119,308 KiB** (**545,836 KiB total** at measurement). No shared DerivedData or `.xcresult` was created or removed; no build artifacts were staged. This pass freed **0 KiB** of build artifacts.

## Evidence and review scope

Documentation was first reconciled on **2026-10-22** against the **0.4.0** baseline. The same task then implemented the unreleased protected-field submission increment described below. Released-product evidence, new automated checks, and still-pending GUI/provider checks are kept separate.

Historical runtime/test results are recorded separately in [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md), primarily dated 2026-10-15. [PRODUCT.md](PRODUCT.md) owns the product requirements; [ROADMAP.md](ROADMAP.md) owns the selected next work.

## Native protected JSON import acceptance — 2026-10-26 (unreleased)

All four original/renamed JSON cases passed in isolated profile `593D6043-A276-4C12-A1C3-453DD37062BF`. Added **Add Item → Import File…** in English/Traditional Chinese: a single-file native `NSOpenPanel` uses the existing drop/import path. Each file was selected individually; the list increased from two to six items. This is native file-picker acceptance, not an automated cross-window drag.

| File | Protected kind / new ID |
| --- | --- |
| `QA — Local synthetic card (edited).card.json` | `creditCard` / `F95BDFF0-871F-4D87-8771-0A4A181FA736` |
| `renamed-card.json` | `creditCard` / `F068E756-62A6-4C57-BAF9-406B44FDA412` |
| `QA — Local submission codes.recovery-codes.json` | `recoveryCodes` / `478DA42E-9858-4C81-8306-82D2E0D1DEA6` |
| `renamed-codes.json` | `recoveryCodes` / `6EE70FCB-F714-4BB3-ADE4-04FD0080650F` |

Metadata and live MCP discovery confirmed protected kinds and no inherited destination, injection variable, settings, allowed hosts or project scope. The original two records remained identical. Exact-service/account Keychain readback compared only these four known synthetic payloads inside the checker, without printing values: card contents, revisions, recovery-code IDs/generation and conservative statuses matched. Both imported sets contain **[needsReview, used, needsReview × 6]**. The checker first needed hexadecimal decoding for `security` output; another attempt checked three items before the last access prompt exceeded ten seconds. A separate successful read checked that last UUID. No Keychain access controls or code statuses were changed.

Exposure review confirmed the four plaintext originals/copies remained readable and byte-identical after import. Card SHA-256: `263e1ba207620f3e8fc18bb5774782301ddfa0696e93e4eebe92cd58f17b5b14`; code SHA-256: `9265aa8ac693484a8d463b755497386a518db8becfbc652632092f5ec6c6d1cd`. Import does not erase original files or copies from opened backups. Raw/base64/URL/hex fixture values were absent from metadata, history, receiver evidence and MCP discovery. The earlier encrypted backup stayed byte-identical; the receiver still had one entry and zero errors. No new submission occurred. An optional readback-backup Save panel stayed disabled under automation; it was cancelled and produced no backup. Scoped Keychain checks supplied the readback evidence instead. Previously passed cancellation, editing, replacement, interruption and backup/restore cases were not rerun.

**QA launch defect found and fixed:** opening the stopped QA bundle through Launch Services without `AGENTKEYBOX_QA_ID` initially loaded production metadata and refreshed the fixed-path MCP helper with an ad-hoc helper. That app was closed, the original signed **0.4.4** helper restored, and the production app restarted after confirming zero browser sessions/no pending prompt. A fresh installed signed helper successfully queried the restored broker. Production metadata retained SHA-256 `cb543c231773526c45a70a441e57e83e2dfd961e7623058d2ed3ede1c7a8bbe6`; no production secret was read. Existing MCP processes were not terminated: processes that loaded the temporary ad-hoc helper need reconnection and are correctly rejected by the signed broker.

`DevelopmentProfile` now rejects QA bundle launches with a missing, malformed or mismatched profile UUID before any production fallback. Three regression tests cover this boundary and ordinary development/helper behavior. A real QA app probe without the environment aborted before changing production metadata, history, token, helper or broker socket inode. **Eight targeted tests passed** (three profile and five localization tests); DEBUG/release warnings-as-errors builds, strict formatting of changed Swift files, final signed MCP/CLI smoke and whitespace checks passed. Earlier full-suite/core results remain applicable and were not rerun.

A local arm64 **0.4.5** candidate is prepared at `dist/local-storage-acceptance/AgentKeyBox.app`, signed with the existing Developer ID, provisioning profile and exact Keychain entitlements. All three executables exclude QA selectors/hooks. Normal macOS deep/strict signature verification passes; verification inside the restricted executor sandbox failed and was rechecked successfully with normal certificate access. The candidate was then installed locally as described below. It has not been notarized or published; signed sensitive-use acceptance remains open.

Cleanup completed: all seven exact QA Keychain accounts (three fixture IDs plus four imported IDs) returned not-found (44), the isolated preferences were removed and no QA image was mounted. Removed `/private/tmp/akb-qa-593D6043-A276-4C12-A1C3-453DD37062BF` (**14,500 KiB**) and `/private/tmp/akb-storage-native.zAsVTG` (**391,224 KiB**), freeing **405,724 KiB (396.2 MiB)**. This includes the synthetic plaintext originals/copies and encrypted QA backup. No shared DerivedData or `.xcresult` was created or removed. The candidate and non-secret validation records remain under `dist/local-storage-acceptance`.

## Signed local 0.4.5 public-demo login acceptance — 2026-10-27

Installed the signed arm64 candidate at `/Applications/AgentKeyBox.app`, retaining a verified **0.4.4** rollback at `dist/local-storage-acceptance/previous-AgentKeyBox.app`. The installed app and rollback pass normal macOS deep/strict signature validation; the fixed-path MCP helper is byte-identical to the installed helper. Provisioning profile and Keychain entitlements are unchanged. Native Settings confirms the data-protection Keychain path, a responding broker and zero private browser sessions. Source/release version remains 0.4.0; this is a local build update, not a public release.

Used one disposable native **Website login** item, `QA Signed 0.4.5 public demo`, ID `BA4E7D4A-D459-442E-8691-7105E3F4ADD1`, containing the test site's publicly supplied demonstration values and `https://the-internet.herokuapp.com/login`. The earlier automatic approval rejection was resolved by the user's explicit authorization of that account/destination. The installed signed MCP connector successfully discovered the item and performed this test; no unrelated production credential was read.

Native approval and authentication completed. Both `browser_login` and `browser_read` returned the expected **Welcome to the Secure Area** marker over production TLS, with the same private session and renewed link IDs. Acceptance depends on that marker, not `pageReady` alone. `browser_close` returned its fixed success message; a subsequent read failed with the fixed browser-operation error. No link was followed. Native Settings showed **zero private browser sessions**, disabled End Browser Access, and the allowed Codex request.

Exactly one new native history event, `02F0B62F-99B8-4CEE-B902-662294EC14B6`, records `allowOnce` for Codex, this item and this project. Metadata stayed byte-identical during use. Raw, URL-encoded, base64 and hex forms of known fixture values were absent from tool output, metadata and history. The retained non-secret summary is `dist/local-storage-acceptance/validation/signed-login.json`, with the pre-use fingerprints in `signed-login-baseline.json`.

Deleted only this disposable item through the native app. The global list is empty and connector discovery no longer exposes it. The two pre-existing project credentials and project metadata are byte-identical to the original pre-test file, SHA-256 `cb543c231773526c45a70a441e57e83e2dfd961e7623058d2ed3ede1c7a8bbe6`. The historical access event remains. Removed the obsolete `dist/local-storage-acceptance/validation/signed-login-pending.json` (222 bytes; 4 KiB allocated) and this verification's `Scripts/__pycache__/browser-acceptance-client.cpython-314.pyc` (33,594 bytes; 36 KiB allocated), freeing **40 KiB** of allocated file storage. No build, DerivedData or `.xcresult` was created in this continuation. Documentation whitespace checks passed; previously passed tests were not rerun.

This passes the **Developer ID signed app + data-protection Keychain + native-approved public-demo login/read/close** slice. Signed card/recovery endpoint use with production PKI, real private-account/GitHub/checkout compatibility and readable browser follow remain open. The local candidate is still unnotarized and unpublished; source/release version remains 0.4.0.

## Native protected storage lifecycle acceptance — 2026-10-26 (unreleased)

The JSON/cleanup checkpoint at the end of this historical section is superseded by the continuation above.

The endpoint/storage cases below passed in isolated profile `593D6043-A276-4C12-A1C3-453DD37062BF`, using the ad-hoc DEBUG app, separate legacy Keychain, ordinary native approval and human LocalAuthentication. Synthetic values went only to the pinned loopback HTTPS receiver. Production metadata matched the SHA-256 fingerprint recorded before this work; the installed production app remains local build **0.4.4**.

| Case / native label | Observed result |
| --- | --- |
| Cancel endpoint authentication / `QA c188723c` | Client observed pending approval and system authentication, then human cancellation. Exact fixed denial, no new history decision, no POST/reservation/metadata change, freed approval slot and responsive broker. |
| Edit while endpoint approval is pending / `QA fced0f22` | Authenticated native card rename created a consistent new revision and promptly cancelled the old request. No approval decision, POST or code-status change; destination and other metadata retained. |
| Submit one code / `QA b131f00b` | One native approval and exact-fields form POST; the first code was durably `issued` before receipt. Fixed result, no reflected secrets or cookies. |
| Native status edit and file replacement | Code 2 changed to `used` through the authenticated editor and explicit status confirmation. Importing the same eight known codes produced a new generation/revision while retaining `[issued, used, available × 6]`; card and destinations unchanged. |
| Native encrypted export | `qa-backup.dmg` opened with the synthetic password. Read-only inspection verified encrypted compressed format 2, exact known card/code payloads, matching revisions and statuses, and protected JSON files without `.env`/`env.txt`. Image was unmounted after inspection. |
| Wrong password and duplicate import | Native UI rejected a deliberately wrong password. Correct password previewed two keys/zero projects; import reported zero additions, retaining exact metadata, statuses and generation. Backup hash unchanged. |
| Real save interruption / same-profile restart | Driver observed native metadata save before Keychain write, killed only verified QA PID `16429`, and required a new boot from PID `18713`. Only the card revision became inconsistent; no POST or code-status change. |
| Approved use after interruption / `QA 08a9f5e1` | Normal Allow Once/authentication still rejected the mismatched payload. Exact fixed error/history, no additional POST/reservation and responsive broker. |
| Native export after interruption | UI reported a corrupt/type-mismatch error. `blocked-backup.dmg` was not created; the earlier valid backup remained byte-identical. |
| Native restore into empty QA | Both disposable items were deleted through the UI and zero-item metadata confirmed. Native backup import restored exact item metadata/revisions/generation; card consistency returned. Code 2 stayed `used`; all seven other codes became `needsReview`. |

The first attempt (`QA f49c1d63`) was refused at the AKB prompt before system authentication and correctly **failed** the specific authentication-cancellation case. It did not send or consume anything. The later observed cancellation above is the passing evidence. The receiver recorded **one unique POST, zero duplicates/unexpected requests and zero fixture errors** throughout these lifecycle cases. Native Settings showed zero browser sessions.

Fixed the acceptance-only backup inspector: `hdiutil -stdinpass` receives the exact password bytes followed by EOF, matching `BackupArchive`; its former trailing newline was interpreted as part of the password and caused inspection to fail. The same native-exported image passed after this correction. No production implementation changed. The current DEBUG incremental build, inspector syntax and whitespace checks passed; the prior **168 Swift tests (166 passed, two opt-in external tests skipped)** and **23 offline acceptance tests** remain applicable rather than being rerun for documentation/test-tool changes.

The earlier prepared profile `025A5B39-423F-4A5F-84C9-1683A9A21D41` was no longer running when resumed. All eight codes were still available. Its three exact QA Keychain accounts were removed/verified not-found (44), preferences removed, and its **14,268 KiB** directory deleted before using the fresh profile. The dedicated build was reused.

Supplementary native original/renamed JSON import is **awaiting human drag-and-drop**, not passed. Four verified synthetic files are prepared in `/private/tmp/akb-qa-593D6043-A276-4C12-A1C3-453DD37062BF/json-reimport`, and Finder is open there. The current UI only exposes generic file import through drop; the available computer tool does not provide reliable cross-window drag targeting. The user was asked to drop the four files individually into the isolated QA global list. No new imports had occurred at this checkpoint (two restored items remain). Originals and the prepared decrypted copies are readable files outside the executor boundary; importing does not erase them. Inspection mounts were detached and removed.

Final read-only checks passed: the restored broker answered discovery, had no pending approval slot, and known raw/common encoded synthetic values were absent from model-readable metadata, history and ledger. No unexpected destination was recorded. The active QA runner (session `53474`, app PID `18713`) and dedicated build `/private/tmp/akb-storage-native.zAsVTG` are retained only for this unfinished manual check. After import, validate all four new items as protected types with no inherited destination or injection settings, verify conservative code statuses, record their IDs for exact QA Keychain cleanup (the runner only knows its original three fixture IDs), then quit QA and remove this run's profile/build and plaintext copies. No shared DerivedData or `.xcresult` was created or removed. Only the old unused profile's **14,268 KiB (13.9 MiB)** has been freed so far.

Real provider/checkout/GitHub compatibility, other agent hosts, pure-cloud transport, team-signed sensitive use and successful readable browser follow remain separate open gates.

## Protected storage lifecycle follow-up — implementation and automated validation (unreleased)

Fixed the pending endpoint approval lifecycle: authenticated native edits now cancel the selected item's old approval/authentication before committing the change; deletion does so after metadata removal succeeds. Browser invalidation remains in the same path. Already-started endpoint operations retain their actual outcome rather than being labelled as cancelled before use. A request-ID recheck after the asynchronous decision-recording step prevents a cancelled request from persisting a late approval or starting execution.

Added `storage-acceptance-client.py` for observed native authentication cancellation, authenticated editing during a pending submission, real QA interruption between metadata and Keychain writes, and approved rejection of the persisted revision mismatch. Assertions require exact fixed output/history, unchanged receipt/status evidence and a responding broker. The DEBUG fixture exports only authentication phase, revision-match flags, a payload revision reference and code generation; the one-shot crash window is restricted to the seeded synthetic card and falls back to ordinary rollback after ten seconds. Release builds exclude these hooks. `inspect-submission-backup.py` inspects only the two known fixture items in a QA-local encrypted image and unmounts it without printing payloads/passwords.

Automated verification: **168 Swift tests executed, 166 passed, 2 opt-in external-site tests skipped, 0 failures**; **23 offline acceptance-driver tests passed**. The new real encrypted-disk-image regression round-trips typed card/code payloads, checks conservative restored statuses, and confirms that a revision-mismatch export leaves the previous valid backup byte-identical. DEBUG/release warnings-as-errors builds, release MCP/CLI smoke, strict changed-core/test formatting, Python/shell syntax, security static checks and whitespace checks passed. The final app-only request-ID guard also passed DEBUG/release rebuilds; the unchanged helpers retain their smoke results and core test evidence remains applicable. All three final release executables exclude the QA selector, phase/storage/crash hooks, certificate paths and synthetic values.

Native status: the isolated QA profile `30457FAE-57C0-466E-9314-667CEC56C35A` launched successfully. UI-tool attachment was unusually slow; no approval test was started during that wait. The final DEBUG app was loaded with a same-profile restart before testing. An `auth-cancel` attempt (`QA 54d5f911`) observed the real pending approval and LocalAuthentication phase. The automation's Escape action did not establish cancellation: authentication actually completed, history recorded `allowOnce` and the first synthetic code became `issued`. The driver correctly **failed** cancellation acceptance. Its receiver then encountered a missing case-configuration file before reading the POST body (one failing POST-handler entry); no valid receipt ledger was produced. The test client now initializes that configuration and complete synthetic field map even for negative cases, so accidental approval will have countable receipt evidence. The issued code was not reset.

**None of the new native lifecycle/replacement/backup cases has passed yet.** The remaining cases require coordinated human authentication; the readiness question was still unanswered at this checkpoint. The earlier seven endpoint outcomes remain valid evidence for their own cases. Native procedures are in [MACOS_TEST.md](MACOS_TEST.md#12-protected-field-submission-increment--native-transport-acceptance-passed); the release gates stay unchecked in [ROADMAP.md](ROADMAP.md). Production metadata matched the pre-run SHA-256 fingerprint.

The installed production bundle remains local build **0.4.4**. This follow-up does not install or publish a new release, access production secrets, establish provider/GitHub compatibility or add a cloud endpoint.

Cleanup: the QA runner exited, stopped its server and removed its app/profile/preferences. All three exact QA Keychain account lookups returned not-found (44). After preserving the results above, removed `/private/tmp/akb-storage-acceptance.j2hl50` (**402,708 KiB**) and `/private/tmp/akb-qa-30457FAE-57C0-466E-9314-667CEC56C35A` (**14,264 KiB**), freeing **416,972 KiB (approximately 407.2 MiB)**. No shared DerivedData or `.xcresult` was created or removed. Existing shared changes and retained production rollback bundles remain untouched. Continue the outstanding native cases in a fresh synthetic profile; do not revive the issued code from this failed cancellation attempt.

## Native protected-field submission acceptance — 2026-10-24 (unreleased)

All seven planned native endpoint cases passed in isolated profile `AC8EC680-5316-4231-8A4D-A3AA0CAC55BA`. The ad-hoc DEBUG app used a separate legacy Keychain, normal native approval and human Touch ID/login-password authentication. Only synthetic values were sent to its exact loopback HTTPS destinations; no payment or real account operation occurred. The installed production app remains local build **0.4.4**.

| Case / native agent label | Verified result |
| --- | --- |
| `card-form` / `QA 65d5b97c` | One form POST containing only card number, month and the literal test note; holder/year omitted; fixed `received`. |
| `card-json` / `QA 285048e4` | One JSON POST containing all four selected card fields and the note; fixed `received`. |
| `code-received` / `QA b4fa211c` | First code durably reserved before one form POST; fixed `received`. |
| `code-rejected` / `QA 87d7b8e9` | Second code reserved before one JSON POST; HTTP 422 became fixed `rejected`, without restoring availability. |
| `code-redirect` / `QA 5e06e667` | Third code reserved before one form POST; HTTP 302 became fixed `redirectBlocked`. No request followed the secret-bearing Location. |
| `code-unknown` / `QA 36071f8d` | Fourth code reserved before one JSON POST; receiver closed the connection before response headers. Fixed `unknown`, no second POST or automatic reuse. |
| `code-restart` / `QA 41ee5ffc` | Fifth code durably received once while the server held its response. The driver killed only verified QA PID `69723`; the runner restarted the same profile as PID `71794`. Fresh boot evidence followed Keychain readback, the waiting MCP call returned the exact unknown-submission error, and the restarted broker answered discovery. |

Final evidence: **7 exact `allowOnce` history decisions, 7 unique POSTs, 0 duplicate/redirect requests, 0 fixture server errors**. All five submitted codes remained `issued`; the other three remained `available`, including after restart. Each receiver entry validated the exact fields/content type and absence of Cookie/Authorization. Code entries additionally verified persisted status before receipt. Metadata remained unchanged except for the expected recovery item's update timestamp; its revision and destination were preserved. Model-readable results/history contained no raw or common encoded synthetic values, cookies, response bodies, headers or redirect destinations. The native app returned to its main window without an approval prompt after restart. These are transport outcomes, not proof of payment or sign-in success.

Added repeatable `--submission` QA with a DEBUG-only profile-bound certificate pin around the real submission transport, eight synthetic codes, a status-only Keychain read-back and ordinal/boolean receiver evidence. The new client requires an exact native history decision, exact fixed output and exactly one matching POST. Offline tests reject wrong fields, encodings, outcome text, duplicates and missing durable reservations. Existing fixture storage is never reset on restart. Native refusal, actual timeout and pending-slot checks from the earlier run remain separate valid evidence.

Validation: **167 Swift tests executed, 165 passed, 2 opt-in external-site tests skipped, 0 failures**, with warnings-as-errors; **20 offline Python acceptance tests passed**. The new real-network test confirms that the normal transport rejects the fixture certificate, the DEBUG transport accepts only its exact destination/certificate, and a different valid certificate is rejected before POST. DEBUG/release builds with warnings-as-errors, release MCP/CLI smoke, strict formatting for changed core/test Swift files and Package.swift, security static checks, shell/Python syntax and diff whitespace checks passed. All three release executables exclude the QA selector, submission configuration/status/boot paths, fixture certificate/type and synthetic values. This run adds acceptance infrastructure, not provider integration or a production installation.

Remaining gates: generic endpoint pending-edit/authentication cancellation and native interrupted-save/replacement/backup scenarios; signed-release protected-secret use and production PKI; native successful readable browser follow; real provider/checkout/GitHub workflows and in-product tests on other agent hosts. Browser-recovery cancellation evidence does not substitute for endpoint-specific checks.

Production metadata matched the pre-run SHA-256 fingerprint. The runner stopped its server, removed its isolated app/profile/preferences, and all three exact QA Keychain account lookups returned not-found (44). After recording results, removed only this run's artifacts:

| Removed directory | KiB |
| --- | ---: |
| `/private/tmp/akb-submission-acceptance.WDhOpx` — dedicated builds, modules, logs and synthetic evidence | 405,760 |
| `/private/tmp/akb-qa-AC8EC680-5316-4231-8A4D-A3AA0CAC55BA` — QA app/profile/server certificate and evidence | 14,208 |

Total freed: **419,968 KiB (approximately 410.1 MiB)**. No shared DerivedData or `.xcresult` was created or removed. Existing shared changes, production credentials and retained rollback bundles were preserved; nothing was committed, pushed or published.

## Native recovery success and abnormal-case acceptance — 2026-10-24 (unreleased)

This run uses isolated ad-hoc DEBUG apps, synthetic credentials in separate legacy Keychain services, normal native approvals/LocalAuthentication, and the exact-certificate-pinned loopback HTTPS fixture. No production vault, agent registration, installed app or system trust is changed. The installed production bundle remains local build **0.4.4**.

Completed native acceptance:

| Case | Evidence |
| --- | --- |
| MCP recovery success | Profile `E74EAE4B-C74F-4BFA-9A04-A983F78261A2`, `QA 85009bf6`: separately approved login and recovery; fixed challenge followed by the verified-page marker, constrained read and closed-session rejection. |
| CLI recovery success | Same profile: original client-session/project handles retained; the second code was reserved and submitted once, without reusing the first code. |
| Recovery refusal | Same profile, `QA 64d0712b`: exact `deny` history event, no additional reservation or POST, session closed. |
| Close while awaiting approval | Same profile, CLI: broker confirmed a pending recovery approval, then closing its browser promptly failed the request without a decision, reservation or POST. |
| Real recovery approval timeout | Profile `C4AE102B-6F2A-43D8-ADE1-30CE6C25B7F3`, `QA 23cc5661`: untouched recovery prompt reached the actual 120-second deadline and exact `timedOut` history/result; all four codes available, zero code POSTs, session closed. |
| Close during local authentication | Second profile, CLI: DEBUG phase evidence confirmed LocalAuthentication was pending; browser closure cancelled it and the waiting request, without a decision, reservation or POST. |
| Edit selected item while approval is pending | Second profile, CLI plus native editor: authenticated rename created a new payload revision and cancelled the old request immediately; destination, IDs, scope and all code statuses remained unchanged, with zero code POSTs. |
| App interrupted during recovery POST and restarted | Second profile, CLI: the server held its response after one durable reservation and one POST; QA PID `64113` was killed, then the runner started PID `66452` with the same profile. A new boot marker followed Keychain readback: `[issued, available, available, available]`. The interrupted request failed, the restarted broker responded, and the old browser handle was rejected. No second POST occurred. |

Every native case checks model-readable output/history for raw and common encoded synthetic login values, codes, cookies and private challenge/CSRF values. Server evidence logs ordinal/status/count only and establishes reservation before receipt. The first profile's two earlier timeout attempts were accidentally approved: both **failed** timeout acceptance and consumed their own next synthetic code. Their issued statuses were never reset. The second profile is a new test dataset, not a reactivation of those codes.

Automated validation: **166 Swift tests executed, 164 passed, 2 opt-in external-site tests skipped, 0 failures**; **17 offline acceptance-driver tests passed**. DEBUG/release warnings-as-errors builds, release MCP/CLI smoke, changed-Swift strict formatting, security static checks, shell/Python syntax and diff whitespace checks passed. All three release executables exclude the QA selector, certificate/config/status/authentication-phase/boot paths and synthetic recovery values.

The QA fixture now has four synthetic codes, an ordered duplicate-rejecting receipt ledger, phase-only authentication evidence and a fresh boot marker written after Keychain readback. The client supports native edit cancellation and a same-profile crash during held submission. The native cases above all passed. After restart, native Settings displayed **zero private browser sessions** and disabled End Browser Access, with no remaining prompt. The read-back also verified that native editing preserved the known code values and statuses. Cleanup is recorded below. Real-provider/GitHub compatibility, production PKI and team-signed protected-secret use remain separate release gates. Generic protected-field/card submission and backup/interrupted-save acceptance are not established by this browser flow.

Production metadata matched this run's saved SHA-256 fingerprint. Both QA runners stopped their servers and removed their profiles/preferences; all three exact Keychain account lookups in each profile returned not-found (44). Removed only this run's artifacts after recording the evidence:

| Removed directory | KiB |
| --- | ---: |
| `/private/tmp/akb-recovery-acceptance.8wHta4` — dedicated builds, modules, logs and synthetic summaries | 379,132 |
| `/private/tmp/akb-qa-E74EAE4B-C74F-4BFA-9A04-A983F78261A2` — first QA app/profile/fixture | 14,008 |
| `/private/tmp/akb-qa-C4AE102B-6F2A-43D8-ADE1-30CE6C25B7F3` — second QA app/profile/fixture | 14,016 |

Total freed: **407,156 KiB (approximately 397.6 MiB)**. No shared DerivedData or `.xcresult` was created or removed. Existing shared modifications and retained production rollback bundles were preserved; nothing was committed, pushed or published.

## Native recovery acceptance infrastructure and partial run — 2026-10-24 (unreleased)

Historical partial run; its open native recovery cases were completed by the acceptance run immediately above.

Added a repeatable isolated recovery QA path. `Scripts/run-browser-acceptance-macos.sh --recovery` creates a loopback-only HTTPS site and an ad-hoc DEBUG app with separate broker, Keychain service, metadata, preferences and history. `DevelopmentRecoveryFixture` accepts only its profile-bound high port, exact per-run certificate and seeded login. Certificate validation remains scoped to that challenge; no system trust is changed. The normal native approval and local authenticator still run. The runner stops its server and cleans only its own fixture accounts/directories on exit.

The QA app reads back its two known synthetic recovery codes from its isolated legacy Keychain and writes statuses only. The receiving server records whether the durable issued status existed before POST, plus a request count; no raw request bodies are logged. Existing fixture data is preserved on relaunch. The new `recovery-acceptance-client.py` supports MCP/CLI success, denial and real timeout, plus CLI closure while recovery approval is pending. It requires exact native history, fixed challenge output, receiving-server evidence and metadata/status invariants; transport failure, accidental approval, duplicate POST or a missing reservation cannot pass. A successful run requires a fresh fixture; refusal checks can retain an earlier issued code without resetting it.

### Automated results

- Full Swift suite: **166 executed, 164 passed, 2 opt-in external-site tests skipped, 0 failures**, with warnings-as-errors. This includes a new real-WebKit check proving the DEBUG fixture accepts its exact certificate, rejects a different valid fixture certificate, and rejects mismatched profile/invalid port configuration.
- **15 offline Python acceptance checks passed**, including strict fixed challenge content/session identity, original CLI recovery handles, reservation-before-POST, duplicate POST rejection and unchanged prior reservations during refusal.
- DEBUG and release builds with warnings-as-errors, release MCP/CLI smoke, strict formatting of changed Swift files, shell/Python syntax, security static checks and `git diff --check` passed.
- All three release executables exclude `AGENTKEYBOX_QA_ID`, recovery config/certificate/status paths, the pinned QA browser type, synthetic recovery values and the refusal domain. This increment adds test infrastructure; the installed production app remains local build **0.4.4**.

### Native evidence and incomplete gates

Used isolated profile `DB1B17B9-3442-4928-842F-DF9DEB23FCBB` with synthetic data only. The user agreed to local authentication. No production credential was read or changed.

- First MCP run (`QA 5d3c7893`) timed out at login approval. No login/code POST occurred. It failed the requested success case.
- Second run (`QA 6468093f`) showed **local authentication cancelled or failed**, with no new approval event and no login/code POST. It also failed success acceptance.
- On the user-requested retry (`QA 019b78da`), native login approval/authentication succeeded. MCP received only fixed `recoveryCodeRequired` output, and repeated read retained that fixed state with no code POST. The separate recovery prompt visibly named the original login, code set and exact local POST destination, defaulted to Deny, and explained issued-before-send/no automatic reuse.
- The recovery prompt then timed out. History recorded `timedOut` for that code set, both codes remained `available`, no recovery POST was received, and native Settings showed **zero private browser sessions** with End Browser Access disabled. The success driver correctly failed instead of treating the login approval or timeout as completed recovery.

This establishes native entry into the recovery gate and the observed timeout's zero-use state. It does **not** complete successful native recovery, the explicitly requested timeout/denial driver cases, CLI recovery, selected-item editing, authentication interruption or restart-race acceptance. The new tools make those repeatable; their unchecked release gates remain in [ROADMAP.md](ROADMAP.md) and [MACOS_TEST.md](MACOS_TEST.md#restricted-browser-recovery-continuation--isolated-native-acceptance-passed). GitHub and other provider compatibility, production PKI and team-signed Keychain secret-use verification remain separate.

Updated architecture/security/acceptance documentation and the roadmap. Existing shared changes were preserved. Production metadata was byte-identical to this increment's initial fingerprint; no production installation or agent registration was changed.

QA cleanup stopped the server, removed the isolated app/profile/preferences, and all three exact fixture-account lookups returned Keychain not-found (44). Removed this run's scratch after recording results:

| Removed directory | KiB |
| --- | ---: |
| `/private/tmp/akb-native-recovery.wQGBCU` — build products, modules and test logs | 376,256 |
| `/private/tmp/akb-qa-DB1B17B9-3442-4928-842F-DF9DEB23FCBB` — QA app, server certificate/key and synthetic evidence | 13,976 |

Total freed: approximately **381.1 MiB**. No shared DerivedData or `.xcresult` was created or removed.

## Restricted browser recovery continuation — 2026-10-24 (unreleased)

Implemented a recovery step within the existing private browser. A compatible challenge after login returns only fixed `recoveryCodeRequired` text and no website content/links. MCP `browser_recover` and CLI `akb browser recover` accept an existing browser plus stored recovery-item reference; they never accept raw codes, URLs or selectors. Discovery now advertises this use for code sets, and CLI listing includes `recoveryCodeSets`.

The recovery item's native-configured HTTPS submission destination must exactly match the discovered same-origin POST action. A new native approval identifies the website login, selected set and destination; no standing grant is offered. The app revalidates visibility and metadata/payload revisions, persists one entry as `issued` before filling/submitting it, then discards the filled view and transfers same-site cookies privately into a fresh ephemeral browser. Errors and uncertain results retain the reservation. A repeated challenge closes the session without another code attempt. Editing/deleting the selected set also invalidates a pending recovery approval.

Supported forms are intentionally narrow: traditional form-encoded POST, one writable visible text input named `recovery_code` or `recovery-code`, optional hidden fields and submit/button controls, no cross-origin/action overrides or other enabled input controls. Website JavaScript remains disabled and the landing GET must be repeatable. This does not establish GitHub compatibility, TOTP/SSO support, checkout, or transfer of login state into another agent's browser.

### Verification

- Full Swift suite with warnings-as-errors: **165 executed, 163 passed, 2 opt-in external-site tests skipped, 0 failures**. The two live tests were not enabled in this increment.
- Includes **13 real WebKit runtime tests**, five covering recovery: successful private continuation and reflection filtering; failed save/stale revision/swapped item/revocation before POST; unsupported forms; rejected/repeated/cross-origin outcomes retaining reservation; and closure during an in-flight code POST. Server markers establish reservation-before-send and exactly one code POST without retaining raw request bodies. TLS trust is confined to the test subclass and generated fixture certificate; production system trust is unchanged.
- Three recovery-policy tests cover endpoint/type binding, persisted reservation/reload/exhaustion, and the separate deny-default approval. CLI tests cover recovery argument validation, denied results, code-set listing and fixed challenge status.
- **12 offline Python acceptance-driver tests passed.** Release build with warnings-as-errors passed. Final release MCP smoke produced 11 responses with 9 expected malformed-input errors, and CLI smoke passed. The actual DEBUG selector `AGENTKEYBOX_QA_ID`, refusal domain and recovery fixture value were absent from all three release executables.
- Strict formatter checks passed for the Swift files changed in this increment, including the app browser section; security static checks, shell syntax and `git diff --check` passed.
- This increment did **not** run native approval/Touch ID + Keychain + MCP/CLI recovery end-to-end. That gate, including denial/timeout and edit/authentication/restart races for this new path, is explicitly unchecked in [ROADMAP.md](ROADMAP.md) and described in [MACOS_TEST.md](MACOS_TEST.md#restricted-browser-recovery-continuation--isolated-native-acceptance-passed). Previous endpoint-refusal and native login evidence below cannot substitute for it.

### Local installation and documentation

Installed **local bundle build 0.4.4** in `/Applications/AgentKeyBox.app` with the existing Developer ID, provisioning profile and identical Keychain entitlements. The source/release version remains 0.4.0; no release was notarized or published. Stage and installed strict signature checks passed. Original metadata remained byte-identical, the fixed-path MCP helper matched the installed bundle, and the app opened normally with its existing items. Opened the empty recovery editor, confirmed its Traditional Chinese exact-destination/approval/issued/no-retry explanation, then cancelled without saving. No production secret was accessed or new QA Keychain account created. Already-running MCP helpers require reconnection to load the new tool.

Updated PRODUCT, ARCHITECTURE, INTEGRATION, ROADMAP, MACOS_TEST, UI_DIRECTION, SECURITY, compatibility notes, both READMEs and CHANGELOG to separate implemented restricted recovery from unverified native/provider flows. Existing shared changes were preserved.

Retained `dist/local-browser-recovery/AgentKeyBox.app` and integrity-checked `dist/local-browser-recovery/AgentKeyBox-before-recovery.zip` for rollback. Removed this run's scratch `/private/tmp/akb-browser-recovery.LyJIFv` after recording results: **391,244 KiB (approximately 382.1 MiB)** of builds, module caches, logs, signing material and the redundant previous-app copy. No shared DerivedData or `.xcresult` was created or removed.

## Browser closure cancels pending navigation — 2026-10-24 (unreleased)

Fixed the app's browser-close callback to cancel the pending approval belonging to that exact browser ID, dismiss local authentication if it is still active, and release the waiting broker request. Previously the callback only removed the browser from the registry; explicit CLI close or automatic expiry could leave a matching prompt waiting until it was answered or timed out. The existing request-ID guards prevent a stale authentication/operation completion from finishing a later prompt. Other leases using the same credential are not matched by this callback.

### Native and automated evidence

- Isolated ad-hoc App + Keychain + normal local authentication + **CLI** passed public-demo login, protected-page read and close. Separate CLI calls retained the original client-session/project handles. This is a synthetic public account, not GitHub or another private account.
- A different session and a different project each failed to read, follow or close the original browser, without a new approval. Positive-control reads by the original owner still returned the protected-page marker. A link from an older read was rejected without approval.
- During a new follow request, a read probe observed the exact pending-approval response. The driver immediately closed that same browser; the pending follow failed within the ten-second gate, with no new history decision. Later reads were rejected, the global approval slot was free, metadata was byte-identical and native Settings showed **zero browser sessions**, disabled End Browser Access, and no remaining prompt. The final QA history contained one allowed login and one earlier timed-out login; cancellation did not invent an allow/deny decision.
- Two earlier manually coordinated cancellation attempts were approved instead; both failed acceptance and are not counted. A later UI-tool attachment took several minutes and its login prompt timed out; this also failed the allowed-login test. The final driver uses the broker's explicit pending response rather than assuming that a sleep or an unfinished subprocess proves a pending prompt.
- **8 actual WebKit runtime tests passed**, including a new slow-navigation cancellation test: while the HTTPS fixture is handling the GET, reads are blocked; revocation fails the in-flight call, closes the lease, prevents further reads and invokes the close callback only once. Test TLS trust remains confined to the existing test subclass pinned to its generated certificate; system trust was not changed.
- **12 offline Python acceptance tests passed**, covering the previous refusal gates plus page identity/content, exact fixture-link selection, CLI follow handle mapping and cancellation/busy false positives. DEBUG/release builds passed with warnings-as-errors; release MCP/CLI smoke checks, security static checks, changed Swift test-file formatting and `git diff --check` passed. The full Swift suite was not rerun in this increment.

The public demo has only Logout as an eligible same-origin link; it returns to a password form, which the current observation policy intentionally refuses. Earlier accidental follow approvals therefore closed the session instead of returning a page. This does **not** establish successful native readable navigation. The existing synthetic WebKit test covers successful follow. Team-signed secret use, UI edit/authentication/restart races, card/recovery allowed submission and actual checkout/GitHub recovery workflows remain open.

### Local installation

Installed **local bundle build 0.4.3** in `/Applications/AgentKeyBox.app` using the existing Developer ID, provisioning profile and identical Keychain entitlements. Source/release version remains 0.4.0; no release was notarized or published. Strict signature verification passed. The updated app opened normally, original metadata was byte-identical and the fixed-path MCP helper matched the bundle. No production secret was accessed and no active agent conversation was terminated.

Retained `dist/local-browser-lifecycle/AgentKeyBox.app` and the integrity-checked `dist/local-browser-lifecycle/AgentKeyBox-before-lifecycle-fix.zip` for rollback. Existing unrelated edits and prior local-update artifacts were preserved.

Both QA apps exited, their cleanup completed and all six exact synthetic Keychain accounts were confirmed absent (status 44). Removed these directories after recording the evidence:

| Removed directory | KiB |
| --- | ---: |
| `/private/tmp/akb-browser-lifecycle.kDeNe5` — builds, modules, logs, signing files and extra previous-app copy | 388,224 |
| `/private/tmp/akb-qa-905102BD-24A7-48D6-A8E4-1906794B8FF6` | 13,600 |
| `/private/tmp/akb-qa-8DBE64D1-F1B1-4466-A43B-502E50B945D5` | 13,600 |

Total freed: approximately **405.7 MiB**. No shared DerivedData or `.xcresult` was created or removed.

## Native refusal, timeout and pending-approval acceptance — 2026-10-24 (unreleased)

Completed the next native approval gate using isolated DEBUG App + Keychain + MCP/CLI profiles. All fixtures are synthetic: the existing public demo login, a test card, and two invented recovery codes. Card/recovery destinations use `akb-acceptance.invalid` and cannot establish successful submission or task completion. No production credential was read, edited or created.

### Results and acceptance rules

| Native scenario | Result | Evidence |
| --- | --- | --- |
| MCP card denial | Passed | `QA ada3f123`, matching `deny` event, 9.0 s |
| MCP recovery-code denial | Passed | `QA 997e86ef`, matching `deny` event, 8.7 s |
| MCP browser-login denial | Passed | `QA 638cae98`, matching `deny` event, 8.6 s |
| MCP card timeout | Passed | `QA e21ef9c3`, matching `timedOut` event and exact timeout result, 130.1 s |
| MCP recovery-code timeout | Passed | `QA cfe11271`, matching `timedOut` event and exact timeout result, 128.6 s |
| MCP browser-login timeout | Passed | `QA 26641460`, matching `timedOut` event and exact timeout result, 129.4 s |
| MCP request while another approval is pending | Passed | `QA 0e783ec3`, exact pending-approval result in about 0.16 s, no new approval event; original card prompt remained visible |
| CLI request while another approval is pending | Passed | Exit 1, empty stdout and exact pending-approval stderr in about 0.04 s |
| CLI browser-login denial | Passed | `Local agent (akb browser)`, matching `deny` event, 9.6 s |

The configured unanswered-approval deadline is **120 seconds**; observed client durations include scheduling and request overhead. Each denial/timeout required a new history event matching the caller, item and project, an error result, and byte-identical metadata before/after. Timeout additionally required at least 119 seconds and the exact native timeout message. Native Settings showed **zero private browser sessions** and disabled End Browser Access after the final run. Its history contained exactly three timeouts and the CLI denial; the busy probes added no approval.

An initial card-denial attempt and an initial card-timeout attempt were accidentally approved. Both failed their intended acceptance checks and are **not** included as passes. An initial concurrency probe also failed because the helper hid the app's pending-approval error; the implementation was corrected and the probe passed with freshly rebuilt helpers.

### Implementation and automated checks

- `BrokerError.controlledApprovalMessage` exposes only the two exact, fixed native messages for pending approval and approval timeout. Protected MCP operations and `akb browser` now preserve those outcomes. Arbitrary app/network diagnostics remain suppressed. A client/transport timeout still reports an unknown outcome because it cannot establish whether an operation ran.
- The acceptance driver now correlates new native history entries rather than accepting any error as a refusal. It checks unchanged metadata and raw/common encoded fixture-value leakage, rejects accidental approval, distinguishes native timeout from transport failure, and supports CLI refusal plus MCP concurrency probes. Seven offline harness tests are part of `Scripts/check-all.sh`.
- The DEBUG-only QA profile adds separate card/recovery fixtures. The runner removes all three exact fixture Keychain accounts when it exits. QA selectors and fixture strings were verified absent from all three release executables.
- **5 focused Swift tests and 7 Python harness tests passed**, with zero failures. DEBUG/release builds passed with warnings-as-errors. MCP/CLI smoke checks passed against final release binaries. Changed-file strict Swift formatting, security static checks, shell syntax and `git diff --check` passed. The full Swift suite was **not** rerun in this increment; earlier full-suite results below remain historical evidence.

### Installed local update and remaining scope

Installed the corrected release binaries in `/Applications/AgentKeyBox.app` using the existing Developer ID, provisioning profile and exact Keychain entitlements. The local bundle build identifier is now **0.4.2**; source/release version remains **0.4.0**. Strict signature verification passed, existing metadata stayed byte-identical, and the Application Support MCP helper matches the new bundle. Existing MCP processes must reconnect to load the new helper; no active agent conversation was terminated.

Retained `dist/local-approval-update/AgentKeyBox.app` and the integrity-checked rollback archive `dist/local-approval-update/AgentKeyBox-before-approval-fix.zip`. This is a local development update, not a notarized/published release.

This gate covers denial, native timeout and contention for the approval prompt. It does **not** establish successful card/recovery submission, recovery-code reservation/consumption after allowed submission, checkout, GitHub authentication, edit/authentication interruption or restart races. Native CLI allowed login/follow, team-signed protected-secret use, and in-product tests for other agent products remain open. The detailed acceptance commands and remaining checks are in [MACOS_TEST.md](MACOS_TEST.md).

After recording the evidence, both QA apps exited normally and their runner cleanup completed. All six exact fixture Keychain accounts across the two isolated services were confirmed absent (Keychain status 44). Removed only this increment's temporary directories:

| Removed directory | KiB |
| --- | ---: |
| `/private/tmp/akb-approval-checks.SH1qH0` — build/module caches, logs, temporary signing files and extra previous-app copy | 388,992 |
| `/private/tmp/akb-qa-3BDAF759-5907-4033-9661-9D4FC0AA9A9C` | 13,596 |
| `/private/tmp/akb-qa-04D7CF30-68E5-4F64-91A5-7480A5A24037` | 13,600 |

Total freed: approximately **406.4 MiB**. No shared DerivedData or `.xcresult` was created or removed. The staged app and rollback archive above remain available.

## Local installation and protected-item form visibility — 2026-10-24

The installed `/Applications/AgentKeyBox.app` was still the original 0.4.0 release with **Add Key**. The working tree already contained the three protected-item editors; the earlier implementation had not updated the app the user was actually opening. No additional form implementation was necessary.

- Built the current working tree for arm64 in release configuration with warnings-as-errors, then installed a local build using the existing Developer ID team, provisioning profile, bundle identifier and exact Keychain entitlements. The bundle's build identifier is **0.4.1**; the source/release version remains **0.4.0**. This is a local development update, **not** a newly notarized or published release.
- Verified the installed native interface: **新增項目 → 信用卡** exposes card number, cardholder, expiration month/year; **網站登入** exposes sign-in page, username/email and password; **復原碼** exposes paste and file import. Opened each empty sheet and cancelled it without entering or saving secrets. Also visually inspected the card sheet's layout.
- The app and both bundled helpers passed strict signature verification. MCP and CLI smoke checks passed against the installed signed helpers, and the installed MCP helper in Application Support matches the bundle. The release executables exclude the DEBUG QA profile selector.
- Existing metadata remained byte-for-byte unchanged. No production credential was read, edited or created. This UI check does not establish new credit-card checkout, recovery-code sign-in, or signed-build secret-use acceptance.
- Kept the staged app at `dist/local-update/AgentKeyBox.app` and an integrity-checked rollback archive at `dist/local-update/AgentKeyBox-0.4.0-before-input-forms.zip` (both ignored build artifacts). No remote publication or platform submission occurred.

After verification, removed the build/module caches, temporary signing files/logs and extra old-app copy under `/private/tmp/akb-input-forms.8gmWus`, freeing approximately **130.4 MiB**. No shared DerivedData or `.xcresult` was created or removed.

## Local agent entry point and native browser acceptance — 2026-10-24 (unreleased)

Implemented `akb browser list/login/read/follow/close` for local-command agents. It uses the same app-owned browser and approvals as MCP, accepts only bounded IDs/purpose/project arguments, retains no browser state in the CLI, and exports an explicit JSON result allowlist. `clientSessionID` binds independent CLI calls to the original project/session. Agent identity is the fixed `akb-browser` entry point, not a claimed authenticated vendor. Unknown MCP clients now default to `Local Agent`.

Official interfaces for dots / ChatGPT Work, Meta Muse, Grok Bot and Claude Duet were researched and recorded in `docs/AGENT_COMPATIBILITY.md` (removed on 2026-11-05; see git history), with direct sources and a per-product acceptance gate. The user confirmed they currently have only Codex and Claude Code. The four other products therefore remain **unverified in-product**. Connected-computer execution and pure-cloud execution have different requirements; no remote MCP service, public tunnel, provider submission or cloud-browser credential handoff was implemented.

### Evidence from this run

- **153 XCTest tests: 151 passed, 2 opt-in live tests skipped, zero failures**, with warnings-as-errors. This adds four CLI ownership/input/output tests and two opt-in live checks to the prior 147 tests.
- The **two live tests also passed separately**, using the production `ControlledBrowserSession` and normal system TLS: public demo login at `https://the-internet.herokuapp.com/login` → protected Secure Area → read → close; and `https://github.com/login` preflight → exact `https://github.com/session` POST action, **without credentials or submission**. The public demo advertises its synthetic account on its login page. This is not GitHub authentication, recovery-code or checkout evidence.
- Isolated **native App + Keychain + normal LocalAuthenticator + MCP** acceptance passed against that public demo: helper initialization/discovery → native approval → protected page → read → close → subsequent read rejected. The visible Traditional Chinese prompt named the actual POST destination and the 15-minute limit, and the access log recorded `allowOnce`. No authentication bypass was added. The evidence confirms the app's normal local-authentication path, not which human authentication factor was used.
- Requests intended to exercise denial were instead approved during the run. The final client recognized this as an allowed-path run and verified/closed it. Native denial/timeout was unverified at this earlier checkpoint; it was subsequently verified in the native-refusal increment above. A passed allowed-path run is not counted as a passed denial test.
- The new CLI was invoked from the current Codex task against the isolated native broker and listed only its single public fixture login. Full CLI request construction/owner isolation/output filtering has unit coverage; a separate native CLI login/follow run remains pending. The MCP acceptance driver is a test client, not a newly configured Claude Code or Codex MCP session.
- MCP/CLI smoke tests, security static checks, shell syntax, Python syntax and `git diff --check` passed. Strict Swift format lint passed for the changed implementation/test files except `Localization.swift`, where the pre-existing `L` helper triggers two `AlwaysUseLowerCamelCase` diagnostics; those unrelated names were preserved.
- An arm64 release build passed with warnings-as-errors. All three release executables were checked to exclude `AGENTKEYBOX_QA_ID` and the native QA seed fixture. This is **not** a new notarized universal release or an installed-app update.

### Native QA support and Keychain fix

`Scripts/run-browser-acceptance-macos.sh` builds or accepts matching DEBUG binaries, refuses a release/mixed helper set, creates a separate bundle/preferences domain, broker/token/metadata/history directory and Keychain service, and seeds only the public demonstration login. It skips automatic integration installation and login-item changes. Both the native app and helpers select the same UUID profile; an invalid QA ID fails instead of falling back to the production vault. The profile selector is compiled out of release builds.

This exposed an ad-hoc Keychain capability bug: a query for an absent item could look usable while the subsequent write failed with `-34018` (missing entitlement). The capability check now verifies the running app's signed `keychain-access-groups` entitlement before selecting data-protection storage. The existing legacy fallback was successfully exercised by the isolated app. Team-signed/data-protection release behavior still needs release validation.

The final runner's startup, isolated broker readiness, termination cleanup, directory deletion and exact Keychain-item absence were verified. An earlier runner was edited while its shell was waiting and emitted a shell-read error during exit; its cleanup trap completed. The final saved script passed syntax and a fresh start/terminate/cleanup run.

No production vault, installed app, agent registration, login item, certificate trust or remote service was changed. Remaining work includes native denial/timeout/concurrent edit cases, actual GitHub authentication/recovery codes, card checkout, and release/in-product compatibility acceptance.

Cleanup completed after recording the evidence above (sizes measured before deletion):

| Removed directory | KiB |
| --- | ---: |
| `/private/tmp/akb-agents.sQJiwO` — SwiftPM debug/release products, module caches and test logs | 375,680 |
| `/private/tmp/akb-qa-396388D3-92F0-4926-BD6A-0B4E8900413E` | 13,564 |
| `/private/tmp/akb-qa-C648ABFF-E9BA-4BF6-BFD2-0D0EF7A02357` | 13,564 |
| `/private/tmp/akb-qa-9EBC885F-29EB-4021-9FD5-D06E110B3A00` | 13,596 |
| `/private/tmp/akb-qa-6EDF37FA-1230-492C-9DEE-80F58AD03566` | 13,592 |

Total: approximately **419.9 MiB**. All four exact QA Keychain service/account pairs were confirmed absent afterwards. No shared DerivedData directory or `.xcresult` was created or removed by this run.

## Controlled browser increment implemented on 2026-10-23 (unreleased)

The next local browser slice is now implemented in the working tree. It preserves the exclusion of provider-side OAuth/GitHub/payment-management services.

- Added protected `login` payloads, a native English/Traditional Chinese Website login editor, optional public `loginURL` metadata, and `.login.json` files in format-2 encrypted backups. Login values cannot use generic HTTP, commands, environment/temp-file delivery, or protected-field submission.
- Added an app-owned offscreen WKWebView with website JavaScript disabled, strict same-origin HTTPS navigation, a single traditional username/password POST form, native approval/authentication, and revision checks. The filled view/history/storage is discarded before observation resumes; only same-site cookies move internally to a fresh non-persistent browser.
- Added MCP `browser_login`, `browser_read`, `browser_follow`, and `browser_close`. Results contain constrained text and opaque links, with login/cookie reflection redaction. No raw DOM, arbitrary scripts/selectors/URLs, form editing, screenshots, cookies or storage are exported. Every follow has a separate native approval.
- Added helper-session/agent/project binding, four-session capacity, a 15-minute lifetime, Settings/menu-bar End Browser Access, and invalidation when the login is edited/deleted. Native termination cancels the browser and any pending browser prompt.
- Production TLS retains system trust. A test-only subclass accepts only the ephemeral fixture's pinned leaf certificate; no trust bypass, global certificate installation or insecure-HTTP runtime option was added.

### Verification

- **147 XCTest tests passed, zero failures**, with warnings-as-errors enabled while compiling all package products and tests. This includes the previous 135 tests plus 5 browser policy/storage/approval tests and 7 actual WebKit runtime tests in [BrowserTests.swift](../Tests/AgentKeyBoxCoreTests/BrowserTests.swift).
- The synthetic HTTPS runtime checks complete login → protected account page → same-site follow → close; submission failure; unsupported GET/cross-site/OTP forms; a real 307 cross-origin redirect whose sink received no request; reflected login/cookie values; production rejection of the self-signed test certificate; revoked/stale-payload submission; and a concurrent read/revocation during sign-in.
- Browser policy checks cover secret-free metadata and encrypted-backup round trips, developer-tool exclusion, origin/port/scheme checks, ownership/expiry, observation states, non-reopenable closure, per-use approval, and overlapping/short/truncated secret redaction.
- MCP discovery plus seven malformed protected-tool requests passed without contacting the app. CLI smoke, security static checks, changed-file strict Swift formatting and `git diff --check` passed.
- The first sandboxed attempt could compile, but could not bind a loopback socket. Tests were rerun with approved local execution outside that restriction; a diagnostic explicitly confirmed the sandbox's `PermissionError`. The fixture uses only generated synthetic credentials and certificates.

These are actual WebKit/core and MCP protocol checks, **not** a signed native UI/Touch ID + MCP end-to-end run. No real account, installed app, registration, system trust setting or third-party service was modified. Real-site compatibility, native denial/timeout/edit races, signed packaging, SSO/JavaScript/OTP, recovery-code browser use and checkout remain open. The landing page is fetched again in a fresh browser, so this increment requires a repeatable landing GET. `pageReady` is not an assertion of successful authentication.

Build/test output used `/private/tmp/agentkeybox-browser.VjrB3k`, not shared DerivedData. After the final one-time cleanup-callback adjustment, all **12 browser tests** were rerun and passed with warnings-as-errors. Cleanup completed: removed `/private/tmp/agentkeybox-browser.VjrB3k` and the five synthetic-certificate directories left by the initial sandbox-blocked fixture startup, freeing approximately **262.5 MiB**. Later fixture runs clean up their own certificates/server processes automatically. No shared DerivedData or `.xcresult` was created or removed.

The five removed fixture directory suffixes under `/private/var/folders/ys/7qypr4yj5bb5v76lb45b380w0000gp/T/akb-browser-test-` were `ECB72153-E7D9-4B5B-BD3E-1AC4654CDE0D`, `7B4C38A0-D28B-484C-ADA4-24629DE2A2DA`, `10C30FC2-087D-4167-AD9C-EF5F5F1CFD92`, `D2DD67DE-A5F2-4284-946F-00776E6C15B9`, and `6F8EB4F2-F59F-4F54-80A6-654F90F4047C`.

## Unreleased increment implemented on 2026-10-22

- `SensitivePayload.swift`: structured card number/cardholder/expiration, recovery-code sets with local status, versioned encoding, and metadata/payload revision binding. No CVV.
- `SensitiveItemView.swift`: native create/edit forms, authenticated access, paste/plain-text code import, replacement preserving matching-code history, and deliberate status correction. No raw code list or copy-to-agent action.
- `SensitiveSubmission.swift` and MCP `submit_sensitive_fields`: exact user-configured HTTPS endpoint, POST only, selected whole-field placeholders, form/JSON encoding, per-use approval, and fixed outcomes without upstream response content. No generic child process or browser insertion.
- `AgentKeyBoxApp.swift`: generic HTTP/command/temp-file/environment restrictions, approval-time snapshot check, synchronous code reservation before networking, and no automatic reissue after uncertainty. Recognized protected JSON envelopes cannot be imported or executed as ordinary credentials.
- Backup format 2 for protected types, compatibility with developer-only format 1, dedicated structured files inside the encrypted image, and restore setting non-used recovery entries to `needsReview`.
- README, product, architecture, integration, backup, UI direction, security, roadmap, and changelog updated to distinguish implementation from browser/task workflows still pending.

### Verification for this increment

On this Apple silicon Mac:

- Package build with `-Xswiftc -warnings-as-errors`: passed. The final full `swift test` also used warnings as errors while compiling the app, helper, CLI, core, and tests.
- **135 XCTest tests passed, zero failures**, including **13 new sensitive-item tests** in [SensitiveItemTests.swift](../Tests/AgentKeyBoxCoreTests/SensitiveItemTests.swift). Coverage includes typed validation, selected-field encoding, secret-free summaries, failed persistence stopping a send, unknown outcomes retaining reservation, restart/replacement/stale restore, partial-edit revision mismatch, protected-JSON recognition, backup versions, reflected/encoded response content and error details, and a real loopback redirect that was not followed.
- MCP discovery/malformed-argument smoke tests and CLI smoke test: passed. The new MCP cases reject non-string fields, URL overrides, and non-string encoding before contacting the app.
- Strict `xcrun swift-format lint` for changed Swift files: passed. Whole-repository lint still reports pre-existing findings in other files; it is not warning-free.
- Security static scan, shell syntax, and `git diff --check`: passed.
- The first sandboxed full-suite attempt failed on loopback/Unix socket and `hdiutil` permissions. The approved rerun outside that sandbox passed all tests; those environmental failures are not counted as product regressions.

Build/test commands used isolated `/private/tmp/agentkeybox-protected.T22jO1` scratch/module caches, with SwiftPM's nested sandbox disabled because it cannot start inside this tool sandbox. No shared Xcode DerivedData, installed app, agent registration, real card, real recovery code, or third-party account was changed. The separately present login/session-restoration fix in the shared working tree was preserved.

This is automated core/transport coverage, **not** a native Touch ID/GUI + MCP end-to-end run, a tested GitHub sign-in, or a completed checkout. Through-app concurrency, denial/timeout, interruption/restart, and signed-release validation remain pending. The test fixture uses synthetic values only. The endpoint must be trusted and compatible; receipt does not establish task success.

## Features previously described as future work

| Earlier wording / location | Current status | Source evidence and remaining boundary |
| --- | --- | --- |
| Allow for Session / future approval UX (`PRODUCT`, `ARCHITECTURE`, `UI_DIRECTION`) | Implemented | [ApprovalEngine.swift](../Sources/AgentKeyBoxCore/ApprovalEngine.swift): `grantSession`, `sessionApproval`, eight-hour expiry. [ApprovalPresentation.swift](../Sources/AgentKeyBoxCore/ApprovalPresentation.swift) offers the checkbox only without warnings. HTTP grants cover the same listed host, not an individual action. |
| Session/project approval management (`UI_DIRECTION`) | Session controls implemented; project-wide grants not exposed | [MainWindow.swift](../Sources/AgentKeyBoxApp/MainWindow.swift): `SettingsView`; [AgentKeyBoxApp.swift](../Sources/AgentKeyBoxApp/AgentKeyBoxApp.swift): `MenuBarContent`, `revokeSessionApprovals`. Both show active sessions and **Ask Every Time**. Enum cases for project approval do not implement a user-facing grant. |
| Menu bar (`PRODUCT`, `UI_DIRECTION`) | Implemented | `MenuBarExtra`, `MenuBarContent`: pending request, recent history, session controls, Open/Quit. No **Lock Vault** action. |
| Dedicated file credential cards (`UI_DIRECTION`) | Implemented as type-aware cards | `MainWindow.swift`: `KeyCard`; [CredentialCardText.swift](../Sources/AgentKeyBoxCore/CredentialCardText.swift): file-aware attention states; credential-type icons and bundle labels. |
| Richer provider bundles / service templates (`PRODUCT`, `ARCHITECTURE`, `UI_DIRECTION`) | Presets and App Store Connect/Supabase bundles implemented | [ProviderCatalog.swift](../Sources/AgentKeyBoxCore/ProviderCatalog.swift), [ProviderBundles.swift](../Sources/AgentKeyBoxCore/ProviderBundles.swift), [ProjectScanner.swift](../Sources/AgentKeyBoxCore/ProjectScanner.swift). Team ID and a structured Firebase project-ID/client-email editor are not implemented. Bundles do not replace file delivery. |
| Empty states and human-readable errors (`UI_DIRECTION`) | Empty states implemented; error cleanup partial | `EmptyStateView`, `ProjectDetailView`, and Settings history in `MainWindow.swift`. Some app error paths still display `localizedDescription`. |
| Auto-detect project folder (`PRODUCT`) | User-selected folder scanning and request-path resolution implemented | `ProjectScanner.scan`; MCP helper project-path resolution; [ProjectScopeResolver.swift](../Sources/AgentKeyBoxCore/ProjectScopeResolver.swift). Do not describe this as automatic discovery of any foreground IDE project. |
| Future safer HTTP/proxy path (`ARCHITECTURE`, `INTEGRATION`); provider-specific operations checked off (`ROADMAP`) | Generic HTTP broker implemented; provider-specific action policy not implemented | [HTTPRequestBroker.swift](../Sources/AgentKeyBoxCore/HTTPRequestBroker.swift), MCP `http_request`, app `handleHTTPRequest` / `executeApprovedHTTPRequest`. Unlisted hosts ask for approval; they are not an unconditional hard block. |
| Credential metadata and notes (`PRODUCT`) | Metadata implemented; notes absent | [Models.swift](../Sources/AgentKeyBoxCore/Models.swift): label, service, project, environment, kind, settings, timestamps. No notes field. |
| `.env` export (`PRODUCT`) | Encrypted-backup use case implemented; no standalone plaintext-export UI | [BackupArchive.swift](../Sources/AgentKeyBoxCore/BackupArchive.swift) writes `.env` and `env.txt` inside encrypted backups; Settings has backup export/import. These are distinct from a new plaintext export feature. |
| Signing, notarization, real-Mac launch listed as future gates (`ARCHITECTURE`) | Implemented with historical verification | [build-release-macos.sh](../Scripts/build-release-macos.sh), [notarize-release-macos.sh](../Scripts/notarize-release-macos.sh), and the 0.4.0 release checklist. Physical Intel Mac validation remains open. |
| Reference image described as not a production master (`BRAND`) | Production assets already exist | [assets/brand/README.md](../assets/brand/README.md); build script bundles `AppIcon.icns` and runtime assets. The large-size master is raster, with separate small-size SVG masters. |

## Implemented baseline

### Product and agent path

- Native SwiftUI macOS app; local Keychain and metadata storage; no hosted account/backend.
- Project/global credential organization, creation/editing/deletion, `.env` import, supported key-file import, and project-folder setup.
- Claude Code/Codex adapters and MCP `list_credentials`, `request_credential`, `http_request`, and `run_with_secret`.
- Native approval, denial, two-minute unanswered-approval timeout, and local authentication; missing-credential entry can wait up to ten minutes.
- Session grants with the boundaries listed above; no persistent project approval UI.
- Generic HTTPS execution, environment injection, protected temporary-file delivery, bounded output, and common secret redaction.
- Type-aware cards, provider metadata bundles, menu bar, English/Traditional Chinese, setup/empty states, and persistent approval history.
- `akb run` for terminal tools; it hands raw values to the child process and does not redact its terminal output.

### Storage and local hardening

- Team-signed builds with the provisioning profile use the data protection keychain and user-presence authentication. Session grants can reuse the approved context.
- Authenticated owner-only Unix socket, signed-helper/CLI peer checks in team-signed builds, freshness/replay protection, request limits, and timeouts.
- Encrypted backup export/import, independently readable recovery contents, and **Remove Keys from Files** guarded by a covering backup.
- Claude Code deny-rule setup and agent instructions. Instructions alone are not isolation; plaintext copies remain readable outside enforced guards.

### Baseline coverage (included in the full-suite rerun above)

[AgentKeyBoxCoreTests.swift](../Tests/AgentKeyBoxCoreTests/AgentKeyBoxCoreTests.swift) includes:

- `testSessionApprovalIsBoundToOperationAndDelivery`
- `testSessionApprovalForHTTPCoversTheSameListedHostOnly`
- `testUnlistedHostsAndAkbRunAreNeverSessionGranted`
- `testSessionApprovalsExpireAndCanBeRevoked`
- `testPromptOffersSessionApprovalOnlyWithoutWarnings`
- `testHTTPPolicyLetsUserDecideOnUnlistedHost`
- `testBrokerReplayGuardRejectsReplayAndExpiredRequests`
- `testApprovedCommandRunnerTemporaryFileDeliveryCleansUp`

[BackupArchiveTests.swift](../Tests/AgentKeyBoxCoreTests/BackupArchiveTests.swift) covers backup layout, coverage, import planning, snapshot freshness, and format/password validation. MCP/CLI smoke scripts and static checks are wired into `make check`.

## Previously verified on a real Mac

The 0.4.0 [release checklist](RELEASE_CHECKLIST.md) records:

- SwiftUI app, Keychain/Touch ID, and the Unix-socket broker.
- Approval prompts, denial, and opted-in session approvals.
- Developer ID signing, notarization, and installation from a quarantined download.
- The universal build's x86_64 slice under Rosetta.
- Claude Code and Codex registration, metadata listing, HTTP/command approvals, denial, and redacted output; Codex project-path resolution from its working directory.
- Agent guard behavior when agents start in the project; the checklist records the limitations of instruction-only protection.
- Encrypted backup export, Finder opening, file cleanup, and import.
- Approval timeout and its persisted history entry.

These results are historical evidence, not a fresh runtime certification.

## Remaining work and verification limits

- Typed card/recovery storage, controlled endpoint submission, traditional-form browser login and restricted recovery continuation are implemented but unreleased. Browser checkout/GitHub sign-in and signed native app + MCP end-to-end verification remain open.
- Operation/resource-specific HTTP authorization: same-host approval currently covers multiple actions.
- Search/filter and complete human-readable error handling.
- Permanent project approvals, credential notes, further provider fields, and additional agent adapters remain unimplemented backlog, not completed features.
- Provider-side credential/OAuth/payment-management connectors were removed from the selected direction on 2026-10-22. Local presets, dashboard links, and approved API calls remain.
- A physical Intel Mac run is still unverified.
- Replay rejection and `.p8` temporary-file cleanup have recorded unit coverage, but their through-app scenarios are explicitly not yet verified in the release checklist.

Use [MACOS_TEST.md](MACOS_TEST.md) when new code or unresolved runtime concerns warrant another run. This increment used only its private SwiftPM scratch directory; it generated no `.xcresult` or shared DerivedData. Cleanup completed: removed `/private/tmp/agentkeybox-protected.T22jO1` (approximately 244 MiB, including build output, module caches, and temporary test logs). Test evidence is summarized above; no shared build directories were touched.

## Product goal and current boundary

The goal is to let agents complete approved tasks without reading raw sensitive values. Generic command execution and `akb run` do not enforce that guarantee: approved processes can disclose values they receive. HTTP execution keeps secret insertion inside AgentKeyBox, but redaction is not full containment. New types must validate a controlled execution and observation boundary before being advertised as agent-ready.
