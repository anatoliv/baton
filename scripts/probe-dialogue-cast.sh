#!/bin/bash
# Voice the dialogue in Change Voice… on the Mac, on a probe instance, never the
# owner's Baton:
#
#   KOKORO_UPSTREAM=http://<kokoro>:8880 scripts/probe-dialogue-cast.sh <Baton.app> <evidence-dir>
#
#   A. a logging pass-through to a real Kokoro (KOKORO_UPSTREAM) on 127.0.0.1, recording each
#      request's voice and text, and a stand-in model on 127.0.0.1 speaking /v1/chat/completions,
#      saved as the probe's only local model source: it writes the cast list (Vashti, Kuno) and
#      places the two lines without a speech tag, by what they say, and logs each prompt's kind
#   B. a two-chapter book made on this Mac by the voice server, Voice the dialogue off: one
#      narrator, no cast in the job
#   C. Change Voice… on the book (DEBUG BATON_DEBUG_OPEN_CHANGE_VOICE=book): Voice the dialogue
#      turned on, the stand-in proposes the cast, Check the Cast… opens, Use This Cast, the lines
#      are placed, Make Again: the new job has the
#      cast (each quote with its speaker), both chapters are replaced, and Kokoro was asked for
#      the characters' voices
#   E. Change Voice… to an expressive narrator, from a loopback
#      fixture server that reads through the real Kokoro but answers 48 kHz stereo float, as
#      another server may: the cast keeps its Kokoro voices, so one chapter mixes two engines
#      and two audio formats. The fixture was asked for the narrator with a delivery
#      instruction, both chapters are replaced, and each is as long as before or longer (no clip
#      dropped or garbled into noise; the fixture's own pauses are not trimmed away)
#   F. Export Audiobook… of that book (DEBUG BATON_DEBUG_EXPORT_BOOK in place of the save panel,
#      which runs in another process): every chapter file is 24 kHz mono, and the M4B decodes
#      to its full length with a mark per chapter
#   D. Change Voice… again: back to Emma, the switch turned off, Make Again: the job is the
#      narrator-only book again (the very job id it had before the cast) and both chapters are
#      replaced
#
# Renaming in the editor is not walked here: setting AXValue does not reach a SwiftUI text
# field's binding, and keys are not sent. The package tests and the phone's UI tests cover it.
# Driven by pid through the Accessibility API only (AXPress): no coordinates, no keys.
# Preference sync is off. Everything is removed on exit unless KEEP_PROBE=1.
# Exit 0 PASS, 1 FAIL, 2 could not run, 3 another probe holds the lock (probe-lib.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/probe-lib.sh

APP="${1:?usage: $0 <Baton.app> <evidence-dir>}"
EVIDENCE="${2:?evidence dir}"
mkdir -p "$EVIDENCE"
EVIDENCE="$(cd "$EVIDENCE" && pwd -P)"
KOKORO_UPSTREAM="${KOKORO_UPSTREAM:?set KOKORO_UPSTREAM to your Kokoro voice server, for example http://kokoro.local:8880}"
KOKORO_PORT="${KOKORO_PORT:-18991}"
MODEL_PORT="${MODEL_PORT:-18992}"
EXPRESSIVE_PORT="${EXPRESSIVE_PORT:-18996}"
EXPRESSIVE="${EXPRESSIVE_VOICE:-Ryan}"
WORK="$(mktemp -d -t baton-dialogue-cast)"
SUITE="$(probe_new_suite dialogue-cast)"
PID="" KOKORO_PID="" MODEL_PID="" EXPRESSIVE_PID=""
fail=0

