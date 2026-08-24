#!/usr/bin/env bash
#
# The local test gate for Baton.
#
# GitHub Actions is intentionally off (validate locally), so this script is the
# single executable merge/release gate: it regenerates the Xcode project from
# project.yml and runs the full test suite, exiting nonzero on any failure.
# `scripts/publish.sh` runs this before packaging a release.
#
# Usage:
#   ./scripts/test.sh              # regenerate + test (incremental derived data)
#   CLEAN=1 ./scripts/test.sh      # wipe derived data first (release-grade)
#   ./scripts/test.sh -only-testing:BatonTests/ScrobbleTests   # pass-through args
#   ALLOW_NO_TESTS=1 ./scripts/test.sh …   # a run that matches nothing may still pass
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_DIR="app"
PROJECT="$APP_DIR/Baton.xcodeproj"
SCHEME="Baton"
DERIVED="${BATON_DERIVED_DATA:-/tmp/baton-dd}"
LOG="$(mktemp -t baton-test.XXXXXX).log"

bold(){ printf '\033[1m%s\033[0m\n' "$*"; }
red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }

# --- "Did this run prove anything?" — one definition, used by both suites -----
#
# Green here means "this tree is safe to merge or publish". A run that executed **no
# tests** has not established that, however cleanly it exited — and exiting cleanly is
# precisely what it does. A typo'd `-only-testing` (this script forwards "$@" straight to
# xcodebuild), a scheme that lost its test targets, or a filter that stopped matching
# after a rename each produce a successful build that asserts nothing, and the gate used
# to print `✓ TESTS PASSED — no tests ran` in green for all three. The summary text was
# honest; the verdict was not.
#
# It is the same lesson this gate has already learned twice, at its limit: the log once
# reported a 790-test run as "Executed 4 tests", and a run with five crashes as "0
# failures". Both were fixed by checking the *count* rather than the tick. Zero is a count.
#
# One function rather than a check at each site, because there are two suites here and
# "when something exists in more than one place, put it in one" is the rule this codebase
# keeps paying to relearn. (TBX-2924)
#
# `ALLOW_NO_TESTS=1` is the escape hatch, and it is deliberately **not** an automatic
# exemption for `-only-testing` runs: a mistyped filter is the likeliest way to arrive
# here, so exempting filtered runs would exempt exactly the case worth catching. Someone
# who genuinely means to run nothing can say so, and it shows up in their shell history.
empty_run_is_failure() { [ -z "${ALLOW_NO_TESTS:-}" ]; }

bold "==> Generating Xcode project (xcodegen)"
( cd "$APP_DIR" && xcodegen generate >/dev/null )

if [ -n "${CLEAN:-}" ]; then
  bold "==> Wiping derived data ($DERIVED)"
  rm -rf "$DERIVED"
fi

# --- Source lints (fast, fail before the build) ----------------------------
bold "==> Lints"
lint_fail=0
SRC="$APP_DIR/Sources/Baton"
# W-18: a single log subsystem (io.tonebox.baton) so `log show` captures everything and
# doesn't collide with the Tonebox app. Any other Logger(subsystem:) is a regression.
if grep -rn 'Logger(subsystem:' "$SRC" --include='*.swift' | grep -v 'io.tonebox.baton' | grep -q .; then
  red "  lint: non-baton Logger subsystem found:"
  grep -rn 'Logger(subsystem:' "$SRC" --include='*.swift' | grep -v 'io.tonebox.baton' | sed 's/^/    /' >&2
  lint_fail=1
fi
# W-16: never log a full URL (Subsonic auth rides in the query string).
if grep -rnE '(^|[^A-Za-z])[Ll]og[A-Za-z]*\.(error|info|notice|debug|warning|fault|log)\(.*absoluteString' "$SRC" --include='*.swift' | grep -q .; then
  red "  lint: a full URL (.absoluteString) is being logged:"
  grep -rnE '(^|[^A-Za-z])[Ll]og[A-Za-z]*\.(error|info|notice|debug|warning|fault|log)\(.*absoluteString' "$SRC" --include='*.swift' | sed 's/^/    /' >&2
  lint_fail=1
