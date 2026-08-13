#!/usr/bin/env python3
"""
Measure what the AVAudioEngine deck costs in energy, against AVPlayer, on the Mac.

This is the measurement the audio-engine work has been missing since the design doc:
everything else about the engine has been argued or heard, and its one real cost —
decoding in-process instead of using AVPlayer's optimised path — has never been a number.
It decides whether the experimental toggle ever becomes the default, and on iOS it decides
whether the engine ships at all.

It needs no interaction. It flips the setting, relaunches Baton, starts the same music both
ways, and reads per-process energy from `powermetrics`.

    sudo -v                      # once, so the samplers don't prompt mid-run
    ./scripts/energy-ab.py --minutes 10

Why it interleaves rather than running A then B: a laptop that has been playing for twenty
minutes is a different machine from one that just started — thermals, fan, other apps, the
display. Running off/on/off/on and comparing medians cancels most of that. A single A-then-B
pass would attribute the room's temperature to the audio engine.

What it cannot do: measure the phone. iOS has no equivalent hook and the simulator runs on
this Mac's CPU, so a simulator "battery" number is a number about your Mac. The nearest
honest iOS proxy is CPU-time-per-minute-of-audio sampled inside the app, or MetricKit
signposts from real devices; see docs/audio-engine-ios.md.
"""

import argparse
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import time
import urllib.request

BUNDLE = "io.tonebox.baton"
ENGINE_KEY = "baton.music.experimentalEngine"
APP = "/Applications/Baton.app"   # overridable with --app


def mcp_endpoint():
    """Baton's own MCP server, as registered for Claude Code — it is how we drive playback."""
    try:
        config = json.load(open(os.path.expanduser("~/.claude.json")))
        server = config["mcpServers"]["baton"]
        return server["url"], server.get("headers", {})
    except Exception:
        return None, {}


def mcp_call(tool, arguments=None, timeout=25, attempts=2):
    """One retry by default.

    A single timed-out call used to abandon a run that was otherwise twenty minutes from an
    answer. These calls cross to Baton, which crosses to Navidrome — `music_random` over a
    real library is not a local operation, and ten seconds was optimistic. Losing the run to
    that is a bad trade when the whole point is a measurement that takes half an hour.
    """
    last: Exception | None = None
    for attempt in range(attempts):
        try:
            return _mcp_call_once(tool, arguments, timeout)
        except Exception as error:            # noqa: BLE001 — any transport failure retries
            last = error
            if attempt + 1 < attempts:
                print(f"  (mcp {tool} failed: {error}; retrying)", flush=True)
                time.sleep(3)
    raise last


def _mcp_call_once(tool, arguments=None, timeout=25):
    url, headers = mcp_endpoint()
    if not url:
        raise RuntimeError("no Baton MCP server registered in ~/.claude.json")
    body = json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": tool, "arguments": arguments or {}},
    }).encode()
    request = urllib.request.Request(url, data=body, method="POST")
    request.add_header("Content-Type", "application/json")
    request.add_header("Accept", "application/json, text/event-stream")
    for key, value in headers.items():
        request.add_header(key, value)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        raw = response.read().decode()
    for line in raw.splitlines():
        if line.startswith("data: "):
            raw = line[6:]
    return json.loads(raw, strict=False)


def wait_for_mcp(seconds=60):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            mcp_call("music_now_playing", timeout=3)
            return True
        except Exception:
            time.sleep(2)
    return False


def read_engine_setting():
    """Whatever the setting was before we touched it, so we can put it back.

    Learned the hard way: an early trial run of this script flipped the setting and
    restarted Baton, and the previous value was simply gone. A measurement tool that leaves
    the machine different from how it found it has changed the thing it was measuring.
    """
    result = subprocess.run(["defaults", "read", BUNDLE, ENGINE_KEY],
                            capture_output=True, text=True)
    if result.returncode != 0:
        return None            # unset
    return result.stdout.strip() in ("1", "YES", "true")


def restore_engine_setting(previous):
    if previous is None:
        subprocess.run(["defaults", "delete", BUNDLE, ENGINE_KEY], capture_output=True)
    else:
        set_engine(previous)


