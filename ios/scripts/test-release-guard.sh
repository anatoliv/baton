#!/bin/bash
#
# Drive ios/scripts/release-guard.sh directly and watch it fail.
#
# A guard nobody has seen fire is decoration. This exercises the guard against a
# throwaway git repo — no Xcode, no archive, no Apple, a second or two — and asserts
# both halves: that it goes red on each way the 2026-09-07 release went wrong, and
# that it stays green through an ordinary run including the script's own deliberate
# patch of project.yml.
#
#   ./ios/scripts/test-release-guard.sh
#
# Exit 0 = every case behaved as expected. Pass -v to see the guard's own output.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

# RELEASE_GUARD_PATH lets test-release-guard-mutants.sh point this suite at a mutated
# copy of the guard. Unset — which is every ordinary run — it is the real file.
. "${RELEASE_GUARD_PATH:-$DIR/release-guard.sh}"

WORK="$(mktemp -d -t baton-release-guard-test)"
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/out.txt"
PASS=0
FAIL=0

yml() {  # $1 = version -> a project.yml shaped like the real one
  cat <<EOF
name: BatonMobile
settings:
  base:
    CODE_SIGN_STYLE: Automatic
    MARKETING_VERSION: "$1"
    CURRENT_PROJECT_VERSION: "1"
EOF
}

archive_plist() {  # $1 = archive dir, $2 = version
  mkdir -p "$1"
  cat > "$1/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>ApplicationProperties</key><dict>
    <key>CFBundleShortVersionString</key><string>$2</string>
    <key>CFBundleVersion</key><string>1757260000</string>
  </dict>
</dict></plist>
EOF
}

# An .xcarchive in miniature: the summary plist Xcode writes at the top, and the app
# bundle underneath it whose Info.plist is what actually ships. $2 = version, and $3,
# when given, is the BatonSourceCommit value; omit $3 for a bundle with no such key,
# which is what every build before TBX-5102 produced.
archive_bundle() {
  local arc="$1" ver="$2" app="$1/Products/Applications/Baton.app"
  mkdir -p "$app"
  cat > "$arc/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>ApplicationProperties</key><dict>
    <key>ApplicationPath</key><string>Applications/Baton.app</string>
    <key>CFBundleShortVersionString</key><string>$ver</string>
    <key>CFBundleVersion</key><string>1786816974</string>
  </dict>
</dict></plist>
EOF
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "  <key>CFBundleShortVersionString</key><string>$ver</string>"
    if [ "$#" -ge 3 ]; then
      echo "  <key>BatonSourceCommit</key><string>$3</string>"
    fi
    echo '</dict></plist>'
  } > "$app/Info.plist"
}

# The manual-signing patch testflight.sh applies in step 2, in miniature.
patch_for_manual_signing() {
  perl -0pi -e 's/    CODE_SIGN_STYLE: Automatic/    CODE_SIGN_STYLE: Manual\n    CODE_SIGN_IDENTITY: "Apple Distribution: Anatoli Vishnyakov (Q8822GNL2H)"/' "$1"
}

fresh_repo() {  # a repo on branch ios-1.0.14 at 1.0.14, plus a main at 1.0.13
  local r="$WORK/repo"
  rm -rf "$r"; mkdir -p "$r/ios/Sources" "$r/Shared" "$r/Packages/BatonSubsonicKit" "$r/docs"
  git -C "$r" init -q -b main
  git -C "$r" config user.email t@example.com
  git -C "$r" config user.name t
  # A skeleton of the real tree, so the production check can be asked about each class
  # of path: compiled (ios/, Shared/, Packages/), bundled prose (HELP.md), and prose
  # that never reaches the app (docs/).
  echo "// app"          > "$r/ios/Sources/App.swift"
  echo "<plist/>"        > "$r/ios/Info.plist"
  echo "// shared"       > "$r/Shared/CrashReporting.swift"
  echo "// package"      > "$r/Packages/BatonSubsonicKit/Client.swift"
  echo "# Help"          > "$r/HELP.md"
  echo "# FAQ"           > "$r/FAQ.md"
  echo "# Notes"         > "$r/docs/notes.md"
  yml "1.0.13" > "$r/ios/project.yml"
  git -C "$r" add -A && git -C "$r" commit -qm "1.0.13"
  git -C "$r" checkout -q -b ios-1.0.14
  yml "1.0.14" > "$r/ios/project.yml"
  git -C "$r" add -A && git -C "$r" commit -qm "1.0.14"
  printf '%s' "$r"
}

