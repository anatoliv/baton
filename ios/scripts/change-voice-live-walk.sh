#!/bin/bash
# Change Voice… on the phone against a throwaway loopback gateway and a real voice server
# on a simulator the caller owns:
#
#   SIM_UDID=<udid> ios/scripts/change-voice-live-walk.sh <evidence-dir>
#
# Starts a logging pass-through to the real Kokoro (KOKORO_UPSTREAM, required: your Kokoro
# voice server's URL) and a baton-gateway built from this checkout
# (gateway/.build/debug/baton-gateway) on 127.0.0.1 with a fresh state directory and a throwaway
# token in a 0600 file, handed over by environment only. Runs ChangeVoiceLiveWalkUITests, which
# makes a two-chapter book in Heart and changes it to TO_VOICE (default am_michael), while a
# watcher records every chapter file in the app's container with its digest and voice. Then
# measures: the voices Kokoro was asked for per job, the digests before and after, and the median
# pitch of each chapter in each voice. Exit 0 PASS, 1 FAIL, 2 could not run.
set -uo pipefail
cd "$(dirname "$0")/../.."
EVIDENCE="${1:?usage: SIM_UDID=<udid> $0 <evidence-dir>}"
: "${SIM_UDID:?set SIM_UDID to a simulator this run owns}"
mkdir -p "$EVIDENCE"; EVIDENCE="$(cd "$EVIDENCE" && pwd -P)"
KOKORO_UPSTREAM="${KOKORO_UPSTREAM:?set KOKORO_UPSTREAM to your Kokoro voice server, for example http://kokoro.local:8880}"
KOKORO_PORT="${KOKORO_PORT:-18990}" GATEWAY_PORT="${GATEWAY_PORT:-18991}"
TO="${TO_VOICE:-am_michael}"
DD="${BATON_IOS_DERIVED_DATA:-/tmp/baton-dd-ios-tbx10989}"
GATEWAY_BIN="${GATEWAY_BIN:-gateway/.build/debug/baton-gateway}"
[ -x "$GATEWAY_BIN" ] || { echo "no gateway at $GATEWAY_BIN (swift build --product baton-gateway in gateway/)"; exit 2; }
WORK="$(mktemp -d -t baton-change-voice-walk)"
KOKORO_PID="" GATEWAY_PID="" WATCH_PID=""
cleanup() {
  for p in $WATCH_PID $GATEWAY_PID $KOKORO_PID; do kill "$p" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT
fail=0
verdict() { if [ "$2" = 0 ]; then echo "   PASS  $1"; else echo "   FAIL  $1"; fail=1; fi; }

echo "==> Kokoro pass-through on 127.0.0.1:$KOKORO_PORT to $KOKORO_UPSTREAM"
: > "$EVIDENCE/kokoro-requests.jsonl"
/usr/bin/python3 - "$KOKORO_PORT" "$KOKORO_UPSTREAM" "$EVIDENCE/kokoro-requests.jsonl" <<'PY' &
import hashlib, http.server, json, sys, time, urllib.request
upstream, log = sys.argv[2].rstrip("/"), sys.argv[3]
def forward(path, raw=None):
    req = urllib.request.Request(upstream + path, data=raw, method="POST" if raw is not None else "GET")
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=300) as r: return r.status, r.headers.get("Content-Type", ""), r.read()
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def answer(self, status, ctype, body):
        self.send_response(status); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self): self.answer(*forward(self.path))
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        try: asked = json.loads(raw)
        except Exception: asked = {}
        status, ctype, body = forward(self.path, raw)
        with open(log, "a") as f:
            f.write(json.dumps({"at": time.strftime("%H:%M:%S"), "path": self.path, "voice": asked.get("voice"),
                                "input": asked.get("input", "")[:60], "status": status, "bytes": len(body),
                                "sha256": hashlib.sha256(body).hexdigest()}, ensure_ascii=False) + "\n")
        self.answer(status, ctype, body)
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
KOKORO_PID=$!; disown "$KOKORO_PID"

echo "==> baton-gateway on :$GATEWAY_PORT (fresh state, throwaway token)"
TOKEN_FILE="$WORK/token"
(umask 077; openssl rand -hex 24 > "$TOKEN_FILE")
mkdir -p "$WORK/gw"
(
  export BATON_GATEWAY_TOKEN="$(cat "$TOKEN_FILE")" BATON_GATEWAY_PORT="$GATEWAY_PORT" \
    BATON_STATE_FILE="$WORK/gw/baton-state.json" BATON_TTS_KOKORO_URL="http://127.0.0.1:$KOKORO_PORT" \
    NAVIDROME_URL="http://127.0.0.1:9" NAVIDROME_USER=probe NAVIDROME_PASSWORD=probe
  exec "$GATEWAY_BIN"
) > "$WORK/gateway.log" 2>&1 &
GATEWAY_PID=$!; disown "$GATEWAY_PID"
gw() { printf 'header = "Authorization: Bearer %s"\n' "$(cat "$TOKEN_FILE")" | curl -s -m 10 -K - "http://127.0.0.1:$GATEWAY_PORT$1"; }
for _ in $(seq 1 30); do gw /v1/books | grep -q '"books"' && break; sleep 1; done
gw /v1/books | grep -q '"available":true'; verdict "the gateway makes books" $?
gw /v1/voices | grep -q "\"$TO\""; verdict "the gateway lists $TO from the real Kokoro" $?
[ "$fail" = 0 ] || { sed -n 1,20p "$WORK/gateway.log"; exit 2; }

