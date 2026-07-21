# 05 — Roadmap: New Features

New capabilities to build in **Baton**, prioritized, each with an
effort tag and tied to the competitive gap it closes. Effort: **S** ≈ days,
**M** ≈ 1–3 weeks, **L** ≈ a month+.

Gaps reference the existing comparison
(`docs/music-player-competitive-comparison.html`) and [07](07-competitive-analysis.md).

---

## Tier 1 — closes the biggest strategic gaps

### 1. iOS / iPadOS companion — **L**
**Gap:** macOS-only is the single gap shared with *every* leader. No phone = no
listening away from the desk.
**Plan:** reuse `NavidromeClient` + `MusicLibraryStore` + the models verbatim (all
`Sendable` value types, no AppKit). New SwiftUI UI + a slimmer engine. Offline sync
of downloads (reuse `MusicDownloadStore`'s manifest format) is the killer piece.
**Why:** turns "a nice desktop player" into a real ecosystem; also gives the
audio-focus/MCP story a second surface.

### 2. Casting beyond AirPlay — Chromecast / Sonos / UPnP-DLNA — **M**
**Gap:** casting is AirPlay-only today (`AirPlayRoutePicker.swift`); Plexamp /
Symfonium / Spotify reach whole-home audio.
**Plan:** Chromecast (Cast SDK / mDNS + the receiver protocol) + generic UPnP/DLNA
push covers most speakers; Sonos via its local API. The stream URLs are already
plain signed HTTP (`NavidromeClient.streamURL` :112), so a cast target can pull
directly.
**Why:** whole-home audio is table-stakes for a "real" player.

### 3. Downloads manager + first-class offline mode — **SHIPPED**
**Shipped:** the Downloads tab (`app/Sources/Baton/Shell/Music/MusicDownloadsView.swift`)
lists what's downloaded with a global **Offline mode** toggle
(`baton.music.offlineMode`) and multi-select batch actions; downloads themselves are
managed by `app/Sources/Baton/Shell/Music/MusicDownloadStore.swift`.
**To extend:** auto-download a playlist/mix and download-on-Wi-Fi-only (reuse
`app/Sources/Baton/Audio/NetworkReachability.swift`).
**Why:** table-stakes for a standalone player; also the iOS companion depends on it.

### 4. Sonic-analysis mood mixes — **L**
**Gap:** mixes today are heuristic (history + server lists + genre shuffle,
`MusicMix.swift:24–67`), **not** sonic — Plexamp's real differentiator.
**Plan:** analyze *downloaded* audio (tempo/energy/key/loudness) locally (the
waveform pipeline in `WaveformExtractor.swift` already reads PCM via `AVAssetReader`
— extend it), store features, and build "more like this" + smart transitions +
mood/energy mixes. Pairs beautifully with the agent angle: "build me a 40-minute
set that ramps energy up then down."
**Why:** where Baton could *beat* the open clients, not just match them — and it's a
natural agent tool (`music_start_radio` seeded by sonic features).

---

## Tier 2 — parity wins & depth

### 5. Podcasts — **SHIPPED**
**Shipped:** a Podcasts tab that routes between **server-side** Subsonic podcasts (when
the server exposes them) and **client-side RSS** subscriptions Baton fetches directly
(`app/Sources/Baton/Shell/Music/MusicPodcastsView.swift`,
`ClientPodcastsView.swift`, `MusicPodcastCapability.swift`); subscriptions, episode
lists, and resume position persist via the podcast stores on `MusicModel`
(`app/Sources/Baton/Model/MusicModel.swift`).
**To extend:** dedicated podcast MCP tools (`music_list_podcasts`, `music_play_episode`).
**Why:** cheap parity win the open clients already have.

### 6. Internet radio stations — **SHIPPED**
**Shipped:** a stations list backed by `app/Sources/Baton/Model/InternetRadioStore.swift`
with the UI in `app/Sources/Baton/Shell/Music/MusicRadioView.swift`; playback is the
station's stream URL straight into the existing engine.
**Why:** cheapest parity win on the board.

### 7. Multi-server / account switching — **SHIPPED**
**Shipped:** `app/Sources/Baton/Integrations/Navidrome/NavidromeConfig.swift` persists
a list of saved servers (`NavidromeServerEntry`) with an active-server selection and
migrates a legacy single-server config in on first read; server editing/switching UI is
in `app/Sources/Baton/Shell/Music/BatonServerEditSheet.swift`. Likes/ratings are
per-server (server-side), so switching stays clean.
**Why:** power-users run more than one library.

### 8. Parametric EQ + crossfeed / DSP — **partly SHIPPED**
**Shipped:** the equalizer is already **parametric** — each band carries its own centre
frequency, Q, and gain (`app/Sources/Baton/Audio/MusicEqualizer.swift`), with the legacy
10-band graphic API mapping onto the parametric model; the `MTAudioProcessingTap` render
path and RBJ biquad math are in `app/Sources/Baton/Audio/AudioEQProcessor.swift`, and the
`music_set_eq` MCP tool is live (`app/Sources/Baton/MCP/BatonMCPTools.swift`).
**To extend:** per-output presets and headphone crossfeed.
**Why:** audiophile credibility; differentiates from every streaming app.

### 9. Lyrics upgrades — **S**
**Gap:** synced lyrics work (`MusicLyricsView.swift`, `getLyricsBySongId`) but depend
entirely on the server having them.
**Plan:** optional LRCLIB fallback (opt-in, network) when the server returns none;
larger-type "lyrics mode"; copy/share a line.
**Why:** low effort, high delight.

---

## Tier 3 — the agent-native differentiators

These have no strong precedent among competitors — they lean into Baton's reason for
existing. Full "wild ideas" list in [08](08-open-questions-and-ideas.md).

### 10. Natural-language mix building — **M**
**Plan:** an MCP prompt + tool flow so "make me a 40-minute focus mix that starts
mellow and ends upbeat" resolves to a concrete queue, using search + (eventually)
sonic features. The existing MCP tool catalog
(`app/Sources/Baton/MCP/BatonMCPTools.swift`) — search + play + queue + `music_build_mix`
— is the seed the client agent already composes over; extend it to *composition*, not
just single commands.
**Why:** the flagship agent interaction; nothing mainstream does this locally.

### 11. Cross-app automations with Tonebox — **M**
**Plan:** now that Tonebox is a client, enable flows like "when I start a recording,
duck the music and log the track that was playing to the session," or "when a
meeting ends, resume my last mix." Built on `audio_suspend` + now-playing
notifications ([04](04-integration-and-mcp.md)).
**Why:** unique to owning both apps; a moat.

### 12. Agent-observable status surface — **shipped foundation, S to extend**
**Shipped:** `baton://now-playing`, `baton://history/recent` (and 3 more) are live
resources with `notifications/resources/updated` over SSE, so external
agents/dashboards can narrate or log listening without polling
([04 §5](04-integration-and-mcp.md#5-mcp-resources--notifications-shipped)).
**To extend:** richer history/analytics resources and a ready-made status-page
recipe.
**Why:** turns Baton into a well-behaved citizen of a larger agent workflow.

---

## Tier 4 - release engineering & observability

### 13. Auto-update via Sparkle - LIVE (feed live, awaiting first release)

**Status:** shipped and live. `SparkleUpdater` wrapper, `UpdateChannel` gating, a "Check for
Updates" menu item, an Updates section in Settings/About, and the Info.plist keys are all in.
The real EdDSA public key (shared with Tonebox, per Sparkle's one-key recommendation) is set,
`SUEnableAutomaticChecks` is true, and an (empty but valid) `appcast.xml` is hosted at
baton.tonebox.io, so the in-app status reads "Ready" and Check for Updates works (reports
"up to date"). The private signing key stays in the login Keychain.

**What (remaining):** cut the first signed + notarized DMG and add its signed `<item>` to the
appcast per `docs/RELEASE-APPCAST-HOSTING.md`. Then real updates flow.

**Build:** add the Sparkle SPM package; wire an updater controller plus a "Check for
Updates..." menu item; add the `SUFeedURL`, `SUEnableAutomaticChecks`, and `SUPublicEDKey`
Info.plist keys; generate an EdDSA key pair and keep the **private** key out of the repo;
host an `appcast.xml` (likely on web-01 / baton.tonebox.io alongside the DMG) and sign each
build's update entry.

**Why:** users expect a shipping macOS app to update itself; manual reinstall is a poor
experience and the docs assumed this existed.

### 14. Crash / error reporting via Sentry - IMPLEMENTED (opt-in, private DSN)

**Status:** shipped. Sentry project `baton-macos` created; `CrashReporting.swift` starts the
SDK only when the user opts in (Settings, About, Diagnostics, default off) and a DSN is baked
in; `sendDefaultPii = false` plus a `beforeSend` scrubber; DSN injected via the gitignored
`app/Config/Sentry.local.xcconfig`; the secrets guard now catches Sentry tokens and DSNs.

**Approach (chosen): public code + private DSN.** The Sentry integration lives in the public
source for transparency, but the DSN is injected at build time from a gitignored xcconfig (or
CI secret) and is never committed. It ships **off by default**, opt-in via a Settings toggle,
and PII-scrubbed: no track or library data, no IP, no account identifiers.

**Build:** follow the house `observability-setup` pattern (Sentry gated + scrubbed); add a
`Baton.Secrets.xcconfig` (gitignored) carrying `SENTRY_DSN`; a "Send crash & error reports"
toggle defaulting off; a `beforeSend` scrubber; and update the "Does Baton phone home?" FAQ
to add the opt-in caveat (as Tonebox does). Keep the DSN out of the public mirror.

**Why:** real crash insight from shipped builds without breaking Baton's privacy-first,
"no telemetry by default" promise.

---

## Suggested sequencing

1. **Ship the extraction first** ([03](03-architecture.md)) — nothing here matters
   until Baton stands alone.
2. **Cheap parity next** (podcasts #5, radio #6, multi-server #7, downloads screen
   #3) — makes Baton feel complete.
3. **Then the differentiators** (sonic mixes #4, NL mix building #10, iOS #1) —
   these are what make Baton worth choosing over Plexamp/Symfonium.
4. **Casting #2** whenever whole-home demand is loud enough; it's self-contained.

## One-line rationale per item

| # | Feature | Effort | Closes |
|---|---|---|---|
| 1 | iOS/iPad companion | L | macOS-only (the biggest gap) |
| 2 | Chromecast/Sonos/UPnP casting | M | AirPlay-only casting |
| 3 | Downloads manager + offline | M | No offline UX / standalone identity |
| 4 | Sonic mood mixes | L | Heuristic-only mixes vs Plexamp |
| 5 | Podcasts | S–M | Missing content type |
| 6 | Internet radio | S | Missing content type |
| 7 | Multi-server | S–M | Single-server |
| 8 | Parametric EQ + DSP | M | EQ depth vs Roon/foobar2000 |
| 9 | Lyrics fallback | S | Server-dependent lyrics |
| 10 | NL mix building | M | Nobody does it locally (differentiator) |
| 11 | Tonebox automations | M | Unique cross-app moat |
| 12 | Agent status resources | S | Agent-native completeness |
