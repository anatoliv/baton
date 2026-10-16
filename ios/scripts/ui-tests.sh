#!/usr/bin/env bash
set -euo pipefail

# Run BatonMobileUITests, and say honestly what happened.
#
# WHY THIS EXISTS (TBX-5165). `scripts/test.sh` filters the phone run to
# `-only-testing:BatonMobileTests`, so the UI tests were compiled by every gate and executed
# by none. The exclusion had a good reason — they drive a real app against Navidrome's public
# demo server and take tens of minutes — but "somebody will run them by hand" turned out to be
# worth exactly what it sounds like: `LiveFriendComposerCaptureTests`, the only thing in the
# repo that photographs the Music Friend composer against a real model, sat broken for an
# unknown period and was found by accident (TBX-5148). The one test of the least-testable
# screen in the product was the one test nothing watched.
#
# So they run here, and this runs on the **release** path rather than the merge path. That is
# the same split the App Store metadata check already makes for the same reason: `check`
# without `--strict` in the gate, `--strict` on release. A merge must not depend on
# demo.navidrome.org; a release can, and a release is where a skip actually costs something.
#
# THE THING THIS MUST NOT BECOME is a stage that skips everything and reads as coverage. This
# board has been bitten twice by exactly that. A readable summary prints all three counts;
# unavailable counts and a run where nothing executed are **failures**, not passes.
#
#   ./ios/scripts/ui-tests.sh                     # pick a simulator, run everything not quarantined
#   ./ios/scripts/ui-tests.sh -only <Suite>       # one suite
#   UITEST_SIM=<udid> ./ios/scripts/ui-tests.sh   # a specific simulator

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
IOS="$REPO/ios"
DD="${UITEST_DD:-/tmp/baton-dd-uitests}"
RESULTS="${UITEST_RESULTS:-$(mktemp -d -t baton-uitests)}/ui.xcresult"

# --- Quarantine ------------------------------------------------------------------------
#
# Tests known to be broken *today*, each with the card that owns it. This list is how the
# stage can be blocking from its first day without blocking every release on rot that
# predates it — and it is deliberately a list of names with card numbers rather than a
# `continue-after-failure` flag, because a quarantine you have to write a card for is one
# somebody eventually empties. Anything not on it is expected to pass or to skip and say why.
#
# Empty, and the five entries it held were emptied rather than deleted: TBX-5173 and
# TBX-5174 were both test rot, driven out by driving the app. The app was right on every
# screen. See `PlayerControls.swift` for what had actually changed.
QUARANTINE=()

ONLY=""
if [ "${1:-}" = "-only" ]; then ONLY="${2:-}"; fi

# --- A simulator to run on -------------------------------------------------------------
SIM="${UITEST_SIM:-}"
if [ -z "$SIM" ]; then
  SIM="$(xcrun simctl list devices available -j 2>/dev/null | python3 -c "
import sys, json
try: devices = json.load(sys.stdin)['devices']
except Exception: sys.exit()
for runtime, entries in devices.items():
    if 'iOS' not in runtime: continue
    for entry in entries:
        if 'iPhone' in entry['name']:
            print(entry['udid']); sys.exit()
")"
fi
[ -n "$SIM" ] || { echo "no iPhone simulator available" >&2; exit 1; }

# One run per simulator, and one writer for this DerivedData, each through its named lock
# (scripts/native-lock.sh): a concurrent gate's iPhone step or another UI run on the same
# device waits its turn instead of sharing it. Different devices and DerivedData run side by
# side, so a Mac release can run while this one tests. (TBX-11003)
# shellcheck source=scripts/native-lock.sh
. "$REPO/scripts/native-lock.sh"
trap native_lock_release_all EXIT
native_lock_acquire "sim-$SIM" ui-tests "$DD" || exit 1
native_lock_acquire "$(native_lock_derived_name "$DD")" ui-tests "$DD" || exit 1

xcrun simctl boot "$SIM" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1 || true

# --- Build, then run -------------------------------------------------------------------
( cd "$IOS" && xcodegen generate >/dev/null )

ARGS=(-project "$IOS/BatonMobile.xcodeproj" -scheme BatonMobile
      -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath "$DD")

