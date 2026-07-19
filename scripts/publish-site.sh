#!/usr/bin/env bash
#
# Deploy the Baton website (baton.tonebox.io) to web-01.
#
# Design mirrors Tonebox's `tonebox-appcast`: a static nginx:alpine container
# behind Nginx Proxy Manager (see deploy/README.md). This script pushes the
# static files + compose config to web-01 and (re)starts the container. It does
# NOT touch the app / DMG pipeline (that's scripts/publish.sh).
#
# Usage:
#   ./scripts/publish-site.sh            # rsync the site + (re)start on web-01
#   DRY_RUN=1 ./scripts/publish-site.sh  # show what would change, touch nothing
#
# Configure the target host with env vars (or an SSH config alias):
#   WEB01=user@your-host  REMOTE_DIR=/opt/docker/baton-web
set -euo pipefail
cd "$(dirname "$0")/.."

WEB01="${WEB01:-web-01}"                          # SSH host/alias for the web box
REMOTE_DIR="${REMOTE_DIR:-/opt/docker/baton-web}"
HOSTNAME_FQDN="baton.tonebox.io"

RSYNC=(rsync -az --delete --human-readable)
[ -n "${DRY_RUN:-}" ] && RSYNC+=(--dry-run --itemize-changes)

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '  \033[2m·\033[0m %s\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# Only the files the site actually needs (not the whole website/ dir).
SITE_FILES=(
  website/index.html
  website/help.html
  website/styles.css
  website/main.js
  website/og.png
  website/apple-touch-icon.png
)
for f in "${SITE_FILES[@]}"; do
  [ -f "$f" ] || fail "missing $f — run from the repo root"
done

bold "Baton site → $WEB01:$REMOTE_DIR  ($HOSTNAME_FQDN)"

step "1/4  Ensure remote dirs"
ssh "$WEB01" "mkdir -p '$REMOTE_DIR/site' '$REMOTE_DIR/nginx'"

step "2/4  Sync static files"
"${RSYNC[@]}" "${SITE_FILES[@]}" "$WEB01:$REMOTE_DIR/site/"

step "3/4  Sync compose + nginx config"
"${RSYNC[@]}" deploy/docker-compose.yml "$WEB01:$REMOTE_DIR/docker-compose.yml"
"${RSYNC[@]}" deploy/nginx/ "$WEB01:$REMOTE_DIR/nginx/"

if [ -n "${DRY_RUN:-}" ]; then
  bold "DRY RUN — nothing changed on web-01."
  exit 0
fi

step "4/4  (Re)start container + verify"
ssh "$WEB01" "cd '$REMOTE_DIR' && docker compose up -d"

status="$(ssh "$WEB01" "docker inspect -f '{{.State.Status}}' baton_web 2>/dev/null || echo missing")"
[ "$status" = "running" ] || fail "baton_web container is '$status' (expected running)"
echo "    container baton_web: $status"

# Does the edge actually serve OUR site? A bare 200 can be the reverse proxy's
# own default page, so match on content, not status.
served="$(ssh "$WEB01" "curl -s --max-time 8 -H 'Host: $HOSTNAME_FQDN' http://127.0.0.1/ 2>/dev/null | grep -c 'Conduct <em>your</em> music' || true")"
if [ "${served:-0}" -gt 0 ]; then
  bold "✓ $HOSTNAME_FQDN is served through the edge"
else
  echo
  bold "Container is up and serving, but the edge isn't routing $HOSTNAME_FQDN to it yet."
  echo "  Finish the one-time setup in deploy/README.md:"
  echo "    · reverse-proxy host  $HOSTNAME_FQDN → baton_web:80  (+ Let's Encrypt cert)"
  echo "    · DNS A record        $HOSTNAME_FQDN → <your host's public IP>"
fi
