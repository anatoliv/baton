#!/usr/bin/env bash
#
# Every Baton ship path refuses a HEAD that origin/main does not contain.
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
# publish.sh's associated-domain preflight reads these; it runs after the guard.
cp "$ROOT/app/Baton.entitlements" "$ROOT/app/Baton.Release.entitlements" "$SRC/app/"
mkdir -p "$SRC/website/.well-known"
cp "$ROOT/website/.well-known/apple-app-site-association" "$SRC/website/.well-known/apple-app-site-association"
cp "$ROOT/ios/project.yml" "$SRC/ios/project.yml"
cp "$ROOT/.gitignore" "$SRC/.gitignore"
# publish-site checks that a site exists before reaching the main guard.
# A minimal page keeps this fixture focused on the guard, with no asset links.
mkdir -p "$SRC/website"
# Stamped like the real pages, so its Content-Security-Policy is current.
printf '<!doctype html>\n<head>\n<meta charset="utf-8">\n<title>Release guard fixture</title>\n' >"$SRC/website/index.html"
BATON_SITE_DIR="$SRC/website" python3 "$SRC/scripts/stamp-site-assets.py" >/dev/null
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

# --- HEAD is origin/main, but the working tree is not HEAD ------
# The main guard checks the commit; publish-site.sh and publish-repo.sh copied the working
# tree, so an uncommitted edit or an untracked file went out under a commit that lacks it.
stamp_rel() { BATON_SITE_DIR="$REL/website" python3 "$REL/scripts/stamp-site-assets.py" >/dev/null; }
printf '<!doctype html>\n<meta charset="utf-8">\n<title>edited, not committed</title>\n' >"$REL/website/index.html"
stamp_rel
printf 'untracked\n' >"$REL/website/.well-known/untracked-extra"
out="$(run_entry site)"; rc=$?
if [ "$rc" = 0 ] || ! grep -qF "would publish files that are not HEAD" <<<"$out"; then
  bad "site: a dirty tree was not refused (exit $rc). Tail: $(tail -6 <<<"$out")"
elif ! grep -qF "website/index.html" <<<"$out" || ! grep -qF "untracked-extra" <<<"$out"; then
  bad "site: the refusal did not name both paths. Tail: $(tail -6 <<<"$out")"
elif grep -qE '^(rsync|scp) ' "$CALLS"; then
  bad "site: files were copied before the refusal: $(tr '\n' ';' <"$CALLS")"
else
  ok "site refuses an uncommitted edit and an untracked file before copying anything"
fi
git -C "$REL" checkout -q -- website/index.html
rm -f "$REL/website/.well-known/untracked-extra"

# publish.sh's own landing-page rewrite is the one dirty change the site may carry.
printf '<meta charset="utf-8">\n<p class="eyebrow">Version 1.2.3</p><a href="/Baton-1.2.3.dmg">get</a>\n' >"$REL/website/index.html"
stamp_rel
git -C "$REL" commit -qam "fixture: a versioned landing page"
git -C "$REL" push -q origin HEAD:main
sed -i '' -e 's/1\.2\.3/1.2.4/g' "$REL/website/index.html"
out="$(run_entry site)"; rc=$?
if grep -qF "would publish files that are not HEAD" <<<"$out"; then
  bad "site: refused publish.sh's own version rewrite of index.html. Tail: $(tail -6 <<<"$out")"
elif ! grep -qF "version rewrite only" <<<"$out"; then
  bad "site: never reached the tree guard with the rewrite (exit $rc). Tail: $(tail -6 <<<"$out")"
else
  ok "site admits publish.sh's version rewrite of index.html and says so"
fi
printf '<meta charset="utf-8">\n<p class="eyebrow">Version 1.2.4</p><a href="/Baton-1.2.4.dmg">get</a> plus an edit\n' >"$REL/website/index.html"
stamp_rel
out="$(run_entry site)"; rc=$?
if [ "$rc" = 0 ] || ! grep -qF "would publish files that are not HEAD" <<<"$out"; then
  bad "site: an edit beyond the version rewrite was admitted (exit $rc)"
else
  ok "site refuses an index.html edit that is more than the version rewrite"
fi
git -C "$REL" checkout -q -- website/index.html

# The mirror is HEAD: an untracked file and an uncommitted edit stay out of it. A local bare
# repo stands in for the public one; the run stops at the stubbed build gate, after the sync.
git init -q --bare "$WORK/public.git"
git clone -q "$WORK/public.git" "$WORK/public-seed" 2>/dev/null
git -C "$WORK/public-seed" commit -q --allow-empty -m "public root"
git -C "$WORK/public-seed" push -q origin HEAD:main
# The sync needs the real rsync; every other tool stays a logging stub.
BIN_REPO="$WORK/bin-repo"; mkdir -p "$BIN_REPO"
for n in $STUBBED; do [ "$n" = rsync ] || ln -sf "$BIN/$n" "$BIN_REPO/$n"; done
run_repo() {   # publish-repo.sh against the local public repo; real rsync, stubbed rest
  ( cd "$REL" || exit 1
    unset -f rsync
    BATON_PUBLIC_REPO="$WORK/public.git" BATON_MIRROR="$WORK/mirror" PATH="$BIN_REPO:$PATH" \
      ./scripts/publish-repo.sh ) </dev/null 2>&1
}
printf 'untracked, never public\n' >"$REL/scripts/untracked-note.sh"
committed="$(git -C "$REL" show HEAD:scripts/release-checkout.sh | shasum -a 256 | cut -c1-64)"
printf '# uncommitted edit\n' >>"$REL/scripts/release-checkout.sh"
rm -rf "$WORK/mirror"
out="$(run_repo)"; rc=$?
mirrored="$( [ -f "$WORK/mirror/scripts/release-checkout.sh" ] && shasum -a 256 <"$WORK/mirror/scripts/release-checkout.sh" | cut -c1-64)"
if [ ! -d "$WORK/mirror/scripts" ]; then
  bad "repo: the run never synced a mirror (exit $rc). Tail: $(tail -6 <<<"$out")"
elif [ -e "$WORK/mirror/scripts/untracked-note.sh" ]; then
  bad "repo: an untracked file reached the public mirror"
elif [ "$mirrored" != "$committed" ]; then
  bad "repo: the mirror carries an uncommitted edit rather than HEAD's file"
else
  ok "repo mirrors HEAD: untracked files and uncommitted edits stay out"
fi
git -C "$REL" checkout -q -- scripts/release-checkout.sh

# A cask rewrite the operator has not committed would be left behind silently, so it refuses.
mkdir -p "$REL/Casks"
printf 'cask "baton" do\n  version "1.2.3,10"\nend\n' >"$REL/Casks/baton.rb"
git -C "$REL" add Casks/baton.rb && git -C "$REL" commit -qm "fixture: cask"
git -C "$REL" push -q origin HEAD:main
sed -i '' -e 's/1\.2\.3,10/1.2.4,11/' "$REL/Casks/baton.rb"
: >"$CALLS"
out="$(run_repo)"; rc=$?
if [ "$rc" = 0 ] || ! grep -qF "Casks/baton.rb" <<<"$out" || ! grep -qF "the mirror publishes HEAD" <<<"$out"; then
  bad "repo: an uncommitted cask was not refused (exit $rc). Tail: $(tail -4 <<<"$out")"
else
  ok "repo refuses while the cask rewrite is uncommitted, since the mirror publishes HEAD"
fi
git -C "$REL" checkout -q -- Casks/baton.rb

echo "ship-main-guard: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
