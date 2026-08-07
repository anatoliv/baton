#!/usr/bin/env python3
"""Turn downloaded CC0 tracks into the bundled demo library.

Baton ships demo audio inside a **paid** App Store binary *and* in a public MIT
repository. That pair is stricter than people expect:

  CC0 / public domain  ✅  no attribution, no conditions, survives being forked
  CC BY                ⚠️  the attribution duty passes to everyone who forks the repo
  CC BY-SA             ⚠️  share-alike over audio inside a distributed binary
  CC BY-NC             ❌  disqualified outright — the App Store build is paid

So this only accepts CC0 or public domain, and *refuses to run* otherwise. The rule
lives here rather than in someone's memory because the failure is silent: a CC-BY-NC
track sounds exactly like a CC0 one.

The audio used to be synthesized (see make-demo-audio.py) precisely to dodge this, and
that stays as the fallback. It was replaced because synthesized pads, however carefully
voiced, don't sound like music.

Usage:

    1. Download 3-6 CC0 tracks. Sources that actually work (both need a free account,
       which is why this script can't fetch them for you):
         - https://musopen.org/search/?license=cc0     public-domain classical, CC0 subset
         - https://freesound.org  filtered to "Creative Commons 0"
    2. Put them in ios/DemoSource/ alongside a credits.json:

         [{"file": "rain.wav", "title": "Rain", "artist": "Someone",
           "licence": "CC0-1.0", "source": "https://freesound.org/s/12345/"}]

    3. python3 ios/scripts/import-demo-audio.py

Output: ios/Resources/Demo/demo-N.m4a (tagged), a generated sleeve per track, and
CREDITS.md recording where every second of it came from.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEMO = os.path.join(HERE, "..", "Resources", "Demo")
# Deliberately *outside* Resources/: that whole tree is copied into the app bundle, so
# source material living under it would ship 8 MB of MP3s to every user to no purpose.
SOURCE = os.path.join(HERE, "..", "DemoSource")

# The only licences that survive a paid binary *and* a public fork.
ALLOWED = {"CC0", "CC0-1.0", "CC0 1.0", "PUBLIC DOMAIN", "PD"}

# Long enough to show the player working, short enough that four of them stay a
# reasonable thing to carry in an app bundle.
MAX_SECONDS = 75
BITRATE = "96000"          # AAC, mono-ish source material; ~700KB a minute


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def duration(path: str) -> float:
    out = subprocess.run(["afinfo", path], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "estimated duration" in line:
            return float(line.split(":")[1].strip().split()[0])
    return 0.0


def check_licences(entries: list[dict]) -> None:
    """The guard. A wrong licence here is invisible in the finished app."""
    for entry in entries:
        licence = str(entry.get("licence", "")).strip().upper()
        if licence not in ALLOWED:
            fail(
                f'"{entry.get("file")}" is licensed "{entry.get("licence")}".\n'
                f"       Only {sorted(ALLOWED)} may be bundled: this ships inside a paid\n"
                f"       binary and a public MIT repo, and anything with an attribution or\n"
                f"       non-commercial condition breaks one or both."
            )
        if not str(entry.get("source", "")).startswith("http"):
            fail(f'"{entry.get("file")}" has no source URL. Provenance is not optional — '
                 f"a licence you can't point at is a licence you can't defend.")


def convert(src: str, dst: str, title: str, artist: str, album: str) -> None:
    """Trim, normalise and encode to AAC, carrying real metadata."""
    seconds = min(duration(src), MAX_SECONDS)
    # A short fade at each end: a hard cut into a trimmed track sounds like a fault,
    # and the last thing a demo should do is sound broken.
    subprocess.run(
        ["ffmpeg", "-y", "-i", src, "-t", str(seconds),
         "-af", f"afade=t=in:st=0:d=0.4,afade=t=out:st={max(0, seconds-1.2)}:d=1.2,"
                "loudnorm=I=-16:TP=-1.5:LRA=11",
         "-c:a", "aac", "-b:a", BITRATE, "-ar", "44100",
         "-metadata", f"title={title}", "-metadata", f"artist={artist}",
         "-metadata", f"album={album}", dst],
        check=True, capture_output=True,
    )


def main() -> None:
    manifest = os.path.join(SOURCE, "credits.json")
    if not os.path.isdir(SOURCE) or not os.path.exists(manifest):
        fail(f"put your CC0 tracks and a credits.json in {SOURCE}\n"
             f"       (see the docstring at the top of this file for the format)")

    entries = json.load(open(manifest))
    if not 1 <= len(entries) <= 8:
        fail("expected between one and eight tracks")
    check_licences(entries)

    if subprocess.run(["which", "ffmpeg"], capture_output=True).returncode != 0:
        fail("ffmpeg not found — brew install ffmpeg")

    album = "Goldberg Variations"
    lines = ["# Demo library credits", "",
             "The tracks bundled for Baton's offline demo. Every one is CC0 or public",
             "domain: this ships inside a paid App Store binary and in a public MIT",
             "repository, so anything carrying an attribution or non-commercial condition",
             "would break one or both. `ios/scripts/import-demo-audio.py` enforces that and",
             "refuses to run otherwise.", ""]

    for index, entry in enumerate(entries, start=1):
        src = os.path.join(SOURCE, entry["file"])
        if not os.path.exists(src):
            fail(f'missing source file: {entry["file"]}')
        dst = os.path.join(DEMO, f"demo-{index}.m4a")
        convert(src, dst, entry["title"], entry.get("artist", "Unknown"), album)
        size = os.path.getsize(dst) / 1000
        print(f"  {entry['title'][:28]:30} {duration(dst):5.1f}s  {size:6.0f} KB")
        lines.append(f"- **{entry['title']}** — {entry.get('artist', 'Unknown')} · "
                     f"{entry['licence']} · <{entry['source']}>")

    open(os.path.join(DEMO, "CREDITS.md"), "w").write("\n".join(lines) + "\n")

    # Sleeves, from the synthesized generator's cover routine. Real cover art would carry
    # its *own* licence question — a CC0 recording says nothing about the photograph on
    # someone's release — so the artwork stays generated even though the audio no longer is.
    covers(entries, album)
    print(f"\nWrote {len(entries)} tracks, {len(entries)} sleeves and CREDITS.md.")


# A palette per track. Kept muted: these sit behind a blurred full-bleed backdrop in the
# album view, and saturated sleeves turn that into a colour wash.
PALETTES = [
    ((214, 199, 173), (92, 68, 51)),
    ((176, 190, 197), (48, 63, 79)),
    ((205, 184, 196), (77, 52, 71)),
    ((186, 199, 184), (52, 71, 58)),
]


def covers(entries: list[dict], album: str) -> None:
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "gen", os.path.join(HERE, "make-demo-audio.py"))
    gen = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gen)
    for index, entry in enumerate(entries, start=1):
        top, bottom = PALETTES[(index - 1) % len(PALETTES)]
        gen.cover(os.path.join(DEMO, f"demo-{index}-cover.png"),
                  entry["title"], entry.get("artist", "Unknown"), top, bottom, index)


if __name__ == "__main__":
    main()
