#!/bin/bash
# The read-along walk, on a probe instance, never the owner's Baton:
#
#   KOKORO_URL=http://<kokoro-host>:8880 scripts/probe-read-along.sh <Baton.app> <evidence-dir>
#
#   A. a small two-chapter book is imported through the import sheet and made on this Mac
#   B. both chapters land in Clippings, each with its read-along timing kept by the audio's
#      digest (Books/read-along/<sha256>.json), checked against the chapter's own length
#   C. Play from the book row's menu, then Read Along from the same menu: a sentence is lit, and
#      a later one is lit a few seconds on (two screenshots)
#   D. a sentence further on is pressed: the player seeks to where it starts, read from the
#      probe's own MCP `baton://now-playing` resource, not from the app's log (screenshot)
#
# Kokoro is reached through a relay on 127.0.0.1 that this script owns (loopback is outside
# local network privacy, so a fresh build is not stopped by its prompt). No music server: books
# and Clippings need none. Preference sync is off. Driven through the Accessibility API by
# process id (scripts/probe-ax.swift), and screenshots are per window (`screencapture -l`).
#
# Exit 0 PASS, 1 FAIL, 2 could not run, 3 another probe holds the lock (probe-lib.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/probe-lib.sh

APP="${1:?usage: $0 <Baton.app> <evidence-dir>}"
EVIDENCE="${2:?evidence dir}"
: "${KOKORO_URL:?set KOKORO_URL to the Kokoro host (http://host:8880)}"
mkdir -p "$EVIDENCE"
EVIDENCE="$(cd "$EVIDENCE" && pwd -P)"
WORK="$(mktemp -d -t baton-read-along)"
RELAY_PORT="${RELAY_PORT:-18881}"
SUITE="$(probe_new_suite readalong)"
ROOT="$PROBE_SUPPORT_ROOT/$SUITE"
RELAY_PID=""
PID=""
fail=0
T0=$(date +%s)

AX_BIN="${TMPDIR:-/tmp}/baton-probe-ax-$(shasum scripts/probe-ax.swift | cut -c1-12)"
[ -x "$AX_BIN" ] || xcrun swiftc -O -o "$AX_BIN" scripts/probe-ax.swift || { echo "could not build probe-ax"; exit 2; }