# expect <"red"|"green"> <label> -- <command...>
expect() {
  local want="$1" label="$2"; shift 3
  "$@" >"$OUT" 2>&1
  local rc=$?
  local got="green"; [ $rc -ne 0 ] && got="red"
  if [ "$got" = "$want" ]; then
    echo "PASS  [$got] $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL  expected $want, got $got — $label"
    FAIL=$((FAIL + 1))
    VERBOSE=1
  fi
  if [ "$VERBOSE" = 1 ]; then
    sed 's/^/      | /' "$OUT"
    echo
  fi
}

# expect_saying <"red"|"green"> <label> <fixed string the output must contain> -- cmd...
#
# Same as expect, plus the message. A guard that fires with an unusable explanation
# has half-failed: the recovery instructions name the branch to go back to and the
# reason a value was refused, and neither is checked by an exit status. Without this,
# the message-only functions have no test at all and can be deleted silently.
expect_saying() {
  local want="$1" label="$2" needle="$3"; shift 4
  "$@" >"$OUT" 2>&1
  local rc=$?
  local got="green"; [ $rc -ne 0 ] && got="red"
  if [ "$got" = "$want" ] && grep -qF -e "$needle" "$OUT"; then
    echo "PASS  [$got] $label"
    PASS=$((PASS + 1))
  else
    if [ "$got" != "$want" ]; then
      echo "FAIL  expected $want, got $got — $label"
    else
      echo "FAIL  $got as expected, but the message never said '$needle' — $label"
    fi
    FAIL=$((FAIL + 1))
    VERBOSE=1
  fi
  if [ "$VERBOSE" = 1 ]; then
    sed 's/^/      | /' "$OUT"
    echo
  fi
}

echo "=== release guard: does it actually fire? ==============================="
echo

# ---------------------------------------------------------------- case 1: green
R="$(fresh_repo)"
release_pin "$R" "$R/ios/project.yml" >/dev/null
expect green "nothing moves: an ordinary run passes the checkpoint" -- \
  release_assert "before the upload"

# ------------------------------------------------- case 2: the actual incident
# Pin on the release branch, then `git checkout main` mid-run, as happened on
# 2026-09-07. Version and HEAD both move.
R="$(fresh_repo)"
release_pin "$R" "$R/ios/project.yml" >/dev/null
git -C "$R" checkout -q main
expect red "TBX-5058 replay: git checkout main mid-run (1.0.14 -> 1.0.13)" -- \
  release_assert "before the upload"

# ----------------------------------------- case 3: same version, different code
# Two commits carrying the same MARKETING_VERSION. The version check cannot see
# this; HEAD can. This is why HEAD is pinned as well.
R="$(fresh_repo)"
release_pin "$R" "$R/ios/project.yml" >/dev/null
git -C "$R" checkout -q -b hotfix
echo "# unrelated change" >> "$R/ios/other.txt"
git -C "$R" add -A && git -C "$R" commit -qm "same version, different tree"
expect red "tree moved to a different commit at the same version (HEAD signal)" -- \
  release_assert "before the archive"

# ------------------------------- case 4: the script's OWN edit must NOT fire...
R="$(fresh_repo)"
release_pin "$R" "$R/ios/project.yml" >/dev/null
patch_for_manual_signing "$R/ios/project.yml"
release_repin_project_yml >/dev/null
expect green "step 2's deliberate manual-signing patch, after re-pinning" -- \
  release_assert "before the archive"

