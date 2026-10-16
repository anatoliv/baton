#!/bin/bash
# Change Voice… on the Mac (TBX-10989), on a probe instance, never the owner's Baton:
#
#   scripts/probe-change-voice.sh <Baton.app> <evidence-dir> <built-in-model-dir>
#
#   A. a logging pass-through to a real Kokoro (KOKORO_UPSTREAM, required: your Kokoro voice
#      server's URL) on 127.0.0.1, recording each request's voice, text and digest
#   B. a two-chapter book made on this Mac with the built-in voices (the model copied in from
#      <built-in-model-dir>, checked against its pinned sha256), read by Heart
#   C. Change Voice… on the book (DEBUG BATON_DEBUG_OPEN_CHANGE_VOICE=book in place of the
#      row's menu), am_michael chosen: the row says "Making again in", both chapters are
#      replaced in their rows (same files, new digests, voice am_michael in the sidecars), and
#      the voice is measurably different (median pitch of each chapter, before and after)
#   D. a kept reading (seeded with Heart's audio from the real Kokoro) changed to am_michael
#      through the voice server: Kokoro is asked for am_michael, the row is kept, its audio
#      and voice are replaced, and the pitch drops the same way
#
# Preference sync is off. Screenshots: book-picker.png, book-making-again.png, book-done.png,
# reading-picker.png, reading-making-again.png, reading-done.png. Everything is removed on exit.
# Exit 0 PASS, 1 FAIL, 2 could not run, 3 another probe holds the lock (probe-lib.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/probe-lib.sh

APP="${1:?usage: $0 <Baton.app> <evidence-dir> <built-in-model-dir>}"
EVIDENCE="${2:?evidence dir}"
MODEL_DIR="${3:?built-in model dir (kokoro-v1_0.safetensors, voices.npz)}"
mkdir -p "$EVIDENCE"
EVIDENCE="$(cd "$EVIDENCE" && pwd -P)"
KOKORO_UPSTREAM="${KOKORO_UPSTREAM:?set KOKORO_UPSTREAM to your Kokoro voice server, for example http://kokoro.local:8880}"
KOKORO_PORT="${KOKORO_PORT:-18989}"
FROM="${FROM_VOICE:-af_heart}" TO="${TO_VOICE:-am_michael}"
WORK="$(mktemp -d -t baton-change-voice)"
SUITE="$(probe_new_suite change-voice)"
PID="" KOKORO_PID=""
fail=0

cleanup() {
  probe_quit "$PID"
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
front() { osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null 2>&1; sleep 0.8; }

AX_BIN="${TMPDIR:-/tmp}/baton-probe-ax-$(shasum scripts/probe-ax.swift | cut -c1-12)"
[ -x "$AX_BIN" ] || xcrun swiftc -O -o "$AX_BIN" scripts/probe-ax.swift || { echo "could not build probe-ax"; exit 2; }

# The median pitch of an audio file, in Hz, from autocorrelation over voiced 40 ms frames: a
# woman's voice and a man's sit about an octave apart, so this tells Heart from Michael.
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
    for k in range(20, 134):   # 60 to 400 Hz
        c = sum(f[i] * x[start + i + k] for i in range(frame))
        if c > best: best, lag = c, k
    if lag and best > 0.3 * energy: found.append(rate / lag)
print(round(statistics.median(found)) if found else 0)'
}

probe_lock_acquire || exit 3
lsof -nP -iTCP:"$KOKORO_PORT" -sTCP:LISTEN >/dev/null 2>&1 && { echo "port $KOKORO_PORT is taken"; exit 2; }

say "A. a logging pass-through to the real Kokoro at $KOKORO_UPSTREAM"
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
                                "input": asked.get("input", "")[:80], "status": status, "bytes": len(body),
                                "sha256": hashlib.sha256(body).hexdigest()}, ensure_ascii=False) + "\n")
        self.answer(status, ctype, body)
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
KOKORO_PID=$!
wait_for 10 'curl -s -m 5 "http://127.0.0.1:$KOKORO_PORT/v1/audio/voices" | grep -q "$TO"'; verdict "the real Kokoro answers through the pass-through and lists $TO" $?
[ "$fail" = 0 ] || exit 2

