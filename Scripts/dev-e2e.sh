#!/bin/bash
# Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE). Derived from SelfControl.
# End-to-end test over real XPC, with no root and no changes to /etc.
# Runs holdfastd in --dev-root mode as a per-user launchd agent and drives it with holdfast-cli.
set -u
cd "$(dirname "$0")/.."

BIN=".build/debug"
swift build >/dev/null || { echo "build failed"; exit 1; }

ROOT="$(mktemp -d /tmp/sc-e2e.XXXXXX)"
LABEL="dev.holdfast.e2e.$$"
PLIST="$ROOT/$LABEL.plist"
UIDN="$(id -u)"
PASS=0; FAIL=0

check() { # name, command...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "  ok   $name"; PASS=$((PASS+1)); else echo "  FAIL $name"; FAIL=$((FAIL+1)); fi
}
cli() { "$BIN/holdfast-cli" --dev-service "$LABEL" --dev-state "$ROOT/support/state.json" "$@"; }

cleanup() {
  launchctl bootout "gui/$UIDN/$LABEL" >/dev/null 2>&1
  pkill -f "$ROOT/FakeGame.app" >/dev/null 2>&1
  rm -rf "$ROOT"
}
trap cleanup EXIT

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$PWD/$BIN/holdfastd</string><string>--dev-root</string><string>$ROOT</string><string>--service</string><string>$LABEL</string>
  </array>
  <key>MachServices</key><dict><key>$LABEL</key><true/></dict>
  <key>StandardOutPath</key><string>$ROOT/daemon.log</string>
  <key>StandardErrorPath</key><string>$ROOT/daemon.log</string>
</dict></plist>
EOF
launchctl bootstrap "gui/$UIDN" "$PLIST" || { echo "couldn't bootstrap agent"; exit 1; }

# A fake app so we can watch app-blocking kill a real process.
APP="$ROOT/FakeGame.app"
mkdir -p "$APP/Contents/MacOS"
# Must be a freshly built binary: macOS kills copied platform binaries (e.g. /bin/sleep) on its own.
printf '#include <unistd.h>\nint main(void){ sleep(600); return 0; }\n' > "$ROOT/fake.c"
cc -o "$APP/Contents/MacOS/FakeGame" "$ROOT/fake.c" || { echo "cc failed"; exit 1; }
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.holdfast.fakegame</string>
  <key>CFBundleName</key><string>FakeGame</string>
  <key>CFBundleExecutable</key><string>FakeGame</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
EOF

echo "== Block 1: sites over XPC =="
check "no block initially"            bash -c "$BIN/holdfast-cli --dev-state $ROOT/support/state.json status | grep -q 'No block'"
check "start 1-minute block"          cli start --duration 1m --site example.com --site '*:8443'
check "state file written by daemon"  grep -q example.com "$ROOT/support/state.json"
check "hosts block present"           grep -q "BEGIN HOLDFAST BLOCK" "$ROOT/etc/hosts"
check "hosts blocks example.com"      grep -q "0.0.0.0.example.com" "$ROOT/etc/hosts"
check "pf anchor written"             grep -q "block return out proto tcp" "$ROOT/etc/pf.anchors/dev.holdfast"
check "pf anchor has port rule"       grep -q "to any port 8443" "$ROOT/etc/pf.anchors/dev.holdfast"
check "pfctl was invoked"             grep -q "pfctl -E" "$ROOT/commands.log"
check "second start is rejected"      bash -c "! $BIN/holdfast-cli --dev-service $LABEL start --duration 5m --site x.com"
check "status shows running"          bash -c "$BIN/holdfast-cli --dev-state $ROOT/support/state.json status | grep -q 'Block running'"
check "add a site while running"      cli add --site added.test
check "added site is in hosts"        grep -q "added.test" "$ROOT/etc/hosts"
check "can't shorten via extend 0"    bash -c "! $BIN/holdfast-cli --dev-service $LABEL --dev-state $ROOT/support/state.json extend 0m"

echo "== Tamper: user edits hosts mid-block =="
cp /dev/null "$ROOT/etc/hosts.tmp"; echo "127.0.0.1 localhost" > "$ROOT/etc/hosts"
sleep 3
check "daemon restored hosts block"   grep -q "BEGIN HOLDFAST BLOCK" "$ROOT/etc/hosts"

echo "== Block 1 expiry (waiting ~65s for the 1-minute block) =="
sleep 66
check "block ended"                   bash -c "$BIN/holdfast-cli --dev-state $ROOT/support/state.json status | grep -q 'No block'"
check "hosts cleaned"                 bash -c "! grep -q 'HOLDFAST' $ROOT/etc/hosts"
check "history recorded"              bash -c "$BIN/holdfast-cli --dev-state $ROOT/support/state.json history | grep -q 'Manual'"

echo "== Block 2: app blocking kills a running process =="
"$APP/Contents/MacOS/FakeGame" &
GAMEPID=$!
sleep 2
check "fake app is running before any block" kill -0 $GAMEPID
check "still running with no block active" kill -0 $GAMEPID
check "start app-only block"          cli start --duration 1m --app "$APP"
sleep 4
check "app was killed by the daemon"  bash -c "! kill -0 $GAMEPID 2>/dev/null"
check "app-only block left hosts alone" bash -c "! grep -q HOLDFAST $ROOT/etc/hosts"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ] || { echo "--- daemon log ---"; cat "$ROOT/daemon.log"; echo "--- state ---"; cat "$ROOT/support/state.json"; echo "--- procs ---"; ps -axo pid,command | grep -i FakeGame | grep -v grep; exit 1; }