def set_engine(enabled):
    """The Mac reads this once at launch, so every change needs a relaunch."""
    subprocess.run(
        ["defaults", "write", BUNDLE, ENGINE_KEY, "-bool", "YES" if enabled else "NO"],
        check=True,
    )


def relaunch():
    """Restart the app under test. Returns the moment it started, for the log check below."""
    subprocess.run(["osascript", "-e", 'tell application "Baton" to quit'],
                   capture_output=True)
    time.sleep(3)
    subprocess.run(["pkill", "-f", "/Applications/Baton.app"], capture_output=True)
    time.sleep(1)
    started = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(time.time() - 2))
    subprocess.run(["open", "-a", APP], check=True)
    if not wait_for_mcp():
        raise RuntimeError("Baton did not come up (its MCP server never answered)")
    return started


def start_playback(volume):
    mcp_call("music_set_volume", {"percent": volume})
    # Shuffle of the whole library: identical call both ways, and long enough that no arm
    # runs out of music. What plays differs between arms, which is why this runs for
    # minutes and compares medians rather than trusting one sample.
    mcp_call("music_random", {"limit": 200}, timeout=45)
    time.sleep(2)
    playing = mcp_call("music_now_playing")
    return playing


def engine_owns_playback(since):
    """Ground truth from the app's own log, not from the setting we just wrote.

    The setting being on does not prove the deck took the track — that is exactly the
    assumption that made an entire afternoon's 'reactive' now-playing bars meaningless.

    Anchored at *this arm's relaunch*, not a fixed window. It used to read the last two
    minutes, which is history rather than the present: run this script twice in a row and
    the AVPlayer arm reads the previous run's engine arm, concludes the engine took the
    track, and aborts a forty-minute measurement that was set up correctly. Measured, at
    01:54 this morning.
    """
    out = subprocess.run(
        ["/usr/bin/log", "show", "--start", since, "--predicate",
         'subsystem == "io.tonebox.baton"', "--info", "--style", "compact"],
        capture_output=True, text=True,
    ).stdout
    return "engine deck owns playback" in out


def sample_energy(seconds, interval_ms=5000):
    """Energy per sample, as a dict: Baton, coreaudiod, and the machine's CPU power.

    **Baton's row alone answers the wrong question**, which is the whole reason the plan
    ranks a system-wide A/B above everything else. In-process rendering is charged to
    Baton; a share of AVPlayer's pipeline is done for it by `coreaudiod` and charged there.
    Comparing only the app's row therefore flatters AVPlayer by exactly the amount it
    delegates — and that comparison is where the widely-quoted engine-versus-AVPlayer gap
    came from.

    So three numbers per sample: the app, the audio daemon, and total CPU power from the
    `cpu_power` sampler, which counts everything including whatever neither row names.
    """
    count = max(1, int(seconds * 1000 / interval_ms))
    proc = subprocess.run(
        ["sudo", "-n", "powermetrics", "--samplers", "tasks,cpu_power",
         "--show-process-energy", "-i", str(interval_ms), "-n", str(count)],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            "powermetrics failed — run `sudo -v` first so it can sample without prompting.\n"
            + proc.stderr.strip()[:400]
        )
    samples = []
    current = {}
    for line in proc.stdout.splitlines():
        # The tasks sampler prints one row per process; the row ends with its energy
        # impact. Matched on the row rather than a fixed column, because the column set
        # differs between machines and macOS versions.
        for name, key in (("Baton", "app"), ("coreaudiod", "coreaudiod")):
            if re.match(rf"^\s*{name}\s+\d+", line):
                numbers = re.findall(r"\d+\.\d+|\d+", line)
                if len(numbers) >= 2:
                    current[key] = float(numbers[-1])
        # `cpu_power` prints this once per sample, and it is the last thing in the sample,
        # so it doubles as the record separator.
        match = re.match(r"^CPU Power:\s+(\d+)\s*mW", line)
        if match:
            current["cpu_mw"] = float(match.group(1))
            if "app" in current:
                samples.append({"app": current.get("app", 0.0),
                                "coreaudiod": current.get("coreaudiod", 0.0),
                                "cpu_mw": current["cpu_mw"]})
            current = {}
    return samples


