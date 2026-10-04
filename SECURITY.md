# Security Policy

AgentKeyBox is experimental security-adjacent software. It has **not** undergone an independent security audit and should not yet be treated as a hardened production secrets platform.

## Reporting a vulnerability

Please do not open a public GitHub issue for a vulnerability that could expose credentials.

Until a dedicated security inbox is established, contact the repository owner privately through the GitHub account that publishes this repository and include:

- affected version / commit
- reproduction steps
- expected and observed behavior
- impact
- any proof-of-concept that does not expose third-party secrets

A dedicated security contact should be added before the first public binary release.

## Current security boundaries

AgentKeyBox aims to reduce accidental leakage by keeping secret values in macOS Keychain and requiring explicit local approval before an agent-triggered command can use them.

The current prototype includes:

- Keychain-backed secret storage; team-signed builds use the data protection keychain with Touch ID / password (user presence) required for every read
- owner-only local metadata/token files where supported
- authenticated broker on an owner-only Unix-domain socket
- request freshness and replay rejection
- project-scoped credential visibility
- approval timeout
- command execution timeout with best-effort termination / direct-child kill escalation
- output-size limits
- common direct secret-representation redaction
- optional Touch ID / login-password confirmation for every approval
- protected temporary-file delivery for file credentials

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

## Secrets in issues and logs

Never attach real API keys, private keys, `.p8` files, service-account JSON, or production `.env` files to an issue. Use synthetic credentials in reproductions.
