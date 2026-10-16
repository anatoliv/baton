#!/bin/bash
#
# Baton's named native-resource locks: the release kit's lib/native-lock.sh with Baton's
# names. (TBX-11003, TBX-11024)
#
# The lock protocol itself lives in the release kit (scripts/release-kit/lib/native-lock.sh,
# canonical source ~/Projects/_release, rule ~/Projects/_method/docs/standards/release.md).
# This file only configures it, so every Baton caller, and Tonebox's hosted-test controller
# through scripts/gate-lock.sh, keeps the names it already knows:
#
#   mac-app-host    stays at ${BATON_GATE_LOCK:-/tmp/baton-gate.lock}, with the five-line
#                   record (pid, start time, working directory, derived data, kind) that
#                   Tonebox's controller reads; other locks under $NATIVE_LOCK_DIR
#                   (default /tmp/native-locks, or beside BATON_GATE_LOCK when that is set)
#   BATON_GATE_LOCK_WAIT, BATON_GATE_LOCK_PRIORITY, BATON_GATE_LOCK_ACTIVE_OWNER_PID and
#   BATON_GATE_LOCK_TEST_BARRIER are the kit's wait, priority, inheritance and test knobs
#   the refusal for mac-app-host keeps its original wording word for word (below), and its
#   release intent stays at $NATIVE_LOCK_DIR/mac-app-host.release-intent
#   scripts/test-gate-lock.sh asserts these defaults read only, without taking a lock
#
# Source this file from bash, then use native_lock_acquire, native_lock_release,
# native_lock_release_all, native_lock_inherit and native_lock_derived_name as documented in
# the kit module. docs/release-design.md records how Baton adopts the standard.

NATIVE_LOCK_ENV=BATON_GATE_LOCK
NATIVE_LOCK_HOST_VAR=BATON_GATE_LOCK
NATIVE_LOCK_HOST_DEFAULT=/tmp/baton-gate.lock
NATIVE_LOCK_PROJECT=Baton

# The gate's original refusal; tests and Tonebox's controller read these words.
native_lock_host_refusal() {   # kind, pid, start time, cwd, derived data
  local kind="${1:-gate or release}"
  _nl_red "✗ another Baton $kind is running (pid ${2:-unknown}, started ${3:-unknown}, ${4:-unknown})"
  _nl_red "  Its derived data: ${5:-unknown}"
  _nl_red "  Baton gates and releases app-host the same Baton.app. Starting or reaping a"
  _nl_red "  second copy makes the other run report a runner death against an unrelated test."
  _nl_red "  This run stopped before it could share derived data or kill that host. (TBX-5291)"
  _nl_red "  Wait for it, or stop it, then run again. BATON_ALLOW_CONCURRENT_GATE=1 overrides."
}

# shellcheck source=scripts/release-kit/lib/native-lock.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release-kit/lib/native-lock.sh"

# A waiting release's intent for mac-app-host stays where Baton's scripts before TBX-11024
# write it, so old and new checkouts still honor each other's release priority. Only Baton
# uses this path; the kit names other projects' host intents by their own file's digest.
NATIVE_LOCK_HOST_INTENT="$NATIVE_LOCK_DIR/mac-app-host.release-intent"
