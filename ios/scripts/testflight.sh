#!/bin/bash
#
# Build + sign + upload Baton for iPhone to TestFlight in one command.
#
#   cd ios && ./scripts/testflight.sh
#
# Modelled on KeepFloat's proven script (apps/ios/scripts/testflight.sh) — same
# Apple team, same machine, same hard-won lesson: sign MANUALLY via a throwaway
# keychain using the distribution .p12 and explicit App Store provisioning
# profiles. Do NOT reach for xcodebuild's `-allowProvisioningUpdates` cloud
# signing; it fails ("Authentication failed: bearer token") for this ASC API key
# even though the same key uploads fine with altool.
#
# Build number is the Unix epoch ($(date +%s)) so it is always unique and
# monotonic; MARKETING_VERSION in project.yml is the user-facing version. The
# script makes a TRANSIENT project.yml edit (manual signing + profile
# specifiers) and restores it on exit via a trap, so your working tree is left
# clean even if a step fails.
#
# ENTITLEMENTS (App Group):
#   - DEFAULT (WITH_ENTITLEMENTS unset/1): the app and its widget share
#     group.io.tonebox.baton — that is what lets the widget read now-playing.
#     Both App Store profiles must carry the group or signing fails loudly.
#   - ESCAPE HATCH (WITH_ENTITLEMENTS=0): DROPS the App Group from both targets
#     and signs against profiles that don't carry it — the widget then shows
#     placeholder data and everything else works. Use it to get a build out
#     while the group identifier is still missing:
#         WITH_ENTITLEMENTS=0 ./scripts/testflight.sh
#     The App Group identifier CANNOT be created through the App Store Connect
#     API (there is no /v1/appGroups resource); it has to be added once in the
#     developer portal, after which the profiles must be regenerated.
#
# SKIP_UPLOAD=1 builds and exports the .ipa but stops before altool — useful
# before the App Store Connect app record exists (records cannot be created via
# the API either; `apps` allows only GET and UPDATE).
#
# When the CarPlay audio entitlement is granted, add it to BatonMobile.entitlements
# and to the app's App Store profile; nothing in this script changes.
#
# SECRETS are never committed. Provide them via the environment or a gitignored
# scripts/.testflight.env (see scripts/.testflight.env.example):
#   P12_PASSWORD     password for the distribution .p12   (required)
#   ASC_ISSUER_ID    App Store Connect API issuer UUID    (required)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS="$(cd "$DIR/.." && pwd)"
REPO="$(cd "$IOS/.." && pwd)"

# Load secrets/overrides from the gitignored env file if present.
[ -f "$DIR/.testflight.env" ] && set -a && . "$DIR/.testflight.env" && set +a

# --- config (override via env / .testflight.env) ---
ASC_KEY_ID="${ASC_KEY_ID:-A9SQS39C62}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
P12_PATH="${P12_PATH:-$HOME/.appstoreconnect/keepfloat_dist.p12}"   # one distribution cert per team
TEAM_ID="${TEAM_ID:-Q8822GNL2H}"
IDENTITY="${IDENTITY:-Apple Distribution: Anatoli Vishnyakov (${TEAM_ID})}"
APP_BUNDLE="${APP_BUNDLE:-io.tonebox.baton}"
WIDGET_BUNDLE="${WIDGET_BUNDLE:-io.tonebox.baton.widgets}"
APP_PROFILE="${APP_PROFILE:-Baton App Store}"
WIDGET_PROFILE="${WIDGET_PROFILE:-Baton Widgets App Store}"
WITH_ENTITLEMENTS="${WITH_ENTITLEMENTS:-1}"
SKIP_UPLOAD="${SKIP_UPLOAD:-0}"
KC="${KC:-/tmp/baton-build.keychain-db}"
KCPASS="${KCPASS:-batonbuild}"
BUILD="$(date +%s)"

die() { echo "ERROR: $*" >&2; exit 1; }
[ -n "${P12_PASSWORD:-}" ]  || die "P12_PASSWORD not set (env or scripts/.testflight.env)"
[ -n "${ASC_ISSUER_ID:-}" ] || die "ASC_ISSUER_ID not set (env or scripts/.testflight.env)"
[ -f "$P12_PATH" ]      || die "distribution .p12 not found at $P12_PATH"
[ -f "$ASC_KEY_PATH" ]  || die "ASC API key not found at $ASC_KEY_PATH"
command -v xcodegen >/dev/null || die "xcodegen not installed (brew install xcodegen)"

cd "$IOS"

# Preflight: the phone ships the same shared core as the Mac, so a red gate means
# a broken player, not just a broken desktop build. Refuse to upload on red.
# Skippable for an emergency upload with SKIP_TESTS=1.
if [ "${SKIP_TESTS:-0}" != "1" ]; then
  echo "→ preflight: shared-core test gate"
  (cd "$REPO" && ./scripts/test.sh >/dev/null 2>&1) \
    || die "test gate is red — fix it, or SKIP_TESTS=1 to ship anyway"
  echo "  gate green"
fi

