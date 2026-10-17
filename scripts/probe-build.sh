#!/bin/bash
# Build a probe copy of the Mac app for scripts/probe-*.sh.
#
#   scripts/probe-build.sh <out-dir> [<git-ref>]
#
# Debug configuration, so lldb can attach. When the primary checkout has
# `app/Config/Crashbox.local.xcconfig`, crash reporting is compiled in exactly as a release
# compiles it, except that the environment is `development`, so the SDK really starts (which
# is what TBX-7352 needs) while nothing it could send is counted as production. Without that
# file the probe is built with reporting disabled and the script says so.
#
# With <git-ref>, the ref is checked out into a throwaway worktree under <out-dir> and built
# from there (for example `v0.19.6` to reproduce a shipped bug). The worktree is removed
# after the build. Prints the path of the built Baton.app on the last line.
#
# PROBE_BUNDLE_ID=io.tonebox.baton.dev.<name> builds the probe under that bundle id instead of
# the release one (TBX-1000000034). A probe of a Mac Service needs it: AppKit names the
# Services port after the bundle id (io.tonebox.baton.ServiceProvider), the owner's running
# Baton already holds that port, so a probe built as io.tonebox.baton never receives a Service
# call. Like scripts/devrun.sh, only io.tonebox.baton.dev.* is accepted. Unset, the build is
# unchanged. Unregister such a probe afterwards (lsregister -u), or a Services click with no
# probe running launches it with no suite, pointed at the owner's data
# (docs/evidence/tbx-1000000015/run.sh does this). Tested by scripts/test-probe-build.py.
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: $0 <out-dir> [<git-ref>]" >&2; exit 64; }
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
OUT="$1"; REF="${2:-}"
BUNDLE_ARGS=()
if [ -n "${PROBE_BUNDLE_ID:-}" ]; then
  [[ "$PROBE_BUNDLE_ID" =~ ^io\.tonebox\.baton\.dev\.[A-Za-z0-9.-]+$ ]] || {
    echo "probe-build: PROBE_BUNDLE_ID must begin io.tonebox.baton.dev. (release identity is reserved)" >&2; exit 64;
  }
  BUNDLE_ARGS=("PRODUCT_BUNDLE_IDENTIFIER=$PROBE_BUNDLE_ID")
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"

SRC="$REPO"
WT=""
if [ -n "$REF" ]; then
  WT="$OUT/src-$(printf '%s' "$REF" | tr -c 'A-Za-z0-9._-' '_')"
  [ -d "$WT" ] && git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
  git -C "$REPO" worktree add --detach "$WT" "$REF" >/dev/null
  SRC="$WT"
fi

XC="$OUT/crash-reporting.xcconfig"
MODE="$("$REPO/scripts/prepare-crash-reporting.sh" "$REPO/app" "$XC")"
if [ "$MODE" = crashbox ]; then
  sed -i '' 's/^CRASH_REPORTING_ENVIRONMENT = .*/CRASH_REPORTING_ENVIRONMENT = development/' "$XC"
  echo "probe-build: crash reporting compiled in (Crashbox, environment=development)" >&2
else
  echo "probe-build: WARNING no Crashbox configuration; crash reporting is disabled in this probe" >&2
fi

COMMIT="$(git -C "$SRC" rev-parse HEAD)"
DD="$OUT/dd-$(printf '%s' "${REF:-worktree}" | tr -c 'A-Za-z0-9._-' '_')"
LOG="$OUT/build-$(basename "$DD").log"
( cd "$SRC/app" && xcodegen generate >/dev/null &&
  xcodebuild -project Baton.xcodeproj -scheme Baton -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$DD" -xcconfig "$XC" \
    BATON_SOURCE_COMMIT="$COMMIT" ${BUNDLE_ARGS[@]+"${BUNDLE_ARGS[@]}"} build ) > "$LOG" 2>&1 || {
  echo "probe-build: build failed, see $LOG" >&2
  grep -E "error:" "$LOG" | head -10 >&2
  exit 1
}
rm -f "$XC"
[ -n "$WT" ] && git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true

APP="$DD/Build/Products/Debug/Baton.app"
[ -d "$APP" ] || { echo "probe-build: no Baton.app produced" >&2; exit 1; }
echo "probe-build: built ${REF:-working tree} @ ${COMMIT:0:12}${PROBE_BUNDLE_ID:+ as $PROBE_BUNDLE_ID}" >&2
echo "$APP"
