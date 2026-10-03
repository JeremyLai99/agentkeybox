#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Formatting/lint"
if command -v swift-format >/dev/null 2>&1; then
  swift-format lint --recursive Sources Tests Package.swift
else
  echo "warning: swift-format not installed; skipping formatter lint" >&2
fi

echo "==> Build (warnings as errors)"
swift build -Xswiftc -warnings-as-errors

echo "==> Unit tests"
swift test

echo "==> MCP smoke test"
./Scripts/mcp-smoke-test.sh

echo "==> CLI smoke test"
./Scripts/cli-smoke-test.sh

echo "==> Security static checks"
./Scripts/security-static-check.sh

echo "==> Shell syntax"
for script in Scripts/*.sh Examples/demo-project/*.sh; do
  bash -n "$script"
done

echo "All AgentKeyBox checks passed."
