#!/bin/bash
# Pronunciations for a book made on the home server (TBX-10964) against a throwaway gateway, on
# a probe instance, never the owner's Baton and never the real home server:
#
#   scripts/probe-pronunciations-home-server.sh <Baton.app> <evidence-dir>
#
#   A. a baton-gateway built from this checkout (gateway/.build/debug/baton-gateway; run
#      `swift build --product baton-gateway` in gateway/ first) starts on 127.0.0.1 with its own
#      state directory, a throwaway token and a stand-in Kokoro that answers silent WAVs, logs
#      every text it is sent, and takes a few seconds over a text with a pronunciation in it
#   B. the probe makes a two-chapter book there from its import sheet (Vashti in chapter 1,
#      Kuno in chapter 2); both chapters come down
#   C. relaunched, Pronunciations… opens for that book (DEBUG BATON_DEBUG_OPEN_PRONUNCIATIONS,
#      in place of the row's context menu); Kuno is added in IPA and saved
#   D. the book goes to the gateway again under a new id with the corrected lexicon, the old
#      job is deleted there, Kokoro is sent "[Kuno](/kˈuːnO/)" and nothing from chapter 1,
#      the row says chapter 2 is being made, and only chapter 2 comes down again
#
# Two switches, for a pre-ship check on the real voice server (TBX-10976):
#
#   KOKORO_UPSTREAM=http://<host>:8880   the local Kokoro becomes a pass-through to that real
#                                        Kokoro: the texts are logged the same way, the audio is the
#                                        real one, and kokoro-requests.jsonl in the evidence directory
#                                        records each request's text, voice, status, size and SHA-256
#   CORRECT=Vashti                       correct Vashti (chapter 1) in place of Kuno (chapter 2), so
#                                        chapter 1 is the one made again and chapter 2 the one kept
#
# Screenshots: pronunciations-sheet.png, pronunciations-corrected.png, remaking-chapter.png,
# remade.png. The token is generated here, kept in a 0600 file and handed over by environment,
# file and `defaults import` on stdin, never argv. Preference sync is off in the probe.
# Everything is stopped and removed on exit.
# Exit 0 PASS, 1 FAIL, 2 could not run, 3 another probe holds the lock (probe-lib.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/probe-lib.sh

APP="${1:?usage: $0 <Baton.app> <evidence-dir>}"
EVIDENCE="${2:?evidence dir}"
mkdir -p "$EVIDENCE"
EVIDENCE="$(cd "$EVIDENCE" && pwd -P)"
GATEWAY_BIN="${GATEWAY_BIN:-gateway/.build/debug/baton-gateway}"
[ -x "$GATEWAY_BIN" ] || { echo "no gateway at $GATEWAY_BIN (swift build --product baton-gateway in gateway/)"; exit 2; }
WORK="$(mktemp -d -t baton-lexicon-server)"
GATEWAY_PORT="${GATEWAY_PORT:-18961}"
KOKORO_PORT="${KOKORO_PORT:-18962}"
SUITE="$(probe_new_suite lexicon-server)"
PID="" GATEWAY_PID="" KOKORO_PID=""
fail=0
KOKORO_UPSTREAM="${KOKORO_UPSTREAM:-}"
case "${CORRECT:-Kuno}" in
  Kuno)   WORD=Kuno   IPA="kˈuːnoʊ" SPELLED="kˈuːnO" AFFECTED=2 KEPT=1 OTHER=Vashti ;;
  Vashti) WORD=Vashti IPA="vˈɑːʃti" SPELLED="vˈɑːʃti" AFFECTED=1 KEPT=2 OTHER=Kuno ;;
  *) echo "CORRECT is Kuno or Vashti"; exit 2 ;;
esac

cleanup() {
  probe_quit "$PID"
  [ -n "$GATEWAY_PID" ] && kill "$GATEWAY_PID" 2>/dev/null
  [ -n "$KOKORO_PID" ] && kill "$KOKORO_PID" 2>/dev/null
  [ "${KEEP_PROBE:-0}" = 1 ] || probe_cleanup "$SUITE"
  [ "${KEEP_PROBE:-0}" = 1 ] && echo "kept: $WORK" || rm -rf "$WORK"
  probe_lock_release
}
trap cleanup EXIT
trap 'exit 130' INT TERM

say() { printf '\n== %s\n' "$1"; }
verdict() { if [ "$2" = 0 ]; then echo "   PASS  $1"; else echo "   FAIL  $1"; fail=1; fi; }
wait_for() {   # $1 = seconds, $2 = shell condition
  local limit=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$limit" ]; do eval "$2" && return 0; sleep 1; done
  return 1
}
port_free() { ! lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }
front() { osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null 2>&1; sleep 0.8; }

