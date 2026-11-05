#!/usr/bin/env bash
# Isolated native QA: public login plus synthetic refusal fixtures, no production vault/config.
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || exit 1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RECOVERY_FIXTURE=false
SUBMISSION_FIXTURE=false
if [[ "${1:-}" == --recovery ]]; then
  RECOVERY_FIXTURE=true
  shift
fi
if [[ "${1:-}" == --submission ]]; then
  SUBMISSION_FIXTURE=true
  shift
fi
[[ "$#" -eq 0 && !( "$RECOVERY_FIXTURE" == true && "$SUBMISSION_FIXTURE" == true ) ]] || {
  echo "Usage: $0 [--recovery | --submission]" >&2; exit 2;
}
QA_ID="$(uuidgen)"
QA_ROOT="/private/tmp/akb-qa-$QA_ID"
mkdir -m 700 "$QA_ROOT"
APP_PID=""
FIXTURE_PID=""
cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  if [[ -n "$FIXTURE_PID" ]] && kill -0 "$FIXTURE_PID" 2>/dev/null; then
    kill "$FIXTURE_PID" 2>/dev/null || true
    wait "$FIXTURE_PID" 2>/dev/null || true
  fi
  # The ad-hoc QA app uses the legacy keychain. Match this run's exact service AND accounts.
  # Keep this byte derivation aligned with DevelopmentProfile.fixtureID.
  while IFS= read -r account; do
    security delete-generic-password -s "dev.agentkeybox.qa.$QA_ID" -a "$account" >/dev/null 2>&1 || true
  done < <(/usr/bin/python3 - "$QA_ID" <<'PY'
import sys, uuid
profile = uuid.UUID(sys.argv[1])
for offset in range(4):
    data = bytearray(profile.bytes)
    data[-1] ^= offset
    print(str(uuid.UUID(bytes=bytes(data))).upper())
PY
  )
  defaults delete "dev.agentkeybox.qa.$QA_ID" >/dev/null 2>&1 || true
  local size
  size="$(du -sk "$QA_ROOT" | awk '{print $1}')"
  rm -rf "$QA_ROOT"
  echo "Removed $QA_ROOT ($size KiB)." >&2
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if [[ "$RECOVERY_FIXTURE" == true || "$SUBMISSION_FIXTURE" == true ]]; then
  # One-day fixture certificate, scoped to a pinned challenge in the DEBUG QA app.
  # Never install this certificate in a Keychain or alter system trust.
  cat > "$QA_ROOT/openssl.cnf" <<'CONFIG'
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=127.0.0.1
[v3]
subjectAltName=IP:127.0.0.1
basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage=serverAuth
CONFIG
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config "$QA_ROOT/openssl.cnf" \
    -keyout "$QA_ROOT/fixture-key.pem" -out "$QA_ROOT/fixture-cert.pem" > /dev/null 2>&1
  /usr/bin/openssl x509 -in "$QA_ROOT/fixture-cert.pem" -outform der -out "$QA_ROOT/fixture-cert.der"
  if [[ "$SUBMISSION_FIXTURE" == true ]]; then
    /usr/bin/python3 -u Tests/AgentKeyBoxCoreTests/Fixtures/submission_fixture.py \
      "$QA_ROOT/fixture-cert.pem" "$QA_ROOT/fixture-key.pem" "$QA_ROOT" \
      > "$QA_ROOT/fixture-port" 2> "$QA_ROOT/fixture-error.log" &
  else
    /usr/bin/python3 -u Tests/AgentKeyBoxCoreTests/Fixtures/browser_fixture.py \
      "$QA_ROOT/fixture-cert.pem" "$QA_ROOT/fixture-key.pem" "$QA_ROOT/server-event" \
      "$QA_ROOT/recovery-statuses.json" > "$QA_ROOT/fixture-port" 2> "$QA_ROOT/fixture-error.log" &
  fi
  FIXTURE_PID=$!
  /usr/bin/python3 - "$QA_ROOT" "$QA_ID" "$SUBMISSION_FIXTURE" <<'PY'