cleanup() {
  echo "===== cleanup ====="
  cd "$IOS"
  git checkout -- project.yml 2>/dev/null || true
  security list-keychains -d user -s "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null || true
  security delete-keychain "$KC" 2>/dev/null || true
  xcodegen generate >/dev/null 2>&1 || true
  echo "cleanup done"
}
trap cleanup EXIT

echo "===== [1/6] temp keychain + import distribution identity (build $BUILD) ====="
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
security import "$P12_PATH" -k "$KC" -P "$P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null
# Prepend the temp keychain; keep login (it carries the WWDR intermediate).
security list-keychains -d user -s "$KC" "$HOME/Library/Keychains/login.keychain-db"
security find-identity -v -p codesigning "$KC" | grep -q "$IDENTITY" \
  || die "distribution identity '$IDENTITY' not found after import (wrong P12_PASSWORD?)"

echo "===== [2/6] transient project.yml manual-signing edit (entitlements: $([ "$WITH_ENTITLEMENTS" = 1 ] && echo KEPT || echo dropped)) ====="
python3 - "$IOS/project.yml" "$APP_PROFILE" "$WIDGET_PROFILE" "$IDENTITY" "$WITH_ENTITLEMENTS" <<'PY'
import re
import sys
path, app_prof, widget_prof, identity, with_ent = sys.argv[1:6]
s = open(path).read()
if with_ent != "1":
    # Remove both `entitlements:` blocks wholesale. Without the App Group there
    # is nothing else in them, so the targets sign cleanly against plain profiles.
    s, n = re.subn(
        r"\n    entitlements:\n      path: \S+\n      properties:\n"
        r"        com\.apple\.security\.application-groups: \[[^\]]*\]\n",
        "\n", s)
    assert n == 2, f"expected 2 entitlements blocks to drop, dropped {n}"
    print("entitlements dropped (widget will show placeholder data)")
assert s.count("    CODE_SIGN_STYLE: Automatic") == 1, "expected one base CODE_SIGN_STYLE: Automatic"
s = s.replace("    CODE_SIGN_STYLE: Automatic",
              f'    CODE_SIGN_STYLE: Manual\n    CODE_SIGN_IDENTITY: "{identity}"', 1)

def add_profile(text, anchor, profile):
    """Attach a profile specifier to a target's settings block."""
    assert anchor in text, f"expected settings anchor: {anchor}"
    indent = " " * 8
    return text.replace(anchor, f'{anchor}\n{indent}PROVISIONING_PROFILE_SPECIFIER: "{profile}"', 1)

s = add_profile(s, "        PRODUCT_BUNDLE_IDENTIFIER: io.tonebox.baton\n"
                   "        PRODUCT_NAME: Baton".rstrip(), app_prof)
s = add_profile(s, "        PRODUCT_BUNDLE_IDENTIFIER: io.tonebox.baton.widgets", widget_prof)
open(path, "w").write(s)
print("project.yml patched (manual signing, profiles set)")
PY

echo "===== [3/6] xcodegen generate ====="
xcodegen generate

echo "===== [4/6] archive ====="
rm -rf build/Baton.xcarchive build/export
xcodebuild archive -project BatonMobile.xcodeproj -scheme BatonMobile -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Baton.xcarchive \
  CURRENT_PROJECT_VERSION="$BUILD" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
  OTHER_CODE_SIGN_FLAGS="--keychain $KC"

# Upload dSYMs so production crashes symbolicate. Guarded: only runs when a token is
# provided (the org token lives in the login Keychain — see the global notes); non-fatal.
if [ -n "${SENTRY_AUTH_TOKEN:-}" ] && command -v sentry-cli >/dev/null; then
  echo "===== dSYM upload to Sentry ====="
  sentry-cli debug-files upload \
    --org "${SENTRY_ORG:-get-virtual-view}" --project "${SENTRY_PROJECT:-baton-ios}" \
    build/Baton.xcarchive/dSYMs || echo "sentry-cli upload failed (non-fatal)"
fi

echo "===== [5/6] export .ipa ====="
cat > /tmp/baton-export.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingCertificate</key><string>${IDENTITY}</string>
  <key>provisioningProfiles</key><dict>
    <key>${APP_BUNDLE}</key><string>${APP_PROFILE}</string>
    <key>${WIDGET_BUNDLE}</key><string>${WIDGET_PROFILE}</string>
  </dict>
  <key>uploadSymbols</key><true/><key>stripSwiftSymbols</key><true/>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath build/Baton.xcarchive \
  -exportPath build/export -exportOptionsPlist /tmp/baton-export.plist \
  OTHER_CODE_SIGN_FLAGS="--keychain $KC"

if [ "$SKIP_UPLOAD" = 1 ]; then
  echo "===== [6/6] SKIP_UPLOAD=1 — built and exported, not uploading ====="
  ls -la build/export/
  exit 0
fi

echo "===== [6/6] upload to TestFlight (build $BUILD) ====="
xcrun altool --upload-app -f build/export/Baton.ipa -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "===== DONE: uploaded Baton build $BUILD to TestFlight ====="
