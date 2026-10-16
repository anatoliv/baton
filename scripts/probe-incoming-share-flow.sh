#!/bin/bash
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
RUN=0
for ARG in "$@"; do [[ "$ARG" = --run ]] && RUN=1; done
if [[ "$RUN" = 0 ]]; then exec python3 "$SCRIPT_DIR/probe-incoming-share-flow.py" "$@"; fi
unset BATON_PROBE_LOCK BATON_PROBE_LOCK_TIMEOUT BATON_PROBE_LOCK_GRACE BATON_PROBE_LOCK_TEST_RECLAIM_DELAY
source "$SCRIPT_DIR/probe-lib.sh"
probe_lock_acquire 0
# Keep the exact output identity in the holder, including early driver death.
if OUTPUT=$(mktemp -d /private/tmp/baton-incoming-ui-XXXXXX); then :; else RC=$?; probe_lock_release; exit "$RC"; fi
if chmod 700 "$OUTPUT"; then :; else RC=$?; probe_lock_release; exit "$RC"; fi
export BATON_INCOMING_OUTPUT="$OUTPUT"
# BEGIN_OWNED_NATIVE_CONTROLLER
wait_interrupted=0
request_cancel(){ wait_interrupted=1; printf '%s\n' requested > "${OUTPUT}.cancel-requested" || true; }
trap request_cancel INT TERM HUP
python3 -B "$SCRIPT_DIR/probe-incoming-share-flow.py" "$@" &
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
    probe_lock_release; exit "$RC"
fi
printf '%s\n' 'BLOCKED: incoming fixture cleanup unqualified; probe custody retained for coordinator. No numeric PID signalling.' >&2
while :; do sleep 30; done
