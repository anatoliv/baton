#!/bin/bash
# Every voice in the Mac's voice picker, on a probe instance, never the owner's Baton:
#
#   scripts/probe-all-voices.sh <Baton.app> <evidence-dir> <built-in-model-dir>
#
#   A. a baton-gateway built from this checkout (gateway/.build/debug/baton-gateway; run
#      `swift build --product baton-gateway` in gateway/ first) on 127.0.0.1, its own state and a
#      throwaway token, with the real Kokoro (KOKORO_UPSTREAM, required) as its voice server
#   B. the import sheet with Made on: Baton server lists every voice the gateway does under
#      All voices; "british male" narrows it to the British male voices
#   C. Made on: This Mac lists the built-in voices instead (the model copied in from
#      <built-in-model-dir>, checked against its pinned sha256), fewer than the server's
#   D. George is chosen and the book is made on this Mac; the next import of an English book
#      starts on George, marked "last used"
#   E. Change Voice… on that book (DEBUG BATON_DEBUG_OPEN_CHANGE_VOICE=book) offers the same
#      picker: Now read by George, All voices, a search
#
# Screenshots: import-server-all-voices.png, import-search-british-male.png,
# import-this-mac-voices.png, import-last-used.png, change-voice.png, change-voice-search.png.
# The token is generated here, kept in a 0600 file and handed over by environment, file and
# `defaults import` on stdin, never argv. Preference sync is off. Everything is removed on exit.
# Exit 0 PASS, 1 FAIL, 2 could not run, 3 another probe holds the lock (probe-lib.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/probe-lib.sh

APP="${1:?usage: $0 <Baton.app> <evidence-dir> <built-in-model-dir>}"
EVIDENCE="${2:?evidence dir}"
MODEL_DIR="${3:?built-in model dir (kokoro-v1_0.safetensors, voices.npz)}"
mkdir -p "$EVIDENCE"
EVIDENCE="$(cd "$EVIDENCE" && pwd -P)"
KOKORO_UPSTREAM="${KOKORO_UPSTREAM:?set KOKORO_UPSTREAM to your Kokoro voice server, for example http://kokoro.local:8880}"
GATEWAY_BIN="${GATEWAY_BIN:-gateway/.build/debug/baton-gateway}"
[ -x "$GATEWAY_BIN" ] || { echo "no gateway at $GATEWAY_BIN (swift build --product baton-gateway in gateway/)"; exit 2; }
GATEWAY_PORT="${GATEWAY_PORT:-19028}"
WORK="$(mktemp -d -t baton-all-voices)"
SUITE="$(probe_new_suite all-voices)"
PID="" GATEWAY_PID=""
fail=0

cleanup() {
  probe_quit "$PID"
  [ -n "$GATEWAY_PID" ] && kill "$GATEWAY_PID" 2>/dev/null
  [ "${KEEP_PROBE:-0}" = 1 ] || probe_cleanup "$SUITE"
  [ "${KEEP_PROBE:-0}" = 1 ] && echo "kept: $WORK" || rm -rf "$WORK"
  probe_lock_release
}
trap cleanup EXIT
trap 'exit 130' INT TERM

say() { printf '\n== %s\n' "$1"; }
verdict() { if [ "$2" = 0 ]; then echo "   PASS  $1"; else echo "   FAIL  $1"; fail=1; fi; }
wait_for() {   # $1 = seconds, $2 = shell condition
  local limit=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$limit" ]; do eval "$2" && return 0; sleep 1; done
  return 1
}
front() { osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null 2>&1; sleep 0.8; }

AX_BIN="${TMPDIR:-/tmp}/baton-probe-ax-$(shasum scripts/probe-ax.swift | cut -c1-12)"
[ -x "$AX_BIN" ] || xcrun swiftc -O -o "$AX_BIN" scripts/probe-ax.swift || { echo "could not build probe-ax"; exit 2; }

