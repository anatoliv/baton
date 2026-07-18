# Music-player UI/UX research — top 10 benchmarks vs. Tonebox

> Research compiled 2026-07-15 to guide the Tonebox player's UI/UX and feature
> roadmap. UI/UX is the primary lens (functionality is broadly similar across
> players). Backend for Tonebox is Subsonic/OpenSubsonic (Navidrome) — noted where
> the API constrains *functionality*; UI has no backend constraints.

## TL;DR

The three design north-stars are **Plexamp** (best self-hosted player, famous for
its "UltraBlur" color-from-artwork backdrops and full-screen now-playing),
**Apple Music on macOS** (typography, animated album art, synced karaoke lyrics,
color-adaptive full-screen player), and **Doppler** (the best-designed *local-
library* macOS app — album/artist-focused, clean, no clutter). For a Subsonic
client specifically, **Cassette** is the closest visual target and **Feishin** the
richest desktop one.

Tonebox's player is functionally credible but visually "so-so" because it leans on
plain SwiftUI lists and under-uses artwork. **The single highest-ROI change is
color-from-artwork adaptive backdrops + a full-screen now-playing hero** — that one
move is what makes Plexamp/Apple Music/Tidal *feel* premium, and it's a client-side
SwiftUI change with zero API dependency.

---

## Top 10 players (UI-first, ranked)

### 1. Plexamp (self-hosted, free with Plex Pass) — the gold standard
- **UI/UX:** "UltraBlur" extracts album-art colors and paints a smoked-glass
  gradient backdrop across player/artist/album pages; gorgeous full-screen
  now-playing with large art, visualizers, and a blurred adaptive background;
  "Sonic Sage"/"Sonic Adventure" discovery; mood/loudness analysis; buttery motion.
  Feels like a premium native app despite being cross-platform.
- **Features:** gapless, crossfade, ReplayGain/loudness leveling, offline downloads,
  synced lyrics, radios/mixes, sweet-fades, waveform seek, multi-device, sonic
  analysis, visualizers.
- **Steal:** UltraBlur adaptive backdrop; full-screen player; visualizer optionality.

### 2. Apple Music (macOS) — the typography & motion reference
- **UI/UX:** immaculate type hierarchy and spacing; **animated (motion) album art**;
  color-adaptive full-screen player whose background gradient is derived from the
  artwork; **time-synced karaoke lyrics** with per-line highlight and spring scroll;
  big editorial hero pages; refined mini-player. The bar most apps are measured against.
- **Features:** synced lyrics, spatial audio, radio/stations, autoplay, crossfade,
  library + streaming blend, handoff.
- **Steal:** color-adaptive full-screen player, synced-lyrics karaoke, hero pages, motion art.

### 3. Doppler (macOS, paid) — best-designed *owned-music* macOS player
- **UI/UX:** album- and artist-focused, deliberately uncluttered, fast, native
  macOS feel; beautiful library grids; gapless; no cloud/no clutter. Widely cited as
  the best-looking local-library Mac player.
- **Features:** gapless, CarPlay/iOS sync, tag editing, folder library, no streaming.
- **Steal:** restraint + density; album/artist-first navigation; native-feeling polish.

### 4. Tidal — bold full-bleed artwork
- **UI/UX:** large full-bleed art, dark premium palette, color-adaptive headers,
  credits, lyrics, mixes; art is the hero of every screen.
- **Steal:** full-bleed artwork behind pages; credits surfacing; adaptive headers.

### 5. Roon (paid, audiophile) — the most information-rich UI
- **UI/UX:** magazine-style layout, rich artist bios/photos, credits graph, focus/
  tags/bookmarks, lyrics, signal-path visualization. Heavy but stunning; the
  reference for "metadata as a first-class visual experience."
- **Steal:** artist hero pages with bios/photos; credits; focus/tag browsing.

### 6. Qobuz — clean hi-res audiophile UI
- **UI/UX:** clean, editorial, hi-res quality badges, restrained typography.
- **Steal:** quality/format badges; editorial calm.

### 7. Spotify — the interaction/navigation benchmark
- **UI/UX:** the density and nav model most users expect; color-adaptive gradient
  page headers, Canvas looping video, robust "now playing + up next" queue, cross-
  device Connect. Not the prettiest, but the most refined *interactions*.
- **Steal:** queue/"up next" design; adaptive gradient headers; connect/hand-off model.

