#!/usr/bin/env bash
# test-native-lock.sh: the named native-resource locks hold one owner per resource, survive
# signals sent to the owner's process group, never wedge on a dead owner's record, wait a
# bounded time naming the holder once, let a waiting release go first, let a release's direct
# child inherit, and keep the five-line record other tools read. Every lock lives under a
# temporary directory: nothing here reads, takes or signals a real lock in /tmp.
# RK_NATIVE_LOCK_SUBJECT points at a mutated copy. About forty seconds; no build, no network.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUBJECT="${RK_NATIVE_LOCK_SUBJECT:-$HERE/../lib/native-lock.sh}"
[ -f "$SUBJECT" ] || { echo "FAIL  no module at $SUBJECT"; exit 1; }
[ -x /usr/bin/lockf ] || { echo "SKIP  /usr/bin/lockf is needed (macOS)"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

# A caller of this test (a gate or a release) may have exported knobs; none may steer it.
unset NATIVE_LOCK_ENV NATIVE_LOCK_HOST_VAR NATIVE_LOCK_HOST_DEFAULT NATIVE_LOCK_PROJECT \
  NATIVE_LOCK_WAIT NATIVE_LOCK_PRIORITY NATIVE_LOCK_ACTIVE_OWNER_PID NATIVE_LOCK_TEST_BARRIER
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/rk-native-lock.XXXXXX")" && pwd -P)"
export SUBJECT
export NATIVE_LOCK_HOST_FILE="$WORK/host.lock"
export NATIVE_LOCK_DIR="$WORK/native-locks"
export NATIVE_LOCK_POLL=0.1
HOST="$NATIVE_LOCK_HOST_FILE"
INTENT="$(/bin/bash -c '. "$SUBJECT"; native_lock_intent_path mac-app-host')"
PIDS=""
cleanup() {
  local pid
  for pid in $PIDS; do kill -9 -- "-$pid" 2>/dev/null; kill -9 "$pid" 2>/dev/null; done
  sleep 0.5   # holders notice their owner's death within a fraction of a second
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 1' INT TERM ALRM
# Every call that could wait is bounded, so a broken module fails here instead of hanging.
# An array, not a function: `"${BOUNDED[@]}" cmd &` makes $! the command's own pid.
BOUNDED=(perl -e 'alarm shift; exec @ARGV or exit 127' "${RK_TEST_CALL_LIMIT:-40}")

await() {   # $1 = file, $2 = fixed string; up to ~10 s
  local _
  for _ in $(seq 1 200); do
    grep -qF -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.05
  done
  return 1
}
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'; }
lstart() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
plant() {   # $1 = file, $2 = pid, $3 = cwd, $4 = kind
  mkdir -p "$(dirname "$1")"
  printf '%s\n%s\n%s\n%s\n%s\n' "$2" "$(lstart "$2")" "$3" /tmp/app-dd "$4" >"$1.tmp" && mv -f "$1.tmp" "$1"
}
stand_in() { sleep 60 >/dev/null 2>&1 & PIDS="$PIDS $!"; STANDIN=$!; disown "$STANDIN" 2>/dev/null || true; }
kernel_free() { /usr/bin/lockf -s -t 0 -k "$1" true 2>/dev/null; }

# An owner that holds NAME until its stop file appears, then releases it. With TRAP=1 it
# traps INT, TERM, HUP and QUIT and keeps custody, as a careful controller does.
cat >"$WORK/owner.sh" <<'OWNER'
#!/bin/bash
. "$SUBJECT"
name="$1" kind="$2" log="$3" stop="$4"
export NATIVE_LOCK_WAIT="${OWNER_WAIT:-20}"   # an owner that cannot get its lock gives up
native_lock_acquire "$name" "$kind" "$WORK_DD" || { echo "refused" >>"$log"; exit 1; }
if [ -n "${TRAP:-}" ]; then trap 'echo "kept custody" >>"$log"' INT TERM HUP QUIT; fi
[ -z "${EXPORT_OWNER:-}" ] || export NATIVE_LOCK_ACTIVE_OWNER_PID="$$"
echo "owner $$ holds" >>"$log"
if [ -n "${CHILD:-}" ]; then
  /bin/bash -c '. "$SUBJECT"; if native_lock_inherit "$1"; then echo "child inherited"; else echo "child refused"; fi' _ "$name" >>"$log" 2>&1
  # The trailing `; true` keeps the middle shell alive, so the inner one is a grandchild.
  /bin/bash -c '/bin/bash -c ". \"\$SUBJECT\"; if native_lock_inherit \"\$1\"; then echo grandchild inherited; else echo grandchild refused; fi" _ "$1"; true' _ "$name" >>"$log" 2>&1
fi
until [ -e "$stop" ] || [ "$SECONDS" -gt 120 ]; do sleep 0.1 || true; done
native_lock_release_all
echo "owner $$ released" >>"$log"
OWNER
chmod +x "$WORK/owner.sh"
export WORK_DD="$WORK/dd-owner"

start_owner() {   # name kind tag [env...]; sets OWNER and LOG, STOP
  local name="$1" kind="$2" tag="$3"; shift 3
  LOG="$WORK/$tag.log"; STOP="$WORK/$tag.stop"; rm -f "$LOG" "$STOP"; : >"$LOG"
  env "$@" python3 -c 'import os, sys; os.setsid(); os.execv(sys.argv[1], sys.argv[1:])' \
    "$WORK/owner.sh" "$name" "$kind" "$LOG" "$STOP" >/dev/null 2>&1 &
  PIDS="$PIDS $!"
  disown "$!" 2>/dev/null || true   # killed on purpose below; no job notices
  await "$LOG" "holds" || return 1
  OWNER="$(sed -n 's/^owner \([0-9]*\) holds$/\1/p' "$LOG")"
}
stop_owner() { : >"$STOP"; await "$LOG" "released" || true; }

try() {   # name [kind]; prints output, returns status (env from the caller)
  "${BOUNDED[@]}" /bin/bash -c '. "$SUBJECT"; native_lock_acquire "$1" "$2" "$3" || exit 1
    echo "acquired $1 by $$"; native_lock_release "$1"' _ "$1" "${2:-gate}" "$WORK/dd-try" 2>&1
}

# --- The record and the refusal ---------------------------------------------------------

mkdir -p "$WORK/owner-cwd"
cd "$WORK/owner-cwd" || exit 1
if ! start_owner mac-app-host gate rec || [ -z "$OWNER" ]; then
  bad "an owner never took mac-app-host; nothing below can be trusted"
  echo "native-lock: $PASS passed, $FAIL failed"; exit 1
fi
cd "$WORK" || exit 1
if [ "$(sed -n '1p' "$HOST")" = "$OWNER" ] && [ "$(sed -n '2p' "$HOST")" = "$(lstart "$OWNER")" ] \
   && [ "$(sed -n '3p' "$HOST")" = "$WORK/owner-cwd" ] && [ "$(sed -n '4p' "$HOST")" = "$WORK/dd-owner" ] \
   && [ "$(sed -n '5p' "$HOST")" = gate ] && [ "$(wc -l <"$HOST" | tr -d ' ')" = 5 ]; then
  ok "the record is five lines: owner pid, its start time, cwd, derived data, kind"
else
  bad "the record is not the five-line contract: $(cat "$HOST")"
fi
kernel_free "$HOST" && bad "the kernel lock is free while an owner holds it" || ok "the kernel lock is held while the owner holds it"
start_s=$(date +%s)
out="$(NATIVE_LOCK_WAIT=0 try mac-app-host)"; rc=$?
if [ "$rc" = 1 ] && grep -qF "another gate holds mac-app-host (pid $OWNER, started" <<<"$out" \
   && grep -qF "$WORK/owner-cwd" <<<"$out" && grep -qF "Its derived data: $WORK/dd-owner" <<<"$out" \
   && grep -qF "set NATIVE_LOCK_WAIT to wait longer" <<<"$out" && [ $(( $(date +%s) - start_s )) -le 2 ]; then
  ok "NATIVE_LOCK_WAIT=0 refuses at once, naming pid, start time, cwd and derived data"
else
  bad "the refusal is wrong or slow. Got: $out"
fi
out="$(NATIVE_LOCK_WAIT=0 "${BOUNDED[@]}" /bin/bash -c '. "$SUBJECT"
  native_lock_host_refusal() { echo "PROJECT WORDING kind=$1 pid=$2"; }
  native_lock_acquire mac-app-host gate x' 2>&1)"
if grep -qF "PROJECT WORDING kind=gate pid=$OWNER" <<<"$out" && ! grep -q "another gate holds" <<<"$out"; then
  ok "a project's native_lock_host_refusal replaces the mac-app-host wording"
else
  bad "the host refusal hook was not used. Got: $out"
fi
out="$(NATIVE_LOCK_WAIT=soon try sim-X)"; rc=$?
[ "$rc" = 1 ] && grep -q "NATIVE_LOCK_WAIT must be whole seconds" <<<"$out" \
  && ok "a wait that is not whole seconds is refused" || bad "a bad wait was accepted. Got: $out"
out="$(NATIVE_LOCK_WAIT=0 try 'sim/../x')"; rc=$?
[ "$rc" = 1 ] && grep -q "invalid resource name" <<<"$out" \
  && ok "a resource name with a path in it is refused" || bad "a path-like name was accepted. Got: $out"
stop_owner
if [ ! -s "$HOST" ] && kernel_free "$HOST"; then
  ok "the owner's release empties the record and frees the kernel lock"
else
  bad "after release: record '$(cat "$HOST")', kernel $(kernel_free "$HOST" && echo free || echo held)"
fi

# --- A dead owner never wedges the next run ---------------------------------------------

start_owner sim-STALE gate stale || bad "the stale-case owner never took its lock"
kill -9 -- "-$OWNER" 2>/dev/null; sleep 0.6
out="$(NATIVE_LOCK_WAIT=0 try sim-STALE)"; rc=$?
[ "$rc" = 0 ] && grep -q "clearing a stale sim-STALE lock (recorded pid $OWNER)" <<<"$out" \
  && ok "a SIGKILLed owner's record is reported as stale and the next run proceeds" \
  || bad "a dead owner's record blocked or was cleared silently. Got: $out"
printf '%s\n%s\n%s\n%s\n%s\n' 999999 "Mon Jan  1 00:00:00 2001" /tmp/old /tmp/app-dd gate >"$HOST"
out="$(NATIVE_LOCK_WAIT=0 try mac-app-host)"; rc=$?
[ "$rc" = 0 ] && grep -q "clearing a stale gate lock (recorded pid 999999)" <<<"$out" \
  && ok "a mac-app-host record naming a dead pid is cleared as a stale gate lock" || bad "dead mac-app-host record: $out"
printf '%s\n%s\n%s\n%s\n%s\n' "$$" "Mon Jan  1 00:00:00 2001" /tmp/old /tmp/app-dd gate >"$HOST"
out="$(NATIVE_LOCK_WAIT=0 try mac-app-host)"; rc=$?
[ "$rc" = 0 ] && grep -q "clearing a stale gate lock" <<<"$out" \
  && ok "a live but reused pid (another start time) cannot impersonate an owner" || bad "a reused pid wedged the lock. Got: $out"
: >"$HOST"
out="$(NATIVE_LOCK_WAIT=0 try mac-app-host)"; rc=$?
[ "$rc" = 0 ] && ok "an empty lock file does not block a run" || bad "an empty lock file blocked. Got: $out"
# A live owner in the record without the kernel lock (an older pidfile guard) is busy.
printf '%s\n%s\n%s\n%s\n' "$$" "$(lstart $$)" /tmp/pidfile-guard /tmp/app-dd >"$HOST"
out="$(NATIVE_LOCK_WAIT=0 try mac-app-host)"; rc=$?
[ "$rc" = 1 ] && grep -qF "pid $$" <<<"$out" \
  && ok "a live owner named only by its record (an older pidfile guard) is busy" || bad "a live pidfile owner was overrun. Got: $out"
: >"$HOST"

# --- Two simultaneous stale reclaimers: one owner ---------------------------------------

printf '%s\n%s\n%s\n%s\n%s\n' 999999 "Mon Jan  1 00:00:00 2001" /tmp/old /tmp/app-dd gate >"$HOST"
rm -f "$WORK"/race.ready.* "$WORK/race.go"
for side in a b; do
  NATIVE_LOCK_WAIT=0 NATIVE_LOCK_TEST_BARRIER="$WORK/race" "${BOUNDED[@]}" /bin/bash -c '. "$SUBJECT"
    native_lock_acquire mac-app-host gate "$1" || exit 1; echo "won by $$"; sleep 2; native_lock_release_all' _ "$WORK/dd-$side" \
    >"$WORK/race-$side.out" 2>&1 &
  PIDS="$PIDS $!"
  if [ "$side" = a ]; then RACE_a=$!; else RACE_b=$!; fi
done
for _ in $(seq 1 300); do [ "$(find "$WORK" -maxdepth 1 -name 'race.ready.*' | wc -l | tr -d ' ')" = 2 ] && break; sleep 0.01; done
: >"$WORK/race.go"
wait "$RACE_a"; ra=$?; wait "$RACE_b"; rb=$?
if { [ "$ra" = 0 ] && [ "$rb" = 1 ]; } || { [ "$ra" = 1 ] && [ "$rb" = 0 ]; }; then
  ok "two stale reclaimers released together: exactly one owner, one named refusal"
else
  bad "racing reclaimers returned $ra and $rb. A: $(cat "$WORK/race-a.out") B: $(cat "$WORK/race-b.out")"
fi
: >"$HOST"

# --- The bounded wait -------------------------------------------------------------------

start_owner mac-app-host gate wait1 || bad "the wait-case owner never took the lock"
( sleep 2; : >"$STOP" ) &
start_s=$(date +%s)
out="$(NATIVE_LOCK_WAIT=20 try mac-app-host)"; rc=$?
elapsed=$(( $(date +%s) - start_s ))
named="$(printf '%s\n' "$out" | grep -c "waiting for gate pid $OWNER from ")"
if [ "$rc" = 0 ] && grep -q "acquired mac-app-host" <<<"$out" && [ "$elapsed" -ge 1 ] \
   && grep -q "mac-app-host is free after" <<<"$out"; then
  ok "a busy lock is waited for and taken when free (${elapsed}s)"
else
  bad "the wait did not end in the lock. Got: $out"
fi
[ "$named" = 1 ] && ok "the waiter names its holder once over many polls" || bad "holder named $named times. Got: $out"
await "$LOG" released || true
start_owner mac-app-host gate wait2 || bad "the bound-case owner never took the lock"
# The holder keeps the lock for this whole case, so only the bound can end the wait, and the
# "gave up after waiting 2s" refusal naming the holder proves that it did. The module counts
# whole seconds (date +%s), so a 2s bound ends between 1s and 2s after the start, plus one
# 0.1s poll: hence a 2s bound here, which makes a 1000ms floor sound (it really waited).
# The ceiling is calibrated in the same run, in milliseconds: an immediate refusal
# (NATIVE_LOCK_WAIT=0) is the same path without the wait, so machine load raises both alike.
# Ceiling: the 2s bound, one poll, twice the refusal's own cost, and 1s of slack (about 3.3s
# on a quiet machine). An unbounded or a ten-times-longer wait fails it.
t0=$(now_ms); NATIVE_LOCK_WAIT=0 try mac-app-host >/dev/null; base_rc=$?; base=$(( $(now_ms) - t0 ))
t0=$(now_ms); out="$(NATIVE_LOCK_WAIT=2 try mac-app-host)"; rc=$?; elapsed=$(( $(now_ms) - t0 ))
ceiling=$(( 2000 + 100 + 2 * base + 1000 ))
if [ "$rc" = 1 ] && grep -q "gave up after waiting 2s for mac-app-host (NATIVE_LOCK_WAIT)" <<<"$out" \
   && grep -qF "pid $OWNER" <<<"$out" && [ "$base_rc" = 1 ] \
   && [ "$elapsed" -ge 1000 ] && [ "$elapsed" -le "$ceiling" ]; then
  ok "the wait is bounded: it gives up after ${elapsed}ms (bound 2s; 1000..${ceiling}ms from a ${base}ms refusal), then refuses naming the holder"
else
  bad "the bound did not hold (${elapsed}ms; want 1000..${ceiling}ms from a ${base}ms refusal, rc $rc/$base_rc). Got: $out"
fi
NATIVE_LOCK_WAIT=30 "${BOUNDED[@]}" /bin/bash -c '. "$SUBJECT"; trap "echo trapped" TERM
  native_lock_acquire mac-app-host gate x && echo "acquired anyway"' >"$WORK/interrupt.out" 2>&1 &
waiter=$!; PIDS="$PIDS $waiter"
await "$WORK/interrupt.out" "waiting for" || true
kill -TERM "$waiter" 2>/dev/null
for _ in $(seq 1 60); do kill -0 "$waiter" 2>/dev/null || break; sleep 0.05; done
if ! kill -0 "$waiter" 2>/dev/null && grep -q "interrupted while waiting for mac-app-host" "$WORK/interrupt.out" \
   && ! grep -q "acquired anyway" "$WORK/interrupt.out"; then
  ok "TERM ends a wait, even when the caller traps it"
else
  bad "an interrupted wait carried on. Got: $(cat "$WORK/interrupt.out")"
fi
stop_owner

# --- Release intents and priority -------------------------------------------------------

rm -f "$INTENT"; : >"$HOST"
stand_in; REL_A="$STANDIN"
plant "$INTENT" "$REL_A" /tmp/release-a release
out="$(NATIVE_LOCK_WAIT=0 try mac-app-host)"; rc=$?
[ "$rc" = 1 ] && grep -qF "another release holds mac-app-host (pid $REL_A" <<<"$out" \
  && ok "an ordinary run refuses behind a live release intent on a free lock, naming the release" \
  || bad "a live intent was overtaken. Got: $out"
NATIVE_LOCK_WAIT=30 "${BOUNDED[@]}" /bin/bash -c '. "$SUBJECT"; native_lock_acquire mac-app-host gate x || exit 1
  echo "acquired behind"; native_lock_release_all' >"$WORK/behind.out" 2>&1 &
behind=$!; PIDS="$PIDS $behind"
if await "$WORK/behind.out" "waiting for release pid $REL_A from /tmp/release-a"; then
  stand_in; REL_B="$STANDIN"
  plant "$INTENT" "$REL_B" /tmp/release-b release
  await "$WORK/behind.out" "waiting for release pid $REL_B" || true
  rm -f "$INTENT"
  wait "$behind"; rc=$?
  if [ "$rc" = 0 ] && grep -q "acquired behind" "$WORK/behind.out" \
     && [ "$(grep -c "waiting for release pid $REL_A" "$WORK/behind.out")" = 1 ] \
     && [ "$(grep -c "waiting for release pid $REL_B" "$WORK/behind.out")" = 1 ]; then
    ok "an ordinary run waits behind a release intent, names each new holder once, then continues"
  else
    bad "the wait behind an intent misbehaved. Got: $(cat "$WORK/behind.out")"
  fi
else
  bad "an ordinary run did not wait behind a live intent. Got: $(cat "$WORK/behind.out")"
fi
sleep 0 & dead=$!; wait "$dead"
plant "$INTENT" "$dead" /tmp/dead-release release
out="$(NATIVE_LOCK_WAIT=0 try mac-app-host)"; rc=$?
[ "$rc" = 0 ] && grep -q "clearing a stale release intent (recorded pid $dead)" <<<"$out" && [ ! -e "$INTENT" ] \
  && ok "a dead release's intent is cleared by whoever reads it, and holds nobody back" \
  || bad "a dead intent held a run back. Got: $out"
printf '%s\n%s\n%s\n%s\n%s\n' "$$" "Mon Jan  1 00:00:00 2001" /tmp/old /tmp/app-dd release >"$INTENT"
out="$(NATIVE_LOCK_WAIT=0 try mac-app-host)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$INTENT" ] && ok "an intent naming a reused pid is stale and cleared" || bad "a reused-pid intent held a run back. Got: $out"
plant "$INTENT" "$REL_A" /tmp/release-a release
out="$(NATIVE_LOCK_WAIT=0 try mac-app-host release)"; rc=$?
[ "$rc" = 0 ] && ok "a release does not yield to another release's intent" || bad "a release yielded to a release. Got: $out"
rm -f "$INTENT"

