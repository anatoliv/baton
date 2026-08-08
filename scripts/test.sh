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
