#!/bin/bash
# Does "Not now" on "Continue where you left off?" stay answered across a relaunch? (TBX-7356)
#
#   scripts/probe-handoff-e2e.sh <Baton.app> [evidence-dir]
#
# <Baton.app> from scripts/probe-build.sh. Needs Docker and ffmpeg. Everything is throwaway:
# a Navidrome container on 127.0.0.1 with three silent tracks and a generated password (never
# printed; Subsonic calls use token auth, so it is not in any URL either), and a probe instance
# of the app with its own preferences suite and Keychain service. The owner's Baton, server and
# preferences are never touched. The script plays the phone's part by saving the play queue
# under the client name `baton-ios`, then drives only the probe's alert, by process id.
#
#   A. phone saves queue 1  -> launch: offer shown -> Not now -> quit
#   B. relaunch             -> NO offer (the bug: it came back at every launch), and the probe
#      did fetch the queue on that launch, so the silence is an answer, not a disconnection
#   C. phone saves queue 2  -> launch: offer shown -> Continue -> the probe plays queue 2,
#      and its MCP server reports the same song (TBX-7371)
#   D. relaunch, slot unchanged -> NO offer (Continue counts as an answer)
#
# Tracks are three minutes of silence, so the saved positions (0:42, 1:35) fall inside them.
# Exit 0 only if all four hold. Exit 3 if another probe run held the machine-wide probe lock past
# the timeout. Red on v0.19.7 (step B), green from 0.19.8.
set -uo pipefail

[ "$#" -ge 1 ] || { echo "usage: $0 <Baton.app> [evidence-dir]" >&2; exit 64; }
APP="$1"; EVIDENCE="${2:-}"
. "$(dirname "$0")/probe-lib.sh"
[ -n "$EVIDENCE" ] && mkdir -p "$EVIDENCE"
command -v docker >/dev/null && command -v ffmpeg >/dev/null || { echo "needs docker and ffmpeg" >&2; exit 2; }

PORT="${HANDOFF_E2E_PORT:-4599}"
NAME="baton-handoff-e2e-$$"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/baton-handoff-e2e.XXXXXX")"
SUITE="$(probe_new_suite handoff)"
PID=""
fail=0

cleanup() {
  # The server's own request log, for reading a mismatch rather than guessing at it. Navidrome
  # redacts the auth parameters itself.
  [ -n "$EVIDENCE" ] && docker logs "$NAME" > "$EVIDENCE/navidrome.log" 2>&1
  probe_quit "$PID"
  probe_cleanup "$SUITE"
  docker rm -f "$NAME" >/dev/null 2>&1
  rm -rf "$WORK"
  probe_lock_release
}
trap cleanup EXIT
# One probe run at a time on this machine (TBX-7383): the screen and keyboard are shared.
probe_lock_acquire || exit 3

say_step() { echo "-- $*"; }
verdict() {   # $1 = description, $2 = 0 for pass
  if [ "$2" = 0 ]; then echo "   PASS  $1"; else echo "   FAIL  $1"; fail=1; fi
}

# ---- a throwaway server -----------------------------------------------------------------
mkdir -p "$WORK/music" "$WORK/data"
for i in 1 2 3; do
  ffmpeg -loglevel error -f lavfi -i anullsrc=r=44100:cl=stereo -t 180 \
    -metadata title="Handoff Track $i" -metadata artist="Handoff Probe" \
    -metadata album="Handoff E2E" -metadata track="$i" -q:a 9 "$WORK/music/track$i.mp3" || exit 2
done
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:4533" -e ND_LOGLEVEL=debug \
  -v "$WORK/music:/music:ro" -v "$WORK/data:/data" deluan/navidrome:latest >/dev/null || exit 2
for _ in $(seq 1 60); do curl -sf "http://127.0.0.1:$PORT/ping" >/dev/null && break; sleep 1; done

USER_NAME="handoff"
PASS="$(openssl rand -hex 12)"
curl -sf -X POST "http://127.0.0.1:$PORT/auth/createAdmin" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$USER_NAME\",\"password\":\"$PASS\"}" >/dev/null || { echo "could not create the throwaway admin" >&2; exit 2; }

