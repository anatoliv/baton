#!/bin/bash
# Book covers on the Mac, on a probe instance against a throwaway gateway, never the
# owner's Baton and never the real home server:
#
#   GATEWAY_URL=http://127.0.0.1:<port> GATEWAY_TOKEN_FILE=<0600 file> GATEWAY_BOOKS=<its books dir> \
#     scripts/probe-book-covers.sh <Baton.app> <evidence-dir> mac|covers|back|remove
#
# The gateway is started by the caller from this checkout (gateway/.build/debug/baton-gateway,
# with a stand-in Kokoro), so the iPhone simulator can use the same one between the phases.
#
#   mac     A. an EPUB with its own cover picture is imported and made into a book: the book
#              keeps the EPUB's cover, and the cover reaches the gateway's record of the book
#           B. Make a Cover (the row's menu): a designed PNG, sent to the gateway
#           C. Find Cover… (the row's menu): Open Library's candidates (only the title and author
#              are sent), Use Cover: a JPEG, sent to the gateway
#           D. the open book's header and Now Playing show it while a chapter plays
#   covers  B to D alone, on a kept suite (SUITE=) whose book is already made
#   macmade a book made on this Mac by its own renderer (KOKORO_URL= the stand-in voice server):
#           its EPUB cover reaches the gateway as soon as the book does; Remove Cover; then
#           Choose Image… with the EPUB file itself, which puts the same picture back
#   finderrors  Find Cover… when Open Library cannot be reached and when it does not answer, the
#           search pointed at a loopback port by the DEBUG override BATON_DEBUG_OPEN_LIBRARY_SEARCH
#           (nothing listening; then a listener that never answers), never the network settings
#   back    the iPhone changed the cover: this Mac fetches it from the gateway (SUITE= the kept one)
#   remove  Remove Cover (the row's menu): gone here, and removed on the gateway for every device
#
# KEEP_PROBE=1 keeps the probe's suite and files for the next phase; SUITE= reuses one.
# Exit 0 PASS, 1 FAIL, 2 could not run, 3 another probe holds the lock (probe-lib.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/probe-lib.sh

APP="${1:?usage: $0 <Baton.app> <evidence-dir> mac|covers|back|remove|macmade|finderrors}"
EVIDENCE="${2:?evidence dir}"
PHASE="${3:?phase: mac, back or remove}"
: "${GATEWAY_URL:?}" "${GATEWAY_TOKEN_FILE:?}" "${GATEWAY_BOOKS:?}"
mkdir -p "$EVIDENCE"
EVIDENCE="$(cd "$EVIDENCE" && pwd -P)"
AX_BIN="${TMPDIR:-/tmp}/baton-probe-ax-$(shasum scripts/probe-ax.swift | cut -c1-12)"
[ -x "$AX_BIN" ] || xcrun swiftc -O -o "$AX_BIN" scripts/probe-ax.swift || { echo "could not build probe-ax"; exit 2; }
TITLE="${BOOK_TITLE:-The Machine Stops}"