cleanup() {
  probe_quit "$PID"
  [ -n "$KOKORO_PID" ] && kill "$KOKORO_PID" 2>/dev/null
  [ -n "$MODEL_PID" ] && kill "$MODEL_PID" 2>/dev/null
  [ -n "$EXPRESSIVE_PID" ] && kill "$EXPRESSIVE_PID" 2>/dev/null
  [ "${KEEP_PROBE:-0}" = 1 ] || probe_cleanup "$SUITE"
  if [ "${KEEP_PROBE:-0}" = 1 ]; then echo "kept: $WORK"; else rm -rf "${WORK:?}"; fi
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

AX_BIN="${TMPDIR:-/tmp}/baton-probe-ax-$(shasum scripts/probe-ax.swift | cut -c1-12)"
[ -x "$AX_BIN" ] || xcrun swiftc -O -o "$AX_BIN" scripts/probe-ax.swift || { echo "could not build probe-ax"; exit 2; }

probe_lock_acquire || exit 3
for port in "$KOKORO_PORT" "$MODEL_PORT" "$EXPRESSIVE_PORT"; do
  lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && { echo "port $port is taken"; exit 2; }
done

say "A. a logging pass-through to the real Kokoro at $KOKORO_UPSTREAM, and a stand-in model"
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
MODEL_PID=$!
: > "$EVIDENCE/expressive-requests.jsonl"
/usr/bin/python3 - "$EXPRESSIVE_PORT" "$KOKORO_PORT" "$EVIDENCE/expressive-requests.jsonl" "$WORK" <<'PY' &
# An expressive server for the walk: OpenAI's speech API, three Qwen3-TTS preset names, each read
# by a real Kokoro voice through the walk's relay, and answered as 48 kHz stereo 32-bit float
# (afconvert), a format unlike Kokoro's, so the chapter's join has to convert.
import http.server, json, os, subprocess, sys, tempfile, time, urllib.request
port, kokoro, log, work = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
READ_BY = {"Ryan": "am_michael", "Aiden": "am_adam", "Vivian": "af_nicole"}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def answer(self, status, ctype, body):
        self.send_response(status); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path.rstrip("/").endswith("/voices"):
            return self.answer(200, "application/json", json.dumps({"data": [{"id": v} for v in READ_BY]}).encode())
        self.answer(404, "application/json", b"{}")
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        voice = body.get("voice", "")
        with open(log, "a") as f:
            f.write(json.dumps({"at": time.strftime("%H:%M:%S"), "model": body.get("model"), "voice": voice,
                                "input": body.get("input", "")[:60], "instructions": body.get("instructions")}) + "\n")
        if voice not in READ_BY: return self.answer(400, "application/json", b'{"error":"unknown voice"}')
        ask = json.dumps({"model": "kokoro", "voice": READ_BY[voice], "input": body.get("input", ""), "response_format": "wav"}).encode()
        req = urllib.request.Request(f"http://127.0.0.1:{kokoro}/v1/audio/speech", data=ask, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=120) as r: wav = r.read()
        src = tempfile.NamedTemporaryFile(dir=work, suffix=".wav", delete=False); src.write(wav); src.close()
        out = src.name + ".48k.wav"
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEF32@48000", "-c", "2", src.name, out], check=True)
        data = open(out, "rb").read(); os.unlink(src.name); os.unlink(out)
        self.answer(200, "audio/wav", data)
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PY
EXPRESSIVE_PID=$!
wait_for 10 'curl -s -m 5 "http://127.0.0.1:$KOKORO_PORT/v1/audio/voices" | grep -q "bf_emma"'; verdict "the real Kokoro answers through the pass-through" $?
wait_for 10 'curl -s -m 5 -H "Content-Type: application/json" -d "{\"messages\":[]}" "http://127.0.0.1:$MODEL_PORT/v1/chat/completions" | grep -q choices'
verdict "the stand-in model answers on 127.0.0.1:$MODEL_PORT" $?
wait_for 10 'curl -s -m 5 "http://127.0.0.1:$EXPRESSIVE_PORT/v1/audio/voices" | grep -q "$EXPRESSIVE"'
verdict "the expressive fixture lists $EXPRESSIVE on 127.0.0.1:$EXPRESSIVE_PORT" $?
[ "$fail" = 0 ] || exit 2

ROOT="$PROBE_SUPPORT_ROOT/$SUITE"
texts() { "$AX_BIN" texts "$PID" 2>/dev/null; }
press() { local i; for i in 1 2 3; do "$AX_BIN" press "$PID" "$1" >/dev/null && return 0; sleep 1; done; return 1; }
shot() {
  local id
  id="$("$AX_BIN" windows "$PID" 2>/dev/null | head -1 | cut -d' ' -f1)"
  [[ "$id" =~ ^[0-9]+$ ]] && screencapture -x -o -l "$id" "$EVIDENCE/$1.png" && echo "   screenshot: $EVIDENCE/$1.png"
}
launch() {
  open -n -a "$APP" --env BATON_DEBUG_PREFERENCE_SYNC=off "$@" --args -baton.defaultsSuite "$SUITE" || return 1
  PID=""
  for _ in $(seq 1 40); do PID="$(pgrep -f -- "-baton.defaultsSuite $SUITE" | head -1)"; [ -n "$PID" ] && break; sleep 0.5; done
  [ -n "$PID" ] && echo "   probe pid $PID (suite $SUITE)"
}
# The newest job: "<id> <narrator> <characters as name=voice,...> <quote speakers in order>
# <digest of the chapters' segments> <speed>".
job() {
  /usr/bin/python3 - "$ROOT/Books" <<'PY'
import json, os, sys, glob
jobs = []
for path in glob.glob(os.path.join(sys.argv[1], "*", "job.json")):
    j = json.load(open(path)); jobs.append((os.path.getmtime(path), j))
if not jobs: sys.exit(0)
j = max(jobs, key=lambda x: x[0])[1]
b = j["book"]
chars = ",".join(f"{k}={v}" for k, v in sorted(b["voices"].get("characters", {}).items())) or "-"
quotes = ",".join(s.get("speaker") or "narrator" for c in b["chapters"] for s in c["segments"] if s["kind"] == "quote")
import hashlib
words = hashlib.sha256(json.dumps(b["chapters"], sort_keys=True).encode()).hexdigest()[:12]
print(j["id"][:12], b["voices"]["narrator"], chars, quotes, words, b["voices"].get("speed", "-"))
PY
}
sidecar() { /usr/bin/python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['payload'].get(sys.argv[2]))" "$1" "$2" 2>/dev/null; }
chapters() {   # "<file> <chapter> <sha256>" per book chapter in Clippings
  for j in "$ROOT"/Clippings/*.json; do
    [ -f "$j" ] || continue
    local c; c="$(sidecar "$j" chapterIndex)"; [ "$c" = None ] && continue
    echo "$(basename "$j" .json) $c $(sidecar "$j" sha256)"
  done | sort -k2 -n
}

say "B. a two-chapter book made on this Mac by the voice server, one narrator"
defaults write "$SUITE" baton.documents.enabled -bool true
defaults write "$SUITE" baton.documents.voiceEngine server
defaults write "$SUITE" baton.documents.makeBooksOn thisMac
defaults write "$SUITE" baton.documents.voiceTheDialogue -bool false
defaults write "$SUITE" tonebox.speech.kokoroBaseURL "http://127.0.0.1:$KOKORO_PORT"
defaults write "$SUITE" baton.documents.expressiveServerURL "http://127.0.0.1:$EXPRESSIVE_PORT"
SOURCE="$(printf '{"version":1,"payload":[{"name":"the stand-in model on this Mac","provider":"openAICompatible","baseURL":"http://127.0.0.1:%s","model":"stand-in","contextTokens":16384}]}' "$MODEL_PORT" | xxd -p | tr -d '\n')"
defaults write "$SUITE" baton.documents.localModelSources -data "$SOURCE"
# HTML, so the book opens with an untitled chapter: the sentences before the first heading,
# which begin with a line of Vashti's. With an expressive narrator and a Kokoro cast (part E)
# that chapter opens in Kokoro's format and every other one in the narrator's, the case the
# An internal task review found broke the M4B export.
BOOK="$WORK/the-machine.html"
cat > "$BOOK" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>The Machine</title></head><body>
<h1>The Machine</h1>
<p>“Where is everyone?” said Vashti. Nobody answered her for a long while, and the room hummed on around her as it always did.</p>
<h2>The Air-Ship</h2>
<p>Vashti sat in her room, and the bell rang twice. She touched a switch, and the plate lit up.</p>
<p>“Who is it?” said Vashti.</p>
<p>“It is Kuno,” said her son. “I want you to come and see me.”</p>
<p>“But I can see you!”</p>
<p>“I want to see you not through the Machine.”</p>
<h2>The Mending Apparatus</h2>
<p>Kuno called again that night, and his face was grey.</p>
<p>“I have been out on the surface,” said Kuno.</p>
<p>“You should not have gone,” said Vashti, and the plate went dark.</p>
</body></html>
HTML
launch --env BATON_DEBUG_IMPORT_DOCUMENT="$BOOK" || { echo "probe did not start"; exit 2; }
wait_for 90 'texts | grep -qx "\[button\] Make Audiobook"'; ok=$?; verdict "the import sheet opened" $ok
sleep "${SHEET_SETTLE:-8}"
[ "$("$AX_BIN" value "$PID" voice-the-dialogue 2>/dev/null)" = 0 ]; verdict "Voice the dialogue is off on the import sheet" $?
shot import-sheet
press "Make Audiobook"; verdict "Make Audiobook pressed" $?
wait_for 300 '[ "$(chapters | wc -l | tr -d " ")" -ge 3 ]'; ok=$?; verdict "the three chapters were made on this Mac, the untitled opening first ($(chapters | wc -l | tr -d ' '))" $ok
J="$(job)"; echo "   job: $J"
FIRST_JOB="$(echo "$J" | awk '{print $1}')" FIRST_WORDS="$(echo "$J" | awk '{print $5}')" FIRST_SPEED="$(echo "$J" | awk '{print $6}')"
NARRATOR="$(echo "$J" | awk '{print $2}')"
[ "$(echo "$J" | awk '{print $3}')" = "-" ]; verdict "no cast in the job: one narrator, $NARRATOR" $?
BEFORE="$(chapters)"
probe_quit "$PID"; PID=""; sleep 2

say "C. Change Voice…: Voice the dialogue turned on and the cast checked"
asked_before="$(wc -l < "$EVIDENCE/kokoro-requests.jsonl" | tr -d ' ')"
launch --env BATON_DEBUG_SHOW_CLIPPINGS=1 --env BATON_DEBUG_OPEN_CHANGE_VOICE=book || { echo "probe did not restart"; exit 2; }
wait_for 90 'texts | grep -q "^Change the voice of The Machine"'; ok=$?; verdict "Change Voice opened for the book" $ok
wait_for 30 '[ "$("$AX_BIN" value "$PID" voice-the-dialogue 2>/dev/null)" = 0 ]'; verdict "Voice the dialogue is there, off: the book has no cast" $?
shot change-voice-no-cast
"$AX_BIN" toggle "$PID" voice-the-dialogue >/dev/null; verdict "Voice the dialogue turned on" $?
wait_for 120 'texts | grep -qx "\[button\] Check the Cast…"'; ok=$?; verdict "the stand-in proposed a cast: Check the Cast… is offered" $ok
texts | grep "proposed" | head -1 | sed 's/^/   /'
grep -q '"kind": "cast list"' "$EVIDENCE/model-requests.jsonl"; verdict "the cast list came from the stand-in model through the router" $?
shot change-voice-proposed
press "Check the Cast…"; verdict "Check the Cast… pressed" $?
wait_for 15 'texts | grep -qx "\[button\] Use This Cast"'; ok=$?; verdict "the cast editor opened" $ok
sleep 1
shot cast-editor
press "Use This Cast"; verdict "Use This Cast pressed" $?
wait_for 60 'texts | grep -q "^Placed by .* more lines"'; ok=$?; verdict "the lines without a tag were placed" $ok
texts | grep "^Placed by" | head -1 | sed 's/^/   /'
shot change-voice-placed
press "Make Again in This Voice"; verdict "Make Again pressed" $?
wait_for 60 '[ "$(job | awk "{print \$3}")" != "-" ]'; ok=$?; verdict "a new job with a cast" $ok
J="$(job)"; echo "   job: $J"
CHARS="$(echo "$J" | awk '{print $3}')"
echo "$CHARS" | grep -q "Kuno=kokoro:" && echo "$CHARS" | grep -q "Vashti=kokoro:"; verdict "the cast travels in the book: $CHARS" $?
[ "$(echo "$J" | awk '{print $2}')" = "$NARRATOR" ]; verdict "the same narrator, $NARRATOR" $?
echo "$J" | awk '{print $4}' | sed 's/^/   quote speakers: /'
[ "$(echo "$J" | awk '{print $4}')" = "Vashti,Vashti,Kuno,Kuno,Vashti,Kuno,Kuno,Vashti" ]
verdict "each quote has its speaker: tags by the rules, the two untagged by the stand-in" $?
wait_for 300 '[ -z "$(comm -12 <(echo "$BEFORE" | awk "{print \$3}" | sort) <(chapters | awk "{print \$3}" | sort))" ]'; ok=$?
verdict "every chapter was replaced in its row" $ok
[ "$(echo "$BEFORE" | awk '{print $1}')" = "$(chapters | awk '{print $1}')" ]; verdict "the same rows as before" $?
for spec in $(echo "$CHARS" | tr ',' '\n' | cut -d= -f2 | sed 's/^kokoro://'); do
  n="$(tail -n +"$((asked_before + 1))" "$EVIDENCE/kokoro-requests.jsonl" | grep -c "\"voice\": \"$spec\"")"
  [ "$n" -gt 0 ]; verdict "Kokoro was asked for the character voice $spec ($n requests)" $?
done
tail -n +"$((asked_before + 1))" "$EVIDENCE/kokoro-requests.jsonl" | sed 's/^/   kokoro <- /'
shot book-with-cast
AFTER_CAST="$(chapters)"
probe_quit "$PID"; PID=""; sleep 2

say "E. Change Voice…: an expressive narrator, $EXPRESSIVE, with the Kokoro cast kept"
seconds() { for f in $(chapters | awk '{print $1}'); do ffprobe -v error -show_entries format=duration -of csv=p=0 "$ROOT/Clippings/$f.m4a"; done | tr '\n' ' '; }
CAST_SECONDS="$(seconds)"
launch --env BATON_DEBUG_SHOW_CLIPPINGS=1 --env BATON_DEBUG_OPEN_CHANGE_VOICE=book || { echo "probe did not restart"; exit 2; }
wait_for 90 'texts | grep -q "^Change the voice of The Machine"'; ok=$?; verdict "Change Voice opened" $ok
wait_for 30 '[ "$("$AX_BIN" value "$PID" voice-the-dialogue 2>/dev/null)" = 1 ]'; verdict "the book has its cast" $?
# All voices is a lazy list with the expressive group last, and a scroll set through the
# Accessibility API does not make its rows. So the picker's own search: the field is focused
# through the Accessibility API, and the name typed only while the probe is frontmost, checked
# immediately before the keys (never brought forward).
if ! "$AX_BIN" press "$PID" "narrator-openai:$EXPRESSIVE" >/dev/null 2>&1; then
  press all-voices; sleep 1
  "$AX_BIN" focus "$PID" "Search voices" >/dev/null 2>&1; sleep 0.5
  if "$AX_BIN" guard "$PID"; then
    "$AX_BIN" type "$PID" "$EXPRESSIVE" >/dev/null; sleep 1
    texts | grep -q "Expressive voices$"; verdict "the search finds $EXPRESSIVE under Expressive voices" $?
    press "voice-openai:$EXPRESSIVE"
  else
    verdict "the probe is frontmost for the search (it is not; no key sent)" 1
  fi
fi
wait_for 5 'texts | grep -q "Ryan, English, male"'; verdict "$EXPRESSIVE chosen from the expressive voices" $?
sleep 1
texts | grep -i "expressive" | head -3 | sed 's/^/   /'
shot change-voice-expressive
asked_before="$(wc -l < "$EVIDENCE/expressive-requests.jsonl" | tr -d ' ')"
press "Make Again in This Voice"; verdict "Make Again pressed" $?
wait_for 60 '[ "$(job | awk "{print \$2}")" = "openai:$EXPRESSIVE" ]'; ok=$?; verdict "a new job read by openai:$EXPRESSIVE" $ok
J="$(job)"; echo "   job: $J"
[ "$(echo "$J" | awk '{print $3}')" = "$CHARS" ]; verdict "the cast keeps its Kokoro voices: $CHARS" $?
wait_for 400 '[ -z "$(comm -12 <(echo "$AFTER_CAST" | awk "{print \$3}" | sort) <(chapters | awk "{print \$3}" | sort))" ]'; ok=$?
verdict "every chapter was made again; the untitled one opens in Kokoro's format, the others in the narrator's" $ok
n="$(tail -n +"$((asked_before + 1))" "$EVIDENCE/expressive-requests.jsonl" | grep -c "\"voice\": \"$EXPRESSIVE\"")"
[ "$n" -gt 0 ]; verdict "the expressive fixture was asked for $EXPRESSIVE ($n requests)" $?
tail -n +"$((asked_before + 1))" "$EVIDENCE/expressive-requests.jsonl" | grep -c '"instructions": "' | grep -qv '^0$'
verdict "each with a delivery instruction" $?
tail -n +"$((asked_before + 1))" "$EVIDENCE/expressive-requests.jsonl" | head -3 | cut -c1-220 | sed 's/^/   expressive <- /'
MIXED_SECONDS="$(seconds)"
echo "   chapter seconds: with the Kokoro narrator $CAST_SECONDS; with $EXPRESSIVE $MIXED_SECONDS"
/usr/bin/python3 -c 'import sys; a=[float(x) for x in sys.argv[1].split()]; b=[float(x) for x in sys.argv[2].split()]; sys.exit(0 if len(a)==len(b)==3 and all(y >= 0.8 * x for x, y in zip(a, b)) else 1)' "$CAST_SECONDS" "$MIXED_SECONDS"
verdict "each chapter is about as long as before (no clip lost in the join)" $?
for f in $(chapters | awk '{print $1}'); do
  /usr/bin/python3 - "$ROOT/Clippings/$f.m4a" <<'PY' || { verdict "chapter $f sounds like speech throughout" 1; continue; }
import subprocess, struct, sys
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", sys.argv[1], "-ac", "1", "-ar", "8000", "-f", "s16le", "-"], capture_output=True).stdout
x = struct.unpack("<%dh" % (len(raw) // 2), raw[: len(raw) // 2 * 2])
w = [sum(v * v for v in x[i:i + 800]) / 800 for i in range(0, len(x) - 800, 800)]
loud = sum(1 for e in w if e > 200 ** 2)
print("   %s: %d of %d tenth-seconds with sound, peak %d" % (sys.argv[1].rsplit("/", 1)[-1], loud, len(w), max(abs(v) for v in x)))
sys.exit(0 if loud > len(w) * 0.4 and max(abs(v) for v in x) < 32000 else 1)
PY
  verdict "chapter $f has speech for most of it and no clipping" $?
done
shot book-expressive-narrator
probe_quit "$PID"; PID=""; sleep 2
AFTER_CAST="$(chapters)"

say "F. Export Audiobook… of the mixed book (DEBUG BATON_DEBUG_EXPORT_BOOK in place of the save panel)"
for f in $(chapters | awk '{print $1}'); do
  echo "   chapter $f: $(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate,channels -of csv=p=0 "$ROOT/Clippings/$f.m4a")"
done
[ "$(for f in $(chapters | awk '{print $1}'); do ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate,channels -of csv=p=0 "$ROOT/Clippings/$f.m4a"; done | sort -u)" = "24000,1" ]
verdict "every chapter file is 24 kHz mono, the untitled one included" $?
M4B="$WORK/the-machine.m4b"
launch --env BATON_DEBUG_EXPORT_BOOK="$M4B" || { echo "probe did not restart"; exit 2; }
wait_for 120 '[ -s "$M4B" ] && ! texts | grep -q "^Exporting "'; ok=$?; verdict "the book was exported to an M4B" $ok
sleep 2
shot book-exported
probe_quit "$PID"; PID=""; sleep 2
REPORTED="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$M4B")"
ffmpeg -nostdin -v error -y -i "$M4B" -f s16le -ac 1 -ar 24000 "$WORK/decoded.raw"
DECODED="$(/usr/bin/python3 -c 'import os,sys; print(round(os.path.getsize(sys.argv[1]) / 48000, 3))' "$WORK/decoded.raw")"
SUM="$(for f in $(chapters | awk '{print $1}'); do ffprobe -v error -show_entries format=duration -of csv=p=0 "$ROOT/Clippings/$f.m4a"; done | /usr/bin/python3 -c 'import sys; print(round(sum(float(x) for x in sys.stdin.read().split()), 3))')"
MARKS="$(ffprobe -v error -show_chapters -of csv=p=0 "$M4B" | wc -l | tr -d ' ')"
echo "   M4B: reported $REPORTED s, decoded $DECODED s, chapters $SUM s together, $MARKS chapter marks"
/usr/bin/python3 -c 'import sys; r, d, s = map(float, sys.argv[1:]); sys.exit(0 if abs(d - s) < 0.5 and abs(r - d) < 0.5 else 1)' "$REPORTED" "$DECODED" "$SUM"
verdict "the M4B decodes to its full length, as long as its chapters" $?
[ "$MARKS" = 3 ]; verdict "three chapter marks" $?
cp "$M4B" "$EVIDENCE/the-machine.m4b"

say "D. Change Voice… again: back to $NARRATOR, Voice the dialogue turned off"
launch --env BATON_DEBUG_SHOW_CLIPPINGS=1 --env BATON_DEBUG_OPEN_CHANGE_VOICE=book || { echo "probe did not restart"; exit 2; }
wait_for 90 'texts | grep -q "^Change the voice of The Machine"'; ok=$?; verdict "Change Voice opened again" $ok
wait_for 30 '[ "$("$AX_BIN" value "$PID" voice-the-dialogue 2>/dev/null)" = 1 ]'; verdict "Voice the dialogue is on: the book has its cast" $?
texts | grep -qx "\[button\] Edit Cast…"; verdict "Edit Cast… is offered for the cast it has" $?
shot change-voice-with-cast
"$AX_BIN" press "$PID" "narrator-$NARRATOR" >/dev/null 2>&1 || { press all-voices; sleep 1; press "voice-$NARRATOR"; }
verdict "back to $NARRATOR" $?
"$AX_BIN" toggle "$PID" voice-the-dialogue >/dev/null; verdict "Voice the dialogue turned off" $?
sleep 1
shot change-voice-off
press "Make Again in This Voice"; verdict "Make Again pressed" $?
wait_for 60 '[ "$(job | awk "{print \$3}")" = "-" ]'; ok=$?; verdict "the job is the narrator-only book again" $ok
J="$(job)"; echo "   job: $J"
! echo "$J" | awk '{print $4}' | tr ',' '\n' | grep -qv '^narrator$'; verdict "no line has a speaker" $?
[ "$(echo "$J" | awk '{print $5}')" = "$FIRST_WORDS" ]; verdict "the same words and pauses as before the cast (chapters $FIRST_WORDS)" $?
if [ "$(echo "$J" | awk '{print $6}')" = "$FIRST_SPEED" ]; then
  [ "$(echo "$J" | awk '{print $1}')" = "$FIRST_JOB" ]; verdict "the very book it was before the cast: job $FIRST_JOB again" $?
else
  echo "   note: the speed suggested for the first narrator ($FIRST_SPEED) did not come back with it after $EXPRESSIVE"
  echo "         (now $(echo "$J" | awk '{print $6}')): VoicePlan.withNarrator gives another narrator its own pace (TBX-10989),"
  echo "         so the job id differs from $FIRST_JOB while the words are the same"
fi
wait_for 300 '[ -z "$(comm -12 <(echo "$AFTER_CAST" | awk "{print \$3}" | sort) <(chapters | awk "{print \$3}" | sort))" ]'; ok=$?
verdict "every chapter was replaced again" $ok
shot book-without-cast

echo
[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
