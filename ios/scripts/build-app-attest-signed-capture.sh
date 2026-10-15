#!/bin/bash
# PREPARATION ONLY until fresh coordinated GO and independent static acceptance.
set -uo pipefail
umask 077
ROOT=/private/tmp/baton-tbx8711-fresh-capture-20261008-2
REPO=/private/tmp/baton-tbx-8711-fresh-capture
if [ "$#" -ne 1 ] || [ "$1" != --coordinated-go ]; then
  printf '%s\n' 'Explicit current coordinated GO required; no operation started.' >&2
  exit 2
fi
cd "$REPO" || exit 1
red(){ printf '%s\n' "$*" >&2; }
yellow(){ printf '%s\n' "$*" >&2; }
wait_interrupted=0
request_cancel(){ wait_interrupted=1; printf '%s\n' 'requested' > "$ROOT/cancel-requested" || :; }
trap request_cancel INT TERM HUP
# Preserve the gate's own lockf reentry variables. Refuse overrides, never fake ownership.
unset BATON_ALLOW_CONCURRENT_GATE BATON_GATE_LOCK BATON_PROBE_LOCK \
  BATON_PROBE_LOCK_TIMEOUT BATON_PROBE_LOCK_GRACE BATON_PROBE_LOCK_TEST_RECLAIM_DELAY \
  BATON_GATE_LOCK_TEST_BARRIER
python3 -B "$REPO/ios/scripts/run-app-attest-signed-capture-build.py" --preflight-only || exit 1
source scripts/gate-lock.sh
gate_lock_acquire signed-minimal-capture-build "$ROOT" "$0" "$@" || exit 1
source scripts/probe-lib.sh
if probe_lock_acquire 0; then :; else
  rc=$?; gate_lock_release; exit "$rc"
fi
# No EXIT release trap: controller absence/unknown cleanup keeps this shell and lockf alive.
python3 -B "$REPO/ios/scripts/run-app-attest-signed-capture-build.py" --coordinated-go > "$ROOT/controller.log" 2>&1 &
controller=$!
while :; do
  wait_interrupted=0
  if wait "$controller"; then rc=0; break; else
    rc=$?
    [ -e "$ROOT/driver-finished" ] && break
    # Retry only an actual handled shell interruption. A signaled terminal child
    # can return >128 repeatedly; that must enter the sleeping custody hold.
    # Waiting again never signals or identifies a reusable numeric PID.
    if [ "$rc" -gt 128 ] && [ "$wait_interrupted" -eq 1 ]; then continue; fi
    break
  fi
done
if python3 -B "$REPO/ios/scripts/run-app-attest-signed-capture-build.py" --qualify-release > "$ROOT/release-readback.log" 2>&1; then
  probe_lock_release
  gate_lock_release
  exit "$rc"
fi
printf '%s\n' 'BLOCKED: owned cleanup unverified. Guards retained; root must reconcile original owned group/inspection state. No automatic release or further SDK operation.' >&2
# This is a deliberate fail-closed custody hold, not a timed job or retry loop.
# INT/TERM/HUP only request cancellation; none authorizes releasing unknown ownership.
while :; do sleep 30; done