### 8. Symfonium (Android, paid) — feature-leader for self-hosted
- **UI/UX:** deeply customizable, tag/genre browsing, excellent library handling for
  Subsonic/Jellyfin/Plex. Android-only, so a functionality reference more than a
  macOS visual one.
- **Steal:** breadth of browse axes (genres, tags, years); customization.

### 9. Feishin (desktop, free, Electron) — richest desktop self-hosted UI
- **UI/UX:** Spotify-like desktop layout, full-screen player, grid browse, themes;
  the best-looking *desktop* Subsonic/Jellyfin client today (Electron, so heavier).
- **Steal:** desktop layout model; full-screen player; theme-ability.

### 10. Cassette (macOS/iOS, free) — closest visual target for Tonebox
- **UI/UX:** Apple-Music-style native SwiftUI Subsonic client; clean cards, sensible
  now-playing. Proof that a *native macOS Subsonic client can look Apple-grade* —
  the most directly relevant benchmark for Tonebox.
- **Steal:** everything — it's the same platform + backend Tonebox targets.

*Honorable mentions:* **Amperfy** (solid native iOS Subsonic), **Supersonic**
(functional Go/Fyne desktop, plain UI), **YouTube Music**, **Sonos** (multiroom UX),
**Audirvana** (audiophile local).

---

## UI/UX pattern catalog (reimplementable in SwiftUI)

The patterns that separate best-in-class from "so-so", with the SwiftUI technique
for each:

1. **Color-from-artwork adaptive backdrop** (Plexamp UltraBlur, Apple Music, Tidal,
   Spotify headers). Extract 2–4 dominant colors from the cover, render an animated
   gradient/mesh behind the now-playing + album/artist pages.
   → SwiftUI: extract via a small `ColorThief`/`UIImageColors` port or `CoreImage`/
   `Vision`; render with `MeshGradient` (macOS 15+) or `LinearGradient`; layer
   `.ultraThinMaterial` for the smoked-glass look; animate color changes on track change.
2. **Full-screen "now playing" hero.** Large centered artwork (with soft shadow +
   subtle parallax), big title/artist, adaptive blurred backdrop, thin scrubber.
   → SwiftUI: `matchedGeometryEffect` to morph the mini-pill into the full player;
   `TimelineView` to drive the scrubber smoothly; `.regularMaterial` panels.
3. **Expandable mini-player.** The status-bar pill / bottom bar expands into the
   full player and collapses back.
   → SwiftUI: `matchedGeometryEffect` + a `@Namespace`; or the `MinimizableView` pattern.
4. **Synced, scrolling karaoke lyrics.** Per-line highlight that tracks playback and
   springs into center.
   → Data: OpenSubsonic `getLyricsBySongId` (structured/synced when the server has
   it). UI: `ScrollViewReader` + per-line opacity/scale + `.animation(.spring)`.
5. **Full-bleed blurred backdrop behind list/detail pages** (Tidal/Apple). Low-
   opacity blurred cover art fills the album/artist page background.
   → SwiftUI: `AsyncImage` → `.blur(radius:)` → `.overlay(Material)`.
6. **Artist hero pages.** Big banner/photo, bio, top tracks, discography grid.
   → Data: `getArtistInfo`/`getArtistInfo2` (bio + images), `getArtist` (albums). UI: a
   large header that collapses on scroll (`GeometryReader`/scroll offset).
7. **Rich album/artist grids with hover-reveal play.** Dense cover grids; on hover a
   play button + subtle scale.
   → SwiftUI: `LazyVGrid` + `.onHover` + `.scaleEffect`/overlay button.
8. **Reorderable, drag-friendly "Up Next" queue.** Drag to reorder, swipe/× to
   remove, now-playing highlighted, drag songs onto playlists.
   → SwiftUI: `List` `.onMove`/`.onDelete`; `.draggable`/`.dropDestination`.
9. **Motion / "breathing" album art.** Apple-Music-style animated art (or a subtle
   idle zoom/shadow pulse when nothing else is animated).
   → SwiftUI: `TimelineView` or repeating `.animation`; video art if the source has it.
10. **Polished scrubber + hover states + keyboard.** Rounded thin scrubber with a
    time bubble on drag; play-on-hover; space = play/pause, ⌘←/→ = prev/next.
    → SwiftUI: custom `Slider`/`Canvas`; `.onHover`; `.keyboardShortcut`.

