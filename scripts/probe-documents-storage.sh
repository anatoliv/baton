#!/bin/bash
# The Documents switch taking effect live and the Storage pane (M6.3 and
# M6.4), on a probe instance, never the owner's Baton:
#
#   scripts/probe-documents-storage.sh <Baton.app> <evidence-dir>
#
#   A. a small book is made on the probe against a stand-in Kokoro on 127.0.0.1 (silent WAV
#      answers), so Clippings and Storage have a real book in them
#   B. File > Import Document… is there; Settings > Speech > Documents is turned off and the
#      item is gone at once (no relaunch) and the probe stored the switch off; on again, the
#      item is back
#   C. Settings > Storage shows the book with its size, the rules and Recently removed
#      (screenshot); Remove Download moves it to Recently removed (screenshot)
#
# Needs a DEBUG build (BATON_DEBUG_IMPORT_DOCUMENT opens the import sheet). Brings the probe to
# the front for each screenshot and keystroke, so run it when nobody is typing.
#
# Exit 0 PASS, 1 FAIL, 2 could not run, 3 another probe holds the lock (probe-lib.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/probe-lib.sh

APP="${1:?usage: $0 <Baton.app> <evidence-dir>}"
EVIDENCE="${2:?evidence dir}"
mkdir -p "$EVIDENCE"
EVIDENCE="$(cd "$EVIDENCE" && pwd -P)"
WORK="$(mktemp -d -t baton-storage-walk)"
KOKORO_PORT="${KOKORO_PORT:-18891}"
SUITE="$(probe_new_suite storage)"
ROOT="$PROBE_SUPPORT_ROOT/$SUITE"
PID=""
KOKORO_PID=""
fail=0

cleanup() {
  probe_quit "$PID"
  [ -n "$KOKORO_PID" ] && kill "$KOKORO_PID" 2>/dev/null
  [ "${KEEP_PROBE:-0}" = 1 ] || probe_cleanup "$SUITE"
  rm -rf "$WORK"
  probe_lock_release
}
trap cleanup EXIT
trap 'exit 130' INT TERM
probe_lock_acquire || exit 3

say() { printf '\n== %s\n' "$1"; }
verdict() { if [ "$2" = 0 ]; then echo "   PASS  $1"; else echo "   FAIL  $1"; fail=1; fi; }
wait_for() {   # $1 = seconds, $2 = shell condition
  local limit=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$limit" ]; do eval "$2" && return 0; sleep 1; done
  return 1
}
front() { osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null 2>&1; sleep 0.8; }

# Accessibility through AXUIElement, by pid (scripts/probe-ax.swift): AppleScript's
# `entire contents` of the Settings window's grouped Form finds nothing in time.
AX_BIN="${TMPDIR:-/tmp}/baton-probe-ax-$(shasum scripts/probe-ax.swift | cut -c1-12)"
[ -x "$AX_BIN" ] || xcrun swiftc -O -o "$AX_BIN" scripts/probe-ax.swift || { echo "could not build probe-ax"; exit 2; }

# A screenshot of the probe's window titled $2, that window alone (`screencapture -l`).
shot() {   # $1 = file name, $2 = window title
  front
  local id
  id="$("$AX_BIN" window "$PID" "$2" 2>/dev/null)"
  if [[ "$id" =~ ^[0-9]+$ ]]; then screencapture -x -o -l "$id" "$EVIDENCE/$1.png"; else screencapture -x "$EVIDENCE/$1.png"; fi
  echo "   screenshot: $EVIDENCE/$1.png"
}

file_menu() {   # the File menu's item names, comma separated
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID)
    return name of every menu item of menu 1 of menu bar item \"File\" of menu bar 1
  end tell" 2>/dev/null
}
has_import() { file_menu | grep -q "Import Document"; }

open_settings() {
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID)
    click (first menu item of menu 1 of menu bar item 2 of menu bar 1 whose name starts with \"Settings\")
  end tell" >/dev/null 2>&1
  sleep 1.5
}