ROOT="$PROBE_SUPPORT_ROOT/$SUITE"
texts() { "$AX_BIN" texts "$PID" 2>/dev/null; }
press() { local i; for i in 1 2 3; do front; "$AX_BIN" press "$PID" "$1" >/dev/null && return 0; sleep 1; done; return 1; }
shot() {
  front
  local id
  id="$("$AX_BIN" window "$PID" "${2:-Baton}" 2>/dev/null)"
  if [[ "$id" =~ ^[0-9]+$ ]]; then screencapture -x -o -l "$id" "$EVIDENCE/$1.png"; else screencapture -x "$EVIDENCE/$1.png"; fi
  echo "   screenshot: $EVIDENCE/$1.png"
}
launch() {
  open -n -a "$APP" --env BATON_DEBUG_PREFERENCE_SYNC=off "$@" --args -baton.defaultsSuite "$SUITE" || return 1
  PID=""
  for _ in $(seq 1 40); do PID="$(pgrep -f -- "-baton.defaultsSuite $SUITE" | head -1)"; [ -n "$PID" ] && break; sleep 0.5; done
  [ -n "$PID" ] && echo "   probe pid $PID (suite $SUITE)"
}
sidecar() {   # $1 = sidecar json, $2 = field
  /usr/bin/python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['payload'].get(sys.argv[2]))" "$1" "$2" 2>/dev/null
}
chapters() {   # "<file> <chapter> <voice> <sha256>" per book chapter, by chapter
  for j in "$ROOT"/Clippings/*.json; do
    [ -f "$j" ] || continue
    local c; c="$(sidecar "$j" chapterIndex)"; [ "$c" = None ] && continue
    echo "$(basename "$j" .json) $c $(sidecar "$j" voice) $(sidecar "$j" sha256)"
  done | sort -k2 -n
}

say "B. a two-chapter book made on this Mac with the built-in voices, in the narrator the import sheet offers first"
DEST="$ROOT/Models/kokoro-mlx"
mkdir -p "$DEST"
W_SHA=4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8
V_SHA=56dbfa2f2970af2e395397020393d368c5f441d09b3de4e9b77f6222e790f10f
[ "$(shasum -a 256 "$MODEL_DIR/kokoro-v1_0.safetensors" | cut -d' ' -f1)" = "$W_SHA" ] \
  && [ "$(shasum -a 256 "$MODEL_DIR/voices.npz" | cut -d' ' -f1)" = "$V_SHA" ]; verdict "the built-in model files match their pinned sha256" $?
cp "$MODEL_DIR/kokoro-v1_0.safetensors" "$MODEL_DIR/voices.npz" "$DEST/"
printf '{"kokoro-v1_0.safetensors":"%s","voices.npz":"%s"}' "$W_SHA" "$V_SHA" > "$DEST/installed.json"
defaults write "$SUITE" baton.documents.enabled -bool true
defaults write "$SUITE" baton.documents.voiceEngine builtIn
defaults write "$SUITE" baton.documents.makeBooksOn thisMac
defaults write "$SUITE" tonebox.speech.kokoroBaseURL "http://127.0.0.1:$KOKORO_PORT"
BOOK="$WORK/the-machine.md"
# Long enough (about a minute a chapter) that the row is seen making it again.
{ printf '# The Machine\n\n## The Air-Ship\n\n'; for _ in 1 2 3; do printf '%s\n\n' "Vashti sat in her room, and the bell rang. She touched a switch, and the music was silent. Then she spoke to her son, who lived on the other side of the earth, and asked him why he had called. He said that he wanted her to visit him, and she said that she did not have time. The room hummed around them, and the light was the same as it always was."; done
  printf '## The Mending Apparatus\n\n'; for _ in 1 2 3; do printf '%s\n\n' "Kuno called again that night. He said that he wanted to see the stars, and that the Machine had no right to stop him. Vashti did not answer him for a long while. When she did, she told him that the surface was dead, that nobody went there, and that he should rest. He laughed, and the sound came through the plate a little late."; done; } > "$BOOK"
launch --env BATON_DEBUG_IMPORT_DOCUMENT="$BOOK" || { echo "probe did not start"; exit 2; }
wait_for 90 'texts | grep -qx "\[button\] Make Audiobook"'; ok=$?; verdict "the import sheet opened" $ok
sleep "${SHEET_SETTLE:-8}"
front
[ "$(osascript -e 'tell application "System Events" to unix id of first process whose frontmost is true' 2>/dev/null)" = "$PID" ] \
  || { echo "the probe is not frontmost; no key sent"; exit 2; }
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to keystroke return" >/dev/null
wait_for 300 '[ "$(chapters | wc -l | tr -d " ")" -ge 2 ]'; ok=$?; verdict "both chapters were made on this Mac ($(chapters | wc -l | tr -d ' '))" $ok
chapters | sed 's/^/   before: /'
BEFORE="$(chapters)"
BOOK_FROM="$(echo "$BEFORE" | awk '{print $3}' | sort -u)"
[ "$(echo "$BOOK_FROM" | wc -l | tr -d ' ')" = 1 ] && [ -n "$BOOK_FROM" ]; verdict "both chapters are in one voice, $BOOK_FROM, stored on each clipping" $?
BOOK_FROM="${BOOK_FROM#kokoro:}"
for f in $(echo "$BEFORE" | awk '{print $1}'); do cp "$ROOT/Clippings/$f.m4a" "$WORK/before-$f.m4a"; done
[ "$(grep -c '"voice"' "$EVIDENCE/kokoro-requests.jsonl")" = 0 ]; verdict "the voice server was not asked: the built-in voices made it" $?
probe_quit "$PID"; PID=""; sleep 2

say "C. Change Voice… on the book: $TO"
launch --env BATON_DEBUG_SHOW_CLIPPINGS=1 --env BATON_DEBUG_OPEN_CHANGE_VOICE=book || { echo "probe did not restart"; exit 2; }
wait_for 90 'texts | grep -q "^Change the voice of The Machine"'; ok=$?; verdict "Change Voice opened for the book" $ok
wait_for 30 'texts | grep -qx "\[button\] $TO on Kokoro"'; ok=$?; verdict "$TO is offered among the built-in voices" $ok
texts | grep -q "^Now read by $BOOK_FROM on Kokoro"; verdict "the sheet names the voice it has now" $?
press "$TO on Kokoro"; verdict "$TO chosen" $?
sleep 1
shot book-picker
T0=$(date +%s)
press "Make Again in This Voice"; verdict "Make Again in This Voice pressed" $?
wait_for 60 'texts | grep -q "^Making again in $TO on Kokoro"'; ok=$?; verdict "the row says Making again in $TO on Kokoro" $ok
texts | grep "^Making again" | head -1 | sed 's/^/   /'
shot book-making-again
wait_for 120 '[ "$(chapters | awk "{print \$3}" | tr "\n" " ")" = "kokoro:$TO kokoro:$BOOK_FROM " ]'; ok=$?
verdict "chapter 1 is replaced while chapter 2 still plays in $BOOK_FROM" $ok
[ "$ok" = 0 ] && { texts | grep "^Making again" | head -1 | sed 's/^/   /'; shot book-chapter-1-replaced; }
wait_for 600 '[ "$(chapters | awk "{print \$3}" | sort -u)" = "kokoro:$TO" ]'; ok=$?
verdict "both chapters were replaced in $TO ($(( $(date +%s) - T0 )) s)" $ok
AFTER="$(chapters)"
echo "$AFTER" | sed 's/^/   after:  /'
[ "$(echo "$BEFORE" | awk '{print $1}')" = "$(echo "$AFTER" | awk '{print $1}')" ]; verdict "the same rows (clipping ids) as before" $?
[ "$(ls "$ROOT"/Clippings/*.m4a | wc -l | tr -d ' ')" = 2 ]; verdict "two audio files, no duplicate" $?
[ -z "$(comm -12 <(echo "$BEFORE" | awk '{print $4}' | sort) <(echo "$AFTER" | awk '{print $4}' | sort))" ]; verdict "every chapter's digest changed" $?
for f in $(echo "$AFTER" | awk '{print $1}'); do
  b="$(pitch "$WORK/before-$f.m4a")" a="$(pitch "$ROOT/Clippings/$f.m4a")"
  echo "   chapter file $f: median pitch $b Hz ($BOOK_FROM) -> $a Hz ($TO)"
  [ "$a" -gt 0 ] && [ "$b" -gt 0 ] && [ $(( b * 100 / a )) -ge 130 ]; verdict "  the new voice is measurably lower (at least 1.3 times)" $?
done
wait_for 10 '! texts | grep -q "^Making again"'; verdict "the Making again line is gone" $?
sleep 1
shot book-done
[ "$(grep -c '"voice"' "$EVIDENCE/kokoro-requests.jsonl")" = 0 ]; verdict "the book was made again on this Mac, not by the voice server" $?
probe_quit "$PID"; PID=""; sleep 2

say "D. a kept reading, read again by the voice server in $TO"
READING_ID="$(uuidgen | tr 'A-Z' 'a-z')"
TEXT="The machine stops, said the man in the next cell. Nobody believed him at first. Then the music faltered, and the lights went dim. People complained to the Committee, and the Committee said that the Mending Apparatus was itself in need of repair. A week later the air began to smell. Nobody knew what to do, because nobody had ever had to do anything. The bells rang in every room at once, and then they stopped ringing altogether."
printf '{"model":"kokoro","voice":"%s","input":"%s","response_format":"wav"}' "$FROM" "$TEXT" \
  | curl -s -m 120 -H 'Content-Type: application/json' --data-binary @- "http://127.0.0.1:$KOKORO_PORT/v1/audio/speech" -o "$WORK/reading.wav"
ffmpeg -v error -y -i "$WORK/reading.wav" -c:a aac -b:a 64k "$ROOT/Clippings/$READING_ID.m4a"; verdict "a reading in $FROM made by the real Kokoro" $?
CREATED="$(/usr/bin/python3 -c 'import time; print(time.time() - 978307200)')"
/usr/bin/python3 - "$ROOT/Clippings/$READING_ID.json" "$READING_ID" "$TEXT" "$CREATED" "kokoro:$FROM" <<'PY'
import json, sys
path, ident, text, created, voice = sys.argv[1:]
json.dump({"version": 3, "payload": {"id": ident, "title": "Ghostty reading", "source": "Ghostty",
           "createdAt": float(created), "text": text, "voice": voice}}, open(path, "w"))
PY
cp "$ROOT/Clippings/$READING_ID.m4a" "$WORK/reading-before.m4a"
SHA_BEFORE="$(shasum -a 256 "$ROOT/Clippings/$READING_ID.m4a" | cut -d' ' -f1)"
asked_before="$(grep -c "\"voice\": \"$TO\"" "$EVIDENCE/kokoro-requests.jsonl")"
launch --env BATON_DEBUG_SHOW_CLIPPINGS=1 --env BATON_DEBUG_OPEN_CHANGE_VOICE=reading || { echo "probe did not restart"; exit 2; }
wait_for 90 'texts | grep -q "^Change the voice of Ghostty reading"'; ok=$?; verdict "Change Voice opened for the reading" $ok
wait_for 30 'texts | grep -qx "\[button\] $TO on Kokoro"'; ok=$?; verdict "$TO is offered from the voice server's list" $ok
press "$TO on Kokoro"; verdict "$TO chosen" $?
sleep 1
shot reading-picker
press "Make Again in This Voice"; verdict "Make Again in This Voice pressed" $?
wait_for 30 'texts | grep -q "^Making again in $TO on Kokoro"'; ok=$?; verdict "the row says Making again in $TO on Kokoro" $ok
shot reading-making-again
wait_for 180 '[ "$(sidecar "$ROOT/Clippings/$READING_ID.json" voice)" = "kokoro:$TO" ]'; ok=$?; verdict "the reading's voice is stored as $TO" $ok
SHA_AFTER="$(shasum -a 256 "$ROOT/Clippings/$READING_ID.m4a" | cut -d' ' -f1)"
echo "   reading audio: ${SHA_BEFORE:0:16}… -> ${SHA_AFTER:0:16}…"
[ "$SHA_BEFORE" != "$SHA_AFTER" ]; verdict "the reading's audio file was replaced" $?
[ "$(ls "$ROOT"/Clippings/*.m4a | wc -l | tr -d ' ')" = 3 ]; verdict "the same row: still three audio files in Clippings" $?
[ "$(grep -c "\"voice\": \"$TO\"" "$EVIDENCE/kokoro-requests.jsonl")" -gt "$asked_before" ]; verdict "Kokoro was asked for $TO" $?
grep "\"voice\": \"$TO\"" "$EVIDENCE/kokoro-requests.jsonl" | tail -3 | sed 's/^/   kokoro <- /'
b="$(pitch "$WORK/reading-before.m4a")" a="$(pitch "$ROOT/Clippings/$READING_ID.m4a")"
echo "   reading: median pitch $b Hz ($FROM) -> $a Hz ($TO)"
[ "$a" -gt 0 ] && [ "$b" -gt 0 ] && [ $(( b * 100 / a )) -ge 130 ]; verdict "the new voice is measurably lower (at least 1.3 times)" $?
sleep 1
shot reading-done
cp "$ROOT/Clippings/$READING_ID.json" "$EVIDENCE/reading-sidecar-after.json"

echo
[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