---

## Comparison matrix (UI/UX + key functionality)

Legend: ✅ have · ◑ partial · ✗ missing

| Capability | Plexamp | Apple Music | Doppler | Tidal | Feishin | Cassette | **Tonebox** |
|---|---|---|---|---|---|---|---|
| Color-from-artwork adaptive UI | ✅ | ✅ | ◑ | ✅ | ◑ | ◑ | **✗** |
| Full-screen now-playing | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | **✗** |
| Expandable mini-player | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ◑ (static pill) |
| Synced lyrics (karaoke) | ✅ | ✅ | ✗ | ✅ | ◑ | ◑ | **✗** |
| Artist hero pages (bio/photos) | ✅ | ✅ | ◑ | ✅ | ◑ | ◑ | **✗** |
| Rich grids + hover play | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ◑ (grid, no hover) |
| Reorderable queue / drag-drop | ✅ | ✅ | ✅ | ✅ | ✅ | ◑ | **✗** |
| Motion/animation polish | ✅ | ✅ | ◑ | ◑ | ◑ | ◑ | **✗** |
| Keyboard shortcuts | ✅ | ✅ | ✅ | ◑ | ✅ | ◑ | **✗** |
| Gapless / crossfade | ✅ | ✅ | ✅(gapless) | ◑ | ◑ | ◑ | **✗** |
| Offline / downloads | ✅ | ✅ | n/a | ✅ | ◑ | ◑ | **✗** |
| Scrobbling / play counts | ✅ | ✅ | ◑ | ✅ | ✅ | ◑ | **✗** |
| Similar/radio/discovery | ✅ | ✅ | ✗ | ✅ | ◑ | ◑ | **✗** |
| EQ / ReplayGain | ✅ | ◑ | ◑ | ◑ | ◑ | ✗ | **✗** |
| Ratings (like + 5-star) | ◑ | ◑(love) | ◑ | ◑(fav) | ✅ | ✅ | **✅** |
| Playlist CRUD + share | ✅ | ✅ | ◑ | ✅ | ✅ | ✅ | **✅** |
| Server-side ratings for pipelines | ✗ | ✗ | ✗ | ✗ | ◑ | ◑ | **✅ (differentiator)** |
| Agent / voice control | ✗ | ◑(Siri) | ✗ | ✗ | ✗ | ✗ | **✅ (differentiator)** |

Tonebox already *wins* on server-side ratings-as-a-pipeline-signal and agent/voice
control. It loses almost entirely on the visual/premium-feel column — which is
exactly where the effort should go.

---

## Prioritized roadmap for Tonebox (macOS SwiftUI)

### Tier 1 — cheap wins, huge visual ROI (client-side, no API dependency)
1. **Adaptive color-from-artwork backdrop** on the now-playing bar + album/artist
   detail. This is the #1 "premium" lever (Plexamp UltraBlur / Apple Music).
   Extract dominant colors (small ColorThief port or CoreImage), animate a gradient
   behind the content, layer `.ultraThinMaterial`.
2. **Full-screen now-playing view** — expand from the bar/pill via
   `matchedGeometryEffect`: big centered art + soft shadow, adaptive blurred backdrop,
   large title, thin `TimelineView`-driven scrubber. Biggest single "wow".
3. **Album grids: hover-reveal play + scale; artist hero header** (banner + name +
   top albums). `LazyVGrid` + `.onHover`.
4. **Reorderable queue + drag-and-drop to playlists** (`List.onMove`/`.draggable`),
   and **keyboard shortcuts** (space, ⌘←/→, ⌘L like). Table-stakes interactions.
5. **Row/typography polish** — denser rows, consistent type scale, hover highlight,
   better spacing; small but removes the "so-so" feel.

### Tier 2 — medium, high perceived value (mostly API-available)
6. **Synced lyrics view** — OpenSubsonic `getLyricsBySongId` (Navidrome supports it);
   karaoke highlight + spring scroll. A signature "premium" feature.
7. **Scrobbling / play counts** — call the Subsonic `scrobble` endpoint on play; makes
   "Most played" / "Recently played" real and feeds the server's stats (and your pipeline).
8. **Similar / radio / discovery** — `getSimilarSongs`/`getSimilarSongs2` + `getArtistInfo`
   ("Start radio from this artist/song", "Fans also like"). *Research note: the claim
   that these require a Last.fm integration was refuted — Navidrome can return
   similarity natively, so this is worth building without external setup.*
