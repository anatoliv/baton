#!/bin/bash
# The phone's book walk against the real home server, on a simulator (M5.2, M5.3):
#
#   GATEWAY_URL=http://<host>:8788 ios/scripts/books-live-walk.sh ~/Downloads/Machine_stops.pdf <evidence-dir>
#
# Builds the app for the iPhone simulator, stages the PDF beside the evidence, relays the
# gateway through 127.0.0.1 (local network privacy does not apply to loopback), and runs
# DocumentImportLiveWalkUITests with the gateway and the file handed over in the runner's
# environment (TEST_RUNNER_…, never argv). The gateway token is read from the login Keychain
# item `baton-gateway-token` and travels only through process environments. The test deletes
# the book it made from the home server. Exit 0 PASS, 1 FAIL, 2 could not run.
set -uo pipefail
cd "$(dirname "$0")/../.."
BOOK="${1:?usage: $0 <book.pdf> <evidence-dir>}"
EVIDENCE="${2:?evidence dir}"
: "${GATEWAY_URL:?set GATEWAY_URL to the gateway (http://host:8788)}"
SIM="${SIM:-iPhone 18 Pro}"
DD="${BATON_IOS_DERIVED_DATA:-/tmp/baton-dd-ios-walk}"
RELAY_PORT="${RELAY_PORT:-18789}"
mkdir -p "$EVIDENCE"; EVIDENCE="$(cd "$EVIDENCE" && pwd -P)"
RELAY_PID=""
cleanup() { [ -n "$RELAY_PID" ] && kill "$RELAY_PID" 2>/dev/null; }
trap cleanup EXIT

/usr/bin/python3 - "$RELAY_PORT" "$GATEWAY_URL" <<'PY' &
import asyncio, sys, urllib.parse
port, upstream = int(sys.argv[1]), urllib.parse.urlparse(sys.argv[2])
async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data); await writer.drain()
    except Exception: pass
    finally: writer.close()
async def handle(cr, cw):
    try: ur, uw = await asyncio.open_connection(upstream.hostname, upstream.port or 80)
    except Exception: cw.close(); return
    await asyncio.gather(pipe(cr, uw), pipe(ur, cw))
async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", port)
    async with server: await server.serve_forever()
asyncio.run(main())
PY
RELAY_PID=$!
sleep 0.5
curl -s -m 5 -o /dev/null "http://127.0.0.1:$RELAY_PORT/health" || { echo "the relay does not reach $GATEWAY_URL"; exit 2; }

echo "==> Building for the simulator ($SIM)"
(cd ios && xcodegen generate >/dev/null) || { echo "xcodegen failed"; exit 2; }
xcodebuild build-for-testing -project ios/BatonMobile.xcodeproj -scheme BatonMobile \
  -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath "$DD" > "$EVIDENCE/build.log" 2>&1 \
  || { echo "build failed: $EVIDENCE/build.log"; exit 2; }
APP="$(ls -d "$DD"/Build/Products/Debug-iphonesimulator/Baton.app | head -1)"
xcrun simctl boot "$SIM" >/dev/null 2>&1 || true
# The book is staged on the host, not in the app's container: the test runner reinstalls the
# app with a fresh data container, which took the first staged copy with it. A simulator app
# reads host paths, and the import copies the file into its own sandbox anyway.
mkdir -p "$EVIDENCE/book"
cp "$BOOK" "$EVIDENCE/book/$(basename "$BOOK")" || exit 2
STAGED="$EVIDENCE/book/$(basename "$BOOK")"

echo "==> Walking"
TOKEN="$(security find-generic-password -s baton-gateway-token -a baton -w 2>/dev/null)" || { echo "no gateway token in the Keychain"; exit 2; }
TEST_RUNNER_BATON_LIVE_GATEWAY_URL="http://127.0.0.1:$RELAY_PORT" \
TEST_RUNNER_BATON_LIVE_GATEWAY_TOKEN="$TOKEN" \
TEST_RUNNER_BATON_LIVE_IMPORT_FILE="$STAGED" \
xcodebuild test-without-building -project ios/BatonMobile.xcodeproj -scheme BatonMobile \
  -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath "$DD" \
  -only-testing:BatonMobileUITests/DocumentImportLiveWalkUITests \
  -resultBundlePath "$EVIDENCE/walk.xcresult" > "$EVIDENCE/walk.log" 2>&1
RC=$?
unset TOKEN
xcrun xcresulttool get test-results summary --path "$EVIDENCE/walk.xcresult" --compact 2>/dev/null \
  | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); print('  tests:', {k:d.get(k) for k in ('totalTestCount','passedTests','failedTests','skippedTests','result')})"
xcrun xcresulttool export attachments --path "$EVIDENCE/walk.xcresult" --output-path "$EVIDENCE/attachments" >/dev/null 2>&1 || true
[ "$RC" = 0 ] && echo "PASS (home server, simulator)" || echo "FAIL: $EVIDENCE/walk.log"
exit "$RC"
