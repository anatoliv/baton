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
  # A process that lost a stale lock race must not delete its successor's lock.
  if [ "$(sed -n '1p' "$GATE_LOCK" 2>/dev/null)" = "$$" ]; then
    rm -f "$GATE_LOCK"
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
  # shellcheck disable=SC2034 # consumed by the sourcing test.sh
  GATE_LOCK_PARENT_KIND="$kind"
  return 0
}

gate_lock_acquire() {   # $1 = owner kind, $2 = derived-data path
  local owner_kind="${1:-gate}" owner_derived="${2:-unknown}"
  local attempt pid started cwd derived kind live
  for attempt in 1 2 3; do
    # noclobber makes the redirect the atomic test-and-set. Two shells cannot both
    # believe they created the same lock, even when they start in the same instant.
    if ( set -o noclobber; printf '%s\n%s\n%s\n%s\n%s\n' \
           "$$" "$(gate_lock_holder_start $$)" "$PWD" "$owner_derived" "$owner_kind" \
           >"$GATE_LOCK" ) 2>/dev/null; then
      GATE_LOCK_HELD=1
      return 0
    fi
    pid="$(sed -n '1p' "$GATE_LOCK" 2>/dev/null || true)"
    started="$(sed -n '2p' "$GATE_LOCK" 2>/dev/null || true)"
    cwd="$(sed -n '3p' "$GATE_LOCK" 2>/dev/null || true)"
    derived="$(sed -n '4p' "$GATE_LOCK" 2>/dev/null || true)"
    kind="$(sed -n '5p' "$GATE_LOCK" 2>/dev/null || true)"
    kind="${kind:-gate}"
    live=""
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      [ "$(gate_lock_holder_start "$pid")" = "$started" ] && live=1
    fi
    if [ -z "$live" ]; then
      yellow "  clearing a stale gate lock (attempt $attempt, pid ${pid:-?} is gone): $GATE_LOCK"
      rm -f "$GATE_LOCK"
      continue
    fi
    red "✗ another Baton $kind is running (pid $pid, started ${started:-unknown}, ${cwd:-unknown})"
    red "  Its derived data: ${derived:-unknown}"
    red "  Baton gates and releases app-host the same Baton.app. Starting or reaping a"
    red "  second copy makes the other run report a runner death against an unrelated test."
    red "  This run stopped before it could share derived data or kill that host. (TBX-5291)"
    red "  Wait for it, or stop it, then run again. BATON_ALLOW_CONCURRENT_GATE=1 overrides."
    return 1
  done
  red "✗ could not take the gate lock at $GATE_LOCK after three attempts"
  red "  Something is recreating it. Remove it by hand if no gate or release is running."
  return 1
}
