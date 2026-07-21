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
# The monotonic build number == CFBundleVersion. Sparkle compares the appcast's
# sparkle:version against the installed CFBundleVersion, so this — NOT the marketing
# string — must be what the appcast advertises, and it must strictly increase every
# release. Bump CURRENT_PROJECT_VERSION in project.yml before each publish. (W-09)
BUILD="$(perl -ne 'print $1 if /CURRENT_PROJECT_VERSION:\s*"([^"]+)"/' "$APP_DIR/project.yml" | head -1)"
[ -n "$BUILD" ] || { echo "could not read CURRENT_PROJECT_VERSION from $APP_DIR/project.yml"; exit 1; }
case "$BUILD" in (*[!0-9]*|'') echo "CURRENT_PROJECT_VERSION must be an integer build number (got '$BUILD')"; exit 1;; esac
DIST="dist"
DD="/tmp/baton-release"
DMG_NAME="Baton-${VERSION}.dmg"
mkdir -p "$DIST"

# A published release must be reproducible from a tagged commit, and the pre-build Help
# sync must not smuggle uncommitted edits into the bundle — so refuse a dirty tree when
# actually publishing. (W-17 / DIST-07/17)
if [ "${PUBLISH:-0}" = "1" ] && [ -n "$(git status --porcelain)" ]; then
  echo "working tree is dirty — commit or stash before publishing (release must be reproducible)"; exit 1
fi

# Sparkle key preflight: the private signing key must match the SUPublicEDKey baked into
# the build, or every future update would fail EdDSA verification on installed apps. (W-17 / DIST-16)
if [ -n "${SPARKLE_BIN:-}" ] && [ -x "$SPARKLE_BIN/sign_update" ]; then
  PUBKEY="$(perl -ne 'print $1 if /SUPublicEDKey:\s*"([^"]+)"/' "$APP_DIR/project.yml" | head -1)"
  KEYPUB="$("$SPARKLE_BIN/sign_update" -p 2>/dev/null || true)"
  if [ -n "$KEYPUB" ] && [ -n "$PUBKEY" ] && [ "$KEYPUB" != "$PUBKEY" ]; then
    echo "Sparkle signing key does not match SUPublicEDKey in project.yml — updates would fail to verify"; exit 1
  fi
fi

bold "Baton $VERSION — release pipeline"

# 0. Test gate --------------------------------------------------------------
# Never package a release that hasn't passed the full suite (Actions is off, so
# this is the only gate). CLEAN=1 forces a from-scratch build+test.
step "0/6 Test gate (scripts/test.sh)"
CLEAN=1 "$(dirname "$0")/test.sh" || { echo "tests failed — refusing to package"; exit 1; }

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
  # Gatekeeper acceptance check (W-17 / DIST-08): confirm the notarized DMG passes assessment.
  spctl -a -t open --context context:primary-signature -vv "$DIST/$DMG_NAME" \
    || warn "spctl assessment reported an issue — inspect before shipping"
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
      <sparkle:version>${BUILD}</sparkle:version>
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
if [ "${PUBLISH:-0}" = "1" ]; then
  # Never publish a broken feed or an unsigned build. (W-17 / DIST-05)
  [ -n "$ED_SIG" ] || { echo "refusing to publish: no EdDSA signature (set SPARKLE_BIN)"; exit 1; }
  [ -n "${SIGN_ID:-}" ] || { echo "refusing to publish: build is not signed (set SIGN_ID)"; exit 1; }
  [ -n "${WEB01:-}" ] || { echo "set WEB01=user@host to publish"; exit 1; }
  # Serve from nginx's docroot, NOT /tmp (which is wiped on reboot). (W-17 / DIST-04)
  REMOTE_DIR="${REMOTE_DIR:-/opt/docker/baton-web/site}"
  step "6/6 Publish → $WEB01:$REMOTE_DIR (DMG first, then appcast, atomically)"
  # DMG before appcast so the feed never points at a missing download; temp name + mv = atomic.
  scp "$DIST/$DMG_NAME" "$WEB01:$REMOTE_DIR/.$DMG_NAME.tmp"
  ssh "$WEB01" "mv -f '$REMOTE_DIR/.$DMG_NAME.tmp' '$REMOTE_DIR/$DMG_NAME'"
  scp "$DIST/appcast.xml" "$WEB01:$REMOTE_DIR/.appcast.xml.tmp"
  ssh "$WEB01" "mv -f '$REMOTE_DIR/.appcast.xml.tmp' '$REMOTE_DIR/appcast.xml'"
  # Origin verify: the served DMG must exist and match the advertised byte length.
  DL="https://${APPCAST_HOST:-baton.tonebox.io}/$DMG_NAME"
  REMOTE_LEN="$(curl -fsSL -o /dev/null -w '%{size_download}' "$DL" || echo 0)"
  [ "$REMOTE_LEN" = "$LEN" ] || { echo "origin verify FAILED: $DL served $REMOTE_LEN bytes, expected $LEN"; exit 1; }
  # Tag the release now it's live (tree is clean per the guard above); -f allows re-publish.
  git tag -f "v$VERSION" && echo "tagged v$VERSION"
  bold "Published $VERSION (build $BUILD), origin-verified (${LEN} bytes, sha256 ${SHA:0:16}…)."
else
  echo
  bold "Local artifacts ready in $DIST/ (NOT published)."
  echo "  To ship: sign (SIGN_ID) + notarize (NOTARY_PROFILE) + Sparkle key (SPARKLE_BIN),"
  echo "  then re-run with PUBLISH=1 WEB01=user@host. Never distribute an unsigned build."
fi
