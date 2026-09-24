#!/bin/bash
# Build one unsigned, reporting-disabled iPhone archive for source and dSYM
# verification. This command never installs, uploads, signs, or reads credentials.
set -euo pipefail
umask 077

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS="$(cd "$DIR/.." && pwd)"
REPO="$(cd "$IOS/.." && pwd)"
PREVIOUS_BUILD=""

usage() {
  echo "usage: $0 --previous-build <installed-build>" >&2
  exit 64
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --previous-build)
      [ "$#" -ge 2 ] || usage
      PREVIOUS_BUILD="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

case "$PREVIOUS_BUILD" in (*[!0-9]*|'') usage ;; esac
[ -z "$(git -C "$REPO" status --porcelain)" ] || {
  echo "reporting-disabled candidate refused: source checkout is dirty" >&2
  exit 1
}

COMMIT="$(git -C "$REPO" rev-parse HEAD)"
case "$COMMIT" in (*[!0-9a-f]*|'') echo "reporting-disabled candidate refused: source identity is invalid" >&2; exit 1 ;; esac
[ "${#COMMIT}" -eq 40 ] || {
  echo "reporting-disabled candidate refused: source identity is not exact" >&2
  exit 1
}

BUILD="${BATON_CANDIDATE_BUILD:-$(date +%s)}"
case "$BUILD" in (*[!0-9]*|'') echo "reporting-disabled candidate refused: build is invalid" >&2; exit 1 ;; esac
[ "$BUILD" -gt "$PREVIOUS_BUILD" ] || {
  echo "reporting-disabled candidate refused: build must be newer than the installed build" >&2
  exit 1
}

command -v xcodegen >/dev/null || {
  echo "reporting-disabled candidate refused: xcodegen is unavailable" >&2
  exit 1
}

VERSION="$(awk '/^[[:space:]]*MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' "$IOS/project.yml")"
[ -n "$VERSION" ] || {
  echo "reporting-disabled candidate refused: marketing version is missing" >&2
  exit 1
}

TEMP_ROOT="$(mktemp -d -t baton-ios-disabled)"
XCCONFIG="$TEMP_ROOT/reporting.xcconfig"
ARCHIVE="$IOS/build/Baton-preproduction-disabled.xcarchive"
cleanup() { rm -rf "$TEMP_ROOT"; }
trap cleanup EXIT HUP INT TERM

"$REPO/scripts/prepare-crash-reporting.sh" "$TEMP_ROOT" "$XCCONFIG" >/dev/null
cd "$IOS"
"$DIR/sync-help.sh"
xcodegen generate
rm -rf "$ARCHIVE"
xcodebuild archive \
  -project BatonMobile.xcodeproj \
  -scheme BatonMobile \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -xcconfig "$XCCONFIG" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  BATON_SOURCE_COMMIT="$COMMIT" \
  BATON_INTERNAL_DIAGNOSTICS=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

APP="$ARCHIVE/Products/Applications/Baton.app"
DSYM="$ARCHIVE/dSYMs/Baton.app.dSYM"
"$REPO/scripts/verify-cocoa-reporting-artifact.sh" \
  --app "$APP" \
  --dsym "$DSYM" \
  --commit "$COMMIT" \
  --provider disabled

if /usr/libexec/PlistBuddy -c 'Print :BatonInternalDiagnostics' "$APP/Info.plist" 2>/dev/null \
   | grep -qi '^yes$'; then
  echo "reporting-disabled candidate refused: destructive diagnostics are enabled" >&2
  exit 1
fi

RELEASE="io.tonebox.baton@${VERSION}+${BUILD}.${COMMIT}"
echo "reporting-disabled candidate ready: release=$RELEASE"
echo "  archive $ARCHIVE"
echo "  dSYM $DSYM"
echo "  no signing, installation, upload, or credential access occurred"
