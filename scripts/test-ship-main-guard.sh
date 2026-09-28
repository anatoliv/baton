#!/usr/bin/env bash
#
# Every Baton ship path refuses a HEAD that origin/main does not contain. (TBX-7466, ESTATE E19)
#
# The release kit's tests (scripts/release-kit/check.sh) prove the guard itself. This proves it is WIRED: it
# runs the real entry points, unmodified, from a throwaway release clone whose HEAD is a
# planted commit that was never pushed, and asserts that each one
#   - exits nonzero with "RELEASE REFUSED", and
#   - called none of the side-effecting tools before refusing (every one is stubbed and
#     logs its call), so a refusal costs seconds and ships nothing;
# then runs each again with HEAD on origin/main and asserts the guard admitted it. The
# admitted run then stops on a stub or on a later check (no Crashbox config in the clone),
# which is fine: only the guard's verdict is under test.
#
# Entry points: scripts/publish.sh (PUBLISH=1), ios/scripts/testflight.sh,
# scripts/publish-site.sh, scripts/publish-repo.sh, gateway/deploy/deploy.sh.
#
# testflight.sh puts /usr/bin first on PATH, which would shadow a PATH stub of xcrun,
# xcodebuild, security and friends. Those are therefore ALSO stubbed as exported shell
# functions, which a child bash resolves before any PATH lookup.
#
# Hermetic: local bare origin, fake HOME, no network, no Apple, no host. About half a minute,
# most of it publish.sh's own release-identity self-test, which runs before its guard.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

# Under /private/tmp: release_checkout_assert_not_primary admits a standalone clone only there.
WORK="$(mktemp -d /private/tmp/baton-ship-main-guard.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT INT TERM

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 HOME="$WORK/home"
mkdir -p "$HOME"
git config --global init.defaultBranch main
git config --global commit.gpgsign false

# --- a release clone of a minimal copy of THIS tree ------------------------------------
# The entry points and everything they source or run before their guard, copied from the
# working tree under test (not from HEAD), so an uncommitted edit is what gets tested.
SRC="$WORK/src"
mkdir -p "$SRC/app" "$SRC/ios" "$SRC/gateway"
cp -R "$ROOT/scripts" "$SRC/scripts"
cp -R "$ROOT/ios/scripts" "$SRC/ios/scripts"
cp -R "$ROOT/gateway/deploy" "$SRC/gateway/deploy"
cp "$ROOT/app/project.yml" "$SRC/app/project.yml"
cp "$ROOT/ios/project.yml" "$SRC/ios/project.yml"
cp "$ROOT/.gitignore" "$SRC/.gitignore"
# Gitignored files in the copied dirs (a local env file, caches) never reach the commit.
git -C "$SRC" init -q
git -C "$SRC" add -A
git -C "$SRC" commit -qm "release candidate"
git init -q --bare "$WORK/origin.git"
git -C "$SRC" push -q "$WORK/origin.git" HEAD:main
REL="$WORK/rel"
git clone -q "$WORK/origin.git" "$REL"

# --- stubs --------------------------------------------------------------------------------
CALLS="$WORK/calls"
BIN="$WORK/bin"
mkdir -p "$BIN"
STUBBED="ssh scp rsync curl docker gh xcrun xcodebuild xcodegen altool notarytool codesign \
hdiutil spctl security ditto pgrep pkill"
for n in $STUBBED; do
  printf '#!/bin/sh\necho "%s $*" >>"%s"\nexit 1\n' "$n" "$CALLS" >"$BIN/$n"
  chmod +x "$BIN/$n"
done
for n in ssh scp rsync curl xcrun xcodebuild codesign hdiutil spctl security ditto pgrep pkill; do
  eval "$n() { echo \"$n \$*\" >>\"$CALLS\"; return 1; }"
  # shellcheck disable=SC2163
  export -f "$n"
done

# testflight.sh checks these exist before it pins anything. Empty placeholders under the
# fake HOME, so no real key is ever looked at.
mkdir -p "$HOME/keys"
: >"$HOME/keys/dist.p12"; : >"$HOME/keys/AuthKey.p8"

