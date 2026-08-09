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


def mcp_call(tool, arguments=None, timeout=10):
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
    subprocess.run(["osascript", "-e", 'tell application "Baton" to quit'],
                   capture_output=True)
    time.sleep(3)
    subprocess.run(["pkill", "-f", "/Applications/Baton.app"], capture_output=True)
    time.sleep(1)
    subprocess.run(["open", "-a", APP], check=True)
    if not wait_for_mcp():
        raise RuntimeError("Baton did not come up (its MCP server never answered)")


def start_playback(volume):
    mcp_call("music_set_volume", {"percent": volume})
    # Shuffle of the whole library: identical call both ways, and long enough that no arm
    # runs out of music. What plays differs between arms, which is why this runs for
    # minutes and compares medians rather than trusting one sample.
    mcp_call("music_random", {"limit": 200})
    time.sleep(2)
    playing = mcp_call("music_now_playing")
    return playing


def engine_owns_playback():
    """Ground truth from the app's own log, not from the setting we just wrote.

    The setting being on does not prove the deck took the track — that is exactly the
    assumption that made an entire afternoon's 'reactive' now-playing bars meaningless.
    """
    out = subprocess.run(
        ["/usr/bin/log", "show", "--last", "2m", "--predicate",
         'subsystem == "io.tonebox.baton"', "--info", "--style", "compact"],
        capture_output=True, text=True,
    ).stdout
    return "engine deck owns playback" in out


def sample_energy(seconds, interval_ms=5000):
    """Per-process energy impact for Baton, via powermetrics. Returns a list of samples."""
    count = max(1, int(seconds * 1000 / interval_ms))
    proc = subprocess.run(
        ["sudo", "-n", "powermetrics", "--samplers", "tasks", "--show-process-energy",
         "-i", str(interval_ms), "-n", str(count)],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            "powermetrics failed — run `sudo -v` first so it can sample without prompting.\n"
            + proc.stderr.strip()[:400]
        )
    samples = []
    for line in proc.stdout.splitlines():
        # The tasks sampler prints one row per process; Baton's row ends with its energy
        # impact. Matched on the row rather than a fixed column, because the column set
        # differs between machines and macOS versions.
        if re.match(r"^\s*Baton\s+\d+", line):
            numbers = re.findall(r"\d+\.\d+|\d+", line)
            if len(numbers) >= 2:
                samples.append(float(numbers[-1]))
    return samples


def run_arm(enabled, minutes, volume, verify):
    set_engine(enabled)
    relaunch()
    start_playback(volume)
    if verify:
        time.sleep(5)
        owns = engine_owns_playback()
        if owns != enabled:
            raise RuntimeError(
                f"engine setting is {enabled} but the log says engine-owns-playback={owns}. "
                "Measuring the wrong thing is worse than not measuring."
            )
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
                print(f"round {round_index + 1}/{args.rounds}  {label}: "
                      f"{args.minutes} min…", flush=True)
                samples = run_arm(enabled, args.minutes, args.volume, not args.no_verify)
                if not samples:
                    sys.exit("no Baton rows in powermetrics output — is Baton playing?")
                results[enabled] += samples
                print(f"  {len(samples)} samples, median energy impact "
                      f"{statistics.median(samples):.1f}", flush=True)
    finally:
        # Including on Ctrl-C and on failure: the setting goes back either way.
        restore_engine_setting(original)
        print(f"\n(restored the experimental engine setting to "
              f"{'unset' if original is None else original})")

    off = statistics.median(results[False])
    on = statistics.median(results[True])
    print("\n=== energy impact (lower is better) ===")
    print(f"  AVPlayer : {off:8.1f}   (n={len(results[False])})")
    print(f"  Engine   : {on:8.1f}   (n={len(results[True])})")
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