9. **Gapless playback** — swap the single-item `AVPlayer` for `AVQueuePlayer` (queue
   the next track); add optional crossfade. Fixes a real audible gap between tracks.

### Tier 3 — larger efforts / partly API-constrained
10. **Offline / download caching** — stream to disk, prefer local on replay.
11. **EQ + ReplayGain** — `AVAudioEngine` + `AVAudioUnitEQ`; ReplayGain via
    OpenSubsonic `replayGain` tags. Audiophile appeal.
12. **Motion album art / visualizers** — Plexamp-style; large effort, high delight.
13. **Smart/auto playlists** — *API-constrained:* Navidrome smart playlists are
    server-side `.nsp` files with no create-API, so the client can't author them; best
    Tonebox can do is surface existing ones or build client-side "virtual" views.

### SwiftUI enablers to reach for
`MeshGradient` (macOS 15+), `matchedGeometryEffect` + `@Namespace`, `.ultraThinMaterial`/
`.regularMaterial`, `TimelineView`, `ScrollViewReader`, `AsyncImage` + `.blur`,
`LazyVGrid` + `.onHover`, `List.onMove`/`.draggable`/`.dropDestination`,
`AVQueuePlayer`, `AVAudioEngine`+`AVAudioUnitEQ`, `CoreImage`/`Vision` (color extraction).

### Subsonic/OpenSubsonic API reality check (functionality only)
- ✅ Available: `getLyricsBySongId` (lyrics), `scrobble` (play counts), `getSimilarSongs`/
  `getSimilarSongs2` + `getArtistInfo`/`getArtistInfo2` (radio/similar/bios/photos),
  `replayGain` tags.
- ✗ Not available / constrained: no delete-file (already known — pipeline's job);
  no smart-playlist authoring API; casting/multi-device is out of scope for a
  single-Mac client.

---

## Sources (verified during research)

- Plexamp v3 / UltraBlur adaptive color backdrop — https://medium.com/plexlabs/plexamp-v3-9af3b10063b4 · https://www.plex.tv/plexamp/ · https://blog.expo.dev/plexamp-v3-81be156b749e · https://thenextweb.com/news/plex-new-winamp-inspired-music-player-for-your-desktop-is-pretty-but-needs-work
- Doppler for Mac (album/artist-focused design) — https://www.macstories.net/reviews/doppler-for-mac-offers-an-excellent-album-and-artist-focused-listening-experience-for-your-owned-music-collection/ · https://brushedtype.co/doppler/features/
- Tidal vs Qobuz (premium streaming UI) — https://www.soundguys.com/tidal-vs-qobuz-140740/
- Best-designed players roundup — https://liveinaus.com/2025/02/10/plexamp-music-player/
- Feishin (desktop self-hosted client) — https://github.com/jeffvli/feishin
- Navidrome community client comparison — https://github.com/navidrome/navidrome/discussions/2375
- Apple Music animations in SwiftUI — https://navsin.medium.com/recreating-the-apple-music-app-animations-with-swiftui-6a3c3f8e709 · https://github.com/HuangRunHua/Apple-Music-Lyric-Animation · https://medium.com/@wesleymatlock/musickit-in-swiftui-building-a-real-apple-music-player-without-losing-your-mind-5e70a7f1ce88 · https://github.com/SwiftieDev/SwiftUI-Music-Player
- SwiftUI techniques — color extraction https://github.com/jathu/UIImageColors · minimizable/expandable player https://github.com/DominikButz/MinimizableView · WWDC26 session on SwiftUI design https://developer.apple.com/videos/play/wwdc2026/322/
- Subsonic/OpenSubsonic API — https://www.navidrome.org/docs/developers/subsonic-api/ · https://opensubsonic.netlify.app/docs/opensubsonic-api/ · https://opensubsonic.netlify.app/docs/endpoints/getlyricsbysongid/

*Research method: 5 parallel search angles → source fetch/dedup → 3-vote
adversarial verification. One high-confidence pattern locked (UltraBlur); one claim
refuted (similar/radio does NOT require Last.fm). The automated synthesis step
returned a partial result, so this report was authored from the verified source set
+ domain knowledge; treat specific per-app feature ticks as directional, not spec.*
