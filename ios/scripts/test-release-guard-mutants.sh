#!/bin/bash
#
# Does test-release-guard.sh actually test the guard?
#
# A suite that is green against a guard which does nothing is not a suite. This breaks
# each guard function in turn — `return 0` planted as its first statement, so it
# accepts everything — and requires ios/scripts/test-release-guard.sh to go RED for
# each. A function whose mutant survives has no assertion depending on it, and is
# decoration until one is written.
#
#   ./ios/scripts/test-release-guard-mutants.sh          # table + verdict
#   ./ios/scripts/test-release-guard-mutants.sh -v       # plus the suite output
#
# WHY THIS EXISTS, and it is not hypothetical. Writing the TBX-5102 additions, two
# assertions looked like coverage and were not:
#
#   - a case that called `git cat-file` itself and asserted on its exit status. It was
#     testing git, and it passed against a guard that never called anything.
#   - `rg_describe_bad_commit`, which only ever prints. Every test asserted on exit
#     status, so the mutant survived — and behind that gap sat a real bug: the case
#     arm `[A-F]` is collation-driven, and under en_US.UTF-8 it spans lowercase b-f
#     too, so every abbreviated lowercase hash reported itself as "uppercase hex".
#     The mutant table is what said the message needed asserting; the assertion is
#     what found the bug.
#
# The list of functions is read out of release-guard.sh rather than hardcoded, so a
# guard function added later is covered — or shows up here as a survivor — without
# anyone remembering to add it.
#
# No build, no Apple, no network. About as long as the suite times the number of
# functions, which is a few seconds.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$DIR/release-guard.sh"
SUITE="$DIR/test-release-guard.sh"
VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

WORK="$(mktemp -d -t baton-guard-mutants)"
trap 'rm -rf "$WORK"' EXIT INT TERM

# Sanity, and the one result that invalidates everything below: the unmutated suite
# has to be green, or a red mutant proves nothing.
if ! "$SUITE" >"$WORK/baseline.txt" 2>&1; then
  echo "ABORT: the suite is already red before any mutation — fix that first." >&2
  tail -30 "$WORK/baseline.txt" >&2
  exit 1
fi
echo "baseline: $(grep -o '[0-9]* passed, [0-9]* failed' "$WORK/baseline.txt" | tail -1)"
echo

# The real guard is never edited — mutants are written to $WORK and the suite is
# pointed at them with RELEASE_GUARD_PATH. That is deliberate and not a detail: a
# runner that edits the file in place can leave a planted `return 0` behind after a
# clean run, and an operator reads "all killed" and walks away with a disabled guard
# in their working tree. This records the guard's digest now and re-checks it at the
# end, so the claim is verified rather than asserted in a comment.
GUARD_SHA_BEFORE="$(shasum -a 256 "$GUARD" | awk '{print $1}')"

FUNCS="$(grep -oE '^[a-z_]+\(\) \{' "$GUARD" | sed 's/() {//')"
KILLED=0
SURVIVED=0
SURVIVORS=""

printf '%-38s %s\n' "MUTANT (return 0 planted first)" "SUITE"
printf '%-38s %s\n' "--------------------------------------" "-----"

for fn in $FUNCS; do
  MUT="$WORK/$fn.sh"
  # Plant `return 0` as the function's first statement. Two shapes to handle: a
  # multi-line definition, where the opening line is exactly `name() {`, and a
  # one-liner like `rg_head() { git ...; }`, where the whole body follows the brace on
  # the same line. The one-liners are not a detail — rg_head and rg_porcelain are both
  # written that way, and an earlier version of this script silently failed to mutate
  # them and reported them as survivors.
  #
  # awk rather than `sed -i` so the real guard is never touched, even for an instant.
  awk -v target="$fn() {" '
    index($0, target) == 1 && $0 == target {
      print; print "  return 0   # MUTANT"; next
    }
    index($0, target) == 1 {
      print target " return 0;   # MUTANT" substr($0, length(target) + 1); next
    }
    { print }
  ' "$GUARD" > "$MUT"

  if ! grep -q "MUTANT" "$MUT"; then
    printf '%-38s %s\n' "$fn" "ERROR: could not plant the mutation"
    SURVIVED=$((SURVIVED + 1))
    SURVIVORS="$SURVIVORS $fn(unplanted)"
    continue
  fi

  if RELEASE_GUARD_PATH="$MUT" "$SUITE" >"$WORK/$fn.out" 2>&1; then
    printf '%-38s %s\n' "$fn" "SURVIVED  <- nothing asserts on this"
    SURVIVED=$((SURVIVED + 1))
    SURVIVORS="$SURVIVORS $fn"
  else
    printf '%-38s %s   (%s)\n' "$fn" "killed" \
      "$(grep -o '[0-9]* passed, [0-9]* failed' "$WORK/$fn.out" | tail -1)"
    KILLED=$((KILLED + 1))
  fi
  [ "$VERBOSE" = 1 ] && sed 's/^/      | /' "$WORK/$fn.out"
