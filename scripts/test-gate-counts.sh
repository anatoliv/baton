#!/bin/bash
#
# The gate counts every test that ran, not just the ones XCTest reports. (TBX-5236)
#
# WHY THIS EXISTS. On 2026-09-08 the same iPhone run was two different numbers:
#
#     scripts/test.sh          iPhone tests pass — Executed 154 tests
#     xcresulttool (bundle)    passed 157  failed 0  skipped 0  total 157
#
# Nothing was lost. `Executed N tests` is the XCTest reporter's rollup, and swift-testing
# (the `@Test` macro) never prints it — it prints `Test run with N tests in M suites`. The
# three the gate could not see were the `Artwork wash` suite, and the same blindness would
# have covered every `@Test` written from then on: **delete them all tomorrow and the
# gate's iPhone line would not move.** A suite that quietly loses tests looks exactly like
# a healthy one, which is this repo's own stated habit and the reason the Mac summary was
# rebuilt around the result bundle in the first place.
#
# So the fix is only worth as much as this file. The card that filed it said so: "a guard
# that cannot be shown to notice a change is the thing being fixed here, so it should not
# be replaced by another one nobody plants a failure against." Every case below therefore
# plants tests into a fixture and asserts the reported number MOVES by exactly as many —
# in both directions, for both reporters.
#
# Everything runs the REAL extractors in scripts/test.sh through the BATON_COUNT_LOG /
# BATON_COUNT_JSON hatches rather than a copy of them, the same way test-gate-diagnosis.sh
# and test-lints.sh drive their subjects: a guard that reimplements its subject can pass
# while the subject is broken.
#
# No Xcode, no simulator, no network, about a second.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '\033[32mok    %s\033[0m\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '\033[31mFAIL  %s\033[0m\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Drives the REAL log extractors over a planted log and returns one labelled field.
count_log() {   # $1 = log file, $2 = XCTEST | SWIFTTESTING | TOTAL
  BATON_COUNT_LOG="$1" "$ROOT/scripts/test.sh" 2>/dev/null \
    | sed -n "s/^$2: //p" | sed 's/[[:space:]]*$//'
}

# Drives the REAL bundle-summary parse over planted JSON, so the parse is checked without
# Xcode, a result bundle, or a machine that has ever run the suite.
count_json() {   # $1 = json file
  BATON_COUNT_JSON="$1" "$ROOT/scripts/test.sh" 2>/dev/null | sed -n 's/^BUNDLE: //p'
}

expect() {   # $1 = case, $2 = got, $3 = want
  if [ "$2" = "$3" ]; then
    ok "$1 → '$2'"
  else
    bad "$1: got '$2', wanted '$3'"
  fi
}

# --- The fixtures -----------------------------------------------------------
#
# Shaped like the real logs, because the extractors are text and the shape is the whole
# question. The XCTest half prints its rollup three times — once per nested suite, once
# per .xctest bundle, once for "All tests" — and only the bundle line may be counted, or
# a run of 154 is reported as 462.

xctest_half() {   # $1 = how many tests the bundle rolled up
  cat <<LOG
Test Suite 'All tests' started at 2026-09-08 12:30:55.500.
Test Suite 'BatonMobileTests.xctest' started at 2026-09-08 12:30:55.501.
Test Suite 'ArtworkTests' started at 2026-09-08 12:30:55.502.
Test Case '-[BatonMobileTests.ArtworkTests testWashIsStable]' passed (0.001 seconds).
Test Suite 'ArtworkTests' passed at 2026-09-08 12:30:55.510.
	 Executed $1 tests, with 0 failures (0 unexpected) in 12.000 (12.100) seconds
Test Suite 'BatonMobileTests.xctest' passed at 2026-09-08 12:30:55.511.
	 Executed $1 tests, with 0 failures (0 unexpected) in 12.000 (12.100) seconds
Test Suite 'All tests' passed at 2026-09-08 12:30:55.512.
	 Executed $1 tests, with 0 failures (0 unexpected) in 12.000 (12.100) seconds
LOG
}

swift_testing_half() {   # $1 = tests, $2 = suites
  cat <<LOG
◇ Test run started.
◇ Suite "Artwork wash" started.
✔ Suite "Artwork wash" passed after 0.005 seconds.
✔ Test run with $1 tests in $2 suites passed after 0.005 seconds.
LOG
}

