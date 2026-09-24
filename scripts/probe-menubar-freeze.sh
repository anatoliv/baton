#!/bin/bash
# Does opening the menu bar menu freeze Baton when crash reporting is on? (TBX-7352)
#
#   scripts/probe-menubar-freeze.sh <Baton.app> [launches] [evidence-dir]
#
# <Baton.app> should come from scripts/probe-build.sh (Debug, crash reporting compiled in).
# Each launch starts a probe instance with its own preferences suite and crash reporting
# switched on, and then checks two things:
#
#   1. Mechanism. lldb reads the main CFRunLoop and asserts that NSEventTrackingRunLoopMode
#      and NSModalPanelRunLoopMode are common modes. When the crash-reporting SDK reached
#      NSApplication.shared first from its background queue, AppKit registered them on the
#      wrong thread's run loop, and the main run loop's common modes held only the default.
#   2. Behaviour. The probe's own menu bar item is pressed (by process id, never by bundle
#      identifier, so the owner's Baton is never touched), and while the menu is open the
#      probe's MCP server is asked `initialize`. A healthy app answers 200 because the main
#      queue still runs during menu tracking; the frozen app cannot answer.
#
# Exit 0 only if every launch passes both. Red on v0.19.6 (the shipped bug), green from 0.19.7.
set -uo pipefail

[ "$#" -ge 1 ] || { echo "usage: $0 <Baton.app> [launches] [evidence-dir]" >&2; exit 64; }
APP="$1"; LAUNCHES="${2:-3}"; EVIDENCE="${3:-}"
. "$(dirname "$0")/probe-lib.sh"
[ -n "$EVIDENCE" ] && mkdir -p "$EVIDENCE"

fail=0
for n in $(seq 1 "$LAUNCHES"); do
  SUITE="$(probe_new_suite menubar)"
  defaults write "$SUITE" baton.crashUploadEnabled -bool true
  PID="$(probe_launch "$APP" "$SUITE")" || { echo "launch $n: FAIL (did not start)"; fail=1; probe_cleanup "$SUITE"; continue; }
  sleep 8

  started="no"
  /usr/bin/log show --last 15s --style compact \
    --predicate "processIdentifier == $PID AND subsystem == \"io.tonebox.baton\" AND category == \"crash-reporting\"" \
    2>/dev/null | grep -q "Remote crash reporting started" && started="yes"

  dump="$(lldb -p "$PID" --batch -o 'expr -l objc -O -- (id)CFRunLoopGetMain()' -o detach 2>&1)"
  common="$(printf '%s\n' "$dump" | awk '/common modes = /{p=1} p&&/contents = /{print} /common mode items/{exit}' \
            | sed -E 's/.*contents = "([^"]+)".*/\1/' | sort | paste -sd, -)"
  modes_ok="no"
  case ",$common," in *,NSEventTrackingRunLoopMode,*) case ",$common," in *,NSModalPanelRunLoopMode,*) modes_ok="yes";; esac;; esac

  # Press the probe's own menu bar item in the background: AXPress blocks while the menu tracks.
  osascript -e "with timeout of 12 seconds
    tell application \"System Events\" to tell (first process whose unix id is $PID) to click menu bar item 1 of menu bar 2
  end timeout" >/dev/null 2>&1 &
  press=$!
  sleep 2.5
  [ -n "$EVIDENCE" ] && screencapture -x "$EVIDENCE/launch-$n-menu-open.png"
  during="$(probe_mcp_status "$SUITE")"
  osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1   # Escape closes the menu
  sleep 1
  after="$(probe_mcp_status "$SUITE")"
  kill "$press" 2>/dev/null; wait "$press" 2>/dev/null

  verdict="PASS"
  [ "$modes_ok" = yes ] && [ "$during" = 200 ] && [ "$after" = 200 ] || { verdict="FAIL"; fail=1; }
  echo "launch $n: $verdict  reporting-started=$started  common-modes=[$common]  mcp-while-menu-open=$during  mcp-after=$after"

  probe_quit "$PID"
  probe_cleanup "$SUITE"
done

if [ "$fail" = 0 ]; then echo "RESULT: PASS ($LAUNCHES/$LAUNCHES launches)"; else echo "RESULT: FAIL"; fi
exit "$fail"
