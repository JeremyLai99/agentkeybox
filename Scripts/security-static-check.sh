#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# High-confidence credential prefixes should never appear in production source.
PATTERN='(sk_live_[A-Za-z0-9]{12,}|sk-proj-[A-Za-z0-9_-]{12,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)'
if grep -RIE --exclude-dir=.build --exclude-dir=Tests --exclude-dir=Examples --exclude='*.md' "$PATTERN" Sources Scripts Package.swift Makefile .github 2>/dev/null; then
  echo "Potential hard-coded secret detected in production source." >&2
  exit 1
fi

# Guardrails against common accidental persistence/logging mistakes.
if grep -RIE --exclude-dir=.build 'UserDefaults.*secret|print\([^)]*secret|NSLog\([^)]*secret' Sources 2>/dev/null; then
  echo "Potential unsafe secret logging or persistence pattern detected." >&2
  exit 1
fi

echo "Security static checks passed."
