#!/bin/bash
#
# publish.sh's two silent-degradation guards. (TBX-5317, D-F8 and D-F9)
#
# WHY THIS EXISTS. Both defects had the same shape as the ones in testflight.sh: a
# protection that stopped protecting without the log looking any different.
#
#   D-F8  (Since TBX-7519 the clock is the release kit's rk_notarize; below proves wiring.)
#         The notarize wall clock was armed by
#             command -v timeout >/dev/null || timeout() { shift; "$@"; }   # run bare
#         `timeout` is not a macOS builtin; it comes from Homebrew's coreutils. On a Mac
#         without it the shim ate the `900` and ran `xcrun notarytool submit` unbounded,
#         restoring the 69-minute hang the comment above it says it removes. Nothing
#         printed differently, so the machine that lost the protection looked exactly like
#         the machine that had it.
#
#   TBX-5357  `hdiutil detach` of the read-only verification mount failed once with
#         "Resource busy" and ended a run in which the DMG was already signed, notarized,
#         stapled and verified. There was no retry, and the message was hdiutil's own
#         one-liner, so a transient that had cleared a minute later cost the whole
#         twenty-minute run. Covered here: the retry, the -force fallback, the message
#         that names the resume point, and the RESUME_FROM_STAPLED identity check that
#         makes resuming safe.
#
#   D-F9  A failed Gatekeeper assessment was a `warn` while every other artifact check in
#         the script is fatal: entitlements, both staples, the DMG verify, the origin hash.
#         `spctl` failing is the closest proxy there is for "the user's Mac will refuse
#         this download", and it printed one yellow line in the middle of a twenty-minute
#         log, above a publish and a tag that both went ahead.
#
# HOW IT TESTS THEM. It extracts the REAL blocks out of publish.sh by their own anchors and
# runs them against stubs, the same way test-testflight-exits.sh does. Nothing is copied:
# put the old one-line shim back, or turn the spctl check back into a warn, and this goes
# red.
#
# What it cannot cover: Apple, a signing identity, a DMG. Both defects are shell control
# flow, which is what this can reach.
#
# No Xcode, no network, no Apple, about two seconds.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
SUBJECT="${BATON_PUBLISH_SUBJECT:-$ROOT/scripts/publish.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '\033[32mok    %s\033[0m\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '\033[31mFAIL  %s\033[0m\n' "$1"; }

WORK="$(mktemp -d)"
TMP_RELEASE="$(mktemp -d /private/tmp/baton-publish-checkout-test.XXXXXX)"
trap 'rm -rf "$WORK" "$TMP_RELEASE"' EXIT

# --- TBX-5386: the release cannot start in the primary checkout -------------------------

# Drive the same shared function publish.sh calls. BATON_PRIMARY_CHECKOUT plants a
# primary at a throwaway path, while TMP_RELEASE proves an independent checkout under
# /private/tmp is admitted.
. "$ROOT/scripts/release-checkout.sh"

git init -q -b main "$WORK/primary"
git -C "$WORK/primary" config user.email t@example.com
git -C "$WORK/primary" config user.name t
printf 'primary\n' >"$WORK/primary/README"
git -C "$WORK/primary" add README
git -C "$WORK/primary" commit -qm primary

out="$(
  export BATON_PRIMARY_CHECKOUT="$WORK/primary"
  unset ALLOW_PRIMARY_CHECKOUT
  release_checkout_assert_not_primary "$WORK/primary" 2>&1
)"
rc=$?
if [ "$rc" = 0 ]; then
  bad "TBX-5386: publish guard admitted the planted primary checkout"
elif ! grep -qF <<<"$out" '/private/tmp/baton-rel'; then
  bad "TBX-5386: refusal did not name the Mac release checkout. Got: $out"
elif ! grep -qF <<<"$out" '/private/tmp/baton-release-tf'; then
  bad "TBX-5386: refusal did not name the iPhone release checkout. Got: $out"
elif ! grep -qF <<<"$out" 'git clone --branch main'; then
  bad "TBX-5386: refusal did not give the one-line Mac recovery command. Got: $out"
elif ! grep -qF <<<"$out" 'checkout --detach origin/main'; then
  bad "TBX-5386: refusal did not give the one-line iPhone recovery command. Got: $out"
else
  ok "TBX-5386 publish guard refuses a planted primary checkout and names both recoveries"
fi

git init -q -b main "$TMP_RELEASE/release"
if (
  export BATON_PRIMARY_CHECKOUT="$WORK/primary"
  unset ALLOW_PRIMARY_CHECKOUT
  release_checkout_assert_not_primary "$TMP_RELEASE/release"
); then
  ok "TBX-5386 publish guard admits an independent checkout under /private/tmp"
else
  bad "TBX-5386: publish guard refused the dedicated checkout under /private/tmp"
fi

if (
  export BATON_PRIMARY_CHECKOUT="$WORK/primary" ALLOW_PRIMARY_CHECKOUT=1
  release_checkout_assert_not_primary "$WORK/primary" >/dev/null 2>&1
); then
  ok "TBX-5386 ALLOW_PRIMARY_CHECKOUT=1 permits and records an intentional override"
else
  bad "TBX-5386: ALLOW_PRIMARY_CHECKOUT=1 did not permit the documented override"
fi

if grep -qF 'release_checkout_assert_not_primary "$PWD"' "$SUBJECT"; then
  ok "TBX-5386 wiring: publish.sh calls the primary-checkout guard"
else
  bad "TBX-5386 wiring: publish.sh no longer calls the primary-checkout guard"
fi

# --- TBX-5386: one command recreates both release checkouts -----------------------------

SOURCE="$WORK/source"
ORIGIN="$WORK/origin.git"
MAC_CLONE="$WORK/baton-rel"
IOS_CLONE="$WORK/baton-release-tf"
mkdir -p "$SOURCE/app/Config" "$SOURCE/ios/Config"
git init -q -b main "$SOURCE"
git -C "$SOURCE" config user.email t@example.com
git -C "$SOURCE" config user.name t
printf 'app/Config/Crashbox.local.xcconfig\napp/Config/CrashboxArtifactUpload.local.json\nios/Config/Crashbox.local.xcconfig\nios/Config/CrashboxArtifactUpload.local.json\n' >"$SOURCE/.gitignore"
printf 'tracked\n' >"$SOURCE/README"
printf 'MAC_DSN\n' >"$SOURCE/app/Config/Crashbox.local.xcconfig"
printf 'IOS_DSN\n' >"$SOURCE/ios/Config/Crashbox.local.xcconfig"
printf 'FAKE_ARTIFACT_CREDENTIAL\n' >"$SOURCE/app/Config/CrashboxArtifactUpload.local.json"
printf 'FAKE_IOS_ARTIFACT_CREDENTIAL\n' >"$SOURCE/ios/Config/CrashboxArtifactUpload.local.json"
chmod 600 "$SOURCE/app/Config/Crashbox.local.xcconfig" \
  "$SOURCE/app/Config/CrashboxArtifactUpload.local.json" \
  "$SOURCE/ios/Config/Crashbox.local.xcconfig" \
  "$SOURCE/ios/Config/CrashboxArtifactUpload.local.json"
git -C "$SOURCE" add .gitignore README
git -C "$SOURCE" commit -qm initial
git init -q --bare "$ORIGIN"
git -C "$SOURCE" remote add origin "$ORIGIN"
git -C "$SOURCE" push -q -u origin main

prepare_out="$(
  BATON_PRIMARY_CHECKOUT="$SOURCE" \
  BATON_RELEASE_ORIGIN="$ORIGIN" \
  BATON_MAC_RELEASE_CHECKOUT="$MAC_CLONE" \
  BATON_IOS_RELEASE_CHECKOUT="$IOS_CLONE" \
    "$ROOT/scripts/prepare-release-checkouts.sh" 2>&1
)"
prepare_rc=$?
if [ "$prepare_rc" != 0 ]; then
  bad "TBX-5386: preparation script could not recreate both missing checkouts. Got: $prepare_out"
elif [ ! -d "$MAC_CLONE/.git" ] || [ ! -d "$IOS_CLONE/.git" ]; then
  bad "TBX-5386: preparation script did not create both Git clones"
elif [ ! -f "$MAC_CLONE/app/Config/Crashbox.local.xcconfig" ] || \
     [ ! -f "$MAC_CLONE/app/Config/CrashboxArtifactUpload.local.json" ] || \
     [ ! -f "$IOS_CLONE/ios/Config/Crashbox.local.xcconfig" ] || \
     [ ! -f "$IOS_CLONE/ios/Config/CrashboxArtifactUpload.local.json" ]; then
  bad "TBX-5386/TBX-5483: preparation script did not copy the Crashbox inputs"
elif [ "$(stat -f '%Lp' "$MAC_CLONE/app/Config/Crashbox.local.xcconfig")" != 600 ] || \
     [ "$(stat -f '%Lp' "$MAC_CLONE/app/Config/CrashboxArtifactUpload.local.json")" != 600 ] || \
     [ "$(stat -f '%Lp' "$IOS_CLONE/ios/Config/Crashbox.local.xcconfig")" != 600 ] || \
     [ "$(stat -f '%Lp' "$IOS_CLONE/ios/Config/CrashboxArtifactUpload.local.json")" != 600 ]; then
  bad "TBX-5386/TBX-5483: copied Crashbox inputs are not mode 0600"
elif [ "$(git -C "$MAC_CLONE" branch --show-current)" != main ]; then
  bad "TBX-5386: Mac release clone is not on main"
elif git -C "$IOS_CLONE" symbolic-ref -q HEAD >/dev/null; then
  bad "TBX-5386: iPhone release clone is not detached at origin/main"
else
  ok "TBX-5386/TBX-5483 preparation recreates both clones with mode-0600 Crashbox inputs"
fi

printf 'refreshed\n' >>"$SOURCE/README"
git -C "$SOURCE" add README
git -C "$SOURCE" commit -qm refreshed
git -C "$SOURCE" push -q origin main
prepare_out="$(
  BATON_PRIMARY_CHECKOUT="$SOURCE" \
  BATON_RELEASE_ORIGIN="$ORIGIN" \
  BATON_MAC_RELEASE_CHECKOUT="$MAC_CLONE" \
  BATON_IOS_RELEASE_CHECKOUT="$IOS_CLONE" \
    "$ROOT/scripts/prepare-release-checkouts.sh" 2>&1
)"
prepare_rc=$?
SOURCE_HEAD="$(git -C "$SOURCE" rev-parse HEAD)"
if [ "$prepare_rc" != 0 ]; then
  bad "TBX-5386: preparation script could not refresh both checkouts. Got: $prepare_out"
elif [ "$(git -C "$MAC_CLONE" rev-parse HEAD)" != "$SOURCE_HEAD" ] || \
     [ "$(git -C "$IOS_CLONE" rev-parse HEAD)" != "$SOURCE_HEAD" ]; then
  bad "TBX-5386: refreshed release checkouts did not reach origin/main"
else
  ok "TBX-5386 preparation refreshes both clean release checkouts to origin/main"
fi

# An intentionally absent optional credential must remove a stale one from the release
# clone. Leaving it behind would turn an unconfigured future release into a configured
# upload using an obsolete capability.
rm -f "$SOURCE/app/Config/CrashboxArtifactUpload.local.json"
rm -f "$SOURCE/ios/Config/CrashboxArtifactUpload.local.json"
prepare_out="$(
  BATON_PRIMARY_CHECKOUT="$SOURCE" \
  BATON_RELEASE_ORIGIN="$ORIGIN" \
  BATON_MAC_RELEASE_CHECKOUT="$MAC_CLONE" \
  BATON_IOS_RELEASE_CHECKOUT="$IOS_CLONE" \
    "$ROOT/scripts/prepare-release-checkouts.sh" 2>&1
)"
prepare_rc=$?
if [ "$prepare_rc" != 0 ]; then
  bad "TBX-5483: preparation could not refresh after removing the optional credential. Got: $prepare_out"
elif [ -e "$MAC_CLONE/app/Config/CrashboxArtifactUpload.local.json" ]; then
  bad "TBX-5483: preparation left a stale artifact credential in the Mac release clone"
elif [ -e "$IOS_CLONE/ios/Config/CrashboxArtifactUpload.local.json" ]; then
  bad "TBX-5498: preparation left a stale artifact credential in the iPhone release clone"
else
  ok "TBX-5483/TBX-5498 preparation removes stale optional artifact credentials"
fi

# Since the release kit (TBX-7519) the tag is pushed, on the build commit, by
# rk_tag_release; the release metadata (cask, site) still stays local for the mirror step.
if grep -qE '^  RK_RETAG="\$\{BATON_REPUBLISH:\+1\}" rk_tag_release "\$VERSION" "\$MACREL_COMMIT"' "$SUBJECT" && \
   grep -qF 'push the tag' "$SUBJECT" && \
   grep -qF 'does not commit or push them' "$SUBJECT"; then
  ok "TBX-5386 publish.sh states plainly that it pushes the tag and leaves release metadata local"
else
  bad "TBX-5386: publish.sh is ambiguous about whether it pushes the tag and release metadata"
fi

# --- the real blocks, by anchor ---------------------------------------------------------

