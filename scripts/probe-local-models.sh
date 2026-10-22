#!/bin/bash
# The Models on this Mac walk (M7.2 to M7.4), on a probe instance, never the owner's Baton:
#
#   scripts/probe-local-models.sh <Baton.app> <evidence-dir>
#
#   A. Settings → Speech opens on the section: Ollama, LM Studio and Kokoro each say what they
#      found on this Mac (screenshot)
#   B. Test the first installed Ollama model: it answers, and the time is shown (screenshot)
#   C. Save it: it appears under Saved for documents, and in the probe's own preferences
#   D. The Kokoro help sheet (screenshot)
#
# It never presses Download: that fetches gigabytes. The screenshot in A shows the button and
# the size it states. KOKORO_URL, when set, is written as the probe's Kokoro host so the row can
# say which Kokoro Baton uses; without it the probe has none configured.
#
# The walk brings the probe to the front for each screenshot. Run it when nobody is typing.
# Exit 0 PASS, 1 FAIL, 2 could not run, 3 another probe holds the lock (probe-lib.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/probe-lib.sh

APP="${1:?usage: $0 <Baton.app> <evidence-dir>}"
EVIDENCE="${2:?evidence dir}"
mkdir -p "$EVIDENCE"
EVIDENCE="$(cd "$EVIDENCE" && pwd -P)"
SUITE="$(probe_new_suite models)"
PID=""
fail=0

cleanup() {
  probe_quit "$PID"
  [ "${KEEP_PROBE:-0}" = 1 ] || probe_cleanup "$SUITE"
  probe_lock_release
}
trap cleanup EXIT
trap 'exit 130' INT TERM
probe_lock_acquire || exit 3

say() { printf '\n== %s\n' "$1"; }
verdict() { if [ "$2" = 0 ]; then echo "   PASS  $1"; else echo "   FAIL  $1"; fail=1; fi; }
front() { osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null 2>&1; sleep 0.8; }

# One window of the probe, by its window id (`screencapture -l`), so nothing else on screen can
# end up in the picture. $2 = "largest" (Settings) or "smallest" (a sheet, its own window).
shot() {   # $1 = name, $2 = largest|smallest
  front
  local id
  if [ "${2:-largest}" = smallest ]; then id="$(ax_windows | tail -1 | cut -d' ' -f1)"; else id="$(ax_windows | head -1 | cut -d' ' -f1)"; fi
  [ -n "$id" ] || { echo "   no window to capture for $1"; fail=1; return; }
  screencapture -x -o -l "$id" "$EVIDENCE/$1.png"
  echo "   screenshot: $EVIDENCE/$1.png"
}

# Accessibility through AXUIElement, by pid (scripts/probe-ax.swift): AppleScript's
# `entire contents` of this Form timed out after minutes and found nothing.
AX_BIN="${TMPDIR:-/tmp}/baton-probe-ax-$(shasum scripts/probe-ax.swift | cut -c1-12)"
[ -x "$AX_BIN" ] || xcrun swiftc -O -o "$AX_BIN" scripts/probe-ax.swift || { echo "could not build probe-ax"; exit 2; }
ax() { "$AX_BIN" "$1" "$PID" "$2" 2>&1; }   # $1 = press|show, $2 = label
texts() { "$AX_BIN" texts "$PID" 2>/dev/null; }
ax_windows() { "$AX_BIN" windows "$PID" 2>/dev/null; }
scroll_to() { "$AX_BIN" scroll "$PID" "$1" >/dev/null 2>&1; sleep 0.6; }   # 0 top, 1 bottom

wait_for() {   # $1 = seconds, $2 = shell condition
  local limit=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$limit" ]; do eval "$2" && return 0; sleep 1; done
  return 1
}

# What this Mac really has, asked directly, so the screen is checked against it.
MODEL="$(curl -s -m 2 http://127.0.0.1:11434/api/tags | /usr/bin/python3 -c 'import json,sys; m=json.load(sys.stdin)["models"]; print(m[0]["name"] if m else "")' 2>/dev/null)"
echo "   Ollama on this Mac: ${MODEL:-not running or no model}"
LMS="$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:1234/v1/models)"
echo "   LM Studio on this Mac: HTTP $LMS"

defaults write "$SUITE" baton.documents.enabled -bool true
defaults write "$SUITE" baton.settings.selectedCategory speech
[ -n "${KOKORO_URL:-}" ] && defaults write "$SUITE" tonebox.speech.kokoroBaseURL "$KOKORO_URL"

say "A. Settings → Speech, Models on this Mac"
# Preference sync off, as probe_launch does: a probe must neither adopt the owner's shared settings
# nor push its throwaway ones into them.
open -n -a "$APP" --env BATON_DEBUG_PREFERENCE_SYNC=off --args -baton.defaultsSuite "$SUITE" -baton.debugCloseMainWindow -baton.debugOpenWindow settings || exit 2
for _ in $(seq 1 40); do PID="$(pgrep -f -- "-baton.defaultsSuite $SUITE" | head -1)"; [ -n "$PID" ] && break; sleep 0.5; done
[ -n "$PID" ] || { echo "probe did not start"; exit 2; }
# Section headers are not static text to Accessibility; the Ollama row and the section's footer are.
wait_for 30 'texts | grep -q "^Document features, such as"'; verdict "the section is in Settings → Speech" $?
front
ax show "Ollama" >/dev/null
sleep 4   # the first detection
if [ -n "$MODEL" ]; then
  wait_for 15 'texts | grep -q "^Running, "'; verdict "Ollama reads as running" $?
  texts | grep -qx "$MODEL"; verdict "$MODEL is listed" $?
fi
texts | grep -E "^Download |^Not installed|^Not running|^Running|Kokoro" | sed 's/^/   /'
shot A-models-on-this-mac

if [ -n "$MODEL" ]; then
  say "B. Test $MODEL"
  ax press "Test" | sed 's/^/   /'
  wait_for 90 'texts | grep -q "^Answered correctly in"'; verdict "it answered the test request" $?
  texts | grep -E "^Answered|^It did not|^It answered" | sed 's/^/   /'
  ax show "Ollama" >/dev/null
  shot B-tested

  say "C. Save it"
  ax press "Save" | sed 's/^/   /'
  wait_for 10 'texts | grep -q "^Answering$"'; verdict "it is listed under Saved for documents, answering" $?
  defaults read "$SUITE" baton.documents.localModelSources >/dev/null 2>&1; verdict "the probe's own preferences hold it" $?
  ax show "LM Studio" >/dev/null
  shot C-saved
fi

say "D. The Kokoro help sheet"
ax show "LM Studio" >/dev/null
shot D-kokoro-row
ax press "How to Run Kokoro on This Mac" | sed 's/^/   /'
wait_for 10 '[ "$(probe_sheet_count "$PID")" -ge 1 ]'; verdict "the help sheet opened" $?
sleep 1
shot D-kokoro-help smallest

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
