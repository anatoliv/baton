# 10 — Findings Implementation Plan & Log

Turns the four findings from [`09-function-value-review.md`](09-function-value-review.md)
into concrete, test-validated work. Each finding gets: **scope**, **what ships now
(tested)**, **what's staged** (larger arc, honestly out of one session's reach), and
a **validation** step run after implementation.

> Honesty note up front: two findings (F2 discovery, F4 casting) are genuinely
> large features. This plan lands a **real, tested increment** of each — not a stub,
> not a claim that the whole feature is done — and specifies the remaining arc. F1
> and F3 are completable in full and are.

---

## F1 — Cohere the agent-native pillar *(positioning / docs)*

**Finding:** #1 MCP, #5 audio-focus, #12 menu-bar keep-alive, #13 speak-summary are
one connected "agent-native" pillar, not scattered features — treat them as one in
messaging, roadmap, and QA.

- **Ships now:** a single "The agent-native pillar" section (below) that names the
  four functions as one load-bearing whole and states the QA invariant that ties
  them together; `09` finding #1 links to it.
- **Staged:** website `help.html` copy pass to mirror the framing (noted, low-risk,
  not code).
- **Validate:** internal doc links/anchors resolve; no broken cross-references.

## F2 — Sonic-aware discovery *(code + tests)*

**Finding:** auto-mixes / Home are the front door and heuristic (`.shuffled()`), not
sonic — the biggest value-vs-execution gap.

- **Ships now:** `MixBuilder.curate(...)` — a **pure, tested** ordering pass that uses
  real sonic metadata already on `NavidromeSong` (`bpm` = server-extracted tempo,
  plus `year`) to (a) **spread artists** so a mix never stacks one artist back-to-back
  and (b) shape a **tempo flow** (gentle arc / mood-biased) instead of a flat random
  shuffle. Mood hints in the prompt (`focus`/`chill`/`upbeat`) bias the tempo target.
  Wired into both the MCP `music_build_mix` path *and* the `Discover` / per-genre auto
  mixes (replacing bare `.shuffled()`), so the improvement shows up on the discovery
  surface, not just the tool.
- **Staged:** true local **DSP feature extraction** (key/energy/spectral from the raw
  audio, à la Plexamp) for libraries whose server carries no `bpm`. Specified in
  [`05`](05-roadmap-new-features.md); this increment covers every library whose
  server *does* tag tempo (Navidrome does, from the file tags / its own scan).
- **Validate:** `MixBuilderTests` + new `MixCurationTests` (artist-spread, tempo
  monotonic/arc, mood→tempo bias, graceful fallback when `bpm` is absent).

## F3 — Protect the audiophile crown jewels *(regression tests)*

**Finding:** the audiophile cluster (gapless, EQ, ReplayGain) is over-delivered and
*correct* — keep it. Implemented as **enforced invariants** so "keep it" can't
silently regress.

- **Already guarded (verified):** EQ `0 dB = identity`, disabled EQ = flat
  pass-through (`EqualizerDSPTests`); ReplayGain off→1, +preamp, peak-clamp, 4× cap,
  album fallback (`MusicLoudnessTests`).
- **Ships now (the real gaps):** (1) the **gapless ⊕ crossfade mutual-exclusivity**
  invariant (`isGaplessMode == gaplessEnabled && crossfadeSeconds < 0.05`) — exposed
  via a DEBUG test hook and asserted across the truth table; (2) an explicit
  **EQ-defaults-to-disabled** assertion.
- **Validate:** new `AudiophileInvariantTests` green.

## F4 — Casting foundation *(pure core + tests + spec)*

**Finding:** AirPlay-only is the most conspicuous gap for a mixed-hardware
self-hosting crowd.

- **Ships now:** a **pure, tested** output-route domain — `CastRoute` (device id /
  name / kind / availability / selection) and `CastRouteResolver` that merges routes
  from multiple providers, de-dups, sorts (this-Mac first, then by kind/name), and
  resolves the single active route. This is the seam every future provider plugs
  into; it is deterministic and fully unit-testable with **no** network or SDK.
- **Staged (explicitly NOT shipped here):** the live provider implementations —
  Chromecast (Cast SDK / mDNS `_googlecast._tcp`), Sonos (UPnP + local API), UPnP/DLNA
  (`_upnp`/SSDP) — each needs a network stack + an audio-egress path AVFoundation
  doesn't give for free, and can't be validated in this environment. Provider
  protocol + integration steps are specified below.
- **Validate:** new `CastRouteResolverTests` (merge/dedup/sort/active-selection/empty).

---

## The agent-native pillar *(F1 deliverable)*

