# Alpha Release Checklist

## Automated

- [ ] `make check`
- [ ] GitHub macOS CI passes
- [ ] packaged `.app` artifact launches

## macOS runtime

- [ ] Keychain save/read/delete works
- [ ] Touch ID / password confirmation appears for every approval
- [ ] broker binds and responds locally
- [ ] stale/replayed broker request is rejected
- [ ] `.env` import works
- [ ] `.p8` temp-file delivery cleans up after execution
- [ ] denial returns a clean error to the agent
- [ ] approval timeout returns a clean error
- [ ] high-risk command warning renders correctly

## Claude Code

- [ ] `akb connect claude` succeeds
- [ ] `claude mcp get agentkeybox` shows the expected command
- [ ] `list_credentials` sees only expected project/global metadata
- [ ] `run_with_secret` triggers native approval
- [ ] Deny blocks execution
- [ ] Allow executes and returns redacted output

## Codex

- [ ] `akb connect codex` succeeds
- [ ] `codex mcp get agentkeybox --json` shows the expected command
- [ ] current project path resolves correctly
- [ ] `list_credentials` sees only expected project/global metadata
- [ ] `run_with_secret` triggers native approval
- [ ] Deny blocks execution
- [ ] Allow executes and returns redacted output

## Release hygiene

- [ ] version updated in MCP and Info.plist
- [ ] CHANGELOG updated
- [ ] dedicated security contact configured
- [ ] binaries signed with Developer ID
- [ ] Developer ID provisioning profile embedded; app reports the data protection keychain mode
- [ ] `AGENTKEYBOX_NOTARY_PROFILE=... ./Scripts/notarize-release-macos.sh` passes
- [ ] SHA-256 checksum published
- [ ] README security disclaimer still matches implementation
