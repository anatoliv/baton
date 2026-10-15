#!/usr/bin/env bash
# Baton — isolated local development loop. Release and test-host identities are unchanged.
# Usage: ./scripts/devrun.sh [--build-only]
# Overrides: BATON_BUILD_DIR, BATON_DEV_BUNDLE_ID, BATON_DEV_SUITE,
# BATON_DEV_SUPPORT_DIR, SIGN_ID. See docs/development-launches.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BUILD_ONLY=0
case "${1:-}" in
  "") ;;
  --build-only) BUILD_ONLY=1; shift ;;
  *) echo "usage: $0 [--build-only]" >&2; exit 2 ;;
esac
[[ $# -eq 0 ]] || { echo "usage: $0 [--build-only]" >&2; exit 2; }

# Physical checkout path is stable across branch changes and distinct across worktrees.
LANE="$(printf '%s' "$ROOT" | shasum -a 256 | cut -c1-16)"
BUILD_DIR="${BATON_BUILD_DIR:-$HOME/Library/Caches/baton-dd-wt/$LANE}"
BUNDLE_ID="${BATON_DEV_BUNDLE_ID:-io.tonebox.baton.dev.$LANE}"
SUITE="${BATON_DEV_SUITE:-io.tonebox.baton.devstate.$LANE}"
SUPPORT_DIR="${BATON_DEV_SUPPORT_DIR:-$HOME/Library/Application Support/Baton Development/$LANE}"
[[ "$BUILD_DIR" = /* && "$SUPPORT_DIR" = /* ]] || {
  echo "error: build and support directory overrides must be absolute paths" >&2; exit 2;
}
[[ "$BUNDLE_ID" =~ ^io\.tonebox\.baton\.dev\.[A-Za-z0-9.-]+$ ]] || {
  echo "error: development bundle ID must begin io.tonebox.baton.dev. (release identity is reserved)" >&2; exit 2;
}
[[ "$SUITE" =~ ^[A-Za-z0-9._-]+$ && ${#SUITE} -le 64 && "$SUITE" != "$BUNDLE_ID" && "$SUITE" != io.tonebox.baton ]] || {
  echo "error: choose a distinct defaults suite of 1–64 letters, digits, dots, underscores or dashes" >&2; exit 2;
}
# Match lsof's physical path even when a caller supplies a symlinked cache path.
mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd -P)"
APP="$BUILD_DIR/Build/Products/Debug/Baton.app"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
cd "$ROOT/app"
bold "==> Regenerating project (xcodegen)"
xcodegen generate
bold "==> Building $BUNDLE_ID (Debug, incremental)"
xcodebuild build \
    -scheme Baton \
    -configuration Debug \
    -derivedDataPath "$BUILD_DIR" \
    -destination 'platform=macOS' \
    "PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID" \
    "CODE_SIGN_IDENTITY=${SIGN_ID:-Apple Development}" \
    -quiet
[[ -d "$APP" ]] || { echo "error: no app at $APP" >&2; exit 1; }
[[ "$BUILD_ONLY" -eq 0 ]] || { bold "==> Built $APP (not launched)"; exit 0; }
bold "==> Launching isolated Baton"
# Reap only this checkout's exact executable. Never terminate installed Baton or another lane.
source "$ROOT/scripts/dev-processes.sh"
baton_stop_executable "$APP/Contents/MacOS/Baton"
open -n "$APP" --args -baton.defaultsSuite "$SUITE" -baton.supportDirectory "$SUPPORT_DIR"
