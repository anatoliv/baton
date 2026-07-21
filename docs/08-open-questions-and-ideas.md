# 08 — Open Questions, Risks & Wild Ideas

A self-audit of this documentation suite: what's missing, what's risky, what's still
undecided — and a "wild ideas" section for things **none** of the competitors do.

---

## 1. Gaps in this suite (things I didn't fully resolve)

- **No wire-level spec for the Streamable HTTP upgrade.** [04](04-integration-and-mcp.md)
  describes the *shape* (POST/GET `/mcp`, SSE, session ids, notifications) but not the
  exact framing, reconnection/resumption (`Last-Event-ID`), or backpressure. That
  needs its own mini-spec before implementation (it's the one genuinely new
  networking effort — [03](03-architecture.md) Phase 4).
- **Audio-focus edge cases under-specified.** The generation-counter contract
  ([04](04-integration-and-mcp.md) §4.3) needs a decision on **nesting** (stack vs
  reject) and exact **handle-expiry timing**, plus a test matrix (user hits play mid-
  duck; two owners overlap; client disconnects mid-suspend; Baton restarts while
  suspended).
- **No performance budget.** "< ~50 ms for dictation ducking" is asserted, not
  measured. Need real loopback round-trip numbers (HTTP vs SSE vs Unix socket) to
  justify the fast-path.
- **No data-migration plan detail.** [06](06-improvements-existing.md) #13 flags the
  cache/manifest move; the actual importer (play history, EQ presets, radio bans,
  download manifest, server config) isn't designed.
- **UI/UX for the standalone shell is unspecified.** Onboarding, menu-bar layout,
  Settings IA, and the "Baton not running" story in Tonebox are named but not designed.
- **Testing strategy for the extraction isn't written.** Each phase has an "exit
  test" ([03](03-architecture.md)) but there's no plan for characterization tests to
  lock current behavior before moving code (the gapless timing especially).

