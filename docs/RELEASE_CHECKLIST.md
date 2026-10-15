# Alpha Release Checklist

Status for **0.4.0**, with the evidence for each checked item. Unchecked items are still open.

## Automated

- [x] `make check` — 122 tests, MCP and CLI smoke tests, static checks (2026-10-15)
- [x] strict build: `-strict-concurrency=complete`, warnings as errors (2026-10-15)
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
- [x] approval timeout returns a clean error — `akb run` left unanswered for 2 minutes printed `Approval timed out.`, exited 1, and the access log recorded `timedOut` (2026-10-15); Claude Code received the same message
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

Verified 2026-10-15 with Codex 0.160 (the CLI bundled with the ChatGPT app) in the same test project:

- [x] Codex connection succeeds — set up from the project setup sheet's Connect Codex option (same adapter as `akb connect codex`)
- [x] `codex mcp get agentkeybox --json` shows the fixed helper path
- [x] current project path resolves correctly — the access log records `~/Desktop/akb-e2e-test`
- [x] `list_credentials` sees only expected project/global metadata
- [x] `http_request` triggers native approval and returns the response (Stripe 401)
- [x] `run_with_secret` triggers native approval, with the orange warning for `/usr/bin/python3`
- [x] Deny blocks execution — `Credential access was denied.`
- [x] Allow executes and returns redacted output — `[REDACTED_BY_AGENTKEYBOX]`

Note: `codex exec` cannot be used for this test, because Codex requires approving MCP tool calls and exec mode cannot ask. Codex 0.149 could not use the account's default model; use a current Codex.

## Agent guard

Verified 2026-10-15 in the test project, set up with the guard option on:

- [x] setup writes `.claude/settings.local.json` Read deny rules and the marked section in `AGENTS.md` and `CLAUDE.md`
- [x] Claude Code, asked for the `.env` value or the `.p8` contents without mentioning AgentKeyBox, declines and uses AgentKeyBox instead
- [x] Codex, started in the project folder, declines both and cites `AGENTS.md`

Note: for Codex the guard is advice in `AGENTS.md`, not enforcement. Started in another folder, Codex did not load it and read both files once the user named the path. Removing keys from files (below) is what actually protects them.

## Encrypted backup

Verified 2026-10-15 on a real Mac:

- [x] export writes an owner-only (600) encrypted `.dmg`; the key text does not appear in the file
- [x] double-clicking it and entering the password opens a Finder window with a folder per project, its `.env`, `env.txt`, and key files
- [x] Remove Keys from Files empties the `.env` value (with a comment pointing to `akb run`) and moves the `.p8` to the Trash
- [x] after Remove Project, Import restores the project and its keys with the same IDs, without duplicating other projects; the restored key worked (Stripe 401 for the fake key)

## Release hygiene

- [x] version updated in `VERSION` and `Sources/AgentKeyBoxCore/AgentKeyBoxVersion.swift` (a test checks they match)
- [x] CHANGELOG updated
- [x] dedicated security contact configured — GitHub private vulnerability reporting is enabled; SECURITY.md points to it
- [x] binaries signed with Developer ID — `Developer ID Application: HUANG-CHENG LAI (8UY9UJ99HY)`
- [x] Developer ID provisioning profile embedded; app reports the data protection keychain mode
- [x] `AGENTKEYBOX_NOTARY_PROFILE=... ./Scripts/notarize-release-macos.sh` passes — Accepted, stapled, `spctl`: Notarized Developer ID
- [x] SHA-256 checksum published with the release — `AgentKeyBox-0.4.0-macOS.zip.sha256` on the v0.4.0 release (dc9683fd…4aa0); a downloaded copy matches
- [x] README security disclaimer still matches implementation
