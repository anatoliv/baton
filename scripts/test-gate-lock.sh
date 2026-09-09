#!/bin/bash
#
# Two gates on this machine must not kill each other, and a dead one must not wedge it.
# (TBX-5291)
#
# WHY THIS EXISTS. On 2026-09-08 at 17:20 a gate died at the Mac suite with the BATON-DIAG
# runner-death signature, and the backtrace named `_handleAEQuit`: a Quit Apple Event from
# outside the process. A Mac release had started four seconds after this run reached its
# Mac stage; both app-hosted the same Baton.app out of /tmp/baton-dd, and launching the
# second made LaunchServices quit the first. The victim reported a runner death against an
# unrelated test, so the diagnosis cost an afternoon and landed on innocent code.
#
# The guard in scripts/test.sh refuses the second run and names the holder. This proves it
# does, and proves the harder half: that the pidfile a killed gate leaves behind does not
# block every later run. A lock that survives a `pkill` and wedges the machine would be
# worse than the bug.
#
# It drives the REAL acquire in scripts/test.sh through the BATON_GATE_LOCK and
# BATON_GATE_LOCK_PROBE hatches, the same way test-gate-counts.sh and test-lints.sh drive
# their subjects: a guard that reimplements its subject can pass while the subject is
# broken. Nothing here builds, and nothing touches the real /tmp/baton-gate.lock.
#
# No Xcode, no simulator, no network, about three seconds.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
GATE="$ROOT/scripts/test.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '\033[32mok    %s\033[0m\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '\033[31mFAIL  %s\033[0m\n' "$1"; }