BOOK="$EVIDENCE/book/the-lighthouse.md"
mkdir -p "$EVIDENCE/book"
cat > "$BOOK" <<'MD'
# The Lighthouse

## The Keeper

The keeper climbed the tower every evening, one hundred and twelve steps, and lit the lamp before the light went out of the sky. He had done it for thirty years. The ships passed far out on the water, and none of them knew his name.

## The Storm

That winter the storm came in from the east and did not stop for three days. The waves broke over the rocks below the tower, and the glass rattled in its frame. On the third night a small boat came round the point with its sail torn, and the keeper went down to the shore with a lantern.
MD

echo "==> Building for the simulator"
(cd ios && xcodegen generate >/dev/null) || { echo "xcodegen failed"; exit 2; }
xcodebuild build-for-testing -project ios/BatonMobile.xcodeproj -scheme BatonMobile \
  -destination "platform=iOS Simulator,id=$SIM_UDID" -derivedDataPath "$DD" > "$EVIDENCE/build.log" 2>&1 \
  || { echo "build failed: $EVIDENCE/build.log"; exit 2; }
xcrun simctl boot "$SIM_UDID" >/dev/null 2>&1 || true
# A clean start on the simulator this run owns: no book or record left from an earlier walk.
xcrun simctl uninstall "$SIM_UDID" io.tonebox.baton >/dev/null 2>&1 || true

echo "==> Watching the app's chapter files"
mkdir -p "$EVIDENCE/audio"
: > "$EVIDENCE/chapter-files.log"
(
  seen=""
  while :; do
    c="$(xcrun simctl get_app_container "$SIM_UDID" io.tonebox.baton data 2>/dev/null)"
    if [ -n "$c" ] && [ -d "$c/Library/Application Support/Baton/Clippings" ]; then
      for j in "$c/Library/Application Support/Baton/Clippings/"*.json; do
        [ -f "$j" ] || continue
        line="$(/usr/bin/python3 -c '
import json, sys, hashlib, os
j = sys.argv[1]; p = json.load(open(j))["payload"]
if p.get("chapterIndex") is None: sys.exit()
base = j[:-5]
audio = next((base + e for e in (".m4a", ".caf", ".wav") if os.path.exists(base + e)), None)
if not audio: sys.exit()
print(p["id"], p["chapterIndex"], p.get("voice"), hashlib.sha256(open(audio, "rb").read()).hexdigest(), audio)' "$j" 2>/dev/null)"
        [ -n "$line" ] || continue
        key="$(echo "$line" | awk '{print $1":"$4}')"
        case " $seen " in *" $key "*) continue ;; esac
        seen="$seen $key"
        set -- $line
        cp "${line#* * * * }" "$EVIDENCE/audio/chapter-$(( $2 + 1 ))-${3#kokoro:}-${4:0:12}.m4a" 2>/dev/null
        echo "$(date +%H:%M:%S) row=$1 chapter=$(( $2 + 1 )) voice=$3 sha256=$4" >> "$EVIDENCE/chapter-files.log"
      done
    fi
    sleep 1
  done
) &
WATCH_PID=$!; disown "$WATCH_PID"

echo "==> Walking"
# The result bundle stays outside the checkout: its simulator diagnostics include files the
# repository's credential guard refuses to have in a working tree.
RESULT="${RESULT_BUNDLE:-${TMPDIR:-/tmp}/change-voice-walk-$(date +%s).xcresult}"
echo "   result bundle: $RESULT"
TEST_RUNNER_BATON_LIVE_GATEWAY_URL="http://127.0.0.1:$GATEWAY_PORT" \
TEST_RUNNER_BATON_LIVE_GATEWAY_TOKEN="$(cat "$TOKEN_FILE")" \
TEST_RUNNER_BATON_LIVE_IMPORT_FILE="$BOOK" \
TEST_RUNNER_BATON_LIVE_TARGET_VOICE="$TO" \
xcodebuild test-without-building -project ios/BatonMobile.xcodeproj -scheme BatonMobile \
  -destination "platform=iOS Simulator,id=$SIM_UDID" -derivedDataPath "$DD" \
  -only-testing:BatonMobileUITests/ChangeVoiceLiveWalkUITests \
  -resultBundlePath "$RESULT" > "$EVIDENCE/walk.log" 2>&1
