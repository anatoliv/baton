#!/bin/bash
# Settings > Storage's Home Server section (M6.4, TBX-10850) against a throwaway gateway, on a
# probe instance, never the owner's Baton and never the real home server:
#
#   scripts/probe-storage-home-server.sh <Baton.app> <evidence-dir>
#
#   A. a baton-gateway built from this checkout (gateway/.build/debug/baton-gateway; run
#      `swift build --product baton-gateway` in gateway/ first) starts on 127.0.0.1 with its own
#      state directory, a throwaway token and a stand-in Kokoro (silent WAV answers)
#   B. three tiny books are made on it through its own routes (scripts/probe-seed-books.swift),
#      and the first is marked finished
#   C. the probe, pointed at that gateway, makes a book there from its import sheet
#   D. Settings > Storage: each book's title and size on the home server and the "Using ..."
#      footer are on screen (mac-storage-home-server.png)
#   E. Remove Download, then Download Again: the chapters are fetched from the gateway again and
#      match its SHA-256 digests (mac-storage-download-again-before/after.png)
#   F. Remove Download, the gateway removes the book, the probe relaunches: Render Again sends
#      it to be made again, the chapters come down and the Home Server list shows it again
#      without Refresh (mac-storage-render-again-before/after.png)
#   G. the book finished nine days ago in the listening ledger: Clippings, opened at launch and
#      left alone, offers the weekly suggestion, Always Do This removes the download and sets the
#      rule, shown in Settings > Storage (clippings-storage-suggestion*.png, mac-storage-rule-set.png)
#
# The token is generated here, kept in a 0600 file and handed over by environment, file and
# `defaults import` on stdin, never argv. Everything is stopped and removed on exit.
# Exit 0 PASS, 1 FAIL, 2 could not run, 3 another probe holds the lock (probe-lib.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/probe-lib.sh

APP="${1:?usage: $0 <Baton.app> <evidence-dir>}"
EVIDENCE="${2:?evidence dir}"
mkdir -p "$EVIDENCE"
EVIDENCE="$(cd "$EVIDENCE" && pwd -P)"
GATEWAY_BIN="${GATEWAY_BIN:-gateway/.build/debug/baton-gateway}"
[ -x "$GATEWAY_BIN" ] || { echo "no gateway at $GATEWAY_BIN (swift build --product baton-gateway in gateway/)"; exit 2; }
WORK="$(mktemp -d -t baton-storage-server)"
GATEWAY_PORT="${GATEWAY_PORT:-18951}"
KOKORO_PORT="${KOKORO_PORT:-18952}"
SUITE="$(probe_new_suite storage-server)"
PID="" GATEWAY_PID="" KOKORO_PID=""
fail=0

