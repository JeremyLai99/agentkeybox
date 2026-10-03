# Changelog

## 0.3.0 — pre-alpha

- Hardened reusable approval identity with exact executable/argument binding.
- Added best-effort SIGKILL escalation for timed-out direct child commands.
- Added `make check` / `Scripts/check-all.sh` and implementation-status documentation.

- Added Claude Code + Codex stdio MCP integration.
- Added local authenticated broker and native approval flow.
- Kept raw secrets inside the AgentKeyBox app process during approved command execution.
- Added request timestamp/replay protection and broker size limits.
- Added process timeout, minimal inherited environment, output truncation, and expanded direct-value redaction.
- Added protected temporary-file secret delivery for `.p8`, `.pem`, and JSON workflows.
- Added project-scope path resolution and provider presets.
- Added optional Touch ID confirmation when available.
- Added `akb doctor`, `akb connect`, macOS install/package scripts, CI, and static security checks.
- Expanded core test suite.