start_owner mac-app-host gate prio || bad "the priority-case owner never took the lock"
NATIVE_LOCK_WAIT=30 "${BOUNDED[@]}" /bin/bash -c '. "$SUBJECT"; native_lock_acquire mac-app-host release x || exit 1
  echo "release acquired at $(date +%s)"; sleep 1; native_lock_release_all' >"$WORK/prio-release.out" 2>&1 &
prio_release=$!; PIDS="$PIDS $prio_release"
if await "$INTENT" "$prio_release"; then
  NATIVE_LOCK_WAIT=30 "${BOUNDED[@]}" /bin/bash -c '. "$SUBJECT"; native_lock_acquire mac-app-host gate y || exit 1
    echo "gate acquired at $(date +%s)"; native_lock_release_all' >"$WORK/prio-gate.out" 2>&1 &
  prio_gate=$!; PIDS="$PIDS $prio_gate"
  await "$WORK/prio-gate.out" "waiting for release pid $prio_release" || true
  : >"$STOP"
  wait "$prio_release"; r1=$?; wait "$prio_gate"; r2=$?
  if [ "$r1" = 0 ] && [ "$r2" = 0 ] && grep -q "waiting for release pid $prio_release" "$WORK/prio-gate.out" \
     && [ ! -e "$INTENT" ] \
     && [ "$(sed -n 's/^release acquired at //p' "$WORK/prio-release.out")" -le "$(sed -n 's/^gate acquired at //p' "$WORK/prio-gate.out")" ]; then
    ok "a waiting release gets the resource before an ordinary run that arrived after it, and withdraws its intent"
  else
    bad "release priority failed. Release: $(cat "$WORK/prio-release.out") Gate: $(cat "$WORK/prio-gate.out")"
  fi