run_entry() {   # <entry> ; prints combined output, returns the entry's status
  local entry="$1"
  : >"$CALLS"
  (
    cd "$REL" || exit 1
    unset SIGN_ID NOTARY_PROFILE SPARKLE_BIN APPCAST_HOST CRASHBOX_ARTIFACT_CREDENTIAL_FILE \
          ALLOW_UNMERGED_RELEASE RELEASE_MAIN_GUARD_REMOTE RELEASE_MAIN_GUARD_BRANCH \
          ALLOW_PRIMARY_CHECKOUT RESUME_FROM_STAPLED DRY_RUN CHECK_ONLY SKIP_UPLOAD \
          SKIP_TESTS SKIP_UI_TESTS SKIP_METADATA BATON_GATE_LOCK_PROBE
    export PATH="$BIN:$PATH" WEB01=stub-host BATON_ALLOW_CONCURRENT_GATE=1 \
           BATON_PUBLIC_REPO="$WORK/no-such-public.git" BATON_MIRROR="$WORK/mirror"
    case "$entry" in
      publish)     PUBLISH=1 ./scripts/publish.sh ;;
      testflight)  P12_PASSWORD=x ASC_ISSUER_ID=x P12_PATH="$HOME/keys/dist.p12" \
                   ASC_KEY_PATH="$HOME/keys/AuthKey.p8" ./ios/scripts/testflight.sh ;;
      site)        ./scripts/publish-site.sh ;;
      repo)        ./scripts/publish-repo.sh ;;
      gateway)     ./gateway/deploy/deploy.sh ;;
    esac
  ) </dev/null 2>&1
}

ENTRIES="publish testflight site repo gateway"

# --- HEAD is a planted commit origin/main does not have ---------------------------------
git -C "$REL" checkout -q -b planted-hotfix
printf 'planted\n' >"$REL/scripts/.planted-hotfix"
git -C "$REL" add scripts/.planted-hotfix
git -C "$REL" commit -qm "planted: fix shipped from a branch"
PLANTED="$(git -C "$REL" rev-parse --short=12 HEAD)"

for e in $ENTRIES; do
  out="$(run_entry "$e")"; rc=$?
  if [ "$rc" = 0 ]; then
    bad "$e: admitted planted commit $PLANTED (exit 0). Tail: $(tail -5 <<<"$out")"
  elif ! grep -qF "RELEASE REFUSED: HEAD $PLANTED is not contained in origin/main" <<<"$out"; then
    bad "$e: exited $rc without the guard's refusal. Tail: $(tail -8 <<<"$out")"
  elif ! grep -qF "planted: fix shipped from a branch" <<<"$out"; then
    bad "$e: refusal did not list the missing commit"
  elif [ -s "$CALLS" ]; then
    bad "$e: side-effecting tools ran before the refusal: $(tr '\n' ';' <"$CALLS")"
  else
    ok "$e refuses an unmerged HEAD (exit $rc) before calling any stubbed tool"
  fi
done

# The gateway deploy guards unconditionally; the others only on their shipping path. Their
# dry and local modes must still be free to run from a branch.
: >"$CALLS"
out="$(cd "$REL" && PATH="$BIN:$PATH" DRY_RUN=1 WEB01=stub-host ./scripts/publish-site.sh </dev/null 2>&1)"
if grep -qF "RELEASE REFUSED" <<<"$out"; then
  bad "site: DRY_RUN=1 was refused by the main guard"
else
  ok "site: DRY_RUN=1 is not asked (it changes nothing on the host)"
fi

# --- HEAD is origin/main: the same runs get past the guard -------------------------------
git -C "$REL" checkout -q main
for e in $ENTRIES; do
  out="$(run_entry "$e")"; rc=$?
  if grep -qF "RELEASE REFUSED" <<<"$out"; then
    bad "$e: refused HEAD on origin/main. Tail: $(tail -8 <<<"$out")"
  elif ! grep -qF "release main guard ok" <<<"$out"; then
    bad "$e: never reached the guard (exit $rc). Tail: $(tail -8 <<<"$out")"
  else
    ok "$e admits HEAD on origin/main (then stopped later, exit $rc, as the stubs intend)"
  fi
done

echo "ship-main-guard: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
