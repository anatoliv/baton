#!/usr/bin/env python3
"""Generate the bundled demo library's audio.

Baton's demo mode needs music it can ship inside a PAID app, so the tracks are
synthesized here rather than sourced. That sidesteps the licensing question entirely:
Creative Commons material is usually NonCommercial (the Navidrome demo server's
netBloc catalogue is), which a paid App Store binary cannot carry.

Deliberately short — four pieces of 50-75s plus their cover art come to about 3.3 MB
total, which is a reasonable thing to carry in an app bundle. Regenerate any time:

    python3 ios/scripts/make-demo-audio.py

Output: ios/Resources/Demo/*.m4a (tagged, so the app reads real metadata) plus a
generated cover PNG per track.
"""
import math
import os
import subprocess
import wave

import numpy as np
from PIL import Image, ImageDraw, ImageFont

RATE = 44_100
OUT = os.path.join(os.path.dirname(__file__), "..", "Resources", "Demo")

# name, artist, chord progression (semitones from A2), tempo, brightness, cover colours
TRACKS = [
    ("First Light",    "Tonebox", [[0, 4, 7, 11], [5, 9, 12, 16], [7, 11, 14, 17], [2, 5, 9, 12]], 0.55, 1.0,
     ((250, 214, 165), (198, 91, 60))),
    ("Long Way Home",  "Tonebox", [[0, 3, 7, 10], [5, 8, 12, 15], [3, 7, 10, 14], [0, 3, 7, 12]], 0.48, 0.8,
     ((92, 124, 140), (26, 38, 58))),
    ("Paper Lanterns", "Tonebox", [[5, 9, 12, 16], [7, 11, 14, 19], [0, 4, 9, 12], [2, 7, 11, 14]], 0.62, 1.2,
     ((240, 176, 96), (140, 60, 96))),
    ("Static Bloom",   "Tonebox", [[2, 5, 9, 14], [0, 3, 7, 12], [7, 10, 14, 17], [5, 8, 12, 15]], 0.42, 0.7,
     ((104, 158, 138), (30, 54, 62))),
]
ALBUM = "Baton Demo"
COVER_PX = 1000


def note(semitones: float) -> float:
    """A2 = 110 Hz reference."""
    return 110.0 * (2 ** (semitones / 12.0))


def pad(freq: float, duration: float, brightness: float, gain: float) -> np.ndarray:
    """A warm additive pad: a few partials, slow attack, long release."""
    t = np.linspace(0, duration, int(RATE * duration), endpoint=False)
    voice = np.zeros_like(t)
    for partial, weight in ((1, 1.0), (2, 0.32), (3, 0.14), (4, 0.07)):
        detune = 1 + 0.0015 * partial            # gentle chorus so it isn't sterile
        voice += weight * (brightness ** (partial - 1)) * np.sin(2 * np.pi * freq * partial * detune * t)
    attack, release = 0.35, 0.55
    env = np.ones_like(t)
    a = int(RATE * attack)
    r = int(RATE * release)
    env[:a] = np.linspace(0, 1, a) ** 1.6
    env[-r:] = np.linspace(1, 0, r) ** 1.4
    # Slow tremolo keeps a long pad from sounding frozen.
    env *= 1 + 0.05 * np.sin(2 * np.pi * 0.23 * t)
    return voice * env * gain


def arpeggio(chord, base_time: float, step: float, brightness: float) -> np.ndarray:
    """A sparse bell line over the pad."""
    total = int(RATE * base_time)
    out = np.zeros(total)
    order = [3, 1, 2, 0, 3, 2]
    for i, idx in enumerate(order):
        start = int(i * step * RATE)
        dur = min(step * 1.9, base_time - i * step)
        if dur <= 0 or start >= total:
            break
        v = pad(note(chord[idx] + 24), dur, brightness * 0.75, 0.10)
        end = min(start + len(v), total)
        out[start:end] += v[: end - start]
    return out


def render(chords, tempo, brightness) -> np.ndarray:
    bar = 1.0 / tempo * 4
    piece = np.zeros(0)
    for _ in range(2):                            # two passes through the progression
        for chord in chords:
            block = np.zeros(int(RATE * bar))
            for semis in chord:
                v = pad(note(semis), bar, brightness, 0.16)
                block[: len(v)] += v[: len(block)]
            block[: len(block)] += arpeggio(chord, bar, bar / 6, brightness)[: len(block)]
            piece = np.concatenate([piece, block])
    # Soft-clip, then normalise with headroom.
    piece = np.tanh(piece * 1.2)
    piece /= max(abs(piece).max(), 1e-9)
    return piece * 0.82