# ------------------------------------- case 5: ...but a foreign edit must fire.
# Same repo state as case 4, then something else touches project.yml while the
# version string stays put — a checkout landing on a branch whose project.yml
# differs only in signing keys, which is how the duplicated keys appeared.
printf '        PROVISIONING_PROFILE_SPECIFIER: "Baton App Store"\n' >> "$R/ios/project.yml"
expect red "project.yml changed under the run, version unchanged (digest signal)" -- \
  release_assert "before the upload"

# ------------------------------------------- case 6: what was actually compiled
R="$(fresh_repo)"
release_pin "$R" "$R/ios/project.yml" >/dev/null      # pinned 1.0.14
archive_plist "$WORK/wrong.xcarchive" "1.0.13"        # but 1.0.13 got built
expect red "the archive holds 1.0.13 while the run is pinned at 1.0.14" -- \
  release_assert_archive_version "$WORK/wrong.xcarchive"

archive_plist "$WORK/right.xcarchive" "1.0.14"
expect green "the archive holds the pinned version" -- \
  release_assert_archive_version "$WORK/right.xcarchive"

expect red "no archive to read (nothing to prove the upload with)" -- \
  release_assert_archive_version "$WORK/missing.xcarchive"


echo
echo "=== source identity (TBX-5102): can the build name its own commit? ======="
echo

REAL="$(fresh_repo)"
REAL_SHA="$(git -C "$REAL" rev-parse HEAD)"

# ---------------------------------------------- the shape rule, on its own
# rg_is_valid_commit is the single place that decides what counts as an identity, and
# every refusal below is a shape a broken build actually produces. Driven directly
# because most of them cannot be reached through a real checkout.
shape() {  # shape <red|green> <label> <candidate>
  expect "$1" "$2" -- rg_is_valid_commit "$3"
}
shape green "40 lowercase hex is the one accepted shape"                  "$REAL_SHA"
shape red   "empty: the build setting never reached xcodebuild"           ""
shape red   "unexpanded \$(BATON_SOURCE_COMMIT) template"                  '$(BATON_SOURCE_COMMIT)'
shape red   "unexpanded \${BATON_SOURCE_COMMIT} template"                  '${BATON_SOURCE_COMMIT}'
shape red   "the placeholder 'dev'"                                       "dev"
shape red   "the placeholder 'unknown'"                                   "unknown"
shape red   "the placeholder 'HEAD'"                                      "HEAD"
shape red   "the placeholder 'local'"                                     "local"
shape red   "abbreviated to 8 characters"                                 "${REAL_SHA:0:8}"
shape red   "39 characters — one short"                                   "${REAL_SHA:0:39}"
shape red   "41 characters — one long"                                    "${REAL_SHA}0"
shape red   "uppercase hex is a second name for one commit"               "$(printf '%s' "$REAL_SHA" | tr 'a-f' 'A-F')"
shape red   "one uppercase character is enough"                           "A${REAL_SHA:1}"
shape red   "not hexadecimal"                                             "not-a-sha-not-a-sha-not-a-sha-not-a-shaa"
# The reason the rule says ASCII rather than "hex". Forty Arabic-Indic digits are 40
# characters to anything Unicode-aware — Swift's Character.isNumber says yes to every
# one — and git cannot emit a single one of them.
shape red   "40 Arabic-Indic digits: digits to Unicode, never a git object id"  "٠١٢٣٤٥٦٧٨٩٠١٢٣٤٥٦٧٨٩٠١٢٣٤٥٦٧٨٩٠١٢٣٤٥٦٧٨٩"

# -------------------------------------- the same rule, under hostile locales
# Both halves of this section are load-bearing, and each was arrived at the expensive
# way on the macOS guard (TBX-5101), which shares this code's shape.
#
# THE FIXTURE. `[!0-9a-f]` looks like "reject anything but lowercase hex" and is not:
# a bracket range is collation-driven, and en_US.UTF-8 orders aAbBcCdDeEfF, so under
# it the range `a-f` SPANS the uppercase letters A-E. Only F falls outside, because it
# sorts after lowercase f. So an uppercase hash containing an F is refused and one
# without an F is accepted — and the macOS suite passed throughout because the
# uppercase fixture it happened to pick contained six Fs. A fixture is not a test if
# a different, equally reasonable fixture would have hidden the bug.
#
# THE LOCALE. Asserting only under the default locale is decoration however well the
# fixture is chosen: the C variants of every case below pass even on the buggy
# spelling. The bug lives in the UTF-8 collation, so a UTF-8 locale has to be named.
NO_F_UPPER="83CCBE9D8BB707C0937A6A1E6E9836E1E2BE7B11"   # 40 hex, uppercase, contains no F
WITH_F_UPPER="83CCBE9D8BB707CF937A6A1F6F9836F1F2BF7B11" # 40 hex, uppercase, contains F
LOWER_40="83ccbe9d8bb707c0937a6a1e6e9836e1e2be7b11"

