# Baton macOS App Visual Design System

> **Status:** v2 — implementable spec. This document is the source of truth for
> Baton's color, theming, selection, and motion. Where it says MUST, the behavior
> is enforced in code (`Color+Baton.swift`, `ArtworkPalette.swift`).

## Vision

A premium native macOS music player whose **immersive surfaces** adapt to the
currently playing artwork, while a **permanent Baton identity** (brand orange)
anchors everything the user acts on. Artwork colors set the mood; the brand color
tells you where to click.

## Design Principles

- Content first — chrome recedes, artwork and lists lead.
- Native macOS — grouped forms, materials, system controls, light/dark aware.
- Artwork influences the UI without overwhelming it, and **never** at the cost of readability.
- Excellent accessibility: legible contrast is guaranteed, not hoped for.
- Motion is calm and intentional.

---

## Color Architecture

Two color systems coexist. The rule that separates them is the spine of this doc.

### The Brand ⇄ Dynamic rule (MUST)

| Layer | Source | Where it applies |
|-------|--------|------------------|
| **Brand** | Fixed `#E98345` | Anything the user **acts on or navigates**: primary buttons, list/sidebar selection, active toggles, links, install/GitHub, the app's global `.tint`/AccentColor. |
| **Dynamic** | Extracted from current artwork | **Ambient & player-context** surfaces only: the now-playing backdrop, and inside the player the progress fill, volume fill, favorite glow, and active transport state. |

One-sentence test: **"Does clicking this take an action?"** → Brand orange.
**"Is this ambient, decorative, or reflecting the playing track?"** → Dynamic.

