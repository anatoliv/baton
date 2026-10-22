#!/bin/bash
# The document clippings walk (M3), on a probe instance, never the owner's Baton:
#
#   KOKORO_URL=http://<kokoro-host>:8880 scripts/probe-documents-walk.sh <Baton.app> <book.pdf> <evidence-dir>
#
#   A. import the book through the import sheet (screenshot), Make Audiobook
#   B. chapter 1 lands in Clippings: how long it took
#   C. quit while chapter 2 renders, relaunch: it resumes, and Kokoro is asked for no chunk it
#      already answered (counted at a relay, not taken from the app's own log)
#   D. Kokoro stops answering mid-book: the row says paused, with the reason (screenshot); it
#      carries on when Kokoro is back, in the same voice
#   E. the book completes: every chapter in Clippings, the total requests against the chunk count
#
# Kokoro is reached through a relay on 127.0.0.1 that this script owns, so "Kokoro stops" is the
# relay stopping: the shared Kokoro host is never touched. The relay also counts every speech
# request, which is the independent check that nothing is synthesized twice.
#
# By default the probe gets a throwaway Navidrome on 127.0.0.1 with an empty library, the same way
# scripts/probe-handoff-e2e.sh does it (Docker and the deluan/navidrome image). NO_SERVER=1 runs
# with no music server at all, which is the case F1 fixed: books and Clippings need none.
# HOME_SERVER=1 makes the book on the home server instead (M5.6): set GATEWAY_URL; the probe gets
# the gateway token from the login Keychain item `baton-gateway-token` into its own Keychain
# service over stdin (never argv), the walk checks chapter 1 comes down into Clippings, and the
# test book is deleted from the server at the end. Stages C and D (quit, outage) are local only.
# The book may be a link (https://...), read as a web page. SHEET_ONLY=1 stops after the import
# sheet's screenshot, for checking what a new source reads as without making the book. HEAR=1
# also presses each narrator's Hear button there (M4.4), then stops without making the book.
# CAST=1 turns on "Voice the dialogue" (G4), waits for a model to write the cast list (a model
# must be set up: Ollama on this Mac will do), screenshots the sheet and the cast editor, presses
# Use This Cast and waits for the lines without a tag to be placed, and stops
# without making the book. CAST_MAKE=1 with CAST=1 then presses Make Audiobook, waits for
# chapter 1 in Clippings and writes the voices per speaker from the book's job.
#
# The walk brings the probe to the front for each screenshot, so anything typed in another app at
# that moment lands in the probe's window. Run it when nobody is typing.
#
# Exit 0 PASS, 1 FAIL, 2 could not run, 3 another probe holds the lock (probe-lib.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/probe-lib.sh

APP="${1:?usage: $0 <Baton.app> <book.pdf> <evidence-dir>}"
BOOK="${2:?book}"
EVIDENCE="${3:?evidence dir}"
: "${KOKORO_URL:?set KOKORO_URL to the Kokoro host (http://host:8880)}"
mkdir -p "$EVIDENCE"
EVIDENCE="$(cd "$EVIDENCE" && pwd -P)"
WORK="$(mktemp -d -t baton-docs-walk)"
case "$BOOK" in
  http://*|https://*) ;;   # a link: read as a web page (M8.1b)
  *)
    # The probe reads its own copy. A file under ~/Downloads (or Desktop, Documents) makes macOS
    # ask the probe for folder access the first time, and that prompt sits on the main thread
    # before the import sheet can open: the M5.6 walk failed on exactly that, twice, with a fresh
    # development build. The walk's temporary directory needs no permission.
    mkdir -p "$WORK/book"
    cp "$BOOK" "$WORK/book/$(basename "$BOOK")" || { echo "could not copy $BOOK"; exit 2; }
    BOOK="$WORK/book/$(basename "$BOOK")" ;;
esac
RELAY_PORT="${RELAY_PORT:-18880}"
CHAPTER1_LIMIT="${CHAPTER1_LIMIT:-180}"   # seconds; the spec says about two minutes

SUITE="$(probe_new_suite docs)"
ROOT="$PROBE_SUPPORT_ROOT/$SUITE"
COUNT_FILE="$EVIDENCE/relay-requests.txt"
RELAY_PID=""
GW_RELAY_PID=""
PID=""
NAME="baton-docs-walk-$$"
ND_PORT="${ND_PORT:-14533}"
fail=0
T0=$(date +%s)