fi
[ "$lint_fail" -eq 0 ] && green "  lints clean" || { red "✗ LINT FAILED"; exit 1; }

# --- iPhone build (cross-platform breakage guard) ---------------------------
#
# This repo ships two apps over shared packages, and until now the gate only ever
# built one of them. Merging the AVAudioEngine work proved what that costs: the
# engine's per-app output routing is CoreAudio HAL, which does not exist on iOS,
# so the iPhone app stopped compiling — while this script reported 1228 tests
# passing and 0 failures over the very same tree. A green gate meant one app was
# healthy, and said nothing at all about the other.
#
# A build, not a test run: the phone's own suite runs on its own hardware and is
# not what leaked. What leaked was compilation of shared code against a second
# SDK, and that is exactly what this catches. Cheap insurance — it runs before
# the long Mac suite so cross-platform breakage fails in minutes, not after.
#
# SKIP_IOS=1 for a fast Mac-only loop while iterating; never for a merge.
if [ -z "${SKIP_IOS:-}" ]; then
  IOS_LOG="$(mktemp -t baton-ios-build.XXXXXX).log"
  ( cd ios && xcodegen generate >/dev/null )

  # Prefer running the phone's unit tests on a simulator: that compiles the shared
  # packages against the iOS SDK *and* exercises the phone-only logic (the audio-session
  # rules for the engine, which have no macOS equivalent and which the Mac suite therefore
  # cannot cover). Falls back to a device build where no simulator is installed — still
  # enough to catch the cross-platform compile breakage this step exists for.
  #
  # The UI tests are deliberately NOT here: they drive a real app against Navidrome's
  # public demo server, so they need the network and take minutes. Run them by hand:
  #   xcodebuild test -project ios/BatonMobile.xcodeproj -scheme BatonMobile \
  #     -destination 'platform=iOS Simulator,name=<device>' \
  #     -only-testing:BatonMobileUITests/EngineDeckPlaybackUITests
  # Selected by UDID, not by name. A name is resolved by xcodebuild at launch time and
  # gives us nothing to wait on; a UDID is a device we can boot and then block until it is
  # actually ready. See the boot gate below for why that matters.
  IOS_SIM_INFO="$(xcrun simctl list devices available -j 2>/dev/null | python3 -c "
import sys, json
try:
    devices = json.load(sys.stdin)['devices']
except Exception:
    sys.exit()
for runtime, entries in devices.items():
    if 'iOS' in runtime:
        for entry in entries:
            if 'iPhone' in entry['name']:
                print(entry['udid'] + '\t' + entry['name'])
                sys.exit()
