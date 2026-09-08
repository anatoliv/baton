#!/bin/bash
#
# Release identity guard — refuse to keep building if the working tree moves
# underneath a running release.
#
# WHY THIS EXISTS (TBX-5058, 2026-09-07). The 1.0.14 version bump was committed to a
# branch, `./ios/scripts/testflight.sh` was launched from that checkout, and then
# `git checkout main` was run in the SAME working tree while the build was still
# going, to merge an unrelated PR. `main` still said MARKETING_VERSION 1.0.13. The
# archive silently picked that up and uploaded a second, different 1.0.13 to App
# Store Connect. Nothing noticed: the script ran green to a successful upload, and
# it left project.yml with duplicated signing keys because the transient patch this
# script applies was made against a file that changed under it.
#
# The guard pins what the build IS at the start, and re-asserts it at the points
# where continuing would waste real time or do real damage.
#
# WHAT IS PINNED, and why not just HEAD:
#   - MARKETING_VERSION resolved from ios/project.yml. This is the thing that must
#     not change — it is what gets compiled in and what App Store Connect keys on.
#   - the sha256 of ios/project.yml itself, which catches a change that keeps the
#     version string but alters signing, bundle ids or targets.
#   - git HEAD, which names the commit and catches a switch that happens to land on
#     the same version. HEAD alone is NOT sufficient (a release may legitimately be
#     cut from a detached HEAD or a tag, and two commits can carry the same version),
#     which is why it is one signal of three rather than the check.
#
# WHAT TBX-5102 ADDED, and why the above was not already enough.
#
# Everything above compares the tree against itself. It proves the tree did not move
# during the run; it proves nothing about the artifact once the artifact has left the
# machine. The live App Store build (version 1.0, build 1786816974, uploaded
# 2026-08-15) is the demonstration: it carries a version string, a build number and
# nothing else, so the question "which revision is the thing buyers are running built
# from" has exactly one honest answer, which is unknown. A git tag is a movable
# pointer somebody typed. An App Store Connect build number is assigned by
# `date +%s` at upload time and is not derived from source at all.
#
# So the pinned HEAD is now three things it was not before:
#   - VALIDATED at pin time (rg_validate_commit_for_repo): exactly 40 lowercase ASCII
#     hex characters, and an object that actually exists in this repo. A wrong
#     identity is worse than a missing one, because a wrong one gets believed.
#   - STAMPED into the compiled app, as the BatonSourceCommit Info.plist key, fed by
#     the BATON_SOURCE_COMMIT build setting testflight.sh passes to xcodebuild.
#   - READ BACK OUT of the app bundle inside the archive
#     (release_assert_archive_identity), which is the only check a working tree
#     cannot fool: a tree that moved and moved back passes every source-side
#     assertion above and fails this one.
#
# And a build that stamps a commit has to be able to stand behind it, which is what
# release_assert_production_ready is for: a commit baked into an app compiled from
# uncommitted edits is a false claim, not an identity.
#
# NOTE ON WHAT THIS CANNOT DO. Build 1786816974 predates all of it and carries no
# embedded identity. Nothing here makes that build self-attesting, and no tag or
# local archive should be stretched into a substitute — the honest record is that the
# live build's source revision is unproven, and that the NEXT one will not be.
#   - `git status --porcelain`, kept as CONTEXT only and never fatal. The build
#     itself writes into the tree, so a porcelain delta is not by itself evidence of
#     a switch; it is printed when a fatal signal fires because it usually explains it.
#
# THE DELIBERATE MUTATION. testflight.sh patches ios/project.yml for manual signing
# in step 2 and restores it in the exit trap. A naive digest would fire on the
# script's own edit, so the pin is explicitly re-taken there via
# release_repin_project_yml. Every later assertion compares against the patched
# file, which means a mid-run branch switch is still caught: `git checkout` either
# reverts the patch or duplicates keys into it, and both move the digest.
#
# Sourced by ios/scripts/testflight.sh. Also driven directly, with no build and no
# Apple involvement, by ios/scripts/test-release-guard.sh — which is how we know it
# fires.