else
  bad "a waiting release wrote no intent. Got: $(cat "$WORK/prio-release.out")"
  : >"$STOP"
fi
await "$LOG" released || true

# --- Inheritance: only a live release's direct child, told so ----------------------------

: >"$HOST"
start_owner mac-app-host release inherit EXPORT_OWNER=1 CHILD=1 || bad "the inheritance owner never took the lock"
await "$LOG" "grandchild" || true
grep -q "^child inherited$" "$LOG" && ok "a release's direct child inherits its lock" || bad "the direct child did not inherit: $(cat "$LOG")"
grep -q "^grandchild refused$" "$LOG" && ok "a grandchild does not inherit" || bad "a grandchild inherited: $(cat "$LOG")"
stop_owner
start_owner mac-app-host release inherit2 CHILD=1 || bad "the second inheritance owner never took the lock"
await "$LOG" "grandchild" || true
grep -q "^child refused$" "$LOG" && ok "without the exported owner pid, a child does not inherit" || bad "a child inherited without the owner pid: $(cat "$LOG")"
stop_owner
start_owner mac-app-host gate inherit3 EXPORT_OWNER=1 CHILD=1 || bad "the third inheritance owner never took the lock"
await "$LOG" "grandchild" || true
grep -q "^child refused$" "$LOG" && ok "an ordinary gate's child does not inherit" || bad "a gate's child inherited: $(cat "$LOG")"
stop_owner

