# Baton — app icon

Baton's icon is a deliberate sibling of the **Tonebox** icon. It keeps Tonebox's
floating **waveform** mark and terracotta accent, and adds one thing: a **music
note** riding the top wave. The waveform still dominates; the note is the quiet
"this is a music app" signal.

## The family DNA (inherited from Tonebox, unchanged)

- Three stacked wavy horizontal lines on a **transparent** background, 1024×1024.
- Stroke color **`#E07A4B`** (terracotta), `stroke-width` **71.76**, round caps.
- Opacity fade top→bottom: **1.0 / 0.82 / 0.64**. On a dark plate the lower waves
  "brown out" against the background exactly like Tonebox — that fade is the
  light/dark trick, so the *same* mark works on both plates with no recolor.
- Same overall weight and proportion, so Baton sits next to Tonebox as an obvious
  sibling in the Dock / Launchpad.

## Primary concept — `Baton.master.svg`

**A single eighth-note riding the crest of the top wave.** The notehead sits just
above the wave's high point (a small, intentional gap so it reads as *floating on*
the wave, like a playhead), the stem rises, and the flag sweeps to the right —
echoing the waveform's own left-to-right motion. The note is full-opacity `#E07A4B`
so it's unmistakably the focal accent, while the three waves carry the Tonebox
identity underneath.

The three waves are nudged down ~44px vs. Tonebox to open headroom for the note
while keeping the whole mark optically centered in the icon frame.

Why this one is primary: it's the most **elegant and least cluttered** of the
options — a single note, clearly legible, that reads as "music" instantly without
fighting the waveform. It also degrades most gracefully at medium sizes.

### 16pt variant — `Baton.master-16pt.svg`

At 16px the full three-wave-plus-note mark turns to mush (same reason Tonebox ships
a simplified 16pt mark). Baton's small-size variant drops to **two thicker, more
separated waves + a chunkier note** so the silhouette survives downscaling. The
generator wires this variant into the `icon_16x16` and `icon_16x16@2x` slots
automatically; every larger slot uses the full master.

## Alternatives (pick-one options)

- **`Baton.alt1.svg` — "note grows out of the wave."** The top wave itself *rises*
  at the crest into the note's stem (the stroke's round cap becomes the notehead),
  then the wave resumes to the right of it. The note literally emerges from the
  waveform — the most conceptually "fused" option, one continuous gesture.
- **`Baton.alt2.svg` — "beamed pair surfing the crests" (♫).** Two noteheads sit on
  the wave's crests joined by a slanted beam. The most **overtly musical** read
  (unmistakably a music glyph), slightly busier than the primary.
- **`Baton.alt3.svg` — "playhead note", most restrained.** The waves stay in their
  exact Tonebox positions; a single compact note perches on the top crest. The
  waveform dominates hardest here and the change from Tonebox is smallest — the
  safest, most conservative differentiation.

## Light / dark handling

The mark is a single transparent glyph; light vs. dark is the **plate behind it**,
matching how the Tonebox dock icons differ:

- **`Baton-dock-light.svg`** — warm off-white rounded plate
  (`#FBF8F3 → #EFE9E0` vertical gradient, faint `#E4DCCF` hairline border).
- **`Baton-dock-dark.svg`** — near-black rounded plate
  (`#1C1C1E → #0E0F12` gradient, `#2A2A2E` hairline). The wave opacity-fade makes the
  lower waves recede into brown against the dark plate, identical to Tonebox dark.

Both use the same `#E07A4B` mark at 0.72 scale, centered on an inset macOS-style
rounded rect (`rx = 184` at the standard icon margin). The note stays full terracotta
on both.

`0e0f12` is also the exact opaque background Tonebox's generator composites for
non-alpha (iOS/opaque) contexts, so anything derived from these masters stays on-brand.

## Files

| File | What it is |
|------|------------|
| `Baton.master.svg` | Primary 1024×1024 master (transparent, waveform + riding note). |
| `Baton.master-16pt.svg` | Simplified 2-wave variant for the 16px slots. |
| `Baton.alt1/2/3.svg` | Alternative note↔wave fusions (see above). |
| `Baton-dock-light.svg` / `-dark.svg` | Dock plate variants (light/dark). |
| `Baton.preview.png` | 1024×1024 transparent render of the primary master. |
| `Baton-dock-light.png` / `-dark.png` | 512×512 rendered dock plates. |
| `generate-app-icons.sh` | Renders the master into the macOS `.appiconset`. |

## Regenerating the icons

Requires `rsvg-convert` (`brew install librsvg`) and, for the montages above,
ImageMagick (`brew install imagemagick`).

```sh
# Emits app/Assets.xcassets/AppIcon.appiconset/ + refreshes Baton.preview.png
design/generate-app-icons.sh
```

The script renders 16/32/64/128/256/512/1024 from `Baton.master.svg`, swaps the two
16pt slots for `Baton.master-16pt.svg`, and writes a `Contents.json` for the catalog.

Manual one-offs (if you don't want the whole set):

```sh
rsvg-convert -w 1024 -h 1024 Baton.master.svg      -o Baton.preview.png
rsvg-convert -w  512 -h  512 Baton-dock-light.svg  -o Baton-dock-light.png
rsvg-convert -w  512 -h  512 Baton-dock-dark.svg   -o Baton-dock-dark.png
```

To swap in a different concept as the primary, point `SOURCE` in
`generate-app-icons.sh` at the chosen `Baton.altN.svg` (or just rename it over
`Baton.master.svg`) and re-run.
