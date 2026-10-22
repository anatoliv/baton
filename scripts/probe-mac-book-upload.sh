#!/bin/bash
# A book made on this Mac reaches the Baton server with every chapter, on a probe
# instance against a throwaway gateway, never the owner's Baton and never the real home server:
#
#   GATEWAY_URL=http://127.0.0.1:<port> GATEWAY_TOKEN_FILE=<0600 file> GATEWAY_BOOKS=<its books dir> \
#   KOKORO_URL=http://127.0.0.1:<port> scripts/probe-mac-book-upload.sh <Baton.app> <evidence-dir> make|check
#
# The gateway and a stand-in Kokoro are started by the caller from this checkout, so the iPhone
# simulator can collect the same book afterwards.
#
#   make   an EPUB is made into a book with "Made on: This Mac" (this Mac's own renderer, the
#          stand-in voice server); then what this Mac recorded about sending it, and what the
#          gateway holds: a build with the bug records it sent with no chapter on the gateway
#   check  relaunch the same suite (SUITE=, a newer build): the record is healed, and the
#          gateway's copy has every chapter, each byte for byte the chapter on this Mac
#
# KEEP_PROBE=1 keeps the suite for the next phase. Every key press goes only to a frontmost probe.
# Exit 0 PASS, 1 FAIL, 2 could not run, 3 another probe holds the lock (probe-lib.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/probe-lib.sh

APP="${1:?usage: $0 <Baton.app> <evidence-dir> make|check}"
EVIDENCE="${2:?evidence dir}"
PHASE="${3:?phase: make or check}"
: "${GATEWAY_URL:?}" "${GATEWAY_TOKEN_FILE:?}" "${GATEWAY_BOOKS:?}"
case "$PHASE" in make|check) ;; *) echo "phase: make or check"; exit 2 ;; esac
mkdir -p "$EVIDENCE"
EVIDENCE="$(cd "$EVIDENCE" && pwd -P)"
AX_BIN="${TMPDIR:-/tmp}/baton-probe-ax-$(shasum scripts/probe-ax.swift | cut -c1-12)"
[ -x "$AX_BIN" ] || xcrun swiftc -O -o "$AX_BIN" scripts/probe-ax.swift || { echo "could not build probe-ax"; exit 2; }
TITLE="${BOOK_TITLE:-Made Here Stops}"

probe_lock_acquire || exit 3
SUITE="${SUITE:-$(probe_new_suite upload)}"
ROOT="$PROBE_SUPPORT_ROOT/$SUITE"
PID=""
fail=0
cleanup() {
  probe_quit "$PID"
  [ "${KEEP_PROBE:-0}" = 1 ] && echo "kept suite: $SUITE" || probe_cleanup "$SUITE"
  probe_lock_release
}
trap cleanup EXIT
trap 'exit 130' INT TERM

say() { printf '\n== %s\n' "$*"; }
verdict() { if [ "$2" = 0 ]; then echo "   PASS  $1"; else echo "   FAIL  $1"; fail=1; fi; }
wait_for() { local limit=$(( $(date +%s) + $1 )); while [ "$(date +%s)" -lt "$limit" ]; do eval "$2" && return 0; sleep 1; done; return 1; }
launch() {   # extra --env pairs; preference sync always off; DEBUG hooks by environment only
  open -n -a "$APP" --env BATON_DEBUG_PREFERENCE_SYNC=off "$@" --args -baton.defaultsSuite "$SUITE" || return 1
  PID=""
  for _ in $(seq 1 40); do PID="$(pgrep -f -- "-baton.defaultsSuite $SUITE" | head -1)"; [ -n "$PID" ] && break; sleep 0.5; done
  [ -n "$PID" ] && echo "   probe pid $PID (suite $SUITE)"
}
front() { osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null 2>&1; sleep 0.8; }
# Every key press goes through here: it refuses, and the run stops, unless the probe itself is the
# frontmost app at that moment, so no key can land in another app that came to the front.
key_to_probe() {   # $1 = the System Events command, e.g. 'key code 36'
  local frontmost
  frontmost="$(osascript -e 'tell application "System Events" to unix id of first process whose frontmost is true' 2>/dev/null)"
  if [ "$frontmost" != "$PID" ]; then
    echo "   REFUSED: the probe (pid $PID) is not frontmost (pid ${frontmost:-unknown} is); no key sent"
    exit 2
  fi
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to $1" >/dev/null
}
texts() { "$AX_BIN" texts "$PID" 2>/dev/null; }
press() { local i; for i in 1 2 3; do front; "$AX_BIN" press "$PID" "$1" >/dev/null && return 0; sleep 1; done; return 1; }
shot() {
  front
  local id; id="$("$AX_BIN" windows "$PID" 2>/dev/null | head -1 | cut -d' ' -f1)"
  if [[ "$id" =~ ^[0-9]+$ ]]; then screencapture -x -o -l "$id" "$EVIDENCE/$1.png"; else screencapture -x "$EVIDENCE/$1.png"; fi
  echo "   screenshot: $EVIDENCE/$1.png"
}
# What this Mac recorded about sending its book: "accepted=… sent=[…] done=… stopped=…", or "none".
upload_record() {
  /usr/bin/python3 -I -c "
import json,sys
try: e=json.load(open(sys.argv[1]))['payload']
except Exception: print('none'); sys.exit()
for x in e: print('accepted=%s sent=%s done=%s stopped=%s' % (x.get('accepted'), x.get('sent'), x.get('done'), x.get('stopped'))); break
else: print('none')" "$ROOT/Books/mac-book-uploads.json"
}
# The gateway's copy of the book this Mac made: "<job> uploaded=… <status> ready=<n>/<total>", or "none".
gateway_book() {
  /usr/bin/python3 -I -c "
import json,glob,sys
for f in sorted(glob.glob(sys.argv[1] + '/*/job.json')):
    j = json.load(open(f))
    if j['book']['title'] != sys.argv[2]: continue
    ready = sum(1 for c in j['chapters'] if isinstance(c, dict) and 'ready' in c)
    print('%s uploaded=%s %s ready=%d/%d' % (j['id'][:12], j.get('uploaded'), j['status'], ready, len(j['chapters']))); break
else: print('none')" "$GATEWAY_BOOKS" "$TITLE"
}
all_up() {   # the gateway's copy is ready with every chapter
  gateway_book | awk '{ split($4, r, "[=/]"); exit !($3 == "ready" && r[2] == r[3] && r[3] > 0) }'
}