probe_lock_acquire || exit 3
lsof -nP -iTCP:"$GATEWAY_PORT" -sTCP:LISTEN >/dev/null 2>&1 && { echo "port $GATEWAY_PORT is taken"; exit 2; }

say "A. a throwaway gateway on 127.0.0.1:$GATEWAY_PORT with the real Kokoro at $KOKORO_UPSTREAM"
TOKEN_FILE="$WORK/token"
(umask 077; openssl rand -hex 24 > "$TOKEN_FILE")
mkdir -p "$WORK/gateway"
(
  export BATON_GATEWAY_TOKEN="$(cat "$TOKEN_FILE")" BATON_GATEWAY_PORT="$GATEWAY_PORT" \
    BATON_STATE_FILE="$WORK/gateway/baton-state.json" BATON_TTS_KOKORO_URL="$KOKORO_UPSTREAM" \
    NAVIDROME_URL="http://127.0.0.1:9" NAVIDROME_USER=probe NAVIDROME_PASSWORD=probe
  exec "$GATEWAY_BIN"
) > "$WORK/gateway.log" 2>&1 &
GATEWAY_PID=$!
gw_get() {
  printf 'header = "Authorization: Bearer %s"\n' "$(cat "$TOKEN_FILE")" \
    | curl -s -m 10 -K - "http://127.0.0.1:$GATEWAY_PORT$1"
}
wait_for 20 'gw_get /v1/books | grep -q "\"books\""'; ok=$?; verdict "the gateway answers GET /v1/books" $ok
[ "$fail" = 0 ] || { sed -n 1,20p "$WORK/gateway.log"; exit 2; }
gw_get /v1/voices > "$EVIDENCE/gateway-voices.json"
SERVER_COUNT="$(/usr/bin/python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["voices"]))' "$EVIDENCE/gateway-voices.json" 2>/dev/null || echo 0)"
SOURCE="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sources"].get("kokoro"))' "$EVIDENCE/gateway-voices.json" 2>/dev/null)"
[ "$SERVER_COUNT" -gt 28 ] && [ "$SOURCE" = server ]; verdict "GET /v1/voices lists $SERVER_COUNT voices from Kokoro itself ($SOURCE)" $?
[ "$fail" = 0 ] || exit 2

