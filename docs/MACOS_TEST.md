# macOS End-to-End Test

This is the remaining validation that cannot be completed in a non-macOS execution environment.

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
- Touch ID (or the password prompt on Macs without Touch ID) appears for every approval
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

## 9. Release packaging

```bash
./Scripts/build-release-macos.sh
```

Confirm:

- `dist/AgentKeyBox.app` launches
- embedded `Contents/Helpers/agentkeybox-mcp` is executable
- embedded `Contents/Helpers/akb` is executable
- release ZIP exists
- SHA-256 file matches

## 10. Before public binary release

Replace ad-hoc signing with a real Developer ID identity and notarize the ZIP/app. Complete `docs/RELEASE_CHECKLIST.md`.