probe_lock_acquire || exit 3
SUITE="${SUITE:-$(probe_new_suite covers)}"
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
relaunch() { probe_quit "$PID"; PID=""; sleep 2; launch "$@"; }
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
# The book's row: one button read as "<title>, <author>, …".
shows_book() { texts | grep -qE "^\[button\] $TITLE(,|$)"; }
press() { local i; for i in 1 2 3; do front; "$AX_BIN" press "$PID" "$1" >/dev/null && return 0; sleep 1; done; return 1; }
row_menu() {   # choose $1 from the book row's context menu
  local i out
  for i in 1 2 3; do
    front; out="$("$AX_BIN" menu "$PID" "$TITLE" "$1" 2>&1)"
    [ "$out" = done ] && return 0
    echo "   (menu: $out)"; sleep 1
  done
  return 1
}
shot() {
  front
  local id; id="$("$AX_BIN" windows "$PID" 2>/dev/null | head -1 | cut -d' ' -f1)"
  if [[ "$id" =~ ^[0-9]+$ ]]; then screencapture -x -o -l "$id" "$EVIDENCE/$1.png"; else screencapture -x "$EVIDENCE/$1.png"; fi
  echo "   screenshot: $EVIDENCE/$1.png"
}
# The gateway's record of the book's cover: "<sha256 or REMOVED> <kind> <bytes>", or "none".
gateway_cover() {
  local f
  f="$(ls "$GATEWAY_BOOKS"/*/cover.json 2>/dev/null | head -1)"
  [ -n "$f" ] || { echo none; return; }
  /usr/bin/python3 -I -c "import json,sys; c=json.load(open(sys.argv[1])); print(c.get('sha256') or 'REMOVED', c.get('kind'), c.get('bytes'))" "$f"
}
# This Mac's record: "<source> <sha256> <needsPush>" for the book, or "none".
local_cover() {
  /usr/bin/python3 -I -c "
import json,sys
try: entries=json.load(open(sys.argv[1]))['payload']
except Exception: print('none'); sys.exit()
for e in entries:
    print(e.get('source') or 'removed', e.get('sha256') or '-', e.get('needsPush')); break
else: print('none')" "$ROOT/Books/covers/covers.json"
}
show_state() { echo "   this Mac: $(local_cover)"; echo "   gateway:  $(gateway_cover)"; }
synced() {   # the Mac's picture is the gateway's, nothing waiting to go
  local l g; l="$(local_cover)"; g="$(gateway_cover)"
  [ "$(echo "$l" | cut -d' ' -f2)" = "$(echo "$g" | cut -d' ' -f1)" ] && [ "$(echo "$l" | cut -d' ' -f3)" = False ]
}

