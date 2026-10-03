#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "AgentKeyBox's native UI requires macOS." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build
BIN_DIR="$(swift build --show-bin-path)"

echo "Starting AgentKeyBox from: $BIN_DIR/AgentKeyBox"
exec "$BIN_DIR/AgentKeyBox"