" 2>/dev/null)"
  IOS_SIM_UDID="${IOS_SIM_INFO%%$'\t'*}"
  IOS_SIM="${IOS_SIM_INFO#*$'\t'}"

  set +e
  if [ -n "$IOS_SIM_UDID" ]; then
    # --- Wait for a settled simulator, rather than racing one ------------------
    #
    # Observed 2026-08-12: this stage failed with
    #
    #   FBSOpenApplicationServiceErrorDomain Code=1 "Simulator device failed to launch
    #   io.tonebox.baton" … Busy ("Application failed preflight checks")
    #
    # No compile errors — the app built and SpringBoard refused to start it. In isolation
    # minutes later on the same tree: 110 tests, 0 failures. The trigger is running gates
    # back to back, so the previous run's simulator is still settling when the next one
    # launches. The cost is the whole gate (~15 min), and it lands *before* the Mac suite,
    # so nothing else gets run either.
    #
    # The fix is to WAIT, not to retry. Re-attempting a failed launch is how a gate stops
    # meaning anything — the same principle as the flaky-test rule in CLAUDE.md. So:
    # `bootstatus -b` boots the device if needed and blocks until it reports ready, which
    # is the state xcodebuild would otherwise have assumed. Its own help says it is safe to
    # call before booting has started.
    #
    # Not fatal on its own: if the wait fails, the launch may still work, and turning a
    # healthy run red over a boot probe would be its own version of this bug. The
    # classification below is what makes a genuine launch failure legible.
    bold "==> Waiting for simulator $IOS_SIM to settle ($IOS_SIM_UDID)"
    if xcrun simctl bootstatus "$IOS_SIM_UDID" -b >/dev/null 2>&1; then
      green "  simulator ready"
    else
      red "  simulator did not report ready — continuing, the launch may still succeed"
    fi

    bold "==> iPhone tests on $IOS_SIM (shared-package guard)"
    xcodebuild test \
      -project ios/BatonMobile.xcodeproj \
      -scheme BatonMobile \
      -destination "id=$IOS_SIM_UDID" \
      -only-testing:BatonMobileTests \
      -derivedDataPath "${DERIVED}-ios" >"$IOS_LOG" 2>&1
    ios_status=$?
    ios_what="iPhone tests"
  else
    bold "==> Building iPhone app (no simulator installed)"
    xcodebuild build \
      -project ios/BatonMobile.xcodeproj \
      -scheme BatonMobile \
      -destination 'generic/platform=iOS' \
      -derivedDataPath "${DERIVED}-ios" \
      CODE_SIGNING_ALLOWED=NO >"$IOS_LOG" 2>&1
    ios_status=$?
    ios_what="iPhone build"
  fi
  set -e

  if [ "$ios_status" -eq 0 ]; then
    # The LAST rollup, not the first. `head -1` takes whichever suite happened to print
    # first — it reported "Executed 16 tests" for a run of 101, which is the same trap the
    # Mac summary above was built to avoid.
    ios_count="$(grep -hoE 'Executed [0-9]+ tests?' "$IOS_LOG" | tail -1)"
    # Zero tests is not a pass — but only when this was a *test* run. The build-only
    # branch above (no simulator installed) legitimately executes none, and it is the one
    # case here where an empty run is expected rather than suspicious.
    ios_n="$(printf '%s' "$ios_count" | grep -oE '[0-9]+' | tail -1 || true)"
    if [ "$ios_what" = "iPhone tests" ] && [ "${ios_n:-0}" -eq 0 ] && empty_run_is_failure; then
      red "✗ ${ios_what} executed NO tests — exit 0, and nothing was proved"
      red "  The build succeeded and the filter matched nothing: check -only-testing:BatonMobileTests"
      red "  still names a target that exists. ALLOW_NO_TESTS=1 to accept an empty run."
      red "  Full log: $IOS_LOG"
      exit 1
    fi
    green "  ${ios_what} pass${ios_count:+ — $ios_count}"
  else
    # A launch failure and a test failure are not the same news, and until now they read
    # identically: "the other app is broken", which is a claim about the code. When
    # SpringBoard refuses to start the app there is no finding at all — nothing ran.
    # Saying so is the difference between "investigate the diff" and "the machine was
    # busy", at the moment that distinction is most expensive to work out by hand.
    #
    # Note this does NOT retry, and it still fails the gate. Whether an environmental
    # launch failure should ever be retried is a live question (it changes what a red gate
    # means), and prevention above is the half that does not need it answered.
    if grep -qE 'FBSOpenApplicationServiceErrorDomain|failed preflight checks|Simulator device failed to launch|Unable to boot device' "$IOS_LOG"; then
      red "✗ ${ios_what} could not LAUNCH — this is environmental, not a code finding"
      red "  The simulator refused to start the app, so no test result exists either way."
      grep -E 'FBSOpenApplicationServiceErrorDomain|failed preflight checks|Simulator device failed to launch|Unable to boot device' "$IOS_LOG" \
        | sed 's/^/    /' | head -5 >&2 || true
      red "  Simulator: $IOS_SIM ($IOS_SIM_UDID). Current state:"
      xcrun simctl list devices | grep -F "$IOS_SIM_UDID" | sed 's/^/    /' >&2 || true
      red "  The gate still fails. Re-run once the device has settled — do not paper over a"
      red "  repeat: a launch that keeps failing on a settled simulator is a real finding."
    else
      red "✗ ${ios_what} FAILED — the other app is broken"
      grep -E 'error:|failed \(' "$IOS_LOG" | sed 's/^/    /' | head -25 >&2 || true
    fi
    red "  Full log: $IOS_LOG"
    exit "$ios_status"
  fi
  # --- Watch build -----------------------------------------------------------
  #
  # The third app, and the one nobody remembers. It is PARKED, not shipping — see
  # docs/watch-app-parked.md — and this build is precisely what makes parking it safe.
  #
  # It links the same packages and had been failing to compile since the offline-envelope
  # fallback landed: a call to a `#if !os(watchOS)` type that was not itself guarded, which
  # went unnoticed for exactly as long as nothing built it. The engine merge then broke it a
  # second, independent way.
  #
  # It is also what keeps `EngineDeckUnavailable.swift` honest: the watch stand-in for
  # `EngineDeckBridge` must keep pace with the real one, and this build is the only thing
  # that enforces that.
  WATCH_SIM="$(xcrun simctl list devices available -j 2>/dev/null | python3 -c "
