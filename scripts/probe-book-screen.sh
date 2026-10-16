#!/bin/bash
# Every function of the Mac's book screen, exercised on a probe instance (TBX-11063), never the
# owner's Baton:
#
#   KOKORO_URL=http://<kokoro-host>:8880 scripts/probe-book-screen.sh <Baton.app> <evidence-dir>
#
# A three-chapter book is made on this Mac with the real Kokoro voice (through a relay on
# 127.0.0.1 this script owns), so its chapters are real speech with real read-along timing. Then
# the open book is driven through the Accessibility API by process id, and every claim is read
# back from the probe itself: its window (screenshots, `probe-ax texts`), its own MCP server
# (`baton://now-playing` for the player's state and playhead) and its files (Clippings, the
# read-along store). Stages, in order, each printing PASS or FAIL lines:
#
#   make      import the book and make it; the status line while it is made
#   button    Play, then Pause and Resume on the same button without moving the playhead, and
#             "% heard" and the bar following the playhead
#   chapters  a double-click and the context menu on the chapter in the player toggle it; on
#             another chapter they play from there
#   list      Back (Command-[), the row's bars, the row's menu (Pause/Resume, Read Along, the More
#             items), the row opening the book
#   readalong Read Along follows the audio: the timing against the speech onsets in the chapter's
#             own audio, the lit sentence against the playhead (scripts/probe-readalong-measure.py),
#             a pressed sentence, Done
#   restore   a chapter left paused, then the app quit and opened again: Resume plays on from
#             that place (the next chapter starts when the audio left runs out) and Read Along
#             follows it
#   menus     More: Show in Finder, Export Audiobook…, Pronunciations…, Change Voice… and Stop
#             Making Again, Keep on This Mac, Remove Download and Render Again (book and
#             chapter), Delete Book… (Cancel, then Remove from This Mac)
#
# STAGES="button readalong" runs a subset against a book already made: pass BOOK_SUITE=<suite>
# from an earlier run that set KEEP_PROBE=1. No music server and no gateway: books need neither.
# Preference sync is off.
#
# Exit 0 PASS, 1 FAIL, 2 could not run, 3 another probe holds the lock (probe-lib.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/probe-lib.sh

APP="${1:?usage: $0 <Baton.app> <evidence-dir>}"
EVIDENCE="${2:?evidence dir}"
: "${KOKORO_URL:?set KOKORO_URL to the Kokoro host (http://host:8880)}"
STAGES="${STAGES:-make button chapters list readalong restore menus}"
mkdir -p "$EVIDENCE"
EVIDENCE="$(cd "$EVIDENCE" && pwd -P)"
WORK="$(mktemp -d -t baton-book-screen)"
RELAY_PORT="${RELAY_PORT:-18882}"
SUITE="${BOOK_SUITE:-$(probe_new_suite bookscreen)}"
ROOT="$PROBE_SUPPORT_ROOT/$SUITE"
TITLE="Probe Machine"
RELAY_PID=""
PID=""
fail=0
T0=$(date +%s)

AX_BIN="${TMPDIR:-/tmp}/baton-probe-ax-$(shasum scripts/probe-ax.swift | cut -c1-12)"
[ -x "$AX_BIN" ] || xcrun swiftc -O -o "$AX_BIN" scripts/probe-ax.swift || { echo "could not build probe-ax"; exit 2; }

cleanup() {
  probe_quit "$PID"
  [ -n "$RELAY_PID" ] && kill "$RELAY_PID" 2>/dev/null
  if [ "${KEEP_PROBE:-0}" = 1 ]; then echo "kept: BOOK_SUITE=$SUITE"; else probe_cleanup "$SUITE"; fi
  rm -rf "$WORK"
  probe_lock_release
}
trap cleanup EXIT
trap 'exit 130' INT TERM
probe_lock_acquire || exit 3