NOTARIZE_FN="$(awk '/^notarize\(\) \{$/,/^\}$/' "$SUBJECT")"
SPCTL_BLOCK="$(awk '/^  if ! spctl -a -t open /,/^  fi$/' "$SUBJECT")"
DETACH_FN="$(awk '/^detach_image\(\) \{$/,/^\}$/' "$SUBJECT")"
DETACH_FAIL_FN="$(awk '/^detach_failed_after_staple\(\) \{$/,/^\}$/' "$SUBJECT")"
RESUME_FN="$(awk '/^resume_assert_stapled_dmg\(\) \{$/,/^\}$/' "$SUBJECT")"

for name in NOTARIZE_FN SPCTL_BLOCK DETACH_FN DETACH_FAIL_FN RESUME_FN; do
  eval "body=\$$name"
  if [ -z "$body" ]; then
    bad "$name: anchor not found in publish.sh; the script was restructured"
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
    exit 1
  fi
done

PRELUDE='set -uo pipefail
warn() { printf "  ! %s\n" "$*"; }
'

# A PATH with nothing on it but what we put there, so "coreutils is absent" is a fact
# rather than a hope.
bare_path() {   # $@ = names to provide from the real PATH
  rm -rf "$WORK/bin"; mkdir -p "$WORK/bin"
  local n src
  for n in bash sed awk grep printf sleep "$@"; do
    src="$(command -v "$n" 2>/dev/null)" && [ -n "$src" ] && ln -sf "$src" "$WORK/bin/$n"
  done
  printf '%s' "$WORK/bin"
}

# --- D-F8: the notarize wall clock -----------------------------------------------------
#
# Since TBX-7519 the clock is the release kit's rk_notarize. Its own tests (run by
# scripts/test.sh as release-kit/check, on these vendored bytes) prove what this section
# used to prove about the local shim, and more strictly: a timeout that does not interrupt
# is refused, no clock at all refuses and submits nothing (the old perl-alarm fallback and
# the loud unbounded run are both gone), attempts are bounded and reaped, and no pkill.
# What is left to prove here is the wiring.
if grep -q <<<"$NOTARIZE_FN" 'rk_notarize "\$file" "\$NOTARY_PROFILE"'; then
  ok "D-F8 wiring: notarize() submits through the kit's bounded rk_notarize"
else
  bad "D-F8 wiring: notarize() no longer goes through rk_notarize"
fi
if grep -qE '^\. "\$PWD/scripts/release-kit/lib/notarize\.sh"$' "$SUBJECT"; then
  ok "D-F8 wiring: publish.sh sources the vendored kit's notarize.sh"
else
  bad "D-F8 wiring: publish.sh does not source scripts/release-kit/lib/notarize.sh"
fi
# Count rather than `grep -q`: under pipefail, grep -q exiting early can SIGPIPE the grep
# feeding it on a file publish.sh's size, and the pipeline then reports failure for a
# match. Threadstow's identical check passed a script that submitted directly that way.
if [ "$(grep -vE '^[[:space:]]*#' "$SUBJECT" | grep -cE 'notarytool submit')" != 0 ]; then
  bad "D-F8: publish.sh calls notarytool submit directly, outside the bounded rk_notarize"
else
  ok "D-F8: publish.sh has no direct notarytool submit left to run unbounded"
fi

# --- D-F9: a failed assessment stops the release -----------------------------------------

make_spctl() {   # $1 = exit status
  rm -rf "$WORK/sbin"; mkdir -p "$WORK/sbin"
  printf '#!/bin/bash\necho "stub spctl: rejected"\nexit %s\n' "$1" >"$WORK/sbin/spctl"
  chmod +x "$WORK/sbin/spctl"
}

run_spctl() {   # $1 = spctl exit status, $2 = ALLOW_SPCTL_FAILURE
  make_spctl "$1"
  { printf '%s' "$PRELUDE"
    echo 'DIST=/tmp; DMG_NAME=Baton-0.19.0.dmg'
    printf '%s\n' "$SPCTL_BLOCK"
    echo 'echo "reached the publish"'; } >"$WORK/t9.sh"
  ALLOW_SPCTL_FAILURE="$2" PATH="$WORK/sbin:$PATH" bash "$WORK/t9.sh" 2>&1
}

out="$(run_spctl 3 "")"; rc=$?
if [ "$rc" = 0 ]; then
  bad "D-F9: a rejected DMG still published. Got: $out"
elif grep -q <<<"$out" "reached the publish"; then
  bad "D-F9: the script carried on past a failed assessment. Got: $out"
elif ! grep -q <<<"$out" "spctl rejected the notarized DMG"; then
  bad "D-F9: no message saying what was rejected. Got: $out"
else
  ok "D-F9 a failed Gatekeeper assessment stops the release before the upload"
fi

out="$(run_spctl 3 "1")"; rc=$?
if [ "$rc" != 0 ]; then
  bad "D-F9: ALLOW_SPCTL_FAILURE=1 did not let a deliberate override through. Got: $out"
elif ! grep -q <<<"$out" "reached the publish"; then
  bad "D-F9: the override stopped the release anyway. Got: $out"
elif ! grep -q <<<"$out" "publishing anyway"; then
  bad "D-F9: the override is silent, so the log does not record that it was used. Got: $out"
else
  ok "D-F9 ALLOW_SPCTL_FAILURE=1 continues, and says in the log that it did"
fi

out="$(run_spctl 0 "")"; rc=$?
if [ "$rc" != 0 ]; then
  bad "D-F9: a passing assessment stopped the release. Got: $out"
elif ! grep -q <<<"$out" "reached the publish"; then
  bad "D-F9: a passing assessment did not continue. Got: $out"
else
  ok "D-F9 a passing assessment continues, unchanged"
fi

# --- D-F9: and it is still the only one of these checks that is not fatal ----------------
#
# Stated as an assertion rather than a comment, since the argument for making it fatal was
# that every sibling already is.
if grep -q <<<"$SPCTL_BLOCK" 'exit 1'; then
  ok "D-F9 the assessment block still ends a failed release rather than noting it"
else
  bad "D-F9: the spctl block no longer exits, so a rejected DMG would publish again"
fi
if grep -q 'spctl .*|| warn' "$SUBJECT"; then
  bad "D-F9: an spctl assessment somewhere in publish.sh is back to warn-and-continue"
else
  ok "D-F9 no spctl call in publish.sh degrades to a warning"
fi

# --- TBX-5357: the verification unmount retries before it gives up ----------------------
#
# The real failure was `hdiutil detach` returning 16 with `couldn't unmount "disk12" -
# Resource busy` while a Spotlight importer (most likely) still had the read-only mount
# open. That is faked here rather than planted for real: attaching a genuine image would
# make this harness touch real devices, and what is under test is the retry control flow,
# which the stub reproduces exactly, message and exit status included.
#
# `sleep` is stubbed to a no-op so three attempts cost nothing on a gate that runs this on
# every merge. The wait itself is asserted as text below, so removing it still goes red.

make_hdiutil() {   # $1 = how many plain detaches fail, $2 = exit status of `detach -force`
  rm -rf "$WORK/hbin"; mkdir -p "$WORK/hbin"
  : >"$WORK/hdiutil.calls"; echo 0 >"$WORK/hdiutil.count"
  cat >"$WORK/hbin/hdiutil" <<EOF
#!/bin/bash
echo "\$*" >>"$WORK/hdiutil.calls"
if [ "\$1" = detach ] && [ "\$2" = -force ]; then exit $2; fi
if [ "\$1" = detach ]; then
  c=\$(cat "$WORK/hdiutil.count"); c=\$((c + 1)); echo "\$c" >"$WORK/hdiutil.count"
  if [ "\$c" -le $1 ]; then
    echo 'hdiutil: couldn'"'"'t unmount "disk12" - Resource busy' >&2
    exit 16
  fi
  exit 0
fi
exit 0
EOF
  chmod +x "$WORK/hbin/hdiutil"
  printf '#!/bin/bash\nexit 0\n' >"$WORK/hbin/sleep"; chmod +x "$WORK/hbin/sleep"
}

run_detach() {   # $1 = plain detaches that fail, $2 = force exit status
  make_hdiutil "$1" "$2"
  { printf '%s' "$PRELUDE"
    echo 'DIST=dist; DMG_NAME=Baton-0.19.3.dmg'
    printf '%s\n' "$DETACH_FN"
    printf '%s\n' "$DETACH_FAIL_FN"
    echo 'if detach_image /tmp/vmp "the verification image"; then'
    echo '  echo "DETACH_OK"'
    echo 'else'
    echo '  detach_failed_after_staple /tmp/vmp; echo "DETACH_GAVE_UP"'
    echo 'fi'; } >"$WORK/t5357.sh"
  PATH="$WORK/hbin:$PATH" bash "$WORK/t5357.sh" 2>&1
}

# Two busy answers, then the mount lets go. That is the 0.19.3 case, where one detach by
# hand a minute later worked on the first try.
out="$(run_detach 2 1)"
plain="$(grep -c '^detach /tmp/vmp$' "$WORK/hdiutil.calls" || true)"
forced="$(grep -c '^detach -force' "$WORK/hdiutil.calls" || true)"
if ! grep -q <<<"$out" "DETACH_OK"; then
  bad "TBX-5357: a busy mount that clears on the third try still failed the release. Got: $out"
elif [ "$plain" != 3 ]; then
  bad "TBX-5357: expected 3 ordinary detach attempts, saw $plain. Got: $out"
elif [ "$forced" != 0 ]; then
  bad "TBX-5357: -force was used even though an ordinary detach succeeded. Got: $out"
elif ! grep -q <<<"$out" "attempt 1 of 3"; then
  bad "TBX-5357: the retries are silent, so a busy mount leaves no trace in the log. Got: $out"
else
  ok "TBX-5357 a busy verification mount is retried and succeeds without -force"
fi

# Never lets go on its own. -force is the next thing tried, not the end of the release.
out="$(run_detach 99 0)"
forced="$(grep -c '^detach -force' "$WORK/hdiutil.calls" || true)"
if ! grep -q <<<"$out" "DETACH_OK"; then
  bad "TBX-5357: -force was never tried, so a stuck mount still ends a finished release. Got: $out"
elif [ "$forced" != 1 ]; then
  bad "TBX-5357: expected exactly one -force attempt, saw $forced. Got: $out"
elif ! grep -q <<<"$out" "with -force"; then
  bad "TBX-5357: -force is used silently, so the log does not record it. Got: $out"
else
  ok "TBX-5357 a mount that never clears is detached with -force, and the log says so"
fi

# Nothing works. Then it fails, but it must not read as a failed release.
out="$(run_detach 99 16)"
if ! grep -q <<<"$out" "DETACH_GAVE_UP"; then
  bad "TBX-5357: an unbreakable mount did not fail. Got: $out"
elif ! grep -q <<<"$out" "notarized and stapled"; then
  bad "TBX-5357: the failure does not say the DMG is already notarized and stapled. Got: $out"
elif ! grep -q <<<"$out" "RESUME_FROM_STAPLED=1"; then
  bad "TBX-5357: the failure does not name the resume point. Got: $out"
elif ! grep -q <<<"$out" "DO NOT REBUILD"; then
  bad "TBX-5357: the failure still reads as a release that has to be started over. Got: $out"
else
  ok "TBX-5357 a hopeless unmount fails saying the artifact is good and naming the resume"
fi

# Wiring, the same shape as the D-F8 one: the helper can be perfect and unreferenced.
if grep -q 'detach_image "\$VERIFY_MP" "the verification image"' "$SUBJECT" \
   && grep -q 'detach_failed_after_staple "\$VERIFY_MP"' "$SUBJECT"; then
  ok "TBX-5357 wiring: step 4a unmounts through detach_image and reports through the resume message"
else
  bad "TBX-5357 wiring: step 4a no longer detaches through the retrying helper"
fi
if grep -q <<<"$DETACH_FN" '^ *sleep '; then
  ok "TBX-5357 the retry loop still waits between attempts"
else
  bad "TBX-5357: the retry loop no longer sleeps, so three attempts happen in one instant"
fi

# --- TBX-5357: RESUME_FROM_STAPLED only proceeds on this release's artifact --------------
#
# Version strings in dist/ prove nothing, so the resume reads the commit and the version
# back out of the .app inside the image, exactly as macrel_assert_built_identity does on a
# freshly built bundle. Here that bundle is a fixture with a real Info.plist, and hdiutil
# attach is stubbed to drop it at the mount point.

PINNED_COMMIT="914dff0c6f9a1b2c3d4e5f60718293a4b5c6d7e8"

make_fixture() {   # $1 = version, $2 = build, $3 = commit, $4 = reporting provider (optional)
  local provider="${4-crashbox}" environment="" dsn=""
  if [ "$provider" = crashbox ]; then
    environment=production
    dsn=public@crash.example.invalid/42
  fi
  rm -rf "$WORK/fixture"; mkdir -p "$WORK/fixture/Baton.app/Contents"
  cat >"$WORK/fixture/Baton.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleShortVersionString</key><string>$1</string>
  <key>CFBundleVersion</key><string>$2</string>
  <key>BatonSourceCommit</key><string>$3</string>
  <key>CrashReportingProvider</key><string>$provider</string>
  <key>CrashReportingEnvironment</key><string>$environment</string>
  <key>CrashReportingDSN</key><string>$dsn</string>
</dict></plist>
EOF
}

