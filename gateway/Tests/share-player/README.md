# Song-sharing browser verification

The browser walks use synthetic sine-wave audio and a generated cover. They upload,
decrypt and play real media through the shipping service and nginx config. They check
Pause/resume, 30 seconds actually heard, completion, a reaction persisted for the sharer, absent and
wrong keys, revoked and expired links, unknown links, pending-to-ready polling, play
cap and cap increase/extension, private metadata, Open Graph privacy, CSP errors,
and iPhone/Mac Get Baton attribution without external navigation.
Each run writes screenshots and `result.json`. A skip is printed explicitly.

Through nginx, every walk first sends raw requests with Range spellings a browser cannot
produce: two Range headers, and a tab or no-break space before `bytes=`. nginx sends each of
them from byte 0, so each must count toward the play cap; a strict continuation inside the
transfer allowance the last play left must not.

The full walk also opens a mixtape page (`/m/`, `mixtape-page.mjs`) through the same service and
nginx: header, expiry and plays-left chips, keyboard Play, pause, seek, Next, the one-line session
prompt for Previous (Not now spends nothing, Start listening spends one play), a reaction, revoked
and expired links reading as ended, the unknown page, and screenshots at 390 and 1280 px in light
and dark. It also checks that nginx sends one `Referrer-Policy: no-referrer` for `/m/`, that the
phone's docked player follows the list in the DOM and Tab order (and leads it when wide), that
"Start listening" meets 4.5:1 contrast in both schemes, and that the time remaining has a
visually hidden label rather than an `aria-label` on a plain span. Its synthetic media comes from `make-mixtape-media.py`, which needs `/private/tmp`,
ffmpeg and a Python with `cryptography` (`SHARE_E2E_PYTHON` selects one). Without them, or against
a service with mixtapes off or a public service, `result.json` lists the mixtape walk as skipped.
It also answers one admission and one track with the transport's 503 `capacity` (in the browser),
checking that neither spends a play or drops the session, and, for a spawned service, plays a link
extended while its page is open. `--mixtape-only` runs only this walk after the
shared nginx checks.
The full walk then opens a whole-book page (`/b/`, `book-page.mjs`, TBX-1000000132). It makes three
6-second AAC chapters with ffmpeg and read-along text for the first, seals them under the
`baton-book-1` keys and creates, uploads and finalizes the book through the real service routes
(the spawned service runs with `BATON_SHARE_BOOKS=1`). It checks one `Referrer-Policy: no-referrer`
for `/b/`, private Open Graph, the authenticated details, that opening and "Not now" spend nothing
and Start listening spends exactly one listener, chapter 1 on a moving media clock with the
read-along sentence following it, play running on into chapter 2 without a second admission (the
first chapter's Blob URL revoked), `localStorage` holding only `{token, expiresAt, chapter,
seconds}`, a reload resuming the position without a second listener, a keyboard chapter choice,
completion and a reaction, wrong and missing keys, unknown, an expired or refused (401) stored
token, blocked storage, pending to ready, revoke reading as expired and clearing storage, an
expired link, contrast and screenshots at 390 and 1280 px in light and dark. `--book-only` runs
only this walk after the shared nginx checks, for a quicker loop.
Last, the full walk opens the album and playlist page (`/b/` with a collection kind,
`collection-page.mjs`, TBX-1000000485; the spawned service also runs with
`BATON_SHARE_COLLECTIONS=1`). It makes three 5-second songs as the apps seal music (AAC, 128 kbps,
stereo, in an .m4a) and a small JPEG cover, seals them under the book keys as a `baton-collection-1`
album (cover, track numbers 1, 2 and 4, one song by a guest artist) and a playlist (each song's
artist and album, no cover, a public preview), and creates, uploads and finalizes both through the
real service routes. It checks the shell's headers and CSP (`blob:` images and media), the versioned
assets, private Open Graph ("Someone sent you an album") and a public preview that names no song;
the authenticated header and song list (album numbers by track number, playlist by position,
artists where they differ), the decrypted cover shown before anyone is admitted and the tinted
placeholder without one; that opening and "Not now" spend nothing and request no song, and Start
listening (from the keyboard) spends exactly one listener; song 1 on a moving media clock running
into song 2 with no second admission (labelled `audio/mp4`, the previous Blob URL revoked); Media
Session metadata where the engine has it; `localStorage` holding only `{token, expiresAt, track,
seconds, shuffle, repeat}`; seek, Previous restarting a song past 3 s and going back a song inside
them, Next stopping at the end; a reload resuming without a second listener or play-started; the
fifth whole-song transfer meeting the 1.5× allowance (409 `transfer_budget`, "This listen has used
its transfer allowance") and Start listening again spending one more; completion and a reaction;
on the playlist, shuffle keeping the current song and playing the rest once, repeat cycling off,
all and one, both surviving a reload, repeat one replaying from memory with no request, and repeat
all running from the last song into the first; no element offering a download; wrong and missing
keys and an unknown link; revoke reading as expired and clearing storage; an expired link; and
contrast and screenshots of both kinds at 390 and 1280 px in light and dark
(`collection-<kind>-<width>-<scheme>.png`, results in `collection-page.json`).
`--collection-only` runs only this walk after the shared nginx checks.
`SHARE_E2E_NGINX_LOG=1` adds nginx's per-request timings and info-level errors and saves them with the
service log as `server.log` in the evidence folder; the book walk also leaves `book-phone.har` and, in
Chromium, `book-network.json`. On 2026-10-21 that log showed the occasional 30 to 60 s stall in
`--nginx-docker` runs to be nginx timing out while connecting from its container to the service on
the host (`upstream timed out ... while connecting to upstream`, Docker Desktop's host gateway), not
the page.
Run different engines sequentially on macOS: simultaneous browser processes can
interrupt the system media output and make the long listening check unmeasurable.
WebKit behavior runs without screenshots and must pass all application/CSP checks
first. It then saves retained final page states as `webkit-final-state-*.png` and
reports screenshot-tool errors separately: Playwright's WebKit screenshot sync
inserts a temporary inline stylesheet, which strict CSP correctly rejects.

Build the service first:

```sh
cd gateway
swift build --product baton-share
cd ..
```

Install Playwright and its three browser runtimes in your test environment. If the
package is outside node's resolution path, set `SHARE_E2E_PLAYWRIGHT` to its absolute
package directory. `SHARE_E2E_BROWSER_PATH` can select a separately cached runtime.
FFmpeg is required. Choose installed nginx with `--nginx` or local Docker nginx with
`--nginx-docker` (the free `nginx:alpine` image).

```sh
node gateway/Tests/share-player/e2e.mjs --nginx-docker --browser=chromium gateway/.build/debug/baton-share /tmp/share-evidence/chromium
node gateway/Tests/share-player/e2e.mjs --nginx-docker --browser=firefox gateway/.build/debug/baton-share /tmp/share-evidence/firefox
node gateway/Tests/share-player/e2e.mjs --nginx-docker --browser=webkit gateway/.build/debug/baton-share /tmp/share-evidence/webkit
node gateway/Tests/share-player/e2e.mjs --nginx-docker --browser=chromium --listeners=50 gateway/.build/debug/baton-share /tmp/share-evidence/load
```

The last command loads 50 isolated browser contexts with distinct synthetic visitor
agents, starts all 50 together, requires every real media clock to reach at least 30 seconds,
then checks exactly 50 fetches, starts, unique listeners and 30-second receipts in the service's owner
view. `load.json` records counts and elapsed time. Load audio is physically muted;
this measures real decoding/media clocks, not 50 physical audio outputs. The runner
saves media readiness/errors, outcomes and CSP errors before assertions, including
partial failures. Chromium headless also receives Playwright's `--mute-audio` default. It refuses an external service or
non-local base. This is a bounded functional concurrency check, not a production
capacity benchmark.

The focused media-failure walk substitutes invalid MP3 bytes into the real Audio
element before playback and after a successful start, then explicitly retries the
retained decrypted song. It requires two real errors and two moving media clocks,
one fetch/play/listener, no completion/30-second/decrypt-failure inflation, and zero
CSP/script errors. It records the served asset hash/version and final screenshot.

```sh
node gateway/Tests/share-player/e2e.mjs --nginx-docker --browser=firefox --media-errors-only gateway/.build/debug/baton-share /tmp/share-evidence/media-errors
```

The deadline test adjusts only its newly-created localhost fixture's SQLite expiry,
then drives the normal public request path and checks audio becomes 410. It skips
that case against an externally supplied service; it never modifies a remote DB.

For an app-created fixture, save the complete LOCAL URL in a mode-0600 file (plain
text or JSON with `url` and optionally `dataDirectory` for its synthetic service), then:

```sh
node gateway/Tests/share-player/play-link.mjs /tmp/link.txt /tmp/app-browser-evidence chromium
```

This helper refuses public links, never prints the link or key, plays at least 31 real
seconds, submits a synthetic reaction, and records outgoing playback beacon types.
It captures the final reaction screenshot only after strict behavior/CSP checks;
snapshot-tool errors are separate from app errors. Failure evidence gives the stage,
redacted error, browser error count and beacon types without request payloads.
With `dataDirectory`, the helper reads only a temporary synthetic SQLite database in
read-only mode and asserts the service received start/30-second/reaction events.
Without it, the helper checks HTTP204 event acknowledgements and explicitly leaves
server counter verification to the caller. Blob beacon bodies can be unavailable in
Playwright; unavailable bodies are counted rather than misreported as missing events.

Production verification still needs owner approval for fixture uploads and reactions.
The localhost spawn mode above does not exercise Cloudflare or Nginx Proxy Manager.
After approval for synthetic creation, playback, reaction, and revocation, this
command exercises all public hops, without requiring an admin credential:

```sh
SHARE_E2E_SERVICE=https://batonmusic.app node gateway/Tests/share-player/e2e.mjs --public --browser=chromium unused /tmp/share-production-evidence/chromium
```

Repeat sequentially for Firefox and WebKit. It explicitly skips the localhost
expiry acceleration and internal admin aggregate report; those are verified
separately. It checks public admin stays 404, uses a fresh synthetic sharer bearer,
and revokes test fixtures even if the browser walk fails. The 50 listener check
refuses this mode. Do not run these public commands before owner approval.

For a bounded localhost startup/memory measurement, use `--startup-only` and an
optional synthetic song length (40–800 seconds, about 1–19.2MB at 192kbps). The
shipping player still downloads, authenticates all BSH1 records, and creates its
normal decrypted Blob. This mode refuses external services, public mode, listener
load and media-error substitution. It finishes after the decoded media clock
advances beyond two seconds; it does not run the full reaction/lifecycle walk.

```sh
node gateway/Tests/share-player/e2e.mjs --nginx-docker --browser=chromium --chromium-channel=chromium --startup-only --song-seconds=400 gateway/.build/debug/baton-share /tmp/share-startup/full-chrome-local
node gateway/Tests/share-player/e2e.mjs --nginx-docker --browser=chromium --chromium-channel=chromium --startup-only --song-seconds=400 --download-mbps=10 --latency-ms=80 gateway/.build/debug/baton-share /tmp/share-startup/full-chrome-shaped
python3 gateway/Tests/share-player/startup-run.py --binary gateway/.build/debug/baton-share --evidence /tmp/share-startup/full-chrome-local --profile local --playwright /absolute/path/to/playwright --browsers /absolute/path/to/cached-browsers --prepare
# After the native audio owner releases the slot, replace --prepare with --run-authorized.
# Run --profile shaped in a NEW evidence directory only after the first result is reviewed.
```

`--chromium-channel=chromium` selects Playwright's cached full Chromium executable
in headless mode. Without it, Playwright chooses its separate headless-shell
executable. Both automatically receive `--mute-audio`; adding that flag again is
not a different experiment. Record the actual browser version/command line before
comparing runtimes. This option also works with the existing full-flow/load walk.

`startup.json` retains download, decryption, Blob and first advancing-clock times,
actual media/error events, strict CSP/script errors, and browser version/flags on
success or failure. `startup-decoder.json` records Chromium's decoder/renderer
messages (the synthetic fragment link is redacted). `startup-receipts.json` records
server counters even on a failed media-clock check. Clock advancement proves real
media decoding; it does not measure physical sound. Decryption instrumentation
observes native WebCrypto calls and never reads or changes their inputs/results.

Memory samples cover only processes enumerated by this run's browser CDP session,
including renderer/audio processes, using RSS plus JS heap/backing-storage figures.
RSS includes caches and native allocations; JS heap alone does not represent Blob
or decoder memory. Samples every 100ms can miss brief peaks, and no GC is forced.
Treat peaks/deltas as observations, not exact allocation accounting or a p95.
The shaped network is a controlled local 10Mbit/s/80ms condition, not a real LTE
measurement. Measure on real Safari/devices before choosing a streaming migration.

The outer Python supervisor gives each startup fixture 180 seconds total, including
cleanup: up to 160 seconds for the child and 20 reserved for cleanup. It uses a
fresh private HOME/TMPDIR and a unique container name, kills only its explicitly
created child process groups, then removes only that exact container/workspace.
A hard deadline also covers a stuck cleanup command. `run-status.json` preserves
the original nonzero exit and marks cleanup unverified if the deadline prevents
confirmation; it records the exact owned paths for later recovery. Existing
evidence directories are refused. `--prepare` prints the command without launching
any browser, service, container or media. No inherited public/service/admin config
is passed through. Test the supervisor with:

```sh
python3 gateway/Tests/share-player/test-startup-watchdog.py
```

Startup registers the actual Chromium process group immediately after launch,
before page/context setup, recording its nonce, UID, start time and executable
metadata without command arguments. Normal cleanup requires an independent
process-table check that both this browser group and the fixture group have no
live members. A successful parent exit without a valid registry is not accepted
as clean. An abnormal/abrupt parent exit can race registration and leave detached
children reparented; it conservatively retains the namespace and registry and
reports process cleanup uncertainty. It never signals a reparented process by
browser name or a possibly reused PID. Root must recover that exact fixture before
releasing a media slot. The outer 180-second deadline still applies.

The installed full Chromium launch does not expose `Browser.getBrowserCommandLine`
without adding `--enable-automation`. Startup verification does not add that flag.
It obtains the browser PID from `SystemInfo.getProcessInfo`, checks exact-PID
UID/start/executable metadata against the explicitly selected cached executable
(with canonical symlink resolution), and records requested launch options.
`actualCommandLineAvailable` is false; expected mute behavior is attributed to
Playwright's installed headless defaults rather than a returned command line or
physical sound measurement. Both registration and measurement work without the
unsupported query. The focused regression uses disposable Node processes, not a
browser:

```sh
node --test gateway/Tests/share-player/startup-registry.test.mjs
```

For the Chromium concurrent-renderer investigation, `--profile load`
runs the full local walk followed by 50 isolated listeners using cached full
Chromium. The same 180-second outer deadline reserves 20 seconds for cleanup.
It records actual runtime/version and owned executable hashes, per-listener media
states/events, renderer error messages, all 50 outcomes, and owner API counters
before assertions. It never changes currentTime or infers physical audibility.
Use a new evidence directory and obtain the coordinated local audio window:

```sh
python3 gateway/Tests/share-player/startup-run.py --binary /absolute/path/to/qualified/baton-share --evidence /tmp/share-load/new-chromium --profile load --playwright /absolute/path/to/playwright --browsers /absolute/path/to/cached-browsers --prepare
# After admission and coordination, replace --prepare with --run-authorized.
```

This creates six disposable synthetic shares, about 5.76MB encrypted uploads and
48MB for the concurrent audio downloads. Public/external service options are not
accepted; inherited service credentials are discarded. Keep a failed result and
its exact cleanup uncertainty. A later successful runtime check does not replace
the original renderer failure or certify production capacity.

The October 4 TBX-8912 investigation found the preserved stalled listener's CDP
`PipelineStatus::AUDIO_RENDERER_ERROR` (code 19), alongside media error 3 and a
moving page timer. That identifies the audio renderer/output failure layer; its
underlying system trigger and original browser version were not recorded. The
existing player error/retry handling addresses the formerly misleading playing UI.
The changed full-Chromium 151.0.7922.34 run passed all 50 actual clocks beyond
30 seconds, exact owner counters and zero renderer/application errors. A first
attempt failed before playback on a valid unrelated macOS UID -2 metadata row;
the public registrar regression fails before the signed-UID intake correction and
all nine registry checks pass after. Original failures and bounded cleanup recovery
remain preserved in `evidence/8912/diagnosis.json`; the successful attempt took
122.138 seconds with verified exact cleanup. This is one local synthetic run.

The supervisor also removes and independently inspects the exact UUID network
created by the fixture. Container, network and registered process groups must all
be absent before the namespace is removed and cleanup is called verified. It never
uses network pruning or name patterns. Interruptions preserve their original exit
status; a retained/uninspectable network keeps the namespace and ownership receipt
for recovery. Network cleanup stays inside the same 180-second outer deadline.


For the complete local per-engine walk, the same watchdog accepts `--profile flow`
and `--browser chromium|firefox|webkit`. It creates five synthetic shares (about
4.8MB encrypted audio in total), with a real 40-second song. Use a new evidence
folder for each engine, sequentially, after coordination. Each has its own 180s
outer cap; three runs can take at most nine minutes, not a six-minute hard bound.
Firefox may select its cached binary with `--browser-executable /absolute/path`.
This mode still refuses inherited public/service credentials and runs through
local nginx; it is not a production check or a 50-listener test.

The full walk uses the native seek range's Home key and verifies the actual audio
clock falls, then advances again. `seek.json` records before/after/resumed media
state. It never writes currentTime or fabricates a media event. Server counters
still require one start/listener, one 30-second listen and one completion.

For watchdog-owned full walks, Playwright's public `launchServer().process()`
provides the spawned PID before `connect()` or page creation. The registry checks
exact spawnfile, UID/group/start/executable and hashes the selected cached runtime.
WebKit's cached bash launcher also requires its pinned script bytes and exact
native runtime direct child; a generic interpreter alone cannot qualify. When ps
reports only a basename, macOS proc_pidpath supplies the kernel executable path
for that already-owned PID. No owner process arguments or generic browser-name
signals are used. Normal cleanup needs independent group absence; abnormal exit
keeps the original failure and exact namespace for recovery. The Node/bash
registry regressions are process-ownership tests, not playback evidence.