done


# --- site mutants -----------------------------------------------------------
#
# Function-level mutation answers "is this function tested at all". It cannot tell a
# test that pins the SITE it names from one that passes for a neighbouring reason —
# the tautology shape, where an assertion is true for a reason other than the intended
# one and the intended one also happens to hold. Such a test stays green after the
# thing it claims to check is deleted, and reading it never reveals that; only a
# surviving mutant does.
#
# So each entry below neutralises ONE comparison and requires the suite to go red.
# They are the comparisons an extension to an existing guard is most likely to get
# false credit for: this guard already pinned and compared a version and a digest
# before any of the identity work existed, so a test could be green because of that
# machinery rather than because of anything added.
#
# Each literal must appear EXACTLY once. A miss is a hard error, not a survivor —
# "the mutation could not be planted" and "the mutation was planted and nothing
# noticed" are different results and must not be reported as the same one.
# Fields are separated by `~~` and not by `|`, because two of these literals contain
# `||`. An earlier version split on `|` and reported three sites as unplantable —
# which is the right report for a literal that does not match, and the reason a miss
# is a hard error here rather than a survivor.
cat > "$WORK/sites.txt" <<'TABLE'
the pin refuses an unusable commit~~  rg_validate_commit_for_repo "$RG_REPO" "$RG_COMMIT" || return 1~~  :
the shape rule rejects non-hex bytes~~      (*[!0123456789abcdef]*)     exit 1 ;;   # not lowercase ASCII hex: uppercase, '$', UTF-8 bytes~~      (*[!0123456789abcdef]*) : ;;
the shape rule requires 40 characters~~    [ "${#1}" -eq 40 ] )~~    true )
the commit must exist in this repo~~  if ! git -C "$repo" cat-file -e "${candidate}^{commit}" 2>/dev/null; then~~  if false; then
the built bundle's commit is validated~~  if ! rg_is_valid_commit "$built_commit"; then~~  if false; then
the built bundle's commit is COMPARED to the pin~~  if [ "$built_commit" != "$RG_COMMIT" ]; then~~  if false; then
the allowlist is consulted before the roots~~  if rg_is_allowed_dirty_path "$path"; then printf 'allowed'; return; fi~~  if false; then printf 'allowed'; return; fi
the classifier is not always-SAFE~~  local path="$1" root r~~  local path="$1" root r; printf 'benign'; return
unclassified paths default to fatal~~  printf 'fatal'~~  printf 'benign'
a fatal root is fatal~~    [ "$r" = "$root" ] && { printf 'fatal'; return; }~~    [ "$r" = "$root" ] && { printf 'benign'; return; }
unexpected dirt aborts the release~~  if [ -n "$unexpected" ]; then~~  if false; then
TABLE

echo
printf '%-52s %s\n' "SITE MUTANT (one comparison neutralised)" "SUITE"
printf '%-52s %s\n' "----------------------------------------------------" "-----"

SITE_N=0
while IFS= read -r row; do
  [ -n "$row" ] || continue
  label="${row%%~~*}"
  rest="${row#*~~}"
  from="${rest%%~~*}"
  to="${rest#*~~}"
  SITE_N=$((SITE_N + 1))
  MUT="$WORK/site-$SITE_N.sh"
  hits="$(awk -v f="$from" '$0 == f { n++ } END { print n + 0 }' "$GUARD")"
  if [ "$hits" != "1" ]; then
    printf '%-52s %s\n' "$label" "ERROR: literal matched $hits lines, expected 1"
    SURVIVED=$((SURVIVED + 1))
    SURVIVORS="$SURVIVORS site:$SITE_N(unplantable)"
    continue
  fi
  awk -v f="$from" -v t="$to" '{ print ($0 == f ? t : $0) }' "$GUARD" > "$MUT"
  if RELEASE_GUARD_PATH="$MUT" "$SUITE" >"$WORK/site-$SITE_N.out" 2>&1; then
    printf '%-52s %s\n' "$label" "SURVIVED  <- no test pins this comparison"
    SURVIVED=$((SURVIVED + 1))
    SURVIVORS="$SURVIVORS site:$label"
  else
    printf '%-52s %s   (%s)\n' "$label" "killed" \
      "$(grep -o '[0-9]* passed, [0-9]* failed' "$WORK/site-$SITE_N.out" | tail -1)"
    KILLED=$((KILLED + 1))
  fi
  [ "$VERBOSE" = 1 ] && sed 's/^/      | /' "$WORK/site-$SITE_N.out"