# in_locale <locale> <fn> <arg...> — run one guard function under an explicit locale.
#
# A SUBSHELL WITH AN EXPORT, and not the obvious `LC_ALL=x fn args`. The assignment-
# prefix form does not work on a shell function: bash re-reads the locale when LC_ALL
# is assigned or exported in the shell, not when it is set as a temporary prefix
# around a function call, so the pattern matching inside the function still collates
# under whatever locale the script inherited. The first version of this helper used
# the prefix form, and every case below was silently running under one locale while
# claiming three. It passed — because the fixed guard is locale-independent — and the
# label was a lie. Replaying the pre-fix spelling through it is what exposed that: the
# [C] cases failed, which is impossible if C were really in effect.
#
# That is the same shape as the bugs this suite exists to catch, produced here by the
# test rather than by the code, which is the reason the replay below is kept.
in_locale() {
  local loc="$1"; shift
  ( export LC_ALL="$loc" LANG="$loc"; "$@" )
}

for LOC in C en_US.UTF-8 tr_TR.UTF-8; do
  expect red "[$LOC] uppercase with NO 'F' is refused (the fixture that hides it)" -- \
    in_locale "$LOC" rg_is_valid_commit "$NO_F_UPPER"
  expect red "[$LOC] uppercase containing 'F' is refused" -- \
    in_locale "$LOC" rg_is_valid_commit "$WITH_F_UPPER"
  expect green "[$LOC] the lowercase spelling of the same hash is accepted" -- \
    in_locale "$LOC" rg_is_valid_commit "$LOWER_40"
  # The diagnosis, which is where this actually bit: an abbreviated LOWERCASE hash
  # containing b-f hits the uppercase arm under a collated range and reports a
  # spelling problem that does not exist. An uppercase input cannot see this bug,
  # because on the buggy spelling it gives the right answer for the wrong reason.
  expect_saying red "[$LOC] an abbreviated lowercase hash is diagnosed by length, not case" \
    "8 characters, not 40" -- \
    in_locale "$LOC" rg_validate_commit_for_repo "$REAL" "0123abcd"
  expect_saying red "[$LOC] an uppercase hash is diagnosed as a spelling" \
    "uppercase hex" -- \
    in_locale "$LOC" rg_validate_commit_for_repo "$REAL" "$NO_F_UPPER"
done

# ---------------------------------- shape is not enough: it has to exist here
# 40 lowercase hex characters somebody typed pass every test above. Stamping one would
# put a revision into the app that nobody can ever check out.
expect green "a real HEAD passes the full admission test" -- \
  rg_validate_commit_for_repo "$REAL" "$REAL_SHA"
expect red "well-formed, but not a commit in this repository" -- \
  rg_validate_commit_for_repo "$REAL" "0123456789abcdef0123456789abcdef01234567"
# A tree object is a real object with a real 40-hex id, and `git rev-parse --verify`
# resolves it happily. It is not something anyone can check out.
TREE_SHA="$(git -C "$REAL" rev-parse 'HEAD^{tree}')"
expect red "a tree object's id is not a source revision" -- \
  rg_validate_commit_for_repo "$REAL" "$TREE_SHA"

# ------------------------------------------- the pin refuses an unusable identity
R="$WORK/not-a-repo"; rm -rf "$R"; mkdir -p "$R/ios"; yml "1.0.14" > "$R/ios/project.yml"
expect red "pinning outside a git checkout: there is no commit to stamp" -- \
  release_pin "$R" "$R/ios/project.yml"

