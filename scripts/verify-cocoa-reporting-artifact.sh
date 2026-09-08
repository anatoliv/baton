#!/usr/bin/env bash
# Prove that one built app, its dSYM and its reporting configuration agree.
# This script never prints the DSN or reads event payloads.
set -euo pipefail

usage() {
  echo "usage: $0 --app <Baton.app> --dsym <Baton.app.dSYM> --commit <40-hex> --provider <crashbox|disabled>" >&2
  exit 64
}

APP=""
DSYM=""
EXPECTED_COMMIT=""
EXPECTED_PROVIDER=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) [ "$#" -ge 2 ] || usage; APP="$2"; shift 2 ;;
    --dsym) [ "$#" -ge 2 ] || usage; DSYM="$2"; shift 2 ;;
    --commit) [ "$#" -ge 2 ] || usage; EXPECTED_COMMIT="$2"; shift 2 ;;
    --provider) [ "$#" -ge 2 ] || usage; EXPECTED_PROVIDER="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[ -d "$APP" ] || { echo "reporting artifact verification failed: app bundle not found" >&2; exit 1; }
[ -d "$DSYM" ] || { echo "reporting artifact verification failed: dSYM bundle not found" >&2; exit 1; }
case "$EXPECTED_PROVIDER" in crashbox|disabled) ;; *) usage ;; esac
case "$EXPECTED_COMMIT" in
  (*[!0123456789abcdef]*|'')
    echo "reporting artifact verification failed: expected commit is not lowercase hex" >&2
    exit 1 ;;
esac
[ "${#EXPECTED_COMMIT}" -eq 40 ] \
  || { echo "reporting artifact verification failed: expected commit is not 40 characters" >&2; exit 1; }

if [ -f "$APP/Contents/Info.plist" ]; then
  PLIST="$APP/Contents/Info.plist"
  EXECUTABLE_DIR="$APP/Contents/MacOS"
else
  PLIST="$APP/Info.plist"
  EXECUTABLE_DIR="$APP"
fi
[ -f "$PLIST" ] || { echo "reporting artifact verification failed: Info.plist not found" >&2; exit 1; }

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null
}

COMMIT="$(plist_value BatonSourceCommit)" \
  || { echo "reporting artifact verification failed: source identity missing" >&2; exit 1; }
PROVIDER="$(plist_value CrashReportingProvider)" \
  || { echo "reporting artifact verification failed: provider identity missing" >&2; exit 1; }
ENVIRONMENT="$(plist_value CrashReportingEnvironment)" \
  || { echo "reporting artifact verification failed: environment missing" >&2; exit 1; }
DSN="$(plist_value CrashReportingDSN)" \
  || { echo "reporting artifact verification failed: DSN missing" >&2; exit 1; }
VERSION="$(plist_value CFBundleShortVersionString)" \
  || { echo "reporting artifact verification failed: version missing" >&2; exit 1; }
BUILD="$(plist_value CFBundleVersion)" \
  || { echo "reporting artifact verification failed: build missing" >&2; exit 1; }
EXECUTABLE="$(plist_value CFBundleExecutable)" \
  || { echo "reporting artifact verification failed: executable name missing" >&2; exit 1; }

[ "$COMMIT" = "$EXPECTED_COMMIT" ] \
  || { echo "reporting artifact verification failed: embedded commit does not match the pinned commit" >&2; exit 1; }
if [ "$EXPECTED_PROVIDER" = crashbox ]; then
  [ "$PROVIDER" = crashbox ] \
    || { echo "reporting artifact verification failed: embedded provider is not Crashbox" >&2; exit 1; }
  [ "$ENVIRONMENT" = production ] \
    || { echo "reporting artifact verification failed: release environment is not production" >&2; exit 1; }
  case "$DSN" in
    (*'//'*) echo "reporting artifact verification failed: embedded DSN must be schemeless" >&2; exit 1 ;;
    (*@*/*) ;;
    (*) echo "reporting artifact verification failed: embedded DSN has an unsafe or malformed shape" >&2; exit 1 ;;
  esac
else
  [ -z "$PROVIDER$ENVIRONMENT$DSN" ] \
    || { echo "reporting artifact verification failed: reporting-disabled artifact carries configuration" >&2; exit 1; }
fi

BINARY="$EXECUTABLE_DIR/$EXECUTABLE"
[ -f "$BINARY" ] || { echo "reporting artifact verification failed: main executable not found" >&2; exit 1; }
command -v dwarfdump >/dev/null \
  || { echo "reporting artifact verification failed: dwarfdump is unavailable" >&2; exit 1; }

TMP="$(mktemp -d -t baton-reporting-artifact)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
dwarfdump --uuid "$BINARY" \
  | sed -E 's/^UUID: ([0-9A-Fa-f-]+) \(([^)]+)\).*/\2 \1/' \
  | LC_ALL=C sort > "$TMP/binary-uuids"
dwarfdump --uuid "$DSYM" \
  | sed -E 's/^UUID: ([0-9A-Fa-f-]+) \(([^)]+)\).*/\2 \1/' \
  | LC_ALL=C sort > "$TMP/dsym-uuids"
[ -s "$TMP/binary-uuids" ] \
  || { echo "reporting artifact verification failed: executable has no UUID" >&2; exit 1; }
if ! cmp -s "$TMP/binary-uuids" "$TMP/dsym-uuids"; then
  echo "reporting artifact verification failed: executable and dSYM UUIDs differ" >&2
  exit 1
fi

echo "reporting artifact verified: provider=$EXPECTED_PROVIDER release=io.tonebox.baton@$VERSION+$BUILD.$COMMIT"
sed 's/^/  UUID /' "$TMP/binary-uuids"