WORK="$(mktemp -d)"
LOCK="$WORK/gate.lock"
HOLDER=""
cleanup() { [ -n "$HOLDER" ] && kill -9 "$HOLDER" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# A second gate that stops at the lock. SKIP_IOS keeps it off the phone, and the refusal
# comes before xcodegen, so a run that is going to be refused costs nothing.
contend() {   # prints the refusal, returns its status
  BATON_GATE_LOCK="$LOCK" BATON_DERIVED_DATA="$WORK/dd" SKIP_IOS=1 \
    BATON_GATE_LOCK_PROBE=0 "$GATE" 2>&1
}

start_holder() {   # $1 = seconds to hold
  BATON_GATE_LOCK="$LOCK" BATON_DERIVED_DATA="$WORK/dd-holder" \
    BATON_GATE_LOCK_PROBE="$1" "$GATE" >"$WORK/holder.out" 2>&1 &
  HOLDER=$!
  # Wait for the lock to appear rather than sleeping a guessed interval.
  local i
  for i in $(seq 1 100); do
    [ -s "$LOCK" ] && return 0
    sleep 0.05
  done
  return 1
}

# --- 1. A live holder is refused, and named -------------------------------------------

if ! start_holder 20; then
  bad "the holder never took the lock; nothing below can be trusted"
  printf '%d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

start_s=$(date +%s)
out="$(contend)"; rc=$?
elapsed=$(( $(date +%s) - start_s ))

if [ "$rc" = 0 ]; then
  bad "a second gate was allowed to run alongside the first"
elif ! printf '%s' "$out" | grep -q "another Baton gate is running"; then
  bad "the refusal does not say a gate is running. Got: $out"
elif ! printf '%s' "$out" | grep -q "pid $HOLDER"; then
  bad "the refusal does not name the holder's pid ($HOLDER). Got: $out"
elif ! printf '%s' "$out" | grep -q "$ROOT"; then
  bad "the refusal does not name the holder's working directory. Got: $out"
elif ! printf '%s' "$out" | grep -q "$WORK/dd-holder"; then
  bad "the refusal does not name the holder's derived data. Got: $out"
else
  ok "a second gate is refused and names pid, start time, cwd and derived data"
fi

# The whole point of refusing rather than queueing: it costs no time at all. The holder is
# still up for another nineteen seconds, so anything but an immediate answer is a wait.
if [ "$elapsed" -gt 2 ]; then
  bad "the refusal took ${elapsed}s; it must be immediate, not a queue"
else
  ok "the refusal took ${elapsed}s, before xcodegen and before any build"
fi

# --- 2. The escape hatch still lets a run through --------------------------------------

out="$(BATON_GATE_LOCK="$LOCK" BATON_DERIVED_DATA="$WORK/dd" SKIP_IOS=1 \
       BATON_ALLOW_CONCURRENT_GATE=1 BATON_GATE_LOCK_PROBE=0 "$GATE" 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then
  bad "BATON_ALLOW_CONCURRENT_GATE=1 did not override the lock. Got: $out"
else
  ok "BATON_ALLOW_CONCURRENT_GATE=1 overrides the lock for someone who means it"
fi

# --- 3. A killed gate does not wedge the next run --------------------------------------
#
# This is the half that would be worse than the bug. The holder is killed with SIGKILL, so
# no trap runs and the pidfile is left exactly as a `pkill` leaves it.

kill -9 "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
HOLDER=""

if [ ! -s "$LOCK" ]; then
  bad "the killed holder's pidfile is gone, so the stale case is not being tested"
else
  out="$(contend)"; rc=$?
  if [ "$rc" != 0 ]; then
    bad "a stale pidfile from a killed gate blocked the next run. Got: $out"
  elif ! printf '%s' "$out" | grep -q "clearing a stale gate lock"; then
    bad "the stale lock was cleared without saying so. Got: $out"
  else
    ok "a pidfile left by a SIGKILLed gate is cleared, and the next run proceeds"
  fi
fi

# --- 4. A recycled pid is not mistaken for a live holder --------------------------------
#
# A pidfile holding a pid that has come round again is the way a liveness check on the pid
# alone would wedge the machine for good. The start time is what separates them, so this
# plants THIS shell's own pid with somebody else's start time: alive, and not the holder.

printf '%s\n%s\n%s\n%s\n' "$$" "Mon Jan  1 00:00:00 2001" "/tmp/some-old-gate" "/tmp/baton-dd" >"$LOCK"
out="$(contend)"; rc=$?
if [ "$rc" != 0 ]; then
  bad "a recycled pid was treated as a live gate, which wedges every later run. Got: $out"
elif ! printf '%s' "$out" | grep -q "clearing a stale gate lock"; then
  bad "the recycled-pid lock was cleared without saying so. Got: $out"
else
  ok "a live pid with the wrong start time is debris, not a holder"
fi

# --- 5. An empty or truncated lockfile is debris ----------------------------------------

: >"$LOCK"
out="$(contend)"; rc=$?
if [ "$rc" != 0 ]; then
  bad "an empty lockfile blocked the next run. Got: $out"
else
  ok "an empty lockfile does not block a run"
fi

# --- 6. Wiring: the lock is taken before anything expensive -----------------------------
#
# The guard is only worth anything if it comes before the build. If it drifts below
# xcodegen or the lints, a refused run starts costing minutes.
lock_line="$(grep -n '^  gate_lock_acquire$' scripts/test.sh | cut -d: -f1)"
xcodegen_line="$(grep -n '^bold "==> Generating Xcode project' scripts/test.sh | cut -d: -f1)"
if [ -z "$lock_line" ] || [ -z "$xcodegen_line" ]; then
  bad "wiring: cannot find the acquire or the xcodegen step in scripts/test.sh"
elif [ "$lock_line" -ge "$xcodegen_line" ]; then
  bad "wiring: the gate lock is taken at line $lock_line, after xcodegen at $xcodegen_line"
else
  ok "wiring: the gate lock is taken before xcodegen, so a refused run costs nothing"
fi

# And it must still be released, or one gate wedges the machine on its way out.
if grep -q "trap gate_lock_release EXIT INT TERM" scripts/test.sh; then
  ok "wiring: the lock is released on EXIT, INT and TERM"
else
  bad "wiring: nothing releases the gate lock when the run ends"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
