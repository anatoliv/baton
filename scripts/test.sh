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
summary="$(grep -hoE 'Executed [0-9]+ tests?, with [0-9]+ failures?|Test run with [0-9]+ tests? in [0-9]+ suites? (passed|failed)' "$LOG" | tail -2 | tr '\n' ' ')"

if [ "$status" -eq 0 ]; then
  green "✓ TESTS PASSED — ${summary:-see $LOG}"
else
  red "✗ TESTS FAILED (exit $status) — ${summary:-see $LOG}"
  red "  Failing cases:"
  grep -E ' error: .*XCTAssert| failed \([0-9]| recorded an issue' "$LOG" | sed 's/^/    /' | tail -25 >&2 || true
  red "  Full log: $LOG"
fi
exit "$status"