import sys, json
try:
    devices = json.load(sys.stdin)['devices']
except Exception:
    sys.exit()
for runtime, entries in devices.items():
    if 'watchOS' in runtime and entries:
        print(entries[0]['udid'])
        sys.exit()
" 2>/dev/null)"

  if [ -n "$WATCH_SIM" ]; then
    bold "==> Building Watch app"
    # Generate the Watch project the same way the Mac and iPhone ones are generated
    # above. The .xcodeproj is gitignored, so on a fresh clone it does not exist and
    # this step failed with "watch/BatonWatch.xcodeproj does not exist" — invisible on
    # a machine where an earlier run had left one behind.
    ( cd watch && xcodegen generate >/dev/null )
    WATCH_LOG="$(mktemp -t baton-watch-build.XXXXXX).log"
    set +e
    xcodebuild build \
      -project watch/BatonWatch.xcodeproj \
      -scheme BatonWatch \
      -destination "id=$WATCH_SIM" \
      -derivedDataPath "${DERIVED}-watch" \
      CODE_SIGNING_ALLOWED=NO >"$WATCH_LOG" 2>&1
    watch_status=$?
    set -e
    if [ "$watch_status" -eq 0 ]; then
      green "  Watch builds"
    else
      red "✗ WATCH BUILD FAILED — shared-package change broke the third app"
      grep -E 'error:' "$WATCH_LOG" | sed 's/^/    /' | head -20 >&2 || true
      red "  Full log: $WATCH_LOG"
      exit "$watch_status"
    fi
  else
    bold "==> Skipping Watch build (no watchOS simulator installed)"
  fi
else
  bold "==> Skipping iPhone and Watch checks (SKIP_IOS set)"
fi

bold "==> Running tests ($SCHEME)"
# Sibling of the log, so the two are findable together and a fresh mktemp name each run
# means xcodebuild never refuses an existing bundle path.
RESULT_BUNDLE="${LOG%.log}.xcresult"
set +e
xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  -resultBundlePath "$RESULT_BUNDLE" \
  "$@" >"$LOG" 2>&1
status=$?
set -e

# --- The summary, from the result bundle -----------------------------------
#
# The authority is `xcresulttool get test-results summary`, not the log. CLAUDE.md already
# says to read the bundle rather than the log when checking a run by hand; the gate has no
# business holding itself to a lower standard, and the log has now been wrong in both
# directions. On 2026-08-12 it announced "Executed 777 tests across 4 bundles, with 0
# failures" with an empty "Failing cases:" list for a run the bundle recorded as 1400
# passed / 1 failed / 5 skipped — the conversation eval took the runner down with it, so
# the per-bundle rollup lines the scrape below depends on were simply never printed.
# Anyone reading that log would have concluded the run was healthy and merely truncated.
#
# The bundle also decides the verdict, not just the wording: a run whose bundle records
# failures is a failed run even if xcodebuild exited 0.
bundle_summary=""
bundle_failures=""
bundle_failed_count=""
bundle_total=""
if [ -d "$RESULT_BUNDLE" ]; then
  bundle_json="$(xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" --compact 2>/dev/null || true)"
  if [ -n "$bundle_json" ]; then
    bundle_summary="$(printf '%s' "$bundle_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