ROOT="$PROBE_SUPPORT_ROOT/$SUITE"
texts() { "$AX_BIN" texts "$PID" 2>/dev/null; }
press() { local i; for i in 1 2 3; do front; "$AX_BIN" press "$PID" "$1" >/dev/null && return 0; sleep 1; done; return 1; }
shot() {   # $1 = file name; the frontmost window of the probe (a sheet is part of its window)
  front
  local id
  id="$("$AX_BIN" windows "$PID" 2>/dev/null | head -1 | cut -d' ' -f1)"
  if [[ "$id" =~ ^[0-9]+$ ]]; then screencapture -x -o -l "$id" "$EVIDENCE/$1.png"; else screencapture -x "$EVIDENCE/$1.png"; fi
  echo "   screenshot: $EVIDENCE/$1.png"
}
launch() {   # extra --env pairs; preference sync always off; DEBUG hooks by environment only
  open -n -a "$APP" --env BATON_DEBUG_PREFERENCE_SYNC=off "$@" --args -baton.defaultsSuite "$SUITE" || return 1
  PID=""
  for _ in $(seq 1 40); do PID="$(pgrep -f -- "-baton.defaultsSuite $SUITE" | head -1)"; [ -n "$PID" ] && break; sleep 0.5; done
  [ -n "$PID" ] && echo "   probe pid $PID (suite $SUITE)"
}
search() {   # $1 = text typed into the picker's search field
  front
  "$AX_BIN" focus "$PID" "Search voices" >/dev/null || "$AX_BIN" focus "$PID" "Search by name, accent or language" >/dev/null || return 1
  "$AX_BIN" clear "$PID" >/dev/null
  "$AX_BIN" type "$PID" "$1" >/dev/null
  sleep 1
}
chapters() { ls "$ROOT"/Clippings/*.m4a 2>/dev/null | wc -l | tr -d ' '; }
# All voices open shows group headings; the toggle is pressed only to change that.
groups() { texts | grep -E "^\[heading\] .*, (female|male)$|^\[heading\] Other voices$"; }
open_all() { groups >/dev/null || { press "all-voices"; sleep 1; }; }
close_all() { groups >/dev/null && { press "all-voices"; sleep 1; }; return 0; }

say "B. the import sheet, Made on: Baton server"
DEST="$ROOT/Models/kokoro-mlx"
mkdir -p "$DEST"
W_SHA=4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8
V_SHA=56dbfa2f2970af2e395397020393d368c5f441d09b3de4e9b77f6222e790f10f
[ "$(shasum -a 256 "$MODEL_DIR/kokoro-v1_0.safetensors" | cut -d' ' -f1)" = "$W_SHA" ] \
  && [ "$(shasum -a 256 "$MODEL_DIR/voices.npz" | cut -d' ' -f1)" = "$V_SHA" ]; verdict "the built-in model files match their pinned sha256" $?
cp "$MODEL_DIR/kokoro-v1_0.safetensors" "$MODEL_DIR/voices.npz" "$DEST/"
printf '{"kokoro-v1_0.safetensors":"%s","voices.npz":"%s"}' "$W_SHA" "$V_SHA" > "$DEST/installed.json"
defaults write "$SUITE" baton.documents.enabled -bool true
defaults write "$SUITE" baton.documents.voiceEngine builtIn
defaults write "$SUITE" baton.documents.makeBooksOn ask
defaults write "$SUITE" baton.agent.gatewayURL "http://127.0.0.1:$GATEWAY_PORT"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>baton.agent.gatewayToken</key><string>%s</string></dict></plist>\n' \
  "$(cat "$TOKEN_FILE")" | defaults import "$SUITE" - || { echo "could not give the probe the token"; exit 2; }
BOOK="$WORK/two-rooms.md"
printf '# Two Rooms\n\n## The Cell\n\nA small room, like the cell of a bee. The air was fresh.\n\n## The Door\n\nThe door opened onto a second room.\n' > "$BOOK"
launch --env BATON_DEBUG_IMPORT_DOCUMENT="$BOOK" || { echo "probe did not start"; exit 2; }
wait_for 90 'texts | grep -qx "\[button\] Make Audiobook"'; ok=$?; verdict "the import sheet opened" $ok
press "Baton server" >/dev/null 2>&1
wait_for 60 'texts | grep -qx "\[button\] All voices ($SERVER_COUNT)"'; ok=$?
verdict "Made on: Baton server offers All voices ($SERVER_COUNT), the gateway's list" $ok
texts | grep -E "^\[button\] [A-Z][a-z]+, (American|British), (female|male)" | sed 's/^/   suggested: /'
texts | grep -qE "^\[button\] [A-Z][a-z]+, (American|British), (female|male)"; verdict "the suggested voices are named in words (such as Heart, American, female)" $?
open_all; groups >/dev/null; verdict "All voices opened" $?
wait_for 10 'texts | grep -qx "\[heading\] American English, female"'; ok=$?; verdict "grouped: American English, female" $ok
shot import-server-all-voices
search "japanese"
wait_for 10 'texts | grep -qx "\[heading\] Japanese, female" && texts | grep -qx "\[heading\] Japanese, male"'; ok=$?
verdict "the server's Japanese voices are there too, grouped (a lazy list builds only what is on screen, so found by search)" $ok
search "british male"; verdict "typed british male" $?
wait_for 10 'texts | grep -qx "\[heading\] British English, male" && [ "$(groups | wc -l | tr -d " ")" = 1 ]'; ok=$?
verdict "the search leaves one group, British English, male" $ok
groups | sed 's/^/   /' 
shot import-search-british-male

say "C. Made on: This Mac follows with this Mac's own voices"
press "This Mac"; verdict "This Mac chosen" $?
wait_for 30 'texts | grep -qE "^\[button\] All voices \(([0-9]+)\)$" && ! texts | grep -qx "\[button\] All voices ($SERVER_COUNT)"'; ok=$?
MAC_COUNT="$(texts | sed -n 's/^\[button\] All voices (\([0-9]*\))$/\1/p' | head -1)"
verdict "This Mac offers its built-in voices instead: All voices (${MAC_COUNT:-none}) < $SERVER_COUNT" $ok
open_all; search ""
texts | grep -qx "\[heading\] American English, female"; verdict "the built-in list is grouped too" $?
texts | grep -q "^\[heading\] Japanese"; [ $? != 0 ]; verdict "no Japanese voices among the built-in English ones" $?
shot import-this-mac-voices
search "george"
press "George, British, male"; verdict "George chosen from All voices" $?
sleep 1
close_all
texts | grep -qE "^\[button\] George, British, male"; verdict "George stays on top with All voices closed" $?

say "D. made on this Mac in George; the next English book starts on George"
press "Make Audiobook"; verdict "Make Audiobook pressed" $?
wait_for 300 '[ "$(chapters)" -ge 2 ]'; ok=$?; verdict "both chapters were made on this Mac ($(chapters))" $ok
REMEMBERED="$(defaults read "$SUITE" baton.documents.lastVoiceByLanguage 2>/dev/null | tr -d '\n ')"
echo "   remembered: $REMEMBERED"
echo "$REMEMBERED" | grep -q 'en="kokoro:bm_george"'; verdict "George is remembered for English" $?
probe_quit "$PID"; PID=""; sleep 2
BOOK2="$WORK/third-room.md"
printf '# A Third Room\n\n## Inside\n\nThere was a third room after the second.\n' > "$BOOK2"
launch --env BATON_DEBUG_IMPORT_DOCUMENT="$BOOK2" || { echo "probe did not restart"; exit 2; }
wait_for 90 'texts | grep -qx "\[button\] Make Audiobook"'; ok=$?; verdict "the second import sheet opened" $ok
press "This Mac" >/dev/null 2>&1
wait_for 60 'texts | grep -qE "^\[button\] George, British, male, last used"'; ok=$?
texts | grep -E "^\[button\] [A-Z][a-z]+, (American|British), (female|male)" | sed 's/^/   offered: /' 
verdict "George is offered first, marked last used" $ok
shot import-last-used
press "Cancel" >/dev/null
probe_quit "$PID"; PID=""; sleep 2

say "E. Change Voice… on the book offers the same picker"
launch --env BATON_DEBUG_SHOW_CLIPPINGS=1 --env BATON_DEBUG_OPEN_CHANGE_VOICE=book || { echo "probe did not restart"; exit 2; }
wait_for 90 'texts | grep -q "^Change the voice of Two Rooms"'; ok=$?; verdict "Change Voice opened for the book" $ok
texts | grep -qx "Now read by George, British, male."; verdict "Now read by George, British, male." $?
wait_for 30 'texts | grep -qE "^\[button\] George, British, male, now"'; ok=$?; verdict "George is on top, marked now" $ok
wait_for 30 'texts | grep -qE "^\[button\] All voices \([0-9]+\)$"'; ok=$?; verdict "All voices is offered" $ok
shot change-voice
open_all
search "american female"
wait_for 10 'texts | grep -qx "\[heading\] American English, female" && [ "$(groups | wc -l | tr -d " ")" = 1 ]'; ok=$?
verdict "the search leaves one group, American English, female" $ok
shot change-voice-search
press "Cancel" >/dev/null

say "Result"
grep -c "GET /v1/voices" "$WORK/gateway.log" | sed 's/^/   GET \/v1\/voices in the gateway log: /'
[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