# ---------------------------------- what was actually COMPILED carries the commit
# The source-side checks say what the tree claims. These say what is in the bundle
# that is about to be packaged, which is the only evidence a tree cannot fabricate.
R="$(fresh_repo)"
release_pin "$R" "$R/ios/project.yml" >/dev/null
SHA="$(git -C "$R" rev-parse HEAD)"

archive_bundle "$WORK/good.xcarchive" "1.0.14" "$SHA"
expect green "the bundle names the pinned commit" -- \
  release_assert_archive_identity "$WORK/good.xcarchive"

# The live App Store build (1.0, build 1786816974) in miniature: version strings and
# no identity key at all. It is unfixable after the fact; this is the check that stops
# a second one being uploaded.
archive_bundle "$WORK/legacy.xcarchive" "1.0.14"
expect red "no BatonSourceCommit key at all — the 1786816974 shape" -- \
  release_assert_archive_identity "$WORK/legacy.xcarchive"

archive_bundle "$WORK/empty.xcarchive" "1.0.14" ""
expect red "the key is present and empty: the setting never reached xcodebuild" -- \
  release_assert_archive_identity "$WORK/empty.xcarchive"

archive_bundle "$WORK/template.xcarchive" "1.0.14" '$(BATON_SOURCE_COMMIT)'
expect red "the key still holds its own unexpanded template" -- \
  release_assert_archive_identity "$WORK/template.xcarchive"

archive_bundle "$WORK/short.xcarchive" "1.0.14" "${SHA:0:8}"
expect red "the bundle carries an abbreviated hash" -- \
  release_assert_archive_identity "$WORK/short.xcarchive"

archive_bundle "$WORK/upper.xcarchive" "1.0.14" "$(printf '%s' "$SHA" | tr 'a-f' 'A-F')"
expect red "the bundle carries the uppercase spelling" -- \
  release_assert_archive_identity "$WORK/upper.xcarchive"

# A well-formed commit that is simply not this run's. This is the tree-moved-and-moved-
# back case: every source-side assertion passes, and only the artifact disagrees.
archive_bundle "$WORK/other.xcarchive" "1.0.14" "0123456789abcdef0123456789abcdef01234567"
expect red "the bundle names a different commit than the one pinned" -- \
  release_assert_archive_identity "$WORK/other.xcarchive"

expect red "no bundle to read (nothing to prove the upload with)" -- \
  release_assert_archive_identity "$WORK/absent.xcarchive"

echo
echo "=== the production bar: is the stamped commit actually true? ============="
echo

# Every case below pins a fresh repo and then dirties it, because the question is not
# "did the tree move" (that is release_assert) but "does the commit about to be stamped
# describe the bytes that were compiled".
prod_repo() {  # a pinned repo with the release script's own allowlist declared
  R="$(fresh_repo)"
  release_pin "$R" "$R/ios/project.yml" >/dev/null
  release_allow_release_edit "ios/project.yml" >/dev/null
}

prod_repo
expect green "a clean tree: the pinned commit is the whole build" -- \
  release_assert_production_ready "before the gate"

# ------------------------------------------------------- direction 1: our own edits
# testflight.sh patches project.yml for manual signing in step 2 and restores it in the
# exit trap. That is the trap this check has to survive: a bare "refuse any dirt" rule
# aborts a good release after the archive, the signing and the export.
prod_repo
patch_for_manual_signing "$R/ios/project.yml"
release_repin_project_yml >/dev/null
expect green "step 2's own manual-signing patch does NOT trip the dirty check" -- \
  release_assert_production_ready "before the upload"

# ------------------------------------------- direction 2: anybody else's edits
# Same run, same allowlist, one more file touched. A genuine mid-run source change has
# to abort even though the declared path is legitimately dirty at the same moment.
printf '\nlet x = 1\n' >> "$R/ios/Sources/App.swift"
expect red "a real source edit alongside our own patch still aborts" -- \
  release_assert_production_ready "before the upload"