cleanup() {
  probe_quit "$PID"
  [ -n "$RELAY_PID" ] && kill "$RELAY_PID" 2>/dev/null
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
front() { osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null 2>&1; sleep 0.8; }
shots() {   # $1 = name: one PNG per on-screen window of the probe, largest first
  front
  local n=0 wid w h
  while read -r wid w h; do
    [ -n "$wid" ] || continue
    n=$((n + 1))
    screencapture -x -o -l "$wid" "$EVIDENCE/$1-$n.png" && echo "   screenshot: $EVIDENCE/$1-$n.png (${w}x${h})"
  done < <("$AX_BIN" windows "$PID")
}
landed() { ls "$ROOT"/Clippings/*.m4a 2>/dev/null | wc -l | tr -d ' '; }
timings() { ls "$ROOT"/Books/read-along/*.json 2>/dev/null | wc -l | tr -d ' '; }
position() {   # the probe's playhead in whole seconds, from its own MCP server
  /usr/bin/python3 - "$ROOT/mcp.json" <<'PY'
import json, subprocess, sys
d = json.load(open(sys.argv[1]))
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
    text = json.loads(body)["result"]["contents"][0]["text"]
    now = json.loads(text)
    print(now.get("position_seconds", "?"), now.get("state", "?"), (now.get("now_playing") or {}).get("title", ""))
except Exception:
    print("? ? " + body[:200].replace("\n", " "))
PY
}

# ---- the book and the probe ---------------------------------------------------------------------
BOOK="$WORK/book/Read Along Test.md"
mkdir -p "$WORK/book"
cat > "$BOOK" <<'MD'
# Read Along Test

## The Cell

Imagine, if you can, a small room, hexagonal in shape, like the cell of a bee.

It is lighted neither by window nor by lamp, yet it is filled with a soft radiance.

There are no apertures for ventilation, yet the air is fresh and moving all the time.

There are no musical instruments, and yet the room is throbbing with melodious sounds.

An armchair is in the centre, and by its side a reading desk, which is all the furniture.

In the armchair there sits a swaddled lump of flesh, a woman about five feet high.

## The Surface

The light at the top was grey, and the hills were bare. He waited a long while for the wind to drop before he climbed.
MD

defaults write "$SUITE" baton.documents.enabled -bool true
defaults write "$SUITE" baton.documents.voiceEngine server
defaults write "$SUITE" baton.documents.makeBooksOn thisMac
defaults write "$SUITE" tonebox.speech.kokoroBaseURL "http://127.0.0.1:$RELAY_PORT"
/usr/bin/python3 - "$RELAY_PORT" "$KOKORO_URL" <<'PY' &
import asyncio, sys, urllib.parse
port, upstream = int(sys.argv[1]), urllib.parse.urlparse(sys.argv[2])
async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data); await writer.drain()
    except Exception: pass
    finally: writer.close()
async def handle(cr, cw):
    try: ur, uw = await asyncio.open_connection(upstream.hostname, upstream.port or 80)
    except Exception: cw.close(); return
    await asyncio.gather(pipe(cr, uw), pipe(ur, cw))
async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", port)
    async with server: await server.serve_forever()
asyncio.run(main())
PY
RELAY_PID=$!
sleep 0.5

say "A. import the book and make it on this Mac"
open -n -a "$APP" --env BATON_DEBUG_IMPORT_DOCUMENT="$BOOK" --env BATON_DEBUG_PREFERENCE_SYNC=off \
  --args -baton.defaultsSuite "$SUITE" || { echo "probe did not start"; exit 2; }
for _ in $(seq 1 40); do PID="$(pgrep -f -- "-baton.defaultsSuite $SUITE" | head -1)"; [ -n "$PID" ] && break; sleep 0.5; done
[ -n "$PID" ] || { echo "probe did not start"; exit 2; }
wait_for 60 '"$AX_BIN" texts "$PID" | grep -qx "\[button\] Make Audiobook"'; verdict "the import sheet offers Make Audiobook" $?
sleep "${SHEET_SETTLE:-4}"
"$AX_BIN" press "$PID" "Make Audiobook" >/dev/null; verdict "Make Audiobook pressed" $?

say "B. both chapters land with their read-along timing"
wait_for "${RENDER_WAIT:-240}" '[ "$(landed)" -ge 2 ] && [ "$(timings)" -ge 2 ]'
verdict "2 chapters in Clippings ($(landed)), 2 timings kept ($(timings))" $?
/usr/bin/python3 - "$ROOT" <<'PY' | tee "$EVIDENCE/timing-check.txt" | sed 's/^/   /'
import glob, json, os, sys, hashlib
root = sys.argv[1]
ok = True
for sidecar in sorted(glob.glob(os.path.join(root, "Clippings", "*.json"))):
    try: clip = json.load(open(sidecar))
    except Exception: continue
    clip = clip.get("payload", clip)
    sha = clip.get("sha256")
    if not sha or clip.get("chapterIndex") is None: continue
    timing_path = os.path.join(root, "Books", "read-along", sha + ".json")
    if not os.path.exists(timing_path):
        print(f"chapter {clip['chapterIndex'] + 1}: no timing"); ok = False; continue
    t = json.load(open(timing_path))
    segs = t["segments"]
    last = segs[-1]["end"]
    dur = clip.get("durationSeconds") or 0
    ordered = all(a["start"] <= a["end"] <= b["start"] + 1e-6 for a, b in zip(segs, segs[1:]))
    print(f"chapter {clip['chapterIndex'] + 1} \"{clip.get('chapterTitle')}\": {len(segs)} chunks, "
          f"first starts {segs[0]['start']:.2f} s, last ends {last:.2f} s, chapter {dur:.2f} s, in order: {ordered}")
    if abs(last - dur) > 0.05 or not ordered: ok = False
print("timing fits every chapter" if ok else "timing does not fit")
sys.exit(0 if ok else 1)
PY
verdict "each chapter's timing ends where its audio ends, chunks in order" "${PIPESTATUS[0]}"
cp "$(ls "$ROOT"/Books/read-along/*.json | head -1)" "$EVIDENCE/timing-sample.json" 2>/dev/null

say "C. Play, then Read Along, from the book row"
front
"$AX_BIN" menu "$PID" "Read Along Test" "Play" >/dev/null; verdict "Play from the book's menu" $?
wait_for 15 '[ "$(position | cut -d" " -f2)" = "playing" ]'; verdict "the book is playing: $(position)" $?
"$AX_BIN" menu "$PID" "Read Along Test" "Read Along" >/dev/null; verdict "Read Along from the book's menu" $?
wait_for 15 '"$AX_BIN" texts "$PID" | grep -q "Imagine, if you can"'; verdict "Read Along shows the chapter's words" $?
sleep 2
shots C-read-along-following-1
first_pos="$(position)"
sleep 6
shots C-read-along-following-2
echo "   playhead: $first_pos -> $(position)"

say "D. press a later sentence: the player seeks to where it starts"
target="$(/usr/bin/python3 - "$ROOT" <<'PY'
import glob, json, os, sys
root = sys.argv[1]
for sidecar in glob.glob(os.path.join(root, "Clippings", "*.json")):
    try: clip = json.load(open(sidecar))
    except Exception: continue
    clip = clip.get("payload", clip)
    if clip.get("chapterIndex") == 0 and clip.get("sha256"):
        segs = json.load(open(os.path.join(root, "Books", "read-along", clip["sha256"] + ".json")))["segments"]
        s = segs[-2]
        print(f"{s['start']:.2f}\t{s['text']}")
PY
)"
start="${target%%$'\t'*}"; sentence="${target#*$'\t'}"
echo "   target: \"$sentence\" at $start s"
"$AX_BIN" press "$PID" "$sentence" >/dev/null; verdict "the sentence was pressed" $?
sleep 1.5
after="$(position)"
echo "   playhead after the press: $after"
/usr/bin/python3 -c "import sys; p=float(sys.argv[1]); s=float(sys.argv[2]); sys.exit(0 if s - 1 <= p <= s + 3 else 1)" \
  "${after%% *}" "$start" 2>/dev/null
verdict "the playhead is at the pressed sentence (${after%% *} s, sentence starts $start s)" $?
shots D-read-along-after-press

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
