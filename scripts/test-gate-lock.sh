#!/bin/bash
#
# Baton gates and releases on this machine must not kill each other, and a dead owner
# must not wedge the next run.
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
# does, and proves the harder half: that metadata a killed gate leaves behind does not
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
cd "$(dirname "$0")/.." || exit
ROOT="$PWD"
GATE="$ROOT/scripts/test.sh"
RELEASE="$ROOT/scripts/publish.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '\033[32mok    %s\033[0m\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '\033[31mFAIL  %s\033[0m\n' "$1"; }

WORK="$(mktemp -d)"
LOCK="$WORK/gate.lock"
HOLDER=""
LAUNCHER=""
RACER_A=""; RACER_B=""
cleanup() {
  [ -z "$HOLDER" ] || kill -9 "$HOLDER" 2>/dev/null
  [ -z "$LAUNCHER" ] || kill -9 "$LAUNCHER" 2>/dev/null
  [ -z "$RACER_A" ] || kill -9 "$RACER_A" 2>/dev/null
  [ -z "$RACER_B" ] || kill -9 "$RACER_B" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# Record any release-side process scan. While another owner holds the lock, publish.sh
# must refuse before even looking for a process to reap. This makes the old ordering red
# without launching an app or putting a sacrificial process in front of its kill command.
mkdir -p "$WORK/bin"
printf '%s\n' '#!/bin/bash' 'printf "pgrep %s\n" "$*" >>"$BATON_GATE_LOCK_PGREP_LOG"' 'exit 1' \
  >"$WORK/bin/pgrep"
chmod +x "$WORK/bin/pgrep"

# A second gate that stops at the lock. SKIP_IOS keeps it off the phone, and the refusal
# comes before xcodegen, so a run that is going to be refused costs nothing.
contend() {   # prints the refusal, returns its status
  BATON_GATE_LOCK="$LOCK" BATON_DERIVED_DATA="$WORK/dd" SKIP_IOS=1 \
    BATON_GATE_LOCK_PROBE=0 "$GATE" 2>&1
}

contend_release() {   # prints the refusal, returns its status
  PATH="$WORK/bin:$PATH" BATON_GATE_LOCK_PGREP_LOG="$WORK/pgrep.calls" \
    BATON_GATE_LOCK="$LOCK" BATON_DERIVED_DATA="$WORK/dd-release" \
    ALLOW_PRIMARY_CHECKOUT=1 BATON_GATE_LOCK_PROBE=0 "$RELEASE" 2>&1
}

start_holder() {   # $1 = seconds to hold
  BATON_GATE_LOCK="$LOCK" BATON_DERIVED_DATA="$WORK/dd-holder" \
    BATON_GATE_LOCK_PROBE="$1" "$GATE" >"$WORK/holder.out" 2>&1 &
  LAUNCHER=$!
  # Wait for the lock to appear rather than sleeping a guessed interval.
  local _
  for _ in $(seq 1 100); do
    if [ -s "$LOCK" ]; then
      HOLDER="$(sed -n '1p' "$LOCK")"
      [ -n "$HOLDER" ] && return 0
    fi
    sleep 0.05
  done
  return 1
}

start_release_holder() {   # $1 = seconds to hold
  BATON_GATE_LOCK="$LOCK" BATON_DERIVED_DATA="$WORK/dd-release-holder" \
    ALLOW_PRIMARY_CHECKOUT=1 BATON_GATE_LOCK_PROBE="$1" "$RELEASE" >"$WORK/holder.out" 2>&1 &
  LAUNCHER=$!
  local _
  for _ in $(seq 1 100); do
    if [ -s "$LOCK" ]; then
      HOLDER="$(sed -n '1p' "$LOCK")"
      [ -n "$HOLDER" ] && return 0
    fi
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

# This was the hole left by the first TBX-5291 fix. publish.sh used to reap /tmp/baton-dd
# before its nested test.sh acquired the lock, so it could kill this holder even though
# gate against gate contention was covered.
out="$(contend_release)"; rc=$?
if [ "$rc" = 0 ]; then
  bad "a release was allowed to start while a gate held the shared test host"
elif ! printf '%s' "$out" | grep -q "another Baton gate is running"; then
  bad "a release does not name the gate it refused to race. Got: $out"
elif [ -e "$WORK/pgrep.calls" ]; then
  bad "the refused release scanned for a test host before it checked the lock"
elif ! kill -0 "$HOLDER" 2>/dev/null; then
  bad "the refused release killed the gate holder before it checked the lock"
else
  ok "a release refuses before it can reap an active gate's test host"
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
wait "$LAUNCHER" 2>/dev/null
HOLDER=""
LAUNCHER=""

if [ ! -s "$LOCK" ]; then
  bad "the killed gate left no metadata, so the stale case is not being tested"
else
  out="$(contend)"; rc=$?
  if [ "$rc" != 0 ]; then
    bad "stale metadata from a killed gate blocked the next run. Got: $out"
  elif ! printf '%s' "$out" | grep -q "clearing a stale gate lock"; then
    bad "the stale gate lock was cleared without saying so. Got: $out"
  else
    ok "metadata left by a SIGKILLed gate is cleared, and the next gate proceeds"
  fi
fi

# --- 4. A gate is also refused while a release owns the host ----------------------------

rm -f "$LOCK"
if ! start_release_holder 20; then
  bad "the release holder never took the lock; reverse contention was not tested"
else
  out="$(contend)"; rc=$?
  if [ "$rc" = 0 ]; then
    bad "a gate was allowed to start while a release held the shared test host"
  elif ! printf '%s' "$out" | grep -q "another Baton release is running"; then
    bad "a gate does not identify the release that owns the lock. Got: $out"
  elif ! printf '%s' "$out" | grep -q "pid $HOLDER"; then
    bad "the gate refusal does not name the release holder's pid ($HOLDER). Got: $out"
  else
    ok "a gate refuses immediately and names the release that owns the test host"
  fi
fi

# --- 5. A killed release does not wedge the next gate -----------------------------------
#
# Kill the release holder without running its trap. The stale path below must recover
# from this exact operational case too, not only from a killed ad-hoc gate.
kill -9 "$HOLDER" 2>/dev/null
wait "$LAUNCHER" 2>/dev/null
HOLDER=""
LAUNCHER=""

if [ ! -s "$LOCK" ]; then
  bad "the killed release left no metadata, so the stale case is not being tested"
else
  out="$(contend)"; rc=$?
  if [ "$rc" != 0 ]; then
    bad "stale metadata from a killed release blocked the next run. Got: $out"
  elif ! printf '%s' "$out" | grep -q "clearing a stale gate lock"; then
    bad "the stale lock was cleared without saying so. Got: $out"
  else
    ok "metadata left by a SIGKILLed release is cleared, and the next gate proceeds"
  fi
fi

# --- 6. Two stale reclaimers cannot delete each other's successor lock -----------------

rm -f "$LOCK" "$WORK"/reclaim.ready.* "$WORK/reclaim.go"
printf '%s\n%s\n%s\n%s\n%s\n' \
  "999999" "Mon Jan  1 00:00:00 2001" "/tmp/old-gate" "/tmp/baton-dd" "gate" >"$LOCK"
BATON_GATE_LOCK="$LOCK" BATON_DERIVED_DATA="$WORK/dd-racer-a" \
  BATON_GATE_LOCK_TEST_BARRIER="$WORK/reclaim" BATON_GATE_LOCK_PROBE=3 \
  "$GATE" >"$WORK/racer-a.out" 2>&1 &
RACER_A=$!
BATON_GATE_LOCK="$LOCK" BATON_DERIVED_DATA="$WORK/dd-racer-b" \
  BATON_GATE_LOCK_TEST_BARRIER="$WORK/reclaim" BATON_GATE_LOCK_PROBE=3 \
  "$GATE" >"$WORK/racer-b.out" 2>&1 &
RACER_B=$!

ready=0
for _ in $(seq 1 200); do
  ready="$(find "$WORK" -maxdepth 1 -name 'reclaim.ready.*' | wc -l | tr -d ' ')"
  [ "$ready" = 2 ] && break
  sleep 0.01
done
if [ "$ready" != 2 ]; then
  bad "the two stale reclaimers did not reach the deterministic barrier"
  : >"$WORK/reclaim.go"
else
  : >"$WORK/reclaim.go"
  winner_pid=""
  for _ in $(seq 1 200); do
    candidate="$(sed -n '1p' "$LOCK" 2>/dev/null || true)"
    if [ -n "$candidate" ] && [ "$candidate" != 999999 ] \
       && kill -0 "$candidate" 2>/dev/null; then
      winner_pid="$candidate"
      break
    fi
    sleep 0.01
  done
  for _ in $(seq 1 200); do
    if grep -q "GATE LOCK: acquired by $winner_pid" "$WORK/racer-a.out" 2>/dev/null \
       || grep -q "GATE LOCK: acquired by $winner_pid" "$WORK/racer-b.out" 2>/dev/null; then
      break
    fi
    sleep 0.01
  done
  if grep -q "GATE LOCK: acquired by $winner_pid" "$WORK/racer-a.out" 2>/dev/null; then
    loser_out="$WORK/racer-b.out"
  else
    loser_out="$WORK/racer-a.out"
  fi
  for _ in $(seq 1 200); do
    grep -q "another Baton gate is running" "$loser_out" 2>/dev/null && break
    sleep 0.01
  done
  if [ -z "$winner_pid" ]; then
    bad "neither stale reclaimer established itself as the one owner"
  elif ! kill -0 "$winner_pid" 2>/dev/null; then
    bad "the losing stale reclaimer removed or disrupted the winner"
  elif [ "$(sed -n '1p' "$LOCK" 2>/dev/null)" != "$winner_pid" ]; then
    bad "the lock no longer names the stale-reclamation winner"
  elif ! grep -q "pid $winner_pid" "$loser_out" 2>/dev/null; then
    bad "the losing stale reclaimer did not name and refuse the new live owner"
  else
    ok "two simultaneous stale reclaimers produce one live owner and one named refusal"
  fi
fi

wait "$RACER_A" 2>/dev/null; racer_a_rc=$?
wait "$RACER_B" 2>/dev/null; racer_b_rc=$?
RACER_A=""; RACER_B=""
if { [ "$racer_a_rc" = 0 ] && [ "$racer_b_rc" != 0 ]; } \
   || { [ "$racer_a_rc" != 0 ] && [ "$racer_b_rc" = 0 ]; }; then
  ok "exactly one simultaneous stale reclaimer acquires the kernel lock"
else
  bad "expected one stale reclaimer to pass and one to refuse, got $racer_a_rc and $racer_b_rc"
fi

# --- 7. A release's child gate inherits instead of deadlocking --------------------------

rm -f "$LOCK"
out="$(BATON_GATE_LOCK="$LOCK" BATON_DERIVED_DATA="$WORK/dd-nested" \
  ALLOW_PRIMARY_CHECKOUT=1 BATON_GATE_LOCK_CHILD_PROBE=1 "$RELEASE" 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then
  bad "a release deadlocked against its own child gate. Got: $out"
elif ! printf '%s' "$out" | grep -q "inherited from release parent"; then
  bad "the child gate passed without proving it inherited the release lock. Got: $out"
else
  ok "a release's child gate inherits the lock and leaves the parent owning it"
fi

# --- 8. A clean release exit clears its lock record -------------------------------------

rm -f "$LOCK"
out="$(BATON_GATE_LOCK="$LOCK" BATON_DERIVED_DATA="$WORK/dd-release-exit" \
  ALLOW_PRIMARY_CHECKOUT=1 BATON_GATE_LOCK_PROBE=0 "$RELEASE" 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then
  bad "a release lock probe could not complete. Got: $out"
elif [ -s "$LOCK" ]; then
  bad "publish.sh left live-looking lock metadata behind after a normal exit"
else
  ok "a normal release exit clears its lock record and releases the kernel lock"
fi

# --- 9. A live legacy pidfile is honored during migration -------------------------------

printf '%s\n%s\n%s\n%s\n' \
  "$$" "$(ps -o lstart= -p $$ 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" \
  "/tmp/legacy-gate" "/tmp/baton-dd" >"$LOCK"
out="$(contend)"; rc=$?
if [ "$rc" = 0 ]; then
  bad "the kernel-lock migration ignored a live gate using the old pidfile guard"
elif ! printf '%s' "$out" | grep -q "pid $$"; then
  bad "the migration refusal did not name the live legacy holder. Got: $out"
else
  ok "a live gate using the old pidfile guard is still refused during migration"
fi

# --- 10. A recycled pid in stale metadata cannot wedge the kernel lock ------------------
#
# This plants THIS shell's live pid with somebody else's start time. The metadata lies,
# but the kernel lock is free, so the next gate must acquire without caring about pid reuse.

printf '%s\n%s\n%s\n%s\n' "$$" "Mon Jan  1 00:00:00 2001" "/tmp/some-old-gate" "/tmp/baton-dd" >"$LOCK"
out="$(contend)"; rc=$?
if [ "$rc" != 0 ]; then
  bad "a recycled pid in stale metadata wedged the free kernel lock. Got: $out"
elif ! printf '%s' "$out" | grep -q "clearing a stale gate lock"; then
  bad "the recycled-pid lock was cleared without saying so. Got: $out"
else
  ok "a live recycled pid in metadata cannot impersonate a kernel lock owner"
fi

# --- 11. An empty or truncated lockfile is harmless -------------------------------------

: >"$LOCK"
out="$(contend)"; rc=$?
if [ "$rc" != 0 ]; then
  bad "an empty lockfile blocked the next run. Got: $out"
else
  ok "an empty lockfile does not block a run"
fi

# --- 12. Wiring: both entry points lock before anything dangerous -----------------------
#
# The guard is only worth anything if it comes before the build. If it drifts below
# xcodegen or the lints, a refused run starts costing minutes.
lock_line="$(grep -n 'gate_lock_acquire gate ' scripts/test.sh | cut -d: -f1)"
xcodegen_line="$(grep -n '^bold "==> Generating Xcode project' scripts/test.sh | cut -d: -f1)"
if [ -z "$lock_line" ] || [ -z "$xcodegen_line" ]; then
  bad "wiring: cannot find the acquire or the xcodegen step in scripts/test.sh"
elif [ "$lock_line" -ge "$xcodegen_line" ]; then
  bad "wiring: the gate lock is taken at line $lock_line, after xcodegen at $xcodegen_line"
else
  ok "wiring: the gate lock is taken before xcodegen, so a refused run costs nothing"
fi

release_lock_line="$(grep -n 'gate_lock_acquire release ' scripts/publish.sh | cut -d: -f1)"
reap_line="$(grep -n '^reap_test_hosts$' scripts/publish.sh | head -1 | cut -d: -f1)"
if [ -z "$release_lock_line" ] || [ -z "$reap_line" ]; then
  bad "wiring: cannot find the release acquire or its first test-host reap"
elif [ "$release_lock_line" -ge "$reap_line" ]; then
  bad "wiring: publish.sh can reap a test host at line $reap_line before locking at line $release_lock_line"
else
  ok "wiring: publish.sh owns the lock before its first test-host reap"
fi

# And it must still be released, or one gate wedges the machine on its way out.
if grep -q "trap gate_lock_release EXIT INT TERM" scripts/test.sh; then
  ok "wiring: the lock is released on EXIT, INT and TERM"
else
  bad "wiring: nothing releases the gate lock when the run ends"
fi

if grep -q "trap publish_cleanup EXIT INT TERM" scripts/publish.sh \
   && grep -A4 '^publish_cleanup()' scripts/publish.sh | grep -q 'gate_lock_release'; then
  ok "wiring: the release keeps and releases the lock through every exit path"
else
  bad "wiring: publish.sh does not release the lock from its shared exit cleanup"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