make_resume_stubs() {   # $1 = exit status of `xcrun stapler validate`
  rm -rf "$WORK/rbin"; mkdir -p "$WORK/rbin"
  cat >"$WORK/rbin/hdiutil" <<EOF
#!/bin/bash
if [ "\$1" = attach ]; then
  mp=""; while [ \$# -gt 0 ]; do [ "\$1" = -mountpoint ] && { mp="\$2"; }; shift; done
  [ -n "\$mp" ] || exit 1
  cp -R "$WORK/fixture/." "\$mp/" || exit 1
  exit 0
fi
if [ "\$1" = detach ]; then rm -rf "\$2"/Baton.app 2>/dev/null; exit 0; fi
exit 0
EOF
  cat >"$WORK/rbin/xcrun" <<EOF
#!/bin/bash
[ "\$1" = stapler ] && exit $1
exit 0
EOF
  chmod +x "$WORK/rbin/hdiutil" "$WORK/rbin/xcrun"
}

run_resume() {   # $1 = version, $2 = build, $3 = commit, $4 = stapler status, $5 = provider, $6 = association status
  make_fixture "$1" "$2" "$3" "${5-crashbox}"; make_resume_stubs "$4"
  rm -rf "$WORK/dist"; mkdir -p "$WORK/dist"; echo "not really a dmg" >"$WORK/dist/Baton-0.19.3.dmg"
  { printf '%s' "$PRELUDE"
    echo ". '$ROOT/scripts/release-identity.sh'"
    echo "DIST='$WORK/dist'; DMG_NAME=Baton-0.19.3.dmg"
    echo "MACREL_VERSION=0.19.3; MACREL_BUILD=103; MACREL_COMMIT=$PINNED_COMMIT"
    # This harness exercises resume control flow; profile/signature claims have their
    # own synthetic tests and actual qualification still requires a signed artifact.
    echo "mac_association_verify() { return ${6-0}; }"
    printf '%s\n' "$DETACH_FN"
    printf '%s\n' "$RESUME_FN"
    echo 'resume_assert_stapled_dmg "before publishing" && echo "RESUME_PROCEEDS"'; } >"$WORK/t5357r.sh"
  PATH="$WORK/rbin:$PATH" bash "$WORK/t5357r.sh" 2>&1
}

out="$(run_resume 0.19.3 103 "$PINNED_COMMIT" 0)"
if ! grep -q <<<"$out" "RESUME_PROCEEDS"; then
  bad "TBX-5357: a stapled DMG whose .app names the pinned release was refused. Got: $out"
elif ! grep -q <<<"$out" "read back from Info.plist"; then
  bad "TBX-5357: the resume did not read the identity out of the bundle inside the DMG. Got: $out"
else
  ok "TBX-5357 resume proceeds when the DMG's .app names the pinned version and commit"
fi

out="$(run_resume 0.19.3 103 "$PINNED_COMMIT" 0 crashbox 1)"
if grep -q <<<"$out" "RESUME_PROCEEDS"; then
  bad "TBX-8693: resume ignored rejected signed association qualification"
else
  ok "TBX-8693 resume refuses when signed association qualification fails"
fi

out="$(run_resume 0.19.2 102 "$PINNED_COMMIT" 0)"
if grep -q <<<"$out" "RESUME_PROCEEDS"; then
  bad "TBX-5357: resumed onto a 0.19.2 DMG while releasing 0.19.3. Got: $out"
elif ! grep -q <<<"$out" "not the version this run started for"; then
  bad "TBX-5357: a version mismatch was refused without saying it was the version. Got: $out"
else
  ok "TBX-5357 resume refuses a DMG whose .app carries a different version"
fi

out="$(run_resume 0.19.3 103 "0000000000000000000000000000000000000000" 0)"
if grep -q <<<"$out" "RESUME_PROCEEDS"; then
  bad "TBX-5357: resumed onto a DMG built from another commit. Got: $out"
elif ! grep -q <<<"$out" "not the commit this run started for"; then
  bad "TBX-5357: a commit mismatch was refused without saying it was the commit. Got: $out"
else
  ok "TBX-5357 resume refuses a DMG whose .app was built from a different commit"
fi

out="$(run_resume 0.19.3 103 "$PINNED_COMMIT" 1)"
if grep -q <<<"$out" "RESUME_PROCEEDS"; then
  bad "TBX-5357: resumed past an unstapled image, which is the state resume exists to skip. Got: $out"
elif ! grep -q <<<"$out" "no stapled ticket"; then
  bad "TBX-5357: an unstapled DMG was refused without saying why. Got: $out"
else
  ok "TBX-5357 resume refuses a DMG with no stapled ticket"
fi

out="$(run_resume 0.19.3 103 "$PINNED_COMMIT" 0 "")"
if grep -q <<<"$out" "RESUME_PROCEEDS"; then
  bad "TBX-5304: resumed onto a reporting-disabled artifact and allowed it to publish. Got: $out"
elif ! grep -q <<<"$out" "reporting-disabled"; then
  bad "TBX-5304: a reporting-disabled resume was refused without naming the reason. Got: $out"
else
  ok "TBX-5304 resume refuses a reporting-disabled public artifact"
fi

# Wiring: the skip has to be real, and the pre-publish identity check has to be the DMG's
# on a resume. A resume that ran the gate would be pointless; one that skipped the check
# would be the reason not to have a resume at all.
if grep -q '^if ! resuming; then$' "$SUBJECT" && grep -q 'resume_assert_stapled_dmg "before publishing"' "$SUBJECT"; then
  ok "TBX-5357 wiring: the resume skips steps 0 to 4a and re-asserts identity before publishing"
else
  bad "TBX-5357 wiring: RESUME_FROM_STAPLED no longer skips the build or no longer re-checks identity"
fi

# --- TBX-5372: the dSYM outlives the release that built it ------------------------------
#
# WHY. "Matching dSYM retained locally" named $DD, the one directory every release builds
# into. 0.19.2's dSYM survived about two hours before the 0.19.3 build overwrote it, and
# the first real crash to reach Crashbox came from an installed 0.19.2 and can never be
# symbolicated. The fix is a per-release copy under dist/dsym/ with the UUID in the name,
# plus a DONE line that says out loud whether anyone uploaded it.
#
# dwarfdump is stubbed: what is under test is the copy, the naming, the mismatch refusal
# and the wording, none of which needs a real Mach-O.

RETAIN_FN="$(awk '/^retain_dsym\(\) \{$/,/^\}$/' "$SUBJECT")"
UUID_FN="$(awk '/^dsym_uuid_lines\(\) \{$/,/^\}$/' "$SUBJECT")"
STATE_FN="$(awk '/^dsym_state_line\(\) \{$/,/^\}$/' "$SUBJECT")"
RETAIN_STEP="$(awk '/^step "4b\/6 Retain the matching dSYM/,/^fi$/' "$SUBJECT")"

for name in RETAIN_FN UUID_FN STATE_FN RETAIN_STEP; do
  eval "body=\$$name"
  if [ -z "$body" ]; then
    bad "$name: anchor not found in publish.sh; the dSYM retention was restructured"
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
    exit 1
  fi
done

# A stub dwarfdump that answers from a file of UUID lines named after the path it is
# asked about, so an app and its dSYM can be made to agree or to differ on demand.
make_dwarfdump() {
  rm -rf "$WORK/dbin"; mkdir -p "$WORK/dbin"
  cat >"$WORK/dbin/dwarfdump" <<'EOF'
#!/bin/bash
# usage: dwarfdump --uuid <path>; reads <path>.uuids for its answer
target="$2"
[ -f "$target.uuids" ] || { d="$(dirname "$target")"; [ -f "$d.uuids" ] && target="$d"; }
[ -f "$target.uuids" ] || exit 1
while read -r arch uuid; do
  [ -n "$arch" ] || continue
  echo "UUID: $uuid ($arch) $target"
done < "$target.uuids"
EOF
  chmod +x "$WORK/dbin/dwarfdump"
}

# Build a fake app bundle and dSYM under a throwaway repo root, with the UUID sets given.
make_release_tree() {   # $1 = root, $2 = app UUID lines, $3 = dSYM UUID lines
  # Only the build inputs are rebuilt. dist/ is deliberately left alone, or this
  # fixture would destroy the previous release's archive itself and prove nothing.
  rm -rf "$1/app" "$1/dd"; mkdir -p "$1/dist" "$1/app/Baton.app/Contents/MacOS"
  mkdir -p "$1/dd/Build/Products/Release/Baton.app.dSYM/Contents/Resources/DWARF"
  echo "not a real mach-o" >"$1/app/Baton.app/Contents/MacOS/Baton"
  echo "not a real dwarf"  >"$1/dd/Build/Products/Release/Baton.app.dSYM/Contents/Resources/DWARF/Baton"
  printf '%s\n' "$2" >"$1/app/Baton.app/Contents/MacOS/Baton.uuids"
  printf '%s\n' "$3" >"$1/dd/Build/Products/Release/Baton.app.dSYM.uuids"
}

run_retain() {   # $1 = root, $2 = VERSION, $3 = BUILD
  { echo 'set -uo pipefail'
    echo 'step() { printf "  . %s\n" "$*"; }'
    echo 'warn() { printf "  ! %s\n" "$*"; }'
    echo "cd '$1'"
    echo 'DIST=dist; DSYM_DIR="$DIST/dsym"; RETAINED_DSYM=""'
    echo "VERSION='$2'; BUILD='$3'"
    printf '%s\n' "$UUID_FN"
    printf '%s\n' "$RETAIN_FN"
    echo 'if retain_dsym "app/Baton.app" "dd/Build/Products/Release/Baton.app.dSYM"; then'
    echo '  echo "RETAINED=$RETAINED_DSYM"'
    echo 'else'
    echo '  echo "RETAIN_REFUSED"'
    echo 'fi'; } >"$WORK/t5372.sh"
  make_dwarfdump
  PATH="$WORK/dbin:$PATH" bash "$WORK/t5372.sh" 2>&1
}

BOTH='arm64 BCC315D8-4575-3B47-99E6-2AF8CC7DB0D7
x86_64 4AE12B98-B3E2-3166-BB27-252874ECAF7D'

# The regression itself: build 103, then build 104 on top, and 103's archive is still there.
ROOT="$WORK/rel"
make_release_tree "$ROOT" "$BOTH" "$BOTH"
out="$(run_retain "$ROOT" 0.19.3 103)"
if ! grep -q <<<"$out" 'RETAINED=dist/dsym/Baton-0.19.3+103-BCC315D8-4575-3B47-99E6-2AF8CC7DB0D7.dSYM.zip'; then
  bad "TBX-5372: the retained archive is not named for this version, build and UUID. Got: $out"
elif [ ! -s "$ROOT/dist/dsym/Baton-0.19.3+103-BCC315D8-4575-3B47-99E6-2AF8CC7DB0D7.dSYM.zip" ]; then
  bad "TBX-5372: nothing was written at the retained path. Got: $out"
else
  # Same tree, next release. This is exactly what destroyed 0.19.2's symbols.
  make_release_tree "$ROOT" "arm64 11111111-2222-3333-4444-555555555555" "arm64 11111111-2222-3333-4444-555555555555"
  out2="$(run_retain "$ROOT" 0.19.4 104)"
  if [ ! -s "$ROOT/dist/dsym/Baton-0.19.3+103-BCC315D8-4575-3B47-99E6-2AF8CC7DB0D7.dSYM.zip" ]; then
    bad "TBX-5372: the next release destroyed the previous release's dSYM, which is the whole defect. Got: $out2"
  elif [ ! -s "$ROOT/dist/dsym/Baton-0.19.4+104-11111111-2222-3333-4444-555555555555.dSYM.zip" ]; then
    bad "TBX-5372: the second release retained nothing. Got: $out2"
  else
    ok "TBX-5372 a retained dSYM survives the next release, under its own version+build+UUID name"
  fi
fi

# The name has to be true. A dSYM that is not this app's must be refused, not filed.
make_release_tree "$ROOT" "$BOTH" "arm64 99999999-8888-7777-6666-555555555555"
out="$(run_retain "$ROOT" 0.19.5 105)"
if ! grep -q <<<"$out" "RETAIN_REFUSED"; then
  bad "TBX-5372: a dSYM whose UUIDs are not the app's was retained anyway. Got: $out"
elif ! grep -q <<<"$out" "not the built app"; then
  bad "TBX-5372: the refusal does not say the UUIDs disagree. Got: $out"
elif ls "$ROOT/dist/dsym/Baton-0.19.5+105-"*.dSYM.zip >/dev/null 2>&1; then
  bad "TBX-5372: a mismatched dSYM was still filed under this release's name. Got: $out"
else
  ok "TBX-5372 a dSYM that is not this build's is refused rather than filed under its name"
fi

# The DONE line. Three states, and the one that matters is the middle one.
run_state() {   # $1 = RETAINED_DSYM value, $2 = 1 to plant a receipt
  { echo 'set -uo pipefail'
    echo 'warn() { printf "  ! %s\n" "$*"; }'
    echo "cd '$ROOT'"
    echo "VERSION=0.19.3; BUILD=103; RETAINED_DSYM='$1'"
    printf '%s\n' "$STATE_FN"
    echo 'dsym_state_line'; } >"$WORK/t5372s.sh"
  mkdir -p "$ROOT/$(dirname "$1")" 2>/dev/null || true
  if [ "$2" = 1 ] && [ -n "$1" ]; then
    printf '{"artifact_id":"stub"}\n' >"$ROOT/$1.receipt.json"
  else
    rm -f "$ROOT/$1.receipt.json" 2>/dev/null || true
  fi
  bash "$WORK/t5372s.sh" 2>&1
}

REL="dist/dsym/Baton-0.19.3+103-BCC315D8-4575-3B47-99E6-2AF8CC7DB0D7.dSYM.zip"
out="$(run_state "$REL" 0)"
if ! grep -q <<<"$out" "NOT uploaded to Crashbox"; then
  bad "TBX-5372: a release that never uploaded its dSYM does not say so. Got: $out"
elif ! grep -q <<<"$out" "./scripts/upload-dsym.sh $REL baton-macos"; then
  bad "TBX-5372: the DONE line does not name the command that uploads it. Got: $out"
else
  ok "TBX-5372 a release whose dSYM was never uploaded says so and names the command"
fi

out="$(run_state "$REL" 1)"
if ! grep -q <<<"$out" "uploaded to Crashbox"; then
  bad "TBX-5372: an uploaded dSYM is not reported as uploaded. Got: $out"
elif grep -q <<<"$out" "NOT uploaded"; then
  bad "TBX-5372: a dSYM with a receipt beside it still reads as not uploaded. Got: $out"
else
  ok "TBX-5372 a dSYM with a receipt beside it is reported as uploaded"
fi

out="$(run_state "" 0)"
if ! grep -q <<<"$out" "NONE retained"; then
  bad "TBX-5372: a release that retained no dSYM at all is silent about it. Got: $out"
elif ! grep -q <<<"$out" "never be symbolicated"; then
  bad "TBX-5372: the no-dSYM case does not say what it costs. Got: $out"
else
  ok "TBX-5372 a release that retained nothing says so as loudly as a disabled provider would"
fi

# Wiring. The functions can be perfect and unreferenced, which is how the old step 4b
# managed to claim retention while doing nothing at all.
if grep -q <<<"$RETAIN_STEP" 'retain_dsym "$APP"'; then
  ok "TBX-5372 wiring: step 4b still copies the built dSYM rather than pointing at \$DD"
else
  bad "TBX-5372 wiring: step 4b no longer calls retain_dsym"
fi
if [ "$(grep -c '^  dsym_state_line$' "$SUBJECT")" -ge 2 ]; then
  ok "TBX-5372 wiring: both endings of publish.sh state the dSYM and its upload state"
else
  bad "TBX-5372 wiring: an ending of publish.sh no longer says whether the dSYM was uploaded"
fi

# F-1: a resume with no retained archive must warn and carry on. publish.sh runs under
# `set -euo pipefail`, where `ls` of an unmatched glob fails the lookup's pipeline and
# ended the script silently before the warning, on every resume detach_failed_after_staple names.
mkdir -p "$WORK/f1/dist/dsym"
{ echo 'set -euo pipefail'
  echo 'step() { printf "  . %s\n" "$*"; }'
  echo 'warn() { printf "  ! %s\n" "$*"; }'
  echo 'resuming() { [ "${RESUME_FROM_STAPLED:-0}" = 1 ]; }'
  echo 'resume_retained_dsym() { :; }'
  echo "cd '$WORK/f1'"
  echo 'DIST=dist; DSYM_DIR="$DIST/dsym"; VERSION=0.19.3; BUILD=103'
  printf '%s\n' "$RETAIN_STEP"
  echo 'echo "CONTINUED"'; } >"$WORK/tf1.sh"
out="$(RESUME_FROM_STAPLED=1 bash "$WORK/tf1.sh" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] || ! grep -q <<<"$out" 'CONTINUED'; then
  bad "F-1: a resume with no retained dSYM ended the script (rc=$rc) instead of warning. Got: $out"
elif ! grep -q <<<"$out" 'no retained dSYM for 0.19.3 build 103'; then
  bad "F-1: a resume with no retained dSYM continued without the warning. Got: $out"
else
  ok "F-1 a resume with no retained dSYM warns and continues under set -euo pipefail"
fi

# F-24: the appcast's EdDSA signature is read out of sign_update's output. A sed that
# passes a non-matching line through unchanged made any output a "signature", and the
# non-empty check before publishing accepted it. sign_update is stubbed to print a fixed line.
SIG_BLOCK="$(awk '/^ED_SIG=""$/,/^fi$/' "$SUBJECT")"
run_sig() {   # $1 = the line the stub sign_update prints
  rm -rf "$WORK/f24"; mkdir -p "$WORK/f24/bin"
  { echo '#!/bin/bash'; printf 'printf "%%s\\n" %q\n' "$1"; } >"$WORK/f24/bin/sign_update"
  chmod +x "$WORK/f24/bin/sign_update"
  { echo 'set -euo pipefail'
    echo 'warn() { printf "  ! %s\n" "$*"; }'
    echo "SPARKLE_BIN='$WORK/f24/bin'; DIST='$WORK/f24'; DMG_NAME=Baton-0.19.3.dmg"
    printf '%s\n' "$SIG_BLOCK"
    echo 'echo "ED_SIG=$ED_SIG"'; } >"$WORK/tf24.sh"
  bash "$WORK/tf24.sh" 2>&1
}
GOOD_SIG="$(printf '%086d' 0 | tr 0 A)=="
out="$(run_sig "Signing update failed: no key in keychain")"; rc=$?
if [ "$rc" -eq 0 ]; then
  bad "F-24: sign_update output with no edSignature was accepted as a signature. Got: $out"
else
  ok "F-24 sign_update output with no sparkle:edSignature is refused"
fi
out="$(run_sig 'sparkle:edSignature="notbase64" length="12"')"; rc=$?
if [ "$rc" -eq 0 ]; then
  bad "F-24: an edSignature that is not 64 bytes of base64 was accepted. Got: $out"
else
  ok "F-24 an edSignature that is not 64 bytes of base64 is refused"
fi
out="$(run_sig "sparkle:edSignature=\"$GOOD_SIG\" length=\"12\"")"; rc=$?
if [ "$rc" -ne 0 ] || ! grep -qxF <<<"$out" "ED_SIG=$GOOD_SIG"; then
  bad "F-24: a well-formed edSignature line was not accepted as exactly the signature (rc=$rc). Got: $out"
