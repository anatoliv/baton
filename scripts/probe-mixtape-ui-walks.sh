#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
RUN=0
OUTPUT=""
PREVIOUS=""
for ARG in "$@"; do
    [[ "$ARG" = --run ]] && RUN=1
    [[ "$PREVIOUS" = --output ]] && OUTPUT="$ARG"
    PREVIOUS="$ARG"
done
if [[ "$RUN" = 0 ]]; then exec python3 "$SCRIPT_DIR/probe-mixtape-ui-walks.py" "$@"; fi
[[ -n "$OUTPUT" ]] || { echo 'A fresh explicit output directory is required' >&2; exit 2; }
red() { echo "$*" >&2; }
yellow() { echo "$*" >&2; }
unset BATON_GATE_LOCK BATON_GATE_LOCK_TEST_BARRIER BATON_ALLOW_CONCURRENT_GATE BATON_PROBE_LOCK BATON_PROBE_LOCK_TIMEOUT BATON_PROBE_LOCK_GRACE BATON_PROBE_LOCK_TEST_RECLAIM_DELAY
source "$SCRIPT_DIR/gate-lock.sh"
gate_lock_acquire native "$OUTPUT/derived-data" "$0" "$@"
source "$SCRIPT_DIR/probe-lib.sh"
if probe_lock_acquire 0; then :; else RC=$?; gate_lock_release; exit "$RC"; fi
# CPU tests extract only this tail; they never invoke wrapper/guard acquisition.
# BEGIN_OWNED_NATIVE_CONTROLLER
wait_interrupted=0
request_cancel(){ wait_interrupted=1; printf '%s\n' requested > "${OUTPUT}.cancel-requested"; }
trap request_cancel INT TERM HUP
python3 -B "$SCRIPT_DIR/probe-mixtape-ui-walks.py" "$@" &
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
if python3 -B "$SCRIPT_DIR/probe-mixtape-ui-walks.py" --qualify-release "$OUTPUT"; then
    probe_lock_release; gate_lock_release; exit "$RC"
fi
printf '%s\n' 'BLOCKED: native cleanup unqualified; kernel/probe custody retained for coordinator. No foreign or reused PID signalling.' >&2
# No EXIT trap: this shell/lockf stays alive until root reconciles exact ownership.
while :; do sleep 30; done
