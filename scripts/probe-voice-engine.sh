#!/bin/bash
# Settings → Speech → Voice engine for books, on a probe instance, never the owner's
# Baton:
#
#   scripts/probe-voice-engine.sh <Baton.app> <evidence-dir> [<kokoro-model-dir>]
#
#   A. Automatic, built-in voices not downloaded, a Kokoro answering, no Chatterbox (screenshot)
#   B. Pressing "Voice server" stores it in the probe's own preferences, and with the Kokoro
#      gone its line says "not answering" (screenshot)
#   C. Built-in voices on this Mac, not downloaded: the plain refusal is on screen (screenshot)
#   D. With <kokoro-model-dir> (kokoro-v1_0.safetensors and voices.npz, checked against the
#      pinned sha256 before use): Built-in, downloaded (screenshot)
#
# The Kokoro is a stand-in on 127.0.0.1 that lists three voices, so no LAN address ends up in a
# screenshot. Nothing is downloaded. Exit 0 PASS, 1 FAIL, 2 could not run, 3 another probe holds
# the lock (probe-lib.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/probe-lib.sh

APP="${1:?usage: $0 <Baton.app> <evidence-dir> [<kokoro-model-dir>]}"
EVIDENCE="${2:?evidence dir}"
MODEL_DIR="${3:-}"
mkdir -p "$EVIDENCE"
EVIDENCE="$(cd "$EVIDENCE" && pwd -P)"
SUITE="$(probe_new_suite voice-engine)"
PID=""
FAKE=""
PORT=18880
fail=0

cleanup() {
  probe_quit "$PID"
  [ -n "$FAKE" ] && kill "$FAKE" 2>/dev/null
  [ "${KEEP_PROBE:-0}" = 1 ] || probe_cleanup "$SUITE"
  probe_lock_release
}
trap cleanup EXIT
trap 'exit 130' INT TERM
probe_lock_acquire || exit 3

say() { printf '\n== %s\n' "$1"; }
verdict() { if [ "$2" = 0 ]; then echo "   PASS  $1"; else echo "   FAIL  $1"; fail=1; fi; }
front() { osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null 2>&1; sleep 0.8; }

AX_BIN="${TMPDIR:-/tmp}/baton-probe-ax-$(shasum scripts/probe-ax.swift | cut -c1-12)"
[ -x "$AX_BIN" ] || xcrun swiftc -O -o "$AX_BIN" scripts/probe-ax.swift || { echo "could not build probe-ax"; exit 2; }
ax() { "$AX_BIN" "$1" "$PID" "$2" 2>&1; }
texts() { "$AX_BIN" texts "$PID" 2>/dev/null; }
ax_windows() { "$AX_BIN" windows "$PID" 2>/dev/null; }

shot() {   # $1 = name
  front
  local id
  id="$(ax_windows | head -1 | cut -d' ' -f1)"
  [ -n "$id" ] || { echo "   no window to capture for $1"; fail=1; return; }
  screencapture -x -o -l "$id" "$EVIDENCE/$1.png"
  echo "   screenshot: $EVIDENCE/$1.png"
}

wait_for() {   # $1 = seconds, $2 = shell condition
  local limit=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$limit" ]; do eval "$2" && return 0; sleep 1; done
  return 1
}

start_fake_kokoro() {
  /usr/bin/python3 -c '
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"voices": ["af_heart", "bf_emma", "jf_alpha"]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
' "$PORT" &
  FAKE=$!
  wait_for 10 "curl -s -m 1 http://127.0.0.1:$PORT/v1/audio/voices | grep -q af_heart"
}

launch() {
  open -n -a "$APP" --env BATON_DEBUG_PREFERENCE_SYNC=off --args -baton.defaultsSuite "$SUITE" -baton.debugCloseMainWindow -baton.debugOpenWindow settings || exit 2
  PID=""
  for _ in $(seq 1 40); do PID="$(pgrep -f -- "-baton.defaultsSuite $SUITE" | head -1)"; [ -n "$PID" ] && break; sleep 0.5; done
  [ -n "$PID" ] || { echo "probe did not start"; exit 2; }
  wait_for 30 'texts | grep -q "^Automatic$"'
}

relaunch() { probe_quit "$PID"; PID=""; sleep 1; launch; }

