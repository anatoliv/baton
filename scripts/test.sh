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
  IOS_SIM="$(xcrun simctl list devices available -j 2>/dev/null | python3 -c "
import sys, json
try:
    devices = json.load(sys.stdin)['devices']
except Exception:
    sys.exit()
for runtime, entries in devices.items():
    if 'iOS' in runtime:
        for entry in entries:
            if 'iPhone' in entry['name']:
                print(entry['name'])
                sys.exit()
" 2>/dev/null)"

  set +e
  if [ -n "$IOS_SIM" ]; then
    bold "==> iPhone tests on $IOS_SIM (shared-package guard)"
    xcodebuild test \
      -project ios/BatonMobile.xcodeproj \
      -scheme BatonMobile \
      -destination "platform=iOS Simulator,name=$IOS_SIM" \
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
    green "  ${ios_what} pass${ios_count:+ — $ios_count}"
  else
    red "✗ ${ios_what} FAILED — the other app is broken"
    grep -E 'error:|failed \(' "$IOS_LOG" | sed 's/^/    /' | head -25 >&2 || true
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
set +e
xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  "$@" >"$LOG" 2>&1
status=$?
set -e

# One-line summary from the XCTest + Swift Testing tails.
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
swift_testing_summary="$(grep -hoE 'Test run with [0-9]+ tests? in [0-9]+ suites? (passed|failed)' "$LOG" | tail -1)"
summary="$(printf '%s %s' "$xctest_summary" "$swift_testing_summary")"

if [ "$status" -eq 0 ]; then
  green "✓ TESTS PASSED — ${summary:-see $LOG}"
else
  red "✗ TESTS FAILED (exit $status) — ${summary:-see $LOG}"
  red "  Failing cases:"
  grep -E ' error: .*XCTAssert| failed \([0-9]| recorded an issue' "$LOG" | sed 's/^/    /' | tail -25 >&2 || true
  red "  Full log: $LOG"
fi
exit "$status"