# The allowlist is exact paths, not prefixes. A sibling file in the same directory as
# the one declared is somebody else's.
prod_repo
printf 'x\n' >> "$R/ios/Info.plist"
expect red "a sibling of the declared path is not covered by it" -- \
  release_assert_production_ready "before the upload"

# ------------------------------------------------------------- fatal vs benign roots
prod_repo
printf '\n// edited\n' >> "$R/Shared/CrashReporting.swift"
expect red "Shared/ compiles into the app — dirty there is fatal" -- \
  release_assert_production_ready "before the upload"

prod_repo
printf '\n// edited\n' >> "$R/Packages/BatonSubsonicKit/Client.swift"
expect red "Packages/ compiles into the app — dirty there is fatal" -- \
  release_assert_production_ready "before the upload"

# HELP.md and FAQ.md are prose, and they are also bundled resources: the prebuild step
# copies them into ios/Resources and they ship inside the app. Classifying them with
# the docs would have been the easy mistake.
prod_repo
printf '\nEdited.\n' >> "$R/HELP.md"
expect red "HELP.md is copied into the bundle — dirty there is fatal" -- \
  release_assert_production_ready "before the upload"

prod_repo
printf '\nEdited.\n' >> "$R/docs/notes.md"
expect green "docs/ cannot reach the compiled bytes — reported, not fatal" -- \
  release_assert_production_ready "before the upload"

# ---------------------------------------------------------- unclassified fails closed
# The point of listing what is FATAL rather than what is ignorable. A directory nobody
# has classified is refused, so the day somebody adds a top-level tree that compiles,
# the release stops instead of silently shipping uncommitted code from it.
prod_repo
mkdir -p "$R/newkit"
printf 'source\n' > "$R/newkit/Thing.swift"
expect red "an unclassified top-level directory is refused, not ignored" -- \
  release_assert_production_ready "before the upload"

prod_repo
printf 'x\n' > "$R/NEWFILE.txt"
expect red "an unclassified top-level file is refused, not ignored" -- \
  release_assert_production_ready "before the upload"

# A path git had to quote is not unpicked and not guessed at — it is refused.
prod_repo
printf 'x\n' > "$R/ios/a file with spaces.swift"
expect red "a quoted path is refused rather than parsed" -- \
  release_assert_production_ready "before the upload"

# ---------------------------------------- an empty allowlist grants nothing
# release_pin clears RG_ALLOWED_DIRTY, so a caller that forgets to declare its edits
# gets the strict rule rather than the last run's list.
R="$(fresh_repo)"
release_pin "$R" "$R/ios/project.yml" >/dev/null
patch_for_manual_signing "$R/ios/project.yml"
release_repin_project_yml >/dev/null
expect red "without a declared allowlist, even our own edit is refused" -- \
  release_assert_production_ready "before the upload"

echo
echo "=== the refusal has to be usable, not just red ==========================="
echo

# rg_describe_bad_commit exists only to turn a refusal into a diagnosis. Nothing about
# an exit status can tell whether it said anything true, so these read the message. The
# distinction it draws is the expensive one: "the key is missing" sends you to
# project.yml and "the value never expanded" sends you to testflight.sh, and a
# diagnosis pointing at the wrong file costs more than none.
R="$(fresh_repo)"
release_pin "$R" "$R/ios/project.yml" >/dev/null
expect_saying red "an empty identity is diagnosed as the setting never arriving" \
  "never reached the build" -- \
  rg_validate_commit_for_repo "$R" ""
expect_saying red "an unexpanded template is diagnosed as a substitution failure" \
  "never substituted" -- \
  rg_validate_commit_for_repo "$R" '$(BATON_SOURCE_COMMIT)'
expect_saying red "an abbreviated hash is diagnosed by its length" \
  "8 characters, not 40" -- \
  rg_validate_commit_for_repo "$R" "0123abcd"
expect_saying red "an uppercase hash is diagnosed as a spelling, not as garbage" \
  "uppercase hex" -- \
  rg_validate_commit_for_repo "$R" "0123456789ABCDEF0123456789abcdef01234567"
