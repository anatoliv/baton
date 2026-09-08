#!/bin/bash
#
# macOS release identity guard — a shipped Baton.app must name the commit it was
# built from, and must refuse to exist if it cannot.
#
# WHY THIS EXISTS (TBX-5101, 2026-09-07). An estate audit asked a simple question of
# the live Mac build and could not answer it: which revision is 0.17.12 built from?
# The evidence available was a tag (v0.17.12 -> 83ccbe9d) and an appcast advertising
# 0.17.12/97. Neither is proof. A tag is a movable pointer created by whoever ran
# `git tag -f`, and CFBundleShortVersionString/CFBundleVersion are two strings a
# build takes from project.yml — every commit that carries those strings produces an
# artifact indistinguishable from every other. So "which source built the thing users
# are running" had exactly one honest answer: unknown.
#
# That matters beyond bookkeeping. A crash report is only actionable against a known
# revision; a rollback is only a rollback if you know what you are rolling back to;
# and a dSYM is matched to a build, not to a tag. The fix is to make the artifact
# carry its own identity, and to check it by reading it back OUT OF THE BUILT BUNDLE
# rather than trusting the tree that produced it.
#
# WHAT IS PINNED, and why each one:
#   - the source commit: `git rev-parse HEAD`, 40 lowercase hex. This is the identity.
#     It is baked into the app as the BatonSourceCommit Info.plist key, via the
#     BATON_SOURCE_COMMIT build setting passed on the xcodebuild command line.
#   - MARKETING_VERSION and CURRENT_PROJECT_VERSION from app/project.yml. What the
#     appcast, the cask and Sparkle all key on. If either moves mid-run the artifact
#     is not the release that was started.
#   - the sha256 of app/project.yml, which catches a change that keeps the version
#     strings but alters the bundle id, entitlements or the Sparkle key.
#   - `git status --porcelain`, kept as CONTEXT only and never fatal on its own. The
#     build writes into the tree (the Help pre-build script copies HELP.md/FAQ.md),
#     so a porcelain delta is not by itself evidence of a switch. It IS fatal for a
#     production run — see macrel_assert_production_ready — because a commit stamped
#     into an app built from uncommitted edits is a false claim, not an identity.
#
# This is the same shape as ios/scripts/release-guard.sh (TBX-5058), deliberately:
# the iPhone side already learned that the only check a working tree cannot lie about
# is reading the version back out of what was actually compiled. The Mac needed the
# same check plus the commit, since the Mac ships to a self-hosted appcast where
# nothing downstream — no App Store Connect record — remembers what was uploaded.
#
# Sourced by scripts/publish.sh. Driven directly, with no build and no Apple
# involvement, by scripts/test-release-identity.sh — which is how we know it fires.
#
# Function prefix is `macrel_` rather than `release_` so this and the iOS guard can
# never collide if both are ever sourced into one shell.

# --- readers ---------------------------------------------------------------