toggle() { "$AX_BIN" toggle "$PID" "$1" >/dev/null; }          # a checkbox or switch, by label
press() { front; "$AX_BIN" press "$PID" "$1" >/dev/null; }     # a button, by label (the probe in front, so SwiftUI runs the action now)
select_pane() { "$AX_BIN" select "$PID" "$1" >/dev/null; }     # a Settings sidebar row, by label

landed() { ls "$ROOT"/Clippings/*.m4a 2>/dev/null | wc -l | tr -d ' '; }

# ---- a stand-in Kokoro: a fifth of a second of silence for every request ----------------------
/usr/bin/python3 - "$KOKORO_PORT" <<'PY' &
import http.server, struct, sys
pcm = bytes(24000 // 5 * 2)
wav = b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 24000, 48000, 2, 16) \
    + b"data" + struct.pack("<I", len(pcm)) + pcm
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        body = b'{"voices":["bf_emma","af_heart"]}'
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.send_response(200); self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(wav))); self.end_headers(); self.wfile.write(wav)
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
KOKORO_PID=$!
sleep 0.5

BOOK="$WORK/the-cell.md"
printf '# The Cell\n\n## One\n\nImagine, if you can, a small room, hexagonal in shape.\n\n## Two\n\nAn electric bell rang.\n' > "$BOOK"
defaults write "$SUITE" baton.documents.enabled -bool true
defaults write "$SUITE" tonebox.speech.kokoroBaseURL "http://127.0.0.1:$KOKORO_PORT"
defaults write "$SUITE" baton.settings.selectedCategory speech

say "A. a book is made on the probe"
open -n -a "$APP" --env BATON_DEBUG_IMPORT_DOCUMENT="$BOOK" --env BATON_DEBUG_PREFERENCE_SYNC=off \
  --args -baton.defaultsSuite "$SUITE" || { echo "probe did not start"; exit 2; }
for _ in $(seq 1 40); do PID="$(pgrep -f -- "-baton.defaultsSuite $SUITE" | head -1)"; [ -n "$PID" ] && break; sleep 0.5; done
[ -n "$PID" ] || { echo "probe did not start"; exit 2; }
wait_for 90 '[ "$(probe_sheet_count "$PID")" -ge 1 ] 2>/dev/null'; verdict "the import sheet opened" $?
sleep "${SHEET_SETTLE:-6}"
front
frontpid="$(osascript -e 'tell application "System Events" to unix id of first process whose frontmost is true' 2>/dev/null)"
[ "$frontpid" = "$PID" ] || { echo "the probe is not frontmost (pid $frontpid is); stopping"; exit 2; }
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to keystroke return" >/dev/null
wait_for 120 '[ "$(landed)" -ge 2 ]'; ok=$?; verdict "both chapters are in Clippings ($(landed))" $ok

say "B. the Documents switch takes effect without a relaunch"
has_import; verdict "File > Import Document… is there with documents on" $?
open_settings
toggle documents-switch; verdict "Settings > Speech > Documents turned off" $?
sleep 1
! has_import; verdict "File > Import Document… is gone at once" $?
[ "$(defaults read "$SUITE" baton.documents.enabled 2>/dev/null)" = 0 ]; verdict "the probe stored the switch off" $?
shot B-documents-off-clippings "Baton"
shot B-documents-off-settings "Settings"
toggle documents-switch; verdict "Documents turned on again" $?
sleep 1
has_import; verdict "File > Import Document… is back at once" $?

say "C. Settings > Storage"
select_pane Storage; verdict "the Storage pane is open" $?
sleep 2
shot mac-storage "Settings"
press "Remove Download"; verdict "Remove Download pressed" $?
sleep 1.5
wait_for 20 '[ "$(landed)" -eq 0 ]'; ok=$?; verdict "the book's audio left this Mac ($(landed) chapters left)" $ok
shot mac-storage-removed "Settings"
press "Render Again"; verdict "Render Again pressed" $?
wait_for 60 '[ "$(landed)" -ge 2 ]'; ok=$?; verdict "the chapters are back ($(landed))" $ok

echo
[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