AX_BIN="${TMPDIR:-/tmp}/baton-probe-ax-$(shasum scripts/probe-ax.swift | cut -c1-12)"
[ -x "$AX_BIN" ] || xcrun swiftc -O -o "$AX_BIN" scripts/probe-ax.swift || { echo "could not build probe-ax"; exit 2; }

probe_lock_acquire || exit 3
port_free "$GATEWAY_PORT" && port_free "$KOKORO_PORT" || { echo "port $GATEWAY_PORT or $KOKORO_PORT is taken"; exit 2; }

say "A. a throwaway gateway on 127.0.0.1:$GATEWAY_PORT and ${KOKORO_UPSTREAM:+a pass-through to the real Kokoro at }${KOKORO_UPSTREAM:-a stand-in Kokoro}"
KOKORO_LOG="$WORK/kokoro-texts.log"
: > "$KOKORO_LOG"
[ -n "$KOKORO_UPSTREAM" ] && : > "$EVIDENCE/kokoro-requests.jsonl"
/usr/bin/python3 - "$KOKORO_PORT" "$KOKORO_LOG" "$KOKORO_UPSTREAM" "$EVIDENCE/kokoro-requests.jsonl" <<'PY' &
import hashlib, http.server, json, struct, sys, time, urllib.request
pcm = bytes(24000 * 2 * 2)   # two seconds of silence, 24 kHz mono 16-bit
wav = b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 24000, 48000, 2, 16) \
    + b"data" + struct.pack("<I", len(pcm)) + pcm
log, upstream, requests = sys.argv[2], sys.argv[3].rstrip("/"), sys.argv[4]
def forward(path, raw=None):   # the real Kokoro's answer, unchanged
    req = urllib.request.Request(upstream + path, data=raw, method="POST" if raw is not None else "GET")
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=300) as r: return r.status, r.headers.get("Content-Type", ""), r.read()
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def answer(self, status, ctype, body):
        self.send_response(status); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if upstream: self.answer(*forward(self.path)); return
        self.answer(200, "application/json", b'{"voices":["bf_emma","af_heart"]}')
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        try: asked = json.loads(raw)
        except Exception: asked = {"input": raw.decode("utf-8", "replace")}
        text = asked.get("input", "")
        with open(log, "a") as f: f.write(json.dumps(text, ensure_ascii=False) + "\n")
        # Slow over a marked-up text, so the row can be seen making the chapter again.
        if "](/" in text: time.sleep(8)
        if not upstream: self.answer(200, "audio/wav", wav); return
        status, ctype, body = forward(self.path, raw)
        with open(requests, "a") as f:
            f.write(json.dumps({"at": time.strftime("%H:%M:%S"), "input": text, "voice": asked.get("voice"), "status": status,
                                "content_type": ctype, "bytes": len(body), "sha256": hashlib.sha256(body).hexdigest()},
                               ensure_ascii=False) + "\n")
        self.answer(status, ctype, body)
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
KOKORO_PID=$!

TOKEN_FILE="$WORK/token"
(umask 077; openssl rand -hex 24 > "$TOKEN_FILE")
mkdir -p "$WORK/gateway"
(
  export BATON_GATEWAY_TOKEN="$(cat "$TOKEN_FILE")" BATON_GATEWAY_PORT="$GATEWAY_PORT" \
    BATON_STATE_FILE="$WORK/gateway/baton-state.json" BATON_TTS_KOKORO_URL="http://127.0.0.1:$KOKORO_PORT" \
    NAVIDROME_URL="http://127.0.0.1:9" NAVIDROME_USER=probe NAVIDROME_PASSWORD=probe
  exec "$GATEWAY_BIN"
) > "$WORK/gateway.log" 2>&1 &
GATEWAY_PID=$!
gw_get() {
  printf 'header = "Authorization: Bearer %s"\n' "$(cat "$TOKEN_FILE")" \
    | curl -s -m 5 -K - "http://127.0.0.1:$GATEWAY_PORT$1"
}
wait_for 20 'gw_get /v1/books | grep -q "\"books\""'; ok=$?; verdict "the gateway answers GET /v1/books" $ok
[ "$fail" = 0 ] || { sed -n 1,20p "$WORK/gateway.log"; exit 2; }