cleanup() {
  probe_quit "$PID"
  [ -n "$GATEWAY_PID" ] && kill "$GATEWAY_PID" 2>/dev/null
  [ -n "$KOKORO_PID" ] && kill "$KOKORO_PID" 2>/dev/null
  [ "${KEEP_PROBE:-0}" = 1 ] || probe_cleanup "$SUITE"
  rm -rf "$WORK"
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
port_free() { ! lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }
front() { osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null 2>&1; sleep 0.8; }

AX_BIN="${TMPDIR:-/tmp}/baton-probe-ax-$(shasum scripts/probe-ax.swift | cut -c1-12)"
[ -x "$AX_BIN" ] || xcrun swiftc -O -o "$AX_BIN" scripts/probe-ax.swift || { echo "could not build probe-ax"; exit 2; }
SEED_BIN="${TMPDIR:-/tmp}/baton-probe-seed-$(cat scripts/probe-seed-books.swift Packages/BatonDocuments/Sources/BatonDocuments/*.swift | shasum | cut -c1-12)"
[ -x "$SEED_BIN" ] || xcrun swiftc -O -parse-as-library -module-name SeedBooks -o "$SEED_BIN" \
  Packages/BatonDocuments/Sources/BatonDocuments/*.swift scripts/probe-seed-books.swift || { echo "could not build the seeder"; exit 2; }

probe_lock_acquire || exit 3
port_free "$GATEWAY_PORT" && port_free "$KOKORO_PORT" || { echo "port $GATEWAY_PORT or $KOKORO_PORT is taken"; exit 2; }

say "A. a throwaway gateway on 127.0.0.1:$GATEWAY_PORT"
/usr/bin/python3 - "$KOKORO_PORT" <<'PY' &
import http.server, struct, sys
pcm = bytes(24000 * 2 * 2)   # two seconds of silence, 24 kHz mono 16-bit
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

TOKEN_FILE="$WORK/token"
(umask 077; openssl rand -hex 24 > "$TOKEN_FILE")
mkdir -p "$WORK/gateway"
# Navidrome is required by the gateway's startup and unused here: a closed port on loopback.
# Exported in a subshell that then execs the gateway, so the token is in no process's argv.
(
  export BATON_GATEWAY_TOKEN="$(cat "$TOKEN_FILE")" BATON_GATEWAY_PORT="$GATEWAY_PORT" \
    BATON_STATE_FILE="$WORK/gateway/baton-state.json" BATON_TTS_KOKORO_URL="http://127.0.0.1:$KOKORO_PORT" \
    NAVIDROME_URL="http://127.0.0.1:9" NAVIDROME_USER=probe NAVIDROME_PASSWORD=probe
  exec "$GATEWAY_BIN"
) > "$WORK/gateway.log" 2>&1 &
GATEWAY_PID=$!
gw_get() {   # $1 = path; the token travels in a curl config on stdin
  printf 'header = "Authorization: Bearer %s"\n' "$(cat "$TOKEN_FILE")" \
    | curl -s -m 5 -K - "http://127.0.0.1:$GATEWAY_PORT$1"
}
wait_for 20 'gw_get /v1/books | grep -q "\"books\""'; ok=$?; verdict "the gateway answers GET /v1/books" $ok
[ "$fail" = 0 ] || { sed -n 1,20p "$WORK/gateway.log"; exit 2; }

say "B. three tiny books made on it"
mkdir -p "$WORK/books"
"$SEED_BIN" "http://127.0.0.1:$GATEWAY_PORT" "$TOKEN_FILE" "$WORK/books" | tee "$WORK/seeded"; verdict "the books were made and the first marked finished" "${PIPESTATUS[0]}"
[ "$(wc -l < "$WORK/seeded" | tr -d ' ')" = 3 ]; verdict "three books on the gateway" $?
gw_get /v1/books | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); print("   listing: %d books, used_bytes %d, maximum_bytes %d, keep_finished_days %d, available %s" % (len(d["books"]), d["used_bytes"], d["maximum_bytes"], d["keep_finished_days"], d["available"]))'

ROOT="$PROBE_SUPPORT_ROOT/$SUITE"
landed() { ls "$ROOT"/Clippings/*.m4a 2>/dev/null | wc -l | tr -d ' '; }
texts() { "$AX_BIN" texts "$PID" 2>/dev/null; }
# A button, by label, with the probe in front. Tried three times: right after the Form scrolls,
# SwiftUI can briefly rebuild its accessibility tree and the first press finds nothing.
press() { local i; for i in 1 2 3; do front; "$AX_BIN" press "$PID" "$1" >/dev/null && return 0; sleep 1; done; return 1; }
shot() {   # $1 = file name, $2 = window title
  front
  local id
  id="$("$AX_BIN" window "$PID" "$2" 2>/dev/null)"
  if [[ "$id" =~ ^[0-9]+$ ]]; then screencapture -x -o -l "$id" "$EVIDENCE/$1.png"; else screencapture -x "$EVIDENCE/$1.png"; fi
  echo "   screenshot: $EVIDENCE/$1.png"
}
launch() {   # extra --env pairs; preference sync always off; DEBUG hooks by environment only
  open -n -a "$APP" --env BATON_DEBUG_PREFERENCE_SYNC=off "$@" --args -baton.defaultsSuite "$SUITE" || return 1
  PID=""
  for _ in $(seq 1 40); do PID="$(pgrep -f -- "-baton.defaultsSuite $SUITE" | head -1)"; [ -n "$PID" ] && break; sleep 0.5; done
  [ -n "$PID" ] && echo "   probe pid $PID (suite $SUITE)"
}
open_storage() {
  front
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID)
    click (first menu item of menu 1 of menu bar item 2 of menu bar 1 whose name starts with \"Settings\")
  end tell" >/dev/null 2>&1
  sleep 2
  "$AX_BIN" select "$PID" Storage >/dev/null 2>&1
  sleep 2
}
job_field() { /usr/bin/python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['payload'][0][sys.argv[2]])" "$ROOT/Books/home-server-books.json" "$1" 2>/dev/null; }
server_digests() { gw_get "/v1/books/$1" | /usr/bin/python3 -c 'import json,sys; print("\n".join(sorted(c["sha256"] for c in json.load(sys.stdin)["chapters"] if c.get("sha256"))))'; }
local_digests() { for f in "$ROOT"/Clippings/*.m4a; do shasum -a 256 "$f" | cut -d' ' -f1; done | sort; }
log_count() { grep -c "$1" "$WORK/gateway.log"; }

say "C. a book made on the home server from the probe's import sheet"
defaults write "$SUITE" baton.documents.enabled -bool true
defaults write "$SUITE" baton.agent.gatewayURL "http://127.0.0.1:$GATEWAY_PORT"
defaults write "$SUITE" tonebox.speech.kokoroBaseURL "http://127.0.0.1:$KOKORO_PORT"
defaults write "$SUITE" baton.settings.selectedCategory storage
# The token on `defaults import`'s stdin; the app moves it into the probe's own Keychain item on
# first read (the same road scripts/probe-documents-walk.sh takes, for the same reason).
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>baton.agent.gatewayToken</key><string>%s</string></dict></plist>\n' \
  "$(cat "$TOKEN_FILE")" | defaults import "$SUITE" - || { echo "could not give the probe the token"; exit 2; }
BOOK="$WORK/the-cell.md"
printf '# The Cell\n\n## One\n\nImagine, if you can, a small room, hexagonal in shape.\n\n## Two\n\nAn electric bell rang.\n' > "$BOOK"
launch --env BATON_DEBUG_IMPORT_DOCUMENT="$BOOK" || { echo "probe did not start"; exit 2; }
wait_for 90 'texts | grep -qx "\[button\] Make Audiobook"'; ok=$?; verdict "the import sheet opened (Make Audiobook is there)" $ok
sleep "${SHEET_SETTLE:-6}"
front
[ "$(osascript -e 'tell application "System Events" to unix id of first process whose frontmost is true' 2>/dev/null)" = "$PID" ] \
  || { echo "the probe is not frontmost; no key sent"; exit 2; }
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to keystroke return" >/dev/null
wait_for 120 '[ "$(landed)" -ge 2 ]'; ok=$?; verdict "both chapters came down from the home server ($(landed))" $ok
JOB="$(job_field jobID)"; DOC="$(job_field documentID)"
[ -n "$JOB" ]; verdict "the book is remembered as made on the home server (job ${JOB:0:12})" $?

say "D. Settings > Storage lists the home server's books, sizes and footer"
open_storage
wait_for 20 'texts | grep -q "^Using "'; ok=$?; verdict "the footer says what the home server is using" $ok
while read -r _ _ title; do texts | grep -qx "$title"; verdict "\"$title\" is listed" $?; done < "$WORK/seeded"
texts | grep -qx "The Cell"; verdict "\"The Cell\" is listed" $?
texts | sed -n '/^Home Server$/,/^Using /p' | sed 's/^/   | /'
"$AX_BIN" show "$PID" "Home Server" >/dev/null 2>&1
shot mac-storage-home-server Settings

say "E. Download Again: the chapters come back from the home server, digests checked"
"$AX_BIN" scroll "$PID" 0 >/dev/null 2>&1
sleep 1
press "Remove Download"; verdict "Remove Download pressed" $?
wait_for 40 '[ "$(landed)" -eq 0 ]'; ok=$?; verdict "the book's audio left this Mac ($(landed) chapters left)" $ok
wait_for 10 'texts | grep -qx "\[button\] Download Again"'; ok=$?; verdict "the row offers Download Again" $ok
shot mac-storage-download-again-before Settings
gets_before="$(log_count "GET /v1/books/$JOB/chapters/")"
press "Download Again"; verdict "Download Again pressed" $?
wait_for 60 '[ "$(landed)" -ge 2 ]'; ok=$?; verdict "both chapters are back ($(landed))" $ok
gets_after="$(log_count "GET /v1/books/$JOB/chapters/")"
[ "$gets_after" -gt "$gets_before" ]; verdict "fetched from the gateway again (chapter GETs in its log $gets_before -> $gets_after)" $?
[ "$(local_digests)" = "$(server_digests "$JOB")" ]; verdict "each chapter's SHA-256 matches the gateway's digest" $?
local_digests | cut -c1-16 | sed 's/^/   sha256 /'
sleep 1
shot mac-storage-download-again-after Settings

say "F. Render Again: the home server removed the book, so it is sent to be made again"
press "Remove Download"; verdict "Remove Download pressed" $?
wait_for 20 '[ "$(landed)" -eq 0 ]'; ok=$?; verdict "the audio left this Mac" $ok
printf 'header = "Authorization: Bearer %s"\n' "$(cat "$TOKEN_FILE")" \
  | curl -s -m 10 -K - -X DELETE "http://127.0.0.1:$GATEWAY_PORT/v1/books/$JOB" -o /dev/null -w "   the gateway removed the book: HTTP %{http_code}\n"
# A collected book is asked about once per process, so the probe learns of the removal on its
# next launch, as it would after the home server's retention removed it while the Mac was away.
probe_quit "$PID"; PID=""; sleep 2
launch || { echo "probe did not restart"; exit 2; }
sleep 5
open_storage
wait_for 30 'texts | grep -q "Render Again"'; ok=$?; verdict "the row offers Render Again" $ok
# The Home Server section: the pane's texts after This Mac's footer ("... free on this Mac.")
# and up to the home server's own ("Using ..."). A row is its title, then its status.
server_section() { texts | sed -n '/free on this Mac\.$/,/^Using /p'; }
server_lists() { server_section | grep -qx "$1"; }
! server_lists "The Cell"; verdict "the home server's listing no longer has The Cell" $?
shot mac-storage-render-again-before Settings
puts_before="$(log_count "PUT /v1/books/$JOB")"
press "Render Again"; verdict "Render Again pressed" $?
wait_for 60 '[ "$(log_count "PUT /v1/books/$JOB")" -gt "$puts_before" ]'; ok=$?; verdict "the book was submitted to the gateway again" $ok
wait_for 60 'gw_get "/v1/books/$JOB" | grep -q "\"status\":\"ready\""'; ok=$?; verdict "the gateway made it again: ready" $ok
wait_for 90 '[ "$(landed)" -ge 2 ]'; ok=$?; verdict "both chapters came down again ($(landed))" $ok
# Without Refresh: the pane reads the listing again after Render Again (TBX-10954).
wait_for 20 'server_lists "The Cell"'; ok=$?; verdict "the Home Server list shows The Cell again without Refresh" $ok
wait_for 30 'server_section | grep -A1 -x "The Cell" | grep -qx "Ready"'; ok=$?
verdict "and says it is Ready there, as the home server does" $ok
server_section | sed 's/^/   | /'
[ "$(local_digests)" = "$(server_digests "$JOB")" ]; verdict "each chapter's SHA-256 matches the gateway's digest" $?
sleep 2
shot mac-storage-render-again-after Settings

say "G. the weekly suggestion: a book finished nine days ago"
probe_quit "$PID"; PID=""; sleep 2
# State, not a shortcut: the shared listening ledger says the book was finished nine days ago,
# as it would after listening to the end then. No suggestion has been made in this suite, so the
# weekly limit is not in the way, and no rule is set.
defaults export "$SUITE" "$WORK/prefs.plist" || { echo "could not read the probe's preferences"; exit 2; }
/usr/bin/python3 - "$WORK/prefs.plist" "$DOC" <<'LEDGER' || { echo "could not set the ledger"; exit 2; }
import json, plistlib, sys, time
path, doc = sys.argv[1], sys.argv[2]
prefs = plistlib.load(open(path, "rb"))
key = "tonebox.clippings.ledger"
ledger = json.loads(prefs[key]) if key in prefs else {"records": []}
finished = time.time() - 978307200 - 9 * 86400   # seconds since 2001, JSONEncoder's default
docs = [d for d in ledger.get("documents", []) if d["documentID"] != doc]
docs.append({"documentID": doc, "finished": True, "finishedAt": finished})
ledger["documents"] = docs
prefs[key] = json.dumps(ledger).encode()
plistlib.dump(prefs, open(path, "wb"))
LEDGER
defaults import "$SUITE" "$WORK/prefs.plist" || { echo "could not write the ledger"; exit 2; }
launch --env BATON_DEBUG_SHOW_CLIPPINGS=1 || { echo "probe did not restart"; exit 2; }
# Clippings is the first screen, and the probe stays on it: nothing is clicked. The book made
# on the home server counts as removable only once the home server has answered about it after
# launch, so the suggestion has to come when that answer lands, not only when Clippings first
# appears (TBX-10954).
front
# What this suite's preferences say about storage (BookStorage.Settings, stored as JSON), read
# with the probe running: the suggestion on offer, and the rule.
storage_field() {   # $1 = pending-ids | after-finished
  defaults export "$SUITE" - 2>/dev/null | /usr/bin/python3 -c '
import json, plistlib, sys
p = plistlib.loads(sys.stdin.buffer.read())
s = json.loads(p.get("baton.books.storage", b"{}") or b"{}")
if sys.argv[1] == "pending-ids": print(" ".join((s.get("pending") or {}).get("ids", [])))
else: print((s.get("rules") or {}).get("afterFinished", ""))' "$1"
}
# The main window is not in the probe's Accessibility tree the way Settings is, so its texts are
# not read here: the suggestion is proven by the preferences (pending, naming this book) and the
# screenshot.
wait_for 30 '[ "$(storage_field pending-ids)" = "$DOC" ]'; ok=$?; verdict "Clippings made the suggestion for The Cell (pending in the probe's settings)" $ok
sleep 1
shot clippings-storage-suggestion Baton
if ! press "Always Do This"; then
  osascript -e "with timeout of 60 seconds
    tell application \"System Events\" to tell (first process whose unix id is $PID)
      click (first button of (entire contents of window \"Baton\") whose name is \"Always Do This\")
    end tell
  end timeout" >/dev/null 2>&1
fi
wait_for 20 '[ "$(landed)" -eq 0 ]'; ok=$?; verdict "Always Do This removed the finished book's download ($(landed) chapters left)" $ok
[ "$(storage_field after-finished)" = 604800 ] || [ "$(storage_field after-finished)" = 604800.0 ]; ok=$?
verdict "the rule is stored: remove a finished book's download after 7 days ($(storage_field after-finished) s)" $ok
[ -z "$(storage_field pending-ids)" ]; verdict "the suggestion is answered (nothing pending)" $?
sleep 1
shot clippings-storage-suggestion-answered Baton
open_storage
"$AX_BIN" show "$PID" "Cleanup" >/dev/null 2>&1
# The picker's chosen value is not a static text in the Accessibility tree; the stored rule is
# checked above and the screenshot shows "After I finish a book: After 7 days".
texts | grep -q "^Removed" && texts | grep "^Removed" | head -2 | sed 's/^/   | /'
shot mac-storage-rule-set Settings

echo
[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