if [ "$PHASE" = make ]; then
  : "${KOKORO_URL:?KOKORO_URL= the stand-in voice server this Mac renders with}"
  say "A book made on this Mac by its own renderer"
  defaults write "$SUITE" baton.documents.enabled -bool true
  defaults write "$SUITE" baton.agent.gatewayURL "$GATEWAY_URL"
  defaults write "$SUITE" tonebox.speech.kokoroBaseURL "$KOKORO_URL"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>baton.agent.gatewayToken</key><string>%s</string></dict></plist>\n' \
    "$(cat "$GATEWAY_TOKEN_FILE")" | defaults import "$SUITE" - || { echo "could not give the probe the token"; exit 2; }
  WORK="$(mktemp -d -t baton-upload)"
  BOOK="$WORK/made-here.md"
  printf '# %s\n\n## The Air-Ship\n\nImagine, if you can, a small room, hexagonal in shape, like the cell of a bee.\n\n## The Mending Apparatus\n\nBy a vestibule, by a lift, by a tubular railway, by a platform.\n' "$TITLE" > "$BOOK"
  launch --env BATON_DEBUG_IMPORT_DOCUMENT="$BOOK" || { echo "probe did not start"; exit 2; }
  wait_for 90 'texts | grep -qx "\[button\] Make Audiobook"'; ok=$?; verdict "the import sheet opened" $ok
  sleep "${SHEET_SETTLE:-6}"
  press "This Mac"; verdict "Made on: This Mac chosen" $?
  sleep 1
  shot upload-1-import-this-mac
  front
  key_to_probe 'keystroke return'
  wait_for 180 '[ "$(ls "$ROOT"/Clippings/*.m4a 2>/dev/null | wc -l | tr -d " ")" -ge 2 ]'; ok=$?
  verdict "both chapters made on this Mac and in Clippings" $ok
  wait_for 60 '[ "$(gateway_book)" != none ]'; ok=$?; verdict "the gateway has the shaped book" $ok
  # Long enough for every round this launch would make.
  wait_for 45 'all_up'
  echo "   this Mac recorded: $(upload_record)"
  echo "   the gateway holds: $(gateway_book)"
  shot upload-2-made-here
fi

if [ "$PHASE" = check ]; then
  [ -d "$ROOT" ] || { echo "no kept suite $SUITE"; exit 2; }
  say "Relaunched: the book this Mac made, on the gateway with every chapter"
  echo "   before: this Mac recorded $(upload_record); the gateway holds $(gateway_book)"
  launch --env BATON_DEBUG_SHOW_BOOKS=1 || exit 2
  wait_for 90 'all_up'; ok=$?
  echo "   after:  this Mac recorded $(upload_record); the gateway holds $(gateway_book)"
  verdict "every chapter is on the gateway and the book is ready there" $ok
  upload_record | grep -q "done=True stopped=None"; verdict "this Mac's record is done, with no reason to stop" $?
  JOB="$(gateway_book | cut -d' ' -f1)"
  JOB_DIR="$(ls -d "$GATEWAY_BOOKS/$JOB"* 2>/dev/null | head -1)"
  same=0
  for n in 1 2; do
    there="$(shasum -a 256 "$JOB_DIR/chapter-$n.m4a" 2>/dev/null | cut -d' ' -f1)"
    here="$(/usr/bin/python3 -I -c "
import json,glob,sys
for f in glob.glob(sys.argv[1] + '/Clippings/*.json'):
    try: p = json.load(open(f))['payload']
    except Exception: continue
    if p.get('documentTitle') == sys.argv[2] and p.get('chapterIndex') == int(sys.argv[3]) - 1: print(p.get('sha256'))" "$ROOT" "$TITLE" "$n")"
    echo "   chapter $n: gateway ${there:0:12}, this Mac ${here:0:12}"
    [ -n "$there" ] && [ "$there" = "$here" ] && same=$((same + 1))
  done
  [ "$same" = 2 ]; verdict "each chapter on the gateway is byte for byte the one made here" $?
  sleep 2; shot upload-3-healed
fi

echo
[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