# The section's lines, for the log.
section_lines() { texts | grep -E "^(Automatic|Built-in voices on this Mac|Voice server|Now:|Downloaded|Not downloaded|Not available|Kokoro|Chatterbox|Voice engine for books is set to|No voice server answers|Make books on|\[button\] Download)" | sed 's/^/   /'; }

defaults write "$SUITE" baton.documents.enabled -bool true
defaults write "$SUITE" baton.settings.selectedCategory speech
defaults write "$SUITE" tonebox.speech.kokoroBaseURL "http://127.0.0.1:$PORT"

say "A. Automatic, not downloaded, a Kokoro answering"
start_fake_kokoro; verdict "the stand-in Kokoro answers" $?
launch; verdict "the Voice engine for books section is in Settings → Speech" $?
ax show "voice-engine-automatic" >/dev/null
wait_for 20 'texts | grep -q "^Kokoro at 127.0.0.1:'"$PORT"': answering, 3 voices$"'; verdict "Kokoro's line names its address and says it answers" $?
texts | grep -qx "Not downloaded"; verdict "the built-in line says Not downloaded" $?
texts | grep -qx "Chatterbox: no address set"; verdict "Chatterbox's line says no address is set" $?
texts | grep -q "^Now: the voice server for every voice"; verdict "Automatic says what it does now" $?
section_lines
shot A-automatic-server-answering

say "B. Voice server, the Kokoro gone"
ax press "voice-engine-server" | sed 's/^/   /'
sleep 1
[ "$(defaults read "$SUITE" baton.documents.voiceEngine 2>/dev/null)" = server ]; verdict "pressing Voice server stores it in this probe's own preferences" $?
kill "$FAKE" 2>/dev/null; FAKE=""
relaunch
ax show "voice-engine-server" >/dev/null
wait_for 30 'texts | grep -q "^Kokoro at 127.0.0.1:'"$PORT"': not answering$"'; verdict "Kokoro's line says not answering" $?
texts | grep -q "^No voice server answers"; verdict "Voice server with nothing answering says books will pause" $?
section_lines
shot B-voice-server-not-answering

say "C. Built-in voices on this Mac, not downloaded"
defaults write "$SUITE" baton.documents.voiceEngine builtIn
relaunch
ax show "voice-engine-builtIn" >/dev/null
sleep 2
texts | grep -q "^Voice engine for books is set to Built-in voices on this Mac, and they are not downloaded"; verdict "the refusal is said plainly" $?
section_lines
shot C-built-in-not-downloaded

if [ -n "$MODEL_DIR" ]; then
  say "D. Built-in voices on this Mac, downloaded"
  DEST="$PROBE_SUPPORT_ROOT/$SUITE/Models/kokoro-mlx"
  mkdir -p "$DEST"
  ok=0
  W_SHA=4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8
  V_SHA=56dbfa2f2970af2e395397020393d368c5f441d09b3de4e9b77f6222e790f10f
  [ "$(shasum -a 256 "$MODEL_DIR/kokoro-v1_0.safetensors" | cut -d' ' -f1)" = "$W_SHA" ] || ok=1
  [ "$(shasum -a 256 "$MODEL_DIR/voices.npz" | cut -d' ' -f1)" = "$V_SHA" ] || ok=1
  verdict "the model files match the pinned sha256" $ok
  if [ "$ok" = 0 ]; then
    cp "$MODEL_DIR/kokoro-v1_0.safetensors" "$MODEL_DIR/voices.npz" "$DEST/"
    printf '{"kokoro-v1_0.safetensors":"%s","voices.npz":"%s"}' "$W_SHA" "$V_SHA" > "$DEST/installed.json"
    start_fake_kokoro
    relaunch
    ax show "voice-engine-builtIn" >/dev/null
    wait_for 20 'texts | grep -qx "Downloaded, 28 English voices"'; verdict "the built-in line says Downloaded, 28 English voices" $?
    texts | grep -q "^Voice engine for books is set to" && r=1 || r=0; verdict "no refusal once downloaded" $r
    section_lines
    shot D-built-in-downloaded
    ax press "voice-engine-automatic" >/dev/null; sleep 1
    wait_for 20 'texts | grep -q "^Now: built-in for the 28 English voices, the voice server for the rest$"'; verdict "Automatic says built-in for English, the server for the rest" $?
    shot E-automatic-both
  fi
fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