print("%d tests: %d passed, %d failed, %d skipped (%s)" % (
    d.get("totalTestCount", 0), d.get("passedTests", 0),
    d.get("failedTests", 0), d.get("skippedTests", 0), d.get("result", "?")))
' 2>/dev/null || true)"
    bundle_failed_count="$(printf '%s' "$bundle_json" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("failedTests", 0))
except Exception:
    sys.exit(1)
' 2>/dev/null || true)"
    bundle_total="$(printf '%s' "$bundle_json" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("totalTestCount", 0))
except Exception:
    sys.exit(1)
' 2>/dev/null || true)"
    bundle_failures="$(printf '%s' "$bundle_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
failures = d.get("testFailures") or []
if isinstance(failures, dict):        # the schema types this singular; runs emit a list
    failures = [failures]
for f in failures[:25]:
    text = (f.get("failureText") or "").strip().splitlines()
    print("%s/%s%s" % (f.get("targetName", "?"), f.get("testName", "?"),
                       " — " + text[0] if text else ""))
' 2>/dev/null || true)"
  fi
fi

# Fallback for when the bundle is missing or unreadable (an older xcresulttool, a run
# killed before it was written). Kept because a degraded summary beats none.
#
# `tail -2` took the last two matching lines regardless of what they were, and xcodebuild
# prints a per-suite "Executed N tests" line for every suite. When the final suite happened
# to be a small one, the summary reported *its* count as the whole run: a green 790-test
# suite was announced as "Executed 4 tests". Then "take the largest count" broke the other
# way once the scheme gained the package test bundles: it reported the biggest bundle and
# silently dropped the other two hundred tests. The truth is per *bundle*: each ".xctest"
# prints one rollup — sum those, keyed by bundle name so a repeated print can't double it.
xctest_summary="$(awk '
    /Test Suite .*\.xctest. (passed|failed) at/ { name = $3; want = 1; next }
    want && /Executed [0-9]+ tests?,/ {
        if (!(name in seen)) {
            seen[name] = 1
            for (i = 1; i <= NF; i++) {
                if ($i == "Executed") tests += $(i + 1)
                if ($(i + 1) ~ /^failures?[,.]?$/) failures += $i
            }
        }
        want = 0
    }
    END { if (length(seen)) printf "Executed %d tests across %d bundles, with %d failures", tests, length(seen), failures }
' "$LOG")"
# `|| true` is load-bearing. Under `set -euo pipefail` a grep that matches nothing fails
# the pipeline, and the assignment takes that status — so on a run with no test lines at
# all (a compile error is the common one) the script died right here, exit 1, having
# printed not one word about why. That is worse than a wrong summary: a build failure
# produced no diagnostics whatsoever, and the caller saw a bare nonzero exit.
swift_testing_summary="$(grep -hoE 'Test run with [0-9]+ tests? in [0-9]+ suites? (passed|failed)' "$LOG" | tail -1 || true)"
scraped_summary="$(printf '%s %s' "$xctest_summary" "$swift_testing_summary")"

# A bundle recording zero tests needs saying in words: "0 tests: 0 passed, 0 failed" is
# true and useless, because it reads like an empty suite rather than like a run that never
# happened. There are two ways to get here and they are different news, so `status` — which
# is xcodebuild's own exit code, before any override below — decides which one to say. The
# old text claimed the build "did not get that far" in both cases, which was a guess that
# happened to be right only for the compile failure.
if [ -n "$bundle_summary" ] && [ "${bundle_total:-0}" != "0" ]; then
  summary="$bundle_summary"
elif [ -n "$bundle_summary" ] && [ "$status" -ne 0 ]; then
  summary="no tests ran — the build did not get that far"
elif [ -n "$bundle_summary" ]; then
  summary="no tests ran — the build succeeded and nothing matched"
else
  summary="${scraped_summary} (scraped from the log — no result bundle)"
fi

# A bundle recording failures overrides a zero exit. This is the direction that actually
# ships a broken build: nobody re-reads a log that says everything passed.
if [ "$status" -eq 0 ] && [ -n "$bundle_failed_count" ] && [ "$bundle_failed_count" -gt 0 ]; then
  red "  xcodebuild exited 0 but the result bundle records $bundle_failed_count failure(s) — trusting the bundle"
  status=1