# Subsonic call with token auth: t = md5(password + salt).
sub() {   # $1 = endpoint, $2 = client name, rest = key=value query items
  local endpoint="$1" client="$2" q="" salt token kv
  shift 2
  for kv in "$@"; do q="$q&$kv"; done
  salt="$(openssl rand -hex 6)"
  token="$(printf '%s%s' "$PASS" "$salt" | md5 -q)"
  curl -s "http://127.0.0.1:$PORT/rest/$endpoint?u=$USER_NAME&t=$token&s=$salt&v=1.16.1&f=json&c=$client$q"
}
json() { /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin)['subsonic-response']; $1"; }

sub startScan baton-ios >/dev/null
IDS=""
for _ in $(seq 1 60); do
  IDS="$(sub search3 baton-ios query=Handoff songCount=10 |
         json "print(' '.join(s['id'] for s in sorted(d.get('searchResult3',{}).get('song',[]), key=lambda s: s.get('track',0))))" 2>/dev/null)"
  [ "$(printf '%s' "$IDS" | wc -w | tr -d ' ')" = 3 ] && break
  sleep 1
done
read -r ID1 ID2 ID3 <<<"$IDS"
[ -n "${ID3:-}" ] || { echo "the throwaway server never indexed its three tracks" >&2; exit 2; }

phone_saves() {   # $1 = current song id, $2 = position ms
  sub savePlayQueue baton-ios "id=$ID1" "id=$ID2" "id=$ID3" "current=$1" "position=$2" >/dev/null
}
slot() { sub getPlayQueue probe-check | json "q=d.get('playQueue',{}); print(q.get('changedBy'), q.get('current'), q.get('position'))"; }

# Successful getPlayQueue fetches (the app calls the `.view` form) made by the probe (every client except this script's own
# `baton-ios` and `probe-check`), from the server's debug log, paired by request id. A "no offer"
# step only means something if this rose during that launch: otherwise the probe may simply
# never have reached the server, and no offer is what a disconnected app shows too (TBX-7376).
probe_queue_fetches() {
  docker logs "$NAME" 2>&1 | awk '
    /API: New request \/rest\/getPlayQueue(\.view)?"/ && !/client=(baton-ios|probe-check) / {
      for (i = 1; i <= NF; i++) if ($i ~ /^requestId=/) asked[substr($i, 11)] = 1
    }
    /API: Successful response" endpoint=\/rest\/getPlayQueue(\.view)?( |$)/ {
      for (i = 1; i <= NF; i++) if ($i ~ /^requestId=/ && (substr($i, 11) in asked)) n++
    }
    END { print n + 0 }'
}

# ---- a probe pointed at it ------------------------------------------------------------------
# The legacy single-server keys: the app migrates them into its server list on first launch and
# moves the plaintext secret into the probe's own Keychain service (NavidromeConfig).
defaults write "$SUITE" tonebox.navidrome.url "http://127.0.0.1:$PORT"
defaults write "$SUITE" tonebox.navidrome.username "$USER_NAME"
defaults write "$SUITE" tonebox.navidromeSecret "$PASS"

offer_visible() {   # $1 = pid; "yes" when a sheet with the handoff question is up
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $1)
    repeat with w in windows
      repeat with s in sheets of w
        if ((value of every static text of s) as text) contains \"Continue where you left off\" then return \"yes\"
      end repeat
    end repeat
    return \"no\"
  end tell" 2>/dev/null || echo "error"
}
wait_for_offer() {   # $1 = pid, $2 = seconds; prints yes/no
  local i
  for i in $(seq 1 "$2"); do [ "$(offer_visible "$1")" = yes ] && { echo yes; return; }; sleep 1; done
  echo no
}
# A "no offer" step that means something (TBX-7376). While this step watches (up to 25 s), the
# probe must fetch the server's queue, and then show no offer for NO_OFFER_SETTLE seconds after
# that fetch. An offer at any point fails it. A fetch that completes only after the watch (a
# paused server resuming, a slow network) is not counted, because every count happens here,
# before the caller does anything else; and silence from a probe that never asked fails too.
NO_OFFER_SETTLE=8
expect_no_offer() {   # $1 = fetch count read before launch, $2 = how the offer was answered
  local got="" n i
  for i in $(seq 1 25); do
    if [ "$(offer_visible "$PID")" = yes ]; then
      verdict "no offer for the queue already $2 (an offer appeared)" 1
      return
    fi
    n="$(probe_queue_fetches)"
    if [ "$n" -gt "$1" ]; then got="$n"; break; fi
    sleep 1
  done
  if [ -z "$got" ]; then
    verdict "the probe fetched the server's queue while this step watched (fetches $1 -> $1 within 25 s)" 1
    return
  fi
  verdict "the probe fetched the server's queue while this step watched (fetches $1 -> $got)" 0
  [ "$(wait_for_offer "$PID" "$NO_OFFER_SETTLE")" = no ]
  verdict "no offer for the queue already $2, ${NO_OFFER_SETTLE} s after that fetch" $?
}
launch() {
  PID="$(probe_launch "$APP" "$SUITE")" || { echo "probe did not start" >&2; exit 2; }
}
relaunch_quit() { probe_quit "$PID"; PID=""; sleep 1; }
shot() { [ -n "$EVIDENCE" ] && screencapture -x "$EVIDENCE/$1.png"; }

