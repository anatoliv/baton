# shellcheck shell=bash
# Sourced by scripts/publish-site.sh, gateway/deploy/deploy-share.sh and scripts/probe-share-api.sh.
#
# Is the estate's edge gate still on?
#
# NPM refuses a request that names a CF-Connecting-IP without the secret header Cloudflare adds in
# every estate zone, then strips that header (amnesia-ops docs/operations/npm-edge-auth.md). That
# gate is what makes NPM's X-Real-IP, and so every per-network limit in baton-share, worth
# believing: without it anyone who reaches the origin directly can name any client address and
# rotate the limits per request (E-9). Baton does not own the gate, and its rollback is one file
# copy, so Baton checks it: straight to NPM's published HTTPS address from the web host, bypassing
# Cloudflare, with a made-up CF-Connecting-IP from the documentation range. Refused (403) is the
# gate; anything served means it is gone. A second request without the header must be served, or
# the 403 proves nothing (an access list or an outage would refuse both).
#
# Nothing here reads, sends or prints the gate's secret: the probe is the request that does NOT
# carry it.

EDGE_GATE_FORGED_IP="192.0.2.1"   # TEST-NET-1 (RFC 5737): never a real visitor

# NPM's published HTTPS address on the web host, ready for curl --resolve. HTTPS may be published
# on a specific host address (127.0.0.1 refused both probes on 2026-10-03 while the public routes
# worked), so read the binding rather than writing a LAN address into this public repository.
npm_https_address() {   # $1 = ssh host
  local address
  address="$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$1" \
    "docker inspect -f '{{range (index .NetworkSettings.Ports \"443/tcp\")}}{{println .HostIp}}{{end}}' nginx-proxy-manager" \
    | awk 'NF { print; exit }')" || {
    echo "  Cannot read the HTTPS binding on $1; origin routing is unmeasured." >&2
    return 1
  }
  case "$address" in
    0.0.0.0|::) address=127.0.0.1 ;;
    ""|*[!0-9a-fA-F:.]*)
      echo "  No usable published HTTPS address; origin routing is unmeasured." >&2
      return 1 ;;
  esac
  [[ "$address" != *:* ]] || address="[$address]"
  printf '%s\n' "$address"
}

# Returns 0 when every host refuses the forged request and serves the plain one, 1 when any host
# serves the forged request (the gate is off), 2 when the gate could not be measured.
edge_gate_check() {   # $1 = ssh host, then the public hostnames
  local ssh_host="$1" address host forged plain rc=0
  shift
  address="$(npm_https_address "$ssh_host")" || return 2
  for host in "$@"; do
    forged="$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$ssh_host" \
      "curl -ksS -o /dev/null --max-time 8 --resolve '$host:443:$address' \
       -H 'CF-Connecting-IP: $EDGE_GATE_FORGED_IP' -w '%{http_code}' https://$host/" 2>/dev/null)" || true
    plain="$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$ssh_host" \
      "curl -ksS -o /dev/null --max-time 8 --resolve '$host:443:$address' \
       -w '%{http_code}' https://$host/" 2>/dev/null)" || true
    [[ "$forged" =~ ^[0-9]{3}$ ]] || forged=none
    [[ "$plain" =~ ^[0-9]{3}$ ]] || plain=none
    if [ "$forged" = 403 ] && [ "$plain" = 200 ]; then
      printf '\033[32m  ✓ %s: a forged CF-Connecting-IP straight to the origin is refused (403); the edge gate is on\033[0m\n' "$host"
    elif [[ "$forged" =~ ^[23] ]]; then
      printf '\033[31m  ✗ %s: a forged CF-Connecting-IP straight to the origin answered %s, not 403.\033[0m\n' "$host" "$forged" >&2
      echo "    The estate edge gate is off; E-9 is open: anyone reaching the origin can name any client" >&2
      echo "    address. See docs/infra/2026-10-22-production-edge-review.md (F5) and amnesia-ops npm-edge-auth.md." >&2
      rc=1
    else
      echo "  ? $host: the edge gate is unmeasured (forged request: $forged, plain request: $plain)." >&2
      [ "$rc" -eq 1 ] || rc=2
    fi
  done
  return "$rc"
}