Baton's moat is not "a nice Subsonic player" — a dozen of those exist. It is **the
player whose control surface *is* an MCP server**. Four functions make that real and
must be understood, built, messaged, and QA'd as **one pillar**, because each is
useless to an agent without the others:

| # | Function | Role in the pillar |
|---|----------|--------------------|
| 1 | **MCP control surface** | The interface itself — 30 tools + 5 live resources an agent drives. |
| 5 | **Audio-focus** (`audio_suspend`/`resume`) | Lets *other* agents/apps duck Baton politely — the pillar's good-citizen primitive. |
| 12 | **Menu-bar controller** | Keeps the app — and therefore the MCP server — **alive headless** so the interface is reachable when no window is open. |
| 13 | **Speak-summary** (`speak_summary`) | The agent's *voice back* — closes the loop from "agent controls music" to "agent talks to you." |

**The pillar QA invariant (new, and the reason to treat these as one):**

> With every Baton window closed, an MCP client must still be able to connect
> (server alive via the menu-bar item, #12), drive playback (#1), have its audio
> ducked and restored around a capture (#5), and hear a spoken summary (#13) — in
> one uninterrupted session. Any change that breaks that end-to-end chain is a
> pillar regression, even if each function's own unit tests stay green.

Roadmap, positioning, and release QA should reference this chain as a unit.

---

## Provider protocol *(F4 staged-arc spec)*

```
protocol CastProvider {                       // one per transport
    var kind: CastRoute.Kind { get }
    func startDiscovery() async                // begins mDNS/SSDP browse
    func routes() -> [CastRoute]               // current known devices
    func select(_ route: CastRoute) async throws
    func endDiscovery()
}
```

Integration steps, in order, each shippable on its own:
1. `CastRouteResolver` + `CastProvider` protocol — **this increment.**
2. `AirPlayCastProvider` — wrap the existing `AVRoutePickerView` state as one
   provider so AirPlay flows through the same model (no behavior change).
3. `ChromecastProvider` — mDNS `_googlecast._tcp` browse + Cast v2 app launch +
   media receiver; audio egress via a local HTTP stream of the current track.
4. `SonosProvider` / `UPnPProvider` — SSDP discovery + `AVTransport` SetURI/Play.
5. UI: a route list in the Now-Playing bar backed by `CastRouteResolver`, replacing
   the AirPlay-only glyph; an MCP `music_list_outputs` / `music_set_output` pair so
   agents can cast too (extends the pillar above).

---

## Validation log

Filled in as each step lands (`scripts/test.sh -only-testing:…`).

| Step | Command | Result |
|------|---------|--------|
| F2 | `-only-testing:BatonTests/MixBuilderTests -only-testing:BatonTests/MixCurationTests` | ✅ 25 passed, 0 failures |
| F3 | `-only-testing:BatonTests/AudiophileInvariantTests` | ✅ 3 passed, 0 failures |
| F4 | `-only-testing:BatonTests/CastRouteResolverTests` | ✅ 9 passed, 0 failures |
| F1 | docs cross-links resolve (`09` → `10` pillar section) + help.html parses | ✅ verified |
| Full | `scripts/test.sh` | ✅ 467 XCTest + 114 Swift Testing, 0 failures |

## Audit against the original ask (gaps found & resolved)

After the four findings were implemented and each validated, a self-audit against
the ask ("plan → implement → validate each → audit → resolve gaps") surfaced three
gaps, all now closed and re-validated:

1. **`docs/10` was missing from the `docs/README.md` index** → added (row 10).
2. **F2 hadn't reached every discovery surface** — `Forgotten Favorites` still used a
   bare `.shuffled()` → now routed through `MixBuilder.curate(…, mood: .neutral)` for
   artist-spread, consistent with Discover / genre mixes. (The per-row user "Shuffle"
   action is deliberately left a true shuffle.)
3. **F1's messaging dimension was docs-only** — the pillar framing wasn't in the
   user-facing help → added a "Four pieces, one pillar" paragraph to `website/help.html`
   `#agents` (in-repo edit; the site is not auto-published).

Re-ran the full suite after the source change (Forgotten Favorites): still green.

### Declared scope boundaries (not gaps — inherent to the findings' size)
- **F4** ships the *foundation* (pure resolver + provider protocol + tests + spec),
  not live Chromecast/Sonos/UPnP, which need network stacks + an audio-egress path
  that can't be built or validated in this environment. Staged arc is specified above.
- **F2** curates using the server's `bpm` (a real sonic feature); local DSP feature
  extraction for libraries with no tempo tags remains the larger arc in [`05`](05-roadmap-new-features.md).