cleanup() {
  probe_quit "$PID"
  [ -n "$RELAY_PID" ] && kill "$RELAY_PID" 2>/dev/null
  [ -n "$GW_RELAY_PID" ] && kill "$GW_RELAY_PID" 2>/dev/null
  # Keep one chapter for a person to listen to, then remove everything the probe made.
  first="$(ls "$ROOT"/Clippings/*.m4a 2>/dev/null | head -1)"
  [ -n "$first" ] && cp "$first" "$EVIDENCE/a-chapter.m4a"
  [ "${KEEP_PROBE:-0}" = 1 ] || probe_cleanup "$SUITE"
  docker rm -f "$NAME" >/dev/null 2>&1
  rm -rf "$WORK"
  probe_lock_release
}
trap cleanup EXIT
trap 'exit 130' INT TERM
probe_lock_acquire || exit 3

say() { printf '\n== %s (+%ss)\n' "$1" "$(( $(date +%s) - T0 ))"; }
verdict() { if [ "$2" = 0 ]; then echo "   PASS  $1"; else echo "   FAIL  $1"; fail=1; fi; }

# ---- the relay ----------------------------------------------------------------------------------
start_relay() {   # Kokoro: counts speech requests
  relay_process "$RELAY_PORT" "$KOKORO_URL" "$COUNT_FILE"
  RELAY_PID=$!
  sleep 0.5
}
# The gateway too goes through 127.0.0.1 in HOME_SERVER mode. Loopback is outside macOS's local
# network privacy, which otherwise stops a freshly built probe at "Allow Baton to find devices
# on local networks?" and, until a person answers, makes the gateway look offline, so the sheet
# offers only "This Mac" (seen 2026-10-14). The bytes still go to the real gateway on the deploy host.
GATEWAY_RELAY_PORT="${GATEWAY_RELAY_PORT:-18788}"
start_gateway_relay() {
  relay_process "$GATEWAY_RELAY_PORT" "$GATEWAY_URL" ""
  GW_RELAY_PID=$!
  sleep 0.5
}
relay_process() {   # $1 = local port, $2 = upstream URL, $3 = count file (empty: no counting)
  /usr/bin/python3 - "$1" "$2" "$3" <<'PY' &
import asyncio, sys, urllib.parse
port, upstream, count_file = int(sys.argv[1]), urllib.parse.urlparse(sys.argv[2]), sys.argv[3]
count = 0
if count_file:
    try: count = int(open(count_file).read().strip() or 0)
    except Exception: count = 0
async def pipe(reader, writer, counting):
    global count
    try:
        while data := await reader.read(65536):
            if counting and count_file:
                n = data.count(b"POST /v1/audio/speech")
                if n:
                    count += n
                    open(count_file, "w").write(str(count))
            writer.write(data); await writer.drain()
    except Exception: pass
    finally: writer.close()
async def handle(cr, cw):
    try: ur, uw = await asyncio.open_connection(upstream.hostname, upstream.port or 80)
    except Exception: cw.close(); return
    await asyncio.gather(pipe(cr, uw, True), pipe(ur, cw, False))
async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", port)
    async with server: await server.serve_forever()
asyncio.run(main())
PY
}
stop_relay() { kill "$RELAY_PID" 2>/dev/null; wait "$RELAY_PID" 2>/dev/null; RELAY_PID=""; }
requests() { cat "$COUNT_FILE" 2>/dev/null || echo 0; }

# ---- the probe ----------------------------------------------------------------------------------
launch() {   # $1 = file to import at launch, or empty
  # DEBUG hooks (BatonApp): open Clippings, and the import sheet for a file. Environment, never
  # launch arguments. Preference sync stays off: the shared document carries the
  # gateway address, so a syncing probe swaps its relay address for the owner's real one
  # (seen 2026-10-14) and could push its throwaway settings the other way.
  if [ -n "${1:-}" ]; then
    open -n -a "$APP" --env BATON_DEBUG_IMPORT_DOCUMENT="$1" --env BATON_DEBUG_PREFERENCE_SYNC=off --args -baton.defaultsSuite "$SUITE" || return 1
  else
    open -n -a "$APP" --env BATON_DEBUG_SHOW_CLIPPINGS=1 --env BATON_DEBUG_PREFERENCE_SYNC=off --args -baton.defaultsSuite "$SUITE" || return 1
  fi
  for _ in $(seq 1 40); do
    PID="$(pgrep -f -- "-baton.defaultsSuite $SUITE" | head -1)"; [ -n "$PID" ] && return 0; sleep 0.5
  done
  return 1
}

front() { osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null 2>&1; sleep 0.8; }

# Screenshot of the probe's main window only (sheets included, they sit inside its frame).
shot() {
  front
  local rect
  # The probe's largest window: after a relaunch "the window named Baton" can resolve to a small
  # auxiliary one, which captured the wrong region.
  rect="$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID)
    set best to \"\"
    set bestArea to 0
    repeat with w in windows
      set {x, y} to position of w
      set {wd, ht} to size of w
      if wd * ht > bestArea then
        set bestArea to wd * ht
        set best to (x as text) & \",\" & (y as text) & \",\" & (wd as text) & \",\" & (ht as text)
      end if
    end repeat
    return best
  end tell" 2>/dev/null)"
  if [ -n "$rect" ]; then screencapture -x -R "$rect" "$EVIDENCE/$1.png"; else screencapture -x "$EVIDENCE/$1.png"; fi
  echo "   screenshot: $EVIDENCE/$1.png"
}

press_in_window() {   # $1 = AX description or title of a button anywhere in the main window
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID)
    repeat with b in (entire contents of (first window whose name is \"Baton\"))
      try
        if class of b is button and ((description of b is \"$1\") or (title of b is \"$1\")) then
          perform action \"AXPress\" of b
          return \"pressed\"
        end if
      end try
    end repeat
    return \"not found\"
  end tell" 2>/dev/null
}

# Return to the probe only if the probe really is the frontmost app. System Events delivers a
# keystroke to whatever is in front, so an unguarded one can land in another app entirely.
probe_return() {
  front
  local frontpid
  frontpid="$(osascript -e 'tell application "System Events" to unix id of first process whose frontmost is true' 2>/dev/null)"
  if [ "$frontpid" != "$PID" ]; then
    echo "   the probe is not the frontmost app (pid $frontpid is), so no key was sent"
    return 1
  fi
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to keystroke return" >/dev/null
}

job_json() { ls "$ROOT"/Books/*/job.json 2>/dev/null | head -1; }

# "ready rendering queued" etc., one word per chapter, and the job status and pause reason.
job_state() {
  local f; f="$(job_json)"; [ -n "$f" ] || { echo "nojob"; return; }
  /usr/bin/python3 - "$f" <<'PY'
import json, sys
j = json.load(open(sys.argv[1]))
states = [next(iter(c)) if isinstance(c, dict) else c for c in j["chapters"]]
print(" ".join(states), "|", j["status"], "|", j.get("pauseReason") or "")
PY
}
chapters_total() { /usr/bin/python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['chapters']))" "$(job_json)"; }
# Distinct chunks: the cache is content-addressed (voice, speed, text), so a sentence the book
# repeats is synthesized once and reused, and that is the number Kokoro should be asked for.
distinct_chunks() {
  /usr/bin/python3 - "$(job_json)" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))["book"]
v = b["voices"]
keys = {(v["characters"].get(s.get("speaker") or "", v["narrator"]), v.get("speed"), s["text"])
        for c in b["chapters"] for s in c["segments"]}
print(len(keys))
PY
}
segments() { /usr/bin/python3 -c "import json,sys; j=json.load(open(sys.argv[1])); print(sum(len(c['segments']) for c in j['book']['chapters']))" "$(job_json)"; }
landed() { ls "$ROOT"/Clippings/*.m4a 2>/dev/null | wc -l | tr -d ' '; }

wait_for() {   # $1 = seconds, $2 = shell condition
  local limit=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$limit" ]; do eval "$2" && return 0; sleep 2; done
  return 1
}

app_log() {   # the probe's documents log since $1 (a `log show --start` date)
  /usr/bin/log show --start "$1" --style compact \
    --predicate "subsystem == \"io.tonebox.baton\" AND category == \"documents\"" 2>/dev/null \
    | grep -F "Baton[" | sed 's/^.*documents\] //'
}

# ---- a throwaway music server -----------------------------------------------------------------
if [ "${NO_SERVER:-0}" = 1 ]; then
  echo "   NO_SERVER=1: no music server; Clippings must still be reachable (F1)"
else
mkdir -p "$WORK/music" "$WORK/data"
docker run -d --name "$NAME" -p "127.0.0.1:$ND_PORT:4533" -v "$WORK/music:/music:ro" -v "$WORK/data:/data" \
  deluan/navidrome:latest >/dev/null || { echo "could not start the throwaway Navidrome"; exit 2; }
for _ in $(seq 1 60); do curl -sf "http://127.0.0.1:$ND_PORT/ping" >/dev/null && break; sleep 1; done
ND_USER="docs-walk"
ND_PASS="$(openssl rand -hex 12)"
curl -sf -X POST "http://127.0.0.1:$ND_PORT/auth/createAdmin" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$ND_USER\",\"password\":\"$ND_PASS\"}" >/dev/null || { echo "could not create the throwaway admin"; exit 2; }
# The legacy single-server keys: the app migrates them into its server list and moves the secret
# into the probe's own Keychain service on first launch (NavidromeConfig).
defaults write "$SUITE" tonebox.navidrome.url "http://127.0.0.1:$ND_PORT"
defaults write "$SUITE" tonebox.navidrome.username "$ND_USER"
defaults write "$SUITE" tonebox.navidromeSecret "$ND_PASS"
fi

# ---- the walk -----------------------------------------------------------------------------------
defaults write "$SUITE" baton.documents.enabled -bool true
if [ "${HOME_SERVER:-0}" = 1 ]; then
  : "${GATEWAY_URL:?set GATEWAY_URL to the gateway (http://host:8788) for HOME_SERVER=1}"
  start_gateway_relay
  defaults write "$SUITE" baton.agent.gatewayURL "http://127.0.0.1:$GATEWAY_RELAY_PORT"
  token="$(security find-generic-password -s baton-gateway-token -a baton -w 2>/dev/null)" || { echo "no gateway token in the Keychain"; exit 2; }
  # The token goes into the probe's preferences suite over stdin (a plist on `defaults import`'s
  # standard input: never argv), the same road the throwaway Navidrome password takes. On its
  # first read the app moves it into its own Keychain item under the probe's service and drops
  # the plaintext (NavidromeKeychain.secret, migrate-on-read). An item written here with the
  # `security` tool instead, even with `-T` naming the probe, raised the Keychain's "Baton wants
  # to access key" prompt on the main thread before the import sheet could open: that is why
  # the M5.6 walk failed (2026-10-03, twice; reproduced 2026-10-14).
  # Escaped for XML: a token is any string the gateway's README allows, not only hex.
  escaped="$(printf '%s' "$token" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>baton.agent.gatewayToken</key><string>%s</string></dict></plist>\n' "$escaped" \
    | defaults import "$SUITE" - || { echo "could not give the probe the gateway token"; exit 2; }
  unset escaped
  unset token
fi
defaults write "$SUITE" tonebox.speech.kokoroBaseURL "http://127.0.0.1:$RELAY_PORT"
echo 0 > "$COUNT_FILE"
start_relay
LOG_START="$(date '+%Y-%m-%d %H:%M:%S')"

say "A. import $(basename "$BOOK") through the import sheet"
launch "$BOOK" || { echo "probe did not start"; exit 2; }
wait_for 30 '[ "$(probe_sheet_count "$PID")" -ge 1 ] 2>/dev/null'; verdict "the import sheet opened" $?
sleep "${SHEET_SETTLE:-4}"   # the sheet reads the file, then shows what it found (and asks a model for a narrator)
[ "${CAST:-0}" = 1 ] || shot A-import-sheet   # CAST takes its own per-window shots
if [ "${HOME_SERVER:-0}" = 1 ] && [ "${SHEET_ONLY:-0}" != 1 ]; then
  probe_return || { verdict "Return reached the probe" 1; exit 1; }
  SUBMITTED=$(date +%s)
  say "H. chapter 1 is made on the home server and comes down into Clippings"
  wait_for 300 '[ "$(landed)" -ge 1 ]'; ok=$?
  verdict "chapter 1 collected from the home server after $(( $(date +%s) - SUBMITTED ))s" $ok
  ls "$ROOT"/Books/home-server-books.json >/dev/null 2>&1; verdict "the book is remembered as made on the home server" $?
  afinfo "$(ls "$ROOT"/Clippings/*.m4a | head -1)" 2>/dev/null | grep -E "estimated duration|bit rate" | sed 's/^/   /'
  press_in_window "Show chapters" >/dev/null; sleep 1
  shot H-book-row-home-server
  JOB="$(/usr/bin/python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['payload'][0]['jobID'])" "$ROOT/Books/home-server-books.json" 2>/dev/null)"
  if [ -n "$JOB" ]; then
    { printf 'header = "Authorization: Bearer %s"\n' "$(security find-generic-password -s baton-gateway-token -a baton -w 2>/dev/null)"; } \
      | curl -s -m 10 -K - -X DELETE "$GATEWAY_URL/v1/books/$JOB" -o /dev/null -w "   test book deleted from the home server: HTTP %{http_code}\n"
  fi
  [ "$fail" = 0 ] && echo "PASS (home server)" || echo "FAIL"
  exit "$fail"
fi
if [ "${HEAR:-0}" = 1 ]; then
  # M4.4: press each narrator's Hear button. The button must turn to Stop, Kokoro must be asked
  # for the opening (counted at the relay, not taken from the app), and it must read Hear again
  # when the preview ends. Pressed through the Accessibility API by process id (probe-ax), since
  # AppleScript's `entire contents` does not reach the sheet. Nothing is made.
  say "P. hear each suggested voice on the import sheet"
  AX_BIN="${TMPDIR:-/tmp}/baton-probe-ax-$(shasum scripts/probe-ax.swift | cut -c1-12)"
  [ -x "$AX_BIN" ] || xcrun swiftc -O -o "$AX_BIN" scripts/probe-ax.swift || { echo "could not build probe-ax"; exit 2; }
  hears="$("$AX_BIN" texts "$PID" | sed -n 's/^\[button\] \(Hear .*\)$/\1/p')"
  heard=0
  while IFS= read -r label <&3; do
    [ -n "$label" ] || continue
    before="$(requests)"
    "$AX_BIN" press "$PID" "$label" >/dev/null
    wait_for 10 '"$AX_BIN" texts "$PID" | grep -qx "\[button\] Stop"'; verdict "$label: the button turned to Stop" $?
    wait_for 30 '[ "$(requests)" -gt "$before" ]'; ok=$?
    verdict "$label: Kokoro was asked for the opening (speech requests $before -> $(requests))" $ok
    [ "$heard" = 0 ] && shot P-hear-playing
    wait_for 60 '"$AX_BIN" texts "$PID" | grep -qxF "[button] $label"'; verdict "$label: Hear again when the preview ended" $?
    if "$AX_BIN" texts "$PID" | grep -q "could not be played"; then verdict "$label: no playback failure shown" 1; fi
    heard=$((heard + 1))
  done 3<<< "$hears"
  [ "$heard" -ge 1 ]; verdict "$heard Hear buttons pressed" $?
fi
if [ "${CAST:-0}" = 1 ]; then
  # G4: the switch, the cast list a model writes, and the editor it is checked in. Driven through
  # the Accessibility API by process id (probe-ax), which reaches sheets. Nothing is made.
  # Screenshots are taken per window id (`screencapture -l`): a sheet is a window of its own, and
  # a screen region would also capture whatever another app has on top of the probe.
  say "G. voice the dialogue: the cast list and its editor"
  AX_BIN="${TMPDIR:-/tmp}/baton-probe-ax-$(shasum scripts/probe-ax.swift | cut -c1-12)"
  [ -x "$AX_BIN" ] || xcrun swiftc -O -o "$AX_BIN" scripts/probe-ax.swift || { echo "could not build probe-ax"; exit 2; }
  window_shots() {   # $1 = name: one PNG per on-screen window of the probe, largest first
    local n=0
    while read -r wid w h; do
      [ -n "$wid" ] || continue
      n=$((n + 1))
      screencapture -x -o -l "$wid" "$EVIDENCE/$1-$n.png" && echo "   screenshot: $EVIDENCE/$1-$n.png (${w}x${h})"
    done < <("$AX_BIN" windows "$PID")
  }
  "$AX_BIN" checkboxes "$PID" | sed 's/^/   /'
  [ "$("$AX_BIN" value "$PID" "voice-the-dialogue")" = 0 ]; verdict "Voice the dialogue is off for a new book" $?
  "$AX_BIN" toggle "$PID" "voice-the-dialogue" >/dev/null; verdict "Voice the dialogue turned on" $?
  wait_for "${CAST_WAIT:-240}" '"$AX_BIN" texts "$PID" | grep -qE "^\[button\] Check the Cast|narrator reads every line"'
  verdict "a cast list was written, or the sheet says why not" $?
  "$AX_BIN" texts "$PID" | grep -iE "cast|speaker|narrator reads" | sed 's/^/   /'
  window_shots G-import-sheet-cast
  "$AX_BIN" press "$PID" "Check the Cast…" >/dev/null
  wait_for 15 '"$AX_BIN" texts "$PID" | grep -qx "\[button\] Use This Cast"'; verdict "the cast editor opened" $?
  sleep 1
  window_shots G-cast-editor
  "$AX_BIN" texts "$PID" | grep -E "lines found|^\[button\] Hear" | sed 's/^/   /'
  # Use This Cast, then a model places the lines the rules leave; the sheet says what
  # happened in one line ("... have a speaker", or why the narrator reads them).
  "$AX_BIN" press "$PID" "Use This Cast" >/dev/null; verdict "Use This Cast pressed" $?
  wait_for "${PLACE_WAIT:-600}" '"$AX_BIN" texts "$PID" | grep -qE "lines have a speaker|the narrator reads those"'
  verdict "the lines without a tag were placed, or the sheet says why not" $?
  "$AX_BIN" texts "$PID" | grep -E "have a speaker|narrator reads those|speakers," | sed 's/^/   /'
  window_shots G-import-sheet-placed
  if [ "${CAST_MAKE:-0}" != 1 ]; then
    [ "$fail" = 0 ] && echo "PASS (cast sheet)" || echo "FAIL"
    exit "$fail"
  fi
  # CAST_MAKE=1: go on and make the book on this Mac with the checked cast, wait for
  # chapter 1 in Clippings, and read who read what from the book's own job record.
  say "M. Make Audiobook with the checked cast"
  "$AX_BIN" press "$PID" "Make Audiobook" >/dev/null; verdict "Make Audiobook pressed" $?
  wait_for 30 '[ -n "$(job_json)" ]'; verdict "Make Audiobook submitted the book" $?
  SUBMITTED=$(date +%s)
  wait_for "${CAST_RENDER_WAIT:-900}" '[ "$(landed)" -ge 1 ]'; ok=$?
  verdict "chapter 1 in Clippings after $(( $(date +%s) - SUBMITTED ))s" $ok
  echo "   job: $(job_state)"
  afinfo "$(ls "$ROOT"/Clippings/*.m4a | head -1)" 2>/dev/null | grep -E "estimated duration|bit rate" | sed 's/^/   /'
  cp "$(job_json)" "$EVIDENCE/job.json" 2>/dev/null
  # Voices per speaker as the renderer resolves them (VoicePlan.voice: the speaker's voice, or
  # the narrator's), counted over the segments of the book.
  /usr/bin/python3 - "$(job_json)" <<'PY2' | tee "$EVIDENCE/voices-per-speaker.txt" | sed 's/^/   /'
import json, sys, collections
b = json.load(open(sys.argv[1]))["book"]
v = b["voices"]
print("narrator:", v["narrator"])
for name, voice in sorted(v["characters"].items()):
    print("character:", name, "->", voice)
per = collections.Counter()
voices = collections.Counter()
for c in b["chapters"]:
    for s in c["segments"]:
        sp = s.get("speaker")
        voice = v["characters"].get(sp or "", v["narrator"])
        per[(sp or "(narrator)", voice)] += 1
        voices[voice] += 1
print("segments by speaker:")
for (sp, voice), n in sorted(per.items(), key=lambda x: -x[1]):
    print(f"  {n:4d}  {sp}  [{voice}]")
print("distinct voices in the rendered book:", len(voices), dict(voices))
sys.exit(0 if len(voices) >= 2 else 1)
PY2
  verdict "the book is read in more than one voice" "${PIPESTATUS[0]}"
  "$AX_BIN" press "$PID" "Show chapters" >/dev/null
  sleep 1
  window_shots M-book-in-clippings
  app_log "$LOG_START" > "$EVIDENCE/documents.log"
  grep -E "ready|submitted|Clippings|cast|voice" "$EVIDENCE/documents.log" | sed 's/^/   /' | head -40
  [ "$fail" = 0 ] && echo "PASS (cast book made)" || echo "FAIL"
  exit "$fail"
fi
if [ "${SHEET_ONLY:-0}" = 1 ] || [ "${HEAR:-0}" = 1 ]; then
  # Only what the import sheet found (a real article, a new format): nothing is made.
  [ "$fail" = 0 ] && echo "PASS (sheet only)" || echo "FAIL"
  exit "$fail"
fi
# Return, the sheet's default action (Make Audiobook): SwiftUI's sheet contents are not in the
# probe's accessibility tree, so the button cannot be pressed by name.
probe_return || { verdict "Return reached the probe" 1; exit 1; }
wait_for 15 '[ -n "$(job_json)" ]'; verdict "Make Audiobook submitted the book" $?
SUBMITTED=$(date +%s)

say "B. chapter 1 lands in Clippings"
wait_for "$CHAPTER1_LIMIT" '[ "$(landed)" -ge 1 ]'
ok=$?; took=$(( $(date +%s) - SUBMITTED ))
verdict "chapter 1 in Clippings after ${took}s (limit ${CHAPTER1_LIMIT}s)" $ok
echo "   job: $(job_state)"
afinfo "$(ls "$ROOT"/Clippings/*.m4a | head -1)" 2>/dev/null | grep -E "estimated duration|bit rate|Data format" | sed 's/^/   /'
press_in_window "Show chapters" >/dev/null
sleep 1
shot B-book-row

say "C. quit while chapter 2 renders, then relaunch"
wait_for 60 'job_state | grep -q "^ready rendering"'; verdict "chapter 2 is rendering" $?
sleep 20
before_quit="$(requests)"
echo "   requests reaching Kokoro so far: $before_quit; job: $(job_state)"
probe_quit "$PID"; PID=""
sleep 2
launch "" || { echo "probe did not relaunch"; exit 2; }
wait_for 240 'job_state | grep -q "^ready ready"'; verdict "chapter 2 finished after the relaunch" $?
echo "   job: $(job_state)"

say "D. Kokoro stops answering mid-book"
wait_for 60 'job_state | grep -q "^ready ready rendering"'; verdict "chapter 3 is rendering" $?
sleep 5
stop_relay
wait_for 60 'job_state | grep -q "| paused |"'; verdict "the book says paused" $?
echo "   job: $(job_state)"
sleep 3
shot D-paused-row
wait_for 10 'false'   # a few retries against nothing: none of them may reach Kokoro or switch voice
start_relay
wait_for 60 'job_state | grep -q "| rendering |"'; verdict "it resumed by itself when Kokoro was back" $?

say "E. the book completes"
wait_for 600 'job_state | grep -q "| ready |"'; verdict "every chapter rendered" $?
wait_for 30 '[ "$(landed)" -ge "$(chapters_total)" ]'; verdict "every chapter is in Clippings" $?
echo "   chapters in Clippings: $(landed); job: $(job_state)"
total_segments="$(segments)"
distinct="$(distinct_chunks)"
total_requests="$(requests)"
echo "   chunks in the book: $total_segments, distinct: $distinct; speech requests that reached Kokoro: $total_requests"
# Two interruptions (the quit and the outage) can each cut one request in flight, which was
# never stored and is asked for again: concurrency is 1, so at most 2 extra, and never fewer.
extra=$(( total_requests - distinct ))
[ "$extra" -ge 0 ] && [ "$extra" -le 2 ]
verdict "no stored chunk synthesized twice ($extra re-asked after an interruption, at most 2 allowed)" $?
shot E-book-complete

say "the probe's own log"
app_log "$LOG_START" | tee "$EVIDENCE/documents.log" | grep -E "ready|paused|resumed|submitted|Clippings" | sed 's/^/   /'
grep -h "voice" "$(job_json)" >/dev/null 2>&1 && \
  /usr/bin/python3 -c "import json,sys; print('   narrator:', json.load(open(sys.argv[1]))['book']['voices']['narrator'])" "$(job_json)"

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
