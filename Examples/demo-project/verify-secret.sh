#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${DEMO_API_KEY:-}" ]]; then
  echo "DEMO_API_KEY is missing" >&2
  exit 2
fi
echo "Credential is available to the approved process."
