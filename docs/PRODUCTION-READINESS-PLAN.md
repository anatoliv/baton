# Baton — Production-Grade Improvement Plan (v0.1.0 → long-term)

Synthesized from 231 findings across 7 review dimensions (architecture, audio, MCP/speech,
networking/persistence, distribution, testing/product, security). Every finding ID is traceable in
§5. Repo: `/Users/anatoli/Projects/baton`; all paths below relative to repo root. The release gate
is LOCAL (GitHub Actions intentionally off) — every phase ends with `scripts/test.sh` green (W-01).

---

## §0 Executive summary

Baton v0.1.0 is unusually strong for a first release: Swift 6 strict concurrency, consistent
`@MainActor @Observable` stores, 34 test files with real breadth on pure logic, sound MCP token
design, and a correct Sparkle/EdDSA update path *in principle*. What stands between this and a
production-grade product is a systemic pattern: **silent failure**. Errors are swallowed
(`try?`-to-empty on both reads and writes), persistence has no versioning and wipes itself on
corruption, downloads adopt HTTP error pages as music, the scrobble queue destroys the very data
it exists to protect when offline, and the auto-update channel will silently never offer the next
release. Several hard crashes are reachable (pre-auth HTTP parser traps, SIGPIPE on the control
socket, `MainActor.assumeIsolated` in AV callbacks). The riskiest code (crossfade, MCP transport,
the 18 original tools, download networking) has zero tests, while the safest code is well covered.

**Top must-fix items (merged IDs):**
1. W-09 — Update channel silently broken for all future releases (DIST-01/02/12)
2. W-08 — Offline plays permanently drop scrobbles (SCR-01/02)
3. W-05/W-06 — Downloads save error pages as audio; folder rescan can delete user files (DL-01/05, ARCH-04, PER-03)
4. W-02/W-03/W-04 — Reachable crashes: pre-auth HTTP parser traps, SIGPIPE, assumeIsolated (ARCH-03, MCP-01, SOCK-01/05, AUDIO-04, ARCH-22, SPEECH-08)
5. W-10 — Sentry can exfiltrate server address + Subsonic auth, contradicting the privacy promise (DIST-03, SEC-02, DIST-13)
6. W-12 — Every persisted store silently wipes user data on corrupt/incompatible files (POD-09, PER-02, NET-13, DL-06, ARCH-28)
7. W-11 — Persisted queue is never restored; playhead effectively not persisted (ARCH-01, AUDIO-09/15)
8. W-20/21/22 — EQ: shared filter state raced across taps, 44.1 kHz hardcoded, silently lost on crossfade (AUDIO-01/02/03/07/08/26/28/29, ARCH-06/16)
9. W-46 — MCP transport + all 18 original tools have zero tests; no E2E gate for the defining feature (TEST-01/02/03, MCP-TEST-01)
10. W-33/W-34 — Downloads: failures invisible, no cancel/resume, always lossy-transcoded `.mp3` (DL-02/03/04)

**Totals:** 64 work items (W-01…W-64) across 6 phases, plus 8 confirmed-good/accepted findings and
7 owner decisions in §4. The single biggest systemic theme: **make failure observable** — a shared
versioned-persistence helper, a "writes never fail silently" rule, generation-token freshness for
every async completion, and a test harness for the MCP surface retire the majority of findings at
the pattern level rather than one-by-one.

---

## §1 Phased roadmap

Ordering rule: each phase leaves the app shippable; foundations (§3) land inside the phase that
first needs them. Numbers are stable IDs, not order — the ordered list per phase is authoritative.

### Phase 0 — Release integrity (crashes, data loss, update channel, privacy promise)
Goal: nothing shipped today can crash the app from local input, destroy user data, or violate the
stated privacy promise; the next release can actually be delivered.
Order: **W-01, W-09, W-02, W-03, W-04, W-05, W-06, W-07, W-08, W-10, W-11, W-12**

### Phase 1 — Security & privacy hardening + release pipeline
Goal: consistent secret handling, a trustworthy repeatable release process, one log identity.
Order: **W-13, W-14, W-15, W-16, W-17, W-18, W-19**

