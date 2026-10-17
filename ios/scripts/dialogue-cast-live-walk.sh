#!/bin/bash
# Voice the dialogue on the phone against a throwaway loopback gateway and a real voice server
# (TBX-11141), on a simulator the caller owns:
#
#   SIM_UDID=<udid> KOKORO_UPSTREAM=http://<kokoro>:8880 ios/scripts/dialogue-cast-live-walk.sh <evidence-dir>
#
# Starts a logging pass-through to the real Kokoro, a stand-in chat model on 127.0.0.1 (the
# gateway's own model, `BATON_LLM_*`, which the phone reaches through `/v1/books/complete`: it
# writes the cast list and places the two lines without a speech tag), and a baton-gateway built
# from this checkout with a fresh state directory and a throwaway token in a 0600 file. Runs
# DialogueCastLiveWalkUITests: a book imported with Voice the dialogue on, made with its cast,
# then Change Voice… with the cast turned off. A watcher keeps every book the gateway was sent.
# Then checks: the first book carries the cast (each quote with its speaker), Kokoro was asked for
# the characters' voices, and the book made again has one narrator. Exit 0 PASS, 1 FAIL, 2 could
# not run.
set -uo pipefail
cd "$(dirname "$0")/../.."
EVIDENCE="${1:?usage: SIM_UDID=<udid> $0 <evidence-dir>}"
: "${SIM_UDID:?set SIM_UDID to a simulator this run owns}"
mkdir -p "$EVIDENCE"; EVIDENCE="$(cd "$EVIDENCE" && pwd -P)"
KOKORO_UPSTREAM="${KOKORO_UPSTREAM:?set KOKORO_UPSTREAM to your Kokoro voice server, for example http://kokoro.local:8880}"
KOKORO_PORT="${KOKORO_PORT:-18993}" GATEWAY_PORT="${GATEWAY_PORT:-18994}" MODEL_PORT="${MODEL_PORT:-18995}"
DD="${BATON_IOS_DERIVED_DATA:-/tmp/baton-dd-ios-tbx11141}"
GATEWAY_BIN="${GATEWAY_BIN:-gateway/.build/debug/baton-gateway}"
[ -x "$GATEWAY_BIN" ] || { echo "no gateway at $GATEWAY_BIN (swift build --product baton-gateway in gateway/)"; exit 2; }
for port in "$KOKORO_PORT" "$GATEWAY_PORT" "$MODEL_PORT"; do
  lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && { echo "port $port is taken"; exit 2; }
