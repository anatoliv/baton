#!/bin/bash
#
# One owner at a time for Baton's app-hosted Mac test host: the `mac-app-host` lock of
# scripts/native-lock.sh, under its original names. (TBX-5291, TBX-11003)
#
# Source this file, call gate_lock_acquire with an owner kind and derived-data path, and
# arrange for gate_lock_release from the caller's exit trap. Hold it only around what can
# launch or reap Baton.app: scripts/test.sh takes it for the Mac app-hosted XCTest step
# alone, and a release from before its first leftover-host reap until its last.
#
# The lock stays at ${BATON_GATE_LOCK:-/tmp/baton-gate.lock} with its five-line record (pid,
# start time, working directory, derived data, kind), which Tonebox's hosted-test controller
# reads. gate_lock_acquire returns in the calling shell with the record naming that shell;
# the trailing script and arguments older callers pass are accepted and ignored.
#
# A busy lock is waited for, up to BATON_GATE_LOCK_WAIT seconds (default 3600), naming the
# holder once and again when it changes. BATON_GATE_LOCK_WAIT=0 refuses at once with the
# original message. A waiting release registers an intent that holds ordinary runs back.
#
# A Mac release owns this lock before it reaps a leftover test host, then starts
# scripts/test.sh as a direct child. The child recognizes that live parent as the owner and
# inherits the lock instead of deadlocking against its own release.

# shellcheck source=scripts/native-lock.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/native-lock.sh"

# shellcheck disable=SC2034 # the original public name; sourcing callers may read it
GATE_LOCK="$(native_lock_path mac-app-host)"
GATE_LOCK_HELD=""
GATE_LOCK_PARENT_KIND=""

gate_lock_holder_start() {   # $1 = pid
  native_lock_start "$1"
}

gate_lock_release() {
  [ -n "$GATE_LOCK_HELD" ] || return 0
  native_lock_release mac-app-host
  GATE_LOCK_HELD=""
  unset BATON_GATE_LOCK_ACTIVE_OWNER_PID
}

gate_lock_inherit_parent() {
  native_lock_inherit mac-app-host || return 1
  # shellcheck disable=SC2034 # consumed by the sourcing test.sh
  GATE_LOCK_PARENT_KIND=release
  return 0
}

gate_lock_refusal() {
  native_lock_refusal mac-app-host
}

gate_lock_acquire() {   # $1 = owner kind, $2 = derived-data path, rest ignored
  native_lock_acquire mac-app-host "${1:-gate}" "${2:-unknown}" || exit 1
  GATE_LOCK_HELD=1
  BATON_GATE_LOCK_ACTIVE_OWNER_PID="${NL_SELF:-$$}"
  export BATON_GATE_LOCK_ACTIVE_OWNER_PID
}