RC=$?
sleep 2
kill "$WATCH_PID" 2>/dev/null; WATCH_PID=""
xcrun xcresulttool get test-results summary --path "$RESULT" --compact 2>/dev/null \
  | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); print('   tests:', {k:d.get(k) for k in ('totalTestCount','passedTests','failedTests','skippedTests','result')})"
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$RESULT-attachments" >/dev/null 2>&1 || true
# The walk's own screenshots and step times, by name; the recording and UI snapshots stay with the bundle.
/usr/bin/python3 - "$RESULT-attachments" "$EVIDENCE" <<'PY'
import json, os, re, shutil, sys
src, dst = sys.argv[1:]
try: manifest = json.load(open(os.path.join(src, "manifest.json")))
except Exception: sys.exit()
steps = []
for test in manifest:
    for a in test.get("attachments", []):
        name, f = a.get("suggestedHumanReadableName", ""), a.get("exportedFileName", "")
        base = re.sub(r"_\d+_[0-9A-F-]{36}", "", name)
        if base[:2].isdigit() and f.endswith(".png"): shutil.copy(os.path.join(src, f), os.path.join(dst, base))
        if base.startswith("step-"): steps.append(open(os.path.join(src, f)).read().strip())
open(os.path.join(dst, "walk-steps.txt"), "w").write("\n".join(sorted(steps)) + "\n")
PY
[ "$RC" = 0 ]; verdict "the walk passed (ChangeVoiceLiveWalkUITests)" $?

echo "==> Measuring"
grep -E "^(PUT|DELETE|GET /v1/books/[0-9a-f]+/chapters)" "$WORK/gateway.log" | sed -E 's/ Baton\/[0-9]+$//' > "$EVIDENCE/gateway-requests.log"
grep -E "^book " "$WORK/gateway.log" > "$EVIDENCE/gateway-render.log"
cat "$EVIDENCE/gateway-requests.log" | sed 's/^/   gateway: /'
voices="$(/usr/bin/python3 -c 'import json,sys,collections; c=collections.Counter(json.loads(l)["voice"] for l in open(sys.argv[1]) if "speech" in json.loads(l)["path"]); print(dict(c))' "$EVIDENCE/kokoro-requests.jsonl")"
echo "   Kokoro was asked for: $voices"
echo "$voices" | grep -q "'af_heart'" && echo "$voices" | grep -q "'$TO'"; verdict "Kokoro made the book in af_heart, then in $TO" $?
cat "$EVIDENCE/chapter-files.log" | sed 's/^/   file: /'
for n in 1 2; do
  before="$(grep "chapter=$n voice=kokoro:af_heart" "$EVIDENCE/chapter-files.log" | head -1)"
  after="$(grep "chapter=$n voice=kokoro:$TO" "$EVIDENCE/chapter-files.log" | tail -1)"
  [ -n "$before" ] && [ -n "$after" ]; verdict "chapter $n: a file in af_heart, then one in $TO" $?
  [ "$(echo "$before" | sed 's/.*row=\([^ ]*\).*/\1/')" = "$(echo "$after" | sed 's/.*row=\([^ ]*\).*/\1/')" ]; verdict "chapter $n kept its row (clipping id)" $?
  [ "$(echo "$before" | sed 's/.*sha256=//')" != "$(echo "$after" | sed 's/.*sha256=//')" ]; verdict "chapter $n's digest changed" $?
done
pitch() {
  ffmpeg -v error -i "$1" -ac 1 -ar 8000 -f s16le - 2>/dev/null | /usr/bin/python3 -c '
import sys, struct, statistics
raw = sys.stdin.buffer.read(); n = len(raw) // 2
x = struct.unpack("<%dh" % n, raw[: n * 2])
rate, frame, hop = 8000, 320, 400
found = []
for start in range(0, n - frame - 140, hop):
    f = x[start:start + frame]
    energy = sum(v * v for v in f)
    if energy < frame * 400 ** 2: continue
    best, lag = 0, 0
    for k in range(20, 134):
        c = sum(f[i] * x[start + i + k] for i in range(frame))
        if c > best: best, lag = c, k
    if lag and best > 0.3 * energy: found.append(rate / lag)
print(round(statistics.median(found)) if found else 0)'
}
: > "$EVIDENCE/pitch.txt"
for f in "$EVIDENCE"/audio/*.m4a; do
  echo "$(basename "$f") median pitch $(pitch "$f") Hz, $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f") s" | tee -a "$EVIDENCE/pitch.txt" | sed 's/^/   /'
done
echo
[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