else
  ok "F-24 a well-formed edSignature line yields exactly the 88-character signature"
fi
UPLOAD_FN="$(awk '/^crashbox_upload_dsym\(\) \{$/,/^\}$/' "$SUBJECT")"
UPLOAD_BLOCK="$(awk '/^  # TBX-5483:/,/^  # End TBX-5483\.$/' "$SUBJECT")"
if [ -z "$UPLOAD_FN" ] || [ -z "$UPLOAD_BLOCK" ]; then
  bad "TBX-5483: the configured artifact-upload anchors are missing"
elif ! grep -qF <<<"$UPLOAD_FN" 'io.tonebox.baton@${VERSION}+${BUILD}.${MACREL_COMMIT}'; then
  bad "TBX-5483: the upload no longer uses the SDK's exact source-qualified release"
else
  ok "TBX-5483 upload derives the exact source-qualified SDK release"
fi

retain_line="$(grep -n 'retain_dsym \"\$APP\"' "$SUBJECT" | awk -F: 'NR == 1 { print $1 }')"
upload_line="$(grep -n '^    crashbox_upload_dsym || {' "$SUBJECT" | awk -F: 'NR == 1 { print $1 }')"
publish_line="$(grep -n '^  step \"6/6 Publish' "$SUBJECT" | awk -F: 'NR == 1 { print $1 }')"
if [ -n "$retain_line" ] && [ -n "$upload_line" ] && [ -n "$publish_line" ] \
   && [ "$retain_line" -lt "$upload_line" ] && [ "$upload_line" -lt "$publish_line" ]; then
  ok "TBX-5483 wiring is after dSYM retention and before remote publication"
else
  bad "TBX-5483: configured upload moved outside the retained/pre-publication window"
fi

{ echo 'set -uo pipefail'
  echo 'step() { :; }; warn() { :; }'
  echo 'CRASHBOX_ARTIFACT_CREDENTIAL=configured'
  echo 'crashbox_upload_dsym() { return 1; }'
  printf '%s\n' "$UPLOAD_BLOCK"
  echo 'echo PUBLICATION_REACHED'; } >"$WORK/t5483.sh"
out="$(bash "$WORK/t5483.sh" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] || grep -qF <<<"$out" PUBLICATION_REACHED; then
  bad "TBX-5483: a configured upload failure did not stop publication"
elif ! grep -qF <<<"$out" 'nothing was published or tagged'; then
  bad "TBX-5483: configured upload refusal does not state the publication boundary"
else
  ok "TBX-5483 a configured upload failure exits before publication or tag"
fi

{ echo 'set -uo pipefail'
  echo 'step() { :; }; warn() { printf "%s\n" "$*"; }'
  echo 'CRASHBOX_ARTIFACT_CREDENTIAL='
  echo 'crashbox_upload_dsym() { return 99; }'
  printf '%s\n' "$UPLOAD_BLOCK"
  echo 'echo PUBLICATION_REACHED'; } >"$WORK/t5483-off.sh"
out="$(bash "$WORK/t5483-off.sh" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] || ! grep -qF <<<"$out" PUBLICATION_REACHED; then
  bad "TBX-5483: an intentionally unconfigured release cannot retain the manual flow"
elif ! grep -qF <<<"$out" 'not configured'; then
  bad "TBX-5483: the unconfigured path does not say automatic upload is off"
else
  ok "TBX-5483 unconfigured releases preserve the explicit manual-upload flow"
fi

# --- TBX-10955: no app ships without MLX's shaders ---------------------------------------
# Two layers refuse it (TBX-10926): the Release build's own "Bundle MLX shaders" step in
# app/project.yml, and publish.sh reading the built app afterwards. Both run here, the real
# text by anchor, against planted folders.

MLX_REL="Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
SHADERS_FN="$(awk '/^assert_mlx_shaders\(\) \{$/,/^\}$/' "$SUBJECT")"
if [ -z "$SHADERS_FN" ]; then
  bad "TBX-10955: assert_mlx_shaders() not found in publish.sh"
else
  mkdir -p "$WORK/shaders/Stripped.app/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources" \
           "$WORK/shaders/Empty.app/$(dirname "$MLX_REL")" "$WORK/shaders/Whole.app/$(dirname "$MLX_REL")"
  : >"$WORK/shaders/Empty.app/$MLX_REL"
  printf 'metallib' >"$WORK/shaders/Whole.app/$MLX_REL"
  { echo 'set -uo pipefail'; printf '%s\n' "$SHADERS_FN"
    echo 'assert_mlx_shaders "$1" || exit 1'; echo 'echo SHADERS_PASSED'; } >"$WORK/t10955.sh"
  for app in Stripped Empty; do
    out="$(bash "$WORK/t10955.sh" "$WORK/shaders/$app.app" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] || grep -qF <<<"$out" SHADERS_PASSED; then
      bad "TBX-10955: publish.sh admitted an app with no MLX shaders ($app)"
    elif ! grep -qF <<<"$out" 'has no MLX shaders'; then
      bad "TBX-10955: the $app refusal does not say what is missing. Got: $out"
    else
      ok "TBX-10955 publish.sh refuses a built app without MLX shaders ($app)"
    fi
  done
  out="$(bash "$WORK/t10955.sh" "$WORK/shaders/Whole.app" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] || ! grep -qF <<<"$out" SHADERS_PASSED; then
    bad "TBX-10955: publish.sh refused an app that has its MLX shaders. Got: $out"
  else
    ok "TBX-10955 publish.sh passes a built app with its MLX shaders"
  fi
fi

# The build step: the YAML block scalar under "- name: Bundle MLX shaders", de-indented.
# $PWD, not $ROOT: the dSYM cases above point ROOT at a planted release tree.
BUNDLE_STEP="$(awk '
  /^      - name: Bundle MLX shaders$/ { found = 1; next }
  found && !inscript && /^        script: [|]$/ { inscript = 1; next }
  inscript { if ($0 != "" && substr($0, 1, 10) != "          ") exit; print substr($0, 11) }
' "$PWD/app/project.yml")"
if ! grep -qF <<<"$BUNDLE_STEP" 'CONFIGURATION'; then
  bad "TBX-10955: the Bundle MLX shaders step was not found in app/project.yml"
