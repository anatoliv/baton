# baton-gateway

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
# {"status":"ok"}          — up, and Navidrome answered
# {"status":"navidrome-unreachable"}   — up, but it can't see your library
```

`/health` is the only route that doesn't need the token, which is what makes it usable as an
uptime check.

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

The four `BATON_LLM_*` variables are only for the music friend. Leave them unset and the
gateway still starts and still syncs settings; only `/v1/agent` will fail.

`BATON_STATE_FILE` defaults under the XDG data directory rather than the working directory
on purpose. Run by hand from a checkout, the working directory is fine — but under systemd
or Docker it is `/`, so the file would land somewhere surprising or unwritable and your
settings would quietly vanish on every restart. Under a container, set it explicitly and put
it on a mounted volume.

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
| `PUT /v1/state` | token | Replace it. Body must be JSON. |
| `POST /v1/agent` | token | One conversation turn. Body: `{"message": "...", "player_context": "..."}`. |
| `GET /v1/device/poll` | token | A player parks here waiting for a command. `204` when there's nothing. |
| `POST /v1/device/result` | token | A player reports back what happened. |

The last two are how "play something mellow" reaches your speakers: the curation tools run
on the gateway against Navidrome, and the playback verbs dispatch to whichever device is
holding the long poll. With nothing listening, those tools say so rather than pretending.

## Pointing the apps at it

- **Mac** — Settings → Remote → **Shared settings**. Paste the address and token, click
  **Save token**, then **Test**.
- **iPhone** — Settings → Music Friend, set **Answers come from** to **Home server**, then
  fill in the same two fields under **Home server**.

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
