#!/usr/bin/env python3
"""Makes BatonAlarmChime.caf, the sound an alarm or timer rings when no clip of the chosen
track can be made (TBX-11171, specs/alarm-and-timer.md).

Synthesized here, so the app carries no third-party audio: a soft three-note bell figure in
Baton's key, four times over about 12 seconds. Notification and AlarmKit sounds must be under
30 seconds and Linear PCM, so the result is 16-bit mono Linear PCM in a CAF, 22.05 kHz.

    python3 tools/alarm-chime/make-chime.py ios/Resources/BatonAlarmChime.caf
"""
import math
import os
import struct
import subprocess
import sys
import tempfile
import wave

RATE = 22050
NOTES = [659.25, 783.99, 1046.50]  # E5, G5, C6
STEP = 0.32          # seconds between notes
PHRASE = 3.0         # seconds per phrase
PHRASES = 4


def bell(t, freq):
    # A struck bell: the fundamental and two inharmonic partials, each decaying.
    return (0.6 * math.sin(2 * math.pi * freq * t) * math.exp(-3.2 * t)
            + 0.25 * math.sin(2 * math.pi * freq * 2.76 * t) * math.exp(-5.5 * t)
            + 0.15 * math.sin(2 * math.pi * freq * 5.40 * t) * math.exp(-8.0 * t))


def main(out):
    total = int(RATE * PHRASE * PHRASES)
    samples = [0.0] * total
    for p in range(PHRASES):
        for i, freq in enumerate(NOTES):
            start = int(RATE * (p * PHRASE + i * STEP))
            for n in range(int(RATE * 2.2)):
                if start + n < total:
                    samples[start + n] += bell(n / RATE, freq)
    peak = max(abs(s) for s in samples) or 1
    frames = b"".join(struct.pack("<h", int(32767 * 0.8 * s / peak)) for s in samples)
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "chime.wav")
        with wave.open(wav, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(frames)
        subprocess.run(["/usr/bin/afconvert", "-f", "caff", "-d", "LEI16", wav, out], check=True)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "BatonAlarmChime.caf")