ROOT="$PROBE_SUPPORT_ROOT/$SUITE"
landed() { ls "$ROOT"/Clippings/*.m4a 2>/dev/null | wc -l | tr -d ' '; }
texts() { "$AX_BIN" texts "$PID" 2>/dev/null; }
press() { local i; for i in 1 2 3; do front; "$AX_BIN" press "$PID" "$1" >/dev/null && return 0; sleep 1; done; return 1; }
shot() {   # $1 = file name, $2 = window title
  front
  local id
  id="$("$AX_BIN" window "$PID" "$2" 2>/dev/null)"
  if [[ "$id" =~ ^[0-9]+$ ]]; then screencapture -x -o -l "$id" "$EVIDENCE/$1.png"; else screencapture -x "$EVIDENCE/$1.png"; fi
  echo "   screenshot: $EVIDENCE/$1.png"
}
launch() {   # extra --env pairs; preference sync always off; DEBUG hooks by environment only
  open -n -a "$APP" --env BATON_DEBUG_PREFERENCE_SYNC=off "$@" --args -baton.defaultsSuite "$SUITE" || return 1
  PID=""
  for _ in $(seq 1 40); do PID="$(pgrep -f -- "-baton.defaultsSuite $SUITE" | head -1)"; [ -n "$PID" ] && break; sleep 0.5; done
  [ -n "$PID" ] && echo "   probe pid $PID (suite $SUITE)"
}
record_field() { /usr/bin/python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['payload'][0][sys.argv[2]])" "$ROOT/Books/home-server-books.json" "$1" 2>/dev/null; }
gateway_job() {   # $1 = job id, $2 = python expression over the job as `j`
  /usr/bin/python3 -c "import json,sys; j=json.load(open(sys.argv[1])); print($2)" "$WORK/gateway/books/$1/job.json" 2>/dev/null
}
log_count() { grep -c "$1" "$WORK/gateway.log"; }

say "B. a book made on the home server from the probe's import sheet"
defaults write "$SUITE" baton.documents.enabled -bool true
defaults write "$SUITE" baton.agent.gatewayURL "http://127.0.0.1:$GATEWAY_PORT"
defaults write "$SUITE" tonebox.speech.kokoroBaseURL "http://127.0.0.1:$KOKORO_PORT"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>baton.agent.gatewayToken</key><string>%s</string></dict></plist>\n' \
  "$(cat "$TOKEN_FILE")" | defaults import "$SUITE" - || { echo "could not give the probe the token"; exit 2; }
BOOK="$WORK/the-machine.md"
printf '# The Machine\n\n## The Air-Ship\n\nVashti sat in her room and touched a switch.\n\n## The Mending Apparatus\n\nKuno called from the other side of the earth.\n' > "$BOOK"
launch --env BATON_DEBUG_IMPORT_DOCUMENT="$BOOK" || { echo "probe did not start"; exit 2; }
wait_for 90 'texts | grep -qx "\[button\] Make Audiobook"'; ok=$?; verdict "the import sheet opened (Make Audiobook is there)" $ok
sleep "${SHEET_SETTLE:-6}"
front
[ "$(osascript -e 'tell application "System Events" to unix id of first process whose frontmost is true' 2>/dev/null)" = "$PID" ] \
  || { echo "the probe is not frontmost; no key sent"; exit 2; }
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to keystroke return" >/dev/null
wait_for 120 '[ "$(landed)" -ge 2 ]'; ok=$?; verdict "both chapters came down from the home server ($(landed))" $ok
JOB1="$(record_field jobID)"
[ -n "$JOB1" ]; verdict "the book is remembered as made on the home server (job ${JOB1:0:12})" $?
VOICES1="$(gateway_job "$JOB1" 'json.dumps(j["book"]["voices"], sort_keys=True)')"
echo "   voices: $VOICES1, lexicon: $(gateway_job "$JOB1" 'j["book"].get("lexicon")')"
[ -f "$ROOT/Books/home-server-books/$JOB1.json" ]; verdict "the shaped book is saved beside the record (M6.3)" $?
FILES_BEFORE="$(shasum -a 256 "$ROOT"/Clippings/*.m4a)"
before_texts="$(wc -l < "$KOKORO_LOG" | tr -d ' ')"
echo "   Kokoro was sent $before_texts texts"

say "C. Pronunciations… for the home-server book; $WORD added and saved"
probe_quit "$PID"; PID=""; sleep 2
launch --env BATON_DEBUG_SHOW_CLIPPINGS=1 --env BATON_DEBUG_OPEN_PRONUNCIATIONS=1 || { echo "probe did not restart"; exit 2; }
wait_for 90 'texts | grep -q "^Pronunciations in The Machine"'; ok=$?; verdict "the Pronunciations sheet opened for the home-server book" $ok
sleep 2
shot pronunciations-sheet Baton
"$AX_BIN" set "$PID" "Word" "$WORD" >/dev/null 2>&1
"$AX_BIN" set "$PID" "IPA, like kˈuːnoʊ" "$IPA" >/dev/null 2>&1
sleep 1
if ! press "Add" || ! wait_for 5 'texts | grep -qx "$WORD"'; then
  # A value set through Accessibility may not reach the field's binding: type it instead.
  echo "   (typing the word and its phonemes)"
  front; "$AX_BIN" focus "$PID" "Word" >/dev/null; "$AX_BIN" clear "$PID" >/dev/null; "$AX_BIN" type "$PID" "$WORD" >/dev/null
  front; "$AX_BIN" focus "$PID" "IPA, like kˈuːnoʊ" >/dev/null; "$AX_BIN" clear "$PID" >/dev/null; "$AX_BIN" type "$PID" "$IPA" >/dev/null
  sleep 1; press "Add" >/dev/null
fi
wait_for 10 'texts | grep -qx "$WORD"'; ok=$?; verdict "$WORD is in the list" $ok
texts | grep -qx "yours"; verdict "marked as yours" $?
echo "   field: $("$AX_BIN" value-of "$PID" "Pronunciation of $WORD" 2>/dev/null)"
shot pronunciations-corrected Baton
puts_before="$(log_count "PUT /v1/books/")"
press "Save"; verdict "Save pressed" $?

say "D. the book is made again on the home server under its new id; only chapter $AFFECTED comes back"
wait_for 30 '[ -n "$(record_field jobID)" ] && [ "$(record_field jobID)" != "$JOB1" ]'; ok=$?
JOB2="$(record_field jobID)"
verdict "the record moved to a new job (${JOB1:0:12} -> ${JOB2:0:12})" $ok
[ "$(log_count "PUT /v1/books/$JOB2")" -ge 1 ]; verdict "PUT /v1/books/${JOB2:0:12}… in the gateway's log (PUTs $puts_before -> $(log_count "PUT /v1/books/"))" $?
lexicon2="$(gateway_job "$JOB2" 'json.dumps(j["book"].get("lexicon"), ensure_ascii=False)')"
echo "   the gateway's job ${JOB2:0:12}: lexicon $lexicon2"
echo "$lexicon2" | grep -q "\"word\": \"$WORD\"" && echo "$lexicon2" | grep -q "$SPELLED"; verdict "the gateway's job carries $WORD in Kokoro's spelling" $?
[ -n "$VOICES1" ] && [ "$(gateway_job "$JOB2" 'json.dumps(j["book"]["voices"], sort_keys=True)')" = "$VOICES1" ]
verdict "the narrator, cast and speed are kept ($VOICES1)" $?
wait_for 20 '[ ! -d "$WORK/gateway/books/$JOB1" ]'; ok=$?; verdict "the old job is gone from the gateway" $ok
wait_for 20 'grep -qF "[$WORD](/$SPELLED/)" "$KOKORO_LOG"'; ok=$?; verdict "Kokoro was sent \"[$WORD](/$SPELLED/)\"" $ok
wait_for 8 '[ "$(landed)" -eq 1 ]'; ok=$?; verdict "chapter $AFFECTED left Clippings, chapter $KEPT stayed ($(landed))" $ok
sleep 1
shot remaking-chapter Baton
wait_for 60 '[ "$(landed)" -ge 2 ]'; ok=$?; verdict "chapter $AFFECTED came down again ($(landed))" $ok
new_texts="$(tail -n +"$((before_texts + 1))" "$KOKORO_LOG")"
echo "$new_texts" | sed 's/^/   kokoro <- /'
! echo "$new_texts" | grep -q "$OTHER"; verdict "nothing from chapter $KEPT was synthesized again (the chunk cache)" $?
gets="$(grep -o "GET /v1/books/$JOB2/chapters/[0-9]*" "$WORK/gateway.log" | sort -u | tr '\n' ' ')"
[ "$gets" = "GET /v1/books/$JOB2/chapters/$AFFECTED " ]; verdict "only chapter $AFFECTED was downloaded from the new job ($gets)" $?
kept="$(comm -12 <(echo "$FILES_BEFORE" | sort) <(shasum -a 256 "$ROOT"/Clippings/*.m4a | sort) | wc -l | tr -d ' ')"
[ "$kept" = 1 ]; verdict "chapter $KEPT's file is the one from before, byte for byte ($kept of 2 unchanged)" $?
shasum -a 256 "$ROOT"/Clippings/*.m4a | sed "s|$ROOT/||; s/^/   /"
sleep 2
shot remade Baton

echo
[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
