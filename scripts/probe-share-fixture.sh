#!/bin/bash
# Foreground supervisor; never take the screen while another probe owns it.
set -euo pipefail
unset BATON_PROBE_LOCK BATON_PROBE_LOCK_TIMEOUT BATON_PROBE_LOCK_GRACE BATON_PROBE_LOCK_TEST_RECLAIM_DELAY
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
for ARG in "$@"; do
  if [ "$ARG" = --check-only ]; then
    exec python3 "$SCRIPT_DIR/probe-share-fixture.py" "$@"
  fi
done
source "$SCRIPT_DIR/probe-lib.sh"
probe_lock_acquire 0
trap 'probe_lock_release' EXIT
python3 "$SCRIPT_DIR/probe-share-fixture.py" "$@" &
FIXTURE_PID=$!
trap 'kill -TERM "$FIXTURE_PID" 2>/dev/null || true; wait "$FIXTURE_PID" || true; probe_lock_release; exit 130' INT TERM HUP
set +e
wait "$FIXTURE_PID"
RC=$?
set -e
exit "$RC"
