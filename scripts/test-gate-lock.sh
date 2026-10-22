#!/bin/bash
#
# Baton gates and releases on this machine must not kill each other, a dead owner must not
# wedge the next run, and a run must hold only the resources it uses.
#
# WHY THIS EXISTS. On 2026-09-08 at 17:20 a gate died at the Mac suite with the BATON-DIAG
# runner-death signature, and the backtrace named `_handleAEQuit`: a Quit Apple Event from
# outside the process. A Mac release had started four seconds after this run reached its
# Mac stage; both app-hosted the same Baton.app out of /tmp/baton-dd, and launching the
# second made LaunchServices quit the first. The victim reported a runner death against an
# unrelated test, so the diagnosis cost an afternoon and landed on innocent code.
#
# The guard in scripts/test.sh takes the `mac-app-host` lock for its Mac app-hosted step
# only, waits for a busy lock (BATON_GATE_LOCK_WAIT) or refuses at once with
# BATON_GATE_LOCK_WAIT=0, and puts a waiting release ahead of ordinary runs. This proves it
# does, proves the harder half (metadata a killed gate leaves behind does not block every
# later run), and proves the named per-resource locks of scripts/native-lock.sh hold one
# simulator per run while different simulators run side by side.
#
# It drives the REAL acquire in scripts/test.sh and scripts/publish.sh through the
# BATON_GATE_LOCK and BATON_GATE_LOCK_PROBE hatches, the same way test-gate-counts.sh and
# test-lints.sh drive their subjects: a guard that reimplements its subject can pass while
# the subject is broken. Nothing here builds. Every lock it touches lives under its own
# temporary directory; it never reads, takes or signals the real /tmp/baton-gate.lock or
# anything in /tmp/native-locks.
#
# No Xcode build, no simulator, no network, about thirty seconds.
# shellcheck disable=SC2016 # the wiring checks grep scripts for literal $NAMES
set -uo pipefail
cd "$(dirname "$0")/.." || exit
ROOT="$PWD"
GATE="$ROOT/scripts/test.sh"
RELEASE="$ROOT/scripts/publish.sh"
TESTFLIGHT="$ROOT/ios/scripts/testflight.sh"