def write_wav(path: str, mono: np.ndarray) -> None:
    # Slight stereo width: delay one side a few ms.
    delay = int(RATE * 0.011)
    left = np.concatenate([mono, np.zeros(delay)])
    right = np.concatenate([np.zeros(delay), mono])
    inter = np.empty(len(left) * 2)
    inter[0::2] = left
    inter[1::2] = right
    pcm = (inter * 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())


def cover(path: str, title: str, artist: str, top, bottom, seed: int) -> None:
    """A vertical-gradient sleeve with the title set on it.

    Not decoration: without artwork every demo screen is a grey placeholder, and
    these screens are what App Review — and the App Store screenshots — show.
    """
    img = Image.new("RGB", (COVER_PX, COVER_PX))
    draw = ImageDraw.Draw(img)
    for y in range(COVER_PX):
        f = (y / COVER_PX) ** 1.25
        draw.line([(0, y), (COVER_PX, y)],
                  fill=tuple(int(a + (b - a) * f) for a, b in zip(top, bottom)))

    # A few soft arcs so the sleeves are distinguishable at thumbnail size.
    overlay = Image.new("RGBA", (COVER_PX, COVER_PX), (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    for i in range(5):
        r = int(COVER_PX * (0.30 + 0.13 * i))
        cx = int(COVER_PX * (0.30 + 0.09 * (seed % 3)))
        cy = int(COVER_PX * (0.72 - 0.05 * (seed % 4)))
        od.ellipse([cx - r, cy - r, cx + r, cy + r],
                   outline=(255, 255, 255, 26 - 3 * i), width=max(2, COVER_PX // 220))
    img = Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")

    draw = ImageDraw.Draw(img)
    def font(size):
        for name in ("/System/Library/Fonts/Supplemental/Futura.ttc",
                     "/System/Library/Fonts/HelveticaNeue.ttc",
                     "/System/Library/Fonts/Helvetica.ttc"):
            try:
                return ImageFont.truetype(name, size)
            except OSError:
                continue
        return ImageFont.load_default()

    margin = int(COVER_PX * 0.09)
    tf, af = font(int(COVER_PX * 0.083)), font(int(COVER_PX * 0.040))
    # Wrap the title so long names don't run off the sleeve.
    words, lines, line = title.split(), [], ""
    for w in words:
        trial = (line + " " + w).strip()
        if draw.textlength(trial, font=tf) > COVER_PX - 2 * margin and line:
            lines.append(line); line = w
        else:
            line = trial
    lines.append(line)

    y = COVER_PX - margin - int(COVER_PX * 0.055) - len(lines) * int(COVER_PX * 0.098)
    for ln in lines:
        draw.text((margin, y), ln, font=tf, fill=(255, 255, 255))
        y += int(COVER_PX * 0.098)
    draw.text((margin, y + int(COVER_PX * 0.008)), artist.upper(), font=af, fill=(255, 255, 255, 200))
    img.save(path, "PNG", optimize=True)


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    for index, (title, artist, chords, tempo, brightness, colours) in enumerate(TRACKS, start=1):
        audio = render(chords, tempo, brightness)
        wav = os.path.join(OUT, f"tmp-{index}.wav")
        m4a = os.path.join(OUT, f"demo-{index}.m4a")
        write_wav(wav, audio)
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-i", wav,
             "-c:a", "aac", "-b:a", "96k",
             "-metadata", f"title={title}",
             "-metadata", f"artist={artist}",
             "-metadata", f"album={ALBUM}",
             "-metadata", f"track={index}",
             "-metadata", "date=2026",
             "-metadata", "genre=Ambient",
             m4a],
            check=True,
        )
        os.remove(wav)
        art = os.path.join(OUT, f"demo-{index}-cover.png")
        cover(art, title, artist, colours[0], colours[1], index)
        size = os.path.getsize(m4a) + os.path.getsize(art)
        print(f"  {title:16s} {len(audio)/RATE:5.1f}s  {size/1024:6.0f} KB (audio+art)")


if __name__ == "__main__":
    main()