# --- Resources are independent; the same one serializes ----------------------------------

start_owner sim-AAAA gate simA || bad "the simulator owner never took sim-AAAA"
out="$(NATIVE_LOCK_WAIT=0 try sim-BBBB)"; rc=$?
[ "$rc" = 0 ] && ok "a different simulator's lock is taken at once beside a held one" || bad "sim-BBBB refused. Got: $out"
out="$(NATIVE_LOCK_WAIT=0 try sim-AAAA)"; rc=$?
[ "$rc" = 1 ] && grep -qF "another gate holds sim-AAAA (pid $OWNER" <<<"$out" \
  && ok "the same simulator is refused to a second run, naming its holder" || bad "two runs held sim-AAAA. Got: $out"
[ "$(wc -l <"$NATIVE_LOCK_DIR/sim-AAAA.lock" | tr -d ' ')" = 5 ] \
  && ok "named locks keep the same five-line record under NATIVE_LOCK_DIR" || bad "sim-AAAA.lock is not five lines"
stop_owner
a="$(/bin/bash -c '. "$SUBJECT"; native_lock_derived_name /tmp/rk-dd-x')"
b="$(/bin/bash -c '. "$SUBJECT"; native_lock_derived_name /private/tmp/rk-dd-x')"
c="$(/bin/bash -c '. "$SUBJECT"; native_lock_derived_name /private/tmp/rk-dd-y')"
if [ "$a" = "$b" ] && [ "$a" != "$c" ] && grep -qE '^derived-data-[0-9a-f]{12}$' <<<"$a"; then
  ok "one DerivedData directory has one lock name, whichever spelling of its path is used"