else
  printf '%s\n' "$BUNDLE_STEP" >"$WORK/bundle-step.sh"
  run_bundle_step() { # configuration, built-products dir
    env -i PATH="$PATH" CONFIGURATION="$1" TARGET_BUILD_DIR="$2" \
      UNLOCALIZED_RESOURCES_FOLDER_PATH="Baton.app/Contents/Resources" \
      SRCROOT="$WORK/shaders/no-src/app" MLX_METALLIB="$WORK/shaders/no-such.metallib" \
      bash "$WORK/bundle-step.sh" 2>&1
  }
  mkdir -p "$WORK/shaders/built-release" "$WORK/shaders/built-debug"
  out="$(run_bundle_step Release "$WORK/shaders/built-release")"; rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "TBX-10955: a Release build with no MLX shaders was not refused"
  elif ! grep -qF <<<"$out" 'error: no MLX shaders'; then
    bad "TBX-10955: the Release refusal does not name the missing shaders. Got: $out"
  else
    ok "TBX-10955 a Release build with no MLX shaders fails its build step"
  fi
  out="$(run_bundle_step Debug "$WORK/shaders/built-debug")"; rc=$?
  if [ "$rc" -ne 0 ] || ! grep -qF <<<"$out" 'warning: no MLX shaders'; then
    bad "TBX-10955: a Debug build with no MLX shaders should warn and continue. rc=$rc: $out"
  else
    ok "TBX-10955 a Debug build with no MLX shaders warns and continues"
  fi
  # Xcode compiled them (Metal Toolchain): left as built, even in Release with no fallback.
  mkdir -p "$WORK/shaders/built-release/Baton.app/$(dirname "$MLX_REL")"
  printf 'metallib' >"$WORK/shaders/built-release/Baton.app/$MLX_REL"
  out="$(run_bundle_step Release "$WORK/shaders/built-release")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "TBX-10955: a Release build with compiled MLX shaders was refused. Got: $out"
  else
    ok "TBX-10955 a Release build with compiled MLX shaders passes its build step"
  fi
fi

# E-4: publish-site.sh uploads the CSS and JS before the HTML that names them
# (~/Projects/_method/web-cache-policy.md, "Upload assets first, then the HTML"). One rsync
# of the whole list sent index.html before styles.css, so a visitor in between got a page
# whose stamped asset URLs did not exist yet. The real block runs with ssh and rsync as
# recording functions, from this tree so every listed site file exists. ($ROOT now names a
# fixture tree from the dSYM cases above; $PWD is still this checkout.)
SITE_TREE="$PWD"
SITE_SUBJECT="$SITE_TREE/scripts/publish-site.sh"
SITE_RSYNC="$(grep -E '^RSYNC=\(|^\[ -n "\$\{DRY_RUN:-\}" \] && RSYNC\+=' "$SITE_SUBJECT")"
SITE_BLOCK="$(awk '/^SITE_FILES=\($/,/^"\$\{RSYNC\[@\]\}" website\/\.well-known\//' "$SITE_SUBJECT")"
if [ "$(printf '%s\n' "$SITE_RSYNC" | wc -l | tr -d ' ')" != 2 ] || [ -z "$SITE_BLOCK" ]; then
  bad "E-4: publish-site.sh's RSYNC or static-sync anchors were not found; the upload was restructured"
else
  run_site_sync() {   # [DRY_RUN value]; one line per rsync call, its arguments tab-separated
    { echo 'set -euo pipefail'
      echo 'bold() { :; }; step() { :; }; fail() { echo "FAIL: $*" >&2; exit 1; }'
      echo 'ssh() { :; }'
      echo "rsync() { local IFS=\$'\\t'; printf '%s\\n' \"\$*\" >>'$WORK/e4-calls'; }"
      echo "cd '$SITE_TREE'; WEB01=stub-host; REMOTE_DIR=/srv/site; HOSTNAME_FQDN=stub.example; DRY_RUN='${1:-}'"
      echo '[ -n "$DRY_RUN" ] || unset DRY_RUN'
      printf '%s\n' "$SITE_RSYNC"
      printf '%s\n' "$SITE_BLOCK"; } >"$WORK/te4.sh"
    : >"$WORK/e4-calls"
    bash "$WORK/te4.sh" 2>&1 || return 1
    cat "$WORK/e4-calls"
  }
  # The verdict: the first call naming any .html must come after every call naming .css/.js,
  # exactly the listed site files are sent, once each, and each site call keeps the RSYNC flags.
  check_site_order() {   # stdin: the calls; $1 = flags each site call starts with; $2 = SITE_FILES
    python3 -c '
import sys
flags = sys.argv[1].split("\t")
calls = [l.rstrip("\n").split("\t") for l in sys.stdin if l.strip()]
site = [c for c in calls if c[-1].endswith("/site/") and not any(".well-known" in a for a in c)]
if not site: sys.exit("no static-site rsync call recorded")
for c in site:
    if c[:len(flags)] != flags: sys.exit("a site call lost the RSYNC flags: %r" % c)
files = [a for c in site for a in c[len(flags):-1]]
if sorted(files) != sorted(sys.argv[2].split()): sys.exit("sent %r, not exactly SITE_FILES" % files)
first_html = next((i for i, c in enumerate(site) if any(a.endswith(".html") for a in c)), None)
if first_html is None: sys.exit("no HTML was uploaded")
late = [a for c in site[first_html:] for a in c if a.endswith((".css", ".js"))]
if late: sys.exit("CSS/JS uploaded with or after the HTML: %r" % late)
print("ok %d files in %d calls" % (len(files), len(site)))
' "$1" "$2"
  }
  listed="$(printf '%s\n' "$SITE_BLOCK" | awk '/^SITE_FILES=\($/{f=1;next} f&&/^\)$/{exit} f{gsub(/^ +/,"");print}')"
  calls="$(run_site_sync)"; rc=$?
  verdict="$(printf '%s\n' "$calls" | check_site_order "$(printf -- '-az\t--delete\t--human-readable\t--chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r')" "$listed" 2>&1)"
  if [ "$rc" -ne 0 ] || [ "${verdict#ok}" = "$verdict" ]; then
    bad "E-4: the site upload does not send assets before the HTML (rc=$rc): $verdict"
  else
    ok "E-4 publish-site.sh uploads every CSS/JS asset before the HTML that names it ($verdict)"
  fi
  calls="$(run_site_sync 1)"; rc=$?
  verdict="$(printf '%s\n' "$calls" | check_site_order "$(printf -- '-az\t--delete\t--human-readable\t--chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r\t--dry-run\t--itemize-changes')" "$listed" 2>&1)"
  if [ "$rc" -ne 0 ] || [ "${verdict#ok}" = "$verdict" ]; then
    bad "E-4: under DRY_RUN=1 a site call is not a dry run, or the order is wrong (rc=$rc): $verdict"
  else
    ok "E-4 under DRY_RUN=1 every site call stays a dry run, in the same order"
  fi
fi