## 2. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Gapless/EQ timing regresses when moved to a new bundle/output path | High | Move verbatim; hardware test matrix ([06](06-improvements-existing.md) #1, #4) |
| Streamable-HTTP transport is more work than budgeted | Med | Treat as a feature, not a refactor; consider a thin SSE layer over the existing handler first |
| Cross-process audio focus feels laggy vs in-process | Med | Native fast-path (Unix socket) for `audio_suspend` ([04](04-integration-and-mcp.md) §7) |
| Two products dilute focus (Tonebox + Baton) | Med | Shared modules; Baton is mostly *extraction*, not net-new code |
| Security: `allowRemote` over plain HTTP leaks the token on-LAN | Med | Keep loopback default; warn/require TLS before remote; `0600` discovery file |
| Users lose offline library on migration | Low–Med | One-time manifest importer ([06](06-improvements-existing.md) #13) |
| Subsonic servers vary (classic vs OpenSubsonic) | Low | Already handled — extension probing, MP3 transcode fallback (`NavidromeClient`) |

## 3. Open product decisions

- **Naming.** `Baton` is a placeholder — and "Baton" collides with
  Google AMP, several audio products, and a Sonos feature. Needs a real,
  trademark-checkable name before any public identity.
- **Licensing / pricing.** Free (as it is inside Tonebox)? One-time purchase
  (Plexamp/foobar model)? Open-source client, paid companion? Undecided.
- **Ship channel.** Direct download + Sparkle appcast (Tonebox has this infra —
  memory: `appcast.tonebox.io`, web-01) vs Mac App Store (sandboxing conflicts with
  the local MCP server + login item + arbitrary download folder — likely
  direct-download only).
- **Relationship to Tonebox after extraction.** Does Tonebox keep a music *tab* (thin
  "open Baton" affordance) or drop music entirely? Affects Phase 6.
- **Multi-platform strategy.** iOS companion is roadmap ([05](05-roadmap-new-features.md)
  #1); does the MCP-server-as-control-surface idea extend to iOS (background limits
  make hosting a server hard) or does iOS become a *client* of the Mac?
- **Which optional deps ship.** Baton ships **no** in-app NL interpreter today —
  natural-language control is delegated to the *client* agent driving the MCP tool
  catalog (`app/Sources/Baton/MCP/BatonMCPTools.swift`). Open question: do we ever bundle
  a local LLM for on-device NL, or stay MCP-only and let the client agent own it?
- **Server support scope.** Navidrome-first, but Subsonic/OpenSubsonic broadly — do
  we test against Jellyfin (via its Subsonic shim), Airsonic, Gonic, Ampache?
- **Default appearance — decided: forced dark.** The app forces a **dark** color scheme
  as its default (`preferredColorScheme(.dark)` in `MusicView.swift` /
  `FullScreenNowPlaying.swift` / `MiniPlayerWindowView.swift`) so text/icons stay legible
  over the color-from-artwork backdrop and the player reads consistently. Intentional and
  shipped; a user-facing light/auto option is a possible future, not a current goal.

## 4. Wild ideas (nobody in the field does these)

Lean into the agent-controllable angle — this is where Baton is unique.

1. **Natural-language mix composition.** "Make me a 40-minute focus mix that starts
   mellow and ramps up." An MCP prompt + tool flow that *composes* a queue (search +
   sonic features + duration budgeting), not just runs a single command. Extends the
   MCP tool catalog from *commands* to *curation*. ([05](05-roadmap-new-features.md) #10)
2. **Agent-built, self-maintaining playlists.** "Keep a playlist of everything I like
   this month that I haven't skipped." An agent subscribed to now-playing +
   likes/skips maintains it continuously via `music_create/add_to_playlist`.
3. **Cross-app "listening context."** When Tonebox starts a recording, Baton logs the
   track that was playing into the session ("we were listening to X when we decided
   Y"). Built on now-playing notifications + `audio_suspend`. A genuinely novel
   Tonebox×Baton feature.
4. **Mood-aware ducking.** `audio_suspend(mode:"duck")` that ducks *musically* — fade
   to a bed volume and, if the track is about to hit a loud section, nudge to a quiet
   passage first. Uses the same sonic analysis as mood mixes.
5. **"Explain this mix."** An agent reads `baton://now-playing` + history and narrates
   *why* a track is in your mix ("because you liked three albums by this artist and it
   matches the tempo of your last focus session").
6. **Voice + agent hand-off.** "Tonebox, play something" (voice) → the agent picks
   based on calendar/time/recent context, not just a keyword search. Route the ambiguous
   case to an agent over Baton's MCP tools (`app/Sources/Baton/MCP/BatonMCPTools.swift`)
   rather than a local keyword classifier.
7. **Shareable control tokens.** A scoped, expiring MCP token that lets a *trusted*
   remote agent (e.g. a home-automation hub) control playback — "play the dinner mix
   at 7pm" as a scheduled agent action.
8. **Listening-session summaries.** End-of-day: an agent summarizes what you played,
   surfaces "you kept skipping X," and offers to prune (reusing the existing "mark for
   removal" server signal, `MusicLibraryStore.markForRemoval`).
9. **Programmable transitions.** Expose crossfade/gapless as agent-tunable per
   transition ("DJ mode: 8-second crossfades for this party playlist").
10. **Deterministic "focus contract."** An agent sets up: "for the next 90 minutes,
    play ambient, duck to 15% whenever I dictate, and don't auto-radio into
    vocals" — a single declarative intent that composes `music_play` +
    `audio_suspend` policy + radio bans. The audio-focus generation counter makes this
    safe against the user grabbing control at any point.

## 5. What would make this suite "done"

- A **wire-level Streamable-HTTP + audio-focus spec** (the two hardest new pieces).
- A **characterization test plan** so the extraction can't silently regress gapless/EQ.
- A **name + licensing + ship-channel decision** so the app has an identity.
- A **migration importer design** so existing Tonebox music users don't lose local
  state.

Everything else in this suite is either verified against the code or a clearly-flagged
proposal ready to be turned into tickets.