expect_saying red "a placeholder is named as the placeholder it is" \
  "the placeholder dev" -- \
  rg_validate_commit_for_repo "$R" "dev"

archive_bundle "$WORK/nokey.xcarchive" "1.0.14"
expect_saying red "a missing key sends you to project.yml, not to the release script" \
  "does not declare the key" -- \
  release_assert_archive_identity "$WORK/nokey.xcarchive"
archive_bundle "$WORK/blank.xcarchive" "1.0.14" ""
expect_saying red "a present-but-empty key sends you to xcodebuild instead" \
  "never reached the build" -- \
  release_assert_archive_identity "$WORK/blank.xcarchive"

# The abort tells you how to get back to where the release started. Without the branch
# name the instruction is `git checkout` with a blank argument.
R="$(fresh_repo)"
release_pin "$R" "$R/ios/project.yml" >/dev/null
git -C "$R" checkout -q main
expect_saying red "the recovery instruction names the branch the release started on" \
  "ios-1.0.14" -- \
  release_assert "before the upload"

echo
echo "=== does the declared allowlist still match what the script rewrites? ===="
echo

# release_assert_production_ready is only as honest as the list testflight.sh declares
# to it. The list is a claim about the script — "these are the tracked files I rewrite
# mid-run" — and nothing keeps the claim true as the script changes. A third in-place
# edit added later, undeclared, aborts a real release after the archive and the
# signing; declared but unnoticed, it widens the carve-out silently. Either way the
# discovery costs a release run.
#
# So this counts the sites that mutate a tracked file in place and compares that count
# against the number of declared paths. It is not a proof of correspondence — it
# cannot tell which path a `sed -i` targets — but it does catch the case that matters,
# which is the count moving without the list moving.

# One line per in-place mutation of a tracked file. Comment lines are excluded: the
# script's header prose talks about the edits it makes, and counting the prose would
# make the check pass for the wrong reason.
#
# The App Store metadata push is an in-place mutation too, one step removed: testflight.sh
# calls `app-store-metadata.py push`, and that script rewrites the `_live` half of
# ios/metadata/en-US.json from what Apple holds after the push. It is the site this check
# could not see on 2026-09-09, when the first release with a pending listing change was
# refused at the checkpoint before the upload for exactly that file. So the call line
# counts as a site and resolves to that path.
tf_edit_sites() {
  grep -nE "sed -i|perl -0?[a-z]*pi|open\([a-z_]+, ['\"]w['\"]\)|app-store-metadata\.py\" push" "$1" \
    | grep -vE '^[0-9]+: *#'
}

# The arguments to release_allow_release_edit, one path per line.
tf_declared_paths() {
  grep -E '^release_allow_release_edit ' "$1" \
    | sed 's/^release_allow_release_edit //' | tr ' ' '\n' | tr -d '"' | grep -v '^$'
}

# Resolve the repo-relative path each in-place edit targets, or print "<unresolved>".
#
# Counting sites catches a third edit appearing. It does not catch an edit whose
# TARGET moved, which is the failure that actually ships: the declared list still has
# one entry, the script still has one site, and they now name different files. So each
# site is resolved to a path and required to be declared. Anything this cannot resolve
# prints <unresolved> and is treated as undeclared, which fails closed — a target this
# cannot read is not a target it can vouch for.
tf_edit_targets() {
  local tf="$1"
  # The step-2 python patch: `python3 - "$IOS/project.yml" ...` names its target as the
  # first argument to the heredoc, and the script writes back to that same path.
  grep -oE 'python3 - "\$IOS/[A-Za-z0-9_./-]+"' "$tf" \
    | sed -e 's|python3 - "\$IOS/|ios/|' -e 's|"$||'
  # sed -i / perl -pi: the target is the last word on the line.
  grep -hE "sed -i|perl -0?[a-z]*pi" "$tf" | grep -vE '^ *#' \
    | awk '{ t = $NF; gsub(/["'"'"']/, "", t); print (t ~ /^[A-Za-z0-9_.\/-]+$/ ? "ios/" t : "<unresolved>") }'
  # The metadata push: its output path is fixed by app-store-metadata.py, not by the line.
  grep -hE 'app-store-metadata\.py" push' "$tf" | grep -vE '^ *#' \
    | sed 's|.*|ios/metadata/en-US.json|'
}

