#!/usr/bin/env bash
#
# Is the share API answering through the whole public chain?
#
#   ./scripts/probe-share-api.sh                 # both hostnames, through Cloudflare
#   EDGE_GATE=1 WEB01=<ssh alias> ./scripts/probe-share-api.sh   # also the edge gate, over SSH
#
# Read-only, from anywhere with HTTPS: per hostname, /v1/share/config must answer 200 with JSON,
# `no-store` and sharing enabled, and the admin report must be a 404 from outside. Exit 0 when
# every check passes, 1 otherwise. It is the probe amnesia-ops monitoring should run from outside
# the home network (review owner step O7); until then, run it after a site or share deploy.
set -euo pipefail
cd "$(dirname "$0")/.."

read -r -a HOSTS <<<"${SHARE_PROBE_HOSTS:-batonmusic.app baton.tonebox.io}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/baton-share-probe.XXXXXX")"
trap 'rm -r "$WORK"' EXIT
failed=0

pass() { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
bad()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; failed=1; }

for host in "${HOSTS[@]}"; do
  status="$(curl -sS -o "$WORK/config" -D "$WORK/headers" -w '%{http_code}' --max-time 15 \
    "https://$host/v1/share/config" 2>/dev/null || true)"
  type="$(tr -d '\r' <"$WORK/headers" 2>/dev/null | awk -F': ' 'tolower($1) == "content-type" { print $2; exit }')"
  cache="$(tr -d '\r' <"$WORK/headers" 2>/dev/null | awk -F': ' 'tolower($1) == "cache-control" { print $2; exit }')"
  if [ "$status" != 200 ]; then
    bad "$host/v1/share/config answered ${status:-nothing}, expected 200"
  elif [[ "$type" != application/json* ]]; then
    bad "$host/v1/share/config is '${type:-untyped}', expected application/json"
  elif [ "$cache" != no-store ]; then
    bad "$host/v1/share/config has Cache-Control '${cache:-none}', expected no-store"
  elif ! python3 -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1])).get("enabled") is True else 1)' "$WORK/config" 2>/dev/null; then
    bad "$host/v1/share/config does not say sharing is enabled"
  else
    pass "$host/v1/share/config: 200, JSON, no-store, enabled"
  fi
  admin="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://$host/v1/share/admin/stats" 2>/dev/null || true)"
  if [ "$admin" = 404 ]; then
    pass "$host/v1/share/admin/stats: 404 from outside"
  else
    bad "$host/v1/share/admin/stats answered ${admin:-nothing}, expected 404"
  fi
done

if [ -n "${EDGE_GATE:-}" ]; then
  if [ -z "${WEB01:-}" ]; then
    bad "EDGE_GATE=1 needs WEB01, the web host's SSH alias (the same one publish-site.sh uses)"
  else
    # shellcheck source=scripts/edge-gate.sh
    . "$PWD/scripts/edge-gate.sh"
    edge_gate_check "$WEB01" "${HOSTS[@]}" || failed=1
  fi
fi

[ "$failed" -eq 0 ] && printf '\033[1mshare API answering through the public chain\033[0m\n'
exit "$failed"