# An EPUB with its own cover picture (a deep red ground with a pale band) and two short chapters.
make_epub() {   # $1 = path, $2 = title
  /usr/bin/python3 -I - "$1" "$2" <<'PY'
import struct, sys, zipfile, zlib
def png(w, h):   # a 2:3 picture: a deep red ground with a pale band, real pixels
    rows = []
    for y in range(h):
        band = h * 0.42 < y < h * 0.58
        rows.append(b"\0" + (bytes([236, 226, 205]) if band else bytes([122, 28, 36])) * w)
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")
z = zipfile.ZipFile(sys.argv[1], "w")
z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip")
z.writestr("META-INF/container.xml", '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
z.writestr("OEBPS/content.opf", '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">probe-covers</dc:identifier>
<dc:title>%s</dc:title><dc:creator>E. M. Forster</dc:creator><dc:language>en</dc:language></metadata>
<manifest><item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>
<item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/>
<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest>
<spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>''' % sys.argv[2])
z.writestr("OEBPS/nav.xhtml", '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol><li><a href="c1.xhtml">The Air-Ship</a></li><li><a href="c2.xhtml">The Mending Apparatus</a></li></ol></nav></body></html>')
z.writestr("OEBPS/c1.xhtml", '<html xmlns="http://www.w3.org/1999/xhtml"><body><h1>The Air-Ship</h1><p>Imagine, if you can, a small room, hexagonal in shape, like the cell of a bee.</p></body></html>')
z.writestr("OEBPS/c2.xhtml", '<html xmlns="http://www.w3.org/1999/xhtml"><body><h1>The Mending Apparatus</h1><p>By a vestibule, by a lift, by a tubular railway, by a platform.</p></body></html>')
z.writestr("OEBPS/cover.png", png(400, 600))
z.close()
PY
}

# The probe's own baton://now-playing, through its MCP server (address and token from its mcp.json).
now_playing_json() {
  /usr/bin/python3 -I - "$ROOT/mcp.json" <<'PY'
import json, subprocess, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("{}"); sys.exit()
cfg = 'header = "Authorization: Bearer %s"\n' % d["token"]
def call(body, sid=None, headers=False):
    args = ["curl", "-s", "-m", "6", "-K", "-", "-X", "POST", d["url"],
            "-H", "Content-Type: application/json", "-H", "Accept: application/json, text/event-stream"]
    args += ["-D", "-"] if headers else []
    args += ["-H", "Mcp-Session-Id: " + sid] if sid else []
    args += ["-d", body]
    return subprocess.run(args, input=cfg, capture_output=True, text=True).stdout
init = call('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}', headers=True)
sid = next((l.split(":", 1)[1].strip() for l in init.splitlines() if l.lower().startswith("mcp-session-id:")), None)
body = call('{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"baton://now-playing"}}', sid)
try:
    print(json.loads(body)["result"]["contents"][0]["text"])
except Exception:
    print("{}")
PY
}

configure() {
  defaults write "$SUITE" baton.documents.enabled -bool true
  defaults write "$SUITE" baton.agent.gatewayURL "$GATEWAY_URL"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>baton.agent.gatewayToken</key><string>%s</string></dict></plist>\n' \
    "$(cat "$GATEWAY_TOKEN_FILE")" | defaults import "$SUITE" - || { echo "could not give the probe the token"; exit 2; }
}

case "$PHASE" in mac|covers|back|remove|macmade|finderrors) ;; *) echo "phase: mac, covers, back, remove, macmade or finderrors"; exit 2 ;; esac

if [ "$PHASE" = mac ]; then
  say "A. an EPUB with its own cover, made into a book on the gateway"
  configure
  WORK="$(mktemp -d -t baton-covers)"
  EPUB="$WORK/the-machine-stops.epub"
  make_epub "$EPUB" "$TITLE" || { echo "could not make the EPUB"; exit 2; }
  launch --env BATON_DEBUG_IMPORT_DOCUMENT="$EPUB" || { echo "probe did not start"; exit 2; }
  wait_for 90 'texts | grep -qx "\[button\] Make Audiobook"'; ok=$?; verdict "the import sheet opened on the EPUB" $ok
  sleep "${SHEET_SETTLE:-6}"
  shot covers-import-sheet
  front
  key_to_probe 'keystroke return' 
  wait_for 120 '[ "$(ls "$ROOT"/Clippings/*.m4a 2>/dev/null | wc -l | tr -d " ")" -ge 2 ]'; ok=$?
  verdict "both chapters came down" $ok
  wait_for 20 '[ "$(local_cover | cut -d" " -f1)" = book ]'; ok=$?; verdict "the book kept the EPUB's own cover" $ok
  relaunch --env BATON_DEBUG_SHOW_BOOKS=1 || exit 2   # Baton comes to the front: the listing is read again
  wait_for 60 'synced'; ok=$?; show_state; verdict "the EPUB's cover reached the gateway" $ok
  wait_for 30 'shows_book'; sleep 2
  shot covers-1-epub-own-cover-row
fi

if [ "$PHASE" = mac ] || [ "$PHASE" = covers ]; then
  if [ -z "$PID" ]; then
    [ -d "$ROOT" ] || { echo "no kept suite $SUITE"; exit 2; }
    launch --env BATON_DEBUG_SHOW_BOOKS=1 || exit 2
    wait_for 30 'shows_book'; sleep 2
  fi
  BOOK_SHA="$(gateway_cover | cut -d' ' -f1)"

  say "B. Make a Cover"
  row_menu "Make a Cover"; verdict "Make a Cover chosen from the row's menu" $?
  wait_for 30 '[ "$(local_cover | cut -d" " -f1)" = made ] && synced'; ok=$?; show_state
  verdict "a designed cover, made here and sent to the gateway" $ok
  [ "$(gateway_cover | cut -d' ' -f2)" = png ]; verdict "the gateway now keeps the designed PNG" $?
  [ "$(gateway_cover | cut -d' ' -f1)" = "$BOOK_SHA" ] && echo "   (the same bytes the gateway already had: the same design, made again)"
  MADE_SHA="$(gateway_cover | cut -d' ' -f1)"
  sleep 2; shot covers-2-made-row

  say "C. Find Cover… on Open Library"
  row_menu "Find Cover…"; verdict "Find Cover… chosen from the row's menu" $?
  wait_for 30 'texts | grep -q "^Only the title and author are sent to Open Library"'; ok=$?; verdict "the finder sheet says what is sent" $ok
  wait_for 40 'texts | grep -qE "E\. M\. Forster, [0-9]{4}"'; ok=$?; verdict "Open Library's candidates are listed" $ok
  sleep 4; shot covers-3-finder-sheet
  texts | grep -E "E\. M\. Forster, [0-9]{4}" | head -6 | sed 's/^/   candidate: /'
  press "Use Cover"; verdict "Use Cover pressed" $?
  wait_for 40 '[ "$(local_cover | cut -d" " -f1)" = openLibrary ] && synced'; ok=$?; show_state
  verdict "Open Library's cover, kept here and sent to the gateway" $ok
  [ "$(gateway_cover | cut -d' ' -f2)" = jpeg ] && [ "$(gateway_cover | cut -d' ' -f1)" != "$MADE_SHA" ]
  verdict "the gateway now keeps a JPEG (re-encoded here)" $?
  sleep 2; shot covers-4-open-library-row

  say "D. the open book and Now Playing"
  relaunch --env BATON_DEBUG_OPEN_BOOK=1 || exit 2
  wait_for 30 'texts | grep -qx "Chapters"'; ok=$?; verdict "the book is open" $ok
  sleep 2; shot covers-5-open-book
  press "Play"; sleep 4
  shot covers-6-now-playing
  # What the system's Now Playing holds (Control Center, the menu bar widget), read back from
  # MPNowPlayingInfoCenter through the probe's own MCP server, its artwork written beside the evidence.
  relaunch --env BATON_DEBUG_OPEN_BOOK=1 --env BATON_DEBUG_NOW_PLAYING_ARTWORK_DUMP="$EVIDENCE/system-now-playing-artwork.png" || exit 2
  wait_for 30 'texts | grep -qx "Chapters"'; sleep 2
  press "Play"; sleep 5
  SYSTEM="$(now_playing_json | /usr/bin/python3 -I -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('system_now_playing')))")"
  echo "   system Now Playing: $SYSTEM"
  echo "$SYSTEM" | grep -q '"width"' && [ -s "$EVIDENCE/system-now-playing-artwork.png" ]
  verdict "the system's Now Playing carries the book's cover as its artwork" $?
fi

if [ "$PHASE" = back ]; then
  say "the cover changed on the iPhone comes to this Mac"
  [ -d "$ROOT" ] || { echo "no kept suite $SUITE"; exit 2; }
  BEFORE="$(local_cover)"; echo "   before: $BEFORE"
  launch --env BATON_DEBUG_SHOW_BOOKS=1 || exit 2
  wait_for 60 '[ "$(local_cover | cut -d" " -f1)" = homeServer ]'; ok=$?; show_state
  verdict "this Mac fetched the iPhone's cover from the gateway" $ok
  sleep 3; shot covers-7-from-iphone-row
  relaunch --env BATON_DEBUG_OPEN_BOOK=1 || exit 2
  wait_for 30 'texts | grep -qx "Chapters"'; sleep 2; shot covers-8-from-iphone-open
fi

if [ "$PHASE" = remove ]; then
  configure
  launch --env BATON_DEBUG_SHOW_BOOKS=1 || exit 2
  wait_for 30 'shows_book'; sleep 2

  say "Choose Image… (a picture file, through the open panel)"
  PICTURE="$(mktemp -d -t baton-covers-pick)/chosen-cover.png"
  /usr/bin/python3 -I - "$PICTURE" <<'PY' || { echo "could not make the picture"; exit 2; }
import struct, sys, zlib
w, h = 500, 750   # a blue and yellow chequer, 2:3
rows = b"".join(b"\0" + b"".join(bytes([40, 90, 160]) if (x // 50 + y // 50) % 2 else bytes([240, 200, 60])
                                for x in range(w)) for y in range(h))
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                              + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))
PY
  row_menu "Choose Image…"; verdict "Choose Image… chosen from the row's menu" $?
  sleep 2; front
  # The open panel runs in the probe's own process; Go to Folder takes the path.
  key_to_probe 'keystroke "g" using {command down, shift down}'
  sleep 1.5
  key_to_probe "keystroke \"$PICTURE\""
  sleep 1
  key_to_probe 'key code 36'
  sleep 1.5
  shot covers-9a-open-panel
  key_to_probe 'key code 36' 
  wait_for 30 '[ "$(local_cover | cut -d" " -f1)" = file ] && synced'; ok=$?; show_state
  verdict "the chosen picture, re-encoded here and sent to the gateway" $ok
  [ "$(gateway_cover | cut -d' ' -f2)" = jpeg ]; verdict "kept as a JPEG" $?
  sleep 2; shot covers-9b-chosen-row

  say "Remove Cover"
  row_menu "Remove Cover"; verdict "Remove Cover chosen from the row's menu" $?
  wait_for 30 '[ "$(local_cover | cut -d" " -f1)" = removed ] && [ "$(gateway_cover | cut -d" " -f1)" = REMOVED ]'; ok=$?
  show_state; verdict "removed here and on the gateway, for every device" $ok
  ls "$ROOT/Books/covers/" | grep -qE '\.(jpg|png)$' && verdict "no picture left on this Mac" 1 || verdict "no picture left on this Mac" 0
  sleep 2; shot covers-9-removed-row
fi

if [ "$PHASE" = macmade ]; then
  : "${KOKORO_URL:?KOKORO_URL= the stand-in voice server this Mac renders with}"
  say "A book made on this Mac by its own renderer"
  configure
  defaults write "$SUITE" tonebox.speech.kokoroBaseURL "$KOKORO_URL"
  WORK="$(mktemp -d -t baton-covers-mac)"
  EPUB="$WORK/made-on-this-mac.epub"
  make_epub "$EPUB" "$TITLE" || { echo "could not make the EPUB"; exit 2; }
  launch --env BATON_DEBUG_IMPORT_DOCUMENT="$EPUB" || { echo "probe did not start"; exit 2; }
  wait_for 90 'texts | grep -qx "\[button\] Make Audiobook"'; ok=$?; verdict "the import sheet opened on the EPUB" $ok
  sleep "${SHEET_SETTLE:-6}"
  press "This Mac"; verdict "Made on: This Mac chosen" $?
  sleep 1
  shot covers-m1-import-this-mac
  front
  key_to_probe 'keystroke return'
  wait_for 180 '[ "$(ls "$ROOT"/Clippings/*.m4a 2>/dev/null | wc -l | tr -d " ")" -ge 2 ]'; ok=$?
  verdict "both chapters made on this Mac" $ok
  wait_for 20 '[ "$(local_cover | cut -d" " -f1)" = book ]'; ok=$?; verdict "the book kept the EPUB's own cover" $ok
  # No relaunch: the cover follows the book as soon as the Baton server takes it.
  wait_for 90 'synced'; ok=$?; show_state; verdict "the cover reached the gateway with the book, without a relaunch" $ok
  JOB_DIR="$(dirname "$(ls "$GATEWAY_BOOKS"/*/cover.json 2>/dev/null | head -1)")"
  UPLOADED="$(/usr/bin/python3 -I -c "import json,sys; print(json.load(open(sys.argv[1])).get('uploaded'))" "$JOB_DIR/job.json" 2>/dev/null)"
  [ "$UPLOADED" = True ]; verdict "the gateway's job is the Mac's upload (uploaded: $UPLOADED), not one it made" $?
  BOOK_SHA="$(local_cover | cut -d' ' -f2)"
  wait_for 30 'shows_book'; sleep 2
  shot covers-m2-made-here-row

  say "Remove Cover, then Choose Image… with the EPUB file"
  row_menu "Remove Cover"; verdict "Remove Cover chosen from the row's menu" $?
  wait_for 30 '[ "$(local_cover | cut -d" " -f1)" = removed ] && [ "$(gateway_cover | cut -d" " -f1)" = REMOVED ]'; ok=$?
  show_state; verdict "removed here and on the gateway" $ok
  row_menu "Choose Image…"; verdict "Choose Image… chosen from the row's menu" $?
  sleep 2; front
  key_to_probe 'keystroke "g" using {command down, shift down}'
  sleep 1.5
  key_to_probe "keystroke \"$EPUB\""
  sleep 1
  key_to_probe 'key code 36'
  sleep 1.5
  key_to_probe 'key code 36'
  wait_for 30 '[ "$(local_cover | cut -d" " -f1)" = file ] && synced'; ok=$?; show_state
  verdict "the EPUB's cover, chosen as a file, kept here and sent to the gateway" $ok
  [ "$(local_cover | cut -d' ' -f2)" = "$BOOK_SHA" ]
  verdict "the same picture the import kept (the same bytes re-encoded the same way)" $?
  sleep 2; shot covers-m3-epub-chosen-row
fi

if [ "$PHASE" = finderrors ]; then
  [ -d "$ROOT" ] || { echo "no kept suite $SUITE"; exit 2; }
  CLOSED_PORT="$(/usr/bin/python3 -I -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()")"
  say "Find Cover… with nothing listening on 127.0.0.1:$CLOSED_PORT"
  launch --env BATON_DEBUG_SHOW_BOOKS=1 --env BATON_DEBUG_OPEN_LIBRARY_SEARCH="http://127.0.0.1:$CLOSED_PORT/search.json" || exit 2
  wait_for 30 'shows_book'; sleep 2
  row_menu "Find Cover…"; verdict "Find Cover… chosen from the row's menu" $?
  wait_for 20 'texts | grep -qF "couldn'"'"'t reach Open Library"'; ok=$?
  verdict "the finder says Open Library couldn't be reached" $ok
  texts | grep -F "Open Library" | sed 's/^/   /'
  shot covers-e1-offline
  press "Cancel" >/dev/null

  say "Find Cover… with a listener that never answers"
  SILENT_LOG="$(mktemp -t baton-covers-silent)"
  /usr/bin/python3 -I -c "
import socket, sys, time
s = socket.socket(); s.bind(('127.0.0.1', 0)); s.listen(8)
print(s.getsockname()[1], flush=True)
time.sleep(120)" > "$SILENT_LOG" &
  SILENT_PID=$!
  wait_for 5 '[ -s "$SILENT_LOG" ]'
  SILENT_PORT="$(head -1 "$SILENT_LOG")"
  relaunch --env BATON_DEBUG_SHOW_BOOKS=1 --env BATON_DEBUG_OPEN_LIBRARY_SEARCH="http://127.0.0.1:$SILENT_PORT/search.json" || exit 2
  wait_for 30 'shows_book'; sleep 2
  STARTED_AT="$(date +%s)"
  row_menu "Find Cover…"; verdict "Find Cover… chosen from the row's menu" $?
  wait_for 6 'texts | grep -qx "Searching Open Library…"'; ok=$?; verdict "the finder says it is searching" $ok
  shot covers-e2-searching
  wait_for 40 'texts | grep -qF "taking too long"'; ok=$?
  verdict "after $(( $(date +%s) - STARTED_AT )) s the finder says Open Library is taking too long" $ok
  texts | grep -F "Open Library" | sed 's/^/   /'
  shot covers-e3-slow
  kill "$SILENT_PID" 2>/dev/null
  press "Cancel" >/dev/null
fi

echo
[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