else
  bad "derived names: $a / $b / $c"
fi

# --- Signals to the owner's process group leave the lock with its owner ------------------

for sig in INT HUP QUIT TERM; do
  : >"$HOST"
  if ! start_owner mac-app-host gate "sig-$sig" TRAP=1; then bad "group $sig: the owner never took the lock"; continue; fi
  kill -"$sig" -- "-$OWNER" 2>/dev/null
  sleep 0.6
  out="$(NATIVE_LOCK_WAIT=0 try mac-app-host)"; rc=$?
  if ! kill -0 "$OWNER" 2>/dev/null; then
    bad "group $sig: the trapping owner died, so the case was not tested"
  elif kernel_free "$HOST"; then
    bad "group $sig freed the kernel lock while its owner kept custody"
  elif [ "$rc" = 0 ]; then
    bad "group $sig let a contender in beside a live owner. Got: $out"
  else
    ok "a group $sig leaves the lock with an owner that traps it"
  fi
  kill -9 -- "-$OWNER" 2>/dev/null; sleep 0.6
done

: >"$HOST"
if start_owner mac-app-host gate holder TRAP=1; then
  holder="$(pgrep -P "$OWNER" -f native-lock | head -1)"
  if [ -z "$holder" ]; then
    bad "could not find the owner's holder process"
  else
    kill -TERM "$holder" 2>/dev/null; sleep 0.6
    out="$(NATIVE_LOCK_WAIT=0 try mac-app-host)"; rc=$?
    kill -0 "$holder" 2>/dev/null && [ "$rc" = 1 ] && ok "TERM to the holder alone does not free the lock" \
      || bad "TERM to the holder freed the lock. Got: $out"
    kill -9 "$holder" 2>/dev/null; sleep 0.4
    out="$(NATIVE_LOCK_WAIT=0 try mac-app-host)"; rc=$?
    [ "$rc" = 1 ] && ok "with its holder SIGKILLed, a live owner still holds the resource by its record" \
      || bad "a live owner's resource was handed out after its holder died. Got: $out"
    stop_owner
    out="$(NATIVE_LOCK_WAIT=0 try mac-app-host)"; rc=$?
    [ "$rc" = 0 ] && [ ! -s "$HOST" ] && ok "the owner's own release clears its record after its holder was killed" \
      || bad "the record outlived the owner's release. Got: $out"
  fi
  kill -9 -- "-$OWNER" 2>/dev/null; sleep 0.4