# --- TBX-1000000502 / 503: re-publish and upload guards in publish.sh ---------------------
fn() { FN="$1() {" awk '$0 == ENVIRON["FN"] { on = 1 } on { print } on && /^\}$/ { exit }' "$SUBJECT"; }
TAG_GUARD_FN="$(fn release_version_tag_guard)"
DMG_GUARD_FN="$(fn remote_dmg_guard)"
APPCAST_FN="$(fn served_appcast_check)"
RESUME_DSYM_FN="$(fn resume_retained_dsym)"
CLEANUP_FN="$(fn publish_cleanup)"
DIRTY_BLOCK="$(XS='^# A published release must be reproducible from a tagged commit' XE='^fi$' awk '!on && $0 ~ ENVIRON["XS"] { on = 1; print; next } on { print; if ($0 ~ ENVIRON["XE"]) exit }' "$SUBJECT")"
REMOTE_DIR_BLOCK="$(XS='^  REMOTE_DIR="[$][{]REMOTE_DIR:-' XE='^  SITE_DIR=' awk '!on && $0 ~ ENVIRON["XS"] { on = 1; print; next } on { print; if ($0 ~ ENVIRON["XE"]) exit }' "$SUBJECT")"
for name in TAG_GUARD_FN DMG_GUARD_FN APPCAST_FN RESUME_DSYM_FN CLEANUP_FN DIRTY_BLOCK REMOTE_DIR_BLOCK; do
  eval "body=\$$name"
  [ -n "$body" ] || bad "$name: anchor not found in publish.sh"
done

# F-3: a re-run after steps 4c/4d rewrote the cask and the landing page is not refused, while
# a dirty build input still is. The real block over a planted repo, with the real classifier.
F3="$WORK/f3"; rm -rf "$F3"; mkdir -p "$F3/Casks" "$F3/website" "$F3/app"
git -C "$F3" init -q -b main
git -C "$F3" config user.email t@example.invalid; git -C "$F3" config user.name t
echo cask >"$F3/Casks/baton.rb"; echo page >"$F3/website/index.html"; echo src >"$F3/app/Main.swift"
git -C "$F3" add -A; git -C "$F3" commit -qm base
run_f3() {
  { echo 'set -euo pipefail'
    echo ". '$ROOT_REAL/scripts/release-identity.sh'"
    echo "cd '$F3'; MACREL_REPO='$F3'; MACREL_COMMIT=\$(git rev-parse HEAD); PUBLISH=1"
    printf '%s\n' "$DIRTY_BLOCK"
    echo 'echo F3_ADMITTED'; } >"$WORK/tf3.sh"
  bash "$WORK/tf3.sh" 2>&1
}
ROOT_REAL="$SITE_TREE"
echo "cask v2" >"$F3/Casks/baton.rb"; echo "page v2" >"$F3/website/index.html"
out="$(run_f3)"
if grep -q <<<"$out" F3_ADMITTED; then
  ok "F-3 a re-run with only the cask and landing-page rewrites dirty is admitted"
else
  bad "F-3: the 4c/4d rewrites alone refused a re-run. Got: $out"
fi
echo "edited" >"$F3/app/Main.swift"
out="$(run_f3)"
if grep -q <<<"$out" F3_ADMITTED; then
  bad "F-3: a dirty build input was admitted. Got: $out"
elif ! grep -q <<<"$out" 'app/Main.swift'; then
  bad "F-3: the refusal did not name the dirty build input. Got: $out"
else
  ok "F-3 a dirty build input is still refused, by name"
fi

# F-4: a version already tagged on another commit is a re-publish and must be asked for.
F4="$WORK/f4"; rm -rf "$F4" "$WORK/f4-origin.git"; git init -q --bare "$WORK/f4-origin.git"
git init -q -b main "$F4"; git -C "$F4" config user.email t@example.invalid; git -C "$F4" config user.name t
git -C "$F4" remote add origin "$WORK/f4-origin.git"
echo 1 >"$F4/f"; git -C "$F4" add f; git -C "$F4" commit -qm one; A="$(git -C "$F4" rev-parse HEAD)"
git -C "$F4" tag -a v1.0.0 -m v1.0.0; git -C "$F4" push -q origin main refs/tags/v1.0.0
echo 2 >"$F4/f"; git -C "$F4" commit -qam two; B="$(git -C "$F4" rev-parse HEAD)"
run_f4() {   # $1 = commit being published; extra env through the caller
  { echo 'set -uo pipefail'; echo 'warn() { printf "  ! %s\n" "$*"; }'
    echo "cd '$F4'"; printf '%s\n' "$TAG_GUARD_FN"
    echo "release_version_tag_guard 1.0.0 '$1' origin && echo F4_ADMITTED"; } >"$WORK/tf4.sh"
  bash "$WORK/tf4.sh" 2>&1
}
out="$(run_f4 "$A")"
grep -q <<<"$out" F4_ADMITTED && ok "F-4 re-running the tagged commit itself is admitted" \
  || bad "F-4: publishing the commit v1.0.0 names was refused. Got: $out"
out="$(run_f4 "$B")"
if grep -q <<<"$out" F4_ADMITTED; then
  bad "F-4: a re-publish of 1.0.0 from another commit was admitted unasked. Got: $out"
elif ! grep -q <<<"$out" 'already published from'; then
  bad "F-4: the refusal does not say the version was already published. Got: $out"
else
  ok "F-4 a re-publish of a tagged version from another commit is refused"
fi
out="$(BATON_REPUBLISH="test re-publish" run_f4 "$B")"
if grep -q <<<"$out" F4_ADMITTED && grep -q <<<"$out" 'BATON_REPUBLISH: re-publishing 1.0.0'; then
  ok "F-4 BATON_REPUBLISH admits the re-publish and says so"
else
  bad "F-4: BATON_REPUBLISH did not admit the re-publish with a warning. Got: $out"
fi
git -C "$F4" tag -d v1.0.0 >/dev/null
out="$(run_f4 "$B")"
if grep -q <<<"$out" F4_ADMITTED; then
  bad "F-4: a tag only the remote holds, on another commit, went unnoticed. Got: $out"
else
  ok "F-4 the remote's tag counts when the local one is missing"
fi
# F-4 review: a remote that cannot be read is not a remote without the tag.
git -C "$F4" remote set-url origin "$WORK/no-such-origin.git"
out="$(run_f4 "$B")"
if grep -q <<<"$out" F4_ADMITTED; then
  bad "F-4: an unreadable origin was read as having no v1.0.0 tag. Got: $out"
else
  ok "F-4 an origin that cannot be read refuses rather than reads as untagged"
fi
git -C "$F4" remote set-url origin "$WORK/f4-origin.git"
# F-4 review: BATON_REPUBLISH when only origin's tag is on another commit. rk_tag_release moves
# a tag only when the LOCAL one moves, so the guard brings origin's tag here first; the real
# kit function then force-moves it on origin to the commit being published.
{ echo 'set -uo pipefail'; echo 'warn() { printf "  ! %s\n" "$*"; }'
  echo "cd '$F4'"; printf '%s\n' "$TAG_GUARD_FN"
  echo ". '$SITE_TREE/scripts/release-kit/lib/tags.sh'"
  echo "release_version_tag_guard 1.0.0 '$B' origin || exit 1"
  echo "RK_RETAG=1 rk_tag_release 1.0.0 '$B' 'Baton 1.0.0 again' origin '$F4'"; } >"$WORK/tf4r.sh"
out="$(BATON_REPUBLISH="test re-publish" bash "$WORK/tf4r.sh" 2>&1)"; rc=$?
now="$(git -C "$F4" ls-remote origin 'refs/tags/v1.0.0^{}' | cut -f1)"
if [ "$rc" -ne 0 ] || [ "$now" != "$B" ]; then
  bad "F-4: BATON_REPUBLISH left origin's v1.0.0 on ${now:0:12}, not the published ${B:0:12} (rc=$rc): $out"
else
  ok "F-4 BATON_REPUBLISH force-moves origin's tag to the published commit"
fi
if grep -qF 'release_version_tag_guard "$VERSION" "$MACREL_COMMIT" origin || exit 1' "$SUBJECT" \
   && grep -qF 'RK_RETAG="${BATON_REPUBLISH:+1}" rk_tag_release' "$SUBJECT" && ! grep -q '^  RK_RETAG=1 ' "$SUBJECT"; then
  ok "F-4 wiring: the guard runs before the gate and only BATON_REPUBLISH moves a tag"
else
  bad "F-4 wiring: the guard is not called, or the tag is still moved unconditionally"
fi

# E-6: the same DMG name must not take different bytes. ssh answers with the remote hash.
run_e6() {   # $1 = what the remote reports (absent, a hash, or FAIL)
  { echo 'set -uo pipefail'; echo 'step() { printf "  . %s\n" "$*"; }; warn() { printf "  ! %s\n" "$*"; }'
    echo "ssh() { case '$1' in FAIL) return 255 ;; *) echo '$1' ;; esac; }"
    echo "WEB01=stub-host; SITE_DIR=/srv/site; DMG_REPLACED=0"
    printf '%s\n' "$DMG_GUARD_FN"
    echo "remote_dmg_guard Baton-1.0.0.dmg $(printf 'a%.0s' $(seq 64)) && echo E6_ADMITTED DMG_REPLACED=\$DMG_REPLACED"; } >"$WORK/te6.sh"
  bash "$WORK/te6.sh" 2>&1
}
SAME="$(printf 'a%.0s' $(seq 64))"; OTHER="$(printf 'b%.0s' $(seq 64))"
out="$(run_e6 absent)"; grep -q <<<"$out" 'E6_ADMITTED DMG_REPLACED=0' && ok "E-6 a DMG name not yet on the host is admitted" || bad "E-6: a new DMG name was refused. Got: $out"
out="$(run_e6 "$SAME")"; grep -q <<<"$out" 'E6_ADMITTED DMG_REPLACED=0' && ok "E-6 the same bytes under the same name (a resume) are admitted" || bad "E-6: identical bytes were refused. Got: $out"
out="$(run_e6 "$OTHER")"
if grep -q <<<"$out" E6_ADMITTED; then
  bad "E-6: different bytes under a live DMG name were admitted. Got: $out"
elif ! grep -q <<<"$out" 'immutable' || ! grep -q <<<"$out" 'baton.tonebox.io/Baton-1.0.0.dmg'; then
  bad "E-6: the refusal does not explain the cache or name the URLs to purge. Got: $out"
else
  ok "E-6 different bytes under a live DMG name are refused, naming both URLs to purge"
fi
out="$(BATON_REPLACE_DMG="rebuild after a bad sign" run_e6 "$OTHER")"
grep -q <<<"$out" 'E6_ADMITTED DMG_REPLACED=1' && ok "E-6 BATON_REPLACE_DMG admits the replacement and records it" || bad "E-6: BATON_REPLACE_DMG did not admit and record the replacement. Got: $out"
out="$(run_e6 FAIL)"; grep -q <<<"$out" E6_ADMITTED && bad "E-6: an unreadable remote was treated as absent. Got: $out" || ok "E-6 an unreadable remote refuses rather than assumes"
guard_line="$(grep -n '^  remote_dmg_guard "$DMG_NAME" "$SHA" || exit 1$' "$SUBJECT" | cut -d: -f1)"
scp_line="$(grep -n '^  scp "$DIST/$DMG_NAME"' "$SUBJECT" | cut -d: -f1)"
if [ -n "$guard_line" ] && [ -n "$scp_line" ] && [ "$guard_line" -lt "$scp_line" ]; then
  ok "E-6 wiring: the hash comparison runs before the first upload"
else
  bad "E-6 wiring: remote_dmg_guard is missing or after the DMG upload"
fi

# F-21: after the upload, each host serves exactly the appcast just written.
printf '<rss>new</rss>\n' >"$WORK/appcast-new.xml"; printf '<rss>old</rss>\n' >"$WORK/appcast-old.xml"
run_f21() {   # $1 = file batonmusic.app serves, $2 = file baton.tonebox.io serves ("" = fetch fails)
  { echo 'set -uo pipefail'; echo 'step() { printf "  . %s\n" "$*"; }; sleep() { :; }'
    echo "curl() { local out='' url=''; while [ \$# -gt 0 ]; do case \"\$1\" in -o) out=\"\$2\"; shift ;; https://*) url=\"\$1\" ;; esac; shift; done
      case \"\$url\" in *batonmusic.app*) src='$1' ;; *) src='$2' ;; esac
      [ -n \"\$src\" ] || return 22; cp \"\$src\" \"\$out\"; }"
    grep '^APPCAST_SERVED_HOSTS=' "$SUBJECT"
    printf '%s\n' "$APPCAST_FN"
    echo "served_appcast_check '$WORK/appcast-new.xml' && echo F21_OK"; } >"$WORK/tf21.sh"
  bash "$WORK/tf21.sh" 2>&1
}
out="$(run_f21 "$WORK/appcast-new.xml" "$WORK/appcast-new.xml")"
grep -q <<<"$out" F21_OK && ok "F-21 both hosts serving the uploaded appcast passes" || bad "F-21: matching appcasts failed. Got: $out"
out="$(run_f21 "$WORK/appcast-new.xml" "$WORK/appcast-old.xml")"
if grep -q <<<"$out" F21_OK || ! grep -q <<<"$out" 'baton.tonebox.io/appcast.xml is a different document'; then
  bad "F-21: the legacy host serving the previous appcast was not caught by name. Got: $out"
else
  ok "F-21 the legacy host still serving the previous appcast fails, named"
fi
out="$(run_f21 "" "$WORK/appcast-new.xml")"
if grep -q <<<"$out" F21_OK || ! grep -q <<<"$out" 'batonmusic.app/appcast.xml is not fetchable'; then
  bad "F-21: an unfetchable appcast host passed. Got: $out"
else
  ok "F-21 an appcast host that cannot be fetched fails, named"
fi
check_line="$(grep -n '^  served_appcast_check "$DIST/appcast.xml" || {' "$SUBJECT" | cut -d: -f1)"
tag_line="$(grep -n 'rk_tag_release "$VERSION" "$MACREL_COMMIT"' "$SUBJECT" | cut -d: -f1)"
upload_line="$(grep -n "^  ssh \"\$WEB01\" \"mv -f '\$SITE_DIR/.appcast.xml.tmp'" "$SUBJECT" | cut -d: -f1)"
if [ -n "$check_line" ] && [ -n "$tag_line" ] && [ -n "$upload_line" ] && [ "$upload_line" -lt "$check_line" ] && [ "$check_line" -lt "$tag_line" ]; then
  ok "F-21 wiring: the served appcasts are checked after the upload and before the tag"
else
  bad "F-21 wiring: served_appcast_check is missing or outside the upload-to-tag window"
fi

# F-2: a resume selects the retained dSYM named for the UUID of the app inside the DMG.
F2="$WORK/f2"; rm -rf "$F2"; mkdir -p "$F2/dist/dsym" "$F2/fixture/Baton.app/Contents/MacOS"
echo bin >"$F2/fixture/Baton.app/Contents/MacOS/Baton"
printf 'arm64 BBBBBBBB-0000-0000-0000-000000000002\nx86_64 CCCCCCCC-0000-0000-0000-000000000003\n' >"$F2/fixture/Baton.app/Contents/MacOS/Baton.uuids"
echo dmg >"$F2/dist/Baton-0.19.3.dmg"
: >"$F2/dist/dsym/Baton-0.19.3+103-AAAAAAAA-0000-0000-0000-000000000001.dSYM.zip"   # a discarded rebuild's, first by name
make_dwarfdump
rm -rf "$WORK/f2bin"; mkdir -p "$WORK/f2bin"
cat >"$WORK/f2bin/hdiutil" <<EOF
#!/bin/bash
if [ "\$1" = attach ]; then
  mp=""; while [ \$# -gt 0 ]; do [ "\$1" = -mountpoint ] && mp="\$2"; shift; done
  cp -R "$F2/fixture/." "\$mp/"; exit 0
fi
[ "\$1" = detach ] && { rm -rf "\$2"/Baton.app; exit 0; }
exit 0
EOF
chmod +x "$WORK/f2bin/hdiutil"
run_f2() {
  { echo 'set -euo pipefail'; echo 'warn() { printf "  ! %s\n" "$*"; }'
    echo "cd '$F2'; DIST=dist; DSYM_DIR=dist/dsym; DMG_NAME=Baton-0.19.3.dmg; VERSION=0.19.3; BUILD=103"
    printf '%s\n' "$UUID_FN" "$DETACH_FN" "$RESUME_DSYM_FN"
    echo 'echo "SELECTED=$(resume_retained_dsym)"'; } >"$WORK/tf2.sh"
  PATH="$WORK/f2bin:$WORK/dbin:$PATH" bash "$WORK/tf2.sh" 2>&1
}
out="$(run_f2)"
if grep -q <<<"$out" '^SELECTED=$' && grep -q <<<"$out" 'none is this DMG'; then
  ok "F-2 a resume does not take another build's archive when the shipped app's is missing"
else
  bad "F-2: a resume selected an archive whose UUID is not the shipped app's. Got: $out"
fi
: >"$F2/dist/dsym/Baton-0.19.3+103-BBBBBBBB-0000-0000-0000-000000000002.dSYM.zip"
out="$(run_f2)"
if grep -qx <<<"$out" 'SELECTED=dist/dsym/Baton-0.19.3+103-BBBBBBBB-0000-0000-0000-000000000002.dSYM.zip'; then
  ok "F-2 a resume selects the archive named for the arm64 UUID of the app inside the DMG"
else
  bad "F-2: the resume did not select the shipped app's archive. Got: $out"
fi
grep -q <<<"$RETAIN_STEP" 'RETAINED_DSYM="$(resume_retained_dsym)"' \
  && ok "F-2 wiring: step 4b's resume path uses the UUID lookup" \
  || bad "F-2 wiring: step 4b's resume path no longer uses resume_retained_dsym"

# F-23: the cleanup removes the DSN xcconfig and the DMG staging copy on any exit.
run_f23() {
  mkdir -p "$WORK/f23"; : >"$WORK/f23/xcconfig"; mkdir -p "$WORK/f23/stage/Baton.app"
  { echo 'set -uo pipefail'; echo 'gate_lock_release() { :; }; native_lock_release_all() { :; }'
    echo 'TMP_DL=""; MAC_ASSOCIATION_WORK=""; PUBLISH_COMPLETE=0'
    echo "REPORTING_XCCONFIG='$WORK/f23/xcconfig'; STAGE='$WORK/f23/stage'"
    printf '%s\n' "$CLEANUP_FN"
    echo 'trap publish_cleanup EXIT'; echo 'exit 1'; } >"$WORK/tf23.sh"
  bash "$WORK/tf23.sh" >/dev/null 2>&1
}
run_f23
if [ -e "$WORK/f23/xcconfig" ] || [ -e "$WORK/f23/stage" ]; then
  bad "F-23: a failed run left the Crashbox xcconfig or the staging copy behind"
else
  ok "F-23 a failed run removes the Crashbox xcconfig and the DMG staging copy"
fi

# F-20: REMOTE_DIR means the deploy directory in both scripts; the docroot meaning is refused.
run_f20() {
  { echo 'set -uo pipefail'; printf '%s\n' "$REMOTE_DIR_BLOCK"; echo 'echo "SITE_DIR=$SITE_DIR"'; } >"$WORK/tf20.sh"
  bash "$WORK/tf20.sh" 2>&1
}
out="$(unset REMOTE_DIR; run_f20)"
site_default="$(sed -nE 's/^REMOTE_DIR="\$\{REMOTE_DIR:-([^}]+)\}"$/\1/p' "$SITE_SUBJECT")"
if grep -qx <<<"$out" "SITE_DIR=$site_default/site"; then
  ok "F-20 publish.sh's default REMOTE_DIR is publish-site.sh's, and the DMG goes to its site/"
else
  bad "F-20: the two scripts' REMOTE_DIR defaults disagree. publish-site: $site_default; publish.sh: $out"
fi
out="$(REMOTE_DIR=/opt/docker/baton-web/site run_f20)"
if grep -q <<<"$out" '^SITE_DIR='; then
  bad "F-20: the old docroot meaning of REMOTE_DIR was accepted. Got: $out"
else
  ok "F-20 REMOTE_DIR naming the docroot (the old meaning) is refused with the right value"
fi
if grep -nE "(scp|ssh).*\\\$REMOTE_DIR/" "$SUBJECT" >/dev/null; then
  bad "F-20 wiring: an upload still writes under \$REMOTE_DIR directly"
else
  ok "F-20 wiring: every upload writes under \$SITE_DIR"
fi

# --- F-16: the manual dSYM upload's host commands (TBX-1000000503) --------------------------
# The real scripts/upload-dsym.sh with ssh, scp and dwarfdump as logging stubs. Every command
# that touches the Crashbox host must go through systemd-run as crashbox (never plain sudo),
# the archive must land in a fresh private directory rather than a predictable /tmp name,
# and leftover bytecode must stop the run BEFORE any Crashbox command executes.
DSYM_SUBJECT="${BATON_UPLOAD_DSYM_SUBJECT:-$SITE_TREE/scripts/upload-dsym.sh}"
F16="$WORK/f16"; rm -rf "$F16"; mkdir -p "$F16/bin" "$F16/a/Baton.app.dSYM/Contents/Resources/DWARF"
echo dwarf >"$F16/a/Baton.app.dSYM/Contents/Resources/DWARF/Baton"
( cd "$F16/a" && zip -q -r "$F16/Baton-0.19.3+103-X.dSYM.zip" Baton.app.dSYM )
cat >"$F16/bin/dwarfdump" <<'EOF'
#!/bin/bash
echo "UUID: BBBBBBBB-0000-0000-0000-000000000002 (arm64) $2"
EOF
cat >"$F16/bin/scp" <<EOF
#!/bin/bash
echo "scp \$*" >>"$F16/log"
EOF
cat >"$F16/bin/ssh" <<EOF
#!/bin/bash
cmd="\${*: -1}"; echo "ssh \$cmd" >>"$F16/log"
case "\$cmd" in
  *mktemp*) echo /tmp/baton-dsym.Q1w2E3 ;;
  *inspect-fingerprint*) echo '{"project_id":"0f0e0d0c-0b0a-4998-8776-655443322110"}' ;;
  *"-name '*.pyc'"*) if [ -n "\${STUB_PYC_FAIL_AFTER_UPLOAD:-}" ] && grep -q artifact-upload "$F16/log"; then exit 1; fi; case "\$cmd" in *"| wc -l"*) echo "\${STUB_PYC:-0}" ;; *) i=0; while [ "\$i" -lt "\${STUB_PYC:-0}" ]; do i=\$((i + 1)); echo "/opt/crashbox/current/x\$i.pyc"; done ;; esac ;;
  *artifact-upload*) echo '{"artifact_id":"stub"}' ;;
