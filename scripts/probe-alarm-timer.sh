#!/bin/bash
# The Mac's Alarm and Timer on a real, isolated Baton (TBX-11171, specs/alarm-and-timer.md).
#
#   scripts/probe-alarm-timer.sh <Baton.app> <evidence-dir>
#
# Launches a probe Baton (its own defaults suite, preference sync off, no real notifications)
# with a timer set at launch by BATON_DEBUG_ALARM_PROBE_TIMER, so nothing on screen is clicked
# to arm it. Then it checks, through the probe's own MCP server and its accessibility tree:
# nothing plays before the timer ends; the chosen file plays when it does; the floating ringing
# card is up with Stop and Keep Playing; Stop on that card pauses the music and takes the card
# down. The audio is silence, so the run is quiet on the owner's speakers.
#
# Build a DEBUG probe under its own bundle id first, so it never shares the owner's Baton's
# ports or notifications: PROBE_BUNDLE_ID=io.tonebox.baton.dev.alarm scripts/probe-build.sh <dir>
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/probe-lib.sh
APP="${1:?Baton.app}"
EVIDENCE="${2:?evidence dir}"
mkdir -p "$EVIDENCE"
EVIDENCE="$(cd "$EVIDENCE" && pwd -P)"
WORK="$(mktemp -d -t baton-alarm-probe)"
SUITE="$(probe_new_suite alarm)"
PID=""
fail=0
T0=$(date +%s)

AX_BIN="${TMPDIR:-/tmp}/baton-probe-ax-$(shasum scripts/probe-ax.swift | cut -c1-12)"
[ -x "$AX_BIN" ] || xcrun swiftc -O -o "$AX_BIN" scripts/probe-ax.swift || { echo "could not build probe-ax"; exit 2; }

cleanup() {
  probe_quit "$PID"
  [ "${KEEP_PROBE:-0}" = 1 ] || probe_cleanup "$SUITE"
  rm -rf "$WORK"
  probe_lock_release
}
trap cleanup EXIT
trap 'exit 130' INT TERM
probe_lock_acquire || exit 3

say() { printf '\n== %s (+%ss)\n' "$1" "$(( $(date +%s) - T0 ))"; }
verdict() { if [ "$2" = 0 ]; then echo "   PASS  $1"; else echo "   FAIL  $1"; fail=1; fi; }
wait_for() {   # $1 = seconds, $2 = shell condition
  local limit=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$limit" ]; do eval "$2" && return 0; sleep 1; done
  return 1
}
now_playing() { probe_mcp_tool "$SUITE" music_now_playing 2>/dev/null; }
texts() { "$AX_BIN" texts "$PID" 2>/dev/null; }

# Thirty seconds of silence, the "chosen track".
/usr/bin/python3 - "$WORK/Wake Up.wav" <<'PY'
import struct, sys, wave
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(8000)
    w.writeframes(struct.pack("<h", 0) * 8000 * 30)
PY
FILE_URL="$(/usr/bin/python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).as_uri())' "$WORK/Wake Up.wav")"

say "launch a probe with a 12-second timer"
open -n -a "$APP" --env BATON_DEBUG_PREFERENCE_SYNC=off --env BATON_DEBUG_ALARM_SYSTEM=off \
  --env "BATON_DEBUG_ALARM_PROBE_TIMER=12|$FILE_URL" --args -baton.defaultsSuite "$SUITE" || exit 1
wait_for 20 'PID="$(pgrep -f -- "-baton.defaultsSuite $SUITE" | head -1)"; [ -n "$PID" ]'
echo "   pid $PID, suite $SUITE"
wait_for 20 '[ "$(probe_mcp_status "$SUITE")" = 200 ]'
before="$(now_playing)"
echo "   before: $before"
case "$before" in *"Wake Up"*) verdict "nothing chosen plays before the timer ends" 1 ;; *) verdict "nothing chosen plays before the timer ends" 0 ;; esac

say "the timer ends"
wait_for 25 'now_playing | grep -q "Wake Up"'
after="$(now_playing)"
echo "   after: $after"
echo "$after" | grep -q "Wake Up"; verdict "the chosen file is what plays" $?
echo "$after" | grep -qi "playing"; verdict "and it is playing" $?
wait_for 5 'texts | grep -q "Keep Playing"'
texts > "$EVIDENCE/ringing-texts.txt"
grep -q "Probe timer" "$EVIDENCE/ringing-texts.txt"; verdict "the ringing card names the timer" $?
grep -q "Stop" "$EVIDENCE/ringing-texts.txt"; verdict "with Stop" $?
n=0
while read -r wid w h; do
  [ -n "$wid" ] || continue
  n=$((n + 1))
  screencapture -x -o -l "$wid" "$EVIDENCE/mac-ringing-window-$n.png" && echo "   screenshot: $EVIDENCE/mac-ringing-window-$n.png (${w}x${h})"
done < <("$AX_BIN" windows "$PID")
# The ringing card is a non-activating floating panel, which the accessibility window list leaves
# out; the window server lists it.
/usr/bin/swift -e '
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerPID as String] as? Int) == pid && (w[kCGWindowLayer as String] as? Int ?? 0) > 0 {
    print(w[kCGWindowNumber as String] as! Int)
}' "$PID" 2>/dev/null | while read -r wid; do
  screencapture -x -o -l "$wid" "$EVIDENCE/mac-ringing-card.png" && echo "   screenshot: $EVIDENCE/mac-ringing-card.png"
done

say "Stop"
"$AX_BIN" press "$PID" "Stop" >/dev/null 2>&1
sleep 1.5
stopped="$(now_playing)"
echo "   after Stop: $stopped"
echo "$stopped" | grep -qi "paused"; verdict "Stop pauses the music" $?
texts | grep -q "Keep Playing"; [ $? -ne 0 ]; verdict "and the card is gone" $?

say "result"
[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