### Phase 2 — Reliability & robustness (playback, network, MCP, radio, downloads)
Goal: the core loops (play, stream, scrobble, download, podcast, agent-drive) survive real-world
failure: server restarts, Wi-Fi blips, malformed data, racing user actions.
Order: **W-25, W-23, W-20, W-21, W-22, W-24, W-26, W-27, W-28, W-29, W-30, W-44, W-45, W-31,
W-32, W-33, W-34, W-35, W-36, W-37, W-46, W-38, W-39, W-40, W-41, W-42, W-43**
(W-46's harness is pulled forward from Phase 3 because W-38…W-41 must not be refactored untested.)

### Phase 3 — Test foundation & architecture (the seams that make change safe)
Goal: characterize the riskiest code, then decompose it; single composition root; module hygiene.
Order: **W-47, W-48, W-49, W-50, W-51, W-52**

### Phase 4 — Product/UX completeness
Goal: honest UI everywhere (offline mode real, pagination, load/empty/error states), the agent
story discoverable, accessibility, diagnostics, docs re-baselined.
Order: **W-62, W-53, W-54, W-55, W-56, W-57, W-58, W-59, W-60, W-61**

### Phase 5 — Long-term platform
Goal: multi-server coherence, localization groundwork; unblocks the (re-baselined) roadmap
(iOS companion, casting, sonic mixes).
Order: **W-63, W-64**

---
## §2 Work items

Template: **Phase · Priority · Effort · Sources**. "Accept" = observable done conditions.
"Verify" = the exact tests/manual checks the implementer runs. All new tests live in
`app/Tests/BatonTests/` unless noted; all must run under `scripts/test.sh` (W-01).

---

### W-01 — `scripts/test.sh`: the single local release gate
Phase 0 · blocker · S · Sources: TEST-11
**Problem.** With GitHub Actions off by policy, there is no executable merge/release gate — test
invocation exists only in prose. Every other work item's "Verify" step needs this.
**Evidence.** `scripts/` contains only `devrun.sh`, `publish*.sh`.
**Fix.** Add `scripts/test.sh`: `xcodegen generate` (if project stale) + `xcodebuild test` against
the Baton scheme on fresh derived data, nonzero exit on failure; print a one-line summary. Wire it
into `publish.sh` as a mandatory pre-package step (see W-17) and reference from README/HANDOFF.
Optional: a git pre-push hook invoking it.
**Accept.**
- One command runs the full suite from a clean checkout and exits nonzero on any failure.
- `publish.sh` refuses to package when tests fail.
**Verify.** Run it twice (clean + incremental); intentionally break one test and confirm nonzero
exit and publish refusal.
**Deps.** none.

### W-02 — MCP HTTP parser: no pre-auth traps on malformed input
Phase 0 · blocker · S · Sources: ARCH-03, MCP-01
**Problem.** Two whole-app crashes reachable by ANY local process (even a browser page doing
`fetch("http://127.0.0.1:8787/mcp?=")`) before the bearer-token check: (1) query pair `"="` →
`split` yields empty array → `kv[0]` traps; (2) `Content-Length: -1` passes the `> maxRequestBytes`
check, then negative-offset Data indexing traps.
**Evidence.** `app/Sources/Baton/MCP/BatonMCPProtocol.swift:134-138` (query), `:151-156`
(Content-Length).
**Fix.** In `HTTPRequestMessage.parse`: skip empty `kv` pairs; `guard let n = Int(v), n >= 0,
n <= maxRequestBytes` else `.malformed`. Treat `Transfer-Encoding: chunked` as explicit 501
(MCP-07's overlap; full read-deadline handled in W-39).
**Accept.**
- `?=`, `?a`, `?a&=&b`, `Content-Length: -1`/absent/non-numeric/huge, non-UTF8 headers all yield
  a clean `.malformed`/error response, never a trap.
**Verify.** New `MCPProtocolParseTests`: table-driven fuzz over the above inputs + byte-wise
fragmented delivery. Manual: `curl 'http://127.0.0.1:8787/mcp?='` and
`curl -H 'Content-Length: -1' …` against a running dev build — app stays alive.
**Deps.** none.

### W-03 — Control socket: SIGPIPE-proof writes
Phase 0 · blocker · S · Sources: SOCK-01, SOCK-05
**Problem.** No `SO_NOSIGPIPE` on listen/accepted fds and SIGPIPE not ignored: a fast-path client
that sends SUSPEND and closes immediately kills the entire app on the reply `write`. Partial
writes also unhandled.
**Evidence.** `app/Sources/Baton/MCP/BatonControlSocket.swift:182` (write), grep-verified absence
of `SO_NOSIGPIPE`/`signal(SIGPIPE…)`.
**Fix.** `setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, …)` on both the listen fd and every accepted
fd; replace the single `write` with a write-all loop that closes the connection on error/EPIPE.
**Accept.** A client that connects, sends a request, and closes before reading the reply leaves
the app running and the accept loop serving the next client.
**Verify.** New test in `AudioFocusHardeningTests` family: real socket client sends SUSPEND then
`close()` immediately, repeated 50×; assert app process (test host) alive and a subsequent
request succeeds.
**Deps.** none. (Full socket concurrency/auth work is W-15 — keep this fix minimal and land it first.)

### W-04 — Replace `MainActor.assumeIsolated` in AV/KVO/delegate callbacks
Phase 0 · blocker · S · Sources: AUDIO-04, ARCH-22, SPEECH-08
**Problem.** AVFoundation KVO (`timeControlStatus`, `AVPlayerItem.status`) and
AVAudioPlayer/AVSpeechSynthesizer delegates are not contractually main-thread; `assumeIsolated`
traps if delivery is ever off-main → latent hard crash at stream failure or end-of-utterance.
Same pattern in the radio engine.
**Evidence.** `app/Sources/Baton/Audio/StreamingPlaybackController.swift:500-517`, `:1515-1536`;
`app/Sources/Baton/Model/InternetRadioStore.swift:289-291`;
`app/Sources/Baton/Speech/SpeechPlaybackEngine.swift:112-115,121-128`.
**Fix.** In each handler: read needed values from the KVO change/argument, then
`Task { @MainActor in … }` (ordering not load-bearing on these paths). Leave the periodic time
observer and notification observers (explicit `queue: .main`) as-is.
**Accept.** Zero `MainActor.assumeIsolated` in KVO/delegate callbacks not pinned to `.main`
(grep-clean except documented-safe sites).
**Verify.** Grep gate; existing playback tests stay green; manual: play a track whose URL 404s
mid-queue (edit stream provider) — app transitions to error state without crashing.
**Deps.** none.

### W-05 — Validate every download HTTP response before adopting it
Phase 0 · blocker · S · Sources: DL-01, ARCH-04, PER-03
**Problem.** `MusicDownloadStore.download` discards the response: a 401/404/500 or reverse-proxy
HTML login page is saved as `Artist - Title.mp3`, marked downloaded, and — because
`resolveStreamURL` prefers local files — **permanently replaces streaming** for that track, with
re-download blocked by the `isDownloaded` guard. The gapless prefetch's own check accepts
non-HTTP responses as success (`?? true`).
**Evidence.** `app/Sources/Baton/Shell/Music/MusicDownloadStore.swift:248-272`, `:241` (guard);
`app/Sources/Baton/Audio/StreamingPlaybackController.swift:428-437` (local-first);
`app/Sources/Baton/Model/MusicModel.swift` init (`?? true` → PER-03).
**Fix.** Require 2xx AND Content-Type not `text/html`/`application/json` AND non-trivial size
before moving into place; on failure leave the track undownloaded, log at error, and record a
failed state (surfacing UI is W-33). Flip the gapless prefetch `?? true` to `?? false`.
**Accept.**
- A stubbed 404/500/HTML response produces no manifest entry, no `downloadedIDs` insert, no file.
- Gapless prefetch rejects non-HTTP responses.
**Verify.** Inject a `URLProtocol` stub session into `MusicDownloadStore` (seam added here, reused
by W-33/W-49): tests `downloadRejects404`, `downloadRejectsHTMLBody`, `downloadAccepts200Audio`.
**Deps.** none.

### W-06 — Stop adopting foreign `.mp3` files; never delete files the store didn't create
Phase 0 · blocker · S · Sources: DL-05
**Problem.** The legacy rescan adopts *every* `.mp3` in the (user-choosable) download folder as a
download with `id = basename`; the Downloads manager's Remove then **deletes the user's own music
files**. Point the folder at an existing library → plausible mass data destruction.
**Evidence.** `app/Sources/Baton/Shell/Music/MusicDownloadStore.swift:408-414` (adoption), `:282-291`
(delete), `:155-159` (folder picker).
**Fix.** Only adopt legacy files present in `meta`/manifest (or whose basename matches a plausible
Subsonic id and is confirmed against the server); files of unknown provenance are listed read-only
("not managed by Baton") and Remove skips them; deleting anything not created via the manifest
requires explicit confirmation naming the file.
**Accept.**
- A folder containing foreign mp3s shows them (at most) as unmanaged; Remove/Clear never unlinks
  a file absent from the manifest.
**Verify.** Test `rescanDoesNotAdoptForeignFiles` (temp dir with `song.mp3` not in manifest →
not in `downloadedIDs`, `delete`/clear leaves it on disk). Manual: point download folder at a
copy of a music folder; use Remove All; confirm files survive.
**Deps.** none.

### W-07 — `music_delete_playlist` requires exact match
Phase 0 · blocker · S · Sources: TOOL-01
**Problem.** The only destructive MCP tool resolves its target by first-substring-match: an agent
sending `{name:"mix"}` deletes whichever of "Monday Mix"/"Mix 2024" happens to match first, with
no confirmation and a reply that doesn't name what was deleted.
**Evidence.** `app/Sources/Baton/MCP/BatonMCPTools.swift:615-636` (`resolvePlaylistID` fallback).
**Fix.** For delete only: accept exact id or exact case-insensitive name; when only fuzzy matches
exist, return an error listing the candidates; echo the deleted playlist's id+name in the reply.
(Shared resolver dedup is W-41.)
**Accept.** Fuzzy-only input never deletes; reply names the deleted playlist.
**Verify.** Unit tests: exact-name deletes; substring-only returns candidate list; response
includes id+name.
**Deps.** none.

### W-08 — Scrobble queue: transport failures must not retire entries
Phase 0 · blocker · S-M · Sources: SCR-01, SCR-02
**Problem.** `fail()` counts every failed delivery including pure transport failures, and flushes
fire on every completed play / launch / path change with no backoff. An evening of offline
listening burns 20 attempts per head entry → **permanent loss of exactly the scrobbles the durable
queue exists to protect**. `retiresAfterMaxAttempts` test locks the wrong behavior in.
**Evidence.** `app/Sources/Baton/Shell/Music/Scrobble.swift:66-69,107-125`;
`ScrobbleService.swift:89-98,140-153`.
**Fix.** Introduce typed failure classes in `ScrobbleError`: `.transport` (URLError,
`NavidromeError.transport`, 5xx, 429) does NOT bump `attempts`; only definitive rejections
(HTTP 4xx protocol errors, Subsonic error codes) do. Add per-destination exponential backoff with
a persisted next-attempt-at; honor `Retry-After`/`X-RateLimit-Reset-In` on 429. Gate opportunistic
flushes on `NWPathMonitor.status == .satisfied`.
**Accept.**
- N consecutive offline flush cycles leave the queue byte-identical (attempts unchanged).
- A permanent rejection still retires after maxAttempts.
- Erroring server receives at most one delivery attempt per backoff window.
**Verify.** Rewrite/extend `ScrobbleTests`: `transportFailuresDoNotBurnAttempts` (20 offline
cycles → queue intact), `permanentRejectionRetires`, `backoffSpacesAttempts` (fake clock).
**Deps.** none. (Session-invalidation semantics: W-31.)

### W-09 — Fix the Sparkle update channel before the next release
Phase 0 · blocker · S · Sources: DIST-01, DIST-02, DIST-12
**Problem.** (1) `publish.sh` emits `sparkle:version = 0.1.0` (marketing) while installed apps
carry `CFBundleVersion "1"` — Sparkle compares `0.2.0 < 1`, so **no future update will ever be
offered**. (2) `SparkleUpdater` is a lazy singleton touched only from Settings/menu UI — a user
who just plays music never gets a background check scheduled despite `SUEnableAutomaticChecks`.
(3) `UpdateChannel.isConfigured` conflates channel-liveness with auto-checks; zero tests.
**Evidence.** `scripts/publish.sh:99`; `app/project.yml:43-44` (`CURRENT_PROJECT_VERSION: "1"`);
`website/appcast.xml:9`; `Integrations/SparkleUpdater.swift:16-26`; `BatonApp.swift:31-35`;
`Integrations/UpdateChannel.swift:26-35`.
**Fix.** Adopt monotonic build numbers: `publish.sh` bumps `CURRENT_PROJECT_VERSION` (integer),
emits it as `sparkle:version` and marketing as `sparkle:shortVersionString`, per
`docs/RELEASE-APPCAST-HOSTING.md:48-49`. In `BatonApp.init()` (or app-level owner):
`if UpdateChannel.isConfiguredFromBundle { _ = SparkleUpdater.shared }`. Add a dedicated
liveness key (or treat non-placeholder key + https feed as configured).
**Accept.**
- Built app's `CFBundleVersion` strictly increases per release and matches the appcast item.
- Fresh install with no UI interaction schedules an automatic check (Sparkle log line visible).
**Verify.** Unit test pinning the version convention (parse built Info.plist vs appcast
generation logic); table-driven `UpdateChannelTests` for `isConfigured`. Manual (runbook step 6):
install the previous DMG, publish a staging appcast with the new build → update IS offered.
**Deps.** none; W-17 extends the pipeline around it.

### W-10 — Sentry privacy hardening: nothing identifying leaves the machine
Phase 0 · blocker · M · Sources: DIST-03, SEC-02, DIST-13
**Problem.** sentry-cocoa 8.x defaults enable network breadcrumbs/tracking/failed-request capture
and `tracesSampleRate = 0.2`; request URLs carry the private hostname and Subsonic auth
(`u`/`t`+`s`, or the literal `apiKey`). `beforeSend` nils only `user`/`serverName`/`request` —
not breadcrumbs, exception messages (`NavidromeError.transport(error.localizedDescription)`
embeds host), `extra`, or spans (which bypass `beforeSend` entirely). This contradicts the
documented promise ("server URL is never attached"). Defaults also include app-hang tracking
(noisy) and 20% transactions not covered by the "crash & error reports" toggle wording.
**Evidence.** `Integrations/CrashReporting.swift:75-95` (no `beforeBreadcrumb`; `:83-86`
tracesSampleRate); `NavidromeClient.swift:73-91` (auth in URL), `:368` (host in error string);
`SpeechService.swift:53,56`; promise at `CrashReporting.swift:16-19`,
`BatonSettingsView.swift:329`.
**Fix.** In `CrashReporting.start`, make every option explicit: disable network
breadcrumbs/tracking/failed-request capture; `tracesSampleRate = 0`; disable/raise app-hang
threshold; add `beforeBreadcrumb` dropping URL-bearing crumbs; extend `beforeSend` to
regex-redact `https?://…`, RFC-1918/`.local` hosts, `t=`/`s=`/`u=`/`apiKey=` params, and file
paths across `message`, `exceptions[].value`, breadcrumbs, `extra`, contexts. Comment each choice.
Verify exact option names against the resolved sentry-cocoa (8.58.4; pin via W-17/DIST-06).
**Accept.**
- A synthetic event containing a Subsonic URL, LAN host, and apiKey in message + breadcrumb +
  exception value leaves `beforeSend` with all of them redacted.
- No transactions/spans are sent.
**Verify.** New `CrashReportingScrubberTests`: build synthetic `Event`s and assert scrubbing
(this is the shipped privacy promise — the test is mandatory). Manual: opt in on a dev build with
a test DSN, force a transport error, inspect the received event in Sentry.
**Deps.** none.

### W-11 — Restore the persisted queue; actually persist the playhead
Phase 0 · blocker · S-M · Sources: ARCH-01, AUDIO-09, AUDIO-15
**Problem.** (1) `restoreQueue()` has NO app call site (lost in the Tonebox extraction) — the
entire persist/restore machinery is dead code; users relaunch to an empty player despite the doc
contract. (2) `persistQueue` only runs on transport events, so the saved position is ~always 0;
quit 40 min into a set → back to 0:00; `willTerminate` doesn't persist. (3) `resume()` after a
restore never fires `notifyTrackStarted`, so history/scrobble "now playing" skip and
`currentTrackStartedAt` (scrobble timestamp) is app-launch time.
**Evidence.** `StreamingPlaybackController.swift:1657` (definition; call sites only in tests),
`:1648-1653` (persist), `:704-717` (`pauseInternal` no persist), `:682-702` (`resume`), `:114`;
`BatonApp.swift:60-65` (terminate handler).
**Fix.** Call `restoreQueue()` once at startup (in `MusicModel.init` after `wire()`, before the
MCP server starts). Persist in `pauseInternal()`, every ~15 s of playback inside the existing
periodic observer, and in the `willTerminate` handler. In `resume()`, when first play of a
restored item (`hasNotifiedStartForLoadedItem` flag cleared by `loadCurrent(autoplay:false)`),
call `notifyTrackStarted(song)` and stamp `currentTrackStartedAt = Date()`.
**Accept.**
- Quit mid-track → relaunch → queue + track + position restored paused; pressing play logs
  history, sends "now playing", and scrobbles with a correct timestamp.
**Verify.** Integration test: play, advance fake clock, recreate controller from the same store,
assert restored queue + `pendingSeek` ≈ saved position; test that resume-after-restore fires the
started callback exactly once. Manual: quit mid-track, relaunch, confirm position and that the
scrobble timestamp is post-resume.
**Deps.** none. (Multi-server queue tagging: W-63.)

### W-12 — Versioned persistence + corruption safety for every store [Foundation F1]
Phase 0 · blocker · M · Sources: POD-09, PER-02, NET-13, DL-06, ARCH-28
**Problem.** Every store follows `try? decode else start-empty`, and the next mutation persists
empty over the old file: one corrupt/truncated file (power loss) or ANY future incompatible
Codable change silently erases subscriptions / progress / listen archive / server list / queue.
No schema versioning exists anywhere; persistence writes (`persistQueue`, manifest/meta,
`MusicPlayHistory.save`, `writeServers`) are `try?`-swallowed without even a log.
**Evidence.** `PodcastSubscriptionStore.swift:55-58`; `PodcastProgressStore.swift:50-53`;
`MusicPlayHistory.swift:209-220`; `Scrobble.swift:132-143`;
`MusicDownloadStore.swift:359-393`; `NavidromeConfig.swift:316-325`;
`StreamingPlaybackController.swift:1648-1653`.
**Fix.** One shared helper (e.g. `VersionedStore<Payload>`): envelope `{version, payload}`;
decode failure → rename the bad file aside as `.corrupt-<ISO date>` (never overwrite), log at
error, surface a one-time notice; migration hooks per version; a rolling last-good backup for the
listen archive and server list. All writes funnel through a logging path — rule: *reads may
degrade, writes must never fail silently*. Adopt in all six stores + the queue snapshot; migrate
existing unversioned files on first load (wrap as v1).
**Accept.**
- A truncated store file on disk → app starts with empty state BUT the original is preserved as
  `.corrupt-*` and an error is logged/surfaced; next save does not destroy it.
- Bumping a payload version with a migration converts old data losslessly (test per store).
- Grep: no bare `try? defaults/write` persistence writes remain in the six stores.
**Verify.** `VersionedStoreTests`: round-trip, corrupt-file preservation, unknown-future-version
handling, v1 migration from today's raw formats (fixture files captured from current encoders).
**Deps.** none; W-32/W-36/W-63 build on it.

---

### W-13 — All secrets into the Keychain
Phase 1 · high · M · Sources: SEC-03, NET-14, SEC-19, PROD-15, SEC-09
**Problem.** Only the Navidrome password gets Keychain treatment. In plaintext UserDefaults:
the MCP bearer token (full remote control), the ListenBrainz user token, the Last.fm API
secret + session key, and webhook `Authorization` header values. Legacy plaintext migration
also leaves residue in the plist and only fires on the read path.
**Evidence.** `BatonMCPServer.swift:51-58`; `MusicScrobbler.swift:17-29`;
`MusicLastFM.swift:19-42`; `WebhookActions.swift:170-175,226-236`;
`NavidromeKeychain.swift:50-61` (migrate-on-read).
**Fix.** Reuse the proven `NavidromeKeychain` migrate-on-read pattern for: MCP token, LB token,
Last.fm session key + shared secret, webhook secret-looking header values (keyed by action id).
Add a one-time launch sweep deleting known legacy plaintext defaults keys regardless of read
path; note in docs that pre-migration backups may contain old plaintext.
**Accept.** Grep: none of these secrets read/written via `UserDefaults` outside the migration
shim; fresh install stores them Keychain-only; existing installs migrate transparently.
**Verify.** `NavidromeKeychainTests` extension: migration round-trip per secret using the
in-memory store; manual: upgrade a dev profile with legacy defaults set → values survive, plist
keys gone.
**Deps.** none.

### W-14 — MCP discovery-file & token lifecycle; Host/Origin validation
Phase 1 · high · S-M · Sources: MCP-11, MCP-12, ARCH-33, SEC-04
**Problem.** (1) `mcp.json` (live token + port) is written world-readable for a moment
(write-then-chmod), persists after quit/crash — a later process binding 8787 receives the token
from reconnecting clients. (2) `?token=` is accepted (secret lands in logs/referrers). (3) No
rotation path. (4) A second Baton instance silently unlinks the first's `control.sock` and
overwrites `mcp.json` → split-brain. (5) No Host/Origin check → DNS-rebinding pages are stopped
only by the token.
**Evidence.** `BatonMCPServer.swift:377-406,397-403,51-58,83-93`; `BatonMCPProtocol.swift:85-93`;
`BatonControlSocket.swift:86-88` (unlink-before-bind).
**Fix.** Create discovery via `FileManager.createFile(attributes: [.posixPermissions: 0o600])`;
delete it in `stop()`/`willTerminate`; rotate the token per launch (clients re-read mcp.json —
document this contract); header-only auth (drop `?token=`, incl. SSE GET); before unlink/
overwrite, check the recorded pid is dead (kill(pid,0)); reject requests whose `Host` is not
`127.0.0.1[:port]`/`localhost` or whose `Origin` (when present) is non-null/non-localhost.
Manual "Regenerate token" ships with W-57's Settings pane.
**Accept.**
- No world-readable window (file created 0600 atomically); mcp.json absent after clean quit.
- `?token=` rejected; wrong Host/Origin → 403.
- Second instance refuses to steal a live first instance's socket/discovery.
**Verify.** Extend W-46 harness tests: perms-at-creation check, Host/Origin rejection table,
query-token rejection; two-instance test using a fake pid file. Manual: quit app → mcp.json gone.
**Deps.** W-46 harness helpful but not required.

### W-15 — Control socket: concurrency correctness + authentication
Phase 1 · high · M · Sources: ARCH-13, ARCH-14, ARCH-15, SOCK-02, SOCK-03, SOCK-04, SEC-05, SEC-06
**Problem.** `stopped`/`listenFD` are plain vars raced across threads (`@unchecked Sendable` UB);
one client at a time is served with no read timeout, so an idle client starves ALL fast-path
callers (dictation ducking silently stops) and blocks `stop()`; the socket is created at umask
then chmod'd (TOCTOU); no authentication beyond file perms (any local process can spam
`SUSPEND … duck 0` or RESUME another's handle); every request blocks on `DispatchQueue.main.sync`
(duck latency = main-thread latency, latent deadlock).
**Evidence.** `BatonControlSocket.swift:27,34-37,136-143,147-187,246-251,110-121`.
**Fix.** (a) `OSAllocatedUnfairLock` (or atomics) around `stopped`/`listenFD`;
`shutdown(SHUT_RDWR)`-then-close to wake `accept`; track+close client fds in `stop()`.
(b) `SO_RCVTIMEO` read deadline (~2 s) and accept-and-spawn per connection (state already hops to
main). (c) `umask(0o077)` around `bind`, keep chmod as backup. (d) Require an `AUTH <token>` first
line (the MCP bearer token) before honoring commands; bind handle ownership to the connection.
(e) Keep `main.sync` for now but document the latency contract; the lock-protected registry
refactor is noted in W-50's decomposition (focus extraction) — don't do it twice.
**Accept.**
- An idle/hung client cannot delay a second client's SUSPEND beyond the read deadline.
- `stop()` returns promptly with a wedged client connected.
- Unauthenticated commands are refused; TSan-clean under a concurrent connect/stop stress test.
**Verify.** New `ControlSocketLifecycleTests`: concurrent clients, idle-client + fast client
latency assertion, stop-with-wedged-client, malformed/oversized frames (also covers TEST-14
adversarial inputs), auth-required. Run the suite under Thread Sanitizer locally.
**Deps.** W-03 (lands first, minimal).

### W-16 — Server-URL scheme validation + cleartext posture
Phase 1 · high · S · Sources: SEC-07, SEC-11, SEC-08
**Problem.** The server-URL validator accepts any non-nil scheme (`file:///etc/passwd` passes and
`ping.view` gets appended and fetched); cleartext `http://` is allowed silently, and in `.apiKey`
mode the raw reusable key rides the query over the LAN. Auth material in query strings can reach
server/proxy logs (partly inherent to Subsonic).
**Evidence.** `NavidromeConfig.swift:176-180`; `NavidromeClient.swift:73-101,112-124`;
`app/Info.plist:27-33`.
**Fix.** Restrict validator to http/https (mirror `PodcastFeed.cleanURL`); on `http://` show a
one-time warning + persistent "insecure connection" indicator in Settings; keep full URLs out of
log calls (add a lint/test greping `absoluteString` in `Logger` calls); document query-auth
implications in docs.
**Accept.** `file://`/`ftp://` rejected at entry; http servers connect but display the indicator.
**Verify.** `NavidromeConfigTests`: scheme table; UI manual check of the indicator; grep-lint in
`scripts/test.sh`.
**Deps.** none.

### W-17 — Release pipeline hardening (one canonical appcast, verified artifacts)
Phase 1 · high · M · Sources: DIST-04, DIST-05, DIST-06, DIST-07, DIST-08, DIST-14, DIST-15, DIST-16, DIST-17, SEC-16
**Problem.** `publish.sh` scp's artifacts to `/tmp` on the web host and prints "Published."
(nginx serves `/opt/docker/baton-web/site`; /tmp is wiped on reboot); two hand-reconciled
appcasts where regeneration overwrites history and placeholder signatures / unsigned builds can
ship; `Package.resolved` is gitignored (unreproducible builds — the Sentry 8.x auto-instrumentation
surface in W-10 depends on the resolved version!); no release tags or artifact archive; `codesign
--deep` (deprecated, Sparkle-fragile), `.app` never stapled, releases built from incremental
derived data with no tests; secrets-guard regex misses the project's own schemeless DSN format;
no Cache-Control on appcast.xml; single-copy Sparkle EdDSA key with unverified backup — key loss
permanently strands all installs; pre-build script mutates tracked files every build.
**Evidence.** `scripts/publish.sh:38-41,48-49,57-71,91-115`; `publish-site.sh:23,31-40`;
`.gitignore:5`; `app/project.yml:18-33,72-78,131`; `scripts/publish-repo.sh:50`;
`deploy/nginx/default.conf:31-42`; `docs/RELEASE-APPCAST-HOSTING.md:32-34,52-55`.
**Fix (checklist — implement in publish.sh + repo config).**
1. Make `website/appcast.xml` the single canonical feed; publish.sh *prepends* the new item,
   XML-validates, and refuses when ED_SIG is empty/placeholder or signing/notarization skipped.
2. Publish stage: place DMG then appcast atomically into `$REMOTE_DIR/site/` (temp name + mv);
   post-publish verify: `curl -f` the DMG URL, compare sha256/length with the appcast item.
3. Commit `Package.resolved` (carve-out from the `*.xcodeproj` ignore); pin Sentry/Sparkle to
   `upToNextMinor` (record resolved: Sentry 8.58.4, Sparkle 2.9.4).
4. Tag `v$VERSION` (refuse dirty tree); archive DMG+appcast per release; record git SHA in the
   appcast item.
5. Sign without `--deep` (explicit nested signing); staple the `.app` before `hdiutil create`
   AND the DMG; run `scripts/test.sh` on fresh derived data before packaging; `spctl -a -vv`
   verification.
6. Key preflight: `sign_update` a temp file and verify against the built app's `SUPublicEDKey`,
   abort on mismatch; confirm+record the private-key backup (per-app key noted as decision D-06).
7. Fix `publish-repo.sh` DSN regex to the schemeless form (`[0-9a-f]{16,}@o[0-9]+\.ingest\.`).
8. nginx: `location = /appcast.xml` no-cache; long-cache immutable version-named `*.dmg`; extend
   the health check to curl appcast + newest DMG; fence DMGs from any `--delete` sync.
9. Reverse the HELP.md/FAQ.md copy direction (Resources canonical + lint) or resolve at
   project-generation time; publish.sh refuses a dirty tree.
**Accept.** A full dry-run release (staging dir) produces: tagged commit, signed+stapled app and
DMG, single appcast with history preserved, all origin-verified; every refusal path triggers on
its induced failure.
**Verify.** Scripted dry-run mode (`PUBLISH=0`) exercised in-repo; deliberately break each gate
(placeholder sig, dirty tree, missing notarization) and confirm refusal. Then execute the real
runbook once end-to-end including W-09's install-old-DMG upgrade test.
**Deps.** W-01, W-09.

### W-18 — One log/identity namespace: `io.tonebox.baton` + client name "baton" [Foundation F2]
Phase 1 · high · S · Sources: DIST-10, NET-08, SPEECH-09
**Problem.** Three Logger subsystems (18 categories under `io.tonebox.macos` — collides with the
Tonebox app on the same Mac — 4 under `io.tonebox.baton`, 1 bare `io.tonebox`); a support
`log show` misses ~80%. The Subsonic client id/User-Agent still say "tonebox" (server activity
logs show the wrong app; Navidrome per-client transcoding config keys on it). Speech logger also
mislabeled. v0.1.0 is the cheapest moment to change the client id.
**Evidence.** grep results per DIST-10; `NavidromeClient.swift:45,357`;
`PodcastSubscriptionStore.swift:35`; `SpeechConfig`/`SpeechService` (`io.tonebox.macos`).
**Fix.** Introduce a `Log` namespace (single `subsystem = "io.tonebox.baton"`, static category
accessors); mechanically migrate all 24 sites; forbid ad-hoc `Logger(subsystem:)` via grep-lint
in `scripts/test.sh`. Change `clientName`/User-Agent to "baton"; release-notes caveat: Navidrome
per-client transcoding configured for "tonebox" must be re-created for "baton".
**Accept.** `log show --predicate 'subsystem == "io.tonebox.baton"'` captures everything; grep
finds zero other subsystems; server activity shows "baton".
**Verify.** Grep-lint; manual log capture during a play session; check Navidrome activity page.
**Deps.** none. Land before W-61 (log export reads this subsystem).

### W-19 — Speech/TTS hardening (temp files, caps, fallbacks, transport)
Phase 1 · high · S-M · Sources: SEC-12, SPEECH-04, SPEECH-05, SPEECH-06, SPEECH-07, SPEECH-10
**Problem.** Synthesized WAVs accumulate in tmp forever (privacy residue + growth);
`mode:"auto"` plays arbitrary audio immediately (audio-spam vector if token leaks); notification
"Play" silently no-ops when the temp file is gone; no cap on summary length (50 KB text → 30 s
timeout → system voice reads the whole thing); native fallback builds a broken locale id
("en_US") and ignores the requested voice/language; TTS hosts are unauthenticated plain HTTP on
the LAN.
**Evidence.** `BatonMCPSpeakTools.swift:46,77-87,94-102`; `SpeechNotifier.swift:45-47`;
`SpeechPlaybackEngine.swift:56-61,70-71`; `SpeechService.swift:40-45`; `SpeechConfig.swift:30-37,
95-107,66-73`.
**Fix.** Delete clips after playback/dismiss + launch sweep of files >1 day; gate `mode:"auto"`
behind a preference (default notify/banner); always store `nativeTextKey` so a missing file falls
back to native speech; cap text ~2k chars (tool returns an error beyond); one quick retry on
connection-refused; proper BCP-47 conversion + voice/language mapping for the native fallback;
case-insensitive category lookup; optional bearer/API-key per TTS host (URLSession header) and
https support.
**Accept.** tmp dir stays bounded across 100 speaks; auto-play off by default; oversized text
rejected with a clear tool error; `category:"es"` fallback uses a Spanish voice.
**Verify.** `SpeechConfigTests` (resolution, category case, locale conversion),
`SpeakToolsTests` (length cap, mode fallback chain, temp cleanup) — requires the injectable
URLSession seam (shared with W-49/TEST-04). Manual: run against the ai-01 Kokoro host.
**Deps.** none; W-43 covers the product-behavior half (ducking/queueing/notify status).

---

### W-20 — EQ: per-tap filter state, no allocation/locks on the render thread
Phase 2 · high · M · Sources: AUDIO-03, ARCH-16, AUDIO-07, AUDIO-29
**Problem.** One shared `AudioEQProcessor` backs every tap the app ever creates; two taps can be
live simultaneously (gapless/crossfade boundaries), concurrently mutating the same plain-Swift
`state: [[BiquadState]]` — memory unsafety in the audio path (garbage at best, crash at worst).
`process()` also takes an `os_unfair_lock`, copies a Swift array per callback, and reallocates
`state` on the render thread (RT-safety violations → dropouts under load). No denormal
protection (Intel-only concern).
**Evidence.** `AudioEQProcessor.swift:9-14,43-45,48-71,84-87`; `MusicModel.swift:50-53`;
`MusicEqualizer.swift:277-292` (`snapshot`).
**Fix.** Per-tap state: allocate channels×bands `BiquadState` in a fixed C buffer in
`tapInit`/`tapPrepare` via `MTAudioProcessingTapGetStorage`, freed in `tapFinalize`; the shared
object carries only coefficients. Publish coefficients via a lock-free slot (fixed-capacity
buffer + atomic sequence/pointer swap). Never allocate or lock in `process`. If x86_64 ships,
flush denormals in `prepare` (FTZ/DAZ) — check the built archs first; if arm64-only, document
and skip.
**Accept.** Two concurrent taps process independent state; Instruments shows zero allocations in
the render callback; TSan-clean on a prepare-during-process stress test.
**Verify.** New `AudioEQProcessorTests`: drive `process` on two threads with interleaved
`prepare` (synthetic buffers) — no crash, per-tap outputs independent; sine-in/level-out DSP test
(basis for W-21). Manual: EQ on + gapless album, listen across boundaries.
**Deps.** none. W-21/W-22 build on this.

### W-21 — EQ: honor the actual sample rate; guard filters; clipping protection
Phase 2 · high · M · Sources: AUDIO-01, AUDIO-26, AUDIO-08
**Problem.** Biquads are computed once for fs=44 100 regardless of the tap's real rate: every
48 k stream (Opus/AAC transcodes, podcasts) shifts all band centers by ~9%, 96 k by 2.18× — the
EQ is quietly wrong on a large fraction of material and the drawn curve diverges from the audible
one. `Biquad.peaking` is unguarded against q≤0 / f0≥Nyquist (NaN cascade once fs varies). Boosts
have no clipping protection (+6 dB bass on a loud master hard-clips).
**Evidence.** `MusicEqualizer.swift:166,240-256,48-49`; `AudioEQProcessor.swift:84-87`
(discards `mSampleRate`), `:59-69` (unclamped write-back).
**Fix.** Thread `mSampleRate` from `tapPrepare` into per-rate coefficient computation (derive
coefficients per rate at prepare from published band params). Clamp inside `Biquad.peaking`
(`q = max(q, 0.1)`, `f0 = min(f0, fs*0.45)`, return `.identity` for non-finite). Auto pre-gain of
`-max(0, maxCombinedBoostDB)` computed from the published response curve (label "auto gain
compensation" in the EQ UI), plus a cheap soft-knee clamp at ±1.0 in `process` as backstop.
**Accept.** A 48 k buffer with a 1 kHz band peaks at 1 kHz (not ~1.09 k); 20 kHz band at fs=22.05k
yields a stable filter; full-scale sine + max boost stays ≤ 0 dBFS out.
**Verify.** DSP tests: run `process()` at 44.1 k and 48 k, FFT/level-probe at band centre;
clamp unit tests; clipping test (full-scale in + Bass Boost → no sample >1.0). Manual: play a
48 kHz FLAC with Vocal Boost, confirm the boost lands on vocals and UI curve matches.
**Deps.** W-20 (per-tap state carries the rate).

### W-22 — EQ attaches to every playback path (crossfade, gapless preload)
Phase 2 · high · S · Sources: AUDIO-02, ARCH-06, AUDIO-28
**Problem.** The crossfade item is created and promoted without ever getting the EQ audio-mix
tap: with EQ + crossfade on, every crossfaded-into track plays entirely un-EQ'd until the next
hard load ("EQ randomly stops working"). The gapless path attaches mid-play and asynchronously
(audible EQ step at each boundary; mid-play `audioMix` assignment isn't guaranteed to take
effect on all asset types).
**Evidence.** `StreamingPlaybackController.swift:1562-1625` (no `configureAudioMix`), `:1444`
(late attach), `:1332-1350` (preload without mix); `MusicModel.swift:115-122` (async attach).
**Fix.** Call `configureAudioMix?(item)` at crossfade-item creation in `startCrossfade`; attach
at gapless preload-item creation (`preloadGaplessNextIfNeeded`) and at `adoptPrefetchedNext`'s
swap, keeping the advance-time call as fallback. Safe only after W-20 (per-tap state makes
multiple live taps correct).
**Accept.** With EQ enabled: promoted crossfade item has non-nil `audioMix`; gapless boundary
has the mix attached before playback starts.
**Verify.** Crossfade test on the tone-file harness asserting `player.currentItem?.audioMix !=
nil` after promotion; mix-attachment counter seam asserting attach-before-play on gapless.
Manual: EQ + crossfade across 3 boundaries — EQ audibly persists.
**Deps.** W-20.

### W-23 — One freshness idiom for async completions [Foundation F4]
Phase 2 · high · M · Sources: ARCH-05, AUDIO-16, ARCH-19, ARCH-20
**Problem.** Fire-and-forget `Task {}`s with bespoke or missing guards throughout: autoplay
`fetchRelated` can resurrect a cleared queue or hijack a new album ("Clear queue" → seconds later
related tracks start playing); store loads have no cancellation/freshness (sort-change races,
shared lying `isLoading`); ~10 unowned tasks in the controller reviewed one-off.
**Evidence.** `StreamingPlaybackController.swift:1483-1510,1298,1474,1227-1238` (fetchRelated +
auto-skip), `:1209,1453,1618,962,908,1575` (unowned tasks); `MusicLibraryStore.swift:174-210,
450-460`.
**Fix.** Generalize the existing `seekGeneration`/`stateGeneration` pattern: a queue-generation
counter bumped by `play`/`clearQueue`/`stop`; every async completion validates it (and, for
`playFirstNew`, that the seed is still `nowPlaying`) before mutating. For stores: a tiny
`LatestWins` helper (per-surface stored `Task` with cancel-on-reissue) + per-surface `isLoading`.
Register controller tasks in an owned-task registry cancelled in `loadCurrent`/`clearQueue`/`stop`.
**Accept.** Clear-queue during an in-flight autoplay fetch → nothing appended, nothing plays;
album-sort change mid-load → final list matches final sort; spinners are per-surface.
**Verify.** Tests: `autoplayDropsResultAfterClearQueue`, `autoplayDoesNotHijackNewAlbum` (slow
fake provider), `storeLoadLatestWins` (two interleaved fake responses). 
**Deps.** none. W-26/W-30 reuse the idiom.

### W-24 — Queue/shuffle/transport correctness cluster
Phase 2 · high · M · Sources: ARCH-02, AUDIO-11, AUDIO-10, ARCH-36(1-3), AUDIO-30(sleep/end nits)
**Problem.** (1) Un-shuffle restores the pre-shuffle snapshot verbatim: tracks enqueued while
shuffled are silently deleted, and if one is currently playing, `currentIndex` goes stale →
`nowPlaying` points at a different song than is audible (MCP agents hit this via
`music_queue_add` + `music_set_shuffle`). (2) `removeFromQueue` mis-picks the next track when
removals span items before the current index. (3) `stop()` shows 0:00 but resume continues
mid-track. (4) Nits: enqueue-while-stopped silence, unclamped seek during `.loading`, stale
`[i/n]` summary, `sleepAtEndOfTrack` not firing `onSleepFire`, sleep fade calling user-facing
`pause()`.
**Evidence.** `StreamingPlaybackController.swift:780-798` (shuffle), `:823-836` (remove),
`:720-729,682-702` (stop/resume), `:655-668,856,976-981,962-971`.
**Fix.** Shuffle: append to `orderBeforeShuffle` on enqueue/playNext/autoplay-append while
shuffled; on un-shuffle merge (original order + members not in snapshot), recompute
`currentIndex`, handle not-found explicitly. Remove: `newIndex = currentIndex - removedBefore`
then clamp. Stop: also `player.seek(to: .zero)` (or drop the item). Fold the listed nits.
**Accept.** shuffle→enqueue→unshuffle keeps the added track and `nowPlaying` unchanged;
`[a,b,c,d,e]` current c, remove {a,c} → plays d; stop-then-play starts at 0:00.
**Verify.** Unit tests: `unshufflePreservesTracksAddedWhileShuffled`,
`removeFromQueueMixedOffsets`, `stopResetsPosition` (tone-file harness) — none exist today.
**Deps.** none (pairs naturally with the future QueueModel extraction in W-50).

### W-25 — Network foundation: timeouts, unified transport, retry, tolerant decode [Foundation F3]
Phase 2 · high · M · Sources: NET-01, NET-02, NET-03, NET-09, NET-10, ARCH-18
**Problem.** Every client path uses `URLSession.shared` (60 s timeout) — a sleeping NAS stalls
search-as-you-type and connect for a minute. `performJSON` is copy-pasted three times (base/
podcasts/radio) and already diverging. No retry for idempotent reads; HTTP 401/403/429 unmapped;
wire decoding is all-or-nothing (one malformed array element errors the whole screen — classic
Subsonic-variant hazard). Every API call also does a fresh main-actor Keychain read
(`makeClient()` per operation; 31 reads for a 30-album artist).
**Evidence.** `NavidromeClient.swift:47-49,354-405,374-377`; `NavidromeClient+Podcasts.swift:
103-139`; `NavidromeClient+Radio.swift:87-122`; `NavidromeModels.swift:204-232`;
`NavidromeConfig.swift:255-258`; `MusicLibraryStore.swift:90-106`.
**Fix.** One injected `URLSession` with `timeoutIntervalForRequest` ≈ 12 s for JSON (shorter for
ping/verify; longer session for downloads); make transport generic
(`perform<R: Decodable>(_:query:) async throws -> R` over a generic envelope), delete the two
copies; one retry with short backoff for idempotent GETs; map HTTP 401/403 → `.unauthorized`
(proxy-specific copy), 429 → backoff; lossy array decoding wrapper (skip+log bad elements,
tolerant string-or-number `id`). Cache the built `NavidromeClient` keyed by active-server id,
invalidated by `refreshConnection()` (hook already called at every connect/switch site).
**Accept.** A black-holed server fails interactive calls in ~12 s; grep finds one transport
implementation; a response with one corrupt song decodes the rest; one Keychain read per
server-session, not per call.
**Verify.** `NavidromeClientTests` additions: timeout config assertion, corrupt-element fixtures
per collection, 401/429 mapping; client-cache test (credential change invalidates). Manual:
suspend the Navidrome container, use search — error in ~12 s not 60.
**Deps.** none. W-26/W-31/W-33 build on it.

### W-26 — Streaming failure recovery: retry same track, stall watchdog, reconnect
Phase 2 · high · M-L · Sources: AUDIO-06
**Problem.** A Wi-Fi blip or server restart mid-track either (a) fails the item →
`handleLoadFailure` skips to next, which also fails → burns through the ENTIRE queue and parks in
`.error` at an arbitrary position, or (b) stalls forever with a spinner. No reconnect-on-
reachability; `NetworkReachability` only reports metered.
**Evidence.** `StreamingPlaybackController.swift:1222-1239,500-517`; `Audio/NetworkReachability.swift`.
**Fix.** Classify failures (URLError/AVFoundationErrorDomain): network-class → retry the SAME
track with capped backoff using `pendingSeek` to return to the last position; decode-class →
keep today's skip. Stall watchdog: >15 s in `waitingToPlayAtSpecifiedRate` with intent to play →
tear down and reload with `pendingSeek`. Extend `NetworkReachability` to expose `isSatisfied`
and trigger one retry on the offline→online edge. Guard all completions with W-23 generations.
**Accept.** Kill the server mid-track for 30 s → playback resumes the same track near the same
position when it returns; queue position never advances on network-class failures.
**Verify.** Tests with a failing-then-recovering URL provider: `networkFailureRetriesSameTrack`,
`decodeFailureSkips`, `stallWatchdogReloads` (fake clock). Manual: `docker stop navidrome` mid-
track, restart after 20 s.
**Deps.** W-23, W-25.

### W-27 — Crossfade behavior: end-handling, readiness gating, live volume/mute
Phase 2 · high · M · Sources: AUDIO-12, AUDIO-13, AUDIO-14
**Problem.** (1) `startCrossfade` sets `didHandleEnd = true` and nothing fires the final
`onProgressUpdate(song, duration, duration)` for the retiring track → podcasts never marked
played, auto-remove-download never runs (silent disk growth). (2) The incoming item starts
streaming only at the fade window with no buffering gate → on slow links: fade-out, silence,
mid-level pop-in. (3) Mute/volume changes mid-fade address only the outgoing player → post-
promotion mute/UI desync and ramp glitches.
**Evidence.** `StreamingPlaybackController.swift:1565,1256-1259,1562-1586,889-901,1590-1611`;
`MusicModel.swift:96-106`.
**Fix.** Fire the final progress report in `startCrossfade`; exclude podcast episodes from
crossfade entirely (`MusicModel.isPodcastEpisode` — crossfading spoken word is undesirable
anyway; do both). Build the crossfade item early (window+10 s) or from the gapless prefetch
file when available; start the ramp only when the incoming player reports `.playing`. Make
`toggleMute`/`applyVolume` own BOTH players during a fade from one effective-volume source
(`out = eff·(1−t)`, `in = effNext·t`).
**Accept.** Podcast episode ending via (now hard) advance flips to played and reaps its
download; on a throttled link the crossfade waits for readiness (no silent gap); toggling mute
mid-fade mutes both and survives promotion.
**Verify.** Crossfade suite on the tone-file harness (the file's riskiest untested path):
promotion, cancel mid-fade, mute-mid-fade, final-progress-fired assertions. Manual: crossfade a
podcast queue; crossfade over Network Link Conditioner "3G".
**Deps.** W-22 (same code region — land W-22's attach first).

### W-28 — Gapless prefetch hygiene: cancellation, byte cap, off-main IO
Phase 2 · medium · S · Sources: AUDIO-17, AUDIO-18, ARCH-36(6)
**Problem.** Skipping never cancels the previous "next track" prefetch — rapid skipping races
multiple full FLAC downloads against the live stream. Cache is capped by count only (6 FLACs can
be ~500 MB); `store`/evict do synchronous FileManager work on the main actor at track boundaries.
**Evidence.** `StreamingPlaybackController.swift:1366-1405,463-470`; `MusicGaplessCache.swift:19,47-58`.
**Fix.** Cancel non-planned `prefetchTasks` in `preloadGaplessNextIfNeeded`; call
`cancelGaplessPrefetch()` from `stop()`/`loadCurrent`. Add a byte cap (default 200 MB) enforced
in `evictOld`. Move cache file ops off the main actor (actor or background executor).
**Accept.** Ten rapid skips leave ≤1 in-flight prefetch; cache never exceeds the cap.
**Verify.** Extend `MusicGaplessCacheTests` (byte-cap eviction) and prefetch tests
(cancel-on-skip via task-count seam).
**Deps.** none.

### W-29 — Media keys / system Now Playing become transport-aware
Phase 2 · high · M · Sources: AUDIO-05, AUDIO-24, AUDIO-30(volume-mirror)
**Problem.** With radio on air, F8/Control-Center play calls the library `resume()` → the music
track resumes OVER the live stream (double audio); Control Center shows the paused library track
while radio plays; next/prev jump the library queue instead of stations. Separately: a failed
artwork fetch shows the previous track's cover for the whole track and never retries; radio
volume mirroring lives per-UI-surface, so MCP `music.setVolume` during radio desyncs.
**Evidence.** `StreamingPlaybackController.swift:580-593`; `InternetRadioStore.swift` (no
MPNowPlaying/RemoteCommand integration); `MusicNowPlayingCenter.swift:82,91-110`;
`NowPlayingBar.swift:229,261-262,282`.
**Fix.** A small transport arbiter: `configureNowPlaying`'s command closures check
`internetRadio.onAirStation` — play/pause → `engine.resume()/pause()`, next/prev →
`playAdjacent(±1)`; publish station + live ICY title to `MPNowPlayingInfoCenter` while on air.
Artwork: clear `lastArtwork` when starting a fetch for a new URL, set `artworkURL` only on
success (tri-state for retry). Move radio volume mirroring into the store (observe the
controller) — one place, not per surface.
**Accept.** With radio on air: media play key never starts the library player; Control Center
shows the station/ICY title; next/prev hop stations. Artwork never shows the wrong track's art.
**Verify.** Unit-test the arbiter routing (radio-on vs off) via injected closures; test
`MusicNowPlayingCenter` artwork state machine (pure). Manual: start radio, press F8 — no double
audio; check Control Center metadata.
**Deps.** W-30 (radio engine state exposed).

### W-30 — Radio engine: errors, stall recovery, focus release, toast ownership
Phase 2 · high · M · Sources: AUDIO-19, RAD-01, ARCH-08, AUDIO-20, RAD-02, RAD-04, ARCH-34, ARCH-26
**Problem.** A dead/wrong-URL/dropping station is silent forever: no `AVPlayerItem.status`/stall
observation, no error state, no retry — station shows "on air", library stays suspended. Radio
acquires the audio-focus token and discards it (`stop()` never releases; contract violated;
music never auto-resumes — implemented as a leak, not a decision). Errors surface only via
`duckController?.postToast` (the playback engine misused as a message bus — if unwired, errors
vanish). ICY title flickers on empty metadata groups; station logos re-scraped every launch.
**Evidence.** `InternetRadioStore.swift:112-127,163-172,227-264,275-312,364-382`;
`RadioPlaybackEngine.stop()` `:326-334`; `MusicModel.swift:56,81-84`.
**Fix.** Observe item status + `AVPlayerItemFailedToPlayToEndTime`/`playbackStalled`; engine
state `playing/buffering/error(String)`; on error toast + auto-retry with backoff (N attempts)
then `stop()` releasing focus; live-stall → reload item to rejoin the live edge. Store the focus
token; release on stop (owner decision D-05 chooses auto-resume vs stay-paused — encode it in
the release call, don't leak). Extract `ToastCenter` (`@MainActor @Observable`, owned by
`MusicModel`) [Foundation F6] — controller and stores post to it; radio errors go there.
Keep last non-nil ICY title until replaced. Persist resolved station artwork/meta.
**Accept.** A 404 station URL → visible error + UI released within the retry budget; stopping
radio releases the focus token (registry shows no dangling "radio" owner); toasts work with no
duck wiring.
**Verify.** `RadioEngineTests` with a stubbed AVPlayer seam: failure → error state + focus
released; ICY-title hold test. Manual: play a known-dead stream URL; stop a live station and
confirm chosen D-05 behavior.
**Deps.** W-23 (generation guard), D-05 decision.

### W-31 — Scrobble correctness completion (timestamps, sessions, enqueue policy)
Phase 2 · high · M · Sources: SCR-03, SCR-04, SCR-06, SCR-08, SCR-09, SCR-07, NET-12, SCR-11
**Problem.** (1) Navidrome scrobbles omit the `time` param → every queued flush credits plays at
flush time (wrong history, broken server-side dedupe). (2) Last.fm permanent errors (9 invalid
session, 4 auth) retried 20× then dropped while Settings shows "Connected" — months of silent
loss. (3) Disconnecting a destination strands its queued items forever (counts against the
500 cap, can push out live scrobbles). (4) Plays during a transiently-unconfigured moment
(Keychain locked at login → `isActive` false) are never enqueued at all. (5) Encoding nits:
raw-value fallback, unencoded auth URL. (6) At-least-once window (crash between submit and
resolve) undocumented.
**Evidence.** `NavidromeClient.swift:287-292`; `MusicLastFM.swift:31,51,119,129-140`;
`ScrobbleService.swift:149-181`; `Scrobble.swift:77-125`; `NavidromeKeychain.swift:104-124`.
**Fix.** Add `time:` to `NavidromeClient.scrobble` (pass `startedAt*1000`). Typed permanent-vs-
transient in `ScrobbleError` (builds on W-08): Last.fm 9/4 → clear session, set a visible
"reconnect Last.fm" state, stop retrying; mirror for LB HTTP 401. Purge/park a destination's
queue on disconnect. Enqueue server scrobbles unconditionally; drain checks activeness.
Distinguish `errSecItemNotFound` from transient Keychain errors in `secret(account:)` (retry
once / `.unavailable` state — also fixes the spurious connect-screen drop). `URLComponents` for
Last.fm encoding, no fallback. Document at-least-once semantics (SCR-07 accepted; `time` makes
Navidrome duplicates diagnosable).
**Accept.** Offline-queued scrobble lands with original timestamp on the server; a revoked
Last.fm session surfaces in Settings within one flush and stops retrying; disconnect leaves no
zombie queue rows; a play during a Keychain-locked moment is delivered later.
**Verify.** Extend `ScrobbleTests`/`MusicLastFMTests`: wire-snapshot the Navidrome call includes
`time`; error-9 handling; disconnect-purges; enqueue-while-unconfigured. Snapshot-test the LB
JSON payloads (currently untested — SCR-11).
**Deps.** W-08.

### W-32 — Play history: append-friendly storage off UserDefaults
Phase 2 · high · M · Sources: SCR-10, ARCH-21
**Problem.** Every completed listen re-encodes the ENTIRE archive (each entry embeds a full
`NavidromeSong`) into UserDefaults on the main actor — multi-MB per play at 10k entries, tens of
MB at the 200k ceiling; cfprefsd rewrites the whole plist; launch loads it wholesale. Stats
(`recentlyPlayed`, `topTracks`, `playCount`) full-scan per SwiftUI render.
**Evidence.** `MusicPlayHistory.swift:33-37,57-65,86-89,125,168-186,216-220`.
**Fix.** Move the archive to append-only JSONL in Application Support (the export format is
already JSONL-compatible via `ListenArchiveIO`), written off-main, with periodic compaction and
the W-12 versioned envelope for the header/sidecar; migrate the existing defaults blob on first
run; memoize derived stats keyed by a mutation counter. Keep UserDefaults for the enabled flag.
**Accept.** Recording a listen is O(1) (append) and off the main actor; a 100k-entry archive
launches without a measurable stall; existing history migrates losslessly.
**Verify.** `MusicPlayHistoryTests`: migration fixture (current-format blob → JSONL), append+
compaction round-trip, stats memoization; perf test with a generated 100k-entry archive (pairs
with TEST-10 fixtures).
**Deps.** W-12.

### W-33 — Downloads UX: visible failures, progress, cancellation, resume, storage management
Phase 2 · high · M-L · Sources: DL-02, DL-03, DL-07, DL-08, DL-09
**Problem.** Failures are only logged — spinner vanishes, user never learns 3 of 40 tracks
failed; no per-item/aggregate progress; batch downloads can't be cancelled (sequential loop, Task
handles discarded); no resume (a blip at 95% of a long episode restarts from zero); no storage
cap/eviction (dir also misleadingly named `music-cache`); Downloads screen stats do per-file
main-actor IO; collection-completeness badges go stale when server playlists change.
**Evidence.** `MusicDownloadStore.swift:104-120,130-135,240-279,303-334,395-417`;
`ClientPodcastsView.swift:513,558,579`; `MusicArtistsBrowser.swift:87-88`.
**Fix.** Per-download state enum (queued/progress(bytes)/failed(error)/done) published for UI;
failures via ToastCenter (F6) + a failed-set the Downloads view shows with retry; keep the batch
Task handle, check `Task.isCancelled` between items, expose Cancel; delegate-based download with
resume data persisted next to the manifest; optional size cap + LRU eviction using play-history
last-played; cache byte sizes in `meta` (no per-render stat); refresh collection registry when a
detail view loads fresh track lists; move init rescan off-main with a ready state.
**Accept.** A failing batch shows which items failed and offers retry; Cancel stops within one
item; kill-and-relaunch mid-episode resumes from partial data; totals render without touching
disk per view update.
**Verify.** Stubbed-session tests (seam from W-05): failure surfaces state; cancellation stops
the loop; resume-data round-trip. Manual: throttle the LAN, download an album, cancel halfway;
kill app mid-podcast-download and relaunch.
**Deps.** W-05 (validation + session seam), W-30 (ToastCenter).

### W-34 — Offline downloads: original quality, honest extensions
Phase 2 · high · M · Sources: DL-04
**Problem.** Downloads reuse `stream.view?format=mp3` — a FLAC library is silently stored
offline as lossy MP3 (in a player whose brand is playback depth; ReplayGain tags may not survive
the transcode). Podcast enclosures (`.m4a`) are saved with a lying `.mp3` extension in the
human-readable folder.
**Evidence.** `NavidromeClient.swift:112-117`; `MusicDownloadStore.swift:198`;
`StreamingPlaybackController.swift:428-437`.
**Fix.** Use Subsonic `download.view` (original file) for library downloads with fallback to
`stream` on server error; derive the extension from the response `Content-Type` (mapping table +
fallback sniff); keep transcoded gapless prefetch as-is (ephemeral). Decision D-07 records
whether a "download transcoded to save space" option ships later.
**Accept.** Downloading a FLAC track yields a byte-identical `.flac`; podcast episodes get their
real extension; existing `.mp3` downloads keep playing.
**Verify.** Stubbed tests: `download.view` URL construction, Content-Type→extension table,
fallback-to-stream on 501. Manual: download one FLAC, compare sha256 with the server file.
**Deps.** W-05, W-33 (same code region).

### W-35 — Podcast feed parsing robustness + fetch hardening
Phase 2 · medium · S-M · Sources: POD-02, POD-03, POD-04(title), POD-06, SEC-13, SEC-10
**Problem.** Date parsing misses common variants (obsolete zone names, ISO in `pubDate`) →
episodes sort to the bottom, shows misplace in recency order. SAX buffer resets on nested child
elements (non-CDATA markup truncates descriptions). `<image><title>` can overwrite the channel
title. Server-side episode ordering compares raw date strings. Feed fetch has no size cap and
XXE-off is implicit; feed-controlled image URLs can probe internal hosts (blind SSRF).
**Evidence.** `PodcastFeed.swift:71-78,89,140-162,190-197,221-231`;
`NavidromeClient+Podcasts.swift:185-190`; `PodcastSubscriptionStore.swift:33-41`;
`ArtworkPalette.swift:140`.
**Fix.** Add `zzz`-zone + ISO-8601 date fallbacks (log unparsed); per-depth buffer accumulation
(element stack); guard channel title with `!inChannelImage`; parse server episode dates to
`Date` before sorting; explicit `shouldResolveExternalEntities = false` + feed body size cap
(~10 MB) before parse; skip image URLs resolving to loopback/link-local (log only).
**Accept.** A corpus of real-world feed fixtures (incl. EST/PDT dates, embedded markup, image-
first channels) parses with correct titles/dates/order; a 100 MB body is refused.
**Verify.** `PodcastFeedTests` corpus expansion (fixture-driven, one file per variant);
date-parser table test.
**Deps.** none.

### W-36 — Podcast identity, progress durability, and refresh policy
Phase 2 · medium · M · Sources: POD-01, POD-05, POD-04(feed-move), POD-07, POD-08, POD-10, ARCH-36(5)
**Problem.** Progress/played is keyed by enclosure URL — CDN/token rotation orphans progress and
grows the dict forever, though the parser already has the stable `<guid>`. Progress `persist()`
is unordered fire-and-forget (older snapshot can win → resume jumps backward). Feeds refresh
once per session with no conditional GET; `loadIfNeeded` marks loaded before the disk read
succeeds (failed read never retries). Feed moves (`itunes:new-feed-url`/301) never migrate the
subscription. Refresh replaces episode lists wholesale (feed-window churn drops downloaded/
in-progress episodes). Capability verdict `.unsupported` persists forever.
**Evidence.** `PodcastProgressStore.swift:26,56-72,134-138`; `PodcastSubscriptionStore.swift:
52-60,104-135,165-183`; `MusicPodcastCapability.swift:56-63,123-131`.
**Fix.** Key progress by guid with URL→guid lookup at playback; prune rows unmatched by current
episodes on refresh; serialize persistence (debounced latest-wins writer on a serial queue) on
top of the W-12 envelope. Staleness-triggered refresh (>N hours on tab appearance or timer) with
`ETag`/`If-Modified-Since` in the injectable fetch. Migrate subscription+progress on
`itunes:new-feed-url`/301. Merge episode lists (union by id; retain episodes with downloads/
progress, cap the tail). Expire the capability verdict (re-probe after 7 days or app update).
Fix `loadIfNeeded` to set `loaded` only on success.
**Accept.** Rotating an enclosure URL in a fixture feed preserves progress; two racing persists
leave the newest snapshot; a refreshed feed that dropped an in-progress episode keeps it visible.
**Verify.** `PodcastProgressStoreTests`/`PodcastSubscriptionStoreTests`: guid migration, ordered
writes (interleaved persist), merge-not-replace, 304 handling via stub fetch.
**Deps.** W-12.

### W-37 — Artwork URL/image caching (stop the per-call salt)
Phase 2 · high · S-M · Sources: NET-06, NET-05
**Problem.** `baseQueryItems` mints a fresh random salt per call → every `coverArtURL(id:)` is a
unique URL → AsyncImage/URLCache never hit; constant artwork refetch against the user's own
server, scroll jank, zero cross-launch caching (hand-rolled memoization in `MusicDetailViews`
documents the bug). Signed URLs also persist auth material into URLCache on disk.
**Evidence.** `NavidromeClient.swift:73-89,120-124`; `MusicHomeView.swift:177`;
`MusicLikedView.swift:933`; `MusicArtistsBrowser.swift:377-378`; `MusicDetailViews.swift:32,322-323`.
**Fix.** Step 1 (3 lines): cache one salt+token pair per client instance (spec allows reuse;
regenerating per client build is enough) — immediately restores URLCache hits. Step 2 (with
W-25's client cache): an app-level artwork cache keyed by `(serverID, coverArtID, size)` storing
decoded images on disk, which also removes auth-bearing URLs from URLCache (NET-05).
**Accept.** Two `coverArtURL` calls for the same art return identical URLs; scrolling the album
grid a second time issues zero art requests (observe server access log).
**Verify.** Unit test URL stability; manual: tail Navidrome access log while scrolling twice.
**Deps.** W-25 (step 2 only).

### W-38 — MCP bind correctness: don't advertise a port we don't own
Phase 2 · high · M · Sources: ARCH-07, MCP-02
**Problem.** `bind(port:)` returns true when `NWListener.start` is *called*; port-in-use arrives
async via `.failed`. The port-scan loop always "succeeds" on 8787, `isRunning = true`, and
`mcp.json` advertises a port another process may own — agents talk to a foreign server.
**Evidence.** `BatonMCPServer.swift:95-120,65-81` (comment at `:116-119` admits it).
**Fix.** Make bind async: await `.ready`/`.failed` with a short timeout; on failure cancel and
advance to the next port; set `isRunning` and write discovery only after `.ready`. Consumers
validate the discovery `pid` (with W-14's liveness check).
**Accept.** With 8787 pre-bound by another process, Baton serves on 8788 and mcp.json says 8788.
**Verify.** W-46-harness test: occupy 8787 with a dummy listener, start server, assert port
walk + discovery contents. Manual: run two Baton dev instances.
**Deps.** W-46 harness (test), W-14 (discovery hygiene).

### W-39 — MCP session & stream lifecycle (server-minted sessions, SSE health)
Phase 2 · high · M · Sources: MCP-03, MCP-04, MCP-05, MCP-07, MCP-09, MCP-10, SEC-15, FOCUS-01, FOCUS-02, FOCUS-03
**Problem.** The server never issues `Mcp-Session-Id` (spec: server assigns at initialize), so
session-scoped focus-handle expiry is dead code for real MCP clients — a crashed dictation
client leaves Baton paused/ducked up to 10 min; the client-supplied id is also forgeable
(SEC-15). SSE streams never `receive()` after opening (disconnects unnoticed; broadcasts buffer
into dead sockets), no backpressure, no heartbeat. Incomplete requests are held forever (no read
deadline); chunked encoding silently mis-handled (501 landed in W-02). DELETE is a no-op; GET
ignores the Accept header. Focus registry entries are never deleted (unbounded growth), and the
owner+generation resume fallback lets any client release another's focus.
**Evidence.** `BatonMCPServer.swift:130-153,170-177,220-231,273-316`; `BatonMCPTools.swift:
832-857`; `BatonAudioFocus.swift:33,89-144,167-180`.
**Fix.** Mint a session id in the initialize response; associate POSTs and the GET stream by it;
DELETE cancels the session's streams + `expireHandles(forConnection:)`. Keep a receive pending
per stream; on EOF/error run `handleStreamClosed`; track send completions, drop streams with N
outstanding sends; emit `: keep-alive` every ~20 s. Per-connection read deadline. Gate
`openStream` on `acceptsEventStream` (405/406 otherwise). Prune resolved focus entries after a
grace period; restrict owner+generation resume to the fast-path socket.
**Accept.** Killing an SSE client expires its suspend handles within seconds (not 10 min);
dead streams are reaped; a plain GET without the SSE Accept header gets 405.
**Verify.** W-46 harness tests: initialize returns session id; kill-client → focus expiry;
heartbeat cadence; DELETE semantics; Accept gating; read-deadline. 
**Deps.** W-46.

### W-40 — MCP off the main thread; bounded responses; honest change signatures
Phase 2 · medium · M · Sources: ARCH-17, MCP-06, TOOL-03, ARCH-11
**Problem.** Listener, byte accumulation, HTTP parse, and JSON (de)serialization all run on the
main queue — a rapid agent or one `music_get_queue` on a 5k-track queue janks the UI and delays
the audio-focus fast path; the 500 ms signature poll wakes the main actor forever even with zero
SSE clients. Queue tool/resource are unbounded (multi-MB JSON). `queueSignature`
(count|first|last) misses middle-of-queue changes → stale agent UIs.
**Evidence.** `BatonMCPServer.swift:114,125,327-341,370-373`; `BatonMCPTools.swift:677-691`;
`BatonMCPResources.swift:100-110`.
**Fix.** Run listener/connections on a utility queue; parse + serialize off-main; hop to the
main actor only for tool dispatch. Gate the poll on `!streams.isEmpty` (slower expiry timer
otherwise). Paginate queue reads (window around `current_index`, length + truncation marker);
trim the reorder response. Hash the ordered id list for `queueSignature`.
**Accept.** A 10k-track `music_get_queue` returns a bounded window without a main-thread stall;
a middle-of-queue reorder emits `resources/updated`.
**Verify.** Harness tests: signature-transition unit tests (also TEST-15), pagination shape;
main-thread hang detector during a burst of 100 tool calls.
**Deps.** W-46.

### W-41 — MCP tool quality: validation, idempotency, store-coherent writes
Phase 2 · medium · M · Sources: TOOL-02, TOOL-04, TOOL-05, TOOL-06, TOOL-07, MCP-08, ARCH-09, ARCH-12, NET-04, ARCH-29(resolver+labels)
**Problem.** Advertised schemas are never enforced (missing `owner` collapses to "unknown" —
two clients steal each other's focus); like/rate write straight to the server bypassing
`MusicLibraryStore.ratingOverrides` → the UI heart stays stale after an agent likes a track;
retried create/add playlist calls duplicate; `createPlaylist` fallback fabricates an empty-id
playlist handed to agents; unknown tool returns a tool-result error instead of JSON-RPC -32602;
preset match case-sensitive; `music_like` on a podcast/radio now-playing id sends bogus server
calls; annotation hints inaccurate; the playlist resolver + state-label logic is duplicated.
**Evidence.** `BatonMCPTools.swift:256-285,330-331,368-376,406-458,522-535,553-600,802-822,
832,863-868`; `MusicLibraryStore.swift:88,323-346`; `NavidromeClient.swift:298-305`.
**Fix.** Minimal schema check at `run()` entry (required fields, trimmed strings); route
like/rate through `MusicLibraryStore.toggleLike/setRating` (optimistic UI for free); create →
error on existing exact name, add → skip already-present ids; on missing create echo re-fetch
`getPlaylists` and match by name (never empty id); unknown tool → -32602; case-insensitive
preset lookup; guard like/rate when nowPlaying isn't a library id (typed-kind from W-52 makes
this clean — interim: `hasPrefix("http")` guard); fix hints (open-world only for network tools,
human titles, idempotent hints); extract the shared playlist resolver + state-label helper.
**Accept.** Agent `music_like` updates the UI heart immediately; retried playlist ops are
idempotent; schema-invalid args return a structured error naming the field.
**Verify.** Per-tool tests (mirrors GapToolsTests — this IS part of TEST-02's coverage): happy +
≥1 bad-arg each; a schema-snapshot test locking `BatonMCPToolCatalog.definitions()`.
**Deps.** W-46 (test shape), W-52 (clean kind check — optional).

### W-42 — Mix builder: use the parsed signals, honest determinism
Phase 2 · medium · M · Sources: MIX-01, MIX-02, MIX-03
**Problem.** `parsePrompt` extracts keywords that `applySeed` never uses — "upbeat focus mix"
degenerates to a literal search plus the entire starred list in server order; the agent gets no
signal the mood was ignored. Selection is deterministic and front-loaded (comment promises a
shuffle that doesn't exist); every build fetches the full starred set with coarse
partial-failure semantics.
**Evidence.** `BatonMCPMixTools.swift:123-157,208-210,249-255,293-330,335-342`.
**Fix.** Apply keywords (per-keyword searches / genre matching) or honestly report which signals
applied in the tool response (do both: apply what's implementable, report the rest); seedable
shuffle before greedy fill; starred as thin-pool fallback only, reuse the loaded store's
`starred`, per-source error tolerance.
**Accept.** Two identical prompt calls return different (seeded-random) mixes; the response
lists applied vs ignored signals; keyword-only prompts return keyword-relevant pools.
**Verify.** `MixBuilderTests` extensions: keyword application on a fixture library, seeded
shuffle determinism-under-seed, per-source failure tolerance.
**Deps.** none.

### W-43 — Speech product correctness: duck the music, queue utterances, honest notify
Phase 2 · high · M · Sources: SPEECH-01, SPEECH-02, SPEECH-03
**Problem.** The premier demo is broken: `speak_summary` plays over full-volume music — the
audio-focus system built exactly for this is never called by Baton's own speech engine.
Concurrent summaries cut each other off (`.file` and `.native` can even play simultaneously;
banners overwrite silently). `mode:"notify"` (the default) reports success even when
notifications are denied/undelivered.
**Evidence.** `SpeechPlaybackEngine.swift:40-92,95-97`; `SpeechNotifier.swift:30-53`;
`BatonMCPSpeakTools.swift:77-87`.
**Fix.** In `SpeechPlaybackEngine.play`: `acquireAudioFocusDuck(owner:"baton.speech",
toPercent:~20)` (or pause per setting); release on finish/stop/error. FIFO utterance queue; each
play path stops the other engine; pending-banner list. Check notification `authorizationStatus`;
on denied fall back to banner and report `status:"banner_shown", fallback:"notifications-denied"`.
**Accept.** speak during playback ducks music and restores it after; two rapid speaks play
sequentially; denied notifications produce a banner + honest tool status.
**Verify.** Engine tests with a fake focus registry (acquire/release pairing, FIFO order);
notifier test with stubbed auth status. Manual: play music, trigger `speak_summary` from an
agent — speech is audible over ducked music.
**Deps.** W-19 (same files; land W-19 first).

### W-44 — Loudness normalization: real headroom
Phase 2 · medium · S · Sources: AUDIO-23
**Problem.** `AVPlayer.volume` can't exceed 1.0, so the +gain half of ReplayGain silently does
nothing at common volumes: quiet tracks stay quiet — track-to-track loudness is NOT equalized,
the feature's whole promise (math itself is correct and tested).
**Evidence.** `StreamingPlaybackController.swift:897-901,935-948`.
**Fix.** Apply a constant pre-amp headroom (≈ −6…−12 dB, configurable) so all adjustments become
attenuations; document in the Loudness settings UI. (DSP-stage gain riding the EQ tap is the
long-term option — note in code, don't build now.)
**Accept.** With normalization on at 100% volume, a −8 dB and a +4 dB RG track play at matched
loudness (both attenuated relative to raw).
**Verify.** Unit test the effective-volume math incl. headroom; manual A/B with two known tracks.
**Deps.** none.

### W-45 — Output-volume duck: don't fight the user; stable device identity
Phase 2 · low · S · Sources: AUDIO-21, AUDIO-22
**Problem.** The post-duck restore watchdog reverts a user's deliberate volume-down for ~6 s
(each press undone within 250 ms). Crash recovery keys on an ephemeral `AudioDeviceID` — after a
reboot the ID can name a different device and recovery sets the wrong output's volume.
**Evidence.** `OutputVolumeController.swift:58-80,213-231`.
**Fix.** Stop re-asserting when two consecutive reads are stable at a lower value (user intent);
persist the device UID (`kAudioDevicePropertyDeviceUID`) alongside the ID and skip recovery on
mismatch.
**Accept.** Lowering volume right after a duck-restore sticks on the second read; recovery
no-ops when the UID doesn't match.
**Verify.** Extend `OutputVolumeRestoreTests` with the stable-lower-value sequence and a
UID-mismatch case.
**Deps.** none.

### W-46 — MCP transport test harness + contract & E2E suite [Foundation F5]
Phase 2/3 boundary · high · M-L · Sources: TEST-01, TEST-02, TEST-03, TEST-15, MCP-TEST-01, TEST-14
**Problem.** The defining surface has zero tests: hand-rolled HTTP over NWConnection (buffer
accumulation, parse, auth, routing, SSE fan-out, session-close→focus expiry, discovery file),
all 18 original `music_*` tools (888 LOC — the external contract), the notification signature
functions, and the control socket's adversarial inputs. Any refactor (W-38…W-41) on this code
untested is the riskiest work in the plan.
**Evidence.** `BatonMCPServer.swift` (422 LOC), `BatonMCPProtocol.swift` (227),
`BatonMCPTools.swift` (888) — no test references; `GapToolsTests.swift:46` asserts only a count.
**Fix.** Three layers: (1) unit — `HTTPRequestMessage.parse` fed byte-wise fragments, oversized,
malformed, missing/wrong tokens, `constantTimeEquals` (W-02's tables live here);
(2) integration — boot `BatonMCPServer` on an ephemeral loopback port with a stubbed MusicModel,
drive with URLSession: initialize→tools/list→tools/call→resources/read; assert
401/404/405/202/parse-error paths; SSE: mutate → `notifications/resources/updated` arrives;
close → focus handles expire; (3) `MCPEndToEndTests` — discovery file → connect → session → tool
call → SSE → disconnect-expiry: **this suite is the release gate** for the agent feature.
Signature-transition unit tests (`nowPlayingSignature`/`queueSignature`). Control-socket
adversarial tests land in W-15.
**Accept.** The harness boots a real server in-process in <1 s per test; every route and error
path asserted; per-tool happy+bad-arg coverage for all 18 original tools (W-41 fills the tool
half); suite runs in `scripts/test.sh`.
**Verify.** The suite itself; mutation check: re-introduce the ARCH-03 `kv[0]` bug locally and
confirm the parser table catches it.
**Deps.** W-01. Blocks (ordering, not hard deps): W-38, W-39, W-40, W-41.

---

### W-47 — Playback characterization suite (pre-decomposition safety net)
Phase 3 · high · M-L · Sources: TEST-07, AUDIO-27, ARCH-37
**Problem.** The riskiest interactions in `StreamingPlaybackController` are untested: gapless
prefetch adopt/swap races ("a late prefetch, a mid-track skip, or a queue mutation during
prefetch" — the repo's own docs name this risk), crossfade (zero tests for a path that swaps the
player object and rewires every observer), `handleLoadFailure` auto-skip, `extendQueueIfNeeded`,
seek semantics, loudness reaching `player.volume`, buffering/error states. Existing tests are
synchronous-only. W-50's decomposition cannot proceed safely without this.
**Evidence.** `StreamingPlaybackControllerTests.swift:5-8,21-27` (sync, file:///dev/null);
untested internals ~`:1051-1117`; `docs/06-improvements-existing.md` §1; `docs/08` (admits the
suite was never written).
**Fix.** Characterization suite using the injectable `streamURLProvider`, prefetch hook, a
deterministic scheduler/fake clock, and `gaplessLocalSwapCountForTesting`: prefetch adopt/swap
under mid-track skip; crossfade activation/promotion/cancel (extends W-27's tests);
load-failure auto-skip + consecutive-failure guard; seek during `.loading`; `moveQueueItem`
index-follow; loudness → volume. Where W-24/W-26/W-27 already added targeted tests, fold rather
than duplicate.
**Accept.** Every public transport operation has at least one async-path test; the known-racy
prefetch scenarios from docs/06 §1 are encoded as tests (passing or documented-failing with a
linked W-item).
**Verify.** The suite; coverage sanity: `xcodebuild test -enableCodeCoverage` shows the
controller's async regions exercised.
**Deps.** W-23, W-24, W-26, W-27 (their fixes+tests feed in). Blocks W-50.

### W-48 — XCUITest smoke + accessibility audit runner
Phase 3 · high · M · Sources: TEST-08
**Problem.** No UI tests at all — not even a launch smoke test, despite HANDOFF.md recording an
unverified "No Observable object of type MusicModel" window-open crash risk. Four Window scenes +
MenuBarExtra ship unexercised.
**Evidence.** No XCUITest target; `HANDOFF.md:23`; `BatonApp.swift:36-134`.
**Fix.** Minimal XCUITest target: launch + main window appears; open Settings/About/Help/Mini
Player; seeded-mock connect → library grid renders. Add
`app.performAccessibilityAudit()` to each screen visit (enforcement bar set by W-56). Run in
`scripts/test.sh` (allow `SKIP_UI=1` for quick iterations).
**Accept.** A window-open crash or missing environment object fails the local gate.
**Verify.** The suite; deliberately break the environment injection on a branch and confirm the
smoke test catches it.
**Deps.** W-01.

### W-49 — Test hygiene sweep (seams, snapshots, fixtures, isolation)
Phase 3 · medium · M · Sources: TEST-04, TEST-05, TEST-06, TEST-09, TEST-10, TEST-12, TEST-13, AUDIO-25, PER-04, ARCH-32, DL-10, TEST-16
**Problem.** Grab-bag of test-infrastructure debt: `SpeechService` hardcodes `URLSession.shared`
(blocks stubbing — TEST-04); UpdateChannel/CrashReporting helpers untested beyond W-09/W-10's
additions; "snapshot" tests only assert png.count>1500 with stale `tonebox-` names in /tmp;
store failure-paths (isLoading/lastError) untested; no large-library fixtures (pairs PROD-02);
sweep list: MusicNowPlayingCenter, WaveformExtractor, FilterHistory, ListenBrainz wire shape,
NavidromeKeychain error mapping; NWPath reconnect→flush and partial-flush resolve untested;
`MusicEqualizer` persists to `.standard` under XCTest (running tests overwrites the developer's
real EQ settings); `BatonRuntime.isTest` sniffing baked into production defaults instead of one
composition root.
**Evidence.** `SpeechService.swift:50,84`; `MusicUISnapshotTests.swift:7,36`;
`MusicEqualizer.swift:24,86-99`; `BatonRuntime.swift:7-10`; `ScrobbleDestination.swift:45,50`;
`MusicLibraryStore.swift:450-466`.
**Fix.** Inject URLSession into SpeechService; adopt pointfree swift-snapshot-testing with
committed references (keep renders as crash-smoke; rename baton-*; bundle temp dir); store
failure-path tests; generated 10k-album/100k-song fixtures with measure budgets; the unit sweep
(S each); give `MusicEqualizer` the injected-defaults treatment; introduce
`MusicModel.init(environment:)` as the single composition root and delete per-store
`isTest` sniffs (tests build `MusicModel(.testing)`).
**Accept.** Test suite touches no real user defaults/keychain/network (assert via isolated-suite
audit); snapshots diff against committed references; fixtures exist and are used by W-54's tests.
**Verify.** Run the suite, then diff the developer's real Baton defaults before/after — byte-
identical. TEST-16's four-layer strategy documented in `docs/testing.md`.
**Deps.** W-01; coordinates with W-19 (speech seam), W-51 (composition root placement).

### W-50 — Decompose StreamingPlaybackController (1,684-line god-object)
Phase 3 · high · L · Sources: ARCH-23
**Problem.** One class owns transport+queue, persistence, gapless, crossfade, sleep/fades,
loudness, audio focus, Now Playing, scrobble wiring, toasts, autoplay — six interleaved state
machines whose cross-products (gapless × crossfade × shuffle × autoplay × focus) are where this
review's section-A bugs lived. Ten injected closures form an unenforced protocol with
`MusicModel.wire()` — nothing guarantees they're wired before first use.
**Evidence.** `Audio/StreamingPlaybackController.swift` (whole file); `Model/MusicModel.swift`
`wire()`.
**Fix.** Staged extraction keeping the public surface, one stage per PR, suite green between:
(1) `QueueModel` — ordering/shuffle-with-merge, pure + testable (W-24's fixes move in);
(2) `TransitionEngine` — gapless preload/prefetch + crossfade behind one prepare-next/advance
interface (W-22/W-27/W-28 logic moves in); (3) audio-focus into its own type (registry half
already exists in `BatonAudioFocusRegistry`; this is where W-15's lock-protected registry
lands, delivering the sub-frame duck without `main.sync`); (4) replace the closure bundle with
a delegate-style protocol so wiring completeness is compiler-checked.
**Accept.** Controller under ~600 lines; each extracted type has its own test file; wiring is a
protocol conformance (a missing method is a compile error); W-47 suite green throughout.
**Verify.** W-47 characterization suite is the regression net; diff review per stage.
**Deps.** W-47 (hard), W-20–W-28 (their fixes should land pre-move so extraction is mechanical).

### W-51 — Module boundaries, composition, and project hygiene
Phase 3 · medium · M-L · Sources: ARCH-24, ARCH-25, ARCH-30, MCP-13, ARCH-31, NET-11, ARCH-35, ARCH-29(remaining)
**Problem.** `Shell/Music/` (40 files) mixes views, domain stores, and IO; `Model/` holds 4
files — directory structure is the only boundary a single-target app has. `MusicDownloadStore.
shared` singleton is woven through ~20 view files + the engine (blocks per-server downloads,
test isolation). MCP server lifecycle is owned by a window's `.task` (menu-bar-only mode would
silently kill the flagship feature). `NavidromeConfig` is `nonisolated(unsafe)` global statics
with unsynchronized read-modify-write of the server list (latent race as MCP/background callers
grow); the codebase's only force-unwraps live there. `SWIFT_TREAT_WARNINGS_AS_ERRORS: NO` with a
stale "re-enable after Wave 1" comment; the real Sentry DSN sits gitignored inside the repo dir.
Duplicated helpers (duration refinement ×3, crash-recovery persist idiom ×2, MCP search
preamble ×6, browse-tab scaffolding ×4) will drift.
**Evidence.** `Shell/Music/` inventory; `MusicDownloadStore.swift:18`; `BatonApp.swift:46-67`;
`NavidromeConfig.swift:56,68-70,75-168`; `NavidromeKeychain.swift:38`; `app/project.yml:44-46`;
`BatonControlSocket.swift:56`; ARCH-29 site list.
**Fix.** Move stores/services into `Model/`+`Services/` (rule: Shell imports Model, never
vice versa; enforce by review + a grep-lint). Hang downloads off `MusicModel`
(`model.downloads`, environment-passed; transitional `shared` initialized by MusicModel, burned
down view-by-view). Move MCP/socket/notification startup to an app-level owner
(`@NSApplicationDelegateAdaptor` or `BatonRuntime`), window-independent. Annotate
`NavidromeConfig` `@MainActor`, drop `nonisolated(unsafe)`, remove the force-unwraps
(`UUID(uuid:)`). Flip warnings-as-errors and fix fallout. Move the real DSN outside the repo via
the xcconfig include path. Extract the duplicated helpers when touched (playlist resolver done
in W-41; duration refinement + crash-recovery idiom here); defer `BrowseTabModel` until the next
tab is added. SPM-target split deferred (§4).
**Accept.** `Shell/` contains only SwiftUI; zero `.shared` download references in views; MCP
starts with no window; build clean with warnings-as-errors; grep finds no
`nonisolated(unsafe)` in NavidromeConfig.
**Verify.** Build + full suite; W-48 smoke confirms startup; launch with window restoration
suppressed → MCP still serves (curl the port).
**Deps.** W-49 (composition root), W-14 (server lifecycle interplay).

### W-52 — Typed media kind on `NavidromeSong`
Phase 3 · medium · M · Sources: ARCH-27
**Problem.** `id` doubles as Subsonic id / enclosure URL / synthetic import id, and behavior
branches on `hasPrefix("http")` in ≥4 subsystems (stream resolution, cover art, scrobble
exclusion, downloads keying). Enclosure URLs aren't stable identities; every new consumer must
remember the convention; a third media kind breaks it silently.
**Evidence.** `MusicModel.swift:63-68`; `StreamingPlaybackController.swift:432-448`;
`ScrobbleService.swift:192-194`; `ClientPodcastsView`/`MusicDownloadStore` keying.
**Fix.** Add `kind: MediaKind` (library/podcastEpisode/radio/imported) to `NavidromeSong` with a
Codable decode-fallback applying today's heuristic once (counts as a W-12 schema migration for
the persisted queue/history). Route every "is podcast?" check through it; delete the prefix
tests.
**Accept.** Grep: zero `hasPrefix("http")` media-kind branches; old persisted queues/history
decode with correct kinds.
**Verify.** Migration test decoding a current-format queue snapshot; behavior tests per consumer
(scrobble exclusion, stream resolution).
**Deps.** W-12. Simplifies W-41's like/rate guard and W-36's identity work.

---

### W-53 — Implement Offline Mode for real
Phase 4 · high · M · Sources: PROD-01
**Problem.** Two UIs persist `baton.music.offlineMode` and FAQ sells "a global Offline mode" —
but the key is READ NOWHERE. A user on a metered link enables it and Baton streams anyway.
**Evidence.** `MusicDownloadsView.swift:11,102`; `BatonSettingsView.swift:375-376,428,518`;
`FAQ.md:149`; grep: no other read.
**Fix.** When offline: `resolveStreamURL` returns only local files (no stream fallback);
un-downloaded content badged/dimmed in browse; queue additions of un-downloaded tracks
warned/blocked; podcast/radio streaming suppressed with an explanatory state; scrobbles queue as
normal (W-08 handles delivery).
**Accept.** Offline on + un-downloaded album → clear "not available offline" state, zero
network stream requests; downloaded content plays.
**Verify.** Test: stream-URL provider never invoked in offline mode for a non-downloaded id;
manual: enable offline, pull the network, browse and play.
**Deps.** W-33 (download states), W-05.

### W-54 — Large-library pagination (albums, search, genres)
Phase 4 · high · M · Sources: PROD-02, NET-07
**Problem.** Albums fetch is a single `getAlbumList2 size:500` — >500-album libraries show an
arbitrary subset that CHANGES with sort type, and the nav badge shows a wrong total (perceived
data loss). `search3` exposes no offsets; genre songs cap at 60 silently.
**Evidence.** `MusicLibraryStore.swift:190`; `MusicView.swift:355`; `NavidromeClient.swift:
142-155,250-256`.
**Fix.** Client: add `songOffset`/`albumOffset`/`artistOffset` + genre offset params. Store/UI:
scroll-triggered paging (append pages) for Albums + search + genre lists; honest totals
("500+ albums") until full count known.
**Accept.** A 2,000-album fixture library browses completely under every sort; badge counts
truthful.
**Verify.** Client param unit tests; store paging test against the W-49 10k fixture; manual
against a large Navidrome library if available.
**Deps.** W-49 (fixtures), W-25.

### W-55 — Load/empty/error design system across the browse surfaces
Phase 4 · medium · M · Sources: PROD-06, PROD-07, ARCH-28(read-half), ARCH-36(4)
**Problem.** One sticky global `lastError` string shows above EVERY tab until the next success
(a failed rating on Podcasts banners all tabs, no retry); loading vs empty indistinguishable
(slow server → Albums looks like an empty library, right after first connect); helpers that
`try?`-return `[]` render server failures as empty albums/mixes; 16 files roll their own
ProgressViews; `isArtistFollowed` reads a possibly-never-loaded `starred` list.
**Evidence.** `MusicLibraryStore.swift:81-83,213-224,293-319,462-466`; `MusicView.swift:378-382,
407-468`; `MusicLibraryStore.swift:266-270`.
**Fix.** A `LoadState<T>` (idle/loading/loaded/empty/failed(Error)) per collection + one shared
component (`ContentUnavailableView`-based) with Retry; make the direct-return helpers throw so
detail views show error states (reads may degrade *visibly*); mutation errors →
auto-dismissing ToastCenter toasts; per-operation scoping; `isArtistFollowed` returns unknown
until starred loads. Sweep all 12 tabs.
**Accept.** Kill the server: every tab shows a distinct error state with Retry; empty library
shows an empty state, not a blank grid; a failed mutation toasts on the active tab only.
**Verify.** Store tests for LoadState transitions (extends TEST-09 coverage in W-49); W-48
UI-smoke extended to assert the error state renders; manual server-down sweep of all tabs.
**Deps.** W-23 (per-surface loading), W-30 (ToastCenter), W-25.

### W-56 — Accessibility & keyboard navigation pass
Phase 4 · high · M-L · Sources: PROD-04, PROD-05
**Problem.** `accessibilityLabel` in only 3 files; zero across ~40 Shell/Music views; scrubber
not adjustable; hover-revealed play buttons invisible to VoiceOver/keyboard; star-rating and
heart unlabeled; no reduceMotion/reduceTransparency/dynamic-type handling. Keyboard: focus only
on filter fields; cards/rows not focusable; multi-select mouse-only. A VoiceOver user cannot
play an album.
**Evidence.** grep results per PROD-04/05; `MusicControls.swift` (scrubber);
`MusicMediaCard` (hover buttons).
**Fix.** Bar: every interactive element labeled; cards get `accessibilityAction("Play")` (and
visible-on-focus buttons); scrubber `accessibilityAdjustableAction`; rating/heart labeled with
values; respect Reduce Motion on animated surfaces; grid/list focusability + `onKeyPress`
(play/enter, arrows); document keys in Help.
**Accept.** `performAccessibilityAudit()` passes on every W-48 screen; a scripted VoiceOver
walkthrough can search → open album → play → rate.
**Verify.** W-48 audit assertions; manual VoiceOver session covering the walkthrough; Keyboard
navigation manual pass.
**Deps.** W-48.

### W-57 — "Agent Access" Settings pane (discoverability + token lifecycle UI)
Phase 4 · high · S-M · Sources: PROD-08
**Problem.** The differentiator ("agents can drive it") requires hand-reading a hidden JSON
file; no in-app endpoint/token/status display, no regenerate. docs/06 §14.2 calls for this;
shipped nowhere.
**Evidence.** grep `BatonSettingsView`: no MCP references; `BatonMCPServer.swift:51-58`.
**Fix.** Settings pane: server status + port, copy endpoint, reveal/copy token, **Regenerate**
(rotates token via W-14, rewrites discovery, drops sessions), docs link, a copyable client
config snippet; menu-bar status line ("Agent connected" when SSE streams > 0). First-run
"Connect an agent?" card (part of PROD-12 item 8).
**Accept.** A new user can connect Claude/agent tooling using only what the pane shows;
Regenerate invalidates old tokens immediately (verified by a failing old-token request).
**Verify.** W-46 harness: regenerate → old token 401s, discovery file updated; manual pane
walkthrough.
**Deps.** W-14, W-13.

### W-58 — Menu bar upgrade + launch-at-login (keep the agent surface alive)
Phase 4 · medium · M · Sources: PROD-09
**Problem.** The MenuBarExtra (72 LOC: title, transport, open, quit) keeps MCP alive when
windows close — but no launch-at-login/keep-running means scheduled agent flows ("play the
dinner mix at 7pm") silently break when the user quits.
**Evidence.** `App/BatonMenuBarExtra.swift`; grep: no `SMAppService`.
**Fix.** `SMAppService.mainApp` login-item toggle in Settings first; then enrich the extra per
docs/06 §14: artwork, like, volume, server/agent status. Requires W-51's window-independent MCP
startup to be meaningful.
**Accept.** With login item on, a reboot brings Baton (and its MCP endpoint) back without user
action; menu bar shows now-playing artwork + like.
**Verify.** Manual: enable, reboot (or logout/login), `curl` the MCP port before opening a
window.
**Deps.** W-51 (lifecycle), W-57 (status line shared).

### W-59 — Connect-sheet polish
Phase 4 · medium · S · Sources: PROD-14, NET-15
**Problem.** The first screen every user sees: no scheme normalization/hinting, raw
`localizedDescription` errors, no "What's Navidrome?" link. Multi-server "Disconnect" removes
the active server + its secret and silently activates the next one.
**Evidence.** `BatonConnectView.swift:28-58,38,86`; `NavidromeConfig.swift:226-235`.
**Fix.** Normalize input (prepend https://, trim trailing slash), map common URLError/subsonic
failures to human text with next steps, link Help; in multi-server UI replace Disconnect-active
with explicit remove/switch actions (or deactivate-without-delete).
**Accept.** Typing `demo.navidrome.org` connects; a wrong port yields actionable copy;
disconnecting with two servers configured asks what the user means.
**Verify.** Unit test the normalizer + error mapping table; manual first-run walkthrough.
**Deps.** W-16 (validator).

### W-60 — Playlist reorder beyond 200 tracks
Phase 4 · medium · S-M · Sources: PROD-10
**Problem.** Drag-reorder is gated at `orderedSongs.count <= 200`; docs/06 §2 documents the
cause and three fixes, none taken; the limit is unexplained in UI.
**Evidence.** `MusicDetailViews.swift:671`; `docs/06-improvements-existing.md` §2.
**Fix.** Implement the chunked `updatePlaylist` approach from docs/06 §2 (bulk-add chunking
already exists as a pattern); until then surface the limit ("reorder available up to 200 —
coming soon" tooltip). Ensure `setPlaylistSongs` failures reach the user (ties W-25 retry).
**Accept.** A 1,000-track playlist reorders and persists server-side; failure shows a toast +
reverts the local order.
**Verify.** Client chunking unit test; manual reorder on a large playlist against Navidrome.
**Deps.** W-25.

### W-61 — In-app diagnostics: log export + update/server status
Phase 4 · medium · M · Sources: DIST-11, DIST-09
**Problem.** For "podcasts won't load"/"updates don't work" there is no evidence path: no log
export, About shows only build-time constants, Sparkle has no delegate so update failures are
invisible to user AND developer.
**Evidence.** `App/BatonAboutView.swift:6-46`; `SparkleUpdater.swift:21-25` (nil delegates); no
OSLogStore usage.
**Fix.** About-pane Diagnostics: "Export Logs…" (OSLogStore, last hour, subsystem
`io.tonebox.baton`), last update check time/result, server connection health (ping + latency).
`SPUUpdaterDelegate` logging appcast load/chosen item/errors via `Log.updates`; surface last
error in About; optional opt-in Sentry breadcrumb on update errors (post-W-10 scrubbing).
**Accept.** One button produces a shareable log file; a bad appcast URL shows a visible error in
About within one check cycle.
**Verify.** Manual: break the feed URL in a dev build, run a check, confirm surfaced error +
exported log contains it.
**Deps.** W-18 (one subsystem), W-09.

### W-62 — Re-baseline the planning docs to the shipped code
Phase 4 (do any time; required before Phase 5/roadmap work) · high · S · Sources: PROD-11, DOC-01, PROD-12, PROD-13
**Problem.** docs/06 paths point at `apps/tonebox-mac` (a different repo) and call MCP "one-shot
HTTP" (it's Streamable HTTP + SSE); docs/05 marks downloads/podcasts/radio/multi-server/EQ as
open (all shipped); docs/02 §H + docs/05 #10 (flagship NL mix building) build on
`MusicCommandInterpreter`/`AppModel+Music.swift` which DO NOT EXIST in Baton. docs/04 overstates
port-walking/session expiry/mix shuffle (fixed by W-38/W-39/W-42 — update alongside). The
roadmap also misses: accessibility/localization, testing strategy, error-state design,
large-library scalability, local-state backup/portability (needed by the iOS companion),
MCP token lifecycle, beta channel, first-run agent discoverability, reset/uninstall story.
Forced dark mode is an unrecorded decision.
**Evidence.** `docs/05-roadmap-new-features.md`, `docs/06-improvements-existing.md:7,§2,§6,§11,
§14`, `docs/08`, `docs/04-integration-and-mcp.md` §2.1/2.2/3.5/4.3.
**Fix.** One re-baselining pass: mark shipped items with Baton paths; rewrite docs/06 against
`app/Sources/Baton`; record decisions (dark mode → D-03, NL commands → D-04); fold the PROD-12
gap list into the roadmap with decide-or-do status per item; update docs/04 as W-38/39/42 land.
**Accept.** No doc references a nonexistent type or the Tonebox repo layout; every roadmap item
carries shipped/open/decision status; this PLAN is linked from HANDOFF.md.
**Verify.** grep docs for `apps/tonebox-mac`, `MusicCommandInterpreter`, `AppModel+Music` → zero
hits; read-through review.
**Deps.** none (content); references decisions D-03/D-04.

---

### W-63 — Multi-server coherence (namespacing or explicit reset)
Phase 5 · medium · L · Sources: PER-01, ARCH-10, SCR-05, ARCH-36(4 partial)
**Problem.** Multi-server exists only at the config layer. On switch: browse state shows server
A's data until each tab reloads; `artistStatsCache` is never cleared (id-collision cross-talk);
the persisted queue holds A's ids resolved against B (wrong tracks or errors); downloads,
history, radio bans are server-agnostic; queued scrobbles deliver A's song ids to whichever
server is active at flush (wrong-track crediting or 20-attempt burn). Only
`PodcastCapabilityStore` namespaces correctly.
**Evidence.** `MusicLibraryStore.swift:129-134,237`; `Scrobble.swift:39-51`;
`StreamingPlaybackController.swift:394`; `MusicPodcastCapability.swift:119-121` (the good
example); call sites `BatonSettingsView.swift:237-250`, `BatonConnectView.swift:81-82`.
**Fix.** Per decision D-02 (recommended: namespace). Stage 1 (S, do immediately alongside
Phase 0 if desired): `resetForServerChange()` clearing every cache/collection + park-or-clear
the persisted queue on switch; stamp `QueuedScrobble` with origin server id (optional Codable
field; drain only matching entries, park others). Stage 2 (L): namespace downloads manifest,
history, radio bans, queue snapshots by `activeServerID` with W-12 migrations.
**Accept.** Switch servers → no stale rows, stats, badges, or queue from the old server;
scrobbles queued on A deliver to A only (parked while B active).
**Verify.** `MultiServerTests` extended beyond config: store-reset assertions, scrobble-routing
test, queue-park test; manual two-server switch session.
**Deps.** W-12, W-11, W-08/W-31.

### W-64 — Localization groundwork
Phase 5 · low · S (decision) / L (execution) · Sources: PROD-03
**Problem.** Zero `NSLocalizedString`/`String(localized:)` — all strings hardcoded. Every month
of new UI raises the retrofit cost; the decision is unrecorded.
**Evidence.** grep per PROD-03; `BatonConnectView.swift:28-58`.
**Fix.** Execute decision D-08: if "may localize", add a String Catalog now and route NEW
strings through it (backfill opportunistically); if "English-only", record it in docs/08 and
revisit at the iOS companion.
**Accept.** Decision recorded; if localizing, new code lints for hardcoded UI strings.
**Verify.** Doc review; optional lint rule in scripts/test.sh.
**Deps.** D-08.

---

## §3 Cross-cutting foundations

Specified once; work items reference them. Build each inside the first work item that needs it.

- **F1 — `VersionedStore<Payload>` (W-12).** Envelope `{version, payload}`; decode-failure →
  preserve-aside + log + surface; migration hooks; rolling last-good backup for precious stores;
  the "writes never fail silently" logging funnel. Consumers: all six stores, queue snapshot,
  W-32 history, W-36 podcasts, W-52 kind migration, W-63 namespacing.
- **F2 — `Log` namespace (W-18).** Single subsystem `io.tonebox.baton`, static categories
  (`Log.playback`, `Log.mcp`, `Log.updates`, …); grep-lint against ad-hoc `Logger(subsystem:)`.
  Consumers: everything; W-61 log export reads it.
- **F3 — Injected networking (W-25).** One `URLSession` per traffic class (json ≈12 s timeout,
  ping shorter, downloads longer), generic Subsonic `perform<R>` transport, lossy array decode,
  idempotent-GET retry, HTTP-status mapping, and a cached `NavidromeClient` per active server
  invalidated by `refreshConnection()`. Consumers: W-26, W-31, W-33, W-37, W-54, W-60.
- **F4 — Freshness idiom (W-23).** Generation tokens on the controller
  (play/clearQueue/stop bump) + `LatestWins` per store surface + an owned-task registry.
  Consumers: W-26, W-30, W-55; pattern for all future async completions.
- **F5 — MCP test harness (W-46).** In-process server boot on an ephemeral port with stubbed
  MusicModel; parse-fuzz tables; SSE assertion helpers; the E2E release-gate suite. Consumers:
  W-14, W-38–W-41, W-57.
- **F6 — `ToastCenter` (W-30).** `@MainActor @Observable`, owned by `MusicModel`; controller and
  stores post; kills the toast-via-playback-controller coupling. Consumers: W-30, W-33, W-55.
- **F7 — `scripts/test.sh` (W-01).** The local gate; grows grep-lints (W-16 URL-in-log, W-18
  subsystem, W-64 strings) and the XCUITest/E2E suites; `publish.sh` depends on it (W-17).
- **F8 — Composition root (W-49/W-51).** `MusicModel.init(environment:)` injecting
  defaults/stores/sessions once; deletes `BatonRuntime.isTest` sniffing; tests build
  `MusicModel(.testing)`.

---

## §4 Confirmed-good, accepted, and decisions for the owner

### Confirmed-good (verified safe — do not re-flag)
- **SEC-17** — download filename sanitizer blocks traversal (verified; optional UTF-8 byte-bound
  is cosmetic).
- **SEC-18** — webhook substitution is context-escaped, cannot inject host, not agent-reachable;
  optional CRLF strip if ever touched.
- Verified positives to preserve: loopback-only MCP with CSPRNG 256-bit token +
  constant-time compare; audio-focus owner/generation design + its test coverage; opt-in Sentry
  with empty DSN in repo builds; honest-UI gating (UpdateChannel placeholder detection);
  zero print/NSLog logging hygiene; scrobble-queue durability core (tested); Sparkle
  EdDSA-over-HTTPS enforcement.

### Accepted / won't-fix (with reason)
- **SEC-14** — token-compare length leak: token length is fixed/public; negligible.
- **RAD-03** — radio logo regex scraping: bounded (200 KB, 6 s, monogram fallback); persistence
  of results handled in W-30; otherwise leave.
- **SCR-07** — at-least-once scrobble delivery: accepted; W-31 documents it and the `time` param
  makes Navidrome duplicates diagnosable.
- **AUDIO-29** — denormal protection: skip if the shipped build is arm64-only (W-20 checks and
  documents).
- **SPM multi-target split** (ARCH-24 tail): deferred until after W-51's directory boundaries
  prove insufficient — the DI seams already permit it later.

### Decisions needed from the owner (the plan does not block on these)
- **D-01 — App Sandbox** (SEC-01, ARCH-35). Recommended: adopt (`network.client`,
  `network.server`, security-scoped bookmark for the downloads folder, Keychain group
  migration) — it's L effort but *now-or-never*: retrofitting after users accumulate data in
  unsandboxed paths is far harder, and Baton parses attacker-influenceable RSS/JSON/images with
  two local listeners. If declined, record an ADR stating why (Sparkle+socket+downloads).
- **D-02 — Multi-server model** (PER-01): namespace per-server (recommended; W-63 stage 2) vs
  declare stores global and only clear-on-switch (W-63 stage 1 alone).
- **D-03 — Forced dark appearance** (PROD-13): record as a product decision in docs/08;
  recommended keep for v0.x, verify Increase Contrast rendering.
- **D-04 — NL-command strategy** (PROD-11 / docs/05 #10): `MusicCommandInterpreter` was never
  extracted from Tonebox. Recommended: **delegate NL to client agents via MCP** (docs/08 §3's
  lean) rather than re-import or rebuild — the tool surface is the product.
- **D-05 — Radio-stop behavior** (AUDIO-20/ARCH-08): after stopping radio, auto-resume the
  library or stay paused? Recommended: stay paused, but via an explicit released token (W-30),
  never a leak.
- **D-06 — Sparkle signing key** (SEC-16): per-app key vs the shared personal key. Recommended:
  cut a per-app key at the next natural break; either way record custody + verified backup (W-17).
- **D-07 — Offline download quality** (W-34): original files by default (recommended) with an
  optional "save space (transcode)" toggle later.
- **D-08 — Localization policy** (PROD-03): recommended "English-only for now" recorded in
  docs/08 + String Catalog for new strings (W-64).

---

## §5 Appendix — traceability (all 231 findings)

Format: `finding → disposition`. W-xx = covered by that work item; slashes = split across items
(first listed is primary). CG = confirmed-good, ACC = accepted/won't-fix, D-x = owner decision.

**Architecture (37):**
ARCH-01→W-11 · ARCH-02→W-24 · ARCH-03→W-02 · ARCH-04→W-05/W-33/W-34 · ARCH-05→W-23 ·
ARCH-06→W-22 · ARCH-07→W-38 · ARCH-08→W-30 · ARCH-09→W-41 · ARCH-10→W-63 · ARCH-11→W-40 ·
ARCH-12→W-41 · ARCH-13→W-15 · ARCH-14→W-15 · ARCH-15→W-15/W-50 · ARCH-16→W-20 · ARCH-17→W-40 ·
ARCH-18→W-25 · ARCH-19→W-23 · ARCH-20→W-23 · ARCH-21→W-32 · ARCH-22→W-04 · ARCH-23→W-50 ·
ARCH-24→W-51/ACC(SPM tail) · ARCH-25→W-51 · ARCH-26→W-30 · ARCH-27→W-52 · ARCH-28→W-12/W-55 ·
ARCH-29→W-41/W-51 · ARCH-30→W-51 · ARCH-31→W-51 · ARCH-32→W-49 · ARCH-33→W-14 · ARCH-34→W-30 ·
ARCH-35→W-51/W-17/D-01 · ARCH-36→(1-3)W-24 ·(4)W-55/W-63 ·(5)W-36 ·(6)W-28 ·(7)W-31 ·(8)W-33 ·
ARCH-37→W-47

**Audio (30):**
AUDIO-01→W-21 · AUDIO-02→W-22 · AUDIO-03→W-20 · AUDIO-04→W-04 · AUDIO-05→W-29 · AUDIO-06→W-26 ·
AUDIO-07→W-20 · AUDIO-08→W-21 · AUDIO-09→W-11 · AUDIO-10→W-24 · AUDIO-11→W-24 · AUDIO-12→W-27 ·
AUDIO-13→W-27 · AUDIO-14→W-27 · AUDIO-15→W-11 · AUDIO-16→W-23 · AUDIO-17→W-28 · AUDIO-18→W-28 ·
AUDIO-19→W-30 · AUDIO-20→W-30/D-05 · AUDIO-21→W-45 · AUDIO-22→W-45 · AUDIO-23→W-44 ·
AUDIO-24→W-29 · AUDIO-25→W-49 · AUDIO-26→W-21 · AUDIO-27→W-47 · AUDIO-28→W-22 ·
AUDIO-29→W-20/ACC(arm64) · AUDIO-30→W-24/W-29

**MCP / tools / mix / focus / socket / speech (43):**
MCP-01→W-02 · MCP-02→W-38 · MCP-03→W-39 · MCP-04→W-39 · MCP-05→W-39 · MCP-06→W-40 ·
MCP-07→W-39/W-02 · MCP-08→W-41 · MCP-09→W-39 · MCP-10→W-39 · MCP-11→W-14/W-13 · MCP-12→W-14 ·
MCP-13→W-51 · TOOL-01→W-07 · TOOL-02→W-41 · TOOL-03→W-40 · TOOL-04→W-41 · TOOL-05→W-41 ·
TOOL-06→W-41 · TOOL-07→W-41 · MIX-01→W-42 · MIX-02→W-42 · MIX-03→W-42 · FOCUS-01→W-39 ·
FOCUS-02→W-39 · FOCUS-03→W-39 · SOCK-01→W-03 · SOCK-02→W-15 · SOCK-03→W-15 · SOCK-04→W-15 ·
SOCK-05→W-03 · SPEECH-01→W-43 · SPEECH-02→W-43 · SPEECH-03→W-43 · SPEECH-04→W-19 ·
SPEECH-05→W-19 · SPEECH-06→W-19 · SPEECH-07→W-19 · SPEECH-08→W-04 · SPEECH-09→W-19/W-18 ·
SPEECH-10→W-19 · MCP-TEST-01→W-46 · DOC-01→W-62

**Networking / scrobble / downloads / podcasts / radio / persistence (54):**
NET-01→W-25 · NET-02→W-25 · NET-03→W-25 · NET-04→W-41 · NET-05→W-37 · NET-06→W-37 ·
NET-07→W-54 · NET-08→W-18 · NET-09→W-25 · NET-10→W-25 · NET-11→W-51 · NET-12→W-31 ·
NET-13→W-12 · NET-14→W-13 · NET-15→W-59 · SCR-01→W-08 · SCR-02→W-08 · SCR-03→W-31 ·
SCR-04→W-31 · SCR-05→W-63 · SCR-06→W-31 · SCR-07→W-31/ACC · SCR-08→W-31 · SCR-09→W-31 ·
SCR-10→W-32 · SCR-11→W-31 · DL-01→W-05 · DL-02→W-33 · DL-03→W-33 · DL-04→W-34/D-07 ·
DL-05→W-06 · DL-06→W-12 · DL-07→W-33 · DL-08→W-33 · DL-09→W-33 · DL-10→W-05/W-33 ·
POD-01→W-36 · POD-02→W-35 · POD-03→W-35 · POD-04→W-35/W-36 · POD-05→W-36 · POD-06→W-35 ·
POD-07→W-36 · POD-08→W-36 · POD-09→W-12 · POD-10→W-36 · RAD-01→W-30 · RAD-02→W-30 ·
RAD-03→ACC · RAD-04→W-30 · PER-01→W-63/D-02 · PER-02→W-12 · PER-03→W-05 · PER-04→W-49

**Distribution (17):**
DIST-01→W-09 · DIST-02→W-09 · DIST-03→W-10 · DIST-04→W-17 · DIST-05→W-17 · DIST-06→W-17 ·
DIST-07→W-17 · DIST-08→W-17 · DIST-09→W-61 · DIST-10→W-18 · DIST-11→W-61 · DIST-12→W-09 ·
DIST-13→W-10 · DIST-14→W-17 · DIST-15→W-17 · DIST-16→W-17/D-06 · DIST-17→W-17

**Testing / product (31):**
TEST-01→W-46 · TEST-02→W-46/W-41 · TEST-03→W-46 · TEST-04→W-49/W-19 · TEST-05→W-09/W-10/W-49 ·
TEST-06→W-49 · TEST-07→W-47 · TEST-08→W-48 · TEST-09→W-49/W-55 · TEST-10→W-49/W-54 ·
TEST-11→W-01 · TEST-12→W-49 · TEST-13→W-49 · TEST-14→W-15 · TEST-15→W-46/W-40 · TEST-16→W-49 ·
PROD-01→W-53 · PROD-02→W-54 · PROD-03→W-64/D-08 · PROD-04→W-56 · PROD-05→W-56 · PROD-06→W-55 ·
PROD-07→W-55 · PROD-08→W-57 · PROD-09→W-58 · PROD-10→W-60 · PROD-11→W-62 · PROD-12→W-62 ·
PROD-13→W-62/D-03 · PROD-14→W-59 · PROD-15→W-13

**Security (19):**
SEC-01→D-01 · SEC-02→W-10 · SEC-03→W-13/W-14 · SEC-04→W-14 · SEC-05→W-15 · SEC-06→W-15 ·
SEC-07→W-16 · SEC-08→W-16 · SEC-09→W-13 · SEC-10→W-35 · SEC-11→W-16 · SEC-12→W-19 ·
SEC-13→W-35 · SEC-14→ACC · SEC-15→W-39 · SEC-16→W-17/D-06 · SEC-17→CG · SEC-18→CG ·
SEC-19→W-13

**Coverage check:** 37 + 30 + 43 + 54 + 17 + 31 + 19 = 231 findings, all dispositioned.