done < "$WORK/sites.txt"

# --- historical replay ------------------------------------------------------
#
# Mutation asks "would the suite notice if this were broken". This asks the sharper
# question: would it have noticed the bug that was actually here. The pre-fix spelling
# of the two hex checks used collated ranges (`[!0-9a-f]`, `[A-F]`) with no LC_ALL, and
# under a UTF-8 locale a collated `a-f` spans uppercase A-E — so an uppercase hash with
# no F was ACCEPTED by the identity rule, and every abbreviated lowercase hash was
# diagnosed as an uppercase problem.
#
# Reconstructing that spelling and requiring the suite to go red keeps the regression
# tests honest as the file is refactored. It is also the check that caught this suite's
# own defect: the first version of in_locale used `LC_ALL=x fn args`, which does not
# make bash re-read the locale for a function call, so all three locale variants ran
# under one. Against the real guard that passed and looked fine; against this replay
# the [C] cases failed, which is impossible if C were genuinely in effect.
echo
echo "historical replay: the pre-fix collated-range spelling must still go red"
REPLAY="$WORK/pre-fix-collation.sh"
sed -e 's/(\*\[!0123456789abcdef\]\*)/(*[!0-9a-f]*)/' \
    -e 's/(\*\[!0123456789abcdefABCDEF\]\*)/(*[!0-9a-fA-F]*)/' \
    -e 's/(\*\[ABCDEF\]\*)/(*[A-F]*)/' \
    -e 's/^  ( LC_ALL=C$/  (/' "$GUARD" > "$REPLAY"
if cmp -s "$REPLAY" "$GUARD"; then
  echo "  ERROR: the replay is identical to the guard — the spellings it rewrites are gone," >&2
  echo "  so this check silently proves nothing. Update the sed or delete it." >&2
  SURVIVED=$((SURVIVED + 1))
  SURVIVORS="$SURVIVORS historical-replay(inert)"
elif RELEASE_GUARD_PATH="$REPLAY" "$SUITE" >"$WORK/replay.out" 2>&1; then
  echo "  SURVIVED: the suite is green against the spelling that accepted uppercase hashes" >&2
  SURVIVED=$((SURVIVED + 1))
  SURVIVORS="$SURVIVORS historical-replay"
else
  echo "  killed   ($(grep -o '[0-9]* passed, [0-9]* failed' "$WORK/replay.out" | tail -1))"
  echo "  and the failures are the UTF-8 locales, as they should be — a C-only suite" 
  echo "  would have been green against this:"
  grep -c '^FAIL.*UTF-8' "$WORK/replay.out" | sed 's/^/    UTF-8 cases that fired: /'
  KILLED=$((KILLED + 1))
fi

GUARD_SHA_AFTER="$(shasum -a 256 "$GUARD" | awk '{print $1}')"
echo
if [ "$GUARD_SHA_BEFORE" = "$GUARD_SHA_AFTER" ]; then
  echo "release-guard.sh is byte-identical to before this run (${GUARD_SHA_AFTER:0:12})"
else
  echo "FATAL: this run modified release-guard.sh and left it modified." >&2
  echo "  Restore it before doing anything else — the working tree may hold a" >&2
  echo "  disabled guard: git checkout -- $GUARD" >&2
  exit 1
fi

echo
echo "=== $KILLED killed, $SURVIVED survived ==================================="
if [ "$SURVIVED" -ne 0 ]; then
  echo "survivors:$SURVIVORS" >&2
  echo "A function survivor is one the suite cannot tell from a no-op. A site" >&2
  echo "survivor is a comparison no test pins — usually a test that matches a" >&2
  echo "pattern rather than the site it claims to check. An (unplantable) entry" >&2
  echo "is neither: the literal no longer matches the guard and the mutation was" >&2
  echo "never applied, so that row proved nothing and the table is incomplete." >&2
  exit 1
fi