This resolves the old contradiction ("Buttons = 100% accent" vs "primary actions =
brand only"): app-wide accent **is** brand orange, so buttons and selection are
brand by construction; the dynamic palette is confined to the player context.

### Permanent Brand Color

Primary Baton Orange: **`#E98345`** (sRGB `0.914, 0.514, 0.271`).

Defined once as `Color.batonOrange` and installed as the app's `AccentColor` asset
so every `Color.accentColor` / `.tint` resolves to brand orange — **not** the user's
macOS system accent. Never replace the brand color with artwork colors.

Derived brand tints (for hover/pressed/disabled): `batonOrange` at 85% / 70% /
38% opacity, exposed as `Color.brandHover`, `Color.brandPressed`, `Color.brandMuted`.

### Dynamic Music Palette

Generated from the current album artwork (`ArtworkColorExtractor`). Roles:

Extraction runs on a canonical cover size (`ArtworkColorExtractor.coverSize`, 400px)
across every now-playing surface — main window, full-screen, and mini player — so all
windows derive the **same** accent for a given track, independent of each surface's
display-image size.

| Role | Meaning | Derivation |
|------|---------|-----------|
| `primary` | Dominant mood color | Most-populated color bucket |
| `secondary` | Deep ambient base | Darkened whole-image average |
| `accent` | Vibrant highlight | Highest-ranked vibrant **bucket** (not a single pixel). Stored **raw** so the backdrop gradient stays rich; contrast-corrected only for foreground use via `uiAccent` (below). |
| `neutral` | Fallback base | Fixed dark, used when art is absent |

The raw `accent` feeds the ambient `AdaptiveBackdrop` gradient. Foreground controls
never use it directly — they use `ArtworkPalette.uiAccent`, which applies the
grayscale fallback + contrast correction described next.

**Fallback (MUST):** if the artwork is (near-)grayscale — extracted accent
saturation `< 0.15` — or the accent cannot be made to meet contrast, the dynamic
`accent` falls back to **Baton orange**. Grayscale albums therefore get a
brand-orange player accent rather than a muddy gray one.

---

## Contrast & Accessibility (MUST)

Legibility is enforced numerically, not assumed.

- **Relative luminance** uses the WCAG formula (linearized sRGB, `0.2126 R +
  0.7152 G + 0.0722 B`).
- **Contrast ratio** `(L1 + 0.05) / (L2 + 0.05)`.
- **Targets:** body text ≥ **4.5:1** (AA); large text / UI accents / icons ≥ **3:1**.
- The dynamic accent is used on foreground controls over the dark player backdrop.
  `ArtworkPalette.uiAccent` **lightens it until it reaches ≥ 4.5:1** against a
  near-black reference; if it cannot (already near-white or degenerate), it falls back
  to brand orange. The raw `accent` (uncorrected) still paints the backdrop gradient,
  which must stay saturated.
- Light/dark:
  - **Chrome** (sidebar, lists, forms, settings) follows the system appearance and
    uses brand orange, which meets contrast in both modes.
  - **Player** (`FullScreenNowPlaying`, `MusicView` backdrop) is a deliberately
    **immersive dark surface** (`.preferredColorScheme(.dark)`). This is an
    intentional single-appearance surface; its readability is guaranteed by the
    contrast-corrected accent + a fixed scrim, not by appearance switching.

`Color+Baton.swift` exposes the single implementation in a `Contrast` enum —
`Contrast.ratio(_:_:)`, `Contrast.relativeLuminance(_:)`, `Contrast.saturation(_:)`,
and `Contrast.ensureContrast(of:against:min:fallback:)`; `ArtworkPalette.uiAccent`
calls them.

---

## Surface Hierarchy

Surfaces are layered for depth. The player backdrop is an artwork gradient
(`AdaptiveBackdrop`); interactive surfaces are tinted with the **accent in play for
that context** (brand orange in chrome; dynamic accent in the player).

Two kinds of foreground color coexist, and they follow the Brand ⇄ Dynamic rule:

- **Discrete highlights** — selection, list "current" rows, mode toggles — are
  *actions/state in the chrome*, so they use **brand orange** (`Color.accentColor`).
- **Continuous fills that visualize the playing track** — progress, volume — plus the
  **playback glow** and the **favorite/rating** accent are *player-context ambient*,
  so they use the **dynamic accent** (`palette.uiAccent`).

| Surface | Tint | Opacity |
|---------|------|---------|
| Sidebar selection | brand orange | 15% |
| Row hover | primary (neutral) | 6% |
| Row selection | brand orange | 12% |
| Now-playing row (queue) | brand orange | 16% |
| Player progress fill | dynamic accent | 100% |
| Player volume fill | dynamic accent | 100% |
| Playback glow / favorite / active transport state | dynamic accent | — |
| Primary button | brand orange | 100% |

Every accent-derived surface value is a helper — `Color.selectionTint`,
`Color.sidebarSelectionTint`, `Color.nowPlayingRowTint`, `Color.hoverTint`,
`Color.badgeTint`, `Color.badgeIdleTint`, `Color.playingGlowTint` — and all the
selection / hover / now-playing-row / count-badge / now-playing-card-glow call sites
are migrated onto them (they resolve to brand orange via the accent asset). The only
remaining inline accent uses are the bespoke Equalizer-curve gradients in Settings,
which are a one-off visualization, not a reusable surface. Do **not** tint every
surface equally — the gradient backdrop already carries the mood; foreground tint
marks state.

---

## Selection

Selected list/grid items get, beyond a background fill:

- context-accent background at the opacity above;
- a **150–200 ms** `easeInOut` transition on selection change;
- for the now-playing **source** media card: a 1 px accent border + soft accent glow
  (`shadow` radius ≈ 14) + a subtle hover scale (`1.06`).

## Player

Artwork **MUST** influence, via the dynamic palette:

- Progress bar fill
- Volume slider fill
- Favorite / rating accent
- Playback glow on the now-playing artwork
- The adaptive gradient backdrop (already shipped)

Transport icons that reflect **state** (shuffle on, repeat on) use the dynamic
accent; transport actions that are neutral controls stay `.white`/`.primary`.

## Motion

Calm, not flashy.

| Transition | Spec |
|-----------|------|
| Palette crossfade on track change | `easeInOut` **0.6 s** |
| Selection change | `easeInOut` **150–200 ms** |
| Full-screen present/dismiss | `spring(response 0.42, damping 0.85)` |
| Now-playing artwork "breathing" | `easeInOut 3.4 s` autoreverse, scale 0.98↔1.02 |
| Hover | `easeOut` ~120–160 ms |

---

## Fallbacks & Edge Cases (MUST)

| Case | Behavior |
|------|----------|
| No artwork / load fails | `ArtworkPalette.neutral` (fixed dark); player accent → brand orange |
| Grayscale / low-saturation art | dynamic accent → brand orange (see Dynamic Palette) |
| Accent fails contrast after clamping | → brand orange |
| Rapid track changes | palette load is cancellable + cached per URL; crossfade debounces visually |
| Extremely dark/bright art | secondary is a fixed-scale darken; scrim guarantees text legibility |

---

## Implementation Map

| Concern | File |
|---------|------|
| Brand color, semantic tokens, contrast math | `Shell/Music/Color+Baton.swift` |
| Global brand accent | `Assets.xcassets/AccentColor.colorset` + `.tint` in `BatonApp.swift` |
| Palette extraction, roles, contrast-correction | `Shell/Music/ArtworkPalette.swift` |
| Adaptive backdrop | `AdaptiveBackdrop` in `ArtworkPalette.swift` |
| Player dynamic accent wiring | `NowPlayingBar.swift`, `FullScreenNowPlaying.swift`, `MiniPlayerWindowView.swift`, `MusicControls.swift` |
| Selection-change animation | `easeInOut(0.18)` on sidebar + list/queue rows |

## Future Ideas

- Dynamic gradients that animate with the waveform
- Adaptive waveform colored from the palette
- Animated equalizer using artwork colors
- Ambient lighting behind artwork