# --- readers ---------------------------------------------------------------

# Resolve MARKETING_VERSION the same way scripts/publish.sh does, so the two
# releases agree on what "the version" means.
rg_marketing_version() {
  local v=""
  [ -f "$1" ] && v="$(perl -ne 'print $1 if /^\s*MARKETING_VERSION:\s*"([^"]+)"/' "$1" | head -1)"
  printf '%s' "${v:-<unreadable>}"
}

rg_yml_sha() {
  [ -f "$1" ] || { printf '%s' "<missing>"; return; }
  shasum -a 256 "$1" | awk '{print $1}'
}

rg_head() { git -C "$1" rev-parse HEAD 2>/dev/null || printf '%s' "<not-a-git-checkout>"; }

# A human name for HEAD: the branch if on one, else the tag or bare sha. Only ever
# used in messages — the sha above is what is compared.
rg_head_name() {
  local n
  n="$(git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null)" && { printf '%s' "$n"; return; }
  n="$(git -C "$1" describe --tags --exact-match HEAD 2>/dev/null)" && { printf 'detached at tag %s' "$n"; return; }
  printf 'detached'
}

rg_porcelain() { git -C "$1" status --porcelain 2>/dev/null | LC_ALL=C sort; }

# --- the identity rule (TBX-5102) ------------------------------------------

# rg_is_valid_commit <string>
# The ONLY accepted shape is exactly 40 lowercase ASCII hex characters.
#
# ASCII is not decoration in that sentence. The obvious "is it a digit / is it hex"
# test in most languages is Unicode-aware and accepts characters git will never emit:
# Swift's Character.isNumber is true for the Arabic-Indic digits ٠-٩ and for a dozen
# other digit families, so a validator written the obvious way admits strings that
# cannot be a git object id and then compares unequal to every real one. The bash
# equivalent is the locale: bracket expressions are collation-driven under a UTF-8
# locale, so the range check below is run with LC_ALL=C, byte-wise, deliberately.
#
# Each refused shape is a real way this goes wrong:
#
#   ""                          the build setting never reached xcodebuild
#   "$(BATON_SOURCE_COMMIT)"    passed but never expanded — the failure that looks
#                               most like success, because the key IS present
#   "dev"/"unknown"/"HEAD"      a placeholder somebody typed to get a build through
#   "local"/"none"/"dirty"
#   "56134326"                  abbreviated. Short hashes collide, and git's default
#                               abbreviation length grows with the repository, so a
#                               prefix that is unique today may not be next year
#   "56134326AB…"               uppercase. Downstream compares these as strings; two
#                               spellings of one commit is two commits
#   "not-a-sha", "٠١٢…"        non-hex, and non-ASCII digits in particular
rg_is_valid_commit() {
  # TWO independent defences, because one of them is a single point of failure.
  #
  # The set is ENUMERATED rather than written as the range `a-f`. A collated range is
  # not the set of characters it looks like: under en_US.UTF-8 the collation order
  # interleaves the cases (aAbBcCdDeEfF...), so `[!0-9a-f]` does not flag uppercase
  # A-E as outside the set at all — only F falls out, because it sorts after lowercase
  # f. An uppercase hash containing no F is therefore ACCEPTED by the range spelling,
  # and a test fixture that happens to contain an F hides it. This is not theoretical:
  # it was measured on the macOS guard, which shares this shape, and its suite passed
  # throughout because the chosen uppercase fixture had six Fs in it.
  #
  # LC_ALL=C in a subshell makes the comparison byte-wise, which fixes it on its own.
  # The enumeration is kept anyway because the locale is one assignment away from
  # being wrong — an exported LC_ALL from a caller, a refactor that drops the
  # subshell — and enumeration stays correct without it. The failure mode being
  # defended against is a silently wrong locale, so the second defence must not
  # itself depend on the locale.
  ( LC_ALL=C
    case "$1" in
      ('')                        exit 1 ;;
      (*[!0123456789abcdef]*)     exit 1 ;;   # not lowercase ASCII hex: uppercase, '$', UTF-8 bytes
    esac
    [ "${#1}" -eq 40 ] )
}

# rg_describe_bad_commit <string> — one line saying WHY it was refused, so whoever
# reads the failure does not have to re-derive the rule from the code.
rg_describe_bad_commit() {
  local c="$1"
  # Enumerated sets and LC_ALL=C, for the reasons in rg_is_valid_commit — and this is
  # the function where the omission was actually caught. With the range spelling
  # `[A-F]` under en_US.UTF-8, every lowercase abbreviated hash reported itself as
  # "uppercase hex", because the collated range spans b, c, d, e and f too. That sent
  # the reader after a spelling problem that did not exist. A subshell, so the
  # caller's locale is untouched.
  ( LC_ALL=C
  case "$c" in
    ('')                                printf 'empty — the BATON_SOURCE_COMMIT build setting never reached the build' ;;
    (*'$('*|*'${'*)                     printf 'an unexpanded build-setting template — the key is present but was never substituted' ;;
    (dev|unknown|HEAD|local|none|dirty) printf 'the placeholder %s' "$c" ;;
    (*[!0123456789abcdefABCDEF]*)       printf 'not hexadecimal (or not ASCII — a non-ASCII digit is not a git object id)' ;;
    (*[ABCDEF]*)                        printf 'uppercase hex — the canonical form git prints is lowercase' ;;
    (*)                                 printf '%s characters, not 40 — an abbreviated hash is ambiguous and gets more so as the repo grows' "${#c}" ;;
  esac )
}

# rg_validate_commit_for_repo <repo-root> <candidate>
# The full admission test: the right shape AND an object that exists here. Both
# halves are needed — shape alone accepts a plausible fiction (40 hex characters
# somebody typed), and existence alone cannot be asked of a string git refuses to
# parse. Kept as its own function, rather than inlined into the pin, so that
# test-release-guard.sh can drive it with a well-formed sha that is not a commit,
# which is not a state a real checkout can be put into.
rg_validate_commit_for_repo() {
  local repo="$1" candidate="$2"
  if ! rg_is_valid_commit "$candidate"; then
    {
      echo "ERROR: refusing to release — there is no usable source identity to stamp into the app."
      echo "  the candidate revision reads as: '$candidate'"
      echo "  that is $(rg_describe_bad_commit "$candidate")."
      echo "  A Baton.ipa that cannot name its own revision is unrollbackable and its crash"
      echo "  reports are unattributable — which is the state the live App Store build"
      echo "  (1.0, build 1786816974) is in and cannot be got out of. Do not ship another."
    } >&2
    return 1
  fi
  # `cat-file -e <sha>^{commit}` and not `rev-parse --verify`: rev-parse happily
  # resolves a 40-hex string that names a tree or a blob, and it resolves refs, so a
  # branch called after a hash would pass. This asks the one question that matters —
  # is there a COMMIT object with exactly this id in this repository.
  if ! git -C "$repo" cat-file -e "${candidate}^{commit}" 2>/dev/null; then
    {
      echo "ERROR: $candidate is well-formed but is not a commit in $repo."
      echo "  Stamping it would put a revision into the app that nobody can check out."
    } >&2
    return 1
  fi
  return 0
}

# --- pin -------------------------------------------------------------------

# release_pin <repo-root> <path-to-project.yml>
# Call once, as early as possible — before the preflight gate, which is the longest
# window in the run and the one the 2026-09-07 switch happened inside.
release_pin() {
  RG_REPO="$1"
  RG_YML="$2"
  RG_VERSION="$(rg_marketing_version "$RG_YML")"
  RG_YML_SHA="$(rg_yml_sha "$RG_YML")"
  RG_HEAD="$(rg_head "$RG_REPO")"
  RG_HEAD_NAME="$(rg_head_name "$RG_REPO")"
  RG_PORCELAIN="$(rg_porcelain "$RG_REPO")"

  # RG_COMMIT is the same string as RG_HEAD, under the name the rest of the release
  # uses for it. RG_HEAD is "the thing that must not move"; RG_COMMIT is "the identity
  # stamped into the app". They are one value with two jobs, and testflight.sh hands
  # RG_COMMIT to xcodebuild as BATON_SOURCE_COMMIT. (TBX-5102)
  RG_COMMIT="$RG_HEAD"
  # Which paths the release is allowed to have dirtied by the time production runs.
  # Nothing, until the run explicitly says otherwise. See release_allow_release_edit.
  RG_ALLOWED_DIRTY=""

  if [ "$RG_VERSION" = "<unreadable>" ]; then
    echo "ERROR: release guard cannot read MARKETING_VERSION from $RG_YML" >&2
    return 1
  fi
  # The commit is validated HERE, at the pin, and not later: every downstream check
  # compares against this value, so an unusable one poisons all of them silently.
  rg_validate_commit_for_repo "$RG_REPO" "$RG_COMMIT" || return 1
  echo "→ release pinned: version $RG_VERSION, HEAD ${RG_HEAD:0:8} ($RG_HEAD_NAME), project.yml ${RG_YML_SHA:0:12}"
  echo "  source commit $RG_COMMIT"
  if [ -n "$RG_PORCELAIN" ]; then
    echo "  note: the tree is already dirty at pin time — a release should be cut from a committed state:"
    printf '%s\n' "$RG_PORCELAIN" | sed 's/^/    /'
  fi
  return 0
}

# Re-take the project.yml digest after this script's OWN deliberate edit of it.
# Anything that moves the file after this point is somebody else.
release_repin_project_yml() {
  RG_YML_SHA="$(rg_yml_sha "$RG_YML")"
  RG_PORCELAIN="$(rg_porcelain "$RG_REPO")"
  echo "  release guard: project.yml re-pinned after the manual-signing patch (${RG_YML_SHA:0:12})"
}

# --- assert ----------------------------------------------------------------

# release_assert <stage label>
# Prints a full explanation and returns 1 if anything that identifies this build has
# moved. Callers should `|| exit 1` — this must never be a warning.
release_assert() {
  local stage="$1"
  local now_ver now_sha now_head now_head_name now_porcelain moved=0

  now_ver="$(rg_marketing_version "$RG_YML")"
  now_sha="$(rg_yml_sha "$RG_YML")"
  now_head="$(rg_head "$RG_REPO")"
  now_head_name="$(rg_head_name "$RG_REPO")"
  now_porcelain="$(rg_porcelain "$RG_REPO")"

  [ "$now_ver"  = "$RG_VERSION" ] || moved=1
  [ "$now_sha"  = "$RG_YML_SHA" ] || moved=1
  [ "$now_head" = "$RG_HEAD" ]    || moved=1

  if [ "$moved" = 0 ]; then
    echo "  release guard ok ($stage): still $RG_VERSION @ ${RG_HEAD:0:8}"
    return 0
  fi

  {
    echo
    echo "=============================================================================="
    echo "RELEASE ABORTED: the working tree moved while the build was running"
    echo "=============================================================================="
    echo "Checkpoint: $stage"
    echo
    echo "What was pinned when this run started, and what it is now:"
    if [ "$now_ver" != "$RG_VERSION" ]; then
      echo "  MARKETING_VERSION   $RG_VERSION  ->  $now_ver      *** THIS IS THE BUILD'S IDENTITY ***"
    else
      echo "  MARKETING_VERSION   $RG_VERSION (unchanged)"
    fi
    if [ "$now_head" != "$RG_HEAD" ]; then
      echo "  git HEAD            ${RG_HEAD:0:8} ($RG_HEAD_NAME)  ->  ${now_head:0:8} ($now_head_name)"
    else
      echo "  git HEAD            ${RG_HEAD:0:8} ($RG_HEAD_NAME) (unchanged)"
    fi
    if [ "$now_sha" != "$RG_YML_SHA" ]; then
      echo "  ios/project.yml     sha256 ${RG_YML_SHA:0:12}  ->  ${now_sha:0:12}"
    else
      echo "  ios/project.yml     sha256 ${RG_YML_SHA:0:12} (unchanged)"
    fi
    if [ "$now_porcelain" != "$RG_PORCELAIN" ]; then
      echo
      echo "  git status --porcelain now says:"
      if [ -n "$now_porcelain" ]; then
        printf '%s\n' "$now_porcelain" | sed 's/^/    /'
      else
        echo "    (clean)"
      fi
    fi
    echo
    echo "Continuing would ship a build that is not the one you asked for. On 2026-09-07"
    echo "exactly this went unnoticed and put a second, different 1.0.13 into App Store"
    echo "Connect (TBX-5058), which had to be expired by hand."
    echo
    echo "NOTHING HAS BEEN UPLOADED by this run. To recover:"
    echo "  1. Put the tree back where the release started:"
    echo "       git -C $RG_REPO checkout $RG_HEAD_NAME     # was ${RG_HEAD:0:8}"
    echo "     then check 'git diff -- ios/project.yml' is empty: a switch during step 2"
    echo "     can leave this script's transient signing keys behind in the file."
    echo "  2. Re-run ./ios/scripts/testflight.sh, and cut the release from a dedicated"
    echo "     git worktree (git worktree add ../baton-release <branch>) so an unrelated"
    echo "     branch switch in your main checkout cannot reach it."
    echo "  3. If this fired AFTER step 6, check App Store Connect for a stray build."
    echo "     ios/build/ is a scratch directory and is safe to delete."
    echo "=============================================================================="
    echo
  } >&2
  return 1
}

# --- the production bar: is the stamped commit actually true? (TBX-5102) ----

# Which roots can change the bytes that get compiled into the .ipa, or the bytes of
# the gate that vouches for it. Dirty here is FATAL on a production run, because the
# commit stamped into the app would then describe source that was never saved —
# anyone who checks that revision out to reproduce a crash gets different code and
# believes they are looking at the right one.
#
# Expressed as what is FATAL rather than what is ignorable, on purpose. An ignore
# list fails open: the day somebody adds a top-level directory that compiles, it is
# absent from the list and is therefore silently permitted. Here the default for
# anything unclassified is fatal (see rg_path_class), so a new directory has to be
# argued INTO the benign list by a person before a release will accept it dirty.
RG_FATAL_ROOTS="ios Shared Packages app watch gateway scripts tools .github HELP.md FAQ.md"

# The SAFE list, and it is a list of arguments rather than a list of paths.
#
# Each entry carries the reason that root cannot reach the compiled bytes, because the
# reason is the part that has to be true. A bare list invites an entry to be added to
# make a release go through, and nothing about a bare list makes that visible; an entry
# that has to state why is one somebody has to actually think about, and the reason is
# printed next to the path when a benign change is reported, so a wrong one is legible
# at the moment it matters rather than only in review.
#
# HELP.md and FAQ.md are deliberately NOT here — see RG_FATAL_ROOTS. They live at the
# repo root, look exactly like prose, and are copied into ios/Resources by the Sync
# Help prebuild step on every build, so they ship inside the app. A rule that reasons
# about "source directories" waves them straight through, and the resulting build has
# help text the stamped commit does not describe while the gate reports success. The
# generalisation worth carrying: read the preBuildScripts, because a build input does
# not have to live under a source root.
RG_BENIGN_ROOTS="
docs|prose; nothing under it is compiled, and no build step reads it
website|the marketing site, published on its own and never bundled
Casks|the macOS Homebrew cask; not an input to any iOS build
design|design sources; the app reads Assets.xcassets, not this
screenshots|App Store screenshots, uploaded to the listing rather than compiled in
specs|written specifications, read by people
deploy|gateway deployment config; nothing here reaches the phone
.claude|agent tooling and worktrees, outside the build entirely
README.md|repo prose; the bundled guides are HELP.md and FAQ.md, which are FATAL
LICENSE|not copied into Resources, so it is not in the bundle
CLAUDE.md|repo runbook
HANDOFF.md|repo prose
ORCHESTRATION-PLAN.md|repo prose
.gitignore|changes what git tracks, not what the compiler reads
"

# rg_benign_reason <root> — the stated reason, or empty if the root is not on the list.
rg_benign_reason() {
  local root="$1" line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "${line%%|*}" = "$root" ] && { printf '%s' "${line#*|}"; return 0; }
  done <<EOF
$RG_BENIGN_ROOTS
EOF
  return 1
}

# release_allow_release_edit <path>...
# Declare the exact tracked paths this release script is itself permitted to have
# rewritten by the time the production check runs.
#
# There is exactly one today: ios/project.yml, which step 2 patches for manual signing
# and the exit trap restores. Allowing it does NOT open a hole, because it is the one
# path already covered by an independent and stronger check — release_repin_project_yml
# takes its sha256 immediately after the script's own edit, and every later
# release_assert compares against that digest. A foreign change to project.yml is
# caught there whether or not the dirty check would have caught it.
#
# Exact paths, never prefixes: a prefix would bless a whole subtree, which is the
# failure this whole function exists to avoid.
release_allow_release_edit() {
  RG_ALLOWED_DIRTY="$(printf '%s\n' "$@")"
  echo "  release guard: the release script's own edits may touch these paths, and only these:"
  printf '    %s\n' "$@"
}

# Exact-path membership in the declared allowlist. Fails closed on anything it cannot
# match, including the empty list.
rg_is_allowed_dirty_path() {
  local candidate="$1" allowed
  [ -n "${RG_ALLOWED_DIRTY:-}" ] || return 1
  while IFS= read -r allowed; do
    [ -n "$allowed" ] || continue
    [ "$allowed" = "$candidate" ] && return 0
  done <<EOF
$RG_ALLOWED_DIRTY
EOF
  return 1
}

# rg_path_class <path> -> prints "allowed" | "fatal" | "benign"
# The default is fatal. Reaching "benign" takes an explicit entry in
# RG_BENIGN_ROOTS; everything else — a new top-level directory, a path git had to
# quote, a rename line — lands on fatal without anyone having to predict it.
rg_path_class() {
  local path="$1" root r

  # A path git had to quote (spaces, non-ASCII) arrives wrapped in double quotes, and
  # a rename arrives as `old -> new`. Do not try to unpick either: classify as fatal,
  # which is the safe answer and prints the raw line for the operator to read.
  case "$path" in
    ('"'*)   printf 'fatal'; return ;;
    (*' -> '*) printf 'fatal'; return ;;
  esac

  if rg_is_allowed_dirty_path "$path"; then printf 'allowed'; return; fi

  root="${path%%/*}"
  for r in $RG_FATAL_ROOTS; do
    [ "$r" = "$root" ] && { printf 'fatal'; return; }
  done
  rg_benign_reason "$root" >/dev/null && { printf 'benign'; return; }
  printf 'fatal'
}

# release_assert_production_ready <what this run will do>
# The extra bar a build clears before it is allowed to leave the machine. Everything
# above says the source did not MOVE; this says the source EXISTS — that the commit
# about to be stamped into the app describes bytes somebody else can check out and
# get this build back from.
#
# Called twice by testflight.sh on purpose, and the two calls prove different halves:
# once immediately after the pin, where the tree must be wholly clean because the
# script has not touched anything yet, and once before the upload, where
# ios/project.yml is legitimately dirty from step 2's own patch. A check that only
# ever ran in the clean case would never have exercised the carve-out it depends on.
release_assert_production_ready() {
  local doing="${1:-this run}"
  local now_porcelain line path class unexpected="" expected="" noted=""

  now_porcelain="$(rg_porcelain "$RG_REPO")"
  if [ -z "$now_porcelain" ]; then
    echo "  release guard ok (production): tree is clean, ${RG_COMMIT:0:12} is the whole build"
    return 0
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # git porcelain v1: two status characters, a space, then the path.
    path="${line:3}"
    class="$(rg_path_class "$path")"
    case "$class" in
      (allowed) expected="${expected}${line}"$'\n' ;;
      (benign)  noted="${noted}${line}   [safe: $(rg_benign_reason "${path%%/*}")]"$'\n' ;;
      (*)       unexpected="${unexpected}${line}"$'\n' ;;
    esac
  done <<EOF
$now_porcelain
EOF

  if [ -n "$unexpected" ]; then
    {
      echo
      echo "=============================================================================="
      echo "RELEASE ABORTED: uncommitted changes would make the stamped identity false"
      echo "=============================================================================="
      echo "Checkpoint: $doing"
      echo
      echo "  This build would claim BatonSourceCommit ${RG_COMMIT:0:12}, but the tree holds"
      echo "  changes that are not in that commit. A commit id is only an identity if the"
      echo "  source it names is the source that was compiled; otherwise it is a false"
      echo "  claim, and a false claim is worse than the missing one it replaced, because"
      echo "  the missing one gets investigated and the false one gets believed."
      echo
      echo "  Not accounted for (anything under a compiled root, plus anything this guard"
      echo "  has no classification for — unclassified fails closed):"
      printf '%s' "$unexpected" | sed 's/^/    /'
      if [ -n "$expected" ]; then
        echo
        echo "  (These are the release script's own declared edits and are expected:"
        printf '%s' "$expected" | sed 's/^/    /'
        echo "  )"
      fi
      if [ -n "$noted" ]; then
        echo
        echo "  (These are outside anything that compiles and are not why this aborted:"
        printf '%s' "$noted" | sed 's/^/    /'
        echo "  )"
      fi
      echo
      echo "  Commit or stash the changes above and re-run. Nothing has been uploaded."
      echo "  If they belong to someone else's work in this checkout, do NOT stash or"
      echo "  reset — cut the release from a dedicated worktree instead:"
      echo "       git -C $RG_REPO worktree add ../baton-release $RG_HEAD_NAME"
      echo "=============================================================================="
      echo
    } >&2
    return 1
  fi

  echo "  release guard ok (production): only declared or non-compiled paths are modified —"
  [ -n "$expected" ] && printf '%s' "$expected" | sed 's/^/    /'
  [ -n "$noted" ] && printf '%s' "$noted" | sed 's/^/    /'
  echo "    ${RG_COMMIT:0:12} is the whole compiled build"
  return 0
}

# --- read the identity back out of what was actually compiled --------------

# rg_archive_app <archive path> — the .app inside an .xcarchive.
# ApplicationProperties:ApplicationPath is the archive's own record of where its
# product lives ("Applications/Baton.app"), so ask it rather than hardcoding a name
# that changes the day PRODUCT_NAME does. Falls back to the conventional path so a
# malformed archive still produces a "no Info.plist" diagnosis rather than an empty one.
rg_archive_app() {
  local archive="$1" plist="$1/Info.plist" rel=""
  [ -f "$plist" ] && rel="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:ApplicationPath' "$plist" 2>/dev/null || true)"
  printf '%s' "$archive/Products/${rel:-Applications/Baton.app}"
}

# release_assert_archive_identity <archive path>
# release_assert_archive_version (below) reads the archive's OWN summary plist, which
# Xcode writes. This reads the Info.plist inside the app bundle that is about to be
# packaged into the .ipa — the actual compiled bytes, the ones a buyer downloads.
#
# It is the only check in this file a working tree cannot fool. Every source-side
# assertion compares the tree against a snapshot of itself, so a tree that moved and
# moved back passes all of them; this one asks the artifact.
release_assert_archive_identity() {
  local archive="$1" app plist built_commit="" key_present=1

  app="$(rg_archive_app "$archive")"
  plist="$app/Info.plist"
  if [ ! -f "$plist" ]; then
    echo "ERROR: no Info.plist at $plist — cannot confirm what source was built" >&2
    return 1
  fi

  # PlistBuddy prints an empty string both for "no such key" and for "the key is there
  # and holds an empty string", and those are different bugs pointing at different
  # files: the first means ios/project.yml never declared the key, the second means
  # BATON_SOURCE_COMMIT never reached xcodebuild. Keep the exit status so the failure
  # names the right one — a diagnosis that sends you to the wrong file costs more than
  # no diagnosis at all.
  built_commit="$(/usr/libexec/PlistBuddy -c 'Print :BatonSourceCommit' "$plist" 2>/dev/null)" || key_present=0

  if ! rg_is_valid_commit "$built_commit"; then
    {
      echo
      echo "=============================================================================="
      echo "RELEASE ABORTED: the built app carries no usable source identity"
      echo "=============================================================================="
      echo "  bundle                     $app"
      if [ "$key_present" = 0 ]; then
        echo "  BatonSourceCommit          <no such key in the Info.plist>"
        echo "  why that is refused        ios/project.yml does not declare the key at all, so"
        echo "                             nothing could have been stamped. Fix project.yml,"
        echo "                             not testflight.sh."
      else
        echo "  BatonSourceCommit          ${built_commit:-<present but empty>}"
        echo "  why that is refused        $(rg_describe_bad_commit "$built_commit")"
      fi
      echo "  expected                   $RG_COMMIT"
      echo
      echo "  This is the state the live App Store build is in (1.0, build 1786816974,"
      echo "  uploaded 2026-08-15): version strings and nothing else, so no crash from it"
      echo "  can be tied to source and no rollback target can be named. That build cannot"
      echo "  be fixed after the fact. Do not upload a second one like it."
      echo
      echo "  Check that testflight.sh passes BATON_SOURCE_COMMIT=<sha> to xcodebuild and"
      echo "  that ios/project.yml maps it to the BatonSourceCommit Info.plist key."
      echo "=============================================================================="
      echo
    } >&2
    return 1
  fi

  if [ "$built_commit" != "$RG_COMMIT" ]; then
    {
      echo
      echo "=============================================================================="
      echo "RELEASE ABORTED: the built app is not the commit this run started for"
      echo "=============================================================================="
      echo "  pinned source commit       $RG_COMMIT"
      echo "  commit inside the bundle   $built_commit"
      echo "  bundle                     $app"
      echo
      echo "  The tree moved between the pin and the compile. Nothing has been uploaded."
      echo "  Delete ios/build, put the tree back on the commit you meant to release, and"
      echo "  re-run from a dedicated git worktree."
      echo "=============================================================================="
      echo
    } >&2
    return 1
  fi

  echo "  release guard ok (archive identity): built from ${built_commit:0:12}, read back from the bundle"
  return 0
}

# release_assert_archive_version <archive path>
# The source-side checks above say what the tree claims; this says what actually got
# compiled. Reading the version back out of the built archive is the only check that
# cannot be fooled by a tree that moved and moved back, so it runs immediately before
# the upload — the last moment where refusing is still free.
release_assert_archive_version() {
  local archive="$1" plist="$1/Info.plist" built=""
  if [ ! -f "$plist" ]; then
    echo "ERROR: no Info.plist in $archive — cannot confirm what version was built" >&2
    return 1
  fi
  built="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
  if [ -z "$built" ]; then
    echo "ERROR: $plist has no ApplicationProperties:CFBundleShortVersionString" >&2
    return 1
  fi
  if [ "$built" != "$RG_VERSION" ]; then
    {
      echo
      echo "=============================================================================="
      echo "RELEASE ABORTED: the archive is not the version this run started for"
      echo "=============================================================================="
      echo "  pinned MARKETING_VERSION   $RG_VERSION"
      echo "  version inside the archive $built"
      echo "  archive                    $archive"
      echo
      echo "The tree moved between the pin and the compile, so the .ipa about to be"
      echo "uploaded would land in App Store Connect as $built. That is the TBX-5058"
      echo "failure. Nothing has been uploaded."
      echo
      echo "Delete ios/build, put the tree back on the commit you meant to release, and"
      echo "re-run from a dedicated git worktree."
      echo "=============================================================================="
      echo
    } >&2
    return 1
  fi
  echo "  release guard ok (archive): built version $built matches the pin"
  return 0
}