echo "==> Building the phone UI tests"
BUILD_LOG="${UITEST_BUILD_LOG:-/tmp/baton-uitests-build.log}"
xcodebuild build-for-testing "${ARGS[@]}" >"$BUILD_LOG" 2>&1 || {
  echo "build-for-testing failed — last 30 lines:" >&2
  tail -30 "$BUILD_LOG" >&2
  exit 1
}

# `-only-testing:` takes one identifier per flag, so a comma-separated list has to be split
# rather than passed through. Passing "A,B" whole is accepted silently and matches nothing,
# which would run zero tests and — but for the all-skipped check below — report a pass.
RUN=(-only-testing:BatonMobileUITests)
if [ -n "$ONLY" ]; then
  RUN=()
  IFS=',' read -ra WANTED <<<"$ONLY"
  for want in "${WANTED[@]}"; do
    want="${want#"${want%%[![:space:]]*}"}"   # trim both ends: a stray space in the list
    want="${want%"${want##*[![:space:]]}"}"   # would match no test and run nothing
    [ -n "$want" ] && RUN+=(-only-testing:"$want")
  done
fi
# Guarded, because an empty array is now the normal case and `"${A[@]}"` on one is an
# unbound-variable error under `set -u` in the bash macOS still ships at /bin/bash.
if [ ${#QUARANTINE[@]} -gt 0 ]; then
  for skipped in "${QUARANTINE[@]}"; do RUN+=(-skip-testing:"$skipped"); done
fi

echo "==> Running the phone UI tests on $SIM"
LOG="$(mktemp -t baton-uitests)"
set +e
# Suppress only verbose failure diagnostics (for example sysdiagnose), which can stall
# finalization. Tests, screenshots/attachments and the result bundle are still collected.
xcodebuild test-without-building "${ARGS[@]}" "${RUN[@]}" -collect-test-diagnostics never -resultBundlePath "$RESULTS" >"$LOG" 2>&1
RC=$?
set -e

# --- Read the result bundle, not the log -----------------------------------------------
#
# The house rule, and it is load-bearing here: this log has reported a 790-test run as
# "Executed 4 tests" and a run with five crashes as "0 failures". `xcresulttool` is the
# authority.
SUMMARY_ERROR="$(mktemp -t baton-uitests-summary)"
if SUMMARY="$(xcrun xcresulttool get test-results summary --path "$RESULTS" 2>"$SUMMARY_ERROR")" &&
   COUNTS="$(python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    counts = [data[name] for name in ("passedTests", "failedTests", "skippedTests")]
    if any(type(value) is not int or value < 0 for value in counts):
        raise ValueError("test counts must be non-negative integers")
    print(*counts)
except (ValueError, TypeError, KeyError) as error:
    print("test summary unavailable: " + str(error), file=sys.stderr)
    sys.exit(1)
' <<<"$SUMMARY" 2>>"$SUMMARY_ERROR")"; then
  read -r PASSED FAILED SKIPPED <<<"$COUNTS"
else
  echo >&2
  echo "  phone UI tests: counts unavailable — result bundle could not be read" >&2
  echo "  result bundle: $RESULTS" >&2
  echo "  xcodebuild exit: $RC; run log: $LOG" >&2
  echo "  summary diagnostics: $SUMMARY_ERROR" >&2
  [ "$RC" -eq 0 ] || exit "$RC"
  exit 1
fi

echo
echo "  phone UI tests: ${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped"
echo "  result bundle: $RESULTS"
[ ${#QUARANTINE[@]} -eq 0 ] || printf '  quarantined (not run): %s\n' "${QUARANTINE[@]}"

if [ "$FAILED" -gt 0 ]; then
  echo "--- failures ---" >&2
  grep -E "^\S+\.swift:[0-9]+: error:" "$LOG" | head -20 >&2
  exit 1
fi

# A run where everything skipped is not a pass. Skips are the honest answer to an unreachable
# demo server or a sleeping model host — that judgement is borrowed from the conversation
# eval, which skips rather than failing because an unmeasurable environment is not a broken
# feature. But "unmeasurable" stops being an acceptable answer when it is the whole run: at
# that point the stage is reporting the shape of coverage with none of the substance, which is
# worse than saying nothing.
if [ "$PASSED" -eq 0 ]; then
  echo "every UI test skipped — nothing was actually measured. Check the network and the demo server." >&2
  exit 1
fi

exit $RC