esac
exit 0
EOF
chmod +x "$F16/bin/"*
run_f16() { : >"$F16/log"; rm -f "$F16/"*.receipt.json
  env PATH="$F16/bin:$PATH" WEB01=stub-host "$@" bash "$DSYM_SUBJECT" "$F16/Baton-0.19.3+103-X.dSYM.zip" baton-macos 2>&1; }
out="$(run_f16)"; rc=$?
log="$(cat "$F16/log")"
if [ "$rc" -ne 0 ]; then
  bad "F-16: the stubbed upload did not complete (rc=$rc): $out"
elif printf '%s\n' "$log" | grep -E '^ssh ' | grep -v 'systemd-run --uid=crashbox --gid=crashbox' | grep -q 'sudo'; then
  bad "F-16: a host command ran under plain sudo: $(printf '%s\n' "$log" | grep sudo | grep -v systemd-run | head -1)"
elif grep -qE <<<"$log" "^scp .* stub-host:/tmp/Baton-0\\.19\\.3\\+103-X\\.dSYM\\.zip$"; then
  bad "F-16: the archive still goes to a predictable /tmp path"
elif ! grep -qE <<<"$log" '^scp .* stub-host:/tmp/baton-dsym\.Q1w2E3/'; then
  bad "F-16: the archive does not go into the private directory made for it: $(printf '%s' "$log" | tr '\n' ';')"
else
  ok "F-16 every host command runs as crashbox, into a fresh private remote directory"
fi
first_pyc="$(printf '%s\n' "$log" | grep -n "pyc" | head -1 | cut -d: -f1)"
first_run="$(printf '%s\n' "$log" | grep -n "inspect-fingerprint" | head -1 | cut -d: -f1)"
if [ -n "$first_pyc" ] && [ -n "$first_run" ] && [ "$first_pyc" -lt "$first_run" ]; then
  ok "F-16 leftover bytecode is counted before the first Crashbox command"
else
  bad "F-16: bytecode is not checked before the first Crashbox command runs"
fi
out="$(run_f16 STUB_PYC=3)"; rc=$?
if [ "$rc" -eq 0 ] || grep -q 'artifact-upload' "$F16/log" || grep -q 'inspect-fingerprint' "$F16/log"; then
  bad "F-16: a release tree holding bytecode still ran a Crashbox command (rc=$rc)"
else
  ok "F-16 a release tree already holding bytecode stops the upload before anything runs"
fi

# F-16 review: a post-upload .pyc count that fails must not lose the receipt of an upload
# Crashbox already accepted, and must say what failed.
out="$(run_f16 STUB_PYC_FAIL_AFTER_UPLOAD=1)"; rc=$?
if [ ! -s "$F16/Baton-0.19.3+103-X.dSYM.zip.receipt.json" ]; then
  bad "F-16: a failed post-upload .pyc count lost the receipt of a completed upload (rc=$rc)"
elif [ "$rc" -eq 0 ] || ! grep -q <<<"$out" 'count'; then
  bad "F-16: a failed post-upload .pyc count was not reported as its own error (rc=$rc): $out"
else
  ok "F-16 a failed post-upload .pyc count keeps the receipt and reports the count failure"
fi

# F-6 review: the index.html exception admits publish.sh's version rewrite and nothing else.
# A reordering of lines is a real edit (the CSP meta moved below the inline script), and must
# be refused even though it adds and removes the same lines.
F6="$WORK/f6"; rm -rf "$F6"; mkdir -p "$F6/website"
git -C "$F6" init -q -b main; git -C "$F6" config user.email t@example.invalid; git -C "$F6" config user.name t
printf '<meta http-equiv="Content-Security-Policy" content="x">\n<script>t()</script>\n<p class="eyebrow">Version 1.2.3</p>\n<a href="/Baton-1.2.3.dmg">get</a>\n' >"$F6/website/index.html"
git -C "$F6" add -A; git -C "$F6" commit -qm base
f6_guard() { ( . "$SITE_TREE/scripts/publish-tree-guard.sh"; publish_tree_guard "$F6" "the site" website ) >/dev/null 2>&1; }
sed -i '' 's/1\.2\.3/1.2.4/g' "$F6/website/index.html"
f6_guard && ok "F-6 publish.sh's version rewrite of index.html is admitted" || bad "F-6: the version rewrite of index.html was refused"
git -C "$F6" checkout -q -- website/index.html
printf '<script>t()</script>\n<meta http-equiv="Content-Security-Policy" content="x">\n<p class="eyebrow">Version 1.2.3</p>\n<a href="/Baton-1.2.3.dmg">get</a>\n' >"$F6/website/index.html"
f6_guard && bad "F-6: two swapped lines in index.html passed as a version rewrite" || ok "F-6 swapped lines in index.html are refused, not read as a version rewrite"
git -C "$F6" checkout -q -- website/index.html

# --- F-17: the public history purge certifies only what it checked (TBX-1000000503) --------
# The real scripts/purge-public-history.sh, without --push, against a planted local "public"
# repository. It must never fetch its tool, must redact commit messages as well as blobs, and
# must refuse a history holding a Cloudflare or Crashbox upload token. The token shapes are
# assembled at run time, so this file never carries one the mirror's own guard would refuse.
PURGE_SUBJECT="${BATON_PURGE_SUBJECT:-$SITE_TREE/scripts/purge-public-history.sh}"
if [ ! -f "$PURGE_SUBJECT" ] || ! command -v git-filter-repo >/dev/null; then
  ok "F-17 skipped: purge-public-history.sh or git-filter-repo is not here"
else
  plant_public() {   # $1 = name, $2 = extra file content (blob), $3 = commit message
    local r="$WORK/f17-$1"
    rm -rf "$r" "$r.git"; git init -q -b main "$r"
    git -C "$r" config user.email t@example.invalid; git -C "$r" config user.name t
    mkdir -p "$r/Packages/Kit"; echo 'public' >"$r/Packages/Kit/Kit.swift"
    git -C "$r" add -A; git -C "$r" commit -qm "initial"
    printf '%s\n' "$2" >"$r/Packages/Kit/Notes.md"; git -C "$r" add -A; git -C "$r" commit -qm "$3"
    git clone -q --bare "$r" "$r.git"
    printf '%s' "$r.git"
  }
  run_purge() {   # $1 = bare repo; prints output, returns status
    env -u FILTER_REPO BATON_PUBLIC_REPO="$1" PURGE_WORKDIR="$WORK/f17-work" bash "$PURGE_SUBJECT" 2>&1
  }
  crashbox_token="cbu1_$(printf 'k%.0s' $(seq 43))"
  cf_token="cf""ut_$(printf 'z%.0s' $(seq 40))"
  host="web"; host="$host-01"
  out="$(run_purge "$(plant_public msg 'nothing secret' "deploy notes for $host")")"; rc=$?
  msgs="$(git -C "$WORK/f17-work/repo" log --all --format=%B 2>/dev/null)"
  if [ "$rc" -ne 0 ]; then
    bad "F-17: a clean planted history was not certified (rc=$rc): $(tail -3 <<<"$out")"
  elif grep -q "$host" <<<"$msgs"; then
    bad "F-17: an internal host name survived in a commit message of the certified history"
  else
    ok "F-17 commit messages are redacted as well as blobs"
  fi
  if grep -q 'raw.githubusercontent.com' "$PURGE_SUBJECT" || grep -qE '^[[:space:]]*curl ' "$PURGE_SUBJECT"; then
    bad "F-17: the purge still fetches git-filter-repo from the network"
  else
    ok "F-17 git-filter-repo is never fetched; the installed one is used"
  fi
  for case in "cf:$cf_token" "crashbox:$crashbox_token"; do
    out="$(run_purge "$(plant_public "${case%%:*}" "token ${case#*:}" "ordinary change")")"; rc=$?
    if [ "$rc" -eq 0 ]; then
      bad "F-17: a history holding a ${case%%:*} token was certified clean"
    else
      ok "F-17 a history holding a ${case%%:*} token is refused"
    fi
  done
  out="$(run_purge "$(plant_public fixture "fixture cbu1_$(printf 'A%.0s' $(seq 43))" "ordinary change")")"; rc=$?
  [ "$rc" -eq 0 ] && ok "F-17 the all-A Crashbox fixture publish-repo.sh allows is allowed here too" \
    || bad "F-17: the all-A Crashbox test fixture was refused (rc=$rc): $(tail -3 <<<"$out")"
  out="$(run_purge "$(plant_public msgtoken 'nothing secret' "rotate $cf_token")")"; rc=$?
  [ "$rc" -ne 0 ] && ok "F-17 a token in a commit message is refused" \
    || bad "F-17: a token in a commit message was certified clean"
fi

