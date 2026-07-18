#!/usr/bin/env bash
#
# Baton macOS — release + publish.
#
# Everything that needs NO credentials runs now: build (Release), package a DMG,
# compute sha256 + byte length, and emit an appcast item into dist/appcast.xml.
# The credentialed stages (Developer ID sign, notarize/staple, Sparkle EdDSA
# signature, scp to the appcast host) run ONLY when the required env/tools are
# present — otherwise the script stops after the local artifacts with a clear note
# on exactly what's needed. This makes `./scripts/publish.sh` safe to run locally.
#
# Credentialed stages (opt in by setting these):
#   SIGN_ID="Developer ID Application: <name> (Q8822GNL2H)"   # enables codesign
#   NOTARY_PROFILE=<notarytool keychain profile>              # enables notarize+staple
#   SPARKLE_BIN=/path/to/Sparkle/bin                          # enables sign_update (EdDSA)
#   APPCAST_HOST=... APPCAST_TOKEN=... WEB01=user@host PUBLISH=1  # enables scp publish
#
# Reference (fully working): ~/Projects/tonebox/apps/tonebox-mac/scripts/publish.sh
set -euo pipefail
cd "$(dirname "$0")/.."

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '  \033[2m·\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m! %s\033[0m\n' "$*"; }

APP_DIR="app"
SCHEME="Baton"
VERSION="$(perl -ne 'print $1 if /MARKETING_VERSION:\s*"([^"]+)"/' "$APP_DIR/project.yml" | head -1)"
[ -n "$VERSION" ] || { echo "could not read MARKETING_VERSION from $APP_DIR/project.yml"; exit 1; }
DIST="dist"
DD="/tmp/baton-release"
DMG_NAME="Baton-${VERSION}.dmg"
mkdir -p "$DIST"

bold "Baton $VERSION — release pipeline"

# 1. Build (Release) --------------------------------------------------------
step "1/6 Build (Release)"
( cd "$APP_DIR" && xcodegen generate >/dev/null && \
  xcodebuild build -scheme "$SCHEME" -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$DD" -quiet )
APP="$DD/Build/Products/Release/Baton.app"
[ -d "$APP" ] || { echo "build produced no Baton.app"; exit 1; }

# 2. Sign (opt-in) ----------------------------------------------------------
if [ -n "${SIGN_ID:-}" ]; then
  step "2/6 Codesign (Developer ID, hardened runtime)"
  codesign --force --deep --options runtime --timestamp \
    --sign "$SIGN_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  warn "2/6 Sign — SKIPPED (set SIGN_ID to Developer ID to enable)"
fi

# 3. Notarize + staple (opt-in) --------------------------------------------
# 4. DMG (always) -----------------------------------------------------------
step "4/6 Package DMG"
STAGE="$(mktemp -d)"; cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DIST/$DMG_NAME"
hdiutil create -volname "Baton" -srcfolder "$STAGE" -ov -format UDZO \
  "$DIST/$DMG_NAME" >/dev/null
rm -rf "$STAGE"

if [ -n "${SIGN_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  step "3/6 Notarize + staple"
  # Sign the DMG container itself with Developer ID (mirrors Tonebox's flow), then
  # submit to Apple's notary service and staple the ticket onto both DMG and .app.
  codesign --force --sign "$SIGN_ID" "$DIST/$DMG_NAME"
  xcrun notarytool submit "$DIST/$DMG_NAME" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m
  xcrun stapler staple "$DIST/$DMG_NAME"
  xcrun stapler validate "$DIST/$DMG_NAME"
else
  warn "3/6 Notarize — SKIPPED (set SIGN_ID + NOTARY_PROFILE to enable)"
fi

SHA="$(shasum -a 256 "$DIST/$DMG_NAME" | awk '{print $1}')"
LEN="$(stat -f%z "$DIST/$DMG_NAME")"
step "DMG: $DIST/$DMG_NAME  (${LEN} bytes, sha256 ${SHA:0:16}…)"

# 5. Appcast item -----------------------------------------------------------
step "5/6 Appcast item -> $DIST/appcast.xml"
ED_SIG=""
if [ -n "${SPARKLE_BIN:-}" ] && [ -x "$SPARKLE_BIN/sign_update" ]; then
  ED_SIG="$("$SPARKLE_BIN/sign_update" "$DIST/$DMG_NAME" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')"
else
  warn "    Sparkle EdDSA signature SKIPPED (set SPARKLE_BIN once Sparkle is added)"
fi
PUBDATE="$(LC_ALL=en_US.UTF-8 date -u '+%a, %d %b %Y %H:%M:%S +0000')"
DL_BASE="https://${APPCAST_HOST:-baton.tonebox.io}"
cat > "$DIST/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Baton</title>
    <item>
      <title>Baton ${VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <enclosure url="${DL_BASE}/${DMG_NAME}"
                 sparkle:edSignature="${ED_SIG:-PLACEHOLDER_RUN_sign_update}"
                 length="${LEN}" type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML

# 6. Publish (opt-in) -------------------------------------------------------
if [ "${PUBLISH:-0}" = "1" ] && [ -n "${WEB01:-}" ]; then
  step "6/6 Publish (scp DMG + appcast to $WEB01)"
  scp "$DIST/$DMG_NAME" "$WEB01:/tmp/$DMG_NAME"
  scp "$DIST/appcast.xml" "$WEB01:/tmp/appcast.xml"
  bold "Published. Verify the origin feed serves $VERSION with sha256 $SHA"
else
  echo
  bold "Local artifacts ready in $DIST/ (NOT published)."
  echo "  To ship: sign (SIGN_ID) + notarize (NOTARY_PROFILE) + Sparkle key (SPARKLE_BIN),"
  echo "  then re-run with PUBLISH=1 WEB01=user@host. Never distribute an unsigned build."
fi