# 1. The run from the card: 154 XCTest + 3 swift-testing = 157.
{ xctest_half 154; swift_testing_half 3 1; } >"$WORK/both.log"
# 2. The same run with the swift-testing suite deleted. This is the planted change.
xctest_half 154 >"$WORK/xctest-only.log"
# 3. A suite written entirely with @Test — where the old grep reported nothing at all.
swift_testing_half 3 1 >"$WORK/swift-testing-only.log"
# 4. A build that died before any test ran. Must stay distinguishable from a run of zero.
cat >"$WORK/no-tests.log" <<'LOG'
CompileSwift normal arm64 /src/ios/Sources/BatonMobile/MusicFriendView.swift
/src/ios/Sources/BatonMobile/MusicFriendView.swift:41:9: error: cannot find 'sendDaft' in scope
** TEST BUILD FAILED **
LOG
# 5. Verbatim shape of a real `swift test` run (the gateway's reporter), measured on
#    2026-09-08 against a throwaway package with 2 XCTest and 3 swift-testing tests.
cat >"$WORK/gateway.log" <<'LOG'
Test Suite 'All tests' started at 2026-09-08 12:47:15.528.
Test Suite 'ProbePackageTests.xctest' started at 2026-09-08 12:47:15.529.
Test Suite 'XCTestSide' started at 2026-09-08 12:47:15.529.
Test Suite 'XCTestSide' passed at 2026-09-08 12:47:15.530.
	 Executed 2 tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds
Test Suite 'ProbePackageTests.xctest' passed at 2026-09-08 12:47:15.530.
	 Executed 2 tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds
Test Suite 'All tests' passed at 2026-09-08 12:47:15.530.
	 Executed 2 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds
◇ Test run started.
✔ Suite "Probe wash" passed after 0.001 seconds.
✔ Test run with 3 tests in 1 suite passed after 0.001 seconds.
LOG
# 6. Two .xctest bundles and a failure, the Mac shape. Keyed by bundle name, so the
#    repeated "All tests" rollup must not be added a second time.
{
  xctest_half 1815
  cat <<'LOG'
Test Suite 'BatonPackageTests.xctest' passed at 2026-09-08 12:33:00.000.
	 Executed 42 tests, with 1 failure (0 unexpected) in 3.000 (3.100) seconds
LOG
  swift_testing_half 149 23
} >"$WORK/mac.log"

# --- 1. The count the card is about -----------------------------------------
expect "both reporters: XCTest half"        "$(count_log "$WORK/both.log" XCTEST)"       "154 1 0"
expect "both reporters: swift-testing half" "$(count_log "$WORK/both.log" SWIFTTESTING)" "3 1"
expect "both reporters: the whole run"      "$(count_log "$WORK/both.log" TOTAL)"        "157"

# The defect itself, asserted rather than described: the count the gate used to report.
old_grep="$(grep -hoE 'Executed [0-9]+ tests?' "$WORK/both.log" | tail -1)"
expect "the old scrape undercounts the same log" "$old_grep" "Executed 154 tests"

# --- 2. THE PLANTED CHANGE: the number has to move --------------------------
#
# This is the assertion the whole card comes down to. Remove the swift-testing suite from
# an otherwise identical run and the reported total must fall by exactly its three tests.
# Under the old scrape both logs reported 154 and this case could not have been written.
with="$(count_log "$WORK/both.log" TOTAL)"
without="$(count_log "$WORK/xctest-only.log" TOTAL)"
if [ "$with" = "157" ] && [ "$without" = "154" ]; then
  ok "deleting a 3-test @Test suite moves the count 157 → 154"
else
  bad "DELETING A SWIFT-TESTING SUITE DID NOT MOVE THE COUNT (with='$with' without='$without') — the exact defect this guards"
fi

# And the other direction: a suite that is *only* @Test must not read as an empty run,
# which is what the old grep made of it — no match at all.
expect "a swift-testing-only run counts"       "$(count_log "$WORK/swift-testing-only.log" TOTAL)"  "3"
expect "…and XCTest reports nothing about it"  "$(count_log "$WORK/swift-testing-only.log" XCTEST)" ""
if grep -qE 'Executed [0-9]+ tests?' "$WORK/swift-testing-only.log"; then
  bad "fixture is wrong: a swift-testing-only log should carry no 'Executed N tests' line"