say() { printf '\n== %s (+%ss)\n' "$1" "$(( $(date +%s) - T0 ))"; }
# Callers read the condition's status into rc before calling: a message holding $(...) would
# otherwise replace $? with the status of its own substitution.
verdict() { if [ "$2" = 0 ]; then echo "   PASS  $1"; else echo "   FAIL  $1"; fail=1; fi; }
note() { echo "   note  $1"; }
wait_for() {   # $1 = seconds, $2 = shell condition
  local limit=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$limit" ]; do eval "$2" && return 0; sleep 0.3; done
  return 1
}
front() { osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null 2>&1; sleep 0.6; }
shot() {   # $1 = name: the probe's largest window alone
  front
  local id; id="$("$AX_BIN" windows "$PID" 2>/dev/null | head -1 | cut -d' ' -f1)"
  if [ -n "$id" ]; then screencapture -x -o -l "$id" "$EVIDENCE/$1.png"; else screencapture -x "$EVIDENCE/$1.png"; fi
  echo "   screenshot: $EVIDENCE/$1.png"
}
rows() { "$AX_BIN" texts "$PID" 2>/dev/null; }
shows() { rows | grep -qxF "$1"; }
mentions() { rows | grep -qF "$1"; }
button() { rows | grep -qxF "[button] $1"; }
main_button() { "$AX_BIN" title "$PID" book-play 2>/dev/null; }   # the book's own button, not the transport's
heard() { rows | grep -oE '^(Under 1|[0-9]+)% heard$' | head -1; }
dump() { echo "   what Accessibility sees:"; rows | head -80 | sed 's/^/     /'; }
landed() { ls "$ROOT"/Clippings/*.m4a 2>/dev/null | wc -l | tr -d ' '; }
timings() { ls "$ROOT"/Books/read-along/*.json 2>/dev/null | wc -l | tr -d ' '; }
# Every synthetic click and key press goes through the guard: the probe's own process must be
# the frontmost app and a click's point must be inside its window, checked immediately before
# the action (after another lane's clicks landed in the owner's app). A refusal stops the run.
refuse() { echo "STOPPED: $1"; echo "FAIL"; exit 4; }
key() {   # $1 = AppleScript keystroke clause, to the probe in front
  front
  "$AX_BIN" guard "$PID" || refuse "a key press ($1) was refused: the probe is not the frontmost app"
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to $1" >/dev/null 2>&1
}
click() {   # $1 = cliclick verb (c, dc), $2 = x,y
  [ -n "$2" ] || return 1
  "$AX_BIN" guard "$PID" "$2" || refuse "a click at $2 was refused: the probe is not in front there"
  cliclick "$1:$2" >/dev/null 2>&1
}
# Whether a Finder window shows this probe's Clippings folder; nothing else of Finder is read.
finder_shows_probe() {
  osascript - "$ROOT/Clippings" <<'AS' 2>/dev/null
on run argv
  set wanted to item 1 of argv
  tell application "Finder"
    repeat with w in Finder windows
      try
        if (POSIX path of (target of w as alias)) starts with wanted then return "yes"
      end try
    end repeat
  end tell
  return "no"
end run
AS
}
close_probe_finder() {
  osascript - "$ROOT" <<'AS' >/dev/null 2>&1
on run argv
  set wanted to item 1 of argv
  tell application "Finder"
    repeat with w in (Finder windows)
      try
        if (POSIX path of (target of w as alias)) starts with wanted then close w
      end try
    end repeat
  end tell
end run
AS
}
now() {   # "<position seconds> <state> <title>" from the probe's own MCP server
  /usr/bin/python3 - "$ROOT/mcp.json" <<'PY'
import json, subprocess, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("? no-mcp"); sys.exit()
cfg = 'header = "Authorization: Bearer %s"\n' % d["token"]
def call(body, sid=None, headers=False):
    args = ["curl", "-s", "-m", "6", "-K", "-", "-X", "POST", d["url"],
            "-H", "Content-Type: application/json", "-H", "Accept: application/json, text/event-stream"]
    args += ["-D", "-"] if headers else []
    args += ["-H", "Mcp-Session-Id: " + sid] if sid else []
    args += ["-d", body]
    return subprocess.run(args, input=cfg, capture_output=True, text=True).stdout
init = call('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}', headers=True)
sid = next((l.split(":", 1)[1].strip() for l in init.splitlines() if l.lower().startswith("mcp-session-id:")), None)
body = call('{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"baton://now-playing"}}', sid)
try:
    n = json.loads(json.loads(body)["result"]["contents"][0]["text"])
    print(n.get("position_seconds", "?"), n.get("state", "?"), (n.get("now_playing") or {}).get("title", ""))
except Exception:
    print("? ? " + body[:160].replace("\n", " "))
PY
}
state() { now | cut -d' ' -f2; }
pos() { now | cut -d' ' -f1; }
playing_title() { now | cut -d' ' -f3-; }
close_to() { /usr/bin/python3 -c "import sys; sys.exit(0 if abs(float(sys.argv[1]) - float(sys.argv[2])) <= float(sys.argv[3]) else 1)" "$1" "$2" "$3" 2>/dev/null; }
greater() { /usr/bin/python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) > float(sys.argv[2]) else 1)" "$1" "$2" 2>/dev/null; }

launch() {   # extra --env pairs
  open -n -a "$APP" --env BATON_DEBUG_PREFERENCE_SYNC=off "$@" --args -baton.defaultsSuite "$SUITE" || return 1
  PID=""
  for _ in $(seq 1 40); do
    PID="$(pgrep -f -- "-baton.defaultsSuite $SUITE" | head -1)"; [ -n "$PID" ] && break; sleep 0.5
  done
  [ -n "$PID" ] || return 1
  wait_for 30 '[ -f "$ROOT/mcp.json" ] && [ "$(probe_mcp_status "$SUITE")" = 200 ]'
}
relaunch() { probe_quit "$PID"; PID=""; sleep 1; launch "$@"; }
open_book() {   # launch on the open book, paused at nothing
  relaunch --env BATON_DEBUG_OPEN_BOOK=1 || { echo "probe did not start"; exit 2; }
  wait_for 30 'shows "The Tube"' || { dump; return 1; }
}

# ---- the relay to Kokoro ------------------------------------------------------------------------
/usr/bin/python3 - "$RELAY_PORT" "$KOKORO_URL" <<'PY' &
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
defaults write "$SUITE" baton.documents.enabled -bool true
defaults write "$SUITE" baton.documents.voiceEngine server
defaults write "$SUITE" baton.documents.makeBooksOn thisMac
defaults write "$SUITE" tonebox.speech.kokoroBaseURL "http://127.0.0.1:$RELAY_PORT"

stage_make() {
  say "make: import a three-chapter book and make it on this Mac with Kokoro"
  local book="$WORK/book/$TITLE.md"
  mkdir -p "$WORK/book"
  cat > "$book" <<'MD'
# Probe Machine

## The Cell

Imagine, if you can, a small room, hexagonal in shape, like the cell of a bee.

It is lighted neither by window nor by lamp, yet it is filled with a soft radiance.

There are no apertures for ventilation, yet the air is fresh.

An armchair is in the centre, and by its side a reading desk.

## The Tube

The airship rose from the tube without a sound, and the lights of the city fell away below.

She sat by the window and looked at nothing, for there was nothing that she wished to see.

The stewardess asked if she would like the blind drawn, and she said that she would.

## The Surface

The light at the top was grey, and the hills were bare.

He waited a long while for the wind to drop before he climbed.

When at last he stood on the ridge, the sky was enormous and quite empty.
MD
  launch --env BATON_DEBUG_IMPORT_DOCUMENT="$book" || { echo "probe did not start"; exit 2; }
  wait_for 60 'button "Make Audiobook"'; rc=$?; verdict "the import sheet offers Make Audiobook" $rc
  sleep "${SHEET_SETTLE:-4}"
  "$AX_BIN" press "$PID" "Make Audiobook" >/dev/null; rc=$?; verdict "Make Audiobook pressed" $rc
  wait_for 60 'rows | grep -qE "^(Making|Waiting to make|Finishing) chapter"'
  rc=$?; verdict "while it is made, the status line says so: $(rows | grep -E '^(Making|Waiting to make|Finishing) chapter' | head -1)" $rc
  shot make-1-status-line
  wait_for "${RENDER_WAIT:-300}" '[ "$(landed)" -ge 3 ] && [ "$(timings)" -ge 3 ]'
  rc=$?; verdict "3 chapters in Clippings ($(landed)), 3 read-along timings kept ($(timings))" $rc
  sleep 2
  ! rows | grep -qE "^(Making|Waiting to make|Finishing) chapter"; rc=$?; verdict "the status line is gone once the book is made" $rc
  shot make-2-made
}

stage_button() {
  say "button: Play, Pause and Resume on the open book"
  open_book; rc=$?; verdict "the open book shows its chapters" $rc
  # A fresh book offers Play; one already heard (an earlier stage, or a book restored paused in
  # the player at launch) offers Resume, with "% heard".
  local first; first="$(main_button)"
  { [ "$first" = Play ] && [ -z "$(heard)" ]; } || { [ "$first" = Resume ] && [ -n "$(heard)" ]; }
  rc=$?; verdict "the button is Play for a fresh book, Resume with \"% heard\" for one begun (got: $first, '$(heard)')" $rc
  shot button-1-play
  "$AX_BIN" press "$PID" "book-play" >/dev/null; rc=$?; verdict "Play pressed" $rc
  wait_for 15 '[ "$(state)" = playing ]'; rc=$?; verdict "the book plays: $(now)" $rc
  wait_for 5 '[ "$(main_button)" = Pause ]'; rc=$?; verdict "the button is now Pause (got: $(main_button))" $rc
  sleep 4
  local h1; h1="$(heard)"
  [ -n "$h1" ]; rc=$?; verdict "\"% heard\" follows the playhead while it plays (got: '$h1' at $(pos) s)" $rc
  "$AX_BIN" frame "$PID" "book-heard-bar" >/dev/null 2>&1; note "the bar is drawn: $([ $? = 0 ] && echo yes || echo no)"
  shot button-2-playing-pause
  local p1; p1="$(pos)"
  "$AX_BIN" press "$PID" "book-play" >/dev/null; rc=$?; verdict "Pause pressed" $rc
  wait_for 5 '[ "$(state)" = paused ]'; rc=$?; verdict "the player paused: $(now)" $rc
  local p2; p2="$(pos)"
  greater "$p2" "$(echo "$p1 - 0.01" | bc)"; rc=$?; verdict "pausing kept the playhead ($p1 -> $p2 s)" $rc
  wait_for 5 '[ "$(main_button)" = Resume ]'; rc=$?; verdict "the button is now Resume (got: $(main_button))" $rc
  shot button-3-paused-resume
  sleep 3
  "$AX_BIN" press "$PID" "book-play" >/dev/null; rc=$?; verdict "Resume pressed" $rc
  wait_for 5 '[ "$(state)" = playing ]'; rc=$?; verdict "the player carries on: $(now)" $rc
  local p3; p3="$(pos)"
  close_to "$p3" "$p2" 1.0; rc=$?; verdict "from where it paused, not the saved place ($p2 -> $p3 s)" $rc
  local chapter; chapter="$(playing_title)"
  [ -n "$chapter" ]; rc=$?; verdict "the same chapter plays on ($chapter)" $rc
  sleep 6
  local h2; h2="$(heard)"
  [ "$h2" != "$h1" ]; rc=$?; verdict "\"% heard\" moved on while playing ('$h1' -> '$h2')" $rc
  # Before TBX-11063 a press here queued the book again from the place saved up to 5 s ago.
  local p4; p4="$(pos)"
  "$AX_BIN" press "$PID" "book-play" >/dev/null
  wait_for 5 '[ "$(state)" = paused ]'; rc=$?; verdict "a press while it plays pauses it, at $(pos) s (was $p4 s)" $rc
  local p5; p5="$(pos)"
  greater "$p5" "$(echo "$p4 - 0.3" | bc)"; rc=$?; verdict "no jump back ($p4 -> $p5 s)" $rc
  shot button-4-paused-again
}

stage_chapters() {
  say "chapters: double-click and the context menu"
  [ -n "$PID" ] || open_book
  # The book in the player, paused: chapter 1 from the open book's menu when nothing is.
  if [ -z "$(playing_title)" ] || [ "$(state)" = stopped ]; then
    "$AX_BIN" menu "$PID" "The Cell" "Play" >/dev/null
    wait_for 10 '[ "$(state)" = playing ]'
  fi
  [ "$(state)" = paused ] || probe_mcp_tool "$SUITE" music_pause >/dev/null
  wait_for 5 '[ "$(state)" = paused ]'
  local cur; cur="$(playing_title)"
  [ -n "$cur" ] || refuse "nothing is in the player to toggle"
  local other="The Surface"; [ "$cur" = "The Surface" ] && other="The Cell"
  local here; here="$(now)"
  local items; items="$("$AX_BIN" menuitems "$PID" "$cur" 2>&1 | tr '\n' '|')"
  echo "$items" | grep -q '^Resume|'; rc=$?; verdict "the paused chapter in the player ($cur): its menu leads with Resume ($items)" $rc
  "$AX_BIN" menu "$PID" "$cur" "Resume" >/dev/null; rc=$?; verdict "Resume from its menu" $rc
  wait_for 5 '[ "$(state)" = playing ]'; rc=$?; verdict "it carries on: $(now) (was $here)" $rc
  items="$("$AX_BIN" menuitems "$PID" "$cur" 2>&1 | tr '\n' '|')"
  echo "$items" | grep -q '^Pause|'; rc=$?; verdict "playing, its menu leads with Pause ($items)" $rc
  local xy; xy="$("$AX_BIN" frame "$PID" "$cur")"
  front
  local p0; p0="$(pos)"
  click dc "$xy"; rc=$?; verdict "double-click on the playing chapter at $xy" $rc
  wait_for 5 '[ "$(state)" = paused ]'; rc=$?; verdict "pauses it: $(now)" $rc
  local p1; p1="$(pos)"
  ! greater "$p0" "$(echo "$p1 + 1.5" | bc)"; rc=$?; verdict "where it was, not its saved place ($p0 -> $p1 s)" $rc
  click dc "$xy"
  wait_for 5 '[ "$(state)" = playing ]'; rc=$?; verdict "a second double-click carries on: $(now)" $rc
  close_to "$(pos)" "$p1" 1.5; rc=$?; verdict "from the same place ($p1 -> $(pos) s)" $rc
  [ "$(playing_title)" = "$cur" ]; rc=$?; verdict "the same chapter ($(playing_title))" $rc
  items="$("$AX_BIN" menuitems "$PID" "$other" 2>&1 | tr '\n' '|')"
  echo "$items" | grep -q '^Play|'; rc=$?; verdict "another chapter's menu leads with Play ($other: $items)" $rc
  xy="$("$AX_BIN" frame "$PID" "$other")"
  front
  click dc "$xy"; rc=$?; verdict "double-click on $other at $xy" $rc
  wait_for 10 '[ "$(playing_title)" = "$other" ]'; rc=$?; verdict "plays $other: $(now)" $rc
  sleep 1.5
  shot chapters-1-other-playing
  "$AX_BIN" menu "$PID" "The Tube" "Play" >/dev/null; rc=$?; verdict "Play from The Tube's menu" $rc
  wait_for 10 '[ "$(playing_title)" = "The Tube" ]'; rc=$?; verdict "plays The Tube: $(now)" $rc
  probe_mcp_tool "$SUITE" music_pause >/dev/null
}

stage_list() {
  say "list: Back, the row, its bars and its menu"
  [ -n "$PID" ] || open_book
  probe_mcp_tool "$SUITE" music_resume >/dev/null
  wait_for 5 '[ "$(state)" = playing ]'
  key 'keystroke "[" using command down'
  wait_for 5 '! shows "The Tube" && mentions "'"$TITLE"'"'; rc=$?; verdict "Command-[ goes back to the list" $rc
  sleep 1
  shot list-1-row-playing
  local items; items="$("$AX_BIN" menuitems "$PID" "$TITLE" 2>&1 | tr '\n' '|')"
  echo "   row menu: $items"
  echo "$items" | grep -q '^Open|Pause|Read Along|'; rc=$?; verdict "the row's menu: Open, Pause (the book plays), Read Along" $rc
  for want in "Show in Finder" "Export Audiobook…" "Pronunciations…" "Change Voice…" "Remove Download" "Keep on This Mac" "Delete Book…"; do
    echo "$items" | grep -qF "|$want|"; rc=$?; verdict "the row's menu has $want" $rc
  done
  "$AX_BIN" menu "$PID" "$TITLE" "Pause" >/dev/null; rc=$?; verdict "Pause from the row's menu" $rc
  wait_for 5 '[ "$(state)" = paused ]'; rc=$?; verdict "paused: $(now)" $rc
  items="$("$AX_BIN" menuitems "$PID" "$TITLE" 2>&1 | tr '\n' '|')"
  echo "$items" | grep -q '^Open|Resume|'; rc=$?; verdict "now the row offers Resume ($items)" $rc
  "$AX_BIN" menu "$PID" "$TITLE" "Open" >/dev/null; rc=$?; verdict "Open from the row's menu" $rc
  wait_for 5 'shows "The Tube"'; rc=$?; verdict "opens the book" $rc
  "$AX_BIN" press "$PID" "books-back" >/dev/null; rc=$?; verdict "the back button" $rc
  wait_for 5 '! shows "The Tube"'; rc=$?; verdict "the list again" $rc
  front
  click c "$("$AX_BIN" frame "$PID" "$TITLE")"
  wait_for 5 'shows "The Tube"'; rc=$?; verdict "a click on the row opens the book" $rc
}

stage_readalong() {
  say "readalong: the lit sentence follows the audio"
  open_book
  # Chapter 1 from its start, paused, then Read Along from the open book.
  "$AX_BIN" menu "$PID" "The Cell" "Play" >/dev/null || "$AX_BIN" menu "$PID" "The Cell" "Resume" >/dev/null
  wait_for 10 '[ "$(playing_title)" = "The Cell" ] && [ "$(state)" = playing ]'
  probe_mcp_tool "$SUITE" music_pause >/dev/null
  "$AX_BIN" press "$PID" "Read Along" >/dev/null; rc=$?; verdict "Read Along pressed" $rc
  wait_for 10 'mentions "Imagine, if you can"'; rc=$?; verdict "Read Along shows chapter 1's words" $rc
  local sha; sha="$(/usr/bin/python3 - "$ROOT" <<'PY2'
import glob, json, os, sys
for f in glob.glob(os.path.join(sys.argv[1], "Clippings", "*.json")):
    try: c = json.load(open(f))
    except Exception: continue
    c = c.get("payload", c)
    if c.get("chapterIndex") == 0 and c.get("sha256"): print(c["sha256"]); break
PY2
)"
  local m4a; m4a="$(grep -l "$sha" "$ROOT"/Clippings/*.json | head -1)"; m4a="${m4a%.json}.m4a"
  local timing="$EVIDENCE/readalong-timing-ch1.json"
  cp "$ROOT/Books/read-along/$sha.json" "$timing"
  # The timing against the chapter's own audio: where speech starts after each pause.
  /usr/bin/python3 - "$timing" "$m4a" <<'PY2' | tee "$EVIDENCE/readalong-audio.txt" | sed 's/^/   /'
import array, json, statistics, subprocess, sys
segs = json.load(open(sys.argv[1]))["segments"]
pcm = subprocess.run(["ffmpeg", "-v", "error", "-i", sys.argv[2], "-ac", "1", "-ar", "24000", "-f", "s16le", "-"],
                     capture_output=True).stdout
a = array.array("h"); a.frombytes(pcm)
hop = 240
env = [max((abs(x) for x in a[i:i + hop]), default=0) for i in range(0, len(a), hop)]
thr = max(env) * 0.04
onsets, quiet = [], 0
for k, v in enumerate(env):
    if v < thr: quiet += 1
    else:
        if quiet >= 15: onsets.append(k * hop / 24000)
        quiet = 0
offs = []
for s in segs[1:]:
    near = min(onsets, key=lambda o: abs(o - s["start"])) if onsets else None
    if near is not None and abs(near - s["start"]) < 1.0: offs.append(near - s["start"])
print(f"timing vs the audio: {len(offs)} of {len(segs) - 1} sentence starts matched to a speech onset after a pause; "
      f"onset minus timing median {statistics.median(offs) if offs else float('nan'):+.3f} s, worst "
      f"{max(offs, key=abs) if offs else float('nan'):+.3f} s; audio {len(a) / 24000:.2f} s, timing ends {segs[-1]['end']:.2f} s")
sys.exit(0 if offs and max(abs(o) for o in offs) < 0.1 and abs(len(a) / 24000 - segs[-1]["end"]) < 0.2 else 1)
PY2
  rc=${PIPESTATUS[0]}; verdict "the timing matches the chapter's audio (readalong-audio.txt)" $rc
  # Play, and hold the lit sentence against the playhead for 14 s.
  probe_mcp_tool "$SUITE" music_resume >/dev/null
  wait_for 5 '[ "$(state)" = playing ]'
  /usr/bin/python3 scripts/probe-readalong-measure.py "$AX_BIN" "$PID" "$ROOT/mcp.json" "$timing" 14 \
    | tee "$EVIDENCE/readalong-follow.txt" | sed 's/^/   /'
  rc=${PIPESTATUS[0]}; verdict "the lit sentence follows the playhead (readalong-follow.txt)" $rc
  shot readalong-1-following
  # Press sentence 3: the player seeks to where it starts, and it is lit.
  local target; target="$(/usr/bin/python3 -c "import json,sys; s=json.load(open(sys.argv[1]))['segments']; print(f\"{s[2]['start']:.3f}\t{s[2]['text']}\")" "$timing")"
  wait_for 5 '[ "$(state)" = playing ]'
  "$AX_BIN" press "$PID" "${target#*$'\t'}" >/dev/null; rc=$?; verdict "sentence 3 pressed" $rc
  /usr/bin/python3 scripts/probe-readalong-measure.py "$AX_BIN" "$PID" "$ROOT/mcp.json" "$timing" 8 "${target%%$'\t'*}" \
    | tee "$EVIDENCE/readalong-seek.txt" | sed 's/^/   /'
  rc=${PIPESTATUS[0]}; verdict "the seek lands on the sentence and it is lit (readalong-seek.txt)" $rc
  shot readalong-2-after-tap
  probe_mcp_tool "$SUITE" music_pause >/dev/null
  "$AX_BIN" press "$PID" "Done" >/dev/null; rc=$?; verdict "Done closes Read Along" $rc
  wait_for 5 '! mentions "Imagine, if you can"'; rc=$?; verdict "closed" $rc
}

stage_restore() {
  say "restore: a chapter left paused, after a relaunch, plays on from its place"
  open_book
  "$AX_BIN" menu "$PID" "The Tube" "Play" >/dev/null
  wait_for 10 '[ "$(playing_title)" = "The Tube" ] && [ "$(state)" = playing ]'
  python3 - "$ROOT/mcp.json" <<'PY2' >/dev/null
import json, subprocess, sys
d = json.load(open(sys.argv[1])); cfg = 'header = "Authorization: Bearer %s"\n' % d["token"]
def call(body, sid=None, headers=False):
    a = ["curl", "-s", "-m", "6", "-K", "-", "-X", "POST", d["url"], "-H", "Content-Type: application/json", "-H", "Accept: application/json, text/event-stream"]
    a += (["-D", "-"] if headers else []) + (["-H", "Mcp-Session-Id: " + sid] if sid else []) + ["-d", body]
    return subprocess.run(a, input=cfg, capture_output=True, text=True).stdout
init = call('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}', headers=True)
sid = next((l.split(":", 1)[1].strip() for l in init.splitlines() if l.lower().startswith("mcp-session-id:")), None)
call(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "music_seek", "arguments": {"seconds": 10}}}), sid)
PY2
  sleep 1
  probe_mcp_tool "$SUITE" music_pause >/dev/null
  wait_for 5 '[ "$(state)" = paused ]'
  local left; left="$(pos)"
  echo "   left paused at $left s in The Tube (18.1 s of audio); quitting and relaunching"
  open_book
  [ "$(playing_title)" = "The Tube" ] && [ "$(state)" = paused ]; rc=$?; verdict "relaunched with The Tube in the player, paused: $(now)" $rc
  [ "$(main_button)" = Resume ]; rc=$?; verdict "the button is Resume ($(main_button))" $rc
  "$AX_BIN" press "$PID" "Read Along" >/dev/null
  wait_for 10 'mentions "The airship rose from the tube"'; rc=$?; verdict "Read Along shows The Tube" $rc
  local t0; t0="$(/usr/bin/python3 -c 'import time; print(time.time())')"
  probe_mcp_tool "$SUITE" music_resume >/dev/null
  local tsha; tsha="$(/usr/bin/python3 - "$ROOT" <<'PY2'
import glob, json, os, sys
for f in glob.glob(os.path.join(sys.argv[1], "Clippings", "*.json")):
    try: c = json.load(open(f))
    except Exception: continue
    c = c.get("payload", c)
    if c.get("chapterIndex") == 1 and c.get("sha256"): print(c["sha256"]); break
PY2
)"
  /usr/bin/python3 scripts/probe-readalong-measure.py "$AX_BIN" "$PID" "$ROOT/mcp.json" "$ROOT/Books/read-along/$tsha.json" 5 \
    | tee "$EVIDENCE/restore-readalong.txt" | sed 's/^/   /'
  wait_for 20 '[ "$(playing_title)" = "The Surface" ]'
  local t1; t1="$(/usr/bin/python3 -c 'import time; print(time.time())')"
  local took; took="$(/usr/bin/python3 -c "print(f'{$t1 - $t0:.1f}')")"
  local expect; expect="$(/usr/bin/python3 -c "print(f'{18.13 - $left:.1f}')")"
  echo "   The Surface began $took s after Resume; the audio left in The Tube from $left s is $expect s"
  /usr/bin/python3 -c "import sys; sys.exit(0 if abs($took - $expect) < 1.8 else 1)"
  rc=$?; verdict "Resume played on from $left s, not from 0:00 (next chapter after $took s, expected about $expect s)" $rc
  shot restore-1-next-chapter
  probe_mcp_tool "$SUITE" music_pause >/dev/null
  "$AX_BIN" press "$PID" "Done" >/dev/null
}

stage_menus() {
  say "menus: More and the storage line"
  open_book
  more() { "$AX_BIN" pick "$PID" book-more "$1" >/dev/null; }   # the open book's More menu
  # Keep on This Mac, on the storage line.
  local k0; k0="$("$AX_BIN" value "$PID" "Keep on This Mac")"
  "$AX_BIN" toggle "$PID" "Keep on This Mac" >/dev/null
  local k1; k1="$("$AX_BIN" value "$PID" "Keep on This Mac")"
  [ "$k0" != "$k1" ]; rc=$?; verdict "Keep on This Mac toggles ($k0 -> $k1)" $rc
  "$AX_BIN" toggle "$PID" "Keep on This Mac" >/dev/null
  # Remove Download on one chapter, then get it back.
  "$AX_BIN" menu "$PID" "The Surface" "Remove Download" >/dev/null; rc=$?; verdict "chapter 3: Remove Download" $rc
  wait_for 5 'shows "removed from this Mac"'; rc=$?; verdict "chapter 3 reads removed from this Mac" $rc
  shot menus-1-chapter-removed
  local items; items="$("$AX_BIN" menuitems "$PID" "The Surface" 2>&1 | tr '\n' '|')"
  local again; again="$(echo "$items" | tr '|' '\n' | grep -E '^(Download|Render) Again' | head -1)"
  [ -n "$again" ]; rc=$?; verdict "and offers to get it back ($items)" $rc
  "$AX_BIN" menu "$PID" "The Surface" "$again" >/dev/null; rc=$?; verdict "$again pressed" $rc
  wait_for "${RENDER_WAIT:-180}" '! shows "removed from this Mac"'; rc=$?; verdict "chapter 3 is back" $rc
  sleep 2
  # The whole book: Remove Download from the storage line, then get it back.
  "$AX_BIN" press "$PID" "Remove Download" >/dev/null; rc=$?; verdict "the storage line's Remove Download" $rc
  wait_for 5 '[ "$(rows | grep -cx "removed from this Mac")" = 3 ]'
  rc=$?; verdict "every chapter reads removed from this Mac ($(rows | grep -cx "removed from this Mac") of 3)" $rc
  shows "Download removed"; rc=$?; verdict "the storage line reads Download removed" $rc
  shot menus-2-book-removed
  again="$(rows | grep -oE '^\[button\] (Download|Render) Again' | head -1 | cut -d' ' -f2-)"
  [ -n "$again" ]; rc=$?; verdict "the storage line offers $again" $rc
  "$AX_BIN" press "$PID" "$again" >/dev/null
  wait_for "${RENDER_WAIT:-300}" 'shows "On this Mac" && [ "$(landed)" -ge 3 ]'; rc=$?; verdict "the book is back on this Mac ($(landed) chapters)" $rc
  shot menus-3-book-back
  # Show in Finder: Finder comes forward with a chapter selected.
  more "Show in Finder"; rc=$?; verdict "More: Show in Finder" $rc
  wait_for 8 '[ "$(finder_shows_probe)" = yes ]'; rc=$?; verdict "a Finder window shows this book's chapter folder" $rc
  close_probe_finder
  front
  # Pronunciations… opens its sheet.
  more "Pronunciations…"; rc=$?; verdict "More: Pronunciations…" $rc
  wait_for 5 '[ "$(probe_sheet_count "$PID")" -ge 1 ]'; rc=$?; verdict "its sheet opens" $rc
  shot menus-4-pronunciations
  "$AX_BIN" press "$PID" "Cancel" >/dev/null
  wait_for 5 '[ "$(probe_sheet_count "$PID")" = 0 ]'; rc=$?; verdict "and closes" $rc
  # Export Audiobook…: the save panel, to a file in the evidence folder.
  mkdir -p "$EVIDENCE/export"
  more "Export Audiobook…"; rc=$?; verdict "More: Export Audiobook…" $rc
  wait_for 5 '[ "$(probe_sheet_count "$PID")" -ge 1 ] || "$AX_BIN" windows "$PID" | grep -q .'
  sleep 1
  key 'keystroke "g" using {command down, shift down}'
  sleep 0.8
  key "keystroke \"$EVIDENCE/export/\""
  key 'key code 36'
  sleep 1
  key 'key code 36'
  wait_for 120 'ls "$EVIDENCE"/export/*.m4b >/dev/null 2>&1 && ! mentions "Exporting"'
  local m4b; m4b="$(ls "$EVIDENCE"/export/*.m4b 2>/dev/null | head -1)"
  [ -n "$m4b" ]; rc=$?; verdict "an audiobook was written: $m4b" $rc
  [ -n "$m4b" ] && echo "   chapters in it: $(ffprobe -v error -show_chapters -of csv=p=0 "$m4b" 2>/dev/null | wc -l | tr -d ' '), length $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$m4b" 2>/dev/null) s"
  close_probe_finder
  front
  # Change Voice… opens its sheet.
  "$AX_BIN" press "$PID" "Change Voice…" >/dev/null; rc=$?; verdict "Change Voice… pressed" $rc
  wait_for 10 '[ "$(probe_sheet_count "$PID")" -ge 1 ]'; rc=$?; verdict "its sheet opens" $rc
  shot menus-5-change-voice
  "$AX_BIN" press "$PID" "Cancel" >/dev/null
  wait_for 5 '[ "$(probe_sheet_count "$PID")" = 0 ]'; rc=$?; verdict "Cancel closes it" $rc
  # Delete Book…: Cancel keeps it; Remove from This Mac removes it and goes back to the list.
  more "Delete Book…"; rc=$?; verdict "More: Delete Book…" $rc
  wait_for 5 '[ "$(probe_sheet_count "$PID")" -ge 1 ]'; rc=$?; verdict "it asks first" $rc
  shot menus-6-delete-asks
  "$AX_BIN" press "$PID" "Cancel" >/dev/null
  wait_for 5 'shows "The Tube"'; rc=$?; verdict "Cancel keeps the book" $rc
  more "Delete Book…"
  wait_for 5 '[ "$(probe_sheet_count "$PID")" -ge 1 ]'
  "$AX_BIN" press "$PID" "Remove from This Mac" >/dev/null; rc=$?; verdict "Remove from This Mac pressed" $rc
  wait_for 10 '! shows "The Tube" && ! mentions "'"$TITLE"'"'; rc=$?; verdict "the book is gone, and the screen is the list" $rc
  shot menus-7-deleted
}

for stage in $STAGES; do "stage_$stage"; done

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