say_step "A. the phone saves queue 1 at Handoff Track 2, 0:42"
phone_saves "$ID2" 42000
echo "   slot: $(slot)"
launch
[ "$(wait_for_offer "$PID" 25)" = yes ]; verdict "the probe offers the phone's queue" $?
shot A-offer
r="$(probe_press_sheet_button "$PID" "Not now")"; [ "$r" = pressed ]; verdict "Not now pressed ($r)" $?
sleep 2
[ "$(offer_visible "$PID")" = no ]; verdict "the alert closed" $?
relaunch_quit
echo "   slot after quit: $(slot)"

say_step "B. relaunch with the same queue still on the server"
case "$(slot)" in baton-ios*) ;; *) echo "   INCONCLUSIVE: the probe overwrote the slot, so step B cannot test anything"; fail=1;; esac
before="$(probe_queue_fetches)"
# Self-test of the guard: HANDOFF_E2E_SELFTEST_DISCONNECT=1 pauses the server for this whole
# step, so "no offer" would be vacuous and the fetch check has to catch it (the run must FAIL).
# The server resumes only after expect_no_offer has done all its counting (TBX-7376: resuming
# first let the probe's queued request complete and be counted).
[ "${HANDOFF_E2E_SELFTEST_DISCONNECT:-0}" = 1 ] && docker pause "$NAME" >/dev/null
launch
expect_no_offer "$before" declined
shot B-relaunch
[ "${HANDOFF_E2E_SELFTEST_DISCONNECT:-0}" = 1 ] && docker unpause "$NAME" >/dev/null
relaunch_quit

say_step "C. the phone saves a different queue: Handoff Track 3, 1:35"
phone_saves "$ID3" 95000
launch
[ "$(wait_for_offer "$PID" 25)" = yes ]; verdict "a new save is offered again" $?
shot C-offer
r="$(probe_press_sheet_button "$PID" "Continue")"; [ "$r" = pressed ]; verdict "Continue pressed ($r)" $?
sleep 4
[ "$(offer_visible "$PID")" = no ]; verdict "the alert closed" $?
# What the probe actually started streaming, from its own log: the song Continue should resume.
streamed="$(/usr/bin/log show --last 30s --info --style compact \
  --predicate "processIdentifier == $PID AND subsystem == \"io.tonebox.baton\" AND category == \"StreamingPlayback\"" 2>/dev/null |
  sed -n 's/.*streaming song id \([A-Za-z0-9]*\).*/\1/p' | tail -1)"
[ "$streamed" = "$ID3" ]; verdict "Continue resumed the phone's current song (streamed ${streamed:-nothing}, expected $ID3)" $?
# The agent-facing view must agree with the window: MCP acts on the same model the user hears.
# Before TBX-7371 it answered from a second MusicModel and said "Nothing is playing" here.
np="$(probe_mcp_tool "$SUITE" music_now_playing 2>/dev/null)"
case "$np" in *"Handoff Track 3"*) r=0;; *) r=1;; esac
verdict "MCP now playing agrees with the window ($(printf '%s' "$np" | tr '\n' ' ' | cut -c1-110))" $r
shot C-continued
relaunch_quit

say_step "D. relaunch; the phone's queue 2 is still the server's snapshot"
case "$(slot)" in
  baton-ios*) ;;
  *) echo "   the probe saved its own queue on quit; the phone re-saves queue 2 unchanged"
     phone_saves "$ID3" 95000;;
esac
before="$(probe_queue_fetches)"
launch
expect_no_offer "$before" continued
relaunch_quit

if [ "$fail" = 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
exit "$fail"