else
  ok "the old scrape sees nothing at all in a swift-testing-only run"
fi

# --- 3. Zero, and the absence of a number, are different news ---------------
#
# `empty_run_is_failure` turns a count of zero into a red gate. A build that never reached
# the tests must therefore report *nothing* rather than 0, or every compile failure would
# be reported as an empty run and the diagnosis would name the wrong cause.
expect "a build that never ran tests reports no count" "$(count_log "$WORK/no-tests.log" TOTAL)" ""

# --- 4. The other two stages' log shapes ------------------------------------
expect "gateway (swift test) counts both reporters" "$(count_log "$WORK/gateway.log" TOTAL)"  "5"
expect "Mac: two bundles summed, not the repeats"   "$(count_log "$WORK/mac.log" XCTEST)"     "1857 2 1"
expect "Mac: whole run"                             "$(count_log "$WORK/mac.log" TOTAL)"      "2006"

# --- 5. The result-bundle parse ---------------------------------------------
#
# Field-for-field the shape `xcresulttool get test-results summary --compact` emits.
# `totalTestCount` counts both reporters — measured on a real bundle, not assumed:
# ~/Library/Logs/Baton/gate-failures/2026-09-08_12-34-00 has 1815 XCTest + 149
# swift-testing in its log and 1964 in its bundle.
cat >"$WORK/summary.json" <<'JSON'
{"environmentDescription":"Baton · Built with iOS 26.5","expectedFailures":0,"failedTests":0,
 "passedTests":157,"result":"Passed","skippedTests":0,"title":"Test - BatonMobile",
 "totalTestCount":157}
JSON
expect "bundle: total/passed/failed/skipped" "$(count_json "$WORK/summary.json")" "157 157 0 0"

cat >"$WORK/summary-failed.json" <<'JSON'
{"failedTests":2,"passedTests":1948,"skippedTests":14,"totalTestCount":1964,"result":"Failed"}
JSON
expect "bundle: a failing run reports its failures" "$(count_json "$WORK/summary-failed.json")" "1964 1948 2 14"

# A bundle that cannot be read must yield nothing, so the caller falls back to the log
# rather than reporting a confident zero — which `empty_run_is_failure` would turn red.
printf 'not json at all\n' >"$WORK/summary-broken.json"
expect "bundle: unreadable JSON yields no count" "$(count_json "$WORK/summary-broken.json")" ""

# --- 6. Wiring: the stages actually use all this ----------------------------
#
# The extractors can be perfect and unreferenced. These are the assertions that would have
# caught the original defect, which was never a bug in a routine — it was a stage reading
# the log instead of calling one.
if grep -q '\-resultBundlePath "$IOS_RESULT_BUNDLE"' scripts/test.sh; then
  ok "wiring: the iPhone test run writes a result bundle"
else
  bad "wiring: the iPhone test run no longer passes -resultBundlePath, so there is nothing to count from"
fi
if grep -q 'ios_counts="$(bundle_counts "$IOS_RESULT_BUNDLE")"' scripts/test.sh; then
  ok "wiring: the iPhone count comes from the bundle"
else
  bad "wiring: the iPhone count no longer reads the result bundle"
fi
if grep -q 'gateway_n="$(log_test_total "$GATEWAY_LOG")"' scripts/test.sh; then
  ok "wiring: the gateway count counts both reporters"
else
  bad "wiring: the gateway count no longer calls log_test_total"
fi
# The regression that would undo all of it: any stage going back to scraping its count out
# of the XCTest rollup. The two legitimate mentions are inside `xctest_log_counts` (the awk
# that sums the rollups) and the fallback that still knows about them.
strays="$(grep -nE 'count.*grep -[a-zA-Z]*oE? .Executed \[0-9\]\+ tests' scripts/test.sh || true)"
if [ -z "$strays" ]; then
  ok "wiring: no stage scrapes its count from the XCTest rollup"
else
  bad "wiring: a stage is counting from 'Executed N tests' again — $strays"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