# Resolve MARKETING_VERSION the same way scripts/publish.sh and check-release.sh do,
# so every part of the release agrees on what "the version" means.
macrel_marketing_version() {
  local v=""
  [ -f "$1" ] && v="$(perl -ne 'print $1 if /^\s*MARKETING_VERSION:\s*"([^"]+)"/' "$1" | head -1)"
  printf '%s' "${v:-<unreadable>}"
}

macrel_build_number() {
  local v=""
  [ -f "$1" ] && v="$(perl -ne 'print $1 if /^\s*CURRENT_PROJECT_VERSION:\s*"([^"]+)"/' "$1" | head -1)"
  printf '%s' "${v:-<unreadable>}"
}

# Returns the digest, or a SENTINEL plus non-zero — never an empty string.
#
# This used to be `shasum -a 256 "$1" | awk '{print $1}'`, which is the vacuous-pass
# shape: if either tool were missing from PATH the function printed nothing, the pin and
# every later assertion would both hold "", "" would compare equal to "", and the
# project.yml digest check would silently stop detecting anything at all while reporting
# ok. A check that cannot see its input must say so, not agree with itself.
#
# awk is gone too — parameter expansion does the same job with one less thing to lose.
macrel_yml_sha() {
  local out
  [ -f "$1" ] || { printf '%s' "<missing>"; return 1; }
  out="$(shasum -a 256 "$1" 2>/dev/null)" || { printf '%s' "<unreadable>"; return 1; }
  out="${out%% *}"
  local LC_ALL=C
  case "$out" in
    (*[!0123456789abcdef]*|'') printf '%s' "<unreadable>"; return 1 ;;
  esac
  printf '%s' "$out"
}

macrel_head() { git -C "$1" rev-parse HEAD 2>/dev/null || printf '%s' "<not-a-git-checkout>"; }

# A human name for HEAD: the branch if on one, else the tag or bare sha. Only ever
# used in messages — the sha is what is compared.
macrel_head_name() {
  local n
  n="$(git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null)" && { printf '%s' "$n"; return; }
  n="$(git -C "$1" describe --tags --exact-match HEAD 2>/dev/null)" && { printf 'detached at tag %s' "$n"; return; }
  printf 'detached'
}

# Enumerate the dirty paths. Emits one porcelain line per path, or NOTHING plus a
# non-zero status if git could not be asked. Callers MUST check the status.
#
# WHY IT IS SHAPED THIS WAY (2026-09-07, found by the Tonebox iOS lane in its own code
# and reproduced here). This was:
#
#     git -C "$1" status --porcelain 2>/dev/null | LC_ALL=C sort
#
# and it is the vacuous-pass shape: a guard that decides by enumerating bad things and
# passing when the list is empty treats "found nothing" and "looked for nothing" as the
# same answer. With `sort` absent from PATH the last pipeline stage produced no stdout,
# `2>/dev/null` hid the reason, and macrel_assert_production_ready declared a demonstrably
# dirty tree clean. `pipefail` does not help: the last stage does not fail, it produces
# nothing. Measured: PATH=/tmp/emptybin turned "refused" into "PASSED".
#
# Three changes, each removing one way to empty the enumeration:
#   - `sort` is gone. It was never load-bearing — git already emits porcelain in a
#     deterministic path order, and what this needs is set membership, not ordering.
#     A dependency that buys nothing can still cost everything.
#   - stderr is captured rather than discarded, so a failure is diagnosable instead of
#     silent. The Tonebox lane caught its instance only because the error printed next
#     to the PASS; had it redirected stderr it would have seen PASS and believed it.
#   - failure returns non-zero, and the callers treat that as fatal rather than clean.
macrel_porcelain() {
  local out rc
  out="$(git -C "$1" status --porcelain 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "macrel_porcelain: cannot read git status in $1 (exit $rc): $out" >&2
    return 1
  fi
  printf '%s' "$out"
}

# --- the identity rule -----------------------------------------------------

# macrel_is_valid_commit <string>
# The ONLY accepted shape is exactly 40 lowercase hex characters. Everything else is
# refused, and each rejected shape is a real way this goes wrong:
#
#   ""                          the build setting was never passed
#   "$(BATON_SOURCE_COMMIT)"    it was passed but never expanded — an Info.plist that
#                               still holds its own template is the failure that looks
#                               most like success, because the key IS present
#   "unknown" / "none" / "HEAD" a placeholder somebody typed to make a build go through
#   "83ccbe9d"                  abbreviated. Short hashes collide, and git's default
#                               abbreviation length changes with repository size, so a
#                               prefix recorded today may be ambiguous later
#   "83CCBE9D8BB7…"             uppercase. Half the tooling downstream compares these
#                               as strings; two spellings of one commit is two commits
#   "not-a-sha"                 non-hex
#
# Refusing all of them is the point: a wrong identity is worse than a missing one,
# because it is believed.
#
# TWO DEFENCES AGAINST ONE BUG, and both are load-bearing (found by lane-5102 on the
# iOS copy of this shape, 2026-09-07). A shell bracket RANGE is collation-driven, and
# under en_US.UTF-8 the collation interleaves the cases — a, A, b, B, c, C … — so
# `[a-f]` spans A, B, C, D and E as well. This function used `[!0-9a-f]` and therefore
# ACCEPTED a 40-character uppercase hash, as long as it contained no `F` (F sorts after
# lowercase f, so it alone fell outside the range). The suite passed only because the
# uppercase fixture happened to contain an F: an assertion true for the wrong reason.
#
#   1. LC_ALL=C, so bracket expressions are byte-wise rather than collated.
#   2. no ranges at all — the accepted characters are enumerated — so the rule is
#      still correct if the locale assignment is ever lost or overridden.
macrel_is_valid_commit() {
  local LC_ALL=C
  case "$1" in
    (*[!0123456789abcdef]*) return 1 ;;   # outside lowercase hex, incl. uppercase and '$'
    ('')                    return 1 ;;
  esac
  [ "${#1}" -eq 40 ]
}

# macrel_describe_bad_commit <string> — one line saying WHY it was refused, so the
# person reading the failure does not have to work it out from the rule.
macrel_describe_bad_commit() {
  # Same collation hazard as macrel_is_valid_commit, and it bit here first: every
  # abbreviated lowercase hash containing b-f reported itself as "uppercase hex",
  # sending the reader after a spelling problem that did not exist.
  local c="$1" LC_ALL=C
  case "$c" in
    ('')                          printf 'empty — the BATON_SOURCE_COMMIT build setting never reached the build' ;;
    (*'$('*|*'${'*)               printf 'an unexpanded build-setting template — the key is present but was never substituted' ;;
    (unknown|none|HEAD|dev|local|dirty) printf 'the placeholder %s' "$c" ;;
    (*[!0123456789abcdefABCDEF]*) printf 'not hexadecimal' ;;
    (*[ABCDEF]*)                  printf 'uppercase hex — the canonical form is lowercase' ;;
    (*)                           printf '%s characters, not 40 — an abbreviated hash is ambiguous and gets more ambiguous as the repo grows' "${#c}" ;;
  esac
}

# macrel_validate_commit_for_repo <repo-root> <candidate>
# The full admission test for a source identity: the right shape AND an object that
# actually exists here. Both halves are needed. Shape alone accepts a plausible
# fiction — 40 hex characters somebody typed — and existence alone cannot be asked of
# a string git will not parse. Kept as its own function rather than inlined into the
# pin so that scripts/test-release-identity.sh can drive it with a bogus sha, which is
# not a state a real checkout can be put into.
macrel_validate_commit_for_repo() {
  local repo="$1" candidate="$2"
  if ! macrel_is_valid_commit "$candidate"; then
    {
      echo "ERROR: refusing to build — there is no usable source identity to stamp into the app."
      echo "  the candidate revision reads as: '$candidate'"
      echo "  that is $(macrel_describe_bad_commit "$candidate")."
      echo "  A Baton.app that cannot name its own revision is unrollbackable and its crash"
      echo "  reports are unattributable. Build from a real git checkout."
    } >&2
    return 1
  fi
  if ! git -C "$repo" cat-file -e "${candidate}^{commit}" 2>/dev/null; then
    echo "ERROR: $candidate is well-formed but is not a commit in $repo" >&2
    return 1
  fi
  return 0
}

# --- pin -------------------------------------------------------------------

# macrel_pin <repo-root> <path-to-app/project.yml>
# Call once, as early as possible — before the test gate, which is the longest window
# in a release run and therefore the one a stray `git checkout` lands inside.
# Exports MACREL_COMMIT for the caller to hand to xcodebuild.
macrel_pin() {
  MACREL_REPO="$1"
  MACREL_YML="$2"
  MACREL_VERSION="$(macrel_marketing_version "$MACREL_YML")"
  MACREL_BUILD="$(macrel_build_number "$MACREL_YML")"
  MACREL_YML_SHA="$(macrel_yml_sha "$MACREL_YML")"
  MACREL_COMMIT="$(macrel_head "$MACREL_REPO")"
  MACREL_HEAD_NAME="$(macrel_head_name "$MACREL_REPO")"
  MACREL_PORCELAIN="$(macrel_porcelain "$MACREL_REPO")"

  # Test for empty as well as the sentinel. A reader that fails in a way its author did
  # not anticipate returns "", and a check that only knows one spelling of "I could not
  # read this" passes on every other spelling.
  if [ "$MACREL_VERSION" = "<unreadable>" ] || [ -z "$MACREL_VERSION" ]; then
    echo "ERROR: release identity cannot read MARKETING_VERSION from $MACREL_YML" >&2
    return 1
  fi
  if [ "$MACREL_BUILD" = "<unreadable>" ] || [ -z "$MACREL_BUILD" ]; then
    echo "ERROR: release identity cannot read CURRENT_PROJECT_VERSION from $MACREL_YML" >&2
    return 1
  fi
  # The digest is a detector, and a detector that cannot read its input detects nothing
  # while comparing equal to itself forever. Refuse it up front.
  case "$MACREL_YML_SHA" in
    (''|'<missing>'|'<unreadable>')
      echo "ERROR: release identity cannot digest $MACREL_YML (got '${MACREL_YML_SHA:-<empty>}')" >&2
      echo "  Without it, a mid-run change to project.yml that keeps the version strings" >&2
      echo "  would go undetected — the check would compare one unreadable value to another." >&2
      return 1 ;;
  esac
  macrel_validate_commit_for_repo "$MACREL_REPO" "$MACREL_COMMIT" || return 1

  echo "→ release identity pinned: $MACREL_VERSION (build $MACREL_BUILD) @ ${MACREL_COMMIT:0:12} ($MACREL_HEAD_NAME)"
  echo "  app/project.yml sha256 ${MACREL_YML_SHA:0:12} · full commit $MACREL_COMMIT"
  if [ -n "$MACREL_PORCELAIN" ]; then
    echo "  note: the tree is dirty at pin time. A distributable build must be cut from a"
    echo "        committed state, or the stamped commit describes source that was never saved:"
    printf '%s\n' "$MACREL_PORCELAIN" | sed 's/^/    /'
  fi
  return 0
}

# --- assert ----------------------------------------------------------------

# macrel_assert <stage label>
# Prints a full explanation and returns 1 if anything identifying this build moved.
# Callers must `|| exit 1` — this is never a warning.
macrel_assert() {
  local stage="$1"
  local now_ver now_build now_sha now_head now_head_name now_porcelain moved=0

  now_ver="$(macrel_marketing_version "$MACREL_YML")"
  now_build="$(macrel_build_number "$MACREL_YML")"
  now_sha="$(macrel_yml_sha "$MACREL_YML")"
  now_head="$(macrel_head "$MACREL_REPO")"
  now_head_name="$(macrel_head_name "$MACREL_REPO")"
  now_porcelain="$(macrel_porcelain "$MACREL_REPO")" || now_porcelain="<unreadable>"

  [ "$now_ver"   = "$MACREL_VERSION" ] || moved=1
  [ "$now_build" = "$MACREL_BUILD" ]   || moved=1
  [ "$now_sha"   = "$MACREL_YML_SHA" ] || moved=1
  [ "$now_head"  = "$MACREL_COMMIT" ]  || moved=1

  if [ "$moved" = 0 ]; then
    echo "  release identity ok ($stage): still $MACREL_VERSION+$MACREL_BUILD @ ${MACREL_COMMIT:0:12}"
    return 0
  fi

  {
    echo
    echo "=============================================================================="
    echo "RELEASE ABORTED: the source moved while the build was running"
    echo "=============================================================================="
    echo "Checkpoint: $stage"
    echo
    echo "What was pinned when this run started, and what it is now:"
    if [ "$now_head" != "$MACREL_COMMIT" ]; then
      echo "  source commit       ${MACREL_COMMIT:0:12} ($MACREL_HEAD_NAME)  ->  ${now_head:0:12} ($now_head_name)"
      echo "                      *** THIS IS THE BUILD'S IDENTITY ***"
    else
      echo "  source commit       ${MACREL_COMMIT:0:12} ($MACREL_HEAD_NAME) (unchanged)"
    fi
    if [ "$now_ver" != "$MACREL_VERSION" ]; then
      echo "  MARKETING_VERSION   $MACREL_VERSION  ->  $now_ver"
    else
      echo "  MARKETING_VERSION   $MACREL_VERSION (unchanged)"
    fi
    if [ "$now_build" != "$MACREL_BUILD" ]; then
      echo "  build number        $MACREL_BUILD  ->  $now_build"
      echo "                      Sparkle keys updates on this; two builds sharing one number"
      echo "                      means installed copies are never offered the newer one."
    else
      echo "  build number        $MACREL_BUILD (unchanged)"
    fi
    if [ "$now_sha" != "$MACREL_YML_SHA" ]; then
      echo "  app/project.yml     sha256 ${MACREL_YML_SHA:0:12}  ->  ${now_sha:0:12}"
    else
      echo "  app/project.yml     sha256 ${MACREL_YML_SHA:0:12} (unchanged)"
    fi
    if [ "$now_porcelain" != "$MACREL_PORCELAIN" ]; then
      echo
      echo "  git status --porcelain now says:"
      if [ -n "$now_porcelain" ]; then
        printf '%s\n' "$now_porcelain" | sed 's/^/    /'
      else
        echo "    (clean)"
      fi
    fi
    echo
    echo "Continuing would stamp one commit into an app compiled from another, which is a"
    echo "worse outcome than the missing identity this guard was written to fix: a wrong"
    echo "answer is believed, a missing one is investigated."
    echo
    echo "NOTHING HAS BEEN PUBLISHED by this run. To recover:"
    echo "  1. Put the tree back where the release started:"
    echo "       git -C $MACREL_REPO checkout $MACREL_HEAD_NAME   # was ${MACREL_COMMIT:0:12}"
    echo "  2. Re-run ./scripts/publish.sh from a dedicated git worktree"
    echo "       (git worktree add ../baton-release <branch>)"
    echo "     so an unrelated branch switch in your main checkout cannot reach it."
    echo "  3. dist/ and /tmp/baton-release are scratch and are safe to delete."
    echo "=============================================================================="
    echo
  } >&2
  return 1
}

# macrel_dirty_path_verdict <path>
# Prints "FATAL <reason>" or "SAFE <reason>" for one uncommitted path.
#
# WHY THIS EXISTS. publish.sh edits two TRACKED files in place with `sed -i ''` AFTER
# the build and BEFORE the publish gate — Casks/baton.rb (version + sha256, step 4c)
# and website/index.html (version + DMG filename, step 4d) — and commits neither; the
# operator does that afterwards with the bump. A bare "refuse any dirt" rule therefore
# aborted a perfectly good release on the script's own edits, after the test gate, the
# build, the signing, the notarization and the DMG had all run. This tree has lost a
# release to that shape of thing before: see the AGENTS.md note in .gitignore, where an
# untracked file made the tree dirty and blocked a publish.
#
# The rule is about REACHABILITY, not about tidiness. The question a dirty path has to
# answer is only ever: can you change what ends up inside Baton.app? If yes, the
# stamped BatonSourceCommit would be a false claim about the binary and the release
# must stop. If provably no, the claim is still true and the release may proceed.
#
# Deliberately NOT a snapshot of the tree taken after the seds. A snapshot blesses
# whatever happened to be dirty at the instant it was taken, including a real source
# edit that landed a moment earlier, and it has to be re-taken by hand every time
# somebody adds another `sed -i ''`. A path rule stays true as the script grows.
#
# THE DEFAULT IS FATAL. An unclassified path is refused, not tolerated. Expressing
# this the other way round — "these roots are fatal, everything else is fine" — reads
# as safer and is not: the day somebody adds a new top-level directory of compiled
# source, a deny-list silently permits it while a fail-closed rule stops and asks. The
# cost of the default being wrong is a release that stops and prints the path; the cost
# of the other default being wrong is a shipped artifact whose identity is a lie.
macrel_dirty_path_verdict() {
  case "$1" in
    # --- reaches the binary -------------------------------------------------
    # app/         the Mac target: sources, project.yml, entitlements, xcconfig
    # Shared/      sources compiled into the Mac app (project.yml `sources:`)
    # Packages/    local SwiftPM modules linked into it
    (app/*|Shared/*|Packages/*)
      printf 'FATAL compiled into Baton.app' ;;
    # HELP.md / FAQ.md are at the REPO ROOT and are copied into the bundle by the
    # `Sync Help guides` pre-build script (app/project.yml). They are the reason this
    # cannot be a rule about directories: two build inputs live outside every source
    # root, and a deny-list of roots would have missed both.
    (HELP.md|FAQ.md)
      printf 'FATAL copied into the app bundle by the Sync Help guides pre-build script' ;;
    # scripts/ does not enter the DMG, but it decides how the DMG is made. An
    # uncommitted change here means the release is not reproducible from the commit
    # being stamped, which is the same promise broken one level up.
    (scripts/*)
      printf 'FATAL the release machinery itself would not be reproducible from the stamped commit' ;;
    # --- provably cannot reach the binary -----------------------------------
    # Rewritten by publish.sh step 4c. Homebrew metadata ABOUT the DMG — it records the
    # DMG's version and sha256 and is never inside it. Changing it cannot change a byte
    # of the app; it is consumed by `brew install` long after the artifact exists.
    (Casks/baton.rb)
      printf 'SAFE the cask describes the DMG and is never inside it (publish.sh step 4c)' ;;
    # Rewritten by publish.sh step 4d. The landing page is rsynced to the web host by
    # publish-site.sh as a separate act; it is not an input to any build phase.
    (website/index.html)
      printf 'SAFE the landing page is served separately and is never inside the DMG (publish.sh step 4d)' ;;
    # --- nobody has decided --------------------------------------------------
    (*)
      printf 'FATAL unclassified — nobody has recorded whether this can reach the DMG' ;;
  esac
}

# macrel_assert_production_ready
# The extra bar a build has to clear before it is allowed to leave this machine.
# Everything above says the source did not move; this says the source EXISTS — that
# the commit stamped into the app describes bytes that are actually committed, so
# somebody else can check out that revision and get this build back.
#
# Each dirty path is judged by macrel_dirty_path_verdict on one question: can it change
# what ends up inside Baton.app? Anything that can — and anything nobody has classified
# — aborts. The cask and the landing page provably cannot, so they do not.
macrel_assert_production_ready() {
  local now_porcelain line path verdict unexpected="" allowed_seen=""

  # An enumerator that could not run is not a clean tree. Check the status BEFORE
  # looking at the output, because the two failure modes produce identical output.
  if ! now_porcelain="$(macrel_porcelain "$MACREL_REPO")"; then
    {
      echo
      echo "RELEASE ABORTED: could not determine whether the tree is clean."
      echo
      echo "  git status could not be read in $MACREL_REPO (the reason is above)."
      echo "  This guard refuses rather than assumes: an unreadable tree and a clean tree"
      echo "  produce the same empty output, and treating them alike is how a dirty tree"
      echo "  ships stamped with a commit that does not describe it."
      echo
    } >&2
    return 1
  fi
  if [ -z "$now_porcelain" ]; then
    echo "  release identity ok (production): tree is clean, ${MACREL_COMMIT:0:12} is the whole build"
    return 0
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # git porcelain v1: two status characters, a space, then the path. A path git had
    # to quote (spaces, non-ASCII) arrives wrapped in double quotes; do not try to
    # unquote it — treat it as unclassified, which fails closed.
    path="${line:3}"
    case "$path" in
      ('"'*) unexpected="${unexpected}${line}    [quoted path — not classified]"$'\n'; continue ;;
    esac
    verdict="$(macrel_dirty_path_verdict "$path")"
    # Fail closed on anything that is not an explicit SAFE, including an empty verdict
    # from a classifier that has been broken or stubbed out.
    case "$verdict" in
      (SAFE\ *)  allowed_seen="${allowed_seen}${line}    [${verdict#SAFE }]"$'\n' ;;
      (FATAL\ *) unexpected="${unexpected}${line}    [${verdict#FATAL }]"$'\n' ;;
      (*)        unexpected="${unexpected}${line}    [classifier returned no verdict]"$'\n' ;;
    esac
  done <<EOF
$now_porcelain
EOF

  if [ -n "$unexpected" ]; then
    {
      echo
      echo "=============================================================================="
      echo "RELEASE ABORTED: uncommitted source changes would make the stamped identity false"
      echo "=============================================================================="
      echo
      echo "  This build claims BatonSourceCommit ${MACREL_COMMIT:0:12}, but the tree holds"
      echo "  changes that are not in that commit. Anyone who later checks out"
      echo "  ${MACREL_COMMIT:0:12} to reproduce a crash gets different source, and believes"
      echo "  they are looking at the right one."
      echo
      echo "  These can change what ends up inside Baton.app, or are unclassified:"
      printf '%s' "$unexpected" | sed 's/^/    /'
      if [ -n "$allowed_seen" ]; then
        echo
        echo "  (These are dirty too, but provably cannot reach the DMG, so they are fine:"
        printf '%s' "$allowed_seen" | sed 's/^/    /'
        echo "  )"
      fi
      echo
      echo "  Commit or stash the changes above, then re-run. Nothing has been published."
      echo
      echo "  If a path is marked 'unclassified' and genuinely cannot reach the DMG, add it"
      echo "  to macrel_dirty_path_verdict in scripts/release-identity.sh with the reason."
      echo "  The default is deliberately refuse-and-ask rather than allow-and-hope."
      echo
    } >&2
    return 1
  fi

  echo "  release identity ok (production): the only dirty paths cannot reach the DMG —"
  printf '%s' "$allowed_seen" | sed 's/^/    /'
  echo "    ${MACREL_COMMIT:0:12} is the whole compiled build"
  return 0
}
# --- read it back out of what was actually built ---------------------------

# macrel_assert_built_identity <path to Baton.app>
# The source-side checks say what the tree claims. This says what got COMPILED. It is
# the only check a working tree cannot fool — a tree that moved and moved back passes
# everything above and fails here — which is why it runs on the bundle that is about
# to be packaged, and again on the copy about to be published.
macrel_assert_built_identity() {
  local app="$1" plist="$1/Contents/Info.plist" built_commit="" built_ver="" built_build=""

  if [ ! -f "$plist" ]; then
    echo "ERROR: no Info.plist at $plist — cannot confirm what was built" >&2
    return 1
  fi

  # PlistBuddy prints nothing for both "no such key" and "the key is there and empty",
  # and those are different bugs: the first means project.yml never declared it, the
  # second means the build setting never reached xcodebuild. Keep the exit status so
  # the failure names the right one — a diagnosis that sends you to the wrong file
  # costs more than no diagnosis.
  local key_present=1
  built_commit="$(/usr/libexec/PlistBuddy -c 'Print :BatonSourceCommit' "$plist" 2>/dev/null)" || key_present=0
  built_ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
  built_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || true)"

  if ! macrel_is_valid_commit "$built_commit"; then
    {
      echo
      echo "=============================================================================="
      echo "RELEASE ABORTED: the built app carries no usable source identity"
      echo "=============================================================================="
      echo "  bundle                     $app"
      if [ "$key_present" = 0 ]; then
        echo "  BatonSourceCommit          <no such key in the Info.plist>"
        echo "  why that is refused        app/project.yml does not declare the key at all, so"
        echo "                             nothing could have been stamped. Fix project.yml, not"
        echo "                             the publish script."
      else
        echo "  BatonSourceCommit          ${built_commit:-<present but empty>}"
        echo "  why that is refused        $(macrel_describe_bad_commit "$built_commit")"
      fi
      echo "  expected                   $MACREL_COMMIT"
      echo
      echo "  This is exactly the state the live 0.17.12 build is in (TBX-5101): version"
      echo "  strings and nothing else, so no crash report from it can be tied to source"
      echo "  and no rollback target can be named. Do not ship another one."
      echo
      echo "  Check that publish.sh passes BATON_SOURCE_COMMIT=<sha> to xcodebuild and that"
      echo "  app/project.yml maps it to the BatonSourceCommit Info.plist key."
      echo "=============================================================================="
      echo
    } >&2
    return 1
  fi

  if [ "$built_commit" != "$MACREL_COMMIT" ]; then
    {
      echo
      echo "=============================================================================="
      echo "RELEASE ABORTED: the built app is not the commit this run started for"
      echo "=============================================================================="
      echo "  pinned source commit       $MACREL_COMMIT"
      echo "  commit inside the bundle   $built_commit"
      echo "  bundle                     $app"
      echo
      echo "  The tree moved between the pin and the compile. Nothing has been published."
      echo "  Delete /tmp/baton-release, put the tree back on the commit you meant to"
      echo "  release, and re-run from a dedicated git worktree."
      echo "=============================================================================="
      echo
    } >&2
    return 1
  fi

  if [ "$built_ver" != "$MACREL_VERSION" ] || [ "$built_build" != "$MACREL_BUILD" ]; then
    {
      echo
      echo "=============================================================================="
      echo "RELEASE ABORTED: the built app is not the version this run started for"
      echo "=============================================================================="
      echo "  pinned                     $MACREL_VERSION (build $MACREL_BUILD)"
      echo "  inside the bundle          ${built_ver:-<absent>} (build ${built_build:-<absent>})"
      echo "  bundle                     $app"
      echo
      echo "  The appcast, the cask and the landing page are all about to be written from"
      echo "  the pinned pair, so publishing this would advertise one release and serve"
      echo "  another. Nothing has been published."
      echo "=============================================================================="
      echo
    } >&2
    return 1
  fi

  echo "  release identity ok (built bundle): $built_ver+$built_build @ ${built_commit:0:12}, read back from Info.plist"
  return 0
}

# --- the artifact -> revision map ------------------------------------------

# macrel_write_identity_manifest <out-path> <dmg-path> <dmg-sha256> <dmg-length>
# The stamp inside the bundle is the authoritative record, but reading it costs a
# download and a mount. This is the cheap public index: served next to the DMG, it
# maps a distribution back to a revision from a single curl, which is the question
# the 2026-09-07 audit could not answer for 0.17.12.
#
# It is a convenience, never the proof. The bundle is the proof; the manifest is a
# claim about it that anyone can re-derive with `hdiutil attach` + PlistBuddy.
macrel_write_identity_manifest() {
  local out="$1" dmg="$2" sha="$3" len="$4"
  cat > "$out" <<EOF
# Baton macOS release identity
# Verify independently:
#   hdiutil attach -readonly -nobrowse <dmg> -mountpoint /tmp/m
#   /usr/libexec/PlistBuddy -c 'Print :BatonSourceCommit' /tmp/m/Baton.app/Contents/Info.plist
product: Baton (macOS)
bundle_id: io.tonebox.baton
version: $MACREL_VERSION
build: $MACREL_BUILD
source_commit: $MACREL_COMMIT
dmg: $(basename "$dmg")
dmg_sha256: $sha
dmg_length: $len
generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
  echo "  identity manifest -> $out"
}