fi

# And a bundle recording *no tests at all* overrides a zero exit too — see
# `empty_run_is_failure`. Kept separate from the failure-count check above because the two
# say different things: that one is "the tests ran and some failed", this one is "the tests
# never ran". `empty_run` is remembered so the diagnosis below does not mistake it for a
# compile failure, which is the other way to reach a bundle with zero tests.
empty_run=""
if [ "$status" -eq 0 ] && [ -n "$bundle_summary" ] && [ "${bundle_total:-0}" = "0" ] && empty_run_is_failure; then
  red "  xcodebuild exited 0 but the result bundle records no tests at all — trusting the bundle"
  empty_run=1
  status=1
fi

if [ "$status" -eq 0 ]; then
  green "✓ TESTS PASSED — ${summary:-see $LOG}"
else
  red "✗ TESTS FAILED (exit $status) — ${summary:-see $LOG}"
  if [ -n "$bundle_failures" ]; then
    red "  Failing cases:"
    printf '%s\n' "$bundle_failures" | sed 's/^/    /' >&2
  elif [ -n "$empty_run" ]; then
    # The build succeeded and nothing matched, so there are neither failing cases nor
    # compiler diagnostics to print. This branch must stand *before* the compile-error one
    # below: both are "the bundle holds zero tests", and printing an empty "Compile errors:"
    # for a build that compiled fine is the same species of misleading output as the green
    # tick this whole change is about.
    red "  Nothing ran, so nothing was proved. The build succeeded — this is a filter that"
    red "  matched no tests, or a scheme with no test targets."
    if [ "$#" -gt 0 ]; then
      red "  Arguments forwarded to xcodebuild: $*"
    else
      red "  No extra arguments were passed, so check the scheme's test targets."
    fi
    red "  ALLOW_NO_TESTS=1 to accept an empty run."
  elif [ -n "$bundle_summary" ] && [ "${bundle_total:-0}" = "0" ]; then
    # No tests ran, so there are no failing cases to list — the useful output is the
    # compiler's. Printing an empty "Failing cases:" here is how a build failure came to
    # look like a mystery.
    red "  Compile errors:"
    grep -E 'error: ' "$LOG" | sed 's/^/    /' | head -20 >&2 || true
  else
    red "  Failing cases:"
    grep -E ' error: .*XCTAssert| failed \([0-9]| recorded an issue' "$LOG" | sed 's/^/    /' | tail -25 >&2 || true
  fi
  # --- Keep the evidence -----------------------------------------------------
  #
  # `$LOG` and `$RESULT_BUNDLE` live in `$TMPDIR`, which macOS reaps by age. That is not a
  # theoretical loss: when the test runner died mid-suite on 2026-08-12 both were already
  # gone by the time anyone looked, and what one surviving log would have answered instead
  # cost four repro attempts, a diagnostic harness, and a day. A failing run is exactly when
  # the evidence has to outlive the temp directory.
  #
  # Failures only, on purpose: a green run's log is noise, and copying every result bundle
  # would quietly put gigabytes somewhere nobody empties.
  keep_dir="$HOME/Library/Logs/Baton/gate-failures/$(date +%Y-%m-%d_%H-%M-%S)"
  if mkdir -p "$keep_dir" 2>/dev/null; then
    cp "$LOG" "$keep_dir/xcodebuild.log" 2>/dev/null || true
    [ -d "$RESULT_BUNDLE" ] && cp -R "$RESULT_BUNDLE" "$keep_dir/results.xcresult" 2>/dev/null || true
    # Bounded, so this can never become the thing that fills the disk. Ten is enough to
    # cover a bad afternoon and small enough to stay ignorable.
    ls -dt "$HOME/Library/Logs/Baton/gate-failures"/* 2>/dev/null | tail -n +11 | while read -r old; do
      rm -rf "$old"
    done
    red "  Kept: $keep_dir"
    red "  (the copies below are in \$TMPDIR and will be reaped — read the kept ones)"
  fi
  red "  Full log: $LOG"
  red "  Result bundle: $RESULT_BUNDLE"
fi
exit "$status"
