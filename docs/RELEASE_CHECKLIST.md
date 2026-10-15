# Alpha Release Checklist

Status for **0.4.0**, with the evidence for each checked item. Unchecked items are still open.

## Automated

- [x] `make check` — 75 tests, MCP and CLI smoke tests, static checks (2026-10-14)
- [x] GitHub macOS CI passes — including the universal `AgentKeyBox-0.4.0-macOS.zip` package
- [x] packaged `.app` artifact launches — notarized build opened from a quarantined copy in Downloads

## macOS runtime

- [x] Keychain save/read/delete works — project setup saves, approvals read, Remove Project deletes without Keychain errors
- [x] Touch ID / password confirmation appears for every approval — one `evaluatePolicy` per approval in the system log; requests covered by an opted-in session approval skip it by design
- [x] broker binds and responds locally — `akb doctor` reports the broker, on Apple silicon and under Rosetta
- [x] stale/replayed broker request is rejected — `testBrokerReplayGuardRejectsReplayAndExpiredRequests` (unit test, not yet through the app)
- [x] `.env` import works — one-step project setup on a real Mac
- [x] `.p8` temp-file delivery cleans up after execution — `testApprovedCommandRunnerTemporaryFileDeliveryCleansUp` (unit test, not yet through the app)
- [x] denial returns a clean error to the agent — `Credential access was denied.`
- [ ] approval timeout returns a clean error
- [x] high-risk command warning renders correctly in the app — orange warning with Deny as default for `/usr/bin/python3` from Claude Code, confirmed by the user

## Install and update

- [x] a downloaded copy runs translocated, offers Move to Applications, and reopens from `/Applications` without quarantine
- [x] the MCP helper is installed at `~/Library/Application Support/AgentKeyBox/bin/agentkeybox-mcp` and matches the app's copy
- [x] a connected agent that points at an old helper path is re-registered at launch — Claude Code's `~/.claude.json` changed from a `dist/` path to the fixed path within seconds of launch, env vars kept
- [x] universal binary: the x86_64 app runs under Rosetta and its broker and helper answer
- [ ] universal binary on a real Intel Mac
- [x] interface in Traditional Chinese on a Traditional Chinese Mac; English when forced
- [x] switching Settings › Language updates the open windows — checked by the user on a real Mac

## Claude Code

Verified 2026-10-15 with Claude Code 2.1.273 in a test project with a fake Stripe key:

- [x] `akb connect claude` succeeds — registers the fixed helper path
- [x] `claude mcp get agentkeybox` shows the fixed helper path — `✔ Connected`
- [x] `list_credentials` sees only expected project/global metadata
- [x] `http_request` triggers native approval and returns the response (Stripe 401 for the fake key); asked to "check the balance", Claude Code picked `http_request` on its own
- [x] `run_with_secret` triggers native approval
- [x] Deny blocks execution — the agent gets `Credential access was denied.` and the command does not run
- [x] Allow executes and returns redacted output — `printenv` returned `[REDACTED_BY_AGENTKEYBOX]`
- [x] one Touch ID evaluation per approval (3 approvals, 3 evaluations in the system log)

Note: in auto mode, Claude Code's own classifier refuses requests that would print a key or use it for an unrelated command, before they reach AgentKeyBox. Testing AgentKeyBox's warning needs auto mode off.

## Codex

- [ ] `akb connect codex` succeeds
- [ ] `codex mcp get agentkeybox --json` shows the fixed helper path
- [ ] current project path resolves correctly
- [ ] `list_credentials` sees only expected project/global metadata
- [ ] `run_with_secret` triggers native approval
- [ ] Deny blocks execution
- [ ] Allow executes and returns redacted output

## Release hygiene

- [x] version updated in `VERSION` and `Sources/AgentKeyBoxCore/AgentKeyBoxVersion.swift` (a test checks they match)
- [x] CHANGELOG updated
- [x] dedicated security contact configured — GitHub private vulnerability reporting is enabled; SECURITY.md points to it
- [x] binaries signed with Developer ID — `Developer ID Application: HUANG-CHENG LAI (8UY9UJ99HY)`
- [x] Developer ID provisioning profile embedded; app reports the data protection keychain mode
- [x] `AGENTKEYBOX_NOTARY_PROFILE=... ./Scripts/notarize-release-macos.sh` passes — Accepted, stapled, `spctl`: Notarized Developer ID
- [ ] SHA-256 checksum published with the release
- [x] README security disclaimer still matches implementation