done
WORK="$(mktemp -d -t baton-dialogue-cast-walk)"
KOKORO_PID="" GATEWAY_PID="" MODEL_PID="" WATCH_PID=""
cleanup() {
  for p in $WATCH_PID $GATEWAY_PID $MODEL_PID $KOKORO_PID; do kill "$p" 2>/dev/null; done
  rm -rf "${WORK:?}"
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

echo "==> a stand-in chat model on 127.0.0.1:$MODEL_PORT, the gateway's own model"
: > "$EVIDENCE/model-requests.jsonl"
/usr/bin/python3 - "$MODEL_PORT" "$EVIDENCE/model-requests.jsonl" <<'PY' &
# A stand-in for a chat model: the cast list for the probe's book, and who speaks each quote it
# is asked about, by what the quote says. Anything else (a narrator suggestion, pronunciations)
# gets an empty object, which the app reads as "nothing to add".
import http.server, json, re, sys, time
log = sys.argv[2]
SHEET = {"characters": [
    {"name": "Vashti", "gender": "f", "age": "old", "aliases": ["his mother"]},
    {"name": "Kuno", "gender": "m", "age": "young", "aliases": ["her son"]}]}
WHO = [("can see you", "Vashti"), ("not through the Machine", "Kuno")]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        text = "\n".join(m.get("content", "") for m in body.get("messages", []) if isinstance(m.get("content"), str))
        if "You prepare the cast list" in text:
            kind, reply = "cast list", json.dumps(SHEET)
        elif "You attribute quoted dialogue" in text:
            asked = [i.strip() for i in text.rsplit("ASK: ", 1)[-1].split(",")]
            quotes = dict(re.findall(r"\[Q ([^\]]+)\](.*?)\[/Q\]", text, re.S))
            out = {}
            for i in asked:
                for phrase, name in WHO:
                    if phrase in quotes.get(i, ""): out[i] = name
            kind, reply = "placing", json.dumps(out)
        else:
            kind, reply = "other", "{}"
        with open(log, "a") as f:
            f.write(json.dumps({"at": time.strftime("%H:%M:%S"), "kind": kind, "model": body.get("model"), "reply": reply}) + "\n")
        data = json.dumps({"choices": [{"message": {"role": "assistant", "content": reply}, "finish_reason": "stop"}],
                           "model": body.get("model")}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
MODEL_PID=$!; disown "$MODEL_PID"

echo "==> baton-gateway on :$GATEWAY_PORT (fresh state, throwaway token)"
TOKEN_FILE="$WORK/token"
(umask 077; openssl rand -hex 24 > "$TOKEN_FILE")
mkdir -p "$WORK/gw"
(
  export BATON_GATEWAY_TOKEN="$(cat "$TOKEN_FILE")" BATON_GATEWAY_PORT="$GATEWAY_PORT" \
    BATON_STATE_FILE="$WORK/gw/baton-state.json" BATON_TTS_KOKORO_URL="http://127.0.0.1:$KOKORO_PORT" \
    BATON_LLM_PROVIDER=openai-compatible BATON_LLM_BASE_URL="http://127.0.0.1:$MODEL_PORT" BATON_LLM_MODEL=stand-in \
    NAVIDROME_URL="http://127.0.0.1:9" NAVIDROME_USER=probe NAVIDROME_PASSWORD=probe
  exec "$GATEWAY_BIN"
) > "$WORK/gateway.log" 2>&1 &
GATEWAY_PID=$!; disown "$GATEWAY_PID"
gw() { printf 'header = "Authorization: Bearer %s"\n' "$(cat "$TOKEN_FILE")" | curl -s -m 10 -K - "http://127.0.0.1:$GATEWAY_PORT$1"; }
for _ in $(seq 1 30); do gw /v1/books | grep -q '"books"' && break; sleep 1; done
gw /v1/books | grep -q '"available":true'; verdict "the gateway makes books" $?
gw /v1/voices | grep -q '"bf_emma"'; verdict "the gateway lists the real Kokoro's voices" $?
[ "$fail" = 0 ] || { sed -n 1,20p "$WORK/gateway.log"; exit 2; }

BOOK="$EVIDENCE/book/the-machine.md"
mkdir -p "$EVIDENCE/book"
cat > "$BOOK" <<'MD'
# The Machine

## The Air-Ship

Vashti sat in her room, and the bell rang twice. She touched a switch, and the plate lit up.

“Who is it?” said Vashti.

“It is Kuno,” said her son. “I want you to come and see me.”

“But I can see you!”

“I want to see you not through the Machine.”

## The Mending Apparatus

Kuno called again that night, and his face was grey.

“I have been out on the surface,” said Kuno.

“You should not have gone,” said Vashti, and the plate went dark.
MD

echo "==> Building for the simulator"
(cd ios && xcodegen generate >/dev/null) || { echo "xcodegen failed"; exit 2; }
xcodebuild build-for-testing -project ios/BatonMobile.xcodeproj -scheme BatonMobile \
  -destination "platform=iOS Simulator,id=$SIM_UDID" -derivedDataPath "$DD" > "$EVIDENCE/build.log" 2>&1 \
  || { echo "build failed: $EVIDENCE/build.log"; exit 2; }
xcrun simctl boot "$SIM_UDID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$SIM_UDID" io.tonebox.baton >/dev/null 2>&1 || true

echo "==> Keeping every book the gateway is sent"
mkdir -p "$EVIDENCE/jobs"
(
  while :; do
    for id in $(gw /v1/books | /usr/bin/python3 -c 'import json,sys; [print(b["id"]) for b in json.load(sys.stdin).get("books", [])]' 2>/dev/null); do
      [ -s "$EVIDENCE/jobs/$id.json" ] || gw "/v1/books/$id/book" > "$EVIDENCE/jobs/$id.json"
    done
    sleep 1
  done
) &
WATCH_PID=$!; disown "$WATCH_PID"

echo "==> Walking"
RESULT="${RESULT_BUNDLE:-${TMPDIR:-/tmp}/dialogue-cast-walk-$(date +%s).xcresult}"
echo "   result bundle: $RESULT"
TEST_RUNNER_BATON_LIVE_GATEWAY_URL="http://127.0.0.1:$GATEWAY_PORT" \
TEST_RUNNER_BATON_LIVE_GATEWAY_TOKEN="$(cat "$TOKEN_FILE")" \
TEST_RUNNER_BATON_LIVE_IMPORT_FILE="$BOOK" \
xcodebuild test-without-building -project ios/BatonMobile.xcodeproj -scheme BatonMobile \
  -destination "platform=iOS Simulator,id=$SIM_UDID" -derivedDataPath "$DD" \
  -only-testing:BatonMobileUITests/DialogueCastLiveWalkUITests \
  -resultBundlePath "$RESULT" > "$EVIDENCE/walk.log" 2>&1
RC=$?
sleep 2
kill "$WATCH_PID" 2>/dev/null; WATCH_PID=""
xcrun xcresulttool get test-results summary --path "$RESULT" --compact 2>/dev/null \
  | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); print('   tests:', {k:d.get(k) for k in ('totalTestCount','passedTests','failedTests','skippedTests','result')})"
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$RESULT-attachments" >/dev/null 2>&1 || true
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
[ "$RC" = 0 ]; verdict "the walk passed (DialogueCastLiveWalkUITests)" $?

echo "==> Checking"
grep -E "^(PUT|DELETE|POST /v1/books/complete)" "$WORK/gateway.log" | sed -E 's/ Baton\/[0-9]+$//' > "$EVIDENCE/gateway-requests.log"
sed 's/^/   gateway: /' "$EVIDENCE/gateway-requests.log"
sed 's/^/   model: /' "$EVIDENCE/model-requests.jsonl" | cut -c1-160
/usr/bin/python3 - "$EVIDENCE/jobs" > "$EVIDENCE/jobs.txt" <<'PY'
import json, os, sys
for f in sorted(os.listdir(sys.argv[1]), key=lambda f: os.path.getmtime(os.path.join(sys.argv[1], f))):
    try: b = json.load(open(os.path.join(sys.argv[1], f)))
    except Exception: continue
    chars = ",".join(f"{k}={v}" for k, v in sorted(b["voices"].get("characters", {}).items())) or "-"
    quotes = ",".join(s.get("speaker") or "narrator" for c in b["chapters"] for s in c["segments"] if s["kind"] == "quote")
    print(f[:12], b["voices"]["narrator"], chars, quotes)
PY
sed 's/^/   job: /' "$EVIDENCE/jobs.txt"
FIRST="$(head -1 "$EVIDENCE/jobs.txt")" LAST="$(tail -1 "$EVIDENCE/jobs.txt")"
[ "$(wc -l < "$EVIDENCE/jobs.txt" | tr -d ' ')" = 2 ]; verdict "two books were sent: with the cast, then made again" $?
echo "$FIRST" | awk '{print $3}' | grep -q "Kuno=kokoro:" && echo "$FIRST" | awk '{print $3}' | grep -q "Vashti=kokoro:"
verdict "the first book carries its cast to the gateway" $?
[ "$(echo "$FIRST" | awk '{print $4}')" = "Vashti,Kuno,Kuno,Vashti,Kuno,Kuno,Vashti" ]
verdict "each quote has its speaker: tags by the rules, the two untagged placed by the gateway's model" $?
grep -q '"kind": "cast list"' "$EVIDENCE/model-requests.jsonl" && grep -q '"kind": "placing"' "$EVIDENCE/model-requests.jsonl"
verdict "the phone's cast list and placing went to the gateway's model" $?
for spec in $(echo "$FIRST" | awk '{print $3}' | tr ',' '\n' | cut -d= -f2 | sed 's/^kokoro://'); do
  n="$(grep -c "\"voice\": \"$spec\"" "$EVIDENCE/kokoro-requests.jsonl")"
  [ "$n" -gt 0 ]; verdict "the gateway asked Kokoro for the character voice $spec ($n requests)" $?
done
voices="$(/usr/bin/python3 -c 'import json,sys,collections; c=collections.Counter(json.loads(l)["voice"] for l in open(sys.argv[1]) if "speech" in json.loads(l)["path"]); print(dict(c))' "$EVIDENCE/kokoro-requests.jsonl")"
echo "   Kokoro was asked for: $voices"
[ "$(echo "$LAST" | awk '{print $3}')" = "-" ]; verdict "the book made again has no cast" $?
[ "$(echo "$LAST" | awk '{print $2}')" = "$(echo "$FIRST" | awk '{print $2}')" ]; verdict "and the same narrator" $?
echo
[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
