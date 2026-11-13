#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 RELEASE_EXECUTABLE_DIRECTORY" >&2
  exit 2
fi

# Read bytes directly: strings(1) can miss non-ASCII or UTF-16 diagnostic literals.
python3 - "$1" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
markers = [
    "AGENTKEYBOX_QA_ID", "/private/tmp/akb-qa-", "dev.agentkeybox.qa.",
    "recovery-fixture.json", "submission-fixture.json", "PinnedRecoveryFixtureBrowser",
    "interrupt-card-save", "QA —", "AgentKeyBox QA", "Unable to open isolated preferences",
]
failed = False
for name in ("AgentKeyBox", "agentkeybox-mcp", "akb"):
    executable = root / name
    if not executable.is_file():
        print(f"FAIL: missing executable: {name}", file=sys.stderr)
        failed = True
        continue
    data = executable.read_bytes()
    hits = [marker for marker in markers if any(
        marker.encode(encoding) in data for encoding in ("utf-8", "utf-16-le", "utf-16-be"))]
    if hits:
        print(f"FAIL: {name}: QA markers: {', '.join(hits)}", file=sys.stderr)
        failed = True
    else:
        print(f"PASS: {name}: no QA markers ({len(markers)} markers, 3 encodings)")
sys.exit(1 if failed else 0)
PY