else
  bad "the holder-case owner never took the lock"
fi

# --- A subshell's lock is the subshell's ----------------------------------------------------

out="$(NATIVE_LOCK_WAIT=0 "${BOUNDED[@]}" /bin/bash -c '. "$SUBJECT"
  ( native_lock_acquire sim-SUB gate x >/dev/null 2>&1 && echo "subshell acquired" )
  sleep 0.6
  native_lock_acquire sim-SUB gate y && echo "parent acquired after subshell exit"
  native_lock_release_all' 2>&1)"
grep -q "subshell acquired" <<<"$out" && grep -q "parent acquired after subshell exit" <<<"$out" \
  && ok "a lock taken in a subshell names the subshell and is freed when it exits" || bad "a subshell's lock outlived it. Got: $out"

# --- An older whole-run holder under lockf -k holds every resource -------------------------

: >"$HOST"
/usr/bin/lockf -s -k "$HOST" /bin/bash -c '
  printf "%s\n%s\n%s\n%s\n%s\n" "$$" "$(ps -o lstart= -p $$ | sed "s/^[[:space:]]*//;s/[[:space:]]*$//")" \
    /tmp/old-checkout /tmp/app-dd gate >"$1"
  sleep 3' _ "$HOST" &
legacy=$!; PIDS="$PIDS $legacy"
for _ in $(seq 1 100); do [ -s "$HOST" ] && break; sleep 0.05; done
legacy_pid="$(sed -n '1p' "$HOST")"
out="$(NATIVE_LOCK_WAIT=0 try sim-LEGACY)"; rc=$?
[ "$rc" = 1 ] && grep -qF "another gate holds sim-LEGACY (pid $legacy_pid" <<<"$out" \
  && ok "an older whole-run holder is treated as holding a simulator too" || bad "a simulator was handed out beside an older whole-run holder. Got: $out"