# This harness also runs inside a real gate or release. Nothing that run exported may steer
# the runs below: a release's priority or owner pid would change what they prove.
unset BATON_GATE_LOCK_PRIORITY BATON_GATE_LOCK_ACTIVE_OWNER_PID BATON_GATE_LOCK_WAIT \
  BATON_ALLOW_CONCURRENT_GATE BATON_GATE_LOCK_TEST_BARRIER BATON_GATE_LOCK_PROBE \
  BATON_GATE_LOCK_CHILD_PROBE NATIVE_LOCK_DIR LINT_ONLY CLEAN BATON_IOS_SIM_UDID

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '\033[32mok    %s\033[0m\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '\033[31mFAIL  %s\033[0m\n' "$1"; }

WORK="$(mktemp -d)"
LOCK="$WORK/gate.lock"
# Exported, so no run below can reach the real locks even if a line forgets to say so.
export BATON_GATE_LOCK="$LOCK"
export NATIVE_LOCK_DIR="$WORK/native-locks"
export NATIVE_LOCK_POLL=0.1
INTENT="$NATIVE_LOCK_DIR/mac-app-host.release-intent"
HOLDER=""
LAUNCHER=""
RACER_A=""; RACER_B=""
EXTRA_PIDS=""
cleanup() {
  [ -z "$HOLDER" ] || kill -9 "$HOLDER" 2>/dev/null
  [ -z "$LAUNCHER" ] || kill -9 "$LAUNCHER" 2>/dev/null
  [ -z "$RACER_A" ] || kill -9 "$RACER_A" 2>/dev/null
  [ -z "$RACER_B" ] || kill -9 "$RACER_B" 2>/dev/null
  local pid
  for pid in $EXTRA_PIDS; do kill -9 "$pid" 2>/dev/null; done
  # Holders notice their owner's death within a fraction of a second; let them go before
  # the directory they lock disappears.
  sleep 0.5
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# Wait up to ~10 s for a pattern in a file.
await() {   # $1 = file, $2 = fixed string
  local _
  for _ in $(seq 1 200); do
    grep -qF -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.05
  done
  return 1
}

# A five-line record naming a live stand-in process, the format every lock and intent uses.
plant_record() {   # $1 = file, $2 = pid, $3 = cwd, $4 = kind
  mkdir -p "$(dirname "$1")"
  printf '%s\n%s\n%s\n%s\n%s\n' "$2" \
    "$(ps -o lstart= -p "$2" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" \
    "$3" "/tmp/baton-dd" "$4" >"$1.tmp" && mv -f "$1.tmp" "$1"
}

stand_in() {   # starts a live process to name in planted records; prints its pid
  sleep 60 >/dev/null 2>&1 &
  EXTRA_PIDS="$EXTRA_PIDS $!"
  printf '%s\n' "$!"
}

# Record any release-side process scan. While another owner holds the lock, publish.sh
# must refuse before even looking for a process to reap. This makes the old ordering red
# without launching an app or putting a sacrificial process in front of its kill command.
mkdir -p "$WORK/bin"
printf '%s\n' '#!/bin/bash' 'printf "pgrep %s\n" "$*" >>"$BATON_GATE_LOCK_PGREP_LOG"' 'exit 1' \
  >"$WORK/bin/pgrep"
chmod +x "$WORK/bin/pgrep"

# A second gate that stops at the lock. SKIP_IOS keeps it off the phone, and the refusal
# comes before xcodegen, so a run that is going to be refused costs nothing.
# BATON_GATE_LOCK_WAIT=0 unless a test says otherwise: the original refusal, unchanged.
contend() {   # prints the refusal, returns its status; extra args go to test.sh
  BATON_GATE_LOCK="$LOCK" BATON_DERIVED_DATA="$WORK/dd" SKIP_IOS=1 \
    BATON_GATE_LOCK_WAIT="${CONTEND_WAIT:-0}" BATON_GATE_LOCK_PROBE=0 "$GATE" "$@" 2>&1
}

contend_release() {   # prints the refusal, returns its status
  PATH="$WORK/bin:$PATH" BATON_GATE_LOCK_PGREP_LOG="$WORK/pgrep.calls" \
    BATON_GATE_LOCK="$LOCK" BATON_DERIVED_DATA="$WORK/dd-release" \
    BATON_GATE_LOCK_WAIT="${CONTEND_WAIT:-0}" \
    ALLOW_PRIMARY_CHECKOUT=1 BATON_GATE_LOCK_PROBE=0 "$RELEASE" 2>&1
}

# Holds one named lock through scripts/native-lock.sh itself, as another project would.
native_hold() {   # $1 = name, $2 = seconds, $3 = output file
  /bin/bash -c '. "$1/scripts/native-lock.sh"
    native_lock_acquire "$2" gate "$4" || exit 1
    echo "held by $$"; sleep "$3"; native_lock_release "$2"' _ "$ROOT" "$1" "$2" "$WORK/dd-$1" \
    >"$3" 2>&1 &
}

native_try() {   # $1 = name; prints output, returns status
  /bin/bash -c '. "$1/scripts/native-lock.sh"
    native_lock_acquire "$2" gate "$3" || exit 1
    echo "acquired $2 by $$"; native_lock_release "$2"' _ "$ROOT" "$1" "$WORK/dd-try-$1" 2>&1
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
elif ! grep -q <<<"$out" "another Baton gate is running"; then
  bad "the refusal does not say a gate is running. Got: $out"
elif ! grep -q <<<"$out" "pid $HOLDER"; then
  bad "the refusal does not name the holder's pid ($HOLDER). Got: $out"
elif ! grep -q <<<"$out" "$ROOT"; then
  bad "the refusal does not name the holder's working directory. Got: $out"
elif ! grep -q <<<"$out" "$WORK/dd-holder"; then
  bad "the refusal does not name the holder's derived data. Got: $out"
else
  ok "a second gate is refused and names pid, start time, cwd and derived data"
fi

# BATON_GATE_LOCK_WAIT=0 is the old behavior, and its words are an interface: people and
# Tonebox's controller read them. Every line of the original refusal, verbatim.
missing=""
plain="$(sed 's/\x1b\[[0-9;]*m//g' <<<"$out")"
for line in \
  "✗ another Baton gate is running (pid $HOLDER, started " \
  "  Its derived data: $WORK/dd-holder" \
  "  Baton gates and releases app-host the same Baton.app. Starting or reaping a" \
  "  second copy makes the other run report a runner death against an unrelated test." \
  "  This run stopped before it could share derived data or kill that host. (TBX-5291)" \
  "  Wait for it, or stop it, then run again. BATON_ALLOW_CONCURRENT_GATE=1 overrides."; do
  grep -qF -- "$line" <<<"$plain" || missing="$missing [$line]"
done
if [ -n "$missing" ]; then
  bad "BATON_GATE_LOCK_WAIT=0 changed the refusal wording; missing:$missing"
elif grep -q <<<"$out" "waiting for"; then
  bad "BATON_GATE_LOCK_WAIT=0 waited instead of refusing. Got: $out"
else
  ok "BATON_GATE_LOCK_WAIT=0 refuses with the original message, word for word"
fi

# This was the hole left by the first an internal task fix. publish.sh used to reap /tmp/baton-dd
# before its nested test.sh acquired the lock, so it could kill this holder even though
# gate against gate contention was covered.
out="$(contend_release)"; rc=$?
if [ "$rc" = 0 ]; then
  bad "a release was allowed to start while a gate held the shared test host"
elif ! grep -q <<<"$out" "another Baton gate is running"; then
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
  elif ! grep -q <<<"$out" "clearing a stale gate lock"; then
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
  elif ! grep -q <<<"$out" "another Baton release is running"; then
    bad "a gate does not identify the release that owns the lock. Got: $out"
  elif ! grep -q <<<"$out" "pid $HOLDER"; then
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
  elif ! grep -q <<<"$out" "clearing a stale gate lock"; then
    bad "the stale lock was cleared without saying so. Got: $out"
  else
    ok "metadata left by a SIGKILLed release is cleared, and the next gate proceeds"
  fi
fi

# --- 6. Two stale reclaimers cannot delete each other's successor lock -----------------

rm -f "$LOCK" "$WORK"/reclaim.ready.* "$WORK/reclaim.go"
printf '%s\n%s\n%s\n%s\n%s\n' \
  "999999" "Mon Jan  1 00:00:00 2001" "/tmp/old-gate" "/tmp/baton-dd" "gate" >"$LOCK"
BATON_GATE_LOCK="$LOCK" BATON_DERIVED_DATA="$WORK/dd-racer-a" BATON_GATE_LOCK_WAIT=0 \
  BATON_GATE_LOCK_TEST_BARRIER="$WORK/reclaim" BATON_GATE_LOCK_PROBE=3 \
  "$GATE" >"$WORK/racer-a.out" 2>&1 &
RACER_A=$!
BATON_GATE_LOCK="$LOCK" BATON_DERIVED_DATA="$WORK/dd-racer-b" BATON_GATE_LOCK_WAIT=0 \
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
elif ! grep -q <<<"$out" "inherited from release parent"; then
  bad "the child gate passed without proving it inherited the release lock. Got: $out"
else
  ok "a release's child gate inherits the lock and leaves the parent owning it"
fi

# --- 8. A clean release exit clears its lock record -------------------------------------
#
# The SIGKILLed holders above left stale records on purpose; start this one from an empty
# temporary lock directory so anything left over is this release's.

rm -f "$LOCK"
rm -rf "$NATIVE_LOCK_DIR"
out="$(BATON_GATE_LOCK="$LOCK" BATON_DERIVED_DATA="$WORK/dd-release-exit" \
  ALLOW_PRIMARY_CHECKOUT=1 BATON_GATE_LOCK_PROBE=0 "$RELEASE" 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then
  bad "a release lock probe could not complete. Got: $out"
elif [ -s "$LOCK" ]; then
  bad "publish.sh left live-looking lock metadata behind after a normal exit"
elif [ -n "$(find "$NATIVE_LOCK_DIR" -type f -size +0 2>/dev/null)" ]; then
  bad "publish.sh left a build-tree lock record or a release intent behind: $(find "$NATIVE_LOCK_DIR" -type f -size +0)"
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
elif ! grep -q <<<"$out" "pid $$"; then
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
elif ! grep -q <<<"$out" "clearing a stale gate lock"; then
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


# --- 12. A busy lock is waited for, and its holder named once ---------------------------
#
# The point of an internal task: a gate that finds the test host busy waits its turn instead of
# throwing away the steps it already ran. The holder is named once, not once per poll.

rm -f "$LOCK"
if ! start_holder 2; then
  bad "the holder never took the lock; the wait was not tested"
else
  start_s=$(date +%s)
  out="$(CONTEND_WAIT=20 contend)"; rc=$?
  elapsed=$(( $(date +%s) - start_s ))
  named="$(printf '%s\n' "$out" | grep -c "waiting for gate pid $HOLDER from $ROOT")"
  if [ "$rc" != 0 ]; then
    bad "a gate given BATON_GATE_LOCK_WAIT=20 did not get the lock after the holder left. Got: $out"
  elif ! grep -q <<<"$out" "GATE LOCK: acquired by"; then
    bad "the waiting gate exited without acquiring. Got: $out"
  elif [ "$elapsed" -lt 1 ]; then
    bad "the gate acquired after ${elapsed}s while the holder still had the lock"
  else
    ok "a gate waits for a busy test host and continues when it is free (${elapsed}s)"
  fi
  if [ "$named" = 1 ]; then
    ok "the waiting gate names its holder exactly once over ~20 polls"
  else
    bad "the holder was named $named times, expected once. Got: $out"
  fi
fi
wait "$LAUNCHER" 2>/dev/null; HOLDER=""; LAUNCHER=""

# --- 13. The wait is bounded --------------------------------------------------------------

rm -f "$LOCK"
if ! start_holder 6; then
  bad "the holder never took the lock; the wait bound was not tested"
else
  start_s=$(date +%s)
  out="$(CONTEND_WAIT=1 contend)"; rc=$?
  elapsed=$(( $(date +%s) - start_s ))
  if [ "$rc" = 0 ]; then
    bad "a gate acquired a lock that was held for longer than its wait"
  elif ! grep -q <<<"$out" "gave up after waiting 1s for mac-app-host"; then
    bad "a timed-out wait does not say it gave up. Got: $out"
  elif ! grep -q <<<"$out" "another Baton gate is running (pid $HOLDER"; then
    bad "a timed-out wait does not name the holder. Got: $out"
  elif [ "$elapsed" -gt 4 ]; then
    bad "BATON_GATE_LOCK_WAIT=1 waited ${elapsed}s"
  else
    ok "BATON_GATE_LOCK_WAIT bounds the wait and then refuses, naming the holder"
  fi
fi
kill -9 "$HOLDER" 2>/dev/null; wait "$LAUNCHER" 2>/dev/null; HOLDER=""; LAUNCHER=""
sleep 0.5

# --- 14. A waiting release holds ordinary runs back, and a holder change is named ---------
#
# The intent is planted with live stand-in processes, so the test controls exactly when it
# changes hands and when it goes away.

rm -f "$LOCK" "$INTENT"
REL_A="$(stand_in)"
plant_record "$INTENT" "$REL_A" "/tmp/release-a" release
out="$(contend)"; rc=$?
if [ "$rc" = 0 ]; then
  bad "a gate overtook a waiting release's intent on a free lock"
elif ! grep -q <<<"$out" "another Baton release is running (pid $REL_A"; then
  bad "the refusal behind a release intent does not name the release. Got: $out"
else
  ok "with BATON_GATE_LOCK_WAIT=0 a gate refuses behind a live release intent, naming it"
fi

BATON_GATE_LOCK="$LOCK" BATON_DERIVED_DATA="$WORK/dd-behind" SKIP_IOS=1 \
  BATON_GATE_LOCK_WAIT=30 BATON_GATE_LOCK_PROBE=0 "$GATE" >"$WORK/behind.out" 2>&1 &
behind=$!
EXTRA_PIDS="$EXTRA_PIDS $behind"
if ! await "$WORK/behind.out" "waiting for release pid $REL_A from /tmp/release-a"; then
  bad "a gate did not wait behind a live release intent. Got: $(cat "$WORK/behind.out")"
else
  REL_B="$(stand_in)"
  plant_record "$INTENT" "$REL_B" "/tmp/release-b" release
  await "$WORK/behind.out" "waiting for release pid $REL_B" || true
  rm -f "$INTENT"
  wait "$behind"; rc=$?
  first="$(grep -c "waiting for release pid $REL_A" "$WORK/behind.out")"
  second="$(grep -c "waiting for release pid $REL_B" "$WORK/behind.out")"
  if [ "$rc" != 0 ] || ! grep -q "GATE LOCK: acquired by" "$WORK/behind.out"; then
    bad "the gate did not continue once the intent was withdrawn. Got: $(cat "$WORK/behind.out")"
  elif [ "$first" != 1 ] || [ "$second" != 1 ]; then
    bad "holders should be named once each on change, got $first and $second. Got: $(cat "$WORK/behind.out")"
  else
    ok "a gate waits behind a release intent, names a new holder once, and continues after"
  fi
fi

# --- 15. A release's child still inherits while another release's intent is live --------

rm -f "$LOCK"
plant_record "$INTENT" "$REL_A" "/tmp/release-a" release
out="$(BATON_GATE_LOCK="$LOCK" BATON_DERIVED_DATA="$WORK/dd-nested-intent" \
  ALLOW_PRIMARY_CHECKOUT=1 BATON_GATE_LOCK_WAIT=5 BATON_GATE_LOCK_CHILD_PROBE=1 "$RELEASE" 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then
  bad "a release or its child gate stalled behind another release's intent. Got: $out"
elif ! grep -q <<<"$out" "inherited from release parent"; then
  bad "the child gate did not inherit while an intent was live. Got: $out"
elif grep -q <<<"$out" "waiting for"; then
  bad "the release's child waited on an intent instead of inheriting. Got: $out"
else
  ok "a release's child inherits the lock even while another release's intent is live"
fi
rm -f "$INTENT"

# --- 16. A stale intent does not hold anyone back ------------------------------------------

rm -f "$LOCK"
sleep 0 & dead=$!; wait "$dead"
plant_record "$INTENT" "$dead" "/tmp/dead-release" release
out="$(contend)"; rc=$?
if [ "$rc" != 0 ]; then
  bad "a dead release's intent blocked a gate. Got: $out"
elif ! grep -q <<<"$out" "clearing a stale release intent (recorded pid $dead)"; then
  bad "the stale intent was cleared without saying so. Got: $out"
elif [ -e "$INTENT" ]; then
  bad "the stale intent file is still there"
else
  ok "an intent whose release has died is cleared, and the gate proceeds"
fi

# A reused pid with somebody else's start time is the same case.
printf '%s\n%s\n%s\n%s\n%s\n' "$$" "Mon Jan  1 00:00:00 2001" "/tmp/old-release" "/tmp/baton-dd" release >"$INTENT"
out="$(contend)"; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$INTENT" ]; then
  ok "an intent naming a reused pid is stale, and cleared"
else
  bad "an intent naming a reused pid held a gate back. Got: $out"
fi

# --- 17. Release priority, end to end -------------------------------------------------------
#
# A gate holds the host; a release starts waiting and registers its intent; then a second
# gate arrives. When the host is free the release must get it first. Without priority this
# is a coin toss between the two pollers.

rm -f "$LOCK" "$INTENT"
if ! start_holder 3; then
  bad "the holder never took the lock; release priority was not tested"
else
  BATON_GATE_LOCK="$LOCK" BATON_DERIVED_DATA="$WORK/dd-prio-release" ALLOW_PRIMARY_CHECKOUT=1 \
    BATON_GATE_LOCK_WAIT=30 BATON_GATE_LOCK_PROBE=1 "$RELEASE" >"$WORK/prio-release.out" 2>&1 &
  prio_release=$!
  EXTRA_PIDS="$EXTRA_PIDS $prio_release"
  if ! await "$INTENT" "$prio_release"; then
    bad "a waiting release wrote no intent. Got: $(cat "$WORK/prio-release.out")"
  else
    BATON_GATE_LOCK="$LOCK" BATON_DERIVED_DATA="$WORK/dd-prio-gate" SKIP_IOS=1 \
      BATON_GATE_LOCK_WAIT=30 BATON_GATE_LOCK_PROBE=0 "$GATE" >"$WORK/prio-gate.out" 2>&1 &
    prio_gate=$!
    EXTRA_PIDS="$EXTRA_PIDS $prio_gate"
    wait "$prio_release"; release_rc=$?
    wait "$prio_gate"; gate_rc=$?
    if [ "$release_rc" != 0 ] || [ "$gate_rc" != 0 ]; then
      bad "release ($release_rc) or gate ($gate_rc) did not finish. Release: $(cat "$WORK/prio-release.out") Gate: $(cat "$WORK/prio-gate.out")"
    elif ! grep -q "waiting for release pid $prio_release" "$WORK/prio-gate.out"; then
      bad "the late gate did not queue behind the release. Got: $(cat "$WORK/prio-gate.out")"
    elif grep -q "waiting for gate pid $prio_gate" "$WORK/prio-release.out"; then
      bad "the late gate overtook the waiting release"
    elif [ -e "$INTENT" ]; then
      bad "the release left its intent behind after acquiring"
    else
      ok "a waiting release gets the host before a gate that arrived after it"
    fi
  fi
fi
wait "$LAUNCHER" 2>/dev/null; HOLDER=""; LAUNCHER=""

# --- 18. One simulator per run; different simulators side by side -------------------------

rm -f "$WORK/sim-a.out"
native_hold sim-AAAA-1111 3 "$WORK/sim-a.out"
sim_holder=$!
EXTRA_PIDS="$EXTRA_PIDS $sim_holder"
if ! await "$WORK/sim-a.out" "held by"; then
  bad "the simulator holder never took sim-AAAA-1111. Got: $(cat "$WORK/sim-a.out")"
else
  sim_pid="$(sed -n 's/^held by //p' "$WORK/sim-a.out")"
  record_lines="$(wc -l <"$NATIVE_LOCK_DIR/sim-AAAA-1111.lock" | tr -d ' ')"
  out="$(BATON_GATE_LOCK_WAIT=0 native_try sim-BBBB-2222)"; rc=$?
  if [ "$rc" != 0 ]; then
    bad "a different simulator was refused while sim-AAAA-1111 was held. Got: $out"
  else
    ok "a different simulator's lock is taken at once, alongside the held one"
  fi
  out="$(BATON_GATE_LOCK_WAIT=0 native_try sim-AAAA-1111)"; rc=$?
  if [ "$rc" = 0 ]; then
    bad "two runs held the same simulator at once"
  elif ! grep -q <<<"$out" "another gate holds sim-AAAA-1111 (pid $sim_pid"; then
    bad "the same-simulator refusal does not name its holder. Got: $out"
  else
    ok "the same simulator is refused to a second run, naming the holder"
  fi
  out="$(BATON_GATE_LOCK_WAIT=20 native_try sim-AAAA-1111)"; rc=$?
  if [ "$rc" != 0 ] || ! grep -q <<<"$out" "acquired sim-AAAA-1111"; then
    bad "a waiting run did not get the simulator once it was free. Got: $out"
  elif [ "$(printf '%s\n' "$out" | grep -c "waiting for gate pid $sim_pid")" != 1 ]; then
    bad "the simulator wait did not name its holder exactly once. Got: $out"
  else
    ok "the same simulator serializes: the second run waits, then gets it"
  fi
  if [ "$record_lines" = 5 ]; then
    ok "a named lock keeps the five-line record under NATIVE_LOCK_DIR"
  else
    bad "sim-AAAA-1111.lock had $record_lines lines, expected 5"
  fi
fi
wait "$sim_holder" 2>/dev/null

# --- 19. Runs that host no Baton.app take no mac-app-host lock ----------------------------

rm -f "$LOCK"
if ! start_holder 30; then
  bad "the holder never took the lock; the no-lock paths were not tested"
else
  mkdir -p "$WORK/empty-src"
  before="$(find "$NATIVE_LOCK_DIR" -type f 2>/dev/null | sort)"
  lock_before="$(cat "$LOCK")"
  start_s=$(date +%s)
  out="$(BATON_GATE_LOCK="$LOCK" BATON_GATE_LOCK_WAIT=0 BATON_DERIVED_DATA="$WORK/dd-lint" \
    LINT_ONLY=1 BATON_LINT_SRC="$WORK/empty-src" BATON_IMPORT_LINT_SRC="$WORK/empty-src" \
    BATON_DASH_LINT_SRC="$WORK/empty-src" "$GATE" 2>&1)"; rc=$?
  elapsed=$(( $(date +%s) - start_s ))
  after="$(find "$NATIVE_LOCK_DIR" -type f 2>/dev/null | sort)"
  if [ "$rc" != 0 ]; then
    bad "a lint-only run failed while the test host was busy. Got: $out"
  elif grep -qE <<<"$out" "another Baton|waiting for|GATE LOCK"; then
    bad "a lint-only run touched the gate lock. Got: $out"
  elif [ "$before" != "$after" ] || [ "$lock_before" != "$(cat "$LOCK")" ]; then
    bad "a lint-only run created or changed a lock record"
  else
    ok "a lint-only run takes no lock and runs beside a busy test host (${elapsed}s)"
  fi

  out="$(contend -only-testing:BatonDSPTests -only-testing:BatonAgentKitTests/SomeTests)"; rc=$?
  if [ "$rc" != 0 ] || ! grep -q <<<"$out" "not taken; this run hosts no Baton.app"; then
    bad "a package-only -only-testing run waited for the test host. Got: $out"
  else
    ok "a run filtered to package suites takes no mac-app-host lock"
  fi
  out="$(contend -only-testing:BatonDSPTests -only-testing:BatonTests/ScrobbleTests)"; rc=$?
  if [ "$rc" = 0 ]; then
    bad "a run that includes BatonTests skipped the test-host lock"
  else
    ok "a run whose filter includes BatonTests still takes the test-host lock"
  fi
fi
kill -9 "$HOLDER" 2>/dev/null; wait "$LAUNCHER" 2>/dev/null; HOLDER=""; LAUNCHER=""
sleep 0.5

# --- 20. Tonebox's hosted-test controller still reads what it expects --------------------
#
# Its wrappers source gate-lock.sh, call `gate_lock_acquire KIND DERIVED "$0" ARGS`, then
# start a Python child that requires: five lines; line 1 = its parent's pid; line 3 = the
# wrapper's working directory; line 4 = the derived data; line 5 = the kind. Then they call
# gate_lock_release. This is that shape, against the temporary lock.

rm -f "$LOCK"
mkdir -p "$WORK/tonebox-repo"
cat >"$WORK/tonebox-wrapper.sh" <<WRAP
#!/bin/bash
set -euo pipefail
. "$ROOT/scripts/gate-lock.sh"
cd "$WORK/tonebox-repo"
gate_lock_acquire tonebox-tbx-9438-ios "$WORK/out/derived-data" "\$0" acceptance "$WORK/out"
python3 -c '
import os, sys
owner = open(sys.argv[1]).read().splitlines()
ok = (len(owner) == 5 and owner[0] == str(os.getppid()) and owner[2] == sys.argv[2]
      and owner[3] == sys.argv[3] and owner[4] == "tonebox-tbx-9438-ios")
print("CONTRACT", "ok" if ok else "broken", owner)
sys.exit(0 if ok else 1)
' "$LOCK" "\$PWD" "$WORK/out/derived-data" || { echo "CONTRACT broken"; exit 1; }
gate_lock_release
[ ! -s "$LOCK" ] || { echo "RECORD LEFT"; exit 1; }
echo "RELEASED"
WRAP
chmod +x "$WORK/tonebox-wrapper.sh"
out="$(BATON_GATE_LOCK="$LOCK" "$WORK/tonebox-wrapper.sh" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q <<<"$out" "CONTRACT ok" && grep -q <<<"$out" RELEASED; then
  ok "Tonebox's controller contract: five lines naming the wrapper, its cwd, derived data and kind"
else
  bad "Tonebox's controller would reject the record or its release. Got: $out"
fi

# --- 22. Signals to the owner's whole process group leave the lock with its owner -------
#
# Review finding B1 (2026-10-16): the holder used to take any TERM as a release, so a timeout
# or tree kill that sent TERM to the group freed the lock while a Tonebox-style owner, which
# traps TERM and keeps custody, was still running. Each signal goes to a fresh owner in its own
# session; afterwards the owner must be alive, the KERNEL lock still held (an old-style
# `lockf -k` probe is refused) and a contender refused.

cat >"$WORK/trap-owner.sh" <<OWNER
#!/bin/bash
red() { printf '%s\n' "\$*" >&2; }; yellow() { printf '%s\n' "\$*" >&2; }
. "$ROOT/scripts/gate-lock.sh"
cd "$WORK"
gate_lock_acquire tonebox-test "$WORK/dd-trap" "\$0"
trap 'echo "owner \$\$ kept custody" >>"$WORK/trap-owner.log"' INT TERM HUP QUIT
echo "owner \$\$ holds" >>"$WORK/trap-owner.log"
while [ ! -e "$WORK/trap-owner.stop" ]; do sleep 0.1 || true; done
gate_lock_release
echo "owner \$\$ released" >>"$WORK/trap-owner.log"
OWNER
chmod +x "$WORK/trap-owner.sh"

start_trap_owner() {   # starts a session leader owner; sets TRAP_OWNER
  rm -f "$WORK/trap-owner.log" "$WORK/trap-owner.stop" "$LOCK"
  : >"$WORK/trap-owner.log"
  python3 -c 'import os, sys; os.setsid(); os.execv(sys.argv[1], sys.argv[1:])' \
    "$WORK/trap-owner.sh" >/dev/null 2>&1 &
  EXTRA_PIDS="$EXTRA_PIDS $!"
  await "$WORK/trap-owner.log" "holds" || return 1
  TRAP_OWNER="$(sed -n 's/^owner \([0-9]*\) holds$/\1/p' "$WORK/trap-owner.log")"
}

for sig in INT HUP QUIT TERM; do
  if ! start_trap_owner; then
    bad "group $sig: the trapping owner never took the lock"
    continue
  fi
  kill -"$sig" -- "-$TRAP_OWNER" 2>/dev/null
  sleep 0.6
  kernel=held
  /usr/bin/lockf -s -t 0 -k "$LOCK" true 2>/dev/null && kernel=free
  out="$(contend)"; rc=$?
  if ! kill -0 "$TRAP_OWNER" 2>/dev/null; then
    bad "group $sig: the trapping owner died, so the case was not tested"
  elif [ "$kernel" != held ]; then
    bad "group $sig freed the kernel lock while its owner kept custody"
  elif [ "$rc" = 0 ] || ! grep -q <<<"$out" "pid $TRAP_OWNER"; then
    bad "group $sig let a contender in beside a live owner. Got: $out"
  else
    ok "a group $sig leaves the lock with an owner that traps it (kernel lock held, contender refused)"
  fi
  kill -9 -- "-$TRAP_OWNER" 2>/dev/null
  sleep 0.6
done

# --- 23. TERM to the holder alone does not release; only its owner does -----------------

if start_trap_owner; then
  # The holder is the owner's own background child.
  holder="$(pgrep -P "$TRAP_OWNER" -f native-lock.sh | head -1)"
  if [ -z "$holder" ]; then
    bad "could not find the holder process for the trapping owner"
  else
    kill -TERM "$holder" 2>/dev/null
    sleep 0.6
    out="$(contend)"; rc=$?
    if kill -0 "$holder" 2>/dev/null && [ "$rc" != 0 ]; then
      ok "TERM to the holder itself (pkill -f native-lock.sh) does not free the lock"
    else
      bad "TERM to the holder freed the lock (holder alive: $(kill -0 "$holder" 2>/dev/null && echo yes || echo no)). Got: $out"
    fi

    # --- 24. A holder SIGKILLed under a live owner: busy until the owner releases --------
    kill -9 "$holder" 2>/dev/null
    sleep 0.4
    out="$(contend)"; rc=$?
    if [ "$rc" = 0 ]; then
      bad "with its holder SIGKILLed, a live owner's resource was handed to a contender"
    else
      ok "a live owner whose holder was SIGKILLed still holds the resource by its record"
    fi
    : >"$WORK/trap-owner.stop"
    await "$WORK/trap-owner.log" "released" || true
    out="$(contend)"; rc=$?
    if kill -0 "$TRAP_OWNER" 2>/dev/null || grep -q released "$WORK/trap-owner.log"; then
      if [ "$rc" = 0 ] && [ ! -s "$LOCK" ]; then
        ok "the owner's own release clears its record after its holder was killed"
      else
        bad "the owner released, but its record still blocks the next run. Got: $out"
      fi
    fi
  fi
  kill -9 -- "-$TRAP_OWNER" 2>/dev/null
  sleep 0.4
fi

# --- 25. A lock taken in a subshell belongs to that subshell ------------------------------

rm -f "$LOCK"
out="$(BATON_GATE_LOCK_WAIT=0 /bin/bash -c '. "$1/scripts/native-lock.sh"
  ( native_lock_acquire sim-SUBSHELL gate x >/dev/null 2>&1 && echo "subshell acquired" )
  sleep 0.6
  if native_lock_acquire sim-SUBSHELL gate y; then echo "parent acquired after subshell exit"; fi
  native_lock_release_all' _ "$ROOT" 2>&1)"
if grep -q <<<"$out" "subshell acquired" \
   && grep -q <<<"$out" "parent acquired after subshell exit"; then
  ok "a lock taken in a subshell names the subshell and is freed when it exits"
else
  bad "a subshell's lock outlived the subshell. Got: $out"
fi

# --- 26. An older whole-run holder holds every resource, as before -----------------------
#
# Review finding S1: a checkout from before an internal task holds only /tmp/baton-gate.lock, for its
# whole run, under `lockf -k`. New runs must treat it as holding simulators and DerivedData too.

rm -f "$LOCK"
/usr/bin/lockf -s -k "$LOCK" /bin/bash -c '
  printf "%s\n%s\n%s\n%s\n%s\n" "$$" "$(ps -o lstart= -p $$ | sed "s/^[[:space:]]*//;s/[[:space:]]*$//")" \
    /tmp/old-checkout /tmp/baton-dd gate >"$1"
  sleep 3' _ "$LOCK" &
legacy_lockf=$!
EXTRA_PIDS="$EXTRA_PIDS $legacy_lockf"
for _ in $(seq 1 100); do [ -s "$LOCK" ] && break; sleep 0.05; done
legacy_pid="$(sed -n '1p' "$LOCK")"
out="$(BATON_GATE_LOCK_WAIT=0 native_try sim-LEGACY)"; rc=$?
if [ "$rc" != 0 ] && grep -q <<<"$out" "another gate holds sim-LEGACY (pid $legacy_pid"; then
  ok "an older whole-run gate is treated as holding a simulator too"
else
  bad "a simulator was handed out while an older whole-run gate held the machine. Got: $out"
fi
out="$(BATON_GATE_LOCK_WAIT=20 native_try sim-LEGACY)"; rc=$?
if [ "$rc" = 0 ] && grep -q <<<"$out" "an older Baton script holds every resource" \
   && grep -q <<<"$out" "acquired sim-LEGACY"; then
  ok "a run waits for the older whole-run gate, says why, and continues when it ends"
else
  bad "the wait for an older whole-run gate did not behave. Got: $out"
fi
wait "$legacy_lockf" 2>/dev/null

# --- 27. The Mac step ends this run's own leftover test host, and only its own ------------
#
# Review finding S2. Stand-in hosts run sleep from the paths a test host runs from.

rm -f "$LOCK"
for dd in dd-reap dd-other; do
  mkdir -p "$WORK/$dd/Build/Products/Debug/Baton.app/Contents/MacOS"
  # A symlink, not a copy: a copied system binary is killed at launch for its signature.
  ln -sf /bin/sleep "$WORK/$dd/Build/Products/Debug/Baton.app/Contents/MacOS/Baton"
done
"$WORK/dd-reap/Build/Products/Debug/Baton.app/Contents/MacOS/Baton" 120 & own_host=$!
"$WORK/dd-other/Build/Products/Debug/Baton.app/Contents/MacOS/Baton" 120 & other_host=$!
EXTRA_PIDS="$EXTRA_PIDS $own_host $other_host"
sleep 0.2
if ! kill -0 "$own_host" 2>/dev/null || ! kill -0 "$other_host" 2>/dev/null; then
  bad "the stand-in test hosts did not start, so reaping was not tested"
fi
out="$(BATON_GATE_LOCK="$LOCK" BATON_DERIVED_DATA="$WORK/dd-reap" SKIP_IOS=1 \
  BATON_GATE_LOCK_WAIT=0 BATON_GATE_LOCK_PROBE=0 "$GATE" 2>&1)"; rc=$?
sleep 0.3
if [ "$rc" != 0 ]; then
  bad "the reaping probe failed. Got: $out"
elif kill -0 "$own_host" 2>/dev/null; then
  bad "this run's own leftover test host survived the end of its Mac step"
elif ! kill -0 "$other_host" 2>/dev/null; then
  bad "the Mac step ended ANOTHER run's test host"
elif ! grep -q <<<"$out" "ending this run's leftover test host"; then
  bad "the Mac step ended its test host without saying so. Got: $out"
else
  ok "the Mac step ends its own leftover test host before releasing mac-app-host, and no other"
fi
kill -9 "$other_host" 2>/dev/null

# --- 21. Wiring: each lock wraps only its own step -----------------------------------------
#
# A lock that drifts back to the top of test.sh serializes every step again; one that drifts
# off the Mac step lets two runs host Baton.app together.

mac_lock_line="$(grep -n '^mac_step_lock "\$@"$' scripts/test.sh | cut -d: -f1)"
mac_unlock_line="$(grep -n '^mac_step_unlock$' scripts/test.sh | cut -d: -f1)"
mac_test_line="$(grep -n '^xcodebuild test \\$' scripts/test.sh | cut -d: -f1)"
if [ -z "$mac_lock_line" ] || [ -z "$mac_unlock_line" ] || [ -z "$mac_test_line" ]; then
  bad "wiring: cannot find the Mac step's lock, unlock or xcodebuild test in scripts/test.sh"
elif [ "$mac_lock_line" -ge "$mac_test_line" ] || [ "$mac_unlock_line" -le "$mac_test_line" ] \
     || [ $((mac_test_line - mac_lock_line)) -gt 8 ] || [ $((mac_unlock_line - mac_test_line)) -gt 14 ]; then
  bad "wiring: mac-app-host no longer wraps just the Mac xcodebuild test (lock $mac_lock_line, test $mac_test_line, unlock $mac_unlock_line)"
elif ! grep -q -- '-scheme "\$SCHEME"' <<<"$(sed -n "${mac_test_line},$((mac_test_line + 3))p" scripts/test.sh)"; then
  bad "wiring: the locked xcodebuild test is not the Baton scheme's"
else
  ok "wiring: mac-app-host is held around the Mac app-hosted xcodebuild test and nothing else"
fi

if [ "$(grep -c 'gate_lock_acquire' scripts/test.sh)" = 1 ] \
   && grep -q 'gate_lock_acquire gate' <<<"$(grep -A6 '^mac_step_lock()' scripts/test.sh)"; then
  ok "wiring: test.sh takes mac-app-host only inside the Mac step"
else
  bad "wiring: test.sh takes mac-app-host somewhere other than the Mac step"
fi

sim_lock_line="$(grep -n 'step_lock "sim-\$IOS_SIM_UDID"' scripts/test.sh | cut -d: -f1)"
sim_unlock_line="$(grep -n 'step_unlock "sim-\$IOS_SIM_UDID"' scripts/test.sh | cut -d: -f1)"
ios_test_line="$(grep -n '^    xcodebuild test \\$' scripts/test.sh | cut -d: -f1)"
if [ -n "$sim_lock_line" ] && [ -n "$sim_unlock_line" ] && [ -n "$ios_test_line" ] \
   && [ "$sim_lock_line" -lt "$ios_test_line" ] && [ "$ios_test_line" -lt "$sim_unlock_line" ] \
   && grep -q 'id=\$IOS_SIM_UDID' <<<"$(sed -n "${ios_test_line},$((ios_test_line + 3))p" scripts/test.sh)"; then
  ok "wiring: the iPhone simulator step holds sim-<UDID> for its own device"
else
  bad "wiring: the iPhone simulator step is not wrapped in its sim-<UDID> lock"
fi

if grep -q "trap native_lock_release_all EXIT INT TERM" scripts/test.sh; then
  ok "wiring: test.sh releases every lock on EXIT, INT and TERM"
else
  bad "wiring: nothing releases test.sh's locks when the run ends"
fi

release_lock_line="$(grep -n 'gate_lock_acquire release ' scripts/publish.sh | cut -d: -f1)"
release_dd_line="$(grep -n 'native_lock_acquire "\$(native_lock_derived_name "\$DD")" release' scripts/publish.sh | cut -d: -f1)"
reap_line="$(grep -n '^reap_test_hosts$' scripts/publish.sh | head -1 | cut -d: -f1)"
if [ -z "$release_lock_line" ] || [ -z "$reap_line" ] || [ -z "$release_dd_line" ]; then
  bad "wiring: cannot find the release's acquires or its first test-host reap"
elif [ "$release_lock_line" -ge "$reap_line" ]; then
  bad "wiring: publish.sh can reap a test host at line $reap_line before locking at line $release_lock_line"
elif [ "$release_dd_line" -ge "$release_lock_line" ]; then
  bad "wiring: publish.sh takes mac-app-host before its own build tree, against the lock order"
else
  ok "wiring: publish.sh owns its build tree, then the test host, before its first reap"
fi

pack_reap="$(grep -n '^reap_test_hosts$' scripts/publish.sh | tail -1 | cut -d: -f1)"
pack_release="$(awk -v from="$pack_reap" 'NR > from && /^gate_lock_release$/ { print NR; exit }' scripts/publish.sh)"
hdiutil_line="$(grep -n '^hdiutil create' scripts/publish.sh | cut -d: -f1)"
if [ -n "$pack_release" ] && [ -n "$hdiutil_line" ] && [ "$pack_reap" -lt "$pack_release" ] \
   && [ "$pack_release" -lt "$hdiutil_line" ]; then
  ok "wiring: publish.sh hands the test host back after its last reap, before notarization"
else
  bad "wiring: publish.sh holds mac-app-host past its last reap (reap $pack_reap, release ${pack_release:-none})"
fi

publish_cleanup_body="$(sed -n '/^publish_cleanup() {/,/^}/p' scripts/publish.sh)"
if grep -q '^trap publish_cleanup EXIT$' scripts/publish.sh \
   && grep -q "^trap 'exit 130' INT$" scripts/publish.sh \
   && grep -q "^trap 'exit 143' TERM$" scripts/publish.sh \
   && grep -q 'gate_lock_release' <<<"$publish_cleanup_body" \
   && grep -q 'native_lock_release_all' <<<"$publish_cleanup_body"; then
  ok "wiring: the release releases every lock and intent through every exit path"
else
  bad "wiring: publish.sh does not release its locks from its shared exit cleanup"
fi

if grep -q 'cmp -s "$NATIVE_LOCK_CANONICAL" scripts/release-kit/lib/native-lock.sh' scripts/test.sh; then
  ok "wiring: the gate compares the kit's native-lock module with the shared _method copy"
else
  bad "wiring: nothing compares the kit's native-lock module with the shared _method copy"
fi

# The protocol lives in the release kit, pinned by its manifest. Baton's file only
# configures it; a lock function defined here again would fork the protocol.
if grep -q '^\. "$(cd "$(dirname "${BASH_SOURCE\[0\]}")" && pwd)/release-kit/lib/native-lock.sh"$' scripts/native-lock.sh \
   && ! grep -qE '^(native_lock_acquire|native_lock_release|_nl_serve|_nl_attempt)\(\)' scripts/native-lock.sh; then
  ok "scripts/native-lock.sh configures the release kit's module and keeps no lock code of its own"
else
  bad "scripts/native-lock.sh no longer just configures scripts/release-kit/lib/native-lock.sh"
fi

if grep -q 'reap_own_test_hosts' <<<"$(grep -A4 '^mac_step_unlock()' scripts/test.sh)"; then
  ok "wiring: the Mac step ends its own leftover test host before giving up mac-app-host"
else
  bad "wiring: mac_step_unlock gives up mac-app-host without ending its own test host"
fi

if grep -q 'BATON_GATE_LOCK_PRIORITY=release ./scripts/test.sh' "$TESTFLIGHT"; then
  ok "wiring: TestFlight's gate runs with release priority"
else
  bad "wiring: TestFlight's gate does not ask for release priority"
fi

# --- 28. Baton's defaults are Tonebox's interface (review K3) -------------------
#
# Every case above moves the locks to temporary paths. This one only RESOLVES the defaults, in
# a clean environment, without taking, reading or signalling any lock: Tonebox's controller
# reads /tmp/baton-gate.lock and its custody matches /tmp/native-locks, and callers set
# BATON_GATE_LOCK_*.
defaults="$(env -u BATON_GATE_LOCK -u NATIVE_LOCK_DIR -u NATIVE_LOCK_HOST_FILE -u BATON_GATE_LOCK_WAIT \
  /bin/bash -c '. "$1/scripts/gate-lock.sh"
  printf "%s\n" "$GATE_LOCK" "$(native_lock_path mac-app-host)" "$NATIVE_LOCK_DIR" \
    "$(native_lock_intent_path mac-app-host)" "$(native_lock_path sim-X)" "$(_nl_knob WAIT)" \
    "$(BATON_GATE_LOCK_WAIT=7 _nl_env WAIT)" "$(BATON_GATE_LOCK_PRIORITY=release _nl_env PRIORITY)" \
    "$(BATON_GATE_LOCK_ACTIVE_OWNER_PID=42 _nl_env ACTIVE_OWNER_PID)"' _ "$ROOT" 2>&1)"
expected="/tmp/baton-gate.lock
/tmp/baton-gate.lock
/tmp/native-locks
/tmp/native-locks/mac-app-host.release-intent
/tmp/native-locks/sim-X.lock
BATON_GATE_LOCK_WAIT
7
release
42"
if [ "$defaults" = "$expected" ]; then
  ok "Baton's defaults: mac-app-host is /tmp/baton-gate.lock, others and the intent under /tmp/native-locks, knobs named BATON_GATE_LOCK_*"
else
  bad "Baton's default lock paths or knob names changed. Got: $defaults"
fi
moved="$(env -u NATIVE_LOCK_DIR BATON_GATE_LOCK="$WORK/moved/gate.lock" /bin/bash -c '. "$1/scripts/native-lock.sh"
  printf "%s %s\n" "$(native_lock_path mac-app-host)" "$(native_lock_intent_path mac-app-host)"' _ "$ROOT" 2>&1)"
if [ "$moved" = "$WORK/moved/gate.lock $WORK/moved/native-locks/mac-app-host.release-intent" ]; then
  ok "BATON_GATE_LOCK still moves the lock, and the other locks and the intent move beside it"
else
  bad "BATON_GATE_LOCK no longer moves the locks together. Got: $moved"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