def run_arm(enabled, minutes, volume, verify, idle=False):
    """One arm. `idle=True` measures what the app costs while *paused*.

    The playing arms answer "what does rendering cost". They cannot answer "what does the
    engine cost when nothing is playing", because both arms play — which is why a fix aimed
    squarely at idle cost (suspending the render tap when the engine does not own playback)
    moved the playing number not at all. It was never in that number to begin with.

    Idle is the interesting half on a phone: an engine that never stops rendering silence
    keeps an I/O unit awake for as long as the app is open, which is most of the day.
    """
    set_engine(enabled)
    started = relaunch()
    start_playback(volume)
    if verify:
        time.sleep(5)
        owns = engine_owns_playback(started)
        if owns != enabled:
            raise RuntimeError(
                f"engine setting is {enabled} but the log says engine-owns-playback={owns}. "
                "Measuring the wrong thing is worse than not measuring."
            )
    if idle:
        # Pause, and let the transport fade and any owed work settle before sampling —
        # otherwise the first samples measure the stopping, not the stopped.
        mcp_call("music_pause")
        time.sleep(10)
    samples = sample_energy(minutes * 60)
    mcp_call("music_pause")
    return samples


def main():
    global APP
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--minutes", type=float, default=10,
                        help="minutes of playback per arm (default 10)")
    parser.add_argument("--rounds", type=int, default=2,
                        help="interleaved off/on rounds (default 2)")
    parser.add_argument("--volume", type=int, default=40)
    parser.add_argument("--app", default=APP,
                        help="which Baton.app to measure (default: the installed one). The "
                             "installed build may predate the engine entirely — the log "
                             "check below catches that, but pointing at a fresh Release "
                             "build is the way to measure work that has not shipped yet.")
    parser.add_argument("--idle", action="store_true",
                        help="measure while PAUSED rather than while playing — the half the "
                             "playing arms are blind to, and the one an always-rendering "
                             "engine costs most on a phone")
    parser.add_argument("--check", action="store_true",
                        help="validate every prerequisite and change nothing")
    parser.add_argument("--no-verify", action="store_true",
                        help="skip the log check that the engine really took the track")
    args = parser.parse_args()
    APP = args.app

    if not shutil.which("powermetrics"):
        sys.exit("powermetrics not found — this only runs on macOS")
    if not os.path.isdir(APP):
        sys.exit(f"{APP} not installed")
    if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode != 0:
        sys.exit("run `sudo -v` first: powermetrics needs root and must not prompt mid-run")

    # Everything that can be checked without touching anything is checked here, before the
    # first `defaults write`. The first version of this script did not do that: a one-minute
    # trial run flipped the setting and restarted Baton before failing on an unrelated
    # prerequisite. A measurement tool that changes the machine before it knows it can
    # measure is worse than no tool.
    problems = []
    if not mcp_endpoint()[0]:
        problems.append("no Baton MCP server registered in ~/.claude.json")
    else:
        # Playback is driven through Baton's own MCP server, which only exists while Baton
        # is running — and the app under test is usually *not* running when a measurement
        # starts, because the last thing anyone did was quit it. Start it here rather than
        # failing with a connection-refused that reads like a broken endpoint.
        if not wait_for_mcp(3):
            print(f"starting {APP} for the preflight…", flush=True)
            subprocess.run(["open", "-a", APP], capture_output=True)
            wait_for_mcp(60)
        try:
            reply = mcp_call("music_now_playing", timeout=5)
            if not isinstance(reply, dict) or "result" not in reply:
                problems.append(
                    f"the MCP endpoint answered but not with JSON-RPC (got {str(reply)[:60]!r}) "
                    "— playback cannot be driven unattended"
                )
        except Exception as error:
            problems.append(f"MCP call failed: {error}")

    if args.check:
        print("preflight:")
        print(f"  powermetrics : ok")
        print(f"  {APP} : ok")
        print(f"  sudo ticket  : ok")
        for problem in problems:
            print(f"  BLOCKED      : {problem}")
        if not problems:
            print("  MCP playback : ok\n\nready — run without --check")
        else:
            print("\nNot ready. Nothing was changed.")
        return
    if problems:
        sys.exit("cannot run unattended:\n  " + "\n  ".join(problems)
                 + "\n\nNothing was changed. Re-run with --check after fixing.")

    original = read_engine_setting()
    results = {False: [], True: []}
    try:
        for round_index in range(args.rounds):
            for enabled in (False, True):
                label = "engine" if enabled else "avplayer"
                what = "idle" if args.idle else "playing"
                print(f"round {round_index + 1}/{args.rounds}  {label} ({what}): "
                      f"{args.minutes} min…", flush=True)
                samples = run_arm(enabled, args.minutes, args.volume,
                                  not args.no_verify, idle=args.idle)
                if not samples:
                    sys.exit("no Baton rows in powermetrics output — is Baton playing?")
                results[enabled] += samples
                print(f"  {len(samples)} samples — Baton {statistics.median([s['app'] for s in samples]):.1f}, "
                      f"coreaudiod {statistics.median([s['coreaudiod'] for s in samples]):.1f}, "
                      f"CPU {statistics.median([s['cpu_mw'] for s in samples]):.0f} mW", flush=True)
    finally:
        # Including on Ctrl-C and on failure: the setting goes back either way.
        restore_engine_setting(original)
        print(f"\n(restored the experimental engine setting to "
              f"{'unset' if original is None else original})")

    def median(enabled, key):
        return statistics.median([s[key] for s in results[enabled]])

    print(f"\n=== while {'PAUSED' if args.idle else 'PLAYING'} (lower is better) ===")
    print(f"{'':12}{'Baton':>10}{'coreaudiod':>13}{'app+daemon':>13}{'CPU total':>12}")
    for enabled, label in ((False, "AVPlayer"), (True, "Engine")):
        print(f"  {label:10}{median(enabled, 'app'):10.1f}{median(enabled, 'coreaudiod'):13.1f}"
              f"{median(enabled, 'app') + median(enabled, 'coreaudiod'):13.1f}"
              f"{median(enabled, 'cpu_mw'):9.0f} mW   (n={len(results[enabled])})")
    # Whole-CPU power is the number that matters and also the noisiest: it counts every
    # other thing the machine chose to do during the window. Print its spread next to it, so
    # a difference smaller than the arms' own variation is visibly not a result.
    for enabled, label in ((False, "AVPlayer"), (True, "Engine")):
        values = sorted(s['cpu_mw'] for s in results[enabled])
        low = values[len(values) // 4]
        high = values[3 * len(values) // 4]
        print(f"  {label:10} CPU spread (p25–p75): {low:.0f}–{high:.0f} mW")

    daemon_delta = median(True, 'coreaudiod') - median(False, 'coreaudiod')
    cpu_delta = median(True, 'cpu_mw') - median(False, 'cpu_mw')
    print(f"\n  coreaudiod difference: {daemon_delta:+.1f}   "
          "(negative = the engine moves work OUT of the daemon, which the app-only")
    print("                          number charges to the engine and credits to nobody)")
    print(f"  whole-CPU difference : {cpu_delta:+.0f} mW   "
          "— the number the adoption decision actually rests on")

    off = median(False, 'app')
    on = median(True, 'app')
    print(f"\n  app-only, the historically quoted comparison:")
    # A ratio is only meaningful when the baseline is meaningfully above the sampler's
    # floor. AVPlayer idles at ~0.0–0.1 energy impact because it offloads decode, so
    # dividing by it produces arithmetic like "29x" that is really "0.1 rounds badly".
    # Report the absolute difference, which is the reproducible part, and offer the ratio
    # only when the denominator can carry one.
    print(f"  Difference: {on - off:+.1f} energy impact")
    if off >= 0.5:
        print(f"  Engine costs {on / off:.2f}x AVPlayer "
              f"({(on - off) / off * 100:+.0f}%)")
    else:
        print("  (no ratio: AVPlayer sits at the sampler's floor, so a multiple would be "
              "an artefact of rounding rather than a measurement)")
    print("\nOne machine, one library, one session. Treat a difference under ~10% as noise;"
          "\nrun more rounds before believing a small number.")


if __name__ == "__main__":
    main()
