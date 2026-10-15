#!/bin/bash
# The Clippings search walk (M8.9, TBX-10870), on a probe instance, never the owner's Baton:
#
#   scripts/probe-clippings-search.sh <Baton.app> <evidence-dir>
#
# Seeds the probe's own Clippings with two book chapters of 70,000 characters and two short
# readings, opens Clippings, types into its filter key by key, and takes a screenshot of each:
#
#   A. nothing typed: all four rows
#   B. "cafe" finds the reading called "Café notes" (accents are ignored) and nothing else
#   C. a phrase from the middle of the second long chapter finds that chapter only
#   D. the filter cleared: all four rows again
#
# The rows are read through the Accessibility API (scripts/probe-ax.swift), so a verdict never
# depends on reading a screenshot. Key presses are posted to the probe's process, not typed into
# whatever is in front; the probe is brought forward for each screenshot.
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
SUITE="$(probe_new_suite search)"
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

# ---- the probe's Clippings ----------------------------------------------------------------------
mkdir -p "$ROOT/Clippings"
/usr/bin/python3 - "$ROOT/Clippings" <<'PY'
import json, os, random, sys
d = sys.argv[1]
words = ("the and of machine said she room light was in that her it to a with for had not but "
         "voice button chair speaking tube lecture music airship earth surface").split()
def chapter(seed, marker):
    rng = random.Random(seed)
    out, n = [], 0
    while n < 70000:
        w = rng.choice(words) + (". " if rng.random() < 0.08 else " ")
        out.append(w); n += len(w)
        if len(out) == 6000 and marker: out.append(marker + " ")
    return "".join(out)
items = [
    ("ch1", "Chapter 1: The Air-Ship", "Kokoro", chapter(1, ""), "The Machine Stops", 0),
    ("ch2", "Chapter 2: The Mending Apparatus", "Kokoro", chapter(2, "the isolation switch was off"), "The Machine Stops", 1),
    ("r1", "Café notes", "Safari", "A crème brûlée and an espresso at the corner.", None, None),
    ("r2", "Ghostty 10.02", "Ghostty", "swift test passed in the worktree.", None, None),
]
for i, (cid, title, source, text, book, index) in enumerate(items):
    payload = {"id": cid, "title": title, "source": source, "text": text,
               "createdAt": 800000000 + i * 60, "durationSeconds": 60}
    if book:
        payload.update(documentID="doc-machine-stops", documentTitle=book, chapterIndex=index,
                       chapterTitle=title, author="E. M. Forster")
    json.dump({"version": 2, "payload": payload}, open(os.path.join(d, cid + ".json"), "w"))
    open(os.path.join(d, cid + ".m4a"), "wb").write(b"\0" * 64)
print("seeded", len(items), "clippings;", sum(len(i[3]) for i in items), "characters")
PY

# ---- the walk -----------------------------------------------------------------------------------
open -n -a "$APP" --env BATON_DEBUG_SHOW_CLIPPINGS=1 --env BATON_DEBUG_PREFERENCE_SYNC=off \
  --args -baton.defaultsSuite "$SUITE" || { echo "probe did not start"; exit 2; }
for _ in $(seq 1 40); do
  PID="$(pgrep -f -- "-baton.defaultsSuite $SUITE" | head -1)"; [ -n "$PID" ] && break; sleep 0.5
done
[ -n "$PID" ] || { echo "probe did not start"; exit 2; }

front() { osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null 2>&1; sleep 0.8; }
shot() {
  front
  local id; id="$("$AX_BIN" windows "$PID" 2>/dev/null | head -1 | cut -d' ' -f1)"
  if [ -n "$id" ]; then screencapture -x -l "$id" "$EVIDENCE/$1.png"; else screencapture -x "$EVIDENCE/$1.png"; fi
  echo "   screenshot: $EVIDENCE/$1.png"
}
rows() { "$AX_BIN" texts "$PID" 2>/dev/null; }
shows() { rows | grep -qxF "$1"; }
# Types $1 one key at a time into the probe's filter field. The keys are posted to the probe's
# process (probe-ax type), so they can never land in another app.
type_keys() {
  front
  "$AX_BIN" focus "$PID" "Filter clippings" >/dev/null || { echo "   no filter field"; return 1; }
  sleep 0.3
  "$AX_BIN" type "$PID" "$1" >/dev/null
  sleep 0.5
  # Posted key presses do not reach a SwiftUI field on every macOS; the field's value is then set
  # through Accessibility instead, which is what VoiceOver and dictation do. The log says which.
  if [ "$(field_value)" != "$1" ]; then
    echo "   the key presses did not reach the field; setting its value through Accessibility"
    "$AX_BIN" set "$PID" "Filter clippings" "$1" >/dev/null
  fi
}
field_value() { "$AX_BIN" value-of "$PID" "Filter clippings" 2>/dev/null; }
clear_field() {
  front
  "$AX_BIN" focus "$PID" "Filter clippings" >/dev/null || return 1
  sleep 0.3
  "$AX_BIN" clear "$PID" >/dev/null
  sleep 0.5
  [ -z "$(field_value)" ] || "$AX_BIN" set "$PID" "Filter clippings" "" >/dev/null
}
wait_for() { local limit=$(( $(date +%s) + $1 )); while [ "$(date +%s)" -lt "$limit" ]; do eval "$2" && return 0; sleep 0.2; done; return 1; }

say "A. Clippings with two 70,000-character chapters and two readings"
wait_for 30 'shows "Café notes"'; verdict "Clippings lists the seeded readings" $?
"$AX_BIN" press "$PID" "Show chapters" >/dev/null 2>&1; sleep 1
shot A-all
"$AX_BIN" focus "$PID" "Filter clippings" >/dev/null; verdict "the filter field can take focus" $?

say "B. \"cafe\" finds \"Café notes\""
type_keys "cafe" || exit 1
T0=$(/usr/bin/python3 -c 'import time; print(time.time())')
wait_for 5 '! shows "Ghostty 10.02"'
T1=$(/usr/bin/python3 -c 'import time; print(time.time())')
shows "Café notes"; verdict "the accented title matches the plain query" $?
shows "Ghostty 10.02"; [ $? != 0 ]; verdict "the other reading is filtered out" $?
echo "   list settled $(/usr/bin/python3 -c "print(round(($T1-$T0)*1000))") ms after the last key (includes the 150 ms pause and the accessibility polling)"
shot B-cafe

say "C. a phrase from the middle of chapter 2"
clear_field
type_keys "isolation switch" || exit 1
wait_for 5 '! shows "Café notes"'
rows > "$EVIDENCE/C-rows.txt"
shows "Café notes"; [ $? != 0 ]; verdict "the readings are filtered out" $?
"$AX_BIN" press "$PID" "Show chapters" >/dev/null 2>&1; sleep 1
shows "Chapter 2: The Mending Apparatus"; verdict "chapter 2 matches by its words" $?
shows "Chapter 1: The Air-Ship"; [ $? != 0 ]; verdict "chapter 1 does not" $?
shot C-phrase

say "D. the filter cleared"
clear_field
wait_for 5 'shows "Ghostty 10.02"'; verdict "every row is back" $?
shot D-cleared

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
