# Deploying baton.tonebox.io

The site is four static files (`index.html`, `help.html`, `styles.css`,
`main.js`) plus two images (`og.png`, `apple-touch-icon.png`). It is served by a
small `nginx:alpine` container behind a reverse proxy that terminates TLS —
here, [Nginx Proxy Manager (NPM)](https://nginxproxymanager.com/) on a
self-hosted host, on a shared external `proxy_net` docker network.

- **Container:** `baton_web` (`nginx:1.27-alpine`), on `proxy_net`, no host ports.
- **Deploy dir on the host:** `/opt/docker/baton-web/` (`./site/`, `./nginx/`, `docker-compose.yml`).
- **Edge:** the proxy routes `baton.tonebox.io → baton_web:80`, TLS via Let's Encrypt.

## Configure your host

The deploy script talks to the host over SSH. Point it at your box with env
vars (or an SSH config alias):

```sh
export WEB01=user@your-host        # SSH target for the web host
export REMOTE_DIR=/opt/docker/baton-web
```

### The actual host (web-01)

Baton's site is a tenant on **web-01**, the same shared self-hosted homelab box
that hosts Tonebox's Sparkle appcast — Baton mirrors that setup:
`tonebox_appcast → /opt/docker/tonebox-appcast` becomes
`baton_web → /opt/docker/baton-web`, both nginx containers on `proxy_net` behind
the same Nginx Proxy Manager edge.

web-01 **does not resolve by name** — it's reached over the LAN by IP with SSH
key auth (passwordless sudo). So there is no `web-01` DNS entry or default SSH
alias; you must pass the target explicitly:

```sh
WEB01=anatoli@<web-01-lan-ip> ./scripts/publish-site.sh
```

The concrete LAN IP (and host-key fingerprint) are deliberately **kept out of
this public repo** — they live in the private Tonebox infra notes
(`~/Projects/tonebox/infra/SERVERS.md`, the `web-01` row). Set `WEB01` from there
per-invocation rather than committing it, or add a `web-01` alias to your local
`~/.ssh/config`. Deploys must run from a machine on the same LAN.

## Routine deploy

From the repo root:

```sh
DRY_RUN=1 ./scripts/publish-site.sh   # preview the file changes
./scripts/publish-site.sh             # rsync + (re)start baton_web + verify
```

It syncs the site into `$REMOTE_DIR/site/`, syncs the compose + nginx config,
runs `docker compose up -d`, and health-checks the edge.

## One-time setup

1. **DNS** — add an **A record** `baton.tonebox.io → <your host's public IP>`.
   If your reverse proxy issues Let's Encrypt certs via HTTP-01, the record
   must be **DNS-only** (not proxied) so the challenge reaches the origin.

2. **First push** — creates the dir and starts the container:

   ```sh
   ./scripts/publish-site.sh
   ```

   The edge check reports non-200 until the proxy host (step 3) exists; expected.

3. **Reverse proxy** — add a proxy host:
   - Domain: `baton.tonebox.io`
   - Forward to: `baton_web` port `80` (scheme `http`) — the proxy and
     `baton_web` share `proxy_net`, so it resolves the container by name.
   - **SSL:** request a Let's Encrypt cert, Force SSL + HTTP/2.

4. **Verify:**

   ```sh
   curl -sI https://baton.tonebox.io/ | head -1          # 200
   curl -s https://baton.tonebox.io/help.html | grep -o '<title>[^<]*'
   ```

## Notes

- `proxy_net` is expected to already exist on the host (shared by every proxied
  service); the compose file references it as `external: true` and never
  creates it. If you don't have one: `docker network create proxy_net`.
- HTML is served `Cache-Control: no-cache` (redeploys show immediately); CSS/JS
  and images get a 1-hour cache. Files aren't content-hashed, so keep caches
  modest or hard-refresh after a deploy.
- This is independent of `scripts/publish.sh`, which ships the macOS **app**
  (DMG + Sparkle appcast).
