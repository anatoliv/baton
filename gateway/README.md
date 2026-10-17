# baton-gateway

The Baton apps call this your **Baton server**, to tell it apart from your **music server**
(Navidrome or another Subsonic server, which holds your library). Both can run on the same
machine. [The two servers Baton uses](../HELP.md#the-two-servers-baton-uses) explains the
difference in plain words; this page is the technical setup.

A small service that does two jobs for Baton, and you can use either one without the other:

- **Shared settings.** Keeps the preferences that belong to *you* rather than to a device —
  the equalizer, crossfade, radio bans, podcast subscriptions, search history and the music
  friend's provider and model — in step between your Mac and your iPhone. Secrets are never
  among them: they live in each device's Keychain and travel by pairing instead. Navidrome has no
  client-preference API and never will, so these need somewhere else to live, and the
  gateway is the one place both devices already sign in to.
- **The music friend's brain, at home.** The phone posts a message; the gateway runs the
  same agent loop the Mac app ships, with the tools bound straight to Navidrome. Your model
  provider key stays on the server instead of on the phone.

It builds and runs on macOS and on Linux. The natural home for it is whatever box already
runs Navidrome.

## Running it

Requires Swift 6. From a checkout of this repository:

```sh
export BATON_GATEWAY_TOKEN="a-long-random-string-you-make-up"
export NAVIDROME_URL="https://music.example.com"
export NAVIDROME_USER="you"
export NAVIDROME_PASSWORD="…"

cd gateway
swift run -c release baton-gateway
```

It prints the port it is listening on and the server it is pointed at, then stays in the
foreground. Those four variables are required and it exits rather than starting without
them — a gateway that came up with no token would be an open door, and one with no library
has nothing to answer about.

Check it from another machine:

```sh
curl -s http://gateway.example:8788/health
# {"status":"ok", "navidrome":{"reachable":true,"probe":"answered","probe_ms":84, …}, …}
# {"status":"navidrome-unreachable", "navidrome":{"probe":"timedOut","probe_ms":2005, …}, …}
```

`/health` is the only route that doesn't need the token, which is what makes it usable as an
uptime check. It answers in **at most about two seconds**: the Navidrome ping behind it is held
to a wall clock, so an unreachable library is reported promptly instead of after the transport's
own two minutes of patience. Read `navidrome.summary` before acting on the headline —
`navidrome-unreachable` covers both "nothing answered in 2s" and "the server rejected the ping",
and the second of those can be a wrong password rather than a server that is down.

## Configuration

Everything is an environment variable.

| Variable | Default | What it does |
|---|---|---|
| `BATON_GATEWAY_TOKEN` | **required** | The bearer token both devices present. Invent a long random one. |
| `NAVIDROME_URL` | **required** | Your music server. |
| `NAVIDROME_USER` | **required** | The user the gateway curates as. |
| `NAVIDROME_PASSWORD` | **required** | That user's password. Sent to Navidrome token-salted, never in the clear. |
| `BATON_GATEWAY_PORT` | `8788` | Listen port. |
| `BATON_STATE_FILE` | `$XDG_DATA_HOME/baton/baton-state.json` | Where shared settings are kept. |
| `BATON_LLM_PROVIDER` | `anthropic` | `anthropic` or `openai-compatible`. |
| `BATON_LLM_MODEL` | `claude-haiku-4-5-20251001` | Model id. |
| `BATON_LLM_BASE_URL` | the provider's own | Point this at a LiteLLM or Ollama box on your LAN. |
| `BATON_LLM_API_KEY` | empty | Key for the provider. |
| `BATON_LLM_LOCAL` | unset | `1` when that model is on your network under a name the address rule cannot read (a Docker service, a bare host name). Book tasks (`/v1/books/complete`) use the model only when it is local. |
| `BATON_TTS_KOKORO_URL` | `http://127.0.0.1:8880` | Kokoro, for rendering books. Any host on your LAN. |
| `BATON_TTS_CHATTERBOX_URL` | unset | Chatterbox, only if a book's voices use it. |
| `BATON_RENDER_CONCURRENCY` | `2` | TTS requests in flight per book. |
| `BATON_BOOKS_MAX_BYTES` | 4 GiB | Space for rendered books, separate from parked files. |
| `BATON_BOOKS_KEEP_FINISHED_DAYS` | `30` | How long a finished book's audio stays. |
| `BATON_FFMPEG` | `ffmpeg` on `PATH` | The encoder for chapters. Without it, books are off and say so. |

The `BATON_LLM_*` variables are for the music friend, and for the phone's book recaps when
the model is on your network. Leave them unset and the gateway still starts and still syncs
settings; only `/v1/agent` and `/v1/books/complete` will fail.

`BATON_STATE_FILE` defaults under the XDG data directory rather than the working directory
on purpose. Run by hand from a checkout, the working directory is fine — but under systemd
or Docker it is `/`, so the file would land somewhere surprising or unwritable and your
settings would quietly vanish on every restart. Under a container, set it explicitly and put
it on a mounted volume.

`deploy/compose.yml` does exactly that: `BATON_STATE_FILE=/var/lib/baton-gateway/baton-state.json`,
which is the named volume, and the parked files sit beside it because `filesDirectory` is derived
from that path. **This was missing until 2026-09-09 and the compose comment claimed otherwise**
: the state file was landing in the container's writable layer, so
`docker compose up --force-recreate` — which is how `deploy.sh` starts the gateway, and the only
way a rotated token takes effect — destroyed the shared settings and every file in flight on every
deploy. Nobody noticed because both devices simply re-seed the document afterwards. `deploy.sh`
now moves the old file onto the volume before recreating anything, and checks its digest across
the restart rather than assuming.

## Where your settings live

One JSON file, at `BATON_STATE_FILE`. It is a plain document you can open and read, and it
holds settings only — no listening history, no credentials, no library data.

Each setting carries when it changed and which device changed it, so a conflict is resolved
one setting at a time rather than one device at a time. Two devices changing different things
never overwrite each other. Lists — search history, filter history, podcast subscriptions —
are merged rather than replaced, because "newest wins" would delete whatever the quieter
device had.

Writes are atomic and the body is validated as JSON before it lands, so a truncated PUT
cannot leave a file that every later read chokes on. Back it up like any other small config
file; losing it costs you your preferences, nothing more.

## Security

**There is no TLS here.** The gateway speaks plain HTTP, because on a home network behind a
reverse proxy that is the simpler and more honest arrangement. Every route except `/health`
requires the bearer token, compared in constant time.

If the gateway is only ever reached over your own LAN or a VPN such as Tailscale or
WireGuard, plain HTTP is fine. **If it is reachable from the internet, put it behind a
reverse proxy that terminates TLS** — Caddy, nginx, or Cloudflare Tunnel. The token is sent
in a header on every request, and a bearer token over plain HTTP across the open internet is
a password shouted across a room.

Treat the token like a password: anyone holding it can read and rewrite your settings and
spend your model provider key. Change it by restarting with a new value and updating both
devices.

## Routes

| Route | Auth | What it's for |
|---|---|---|
| `GET /health` | none | Liveness, and whether Navidrome answers. |
| `GET /v1/state` | token | Read the shared settings document. |
| `PUT /v1/state` | token | Replace it. Body must be JSON. `409` if the document has moved on. |
| `POST /v1/agent` | token | One conversation turn. Body: `{"message": "...", "player_context": "..."}`. |
| `GET /v1/device/poll` | token | A player parks here waiting for a command. `204` when there's nothing. |
| `POST /v1/device/result` | token | A player reports back what happened. |
| `PUT /v1/books/{id}` | token | Submit a prepared book to render. Streamed like a file upload. |
| `PUT /v1/books/{id}/upload` | token | A book another device made itself (the Mac, with its own voices): its prepared book, kept as a job the gateway never renders, every chapter `queued` until its audio arrives. The same book again answers with the job already there. Needs no ffmpeg. |
| `PUT /v1/books/{id}/chapters/{n}/timing` | token | That uploaded book's chapter *n* read-along timing (JSON, at most 2 MB), sent before its audio. |
| `PUT /v1/books/{id}/chapters/{n}` | token | That uploaded book's chapter *n* M4A, with `X-Baton-SHA256` (checked against the bytes received; `422` and nothing kept on a mismatch) and `X-Baton-Duration`. Bounded by the upload size limit and the books' space (`507` when full). The last chapter makes the book `ready`. `409` for a book the gateway renders itself. |
| `GET /v1/books` | token | Every book, its chapters' state, and the space used and allowed. |
| `GET /v1/books/{id}` | token | One book: per chapter `queued`, `rendering`, `encoding`, `ready` or `failed`. Each summary, here and in the listing, names its `documentID`, so a device that did not send the book can adopt it. |
| `GET /v1/books/{id}/book` | token | The prepared book the job was made from (JSON), for a device that did not send it: the chapter words for read-along, and what Render Again starts from. |
| `GET /v1/books/{id}/chapters/{n}` | token | Chapter *n*'s M4A, with `X-Baton-SHA256` and `X-Baton-Duration`. |
| `GET /v1/books/{id}/chapters/{n}/timing` | token | Chapter *n*'s read-along timing: each chunk's text with its start and end in seconds (JSON). 404 for a chapter made before timing was kept, which a client reads as "no highlight", as it does from a gateway without this route. |
| `GET /v1/books/{id}/export.m4b` | token | The whole book as one audiobook with chapter marks (ffmpeg stream copy, made on request and not kept); 409 until every chapter is ready. |
| `POST /v1/books/{id}/finished` | token | The listener reached the end; retention starts counting, and the book's `removesAt` says when it goes. |
| `DELETE /v1/books/{id}` | token | Stop rendering and remove it. |
| `POST /v1/books/complete` | token | One book task, such as a recap, by the gateway's own model (`{"system","user","max_tokens"}` → `{"text","model"}`), for a phone that reaches a model only through here. Only when that model is on your network: loopback, `.local`, a private or Tailscale address, or `BATON_LLM_LOCAL=1`; a cloud model is refused with `403` and the reason. At most 32,000 characters in, 2,048 tokens out and 120 seconds. |
| `POST /v1/speech/preview` | token | A few seconds of a voice (`{"text","voice","speed"}`), for choosing one. |
| `GET /v1/voices` | token | The voices the voice server offers, for the phone's narrator choice: `{"voices":[{"spec":"kokoro:af_heart","engine":"kokoro","id":"af_heart","language":"en"}],"sources":{"kokoro":"server"}}`. From each engine's `/v1/audio/voices`, kept 60 s; Kokoro's English voices stand in (`"built-in"`) when Kokoro does not answer. |

### The shared settings document has a revision

Both `/v1/state` answers carry two headers:

- `X-Baton-State-Revision` is which write of the document this is. It goes up by one on every
  successful PUT. A client sends the revision it read back on its own PUT; if the document has
  moved on since, the write is refused with `409 Conflict` and the client reads and merges
  again. Without this, two devices that synced at the same time would each replace the other's
  write and both would report success, because the PUT is a whole-file replace.
- `X-Baton-Server-Time` is the gateway's clock, in seconds since 1970. Every timestamp inside
  the document is expressed in it, so two devices whose own clocks disagree still order their
  edits the same way. A device an hour ahead used to win every conflict for a setting until the
  other one edited past that future time.

A PUT that sends no revision is still accepted, so a device running an older build keeps
syncing. It just cannot be told that it lost a race.

The last two are how "play something mellow" reaches your speakers: the curation tools run
on the gateway against Navidrome, and the playback verbs dispatch to whichever device is
holding the long poll. With nothing listening, those tools say so rather than pretending.

## Books

The gateway renders **document clippings** (`specs/document-clippings.md`): a Mac or a phone
imports a PDF or a text file, shapes it into a *prepared book* (chapters cut into sentence-sized
chunks, with voices and pauses), and submits it here. The gateway asks the TTS host for each
chunk, joins them, encodes each chapter to M4A with ffmpeg, and keeps them for both devices to
collect. Once submitted, nothing depends on the device that sent it: a Mac can sleep and a
phone can be locked.

- **Chapter 1 first**, so listening starts while the rest renders.
- **A TTS host that stops answering pauses the book** (its status says why) and is retried
  with backoff. The book is never finished in another voice.
- **Restarts resume.** Jobs and a content-addressed chunk cache live under `books/` beside the
  state file, so a redeploy carries on where it stopped and a re-render of the same text in the
  same voice costs no TTS at all.
- **Space is separate from parked files** and governed differently. Parked files are evicted
  oldest first, which would take chapter 1 of the book someone is halfway through. A finished
  book's audio goes `BATON_BOOKS_KEEP_FINISHED_DAYS` after it was finished, or earlier, oldest
  finished first, when space runs out. **An unfinished book is never evicted**, and a new one
  that does not fit is refused with `507` and a reason.

Synthesis and encoding need not be on the same machine: point `BATON_TTS_KOKORO_URL` at the GPU
box's Kokoro and run the gateway wherever it already runs.

## Pointing the apps at it

- **Mac** — Settings → Remote → **Baton server**. Paste the address and token, click
  **Save token**, then **Test**.
- **iPhone** — Settings → Music Friend, set **Answers come from** to **Baton server**, then
  fill in the same two fields under **Baton server**.

Neither app needs the gateway. With no gateway configured both work exactly as they always
have; sync is an upgrade, not a dependency. The full walkthrough is in
[Shared settings between your devices](../HELP.md#shared-settings-between-your-devices).

## Running it as a service

A systemd unit, for the common case of a Linux box beside Navidrome:

```ini
[Unit]
Description=Baton gateway
After=network-online.target

[Service]
ExecStart=/opt/baton/baton-gateway
EnvironmentFile=/etc/baton/gateway.env
Restart=on-failure
User=baton

[Install]
WantedBy=multi-user.target
```

Put the variables in `/etc/baton/gateway.env` (one `KEY=value` per line) and keep that file
readable only by the service user — it holds two passwords. Build the binary with
`swift build -c release` and copy `.build/release/baton-gateway` into place.

## The second executable: `baton-share`

This package also builds `baton-share`, the service behind song links for friends outside the
LAN (`https://batonmusic.app/s/<id>#<key>`). It is a separate process and a separate container,
on purpose: this gateway holds a Navidrome password and an LLM key and stays on the LAN, while
`baton-share` faces the internet and holds no secret about anyone. What they share is the
transport.

- Contract: [`specs/song-sharing.md`](../specs/song-sharing.md). Why: [`docs/plan-song-sharing.md`](../docs/plan-song-sharing.md).
  Progress: [`docs/song-sharing-todo.md`](../docs/song-sharing-todo.md).
- Code: `Sources/BatonShareServer` (service, store, player page in `Web/`), `Sources/baton-share`.
- Deploy: `deploy/deploy-share.sh`, then `scripts/publish-site.sh` so `baton_web` routes to it.

```sh
# Tests on Linux need Swift 6.1 or later: 6.0's XCTest discovery rejects the gateway's
# @MainActor test classes there. 6.0 still builds the binaries (the Docker images use it).
swift test                                           # gateway + share, 136 tests
node --test Tests/share-player/*.test.mjs            # the browser crypto, against the shared vectors
swift build --product baton-share
node Tests/share-player/e2e.mjs                      # a real browser plays a shared song (~45 s)
node Tests/share-player/e2e.mjs --nginx              # the same through deploy/nginx/default.conf
```
