#!/bin/bash
# The Books section walk, on a probe instance, never the owner's Baton:
#
#   scripts/probe-books-section.sh <Baton.app> <evidence-dir>
#
# Seeds the probe's own Clippings folder with two readings and a two-chapter book, each a real
# 40-second audio file, then:
#
#   A. Clippings: the two readings, and no book or chapter
#   B. Books: the book's row with its author and length, and no reading
#   C. the book open: its chapters, Play, Read Along, More, and its storage
#   D. chapter 2 played from its row's menu: the chapter row has the bars, the accent title and
#      the tint, the book's cover the bars alone
#   E. paused: the tint stays on the chapter row, the bars go
#   F. back in the list while chapter 2 plays: the book's row has the bars
#
# Playback state is read from the probe's own MCP `baton://now-playing` resource, so a verdict
# never depends on reading a screenshot. Rows are driven through the Accessibility API
# (scripts/probe-ax.swift); sections are chosen at launch by environment (BATON_DEBUG_SHOW_*,
# BATON_DEBUG_OPEN_BOOK), never by typing into whatever is in front.
#
# Exit 0 PASS, 1 FAIL, 2 could not run, 3 another probe holds the lock (probe-lib.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/probe-lib.sh

APP="${1:?usage: $0 <Baton.app> <evidence-dir>}"
EVIDENCE="${2:?evidence dir}"
mkdir -p "$EVIDENCE"
EVIDENCE="$(cd "$EVIDENCE" && pwd -P)"
AX_BIN="${TMPDIR:-/tmp}/baton-probe-ax-$(shasum scripts/probe-ax.swift | cut -c1-12)"
[ -x "$AX_BIN" ] || xcrun swiftc -O -o "$AX_BIN" scripts/probe-ax.swift || { echo "could not build probe-ax"; exit 2; }

probe_lock_acquire || exit 3
SUITE="$(probe_new_suite books)"
ROOT="$PROBE_SUPPORT_ROOT/$SUITE"
PID=""
fail=0
cleanup() {
  probe_quit "$PID"
  [ "${KEEP_PROBE:-0}" = 1 ] || probe_cleanup "$SUITE"
  probe_lock_release
}
trap cleanup EXIT

say() { printf '\n== %s\n' "$*"; }
verdict() { if [ "$2" = 0 ]; then echo "   PASS $1"; else echo "   FAIL $1"; fail=1; fi; }