out="$(NATIVE_LOCK_PROJECT=Demo NATIVE_LOCK_WAIT=20 try sim-LEGACY)"; rc=$?
[ "$rc" = 0 ] && grep -q "an older Demo script holds every resource" <<<"$out" && grep -q "acquired sim-LEGACY" <<<"$out" \
  && ok "a run waits for the older holder, says why in the project's name, and continues" || bad "the wait for an older holder misbehaved. Got: $out"
wait "$legacy" 2>/dev/null

# --- A project's own names -----------------------------------------------------------------

out="$(env -u NATIVE_LOCK_DIR -u NATIVE_LOCK_HOST_FILE DEMO_HOST="$WORK/demo/gate.lock" /bin/bash -c '
  NATIVE_LOCK_ENV=DEMO_LOCK; NATIVE_LOCK_HOST_VAR=DEMO_HOST; . "$SUBJECT"
  echo "host=$(native_lock_path mac-app-host) dir=$NATIVE_LOCK_DIR"' 2>&1)"
[ "$out" = "host=$WORK/demo/gate.lock dir=$WORK/demo/native-locks" ] \
  && ok "a project's host variable moves mac-app-host, and the other locks move beside it" || bad "host mapping: $out"
out="$(env -u NATIVE_LOCK_DIR -u NATIVE_LOCK_HOST_FILE /bin/bash -c '
  NATIVE_LOCK_HOST_DEFAULT=/tmp/rk-demo-default.lock; . "$SUBJECT"; echo "$(native_lock_path mac-app-host) $NATIVE_LOCK_DIR"' 2>&1)"
[ "$out" = "/tmp/rk-demo-default.lock /tmp/native-locks" ] \
  && ok "unset, mac-app-host is the project's default file and the rest stay in /tmp/native-locks (paths only, nothing taken)" \
  || bad "default mapping: $out"
start_owner sim-PREFIX gate prefix || bad "the prefix-case owner never took its lock"
out="$(DEMO_LOCK_WAIT=0 "${BOUNDED[@]}" /bin/bash -c 'NATIVE_LOCK_ENV=DEMO_LOCK; . "$SUBJECT"; native_lock_acquire sim-PREFIX gate x' 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q "set DEMO_LOCK_WAIT to wait longer" <<<"$out" \
  && ok "NATIVE_LOCK_ENV renames the knobs, read when the function runs" || bad "the knob prefix was ignored. Got: $out"
stop_owner

# --- A release intent belongs to its lock file (review K1) ---------------------------------
#
# Two projects with their own mac-app-host files: a release waiting for one must not hold
# back the other's free lock. Two callers of the same file must still see one intent.

