#!/bin/bash
#
# One owner for Baton's app-hosted Mac test process and its shared derived data.
# Source this file, call gate_lock_acquire with an owner kind and derived-data path,
# and arrange for gate_lock_release from the caller's exit trap.
#
# A Mac release owns this lock before it reaps a leftover test host, then starts
# scripts/test.sh as a direct child. The child recognizes that live parent as the
# owner and inherits the lock instead of deadlocking against its own release.

GATE_LOCK="${BATON_GATE_LOCK:-/tmp/baton-gate.lock}"
GATE_LOCK_HELD=""
GATE_LOCK_PARENT_KIND=""

# `ps -o lstart=` comes from the kernel. Pairing it with the pid distinguishes a
# live owner from a later process that happens to reuse the same pid.
gate_lock_holder_start() {   # $1 = pid
  ps -o lstart= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

gate_lock_release() {
  [ -n "$GATE_LOCK_HELD" ] || return 0
  # Keep the inode forever. `lockf -k` relies on every contender opening the same
  # file; unlinking it would let a new inode and a second independent lock appear.
  if [ "$(sed -n '1p' "$GATE_LOCK" 2>/dev/null)" = "$$" ]; then
    : >"$GATE_LOCK"
  fi
  GATE_LOCK_HELD=""
}

# A release invokes test.sh directly while retaining ownership. Only that direct,
# still-live parent may be inherited; an environment flag alone would be spoofable
# and a pid alone would be vulnerable to reuse.
gate_lock_inherit_parent() {
  local pid started kind
  pid="$(sed -n '1p' "$GATE_LOCK" 2>/dev/null || true)"
  [ -n "$pid" ] && [ "$pid" = "$PPID" ] || return 1
  started="$(sed -n '2p' "$GATE_LOCK" 2>/dev/null || true)"
  # Some constrained shells deny ps even for their own process. In that case both
  # reads are empty, and the direct-parent requirement still makes inheritance safe.
  [ "$(gate_lock_holder_start "$pid")" = "$started" ] || return 1
  kind="$(sed -n '5p' "$GATE_LOCK" 2>/dev/null || true)"
  [ "$kind" = "release" ] || return 1
  [ "${BATON_GATE_LOCK_ACTIVE_OWNER_PID:-}" = "$pid" ] || return 1
  # shellcheck disable=SC2034 # consumed by the sourcing test.sh
  GATE_LOCK_PARENT_KIND="$kind"
  return 0
}

gate_lock_refusal() {
  local pid="" started="" cwd derived kind _
  # The winner writes its record immediately after taking the kernel lock. Give it a
  # bounded instant to replace stale metadata so the refusal names the actual owner.
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    pid="$(sed -n '1p' "$GATE_LOCK" 2>/dev/null || true)"
    started="$(sed -n '2p' "$GATE_LOCK" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
       && [ "$(gate_lock_holder_start "$pid")" = "$started" ]; then
      break
    fi
    sleep 0.01
  done
  cwd="$(sed -n '3p' "$GATE_LOCK" 2>/dev/null || true)"
  derived="$(sed -n '4p' "$GATE_LOCK" 2>/dev/null || true)"
  kind="$(sed -n '5p' "$GATE_LOCK" 2>/dev/null || true)"
  kind="${kind:-gate or release}"
  red "✗ another Baton $kind is running (pid ${pid:-unknown}, started ${started:-unknown}, ${cwd:-unknown})"
  red "  Its derived data: ${derived:-unknown}"
  red "  Baton gates and releases app-host the same Baton.app. Starting or reaping a"
  red "  second copy makes the other run report a runner death against an unrelated test."
  red "  This run stopped before it could share derived data or kill that host. (TBX-5291)"
  red "  Wait for it, or stop it, then run again. BATON_ALLOW_CONCURRENT_GATE=1 overrides."
}

gate_lock_acquire() {   # $1 = owner kind, $2 = derived-data path, $3 = script, rest = args
  local owner_kind="${1:-gate}" owner_derived="${2:-unknown}"
  local entrypoint="${3:-}" previous_pid previous_started marker state rc
  shift 3

  # lockf has acquired the kernel lock and invoked this fresh copy of the script.
  # Its parent retains the locked descriptor, so no child command inherits it and a
  # SIGKILL of this script makes lockf release ownership immediately.
  if [ "${BATON_GATE_LOCK_ACTIVE:-}" = 1 ] \
     && [ -z "${BATON_GATE_LOCK_ACTIVE_OWNER_PID:-}" ] \
     && [ -n "${BATON_GATE_LOCK_MARKER:-}" ] \
     && [ "$(sed -n '1p' "$BATON_GATE_LOCK_MARKER" 2>/dev/null)" = waiting ]; then
    previous_pid="$(sed -n '1p' "$GATE_LOCK" 2>/dev/null || true)"
    previous_started="$(sed -n '2p' "$GATE_LOCK" 2>/dev/null || true)"
    # A gate from a checkout with the older pidfile implementation may still be
    # running. It cannot hold this kernel lock, so honor its live metadata during
    # the transition instead of racing it the first time the new guard runs.
    if [ -n "$previous_pid" ] && kill -0 "$previous_pid" 2>/dev/null \
       && [ "$(gate_lock_holder_start "$previous_pid")" = "$previous_started" ]; then
      printf 'active\n' >"$BATON_GATE_LOCK_MARKER"
      gate_lock_refusal
      return 1
    fi
    if [ -n "$previous_pid" ] && [ "$previous_pid" != "$$" ]; then
      yellow "  clearing a stale gate lock (recorded pid $previous_pid): $GATE_LOCK"
    fi
    : >"$GATE_LOCK"
    printf '%s\n%s\n%s\n%s\n%s\n' \
      "$$" "$(gate_lock_holder_start $$)" "$PWD" "$owner_derived" "$owner_kind" >"$GATE_LOCK"
    printf 'active\n' >"$BATON_GATE_LOCK_MARKER"
    BATON_GATE_LOCK_ACTIVE_OWNER_PID="$$"
    export BATON_GATE_LOCK_ACTIVE_OWNER_PID
    GATE_LOCK_HELD=1
    return 0
  fi

  [ -n "$entrypoint" ] || { red "✗ gate lock has no script to run"; return 1; }
  marker="$(mktemp -t baton-gate-lock.XXXXXX)"
  printf 'waiting\n' >"$marker"

  # Test-only barrier for the deterministic two-contender proof. Both wrappers stop
  # here, then the harness releases them into lockf together against the same inode.
  if [ -n "${BATON_GATE_LOCK_TEST_BARRIER:-}" ]; then
    : >"${BATON_GATE_LOCK_TEST_BARRIER}.ready.$$"
    while [ ! -e "${BATON_GATE_LOCK_TEST_BARRIER}.go" ]; do sleep 0.01; done
  fi

  if BATON_GATE_LOCK_ACTIVE=1 BATON_GATE_LOCK_ACTIVE_OWNER_PID='' \
       BATON_GATE_LOCK_MARKER="$marker" \
       /usr/bin/lockf -s -t 0 -k "$GATE_LOCK" "$entrypoint" "$@"; then
    rc=0
  else
    rc=$?
  fi
  state="$(sed -n '1p' "$marker" 2>/dev/null || true)"
  rm -f "$marker"
  if [ "$state" != active ]; then
    gate_lock_refusal
    exit 1
  fi
  exit "$rc"
}
