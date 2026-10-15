# Changelog

## 0.4.0 — alpha

First release meant for people to download: a notarized, universal app with a project-centric window, plain-language approvals, provider bundles, English and Traditional Chinese, and connections that survive moving or updating the app.

### Added

- AgentKeyBox no longer has to be open. When it is not running, the MCP helper and `akb run` open it in the background (menu bar only, no window) and retry, instead of failing with "AgentKeyBox is not running". It also opens at login: turned on the first time it runs from Applications, and both can be switched off in Settings › Startup. `akb doctor` never opens the app.
- The release app is universal: it runs natively on Apple silicon and Intel Macs. `build-release-macos.sh` builds each architecture and merges them with `lipo` (`AGENTKEYBOX_ARCHS=arm64` builds one for quicker local packaging).
- README section on connecting other local MCP agents by hand (untested: Gemini CLI, Copilot in VS Code, Cursor, Windsurf, Cline, Muse Code), and why cloud agents such as OpenAI Dots cannot connect.
- README install, update, and uninstall guide for people downloading the app (macOS 14+), and a Traditional Chinese README (`README.zh-TW.md`) for users. Agent connection examples now use the helper's fixed path.
- Coding agents stay connected wherever the app lives. Agents now run a copy of the MCP helper at a fixed path (`~/Library/Application Support/AgentKeyBox/bin/agentkeybox-mcp`), refreshed from the app on every launch; a connected agent that still points elsewhere is re-registered automatically. Previously the connection broke when the app was moved, or when it was opened straight from Downloads (macOS runs it from a temporary translocated copy).
- When AgentKeyBox runs from outside Applications, a banner offers Move to Applications: it copies the app there (replacing an older copy, which goes to the Trash), clears the quarantine flag on the copy, and reopens it.
- English and Traditional Chinese throughout: windows, approval prompts, the Touch ID reason, the menu bar, and `akb` output. Settings › Language offers Same as macOS (the default; Traditional Chinese for zh-Hant/TW/HK/MO), English, or 繁體中文, and switches immediately. Messages for coding agents (MCP tool text) and `akb doctor --json` stay English. A test fails if any interface string lacks a translation or loses a placeholder.
- Remove a project: right-click it in the sidebar and choose Remove Project… (or Show in Finder). Its keys are deleted from the Keychain after a confirmation; files in the project folder are not changed.
- Provider bundles: a key and the non-secret values it is used with show as one card. An App Store Connect `.p8` key carries its Key ID (from `AuthKey_<ID>.p8`) and Issuer ID; a Supabase key carries its project URL and anon key. Setup and `.env` import attach these from the project's files under any common name (`NEXT_PUBLIC_SUPABASE_URL`, `APP_STORE_CONNECT_ISSUER_ID`, …) instead of listing them as separate entries. A card missing a required value says so ("Needs the Issuer ID") with a one-click fix; the editor checks the format and links to where the value is shown. `list_credentials` returns the settings, and `run_with_secret` and `akb run` set them as environment variables next to the key.
- "Don't ask again during this session": an approval can cover identical requests for the rest of the coding-agent session (one session ID per MCP helper process), reusing that Touch ID authentication. Scope is narrow — the same listed host for `http_request`, the exact same command for `run_with_secret`; never for unlisted hosts, flagged requests, or `akb run` — and grants expire after 8 hours. The menu bar and Settings show active sessions with an "Ask Every Time" button.
- Project-centric main window: the sidebar lists projects and Global keys; each project shows its keys as cards with "Used by Claude Code · 2 min ago" and only flags keys that need attention (e.g. "Can be sent to any website" with a one-click fix). Agent status moves to the sidebar footer; connections, Keychain mode, and recent access move to Settings (⌘,).
- Three-field key editor (name, project, paste a new key) with the variable name and allowed websites under Advanced; a simpler Add Key sheet that fills everything from the chosen service.
- Approval history persists across launches (metadata only, owner-only file, last 500 events) so cards can show when a key was last used.
- Dropping a file on the window stores it in the selected project in one step.
- One-step project setup: drop a project folder on the window (or choose it) and AgentKeyBox finds `.env*` files, `.p8`/`.pem` private keys, and service-account JSON (skipping templates, dependencies, and build output), preselects the real secrets, offers to add unignored `.env` files to `.gitignore`, and connects installed coding agents — one Set Up click. First-time setup drops from about 10 actions to 2.
- Plain-language approval prompt: one-sentence headline, purpose and destination only, technical details collapsed; warnings lead and make Deny the default.
- A request to a host outside a key's list now asks the user (with a warning and Deny as default) instead of failing, and can remember the host for that key.
- The app ships the brand icon: `AppIcon.icns` rendered onto Apple's icon grid from the brand masters, credential-type glyphs in the sidebar, the branded request glyph in approval prompts, AgentKey Blue as the accent color, and a menu bar item (template icon) showing pending requests and recent access.
- `http_request` MCP tool: AgentKeyBox performs one approved HTTPS request with the credential placed in a header via `{{secret}}`. Enforces https, per-credential allowed hosts (prefilled from provider presets), header-only placement, no redirects, a timeout, and a redacted, size-limited response.
- `akb run [--only …] -- <command>`: one Touch ID approval, then the command runs in your terminal with the project's secrets in its environment — a drop-in replacement for `.env` files for dev servers.
- `request_credential` MCP tool: when a credential is missing, the user enters it in an AgentKeyBox prompt (with a link to the provider's dashboard) instead of pasting it into chat; the agent receives only the new credential ID.
- Credentials record their environment variable name and allowed hosts; `list_credentials` returns both.

### Security

- Text an agent supplies can no longer pass for AgentKeyBox's own: its stated purpose is labeled "Agent's reason" and quoted, and both the purpose and the agent's name are flattened to one line (control characters and line breaks removed) and shortened, in the prompt, the Touch ID reason, window titles, the menu bar, and history.
- Encrypted backups: Settings › Backup exports every project and key to a password-protected `.dmg` (AES-256 encrypted disk image; at least 12-character password; Touch ID before export) and imports it on another Mac, keeping keys that already exist. The backup opens without AgentKeyBox: double-click it, enter the password, and Finder opens a disk with a folder per project holding its `.env` (plus a visible copy, `env.txt`) and key files. The image is filled while mounted privately and the finished backup is a compressed read-only copy made from the encrypted device, so the keys are never written unencrypted. Password fields have a show/hide button. Format: `docs/BACKUP_FORMAT.md`.
- Remove Keys from Files: after a backup that covers a project, its `.env` keys are emptied (with a comment pointing to `akb run`) and its key files moved to the Trash, so no agent can read the plaintext. Only values identical to the stored keys are touched; a name that also appears with any other value is left alone, since emptying it would erase that value too. Differences and unwritable files are reported. A backup counts for the keys as they were when it read them, so keys added or edited while it was being written are not treated as backed up. If a key is moved or changed while the export reads the values, the export stops and asks to try again, so a backup never pairs a key's old project with its new value.
- Setup keeps coding agents away from the `.env` and key files it leaves on disk as the user's backup (on by default): Claude Code `Read` deny rules in `.claude/settings.local.json` (at the git root, where Claude Code loads them; templates such as `.env.example` stay readable) and a marked section in `AGENTS.md` and `CLAUDE.md` telling agents to use AgentKeyBox and never read or ask for keys. Existing settings and text are kept; a broken settings file is left untouched. The README now says the Keychain copy is device-only, so keep a backup.
- The broker now checks who is calling. A coding agent with a shell could read the broker token and send requests itself, including a fake `akb run` that returns raw secrets after a convincing prompt. Team-signed builds read the caller's audit token and accept only AgentKeyBox's own signed helper and `akb`; only `akb` may make `akb run` requests. The broker moved from Network.framework to BSD sockets to get the caller's identity, and compares tokens in constant time.
- Commands under `akb run` that print the environment (`printenv`, `env`) are flagged high risk, since their output reaches the caller unredacted.
- More commands that can run other code are flagged: `arch`, `timeout`, `nice`, `xcrun`, `watch`, `script`, and similar launchers; `find -exec`; `awk` and other interpreters; `git` (hooks).
- Redaction also catches the Base64 of a key followed by a newline, as produced by `printenv KEY | base64`.
- Output or a response cut off at AgentKeyBox's size limit can no longer leak the start of a key: redacting earlier copies shortened the text and pulled a cut-off copy at the end into view. Any trailing fragment that begins an encoded form of the key is removed, including when the cut falls inside a multi-byte character of the key.
- `akb run` parses its options strictly: `--only` without names, an unknown option, or a repeated `--only` is an error instead of passing every key. `--only=A,B` works, and without `--` the value is no longer taken as the command.
- Editing a key saves its project and settings before the new value, and puts them back if the value cannot be saved, so a failed save cannot leave a new key readable by the project it was moving away from.
- Every decision check in the MCP helper and `akb` now asks whether access was allowed, so any decision that does not allow access fails closed.
- `dist/bin` now holds the signed helper and `akb`, so they are accepted by a signed broker.

### Fixed

- Approval prompts that nobody answers are recorded in the access history as "Timed out" (orange), instead of leaving no trace.
- `.gitignore` checks follow Git: `*` no longer matches `/`, so `/*.env` is not mistaken for covering `apps/api/.env` and the setup warning is shown.
- Global keys stay visible and editable after the last project is removed.
- Codex shows as connected only when its AgentKeyBox entry is enabled and runs the AgentKeyBox helper; Claude Code only when its command is the helper.
- The access history label for `akb run` is translated.
- Importing a backup that is still open in Finder says so ("Eject the AgentKeyBox Backup disk, then try again") instead of reporting a wrong password.
- A failed import no longer removes a project that was already here with the same ID as one in the backup.
- The agent guard no longer lifts a deny rule the user already had: a template (such as `.env.example`) that any of the user's rules could cover at any depth, like `Read(config/.env.example)`, `Read(.env.*)` or `Read(secrets/**)`, stays denied, and a negation from an earlier setup is removed when a later user rule conflicts with it. AgentKeyBox records which rules it wrote (in its own folder, `guard-rules.json`), so rules the user wrote, even ones identical to AgentKeyBox's, are never treated as its own, and an exception the user removed is not added back by a later setup.
- Approved-command output is captured through a bounded pipe and redacted before truncation (no unbounded temp file, no leaked secret prefix at the size limit).
- Secrets cannot be injected into reserved variables (PATH, HOME, DYLD_*, LD_*, NODE_OPTIONS, …); variable names must be ASCII.
- The risk warning recognizes versioned interpreters, bun/deno, launchers such as env/xargs, package runners that execute project scripts, and executables inside the project.
- `.env` import lets the user choose entries (likely secrets preselected) and updates existing credentials instead of duplicating them.
- A corrupt metadata file is moved aside instead of being overwritten by the next save.
- Approval and credential prompts appear in their own floating panel, so they still show when the main window is closed.
- Approval prompts show one argument per line with control and bidi characters escaped, and scroll instead of pushing the buttons off-screen.
- Simulation buttons are compiled into debug builds only.
- Fixed two Swift 6 compile errors that prevented the macOS broker client/server from building.
- Moved the local broker from TCP port 49321 (bound on all interfaces) to an owner-only Unix-domain socket; removed the bypassable string-based loopback check.
- The MCP helper now fails immediately with "AgentKeyBox is not running" instead of waiting for the full timeout.
- The approval timeout no longer fires after the user approves, so a slow approved command is no longer reported as an approval timeout after it already ran.
- Concurrent broker requests can no longer both claim the single approval slot and leak a pending continuation.
- `.env` and key-file imports now ask which project the credentials belong to instead of using the first project.
- Raised the broker client timeout to cover the approval wait plus command execution.
- Added Unix-socket broker round-trip, auth, and app-not-running tests.
- Approval confirmation now uses Touch ID with login-password fallback. The biometrics-only policy reported "not enrolled" on a real Mac with Touch ID set up, so approvals were silently granted on a single click.
- The app now finds agent CLIs installed outside the minimal Finder PATH (e.g. `~/.npm-global/bin`) by consulting the login-shell PATH and common install locations, and passes that PATH to agent CLI child processes. "Connect Claude Code" previously reported "Not installed" when launched from Finder.
- Agent CLI lookup now searches directories in a deterministic order.
- A Touch ID / password prompt is now dismissed when its approval times out, instead of staying on screen with nothing behind it.
- Team-signed builds store secrets in the data protection keychain with user presence required, and reuse the approval's Touch ID authentication to read them: one approval now costs one prompt instead of Touch ID followed by repeated keychain password dialogs. Legacy-keychain items are migrated on first read; unsigned development builds keep using the legacy keychain.
- Removed the "Require Touch ID" toggle; every approval now requires Touch ID or the login password.
- `Scripts/build-release-macos.sh` can embed a provisioning profile and sign with keychain entitlements (`AGENTKEYBOX_PROVISIONING_PROFILE`), and signs helpers separately instead of using `--deep`.

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
