# Contributing to AgentKeyBox

AgentKeyBox is intentionally small. Contributions should preserve the core product principle: **make the secure path simpler, not more configurable.**

## Development requirements

Core/MCP work can be developed with Swift 6 on Linux or macOS. Native UI, Keychain, LocalAuthentication, and Network.framework work requires macOS 14+.

Run before submitting a PR:

```bash
swift build -Xswiftc -warnings-as-errors
swift test
./Scripts/mcp-smoke-test.sh
./Scripts/cli-smoke-test.sh
./Scripts/security-static-check.sh
```

## Architecture rules

- Never persist raw secret values outside the approved secret store.
- Never write raw secrets to logs, diagnostics, analytics, or test snapshots.
- Keep cloud services out of the MVP.
- Agent-specific logic belongs behind the adapter/MCP boundary.
- New persistent approval modes must be scoped narrowly enough that a different command cannot silently reuse a prior grant.
- Prefer Apple/system security APIs over custom cryptography.
- Use synthetic secrets in tests.

## Pull requests

Keep PRs focused. Explain:

1. the user problem
2. the behavior change
3. security implications
4. test coverage
5. macOS-specific verification still required, if any

Security vulnerabilities should follow `SECURITY.md`, not public issues.
