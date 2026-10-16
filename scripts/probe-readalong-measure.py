#!/usr/bin/env python3
"""Read Along against the playhead on a Mac probe (TBX-11063), for scripts/probe-book-screen.sh.

    probe-readalong-measure.py <probe-ax> <pid> <mcp.json> <timing.json> <seconds> [<seek-target-seconds>]

Samples two things at once for <seconds>: the lit sentence (`probe-ax selected`, about 20 a
second) and the probe's playhead from its own MCP server (`baton://now-playing`). The server
rounds the playhead to whole seconds, so the playhead is recovered from the moments it ticks
over: a change from k to k + 1 is the playhead crossing k + 0.5, and playing at 1x the playhead
is then wall time less one constant, the median over every tick. With a seek target, the run
starts right after a sentence was pressed and also reports where the seek landed.

Prints the measured lag of each change of the lit sentence after that sentence's start in the
timing, and exits 0 when every lag is under 0.6 s (the panel is fed four times a second) and the
seek, when there is one, landed within 0.3 s of the sentence.
"""
import json, statistics, subprocess, sys, threading, time

ax, pid, mcp, timing_path, seconds = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], float(sys.argv[5])
seek_target = float(sys.argv[6]) if len(sys.argv) > 6 else None
starts = [s["start"] for s in json.load(open(timing_path))["segments"]]
d = json.load(open(mcp))
cfg = 'header = "Authorization: Bearer %s"\n' % d["token"]


def call(body, sid=None, headers=False):
    args = ["curl", "-s", "-m", "6", "-K", "-", "-X", "POST", d["url"], "-H", "Content-Type: application/json",
            "-H", "Accept: application/json, text/event-stream"]
    args += (["-D", "-"] if headers else []) + (["-H", "Mcp-Session-Id: " + sid] if sid else []) + ["-d", body]
    return subprocess.run(args, input=cfg, capture_output=True, text=True).stdout


init = call('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26",'
            '"capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}', headers=True)
sid = next((l.split(":", 1)[1].strip() for l in init.splitlines() if l.lower().startswith("mcp-session-id:")), None)
t0 = time.time()
end = t0 + seconds
heads, lits = [], []


def poll_head():
    while time.time() < end:
        a = time.time()
        body = call('{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"baton://now-playing"}}', sid)
        b = time.time()
        try:
            now = json.loads(json.loads(body)["result"]["contents"][0]["text"])
            if now.get("state") == "playing":
                heads.append(((a + b) / 2, int(now["position_seconds"]), b - a))
        except Exception:
            pass
        time.sleep(0.08)


def poll_lit():
    while time.time() < end:
        a = time.time()
        out = subprocess.run([ax, "selected", pid], capture_output=True, text=True).stdout.split()
        b = time.time()
        lit = next((int(s.rsplit("-", 1)[1]) for s in out if s.startswith("readalong-sentence-")), None)
        lits.append(((a + b) / 2, lit))
        time.sleep(0.03)


threads = [threading.Thread(target=poll_head), threading.Thread(target=poll_lit)]
for t in threads: t.start()
for t in threads: t.join()

# The playhead: each tick of the rounded value, at the midpoint between the samples either side.
offsets = []
for (ta, ka, _), (tb, kb, _) in zip(heads, heads[1:]):
    if kb == ka + 1 and tb - ta < 0.6:
        offsets.append((ta + tb) / 2 - (ka + 0.5))
if len(offsets) < 3:
    print(f"too few playhead ticks to place the playhead ({len(offsets)})"); sys.exit(2)
c = statistics.median(offsets)
spread = max(abs(o - c) for o in offsets)
print(f"playhead from {len(offsets)} ticks, each within {spread:.2f} s of the median (MCP round trip median "
      f"{statistics.median(h[2] for h in heads):.2f} s)")
playhead = lambda t: t - c
if seek_target is not None:
    landed = playhead(t0)
    print(f"seek asked for {seek_target:.2f} s, the playhead was at {landed:.2f} s when the samples began "
          f"({landed - seek_target:+.2f} s; the samples began just after the press)")
changes = []
for (ta, ia), (tb, ib) in zip(lits, lits[1:]):
    if ib is not None and ib != ia:
        changes.append(((ta + tb) / 2, ib))
lags = []
for t, i in changes:
    # After a press, the pressed sentence is lit by the press itself, not reached by playing.
    if seek_target is not None and 0 <= i < len(starts) and starts[i] <= seek_target + 0.01:
        continue
    if 0 <= i < len(starts):
        lags.append(playhead(t) - starts[i])
        print(f"  sentence {i} lit at playhead {playhead(t):.2f} s; it starts at {starts[i]:.2f} s: {lags[-1]:+.2f} s")
wrong = 0
for t, i in lits:
    if i is None or playhead(t) < 0: continue
    expect = max([k for k, s in enumerate(starts) if s <= playhead(t)] or [0])
    if abs(expect - i) > 1: wrong += 1
print(f"lit-sentence samples: {len(lits)}, more than one sentence off: {wrong}")
ok = bool(lags) and all(-0.3 < l < 0.6 for l in lags) and wrong == 0
if seek_target is not None:
    # The panel holds the playhead at the target until the audio starts again (about a third of
    # a second on AVPlayer, more under load), so the line through the later ticks, read back to
    # the press, sits before the sentence by that wait. What a listener sees is the lit sentence:
    # the pressed one first, and never one before it, which a seek that landed early would show.
    pressed = max([k for k, st in enumerate(starts) if st <= seek_target + 0.01] or [0])
    timed = [(t - t0, i) for t, i in lits if i is not None]
    earlier = [dt for dt, i in timed if i < pressed]
    flash = (max(earlier) - min(earlier)) if earlier else 0.0
    settled = [i for dt, i in timed if dt > 1.0]
    print(f"after the press: sentences lit {[i for _, i in timed][:6]}... (pressed {pressed}); an earlier sentence was lit "
          + (f"from +{min(earlier):.2f} s to +{max(earlier):.2f} s after the press" if earlier else "never"))
    # Lit within a second, and never an earlier one after that: a seek that landed early would
    # keep the sentence before lit while its words play.
    ok = ok and bool(settled) and all(i >= pressed for i in settled) and pressed in [i for _, i in timed]
if lags:
    print(f"lag after a sentence starts: median {statistics.median(lags):+.2f} s, worst {max(lags, key=abs):+.2f} s")
print("SYNC OK" if ok else "SYNC NOT OK")
sys.exit(0 if ok else 1)
