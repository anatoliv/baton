#!/bin/bash
#
# The gate's failure report names the cause the log actually states. (TBX-5139)
#
# WHY THIS EXISTS. On 2026-09-07 two gate runs died before a single test executed and
# `scripts/test.sh` reported both as:
#
#     ✗ TESTS FAILED (exit 65) — no tests ran — the build did not get that far
#       Compile errors:
#       Kept: ~/Library/Logs/Baton/gate-failures/2026-09-07_18-33-36
#
# A header with nothing under it, naming a cause that was not there: `grep -c 'error: '`
# over that 5,469-line log returns 0. The real failure was `Command CodeSign failed with
# a nonzero exit code` on an Xcode-provided test dylib — `errSecInternalComponent`, the
# keychain refusing to sign, which nothing in the tree can cause. "Compile errors" sends
# whoever reads it to re-read their own diff, which is the most expensive wrong direction
# precisely when the tree is innocent.
#
# This is that file's oldest defect one layer up. It has twice reported a status that did
# not mean what it looked like (a 790-test run as "Executed 4 tests"; five crashes as "0
# failures"), and the report is only worth trusting if a wrong one cannot be produced
# silently. So this guard asserts two different things:
#
#   1. the named cause matches the planted evidence, per failure shape; and
#   2. THE INVARIANT — no fixture, including a log this gate understands nothing about,
#      can produce a header with an empty body. That is the shape of the original defect,
#      and it is checked on every case rather than on the ones we thought of.
#
# The two codesign fixtures are verbatim excerpts of the real kept logs. Everything runs
# the REAL routines in scripts/test.sh through the BATON_DIAGNOSE_LOG hatch rather than a
# copy of them, the same way test-lints.sh drives the real lints: a guard that
# reimplements its subject can pass while the subject is broken.
#
# No Xcode, no simulator, no network, about a second.
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '\033[32mok    %s\033[0m\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '\033[31mFAIL  %s\033[0m\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OUT=""
# Drives the REAL diagnosis in scripts/test.sh over a planted log. Colour codes are
# stripped so the assertions below match on text rather than on escape sequences.
diagnose() {   # $1 = log file
  OUT="$(BATON_DIAGNOSE_LOG="$1" ./scripts/test.sh 2>&1 | sed $'s/\033\\[[0-9;]*m//g')"
}

# Every report must carry at least one indented evidence line under its header. This is
# the assertion the original defect fails: it printed "  Compile errors:" and stopped.
expect_evidence() {   # $1 = case name
  if printf '%s\n' "$OUT" | grep -qE '^ {4}[^ ]'; then
    ok "$1: the report carries evidence"
  else
    bad "$1: HEADER WITH NOTHING UNDER IT — the exact defect this guards"
    printf '%s\n' "$OUT" | sed 's/^/      | /'
  fi
}

expect_says() {   # $1 = case name, $2 = description, $3 = pattern
  if printf '%s\n' "$OUT" | grep -qE "$3"; then
    ok "$1: $2"
  else
    bad "$1: $2 (no line matched /$3/)"
    printf '%s\n' "$OUT" | sed 's/^/      | /'
  fi
}

expect_silent_about() {   # $1 = case name, $2 = description, $3 = pattern that must NOT appear
  if printf '%s\n' "$OUT" | grep -qE "$3"; then
    bad "$1: $2 (matched /$3/, which this failure is not)"
    printf '%s\n' "$OUT" | sed 's/^/      | /'
  else
    ok "$1: $2"
  fi
}

# --- 1. The failure that produced the card ----------------------------------
#
# Verbatim from ~/Library/Logs/Baton/gate-failures/2026-09-07_18-33-36/xcodebuild.log,
# paths shortened. One CodeSign failure, zero `error:` lines in the whole file.
cat >"$WORK/codesign.log" <<'LOG'
CodeSign /dd/Build/Products/Debug/Baton.app/Contents/Frameworks/libXCTestBundleInject.dylib (in target 'Baton' from project 'Baton')
    cd /src/app

    Signing Identity:     "Apple Development: Anatoli Vishnyakov (DKG9SL6S7Z)"

    /usr/bin/codesign --force --sign 6D8F8502 -o runtime --timestamp\=none /dd/Build/Products/Debug/Baton.app/Contents/Frameworks/libXCTestBundleInject.dylib
/dd/Build/Products/Debug/Baton.app/Contents/Frameworks/libXCTestBundleInject.dylib: replacing existing signature
/dd/Build/Products/Debug/Baton.app/Contents/Frameworks/libXCTestBundleInject.dylib: errSecInternalComponent
Command CodeSign failed with a nonzero exit code

Testing failed:
	Command CodeSign failed with a nonzero exit code
	Testing cancelled because the build failed.

** TEST FAILED **


The following build commands failed:
	CodeSign /dd/Build/Products/Debug/Baton.app/Contents/Frameworks/libXCTestBundleInject.dylib (in target 'Baton' from project 'Baton')
	Testing project Baton with scheme Baton
(2 failures)
LOG
diagnose "$WORK/codesign.log"
expect_evidence     "codesign"
expect_says         "codesign" "names code signing"          'HEADLINE: the build failed at code signing'
expect_says         "codesign" "quotes the failed command"   '^ +CodeSign /dd/.*libXCTestBundleInject\.dylib'
# Quoting the log's own line, not just recognising the string. An earlier draft asserted
# only "errSecInternalComponent appears somewhere", which the standing advice paragraph
# satisfies on its own — so deleting errSec from the evidence grep left the guard green
# while the report stopped showing which dylib failed. Assert the quoted line.
expect_says         "codesign" "quotes the keychain error"    '^ +.*libXCTestBundleInject\.dylib: errSecInternalComponent'
expect_says         "codesign" "labels it as signing"         '^ +Signing diagnostics:'
expect_says         "codesign" "sends the reader off the diff" 'Nothing in the|Re-run before re-reading your diff'
expect_silent_about "codesign" "does not blame the compiler" 'Compile errors'

# --- 2. The second instance, where a collateral Ld failure printed no diagnostic ---
#
# From .../2026-09-07_18-34-56/. Four failures, still zero `error:` lines — so a fix that
# only greps harder for `error: ` prints nothing here either. The Ld failure has no
# diagnostic line of its own, which is why the failed-command list has to carry the report.
cat >"$WORK/codesign-ld.log" <<'LOG'
/dd/Build/Products/Debug/Baton.app/Contents/Frameworks/libXCTestSwiftSupport.dylib: errSecInternalComponent
Command CodeSign failed with a nonzero exit code
/dd/Build/Products/Debug/Baton.app/Contents/Frameworks/libXCTestBundleInject.dylib: errSecInternalComponent
Command CodeSign failed with a nonzero exit code

Ld /dd/Build/Products/Debug/Baton.app/Contents/MacOS/__preview.dylib normal (in target 'Baton' from project 'Baton')
    cd /src/app
    /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang -dynamiclib -o /dd/Build/Products/Debug/Baton.app/Contents/MacOS/__preview.dylib
Command Ld failed with a nonzero exit code

Testing failed:
	Command CodeSign failed with a nonzero exit code
	Command Ld failed with a nonzero exit code
	Testing cancelled because the build failed.

** TEST FAILED **

The following build commands failed:
	CodeSign /dd/Build/Products/Debug/Baton.app/Contents/Frameworks/libXCTestSwiftSupport.dylib (in target 'Baton' from project 'Baton')
	CodeSign /dd/Build/Products/Debug/Baton.app/Contents/Frameworks/libXCTestBundleInject.dylib (in target 'Baton' from project 'Baton')
	Ld /dd/Build/Products/Debug/Baton.app/Contents/MacOS/__preview.dylib normal (in target 'Baton' from project 'Baton')
	Testing project Baton with scheme Baton
(4 failures)
LOG
diagnose "$WORK/codesign-ld.log"
expect_evidence     "codesign+ld"
expect_says         "codesign+ld" "names both failures"      'HEADLINE: the build failed at code signing and linking'
expect_says         "codesign+ld" "lists the Ld command"     '^ +Ld /dd/.*__preview\.dylib'
expect_silent_about "codesign+ld" "does not blame the compiler" 'Compile errors'

# A log cut off before the summary block — a killed run, a full disk. The inline markers
# are the only record that anything failed, and the report has to be built from them.
cat >"$WORK/codesign-truncated.log" <<'LOG'
/dd/Build/Products/Debug/Baton.app/Contents/Frameworks/libXCTestBundleInject.dylib: errSecInternalComponent
Command CodeSign failed with a nonzero exit code
LOG
diagnose "$WORK/codesign-truncated.log"
expect_evidence "codesign-truncated"
expect_says     "codesign-truncated" "still names code signing" 'HEADLINE: the build failed at code signing'
expect_says     "codesign-truncated" "names the command it has" '^ +CodeSign$'

# --- 3. A real compile error still reads as one -----------------------------
#
# The case the old code assumed was the only one. It has to keep working, or this change
# has traded one wrong answer for another.
cat >"$WORK/compile.log" <<'LOG'
SwiftCompile normal arm64 /src/app/Sources/Baton/PlayerView.swift (in target 'Baton' from project 'Baton')
/src/app/Sources/Baton/PlayerView.swift:42:9: error: cannot find 'nowPlayingg' in scope
Command SwiftCompile failed with a nonzero exit code

** TEST FAILED **

The following build commands failed:
	SwiftCompile normal arm64 /src/app/Sources/Baton/PlayerView.swift (in target 'Baton' from project 'Baton')
	Testing project Baton with scheme Baton
(2 failures)
LOG
diagnose "$WORK/compile.log"
expect_evidence "compile"
expect_says     "compile" "names compilation"        'HEADLINE: the build failed at compilation'
expect_says     "compile" "prints the diagnostic"    "cannot find 'nowPlayingg' in scope"

# A compile error with no summary block at all — a log truncated mid-build. The inline
# marker is the only evidence, and the report must still name the cause.
cat >"$WORK/compile-truncated.log" <<'LOG'
/src/app/Sources/Baton/PlayerView.swift:42:9: error: cannot find 'nowPlayingg' in scope
LOG
diagnose "$WORK/compile-truncated.log"
expect_evidence "compile-truncated"
expect_says     "compile-truncated" "names compile errors" 'HEADLINE: compile errors'

# --- 4. The three destinations are told apart -------------------------------
#
# Compilation, code signing and "the test runner never started" send a reader to the diff,
# the machine and the test host. Reading identically is what cost the afternoon.
cat >"$WORK/runner.log" <<'LOG'
Test Suite 'All tests' started at 2026-09-07 18:33:36.000
** BUILD SUCCEEDED **
Testing failed:
	Test runner never began executing tests after launching.
	Lost connection to the test runner.
** TEST FAILED **
LOG
diagnose "$WORK/runner.log"
expect_evidence     "runner"
expect_says         "runner" "names the runner"           'HEADLINE: the test runner never started'
expect_says         "runner" "points away from the diff"  'Look at the test host'
expect_silent_about "runner" "does not blame the compiler" 'Compile errors'

# One marker on its own. The fixture above carries two, so either alone kept it green and
# a deleted marker was invisible — each has to be load-bearing, because a real log usually
# prints only one of them.
printf '** BUILD SUCCEEDED **\nTesting failed:\n\tTest runner never began executing tests after launching.\n' >"$WORK/runner-solo.log"
diagnose "$WORK/runner-solo.log"
expect_evidence "runner-solo"
expect_says     "runner-solo" "names the runner from one marker" 'HEADLINE: the test runner never started'

# --- 5. The /tmp reaping failure this repo documents ------------------------
#
# Documented in CLAUDE.md and recurring: macOS reaps $TMPDIR by age, SPM sees resolved
# checkouts with no manifests. It arrives as `xcodebuild: error:`, so a naive `grep
# 'error: '` would have captioned it "Compile errors" too.
cat >"$WORK/packages.log" <<'LOG'
xcodebuild: error: Could not resolve package dependencies:
  Package.swift doesn't exist in /tmp/baton-dd/SourcePackages/checkouts/swift-log
LOG
diagnose "$WORK/packages.log"
expect_evidence     "packages"
expect_says         "packages" "names package resolution" 'HEADLINE: package resolution failed'
expect_says         "packages" "names the documented fix" 'mv /'
expect_silent_about "packages" "does not blame the compiler" 'Compile errors'

# --- 6. Ordinary test failures, for the branch with no result bundle --------
cat >"$WORK/tests.log" <<'LOG'
Test Case '-[BatonTests.ScrobbleTests testThreshold]' started.
/src/app/Tests/ScrobbleTests.swift:88: error: -[BatonTests.ScrobbleTests testThreshold] : XCTAssertEqual failed: ("1") is not equal to ("0")
Test Case '-[BatonTests.ScrobbleTests testThreshold]' failed (0.412 seconds).
** TEST FAILED **
LOG
diagnose "$WORK/tests.log"
expect_evidence "tests"
expect_says     "tests" "names test failures"  'HEADLINE: tests failed'
expect_says     "tests" "quotes the assertion" 'XCTAssertEqual failed'

# --- 7. The cases nobody thought of -----------------------------------------
#
# The point of the invariant. A log this gate understands nothing about must degrade into
# an honest "no cause named, here is the tail" rather than into a confident wrong header.
{ echo "note: Using codesigning identity override"
  echo "warning: Skipping duplicate build file"
  echo "Something entirely unforeseen happened here"
  echo "and then the process was killed"
} >"$WORK/unknown.log"
diagnose "$WORK/unknown.log"
expect_evidence     "unknown"
expect_says         "unknown" "admits it cannot name a cause" 'HEADLINE: a cause the log does not name'
expect_says         "unknown" "hands over the tail"           'and then the process was killed'
expect_silent_about "unknown" "does not blame the compiler"   'Compile errors'
# A non-empty log must never be described as empty. This is what makes the last-resort
# branch mutation-visible: without it, deleting the tail backstop leaves the second one
# to fire and the report claims there was no evidence when four lines were sitting there.
expect_silent_about "unknown" "does not claim the log is empty" 'log is empty'

: >"$WORK/empty.log"
diagnose "$WORK/empty.log"
expect_evidence "empty"
expect_says     "empty" "says the log is empty" 'log is empty \(0 bytes\)'

diagnose "$WORK/no-such-file.log"
expect_says "missing" "says there is no log"    'No log to read'

# --- 8. The seam is actually wired into the report --------------------------
#
# A routine nobody calls reads as coverage while the gate keeps printing the old header —
# the same trap `test-signing-patch` was written for. Assert the failure path calls it and
# that the hard-coded header is gone.
if grep -q 'diagnose_build_failure "\$LOG"' scripts/test.sh; then
  ok "wiring: the Mac failure report calls the diagnosis"
else
  bad "wiring: scripts/test.sh no longer calls diagnose_build_failure on the Mac failure path"
fi
if grep -qE 'red "  Compile errors:"' scripts/test.sh; then
  bad "wiring: the hard-coded \"Compile errors:\" header is back in scripts/test.sh"
else
  ok "wiring: no hard-coded \"Compile errors:\" header remains"
fi
for hooked in IOS_LOG WATCH_LOG; do
  if grep -q "diagnose_build_failure \"\$$hooked\"" scripts/test.sh; then
    ok "wiring: the \$$hooked failure report calls the diagnosis"
  else
    bad "wiring: \$$hooked still reports build failures with a bare grep"
  fi
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
