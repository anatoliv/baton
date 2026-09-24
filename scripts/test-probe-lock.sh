#!/bin/bash
#
# Probe checks on this machine run one at a time, and a dead owner must not wedge the next.
# (TBX-7383)
#
# WHY THIS EXISTS. On 2026-09-24 a review-queue audit's `probe-handoff-e2e.sh` failed at
# "Not now pressed" with a System Events error (-1719) while another agent's probe checks ran
# on the same screen; a quiet re-run passed. The probes keep their state apart (own suites,
# ports, containers) but share the screen, the frontmost app and the keyboard, so two at once
# can fail each other and photograph each other. scripts/probe-lib.sh now has a machine-wide
# lock that every probe script takes; this proves it serialises, names what it waits on,
# reclaims what a killed run left behind, gives up with its own status, and cannot be
# released by a process that does not hold it.
#
# It drives the REAL functions in scripts/probe-lib.sh through BATON_PROBE_LOCK, pointed at a
# throwaway path: a guard that reimplements its subject can pass while the subject is broken.
# Nothing here launches the app or touches the real /tmp/baton-probe.lock.
#
# No Xcode, no app, no network, about fifteen seconds.
set -uo pipefail
cd "$(dirname "$0")/.." || exit
ROOT="$PWD"
LIB="$ROOT/scripts/probe-lib.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '\033[32mok    %s\033[0m\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '\033[31mFAIL  %s\033[0m\n' "$1"; }

