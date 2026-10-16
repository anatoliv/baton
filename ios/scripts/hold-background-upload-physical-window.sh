#!/bin/bash
# Adaptation of the historical TBX-9142 holder. No device commands or child jobs.
# Coordinator owns acceptance/restore; this shell keeps ordinary guards continuous.
set -uo pipefail
umask 077
if [ "$#" -ne 3 ] || [ "$1" != --coordinated-go ] ||
   [[ ! "$2" =~ ^TBX-[0-9]+$ ]]; then
  printf '%s\n' 'Usage: holder --coordinated-go TBX-id private-empty-window' >&2
  exit 2
fi
deployment=$2
window=$3
repo=$(cd "$(dirname "$0")/../.." && pwd) || exit 1
# Metadata only. Existing private directories/receipts cannot be reused as attempts.
python3 -B - "$window" <<'PY' || exit 1
import os,stat,sys
from pathlib import Path
p=Path(sys.argv[1]); s=p.lstat()
assert p.is_absolute() and p.resolve()==p and stat.S_ISDIR(s.st_mode)
assert s.st_uid==os.getuid() and stat.S_IMODE(s.st_mode)==0o700
assert not any(p.iterdir())
PY
cd "$repo" || exit 1
red(){ printf '%s\n' "$*" >&2; }
yellow(){ printf '%s\n' "$*" >&2; }
cancelled=0
request_stop(){ cancelled=1; }
# No EXIT release trap. A handled interruption stops acceptance, never custody.
trap request_stop INT TERM HUP
unset BATON_ALLOW_CONCURRENT_GATE BATON_GATE_LOCK BATON_PROBE_LOCK \
  BATON_PROBE_LOCK_TIMEOUT BATON_PROBE_LOCK_GRACE BATON_PROBE_LOCK_TEST_RECLAIM_DELAY
source scripts/gate-lock.sh
gate_lock_acquire physical-background-upload "$window" "$0" "$@" || exit 1
source scripts/probe-lib.sh
if probe_lock_acquire 0; then :; else
  rc=$?; gate_lock_release; exit "$rc"
fi
started=$SECONDS
started_epoch=$(date +%s)
acceptance_seconds=900
planning_seconds=1200
# Metadata failure after admission must not drop either guard.
retain(){ while :; do sleep 1; done; }
printf '{"deployment":"%s","holderPID":%s,"startedAtEpoch":%s,"acceptanceCutoffEpoch":%s,"planningBoundaryEpoch":%s}\n' \
  "$deployment" "$$" "$started_epoch" "$((started_epoch+acceptance_seconds))" \
  "$((started_epoch+planning_seconds))" > "$window/acquired.json" || retain
acceptance_stopped=0
boundary_recorded=0
while :; do
  elapsed=$((SECONDS-started))
  if [ "$acceptance_stopped" -eq 0 ] &&
     { [ "$cancelled" -eq 1 ] || [ "$elapsed" -ge "$acceptance_seconds" ]; }; then
    acceptance_stopped=1
    printf '{"acceptanceStopped":true,"cancelled":%s}\n' \
      "$([ "$cancelled" -eq 1 ] && printf true || printf false)" \
      > "$window/acceptance-stopped.json" || retain
  fi
  if [ "$boundary_recorded" -eq 0 ] && [ "$elapsed" -ge "$planning_seconds" ]; then
    boundary_recorded=1
    printf '{"holdDeadlineExceeded":true,"coordinatorReconciliationRequired":true,"guardsRetained":true}\n' \
      > "$window/expired.json" || retain
  fi
  # Coordinator writes this only after actual TestFlight restore/readback AND
  # owned CLI cleanup. It is a confirmation, never proof obtained by this shell.
  # Exact live holder PID and fresh private window prevent stale/reused signals.
  if python3 -B - "$window/restore-complete" "$$" <<'PY'
import os,stat,sys
from pathlib import Path
try:
    p=Path(sys.argv[1]); s=p.lstat()
    assert stat.S_ISREG(s.st_mode) and s.st_uid==os.getuid()
    assert stat.S_IMODE(s.st_mode)==0o600 and s.st_size<=128
    assert p.read_bytes()==('restored-and-owned-cleanup-verified:'+sys.argv[2]+'\n').encode()
except Exception:
    raise SystemExit(1)
PY
  then
    # Use ordinary own-release only, and fail closed on changed/unreadable ownership.
    [ "$PROBE_LOCK_HELD" = 1 ] && [ -n "$GATE_LOCK_HELD" ] &&
      [ "$(cut -d' ' -f1 "$PROBE_LOCK/owner" 2>/dev/null)" = "$$" ] &&
      [ "$(sed -n '1p' "$GATE_LOCK" 2>/dev/null)" = "$$" ] || retain
    probe_lock_release || retain
    gate_lock_release || retain
    [ ! -e "$PROBE_LOCK" ] && [ -f "$GATE_LOCK" ] && [ ! -s "$GATE_LOCK" ] || retain
    printf '{"releasedAfterRestoreSignal":true,"ownedCleanupConfirmed":true}\n' \
      > "$window/released.json" || retain
    exit 0
  fi
  sleep 1
done