import json, pathlib, sys, time
root = pathlib.Path(sys.argv[1])
deadline = time.monotonic() + 10
while True:
    raw = (root / "fixture-port").read_text().strip() if (root / "fixture-port").exists() else ""
    if raw.isdigit():
        port = int(raw)
        assert 1024 <= port <= 65535
        name = "submission-fixture.json" if sys.argv[3] == "true" else "recovery-fixture.json"
        (root / name).write_text(json.dumps({"profileID": sys.argv[2], "port": port}))
        break
    if time.monotonic() >= deadline:
        raise SystemExit("Local HTTPS fixture failed to start")
    time.sleep(0.05)
PY
fi

if [[ -n "${AGENTKEYBOX_BIN_DIR:-}" ]]; then
  BIN_DIR="$AGENTKEYBOX_BIN_DIR"
else
  export CLANG_MODULE_CACHE_PATH="$QA_ROOT/modules"
  export SWIFTPM_MODULECACHE_OVERRIDE="$QA_ROOT/modules"
  swift build --disable-sandbox --scratch-path "$QA_ROOT/build" -Xswiftc -warnings-as-errors
  BIN_DIR="$(swift build --disable-sandbox --scratch-path "$QA_ROOT/build" --show-bin-path)"
fi
# Refuse a release binary: it ignores the QA profile and would open the real vault.
for product in AgentKeyBox agentkeybox-mcp akb; do
  strings "$BIN_DIR/$product" | grep -F 'Invalid AgentKeyBox QA profile ID' >/dev/null || {
    echo "Every QA executable must be a DEBUG build with profile support: $product" >&2
    exit 1
  }
done
strings "$BIN_DIR/AgentKeyBox" | grep -F 'Could not initialize isolated AgentKeyBox QA fixture' >/dev/null || {
  echo "A DEBUG build with QA profile support is required." >&2
  exit 1
}
APP="$QA_ROOT/AgentKeyBox QA.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers"
cp "$BIN_DIR/AgentKeyBox" "$APP/Contents/MacOS/AgentKeyBox"
cp "$BIN_DIR/agentkeybox-mcp" "$BIN_DIR/akb" "$APP/Contents/Helpers/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AgentKeyBox</string>
<key>CFBundleIdentifier</key><string>dev.agentkeybox.qa.$QA_ID</string>
<key>CFBundleName</key><string>AgentKeyBox QA</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
export AGENTKEYBOX_QA_ID="$QA_ID"
echo "QA profile: $QA_ID"
if [[ "$SUBMISSION_FIXTURE" == true ]]; then
  echo "Local HTTPS protected-field fixture; synthetic card/codes only. No payment is performed."
  echo "Client: python3 -B Scripts/submission-acceptance-client.py $QA_ID"
elif [[ "$RECOVERY_FIXTURE" == true ]]; then
  echo "Local HTTPS recovery fixture; synthetic values only. Certificate pin is DEBUG/profile scoped."
  echo "Client: python3 -B Scripts/recovery-acceptance-client.py $QA_ID"
else
  echo "Public demo item: $QA_ID"
  echo "Synthetic card and recovery-code fixtures are for denial/timeout only (.invalid destinations)."
fi
echo "Helper: $APP/Contents/Helpers/agentkeybox-mcp"
echo "CLI: $APP/Contents/Helpers/akb"
echo "In another terminal, set AGENTKEYBOX_QA_ID=$QA_ID before using either helper."
echo "Quit AgentKeyBox QA when finished; this script deletes this run's data and Keychain item."
echo "This is an ad-hoc QA build, not signed-release acceptance."
while true; do
  "$APP/Contents/MacOS/AgentKeyBox" &
  APP_PID=$!
  echo "$APP_PID" > "$QA_ROOT/app-pid"
  echo "QA app PID: $APP_PID"
  app_status=0
  wait "$APP_PID" || app_status=$?
  APP_PID=""
  if [[ ( "$RECOVERY_FIXTURE" == true || "$SUBMISSION_FIXTURE" == true ) && -f "$QA_ROOT/restart-on-exit" ]]; then
    rm "$QA_ROOT/restart-on-exit"
    echo "Restarting the same isolated QA profile after the requested lifecycle test (exit $app_status)."
    continue
  fi
  break
done