# ---- the probe's Clippings folder: real audio, so the player really plays it -------------------
mkdir -p "$ROOT/Clippings"
/usr/bin/python3 - "$ROOT/Clippings" <<'PY' || { echo "could not seed"; exit 2; }
import json, os, subprocess, sys, wave
d = sys.argv[1]
wav = os.path.join(d, "silence.wav")
with wave.open(wav, "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(22050)
    w.writeframes(b"\0\0" * 22050 * 40)
items = [
    ("ch1", "Chapter 1: The Air-Ship", "Kokoro", "The Machine Stops", 0),
    ("ch2", "Chapter 2: The Mending Apparatus", "Kokoro", "The Machine Stops", 1),
    ("r1", "Cafe notes", "Safari", None, None),
    ("r2", "Ghostty 10.02", "Ghostty", None, None),
]
for i, (cid, title, source, book, index) in enumerate(items):
    payload = {"id": cid, "title": title, "source": source, "text": title,
               "createdAt": 800000000 + i * 60, "durationSeconds": 40}
    if book:
        payload.update(documentID="doc-machine-stops", documentTitle=book, chapterIndex=index,
                       chapterTitle=title, author="E. M. Forster")
    json.dump({"version": 2, "payload": payload}, open(os.path.join(d, cid + ".json"), "w"))
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", wav, os.path.join(d, cid + ".m4a")], check=True)
os.remove(wav)
print("seeded", len(items), "clippings with 40 s of audio each")
PY

launch() {   # extra --env pairs
  open -n -a "$APP" --env BATON_DEBUG_PREFERENCE_SYNC=off "$@" --args -baton.defaultsSuite "$SUITE" || return 1
  PID=""
  for _ in $(seq 1 40); do
    PID="$(pgrep -f -- "-baton.defaultsSuite $SUITE" | head -1)"; [ -n "$PID" ] && break; sleep 0.5
  done
  [ -n "$PID" ]
}
relaunch() { probe_quit "$PID"; PID=""; sleep 1; launch "$@"; }

front() { osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null 2>&1; sleep 0.8; }
shot() {
  front
  local id; id="$("$AX_BIN" windows "$PID" 2>/dev/null | head -1 | cut -d' ' -f1)"
  if [ -n "$id" ]; then screencapture -x -o -l "$id" "$EVIDENCE/$1.png"; else screencapture -x "$EVIDENCE/$1.png"; fi
  echo "   screenshot: $EVIDENCE/$1.png"
}
rows() { "$AX_BIN" texts "$PID" 2>/dev/null; }
shows() { rows | grep -qxF "$1"; }
mentions() { rows | grep -qF "$1"; }
wait_for() { local limit=$(( $(date +%s) + $1 )); while [ "$(date +%s)" -lt "$limit" ]; do eval "$2" && return 0; sleep 0.2; done; return 1; }
now_playing() {   # "<state> <title>" from the probe's own MCP server
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
    now = json.loads(json.loads(body)["result"]["contents"][0]["text"])
    print(now.get("state", "?"), (now.get("now_playing") or {}).get("title", ""))
except Exception:
    print("? " + body[:120].replace("\n", " "))
PY
}
dump() { echo "   what Accessibility sees:"; rows | head -60 | sed 's/^/     /'; }

say "A. Clippings: readings only"
launch --env BATON_DEBUG_SHOW_CLIPPINGS=1 || { echo "probe did not start"; exit 2; }
wait_for 30 'shows "Ghostty 10.02"'; rc=$?; verdict "Clippings lists the readings" $rc
[ "$rc" = 0 ] || dump
shows "Cafe notes"; verdict "both readings" $?
! mentions "The Machine Stops"; verdict "no book in Clippings" $?
! mentions "Chapter 2: The Mending Apparatus"; verdict "no chapter in Clippings" $?
wait_for 30 '[ -f "$ROOT/mcp.json" ]'
shot A-clippings-readings-only

say "B. Books: the book, no reading"
relaunch --env BATON_DEBUG_SHOW_BOOKS=1 || { echo "probe did not restart"; exit 2; }
wait_for 30 'mentions "The Machine Stops"'; rc=$?; verdict "Books lists the book" $rc
[ "$rc" = 0 ] || dump
mentions "E. M. Forster"; verdict "with its author" $?
! mentions "Ghostty 10.02"; verdict "no reading in Books" $?
shot B-books-list

say "C. the book open"
relaunch --env BATON_DEBUG_OPEN_BOOK=1 || { echo "probe did not restart"; exit 2; }
wait_for 30 'shows "Chapter 2: The Mending Apparatus"'; rc=$?; verdict "the open book lists its chapters" $rc
[ "$rc" = 0 ] || dump
shows "Chapter 1: The Air-Ship"; verdict "chapter 1 too" $?
rows | grep -qE '^\[button\] (Play|Resume)'; verdict "Play or Resume" $?
mentions "Read Along"; verdict "Read Along" $?
"$AX_BIN" value "$PID" "Keep on This Mac" >/dev/null; verdict "the storage line's Keep on This Mac" $?
wait_for 30 '[ -f "$ROOT/mcp.json" ]'
shot C-book-detail

say "D. chapter 2 plays"
out="$("$AX_BIN" menu "$PID" "Chapter 2: The Mending Apparatus" "Play" 2>&1)"; rc=$?; verdict "Play from the chapter's menu ($out)" $rc
wait_for 15 '[ "$(now_playing)" = "playing Chapter 2: The Mending Apparatus" ]'; rc=$?; verdict "chapter 2 is playing: $(now_playing)" $rc
sleep 1.5
shot D-chapter-playing-bars

say "E. paused"
probe_mcp_tool "$SUITE" music_pause >/dev/null
wait_for 10 '[ "$(now_playing | cut -d" " -f1)" = "paused" ]'; rc=$?; verdict "paused: $(now_playing)" $rc
sleep 1
shot E-chapter-paused

say "F. back in the list while it plays"
probe_mcp_tool "$SUITE" music_resume >/dev/null
wait_for 10 '[ "$(now_playing | cut -d" " -f1)" = "playing" ]'; verdict "playing again: $(now_playing)" $?
"$AX_BIN" press "$PID" "books-back" >/dev/null; verdict "the back button" $?
wait_for 10 '! shows "Chapter 2: The Mending Apparatus" && mentions "The Machine Stops"'; verdict "the list again" $?
sleep 1.5
[ "$(now_playing | cut -d" " -f1)" = "playing" ]; verdict "still playing in the list: $(now_playing)" $?
shot F-books-list-playing
probe_mcp_tool "$SUITE" music_pause >/dev/null

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
