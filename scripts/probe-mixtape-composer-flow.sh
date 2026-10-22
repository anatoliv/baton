#!/bin/bash
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
RUN=0
OUTPUT=""
PREVIOUS=""
for ARG in "$@"; do
    [[ "$ARG" = --run ]] && RUN=1
    [[ "$PREVIOUS" = --output ]] && OUTPUT="$ARG"
    PREVIOUS="$ARG"
done
if [[ "$RUN" = 0 ]]; then exec python3 "$SCRIPT_DIR/probe-mixtape-composer-flow.py" "$@"; fi
[[ -n "$OUTPUT" ]] || { echo 'A fresh explicit output directory is required' >&2; exit 2; }
red() { echo "$*" >&2; }
yellow() { echo "$*" >&2; }
unset BATON_GATE_LOCK BATON_GATE_LOCK_TEST_BARRIER BATON_ALLOW_CONCURRENT_GATE BATON_PROBE_LOCK BATON_PROBE_LOCK_TIMEOUT BATON_PROBE_LOCK_GRACE BATON_PROBE_LOCK_TEST_RECLAIM_DELAY
source "$SCRIPT_DIR/gate-lock.sh"
gate_lock_acquire native "$OUTPUT/derived-data" "$0" "$@"
source "$SCRIPT_DIR/probe-lib.sh"
if probe_lock_acquire 0; then :; else RC=$?; gate_lock_release; exit "$RC"; fi
# BEGIN_OWNED_NATIVE_CONTROLLER
wait_interrupted=0
request_cancel(){ wait_interrupted=1; printf '%s\n' requested > "${OUTPUT}.cancel-requested" || true; }
trap request_cancel INT TERM HUP
python3 -B "$SCRIPT_DIR/probe-mixtape-composer-flow.py" "$@" &
OWN_PID=$!
set +e
while :; do
    wait_interrupted=0
    if wait "$OWN_PID"; then RC=0; break; else
        RC=$?
        if [[ "$RC" -gt 128 && "$wait_interrupted" = 1 ]]; then continue; fi
        break
    fi
done
if python3 -B "$SCRIPT_DIR/mixtape_owned_lifecycle.py" --qualify-release "$OUTPUT"; then
    probe_lock_release; gate_lock_release
    # The qualified release, after both locks are let go.
    # Read from the lock itself: released when its owner record no longer names this shell.
    probe_released=false; [ "$(cut -d' ' -f1 "${PROBE_LOCK:-/nonexistent}/owner" 2>/dev/null)" != "$$" ] && probe_released=true
    gate_released=false; [ -z "${GATE_LOCK_HELD:-}" ] && gate_released=true
    { printf '{"qualified": true, "custodyReleaseQualified": true, "gateLock": "%s", "gateLockReleased": %s, "probeLock": "%s", "probeLockReleased": %s}\n' \
        "${GATE_LOCK:-}" "$gate_released" "${PROBE_LOCK:-}" "$probe_released" > "$OUTPUT/native-lock-release.json"; } 2>/dev/null || true
    exit "$RC"
fi
printf '%s\n' 'BLOCKED: composer fixture cleanup unqualified; gate/probe custody retained for coordinator. No numeric PID signalling.' >&2
while :; do sleep 30; done