check_release_edit_drift() {
  local tf="$1" nsites ndeclared target
  nsites="$(tf_edit_sites "$tf" | grep -c . || true)"
  ndeclared="$(tf_declared_paths "$tf" | grep -c . || true)"
  if [ "$ndeclared" -eq 0 ]; then
    echo "ERROR: $tf declares no allowed edits at all — release_allow_release_edit is missing" >&2
    return 1
  fi
  if [ "$nsites" != "$ndeclared" ]; then
    {
      echo "ERROR: $tf rewrites $nsites tracked path(s) in place but declares $ndeclared."
      echo "  declared to the guard:"
      tf_declared_paths "$tf" | sed 's/^/    /'
      echo "  in-place mutation sites found:"
      tf_edit_sites "$tf" | sed 's/^/    /'
      echo "  Every path the script rewrites must be passed to release_allow_release_edit,"
      echo "  or release_assert_production_ready aborts the release on the script's own"
      echo "  edit — after the archive, the signing and the export."
    } >&2
    return 1
  fi
  # Counts agree. Now the part counts cannot see: every resolved target must itself be
  # declared, so an edit that moves to a different file fails here even though the
  # count is unchanged.
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    if ! tf_declared_paths "$tf" | grep -qxF "$target"; then
      {
        echo "ERROR: $tf rewrites '$target' in place, which is not declared to the guard."
        echo "  declared:"
        tf_declared_paths "$tf" | sed 's/^/    /'
        echo "  resolved edit targets:"
        tf_edit_targets "$tf" | sed 's/^/    /'
        echo "  An <unresolved> target is treated as undeclared on purpose: a target this"
        echo "  check cannot read is not one it can vouch for."
      } >&2
      return 1
    fi
  done <<EOF
$(tf_edit_targets "$tf")
EOF
  echo "  $nsites in-place mutation site, $ndeclared declared path, and every target is declared:"
  tf_edit_targets "$tf" | sed 's/^/    /'
  return 0
}

expect green "the real testflight.sh declares every path it rewrites" -- \
  check_release_edit_drift "$DIR/testflight.sh"

# ...and the check can fail. A third in-place edit, added the way a real one would be
# and not declared, has to be caught here rather than by a release.
DRIFTED="$WORK/testflight-drifted.sh"
sed 's|^xcodegen generate$|sed -i "" "s/x/y/" Info.plist\nxcodegen generate|' \
  "$DIR/testflight.sh" > "$DRIFTED"
expect red "an undeclared third in-place edit is caught here, not by a release" -- \
  check_release_edit_drift "$DRIFTED"

# The case counting cannot see: one site, one declared path, and they name different
# files. This is the drift that actually ships, because nothing about the arithmetic
# looks wrong.
MOVED="$WORK/testflight-moved-target.sh"
sed 's|python3 - "\$IOS/project.yml"|python3 - "$IOS/Info.plist"|' "$DIR/testflight.sh" > "$MOVED"
expect_saying red "an edit whose TARGET moved is caught, though the counts still agree" \
  "which is not declared to the guard" -- \
  check_release_edit_drift "$MOVED"

# And the failure has to be the one it claims: the count, not some unrelated grep. The
# numbers come from the real script rather than being written down here, so adding a
# legitimate site and its declaration (as the metadata push was, 2026-09-09) does not turn
# this into a test of last month's testflight.sh.
REAL_SITES="$(tf_edit_sites "$DIR/testflight.sh" | grep -c . || true)"
REAL_DECLARED="$(tf_declared_paths "$DIR/testflight.sh" | grep -c . || true)"
expect_saying red "the drift report names both counts" \
  "rewrites $((REAL_SITES + 1)) tracked path(s) in place but declares $REAL_DECLARED" -- \
  check_release_edit_drift "$DRIFTED"

echo
echo "=== $PASS passed, $FAIL failed ==========================================="
[ "$FAIL" -eq 0 ]