# --- E-5: the nginx config is validated before it reaches the live bind mount -------------
# publish-site.sh used to rsync deploy/nginx/ straight into the directory baton_web mounts and
# run `nginx -t` only afterwards, inside the container. A broken config then stayed on disk,
# and the next recreate of the container started on it. The real block, from "Ensure remote
# dirs" to the container status read, runs with ssh and rsync as recording functions; ssh
# fails any `nginx -t` when the stub is told the config is broken.
E5_BLOCK="$(XS='^step "1/[0-9]  Ensure remote dirs"$' XE='^status="[$][(]ssh ' awk '!on && $0 ~ ENVIRON["XS"] { on = 1; print; next } on { print; if ($0 ~ ENVIRON["XE"]) exit }' "$SITE_SUBJECT")"
if [ -z "$E5_BLOCK" ] || ! printf '%s\n' "$E5_BLOCK" | tail -1 | grep -q '^status='; then
  bad "E-5: publish-site.sh's deploy-step anchors were not found; the deploy was restructured"
else
  run_e5() {   # $1 = 1 when the stub's nginx -t should fail
    { echo 'set -euo pipefail'
      echo 'bold() { :; }; step() { :; }; fail() { echo "FAIL: $*" >&2; exit 1; }'
      echo "ssh() { shift; printf 'ssh %s\\n' \"\$*\" >>'$WORK/e5-calls'; case \"\$*\" in *'nginx -t'*) [ '$1' != 1 ] ;; esac; }"
      echo "rsync() { local last=\"\${*: -1}\"; printf 'rsync %s\\n' \"\$last\" >>'$WORK/e5-calls'; }"
      echo "cd '$SITE_TREE'; WEB01=stub-host; REMOTE_DIR=/srv/baton-web; HOSTNAME_FQDN=stub.example"
      echo 'unset DRY_RUN'
      printf '%s\n' "$SITE_RSYNC"
      printf '%s\n' "$SITE_BLOCK" | awk '/^SITE_FILES=\($/,/^\)$/'
      printf '%s\n' "$E5_BLOCK"
      echo 'echo E5_REACHED_STATUS'; } >"$WORK/te5.sh"
    : >"$WORK/e5-calls"
    bash "$WORK/te5.sh" 2>&1
  }
  out="$(run_e5 1)"; rc=$?
  calls="$(cat "$WORK/e5-calls")"
  if [ "$rc" -eq 0 ] || grep -q <<<"$out" E5_REACHED_STATUS; then
    bad "E-5: a config that fails nginx -t still reached the container restart (rc=$rc)"
  elif grep -qE <<<"$calls" 'stub-host:/srv/baton-web/nginx/$|compose up'; then
    bad "E-5: a config that fails nginx -t was written to the live bind mount or started: $(printf '%s' "$calls" | tr '\n' ';')"
  elif ! grep -q <<<"$calls" 'nginx -t'; then
    bad "E-5: nothing validated the config before the deploy: $(printf '%s' "$calls" | tr '\n' ';')"
  else
    ok "E-5 a config that fails nginx -t never reaches the live mount or a restart"
  fi
  out="$(run_e5 0)"; rc=$?
  calls="$(cat "$WORK/e5-calls")"
  order="$(printf '%s\n' "$calls" | awk '
    /nginx[.]staged\/$/ && !s { s = NR } /nginx -t/ && !v { v = NR }
    /rsync -a --delete .*nginx[.]staged\/.*nginx\// && !w { w = NR }
    /compose up/ && !u { u = NR }
    END { print (s && v && w && u && s < v && v < w && w < u) ? "ok" : "bad " s " " v " " w " " u }')"
  if [ "$rc" -ne 0 ] || [ "$order" != ok ]; then
    bad "E-5: a valid config was not staged, validated, swapped in and only then started (rc=$rc, $order): $(printf '%s' "$calls" | tr '\n' ';')"
  elif grep -q <<<"$calls" 'nginx -t' && ! printf '%s\n' "$calls" | grep 'nginx -t' | head -1 | grep -qF 'nginx:1.30-alpine'; then
    bad "E-5: the throwaway validation does not use the image docker-compose.yml runs"
  else
    ok "E-5 a valid config is staged, validated in a throwaway nginx, swapped in, then started"
  fi
fi

# --- E-10, E-7: the static site's CSP, Permissions-Policy and supporters.json policy ---------
# The CSP is a <meta> per page naming the SHA-256 of that page's inline scripts, kept by
# scripts/stamp-site-assets.py. An inline script edited without restamping must fail --check,
# or the browser silently refuses to run it on the live site.
STAMPER="$SITE_TREE/scripts/stamp-site-assets.py"
E10="$WORK/e10"; rm -rf "$E10"; mkdir -p "$E10"
cp "$SITE_TREE/website/styles.css" "$SITE_TREE/website/main.js" "$E10/"
printf '<!doctype html>\n<head>\n<meta charset="utf-8">\n<script>document.documentElement.classList.add("js");</script>\n<link rel="stylesheet" href="styles.css">\n' >"$E10/page.html"
BATON_SITE_DIR="$E10" python3 "$STAMPER" >/dev/null
want_hash="sha256-$(printf '%s' 'document.documentElement.classList.add("js");' | openssl dgst -sha256 -binary | base64)"
if BATON_SITE_DIR="$E10" python3 "$STAMPER" --check >/dev/null 2>&1 && grep -qF "script-src 'self' '$want_hash'" "$E10/page.html" \
   && [ "$(grep -c 'http-equiv="Content-Security-Policy"' "$E10/page.html")" = 1 ]; then
  ok "E-10 the stamper writes one CSP naming the inline script's SHA-256"
else
  bad "E-10: the stamped page does not carry exactly one CSP with the inline script's hash: $(grep -i security "$E10/page.html")"
fi
sed -i '' 's/classList.add("js")/classList.add("js-edited")/' "$E10/page.html"
if BATON_SITE_DIR="$E10" python3 "$STAMPER" --check >/dev/null 2>&1; then
  bad "E-10: an inline script edited without restamping passed --check"
else
  ok "E-10 an inline script edited without restamping fails --check"
fi
if BATON_SITE_DIR="$SITE_TREE/website" python3 "$STAMPER" --check >/dev/null 2>&1; then
  ok "E-10 every page in website/ carries a current CSP"
else
  bad "E-10: website/ has a stale CSP or asset hash (run python3 scripts/stamp-site-assets.py)"
fi
NGINX_CONF="$SITE_TREE/deploy/nginx/default.conf"
if grep -qE '^    "/supporters\.json" +"no-cache";$' "$NGINX_CONF" && grep -qF '"/supporters.json|no-cache|200"' "$SITE_SUBJECT"; then
  ok "E-7 supporters.json revalidates (no-cache), and the deploy's header check asserts it"
else
  bad "E-7: supporters.json has no no-cache policy, or the deploy check still expects none"
fi
pp="$(awk '/^map \$uri \$baton_permissions_policy \{$/,/^\}$/' "$NGINX_CONF")"
if grep -qE <<<"$pp" '^    default +"camera=\(\)' \
   && [ "$(printf '%s\n' "$pp" | grep -cE '^    ~\^/(s|m|b|v1/share|_share_blobs)/ +"";$')" = 5 ] \
   && grep -qF 'add_header Permissions-Policy $baton_permissions_policy always;' "$NGINX_CONF" \
   && grep -qF '"permissions-policy|' "$SITE_SUBJECT"; then
  ok "E-10 Permissions-Policy is set for the site, never for share paths (the service sends its own)"
else
  bad "E-10: the Permissions-Policy map, its share exemptions or the deploy check are missing"
fi
if grep -qE '^      - /opt/docker/baton-share/data/blobs:/srv/baton-share/blobs:ro$' "$SITE_TREE/deploy/docker-compose.yml" \
   && ! grep -qE '/opt/docker/baton-share/data:/' "$SITE_TREE/deploy/docker-compose.yml" \
   && grep -qF 'alias /srv/baton-share/blobs/;' "$NGINX_CONF"; then
  ok "E-8 baton_web mounts only the share blobs, read-only, at the path nginx serves"
else
  bad "E-8: baton_web still mounts the whole share data directory, or the alias moved"
fi

# --- publish-repo.sh: what reaches the public mirror (TBX-1000000503 F-8, F-9) -------------
# The real EXCLUDES list, purge and task-tag strip, by the anchors scripts/lint-public-safe.sh
# uses, run over a planted mirror.
REPO_SUBJECT="$SITE_TREE/scripts/publish-repo.sh"
block() { XS="$2" XE="$3" awk '!on && $0 ~ ENVIRON["XS"] { on = 1; print; next } on { print; if ($0 ~ ENVIRON["XE"]) exit }' "$1"; }
EXCLUDES_BLOCK="$(block "$REPO_SUBJECT" '^EXCLUDES=[(]$' '^[)]$')"
PURGE_BLOCK="$(block "$REPO_SUBJECT" '^for exclude in "[$][{]EXCLUDES\[@\][}]"; do$' '^done   # end of the purge of excluded paths$')"
TAGS_BLOCK="$(block "$REPO_SUBJECT" '^bold "==> Stripping internal task tags"$' "s/W-\\[0-9\\]\\[0-9\\]\\*//g'$")"
if [ -z "$EXCLUDES_BLOCK" ] || [ -z "$PURGE_BLOCK" ] || [ -z "$TAGS_BLOCK" ]; then
  bad "publish-repo.sh: the EXCLUDES, purge or task-tag anchors were not found"
else
  # F-8: a path the mirror holds from an earlier publish must leave it once EXCLUDES names it.
  # rsync --delete protects excluded paths, so only the purge can remove them.
  M="$WORK/mirror-f8"; S="$WORK/source-f8"
  rm -rf "$M" "$S"; mkdir -p "$M/.git" "$M/specs" "$M/scripts" "$M/app" "$S/app" "$S/scripts"
  echo keep >"$M/.git/HEAD"
  for f in specs/song-sharing.md HANDOFF.md ORCHESTRATION-PLAN.md scripts/backup-repo.sh \
           scripts/publish-repo.sh scripts/install-quota-notifier.py scripts/provision-quota-ses.py; do
    echo stale >"$M/$f"
  done
  echo src >"$S/app/main.swift"; echo src >"$S/scripts/tool.sh"
  { echo 'set -euo pipefail'
    echo 'fail() { echo "FAIL: $*" >&2; exit 1; }'
    echo "SRC='$S'; MIRROR='$M'"
    printf '%s\n' "$EXCLUDES_BLOCK"
    # shellcheck disable=SC2016 # literal text for the harness script
    echo 'rsync -a --delete "${EXCLUDES[@]}" "$SRC/" "$MIRROR/"'
    printf '%s\n' "$PURGE_BLOCK"; } >"$WORK/tf8.sh"
  out="$(bash "$WORK/tf8.sh" 2>&1)"; rc=$?
  left="$(cd "$M" && find . -type f -not -path './.git/*' | sort | tr '\n' ' ')"
  if [ "$rc" -ne 0 ]; then
    bad "F-8: the purge failed (rc=$rc): $out"
  elif [ "$left" != "./app/main.swift ./scripts/tool.sh " ]; then
    bad "F-8: excluded paths survived the purge in the mirror: $left"
  elif [ ! -f "$M/.git/HEAD" ]; then
    bad "F-8: the purge removed the mirror's own .git"
  else
    ok "F-8 every path EXCLUDES names leaves a mirror that held it, and .git stays"
  fi

  # F-8 review: a mirror directory whose own name matches an EXCLUDES pattern (BATON_MIRROR
  # ending in build, docs, dist, ...) must not be purged as a whole, .git included.
  M="$WORK/f8b/build"; rm -rf "$WORK/f8b"; mkdir -p "$M/.git" "$M/app"
  echo keep >"$M/.git/HEAD"; echo src >"$M/app/main.swift"
  sed "s|MIRROR='[^']*'|MIRROR='$M'|" "$WORK/tf8.sh" >"$WORK/tf8b.sh"
  bash "$WORK/tf8b.sh" >/dev/null 2>&1
  if [ -f "$M/.git/HEAD" ] && [ -f "$M/app/main.swift" ]; then
    ok "F-8 a mirror directory named like an excluded path is not itself purged"
  else
    bad "F-8: a BATON_MIRROR named 'build' was removed by the purge, .git included"
  fi

  # F-9: the task-tag strip must not rewrite a Swift string literal or a test name.
  M="$WORK/mirror-f9"; rm -rf "$M"; mkdir -p "$M/app"
  cat >"$M/app/WebhookActions.swift" <<'SWIFT'
// Fills in the publish date (TBX-1234) on every hook. (W-12)
    let label = "Publish date (ISO-8601)"
    func testW32() { XCTFail("W-32: refused") }
  /* Block comment (DL-04)
   * continuation line (STRUCT-06)
   */
    play() // trailing comment (TBX-11038)
    let u = "https://host/path (TBX-5350)" // after a URL string (W-19)
    /*
     block body without a star (W-11)
     */
    let s = "a // not a comment (TBX-77)"
    let i = "\(f("x")) // still a string (TBX-78)"
    let m = """
      multi-line // literal (TBX-79)
      """
SWIFT
  printf 'A note (W-7) about (ABC-12) things.\n' >"$M/app/NOTES.md"
  { echo 'set -euo pipefail'; echo 'bold() { :; }'; echo "MIRROR='$M'"
    printf '%s\n' "$TAGS_BLOCK"; } >"$WORK/tf9.sh"
  out="$(bash "$WORK/tf9.sh" 2>&1)"; rc=$?
  swift="$(cat "$M/app/WebhookActions.swift")"
  if [ "$rc" -ne 0 ]; then
    bad "F-9: the task-tag strip failed (rc=$rc): $out"
  elif ! grep -qF '"Publish date (ISO-8601)"' <<<"$swift" || ! grep -qF '"W-32: refused"' <<<"$swift" \
     || ! grep -qF '"https://host/path (TBX-5350)"' <<<"$swift" || ! grep -qF '"a // not a comment (TBX-77)"' <<<"$swift" \
     || ! grep -qF '// still a string (TBX-78)"' <<<"$swift" || ! grep -qF 'multi-line // literal (TBX-79)' <<<"$swift"; then
    bad "F-9: the strip rewrote a Swift string literal: $swift"
  elif grep -qE 'TBX-1234|W-12|DL-04|STRUCT-06|TBX-11038|W-19|W-11' <<<"$swift"; then
    bad "F-9: a tag in a comment line survived: $swift"
  elif [ "$(cat "$M/app/NOTES.md")" != "A note about things." ]; then
    bad "F-9: Markdown prose is no longer stripped: $(cat "$M/app/NOTES.md")"
  else
    ok "F-9 task tags leave Swift comments (whole lines, trailing // tails, block bodies) and Markdown; string literals stay intact"
  fi
fi

# Report JSON optionals and direct NPM routing are part of publication acceptance.
# Keep these offline regressions on the ordinary gate via this existing script.
if python3 "$PWD/scripts/test-song-sharing-scripts.py"; then
  ok "TBX-8675/TBX-8676 song-sharing report and origin-routing regressions"
else
  bad "TBX-8675/TBX-8676 song-sharing script regressions"
fi

if python3 "$PWD/scripts/test-publish-shell.py"; then
  ok "TBX-11148 Bash3.2 signing arguments and cleanup exit status"
else
  bad "TBX-11148 Bash3.2 publisher shell regressions"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