A_HOST="$WORK/project-a/host.lock"; B_HOST="$WORK/project-b/host.lock"
mkdir -p "$(dirname "$A_HOST")" "$(dirname "$B_HOST")"
A_INTENT="$(NATIVE_LOCK_HOST_FILE="$A_HOST" /bin/bash -c '. "$SUBJECT"; native_lock_intent_path mac-app-host')"
B_INTENT="$(NATIVE_LOCK_HOST_FILE="$B_HOST" /bin/bash -c '. "$SUBJECT"; native_lock_intent_path mac-app-host')"
A_AGAIN="$(NATIVE_LOCK_HOST_FILE="$WORK/project-a/../project-a/host.lock" /bin/bash -c '. "$SUBJECT"; native_lock_intent_path mac-app-host')"
[ "$A_INTENT" != "$B_INTENT" ] && [ "$A_INTENT" = "$A_AGAIN" ] && [ "$(dirname "$A_INTENT")" = "$NATIVE_LOCK_DIR" ] \
  && ok "each mac-app-host file has its own release intent, whichever spelling of its path is used" \
  || bad "intent paths: A $A_INTENT, B $B_INTENT, A again $A_AGAIN"
stand_in; REL_K1="$STANDIN"
plant "$A_INTENT" "$REL_K1" /tmp/project-a-release release
out="$(NATIVE_LOCK_HOST_FILE="$B_HOST" NATIVE_LOCK_WAIT=0 try mac-app-host)"; rc=$?
[ "$rc" = 0 ] && ok "a release waiting on another project's app host does not hold back this project's free one" \
  || bad "project B was held back by project A's intent. Got: $out"
out="$(NATIVE_LOCK_HOST_FILE="$A_HOST" NATIVE_LOCK_WAIT=0 try mac-app-host)"; rc=$?
[ "$rc" = 1 ] && grep -qF "pid $REL_K1" <<<"$out" \
  && ok "the same project's ordinary run still waits behind its own release" || bad "project A overtook its own release intent. Got: $out"
rm -f "$A_INTENT"
out="$(NATIVE_LOCK_HOST_INTENT="$WORK/kept.release-intent" /bin/bash -c '. "$SUBJECT"; native_lock_intent_path mac-app-host; native_lock_intent_path sim-X')"
[ "$out" = "$WORK/kept.release-intent"$'\n'"$NATIVE_LOCK_DIR/sim-X.release-intent" ] \
  && ok "NATIVE_LOCK_HOST_INTENT keeps an older intent path for mac-app-host only" || bad "intent override: $out"

# --- Only the owner releases: USR1 alone is not a release ---------------------------

: >"$HOST"
if start_owner mac-app-host gate usr1 TRAP=1; then
  holder="$(pgrep -P "$OWNER" -f native-lock | head -1)"
  if [ -z "$holder" ]; then
    bad "could not find the holder for the USR1 case"
  else
    kill -USR1 "$holder" 2>/dev/null; sleep 0.6
    out="$(NATIVE_LOCK_WAIT=0 try mac-app-host)"; rc=$?
    if [ "$rc" = 1 ] && ! kernel_free "$HOST" && [ "$(sed -n '1p' "$HOST")" = "$OWNER" ]; then
      ok "a USR1 without the owner's release marker leaves the lock, its record and the kernel lock held"
    else
      bad "a stray USR1 released the lock. Got: $out"
    fi
  fi
  stop_owner
else
  bad "the USR1-case owner never took the lock"
fi

# --- Release signals only the holder it started -------------------------------
#
# If the holder died and its pid now names an unrelated process, release must not send that
# process USR1 (which would kill it). The owner's bookkeeping is pointed at a stand-in with
# another start time, as a reused pid would be.

: >"$HOST"
stand_in; VICTIM="$STANDIN"
out="$("${BOUNDED[@]}" /bin/bash -c '. "$SUBJECT"
  native_lock_acquire sim-REUSE gate x >/dev/null 2>&1 || { echo "not acquired"; exit 1; }
  held="$NL_HELD_sim_REUSE"; marker="${held#* }"; marker="${marker%% *}"
  NL_HELD_sim_REUSE="$1 $marker Mon Jan  1 00:00:00 2001"
  native_lock_release sim-REUSE
  echo "released"' _ "$VICTIM" 2>&1)"
sleep 0.3
if grep -q released <<<"$out" && kill -0 "$VICTIM" 2>/dev/null; then
  ok "release does not signal a process whose pid matches but whose start time does not"
else
  bad "release signalled an unrelated process (alive: $(kill -0 "$VICTIM" 2>/dev/null && echo yes || echo no)). Got: $out"
fi

echo "native-lock: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