WORK="$(mktemp -d)"
export BATON_PROBE_LOCK="$WORK/probe.lock"
export LIB WORK
HOLDERS=()
cleanup() { for p in "${HOLDERS[@]:-}"; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
export -f now

# ---- 1. two runs started together serialise, and the second names the first ----------------
bash -c '. "$LIB"; probe_lock_acquire 30 || exit 9; now > "$WORK/a.start"; sleep 3; now > "$WORK/a.end"; probe_lock_release' \
  2>"$WORK/a.err" &
A=$!; HOLDERS+=("$A")
sleep 0.5
bash -c '. "$LIB"; probe_lock_acquire 30 || exit 9; now > "$WORK/b.start"; probe_lock_release' 2>"$WORK/b.err"
b_rc=$?
wait "$A"; a_rc=$?
if [ "$a_rc" = 0 ] && [ "$b_rc" = 0 ] && [ -s "$WORK/a.end" ] && [ -s "$WORK/b.start" ] &&
   awk -v e="$(cat "$WORK/a.end")" -v s="$(cat "$WORK/b.start")" 'BEGIN { exit !(s >= e) }'; then
  ok "serialises: the second run started only after the first released"
else
  bad "serialises: a_rc=$a_rc b_rc=$b_rc a.end=$(cat "$WORK/a.end" 2>/dev/null) b.start=$(cat "$WORK/b.start" 2>/dev/null)"
fi
if grep -q "waiting for pid $A " "$WORK/b.err" && grep -q "acquired after waiting [0-9]*s for pid $A" "$WORK/b.err"; then
  ok "the waiting run names the holder's pid, then says how long it waited"
else
  bad "the waiting run did not name holder pid $A: $(tr '\n' '|' < "$WORK/b.err")"
fi
[ ! -e "$BATON_PROBE_LOCK" ] && ok "released: no lock left after both runs" || bad "a lock was left behind after both runs"

# ---- 2. a lock whose owner died is reclaimed ------------------------------------------------
sh -c 'exit 0' & DEAD=$!; wait "$DEAD"
mkdir "$BATON_PROBE_LOCK" && echo "$DEAD ghost-probe.sh" > "$BATON_PROBE_LOCK/owner"
bash -c '. "$LIB"; probe_lock_acquire 10 || exit 9; cut -d" " -f1 "$BATON_PROBE_LOCK/owner" > "$WORK/c.owner"; echo "$$" > "$WORK/c.pid"; probe_lock_release' 2>"$WORK/c.err"
c_rc=$?
if [ "$c_rc" = 0 ] && grep -q "reclaimed a stale lock left by pid $DEAD (ghost-probe.sh)" "$WORK/c.err" &&
   [ "$(cat "$WORK/c.owner")" = "$(cat "$WORK/c.pid")" ]; then
  ok "a killed run's lock (owner pid $DEAD dead) is reclaimed and named"
else
  bad "stale lock not reclaimed: rc=$c_rc $(tr '\n' '|' < "$WORK/c.err")"
fi

# ---- 3. a lock with no owner written (died between mkdir and write) is reclaimed ------------
mkdir "$BATON_PROBE_LOCK"
BATON_PROBE_LOCK_GRACE=2 bash -c '. "$LIB"; probe_lock_acquire 20 || exit 9; probe_lock_release' 2>"$WORK/d.err"
d_rc=$?
if [ "$d_rc" = 0 ] && grep -q "no owner written" "$WORK/d.err"; then
  ok "an ownerless lock is reclaimed after the grace period"
else
  bad "ownerless lock not reclaimed: rc=$d_rc $(tr '\n' '|' < "$WORK/d.err")"
fi

# ---- 4. a live holder past the timeout: give up with status 3, naming it -------------------
bash -c '. "$LIB"; probe_lock_acquire 5 || exit 9; touch "$WORK/h.held"; sleep 8; probe_lock_release' 2>/dev/null &
H=$!; HOLDERS+=("$H")
for _ in $(seq 1 30); do [ -e "$WORK/h.held" ] && break; sleep 0.1; done
bash -c '. "$LIB"; probe_lock_acquire 2' 2>"$WORK/e.err"
e_rc=$?
if [ "$e_rc" = 3 ] && grep -q "gave up after 2s; still held by pid $H" "$WORK/e.err"; then
  ok "times out with status 3 and names the live holder"
else
  bad "timeout: rc=$e_rc (want 3) $(tr '\n' '|' < "$WORK/e.err")"
fi

# ---- 5. only the holder can release ---------------------------------------------------------
bash -c '. "$LIB"; probe_lock_release; PROBE_LOCK_HELD=1; probe_lock_release'
if [ -d "$BATON_PROBE_LOCK" ] && [ "$(cut -d' ' -f1 "$BATON_PROBE_LOCK/owner")" = "$H" ]; then
  ok "a process that does not hold the lock cannot release it, even claiming it does"
else
  bad "the lock was released by a non-holder"
fi
wait "$H"
[ ! -e "$BATON_PROBE_LOCK" ] && ok "the holder's own release frees it" || bad "the holder's release left the lock"

# ---- 7. a dead holder and two waiters, one slow to act on it: the holds never overlap -------
# TBX-7388. The slow waiter judges the lock stale first, then stalls (the test-only delay sits
# between that judgement and the reclaim). Meanwhile the fast waiter reclaims it and takes a
# fresh lock. When the slow one resumes it must not remove that fresh, live lock.
sh -c 'exit 0' & DEAD2=$!; wait "$DEAD2"
mkdir "$BATON_PROBE_LOCK" && echo "$DEAD2 dead-probe.sh" > "$BATON_PROBE_LOCK/owner"
HOLD='. "$LIB"; probe_lock_acquire 30 || exit 9; now > "$WORK/$1.acq"; sleep 4; now > "$WORK/$1.rel"; probe_lock_release'
BATON_PROBE_LOCK_TEST_RECLAIM_DELAY=2 bash -c "$HOLD" _ slow 2>"$WORK/slow.err" &
SLOW=$!; HOLDERS+=("$SLOW")
sleep 0.3
bash -c "$HOLD" _ fast 2>"$WORK/fast.err" &
FAST=$!; HOLDERS+=("$FAST")
wait "$SLOW"; slow_rc=$?; wait "$FAST"; fast_rc=$?
reclaims="$(cat "$WORK/slow.err" "$WORK/fast.err" | grep -c 'reclaimed a stale lock')"
if [ "$slow_rc" = 0 ] && [ "$fast_rc" = 0 ] &&
   awk -v a1="$(cat "$WORK/slow.acq")" -v r1="$(cat "$WORK/slow.rel")" \
       -v a2="$(cat "$WORK/fast.acq")" -v r2="$(cat "$WORK/fast.rel")" \
       'BEGIN { exit !(r1 <= a2 || r2 <= a1) }'; then
  ok "a slow waiter cannot reclaim a lock another waiter has just taken: the holds do not overlap"
else
  bad "overlapping holds: slow $(cat "$WORK/slow.acq" 2>/dev/null)-$(cat "$WORK/slow.rel" 2>/dev/null) fast $(cat "$WORK/fast.acq" 2>/dev/null)-$(cat "$WORK/fast.rel" 2>/dev/null) (rc $slow_rc/$fast_rc)"
fi
[ "$reclaims" = 1 ] && ok "one stale lock is reclaimed exactly once" \
  || bad "the stale lock was reclaimed $reclaims times: $(cat "$WORK/slow.err" "$WORK/fast.err" | tr '\n' '|')"
[ ! -e "$BATON_PROBE_LOCK" ] && ok "no lock left after the two waiters" || bad "a lock was left after the two waiters"

# ---- 6. wiring: both probe scripts take the lock and give it back --------------------------
for s in probe-menubar-freeze.sh probe-handoff-e2e.sh; do
  if grep -q '^probe_lock_acquire || exit 3' "scripts/$s" && grep -q 'probe_lock_release' "scripts/$s"; then
    ok "wiring: $s takes the lock (exit 3 on timeout) and releases it"
  else
    bad "wiring: $s does not take and release the probe lock"
  fi
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
