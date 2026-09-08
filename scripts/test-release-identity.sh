#!/bin/bash
#
# Drive scripts/release-identity.sh directly and watch it fail.
#
# A guard nobody has seen fire is decoration, and this one guards a claim that only
# matters when it is false — an app that names the wrong commit is worse than one
# that names none, because the wrong name is believed. So exercise it against a
# throwaway git repo and synthetic Info.plists: no Xcode, no archive, no Apple, no
# network, about a second.
#
#   ./scripts/test-release-identity.sh
#
# Exit 0 = every case behaved as expected. Pass -v to see the guard's own output.
#
# Deliberately standalone rather than folded into scripts/test.sh: this needs no
# simulator, no signing and no build, so making it wait behind a ten-minute Xcode
# gate would mean it stops being run. scripts/publish.sh calls it at the top of a
# release, which is the moment its answer is actually load-bearing.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

# Everything --prove-it could conceivably write to. Compared BEFORE and AFTER a run
# rather than checked for cleanliness: a developer may legitimately have uncommitted
# work in this tree, and demanding a clean tree would both fail for them and — worse —
# train people to read "modified" as "leftover mutant" and discard it. Mistaking real
# in-progress work for a planted mutant is how a refactor got destroyed on 2026-09-07.
# Before-and-after answers the only question that matters: did THIS RUN change anything?
macrel_harness_fingerprint() {
  local f
  for f in release-identity.sh test-release-identity.sh publish.sh; do
    [ -f "$DIR/$f" ] && shasum -a 256 "$DIR/$f"
  done
  return 0
}

# ------------------------------------------------------- --prove-it-selftest
# Does the mutation harness clean up after itself?
#
# WHY THIS EXISTS (2026-09-07). A sibling lane's harness planted its `return 0` edits
# IN PLACE and left them there after a successful run, so an operator could read
# "8 killed, 0 survived" and walk away with a disabled guard in the tree; the next
# release would pass checks that were no longer running. This harness has never worked
# that way — mutants are written into a temp directory and the guard is only ever read
# — but "has never" is a claim about the past, and the whole point of this file is that
# unobserved properties decay. So check it, including on the interrupted path, where a
# missing trap would show up and a normal run would not.
#
#   ./scripts/test-release-identity.sh --prove-it-selftest
#
# Kept out of the default suite because it runs --prove-it twice and takes tens of
# seconds, where the default suite is a second and gates every release.
if [ "${1:-}" = "--prove-it-selftest" ]; then
  DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SPASS=0; SFAIL=0
  scheck() {  # <label> <expected: same|changed> <before> <after>
    local label="$1" want="$2" got="same"
    [ "$3" = "$4" ] || got="changed"
    if [ "$got" = "$want" ]; then
      echo "PASS  [$got] $label"; SPASS=$((SPASS + 1))
    else
      echo "FAIL  expected $want, got $got — $label"; SFAIL=$((SFAIL + 1))
      diff <(printf '%s\n' "$3") <(printf '%s\n' "$4") | sed 's/^/      | /'
    fi
  }
  macrel_harness_fingerprint() {
    local f
    for f in release-identity.sh test-release-identity.sh publish.sh; do
      [ -f "$DIR/$f" ] && shasum -a 256 "$DIR/$f"
    done
    return 0
  }

  echo "=== does the mutation harness clean up after itself? ===================="
  echo

  # 1. A run that completes normally.
  B="$(macrel_harness_fingerprint)"
  "$DIR/test-release-identity.sh" --prove-it >/dev/null 2>&1
  scheck "a completed --prove-it leaves the scripts it tested untouched" same "$B" "$(macrel_harness_fingerprint)"

  # 2. A run killed part-way. This is the case a missing trap fails and a normal run
  #    passes, so it is the one worth the seconds it costs.
  B="$(macrel_harness_fingerprint)"
  "$DIR/test-release-identity.sh" --prove-it >/dev/null 2>&1 &
  PI_PID=$!
  sleep 3
  kill -TERM "$PI_PID" 2>/dev/null
  wait "$PI_PID" 2>/dev/null
  scheck "an INTERRUPTED --prove-it leaves the scripts it tested untouched" same "$B" "$(macrel_harness_fingerprint)"

  # 3. ...and the hygiene check must be able to FAIL, or it is the same decoration this
  #    whole file exists to rule out. Build a sandbox copy of the three scripts, sabotage
  #    the copy so it writes each mutant over its own guard, and require it to notice.
  #    Nothing outside the sandbox is touched.
  SBOX="$(mktemp -d -t baton-harness-sabotage)"
  trap 'rm -rf "$SBOX"' EXIT INT TERM
  cp "$DIR/release-identity.sh" "$DIR/test-release-identity.sh" "$DIR/publish.sh" "$SBOX/"
  perl -0pi -e 's{(\n\s+# A mutation that did not land)}{\n    cp "\$MUTANT" "\$DIR/release-identity.sh"$1}' \
    "$SBOX/test-release-identity.sh"
  if ! grep -q 'cp "\$MUTANT" "\$DIR/release-identity.sh"' "$SBOX/test-release-identity.sh"; then
    echo "FAIL  could not build the sabotaged harness — the injection point moved"; SFAIL=$((SFAIL + 1))
  else
    SB_OUT="$SBOX/out.txt"
    "$SBOX/test-release-identity.sh" --prove-it >"$SB_OUT" 2>&1
    SB_RC=$?
    if [ "$SB_RC" -ne 0 ] && grep -q "HARNESS FAULT" "$SB_OUT"; then
      echo "PASS  [red] a harness that DOES write in place is caught and named"
      SPASS=$((SPASS + 1))
    else
      echo "FAIL  a sabotaged harness went unnoticed (exit $SB_RC) — the hygiene check is decoration"
      SFAIL=$((SFAIL + 1))
      tail -20 "$SB_OUT" | sed 's/^/      | /'
    fi
  fi

  echo
  echo "=== $SPASS passed, $SFAIL failed ======================================="
  [ "$SFAIL" -eq 0 ]
  exit $?
fi

# ---------------------------------------------------------------- --prove-it
# A suite that has only ever been green proves nothing about the guard; it proves
# the suite runs. So break the guard on purpose, one function at a time, and require
# the suite to notice each time.
#
# This is the second half of "a guard nobody has seen fire is decoration": seeing it
# fire once, by hand, is a fact about one afternoon. Making the proof a command means
# it keeps being true — a case deleted, a rule loosened, or an assert that silently
# stopped being reachable all show up here as a mutant the suite fails to kill.
#
#   ./scripts/test-release-identity.sh --prove-it
#
# Each mutant is a copy of release-identity.sh with `return 0` planted at the top of
# one function, so that check always passes. A surviving mutant means nothing in the
# suite depends on that function refusing anything.
if [ "${1:-}" = "--prove-it" ]; then
  MWORK="$(mktemp -d -t baton-release-identity-mutants)"
  # INT/TERM as well as EXIT: an interrupted run must not leave mutants behind either.
  trap 'rm -rf "$MWORK"' EXIT INT TERM
  # Mutants are written into MWORK and the real guard is only ever READ (perl -p, not
  # -i). Prove that rather than assert it: a harness that proves guards work must never
  # leave one disabled, and "8 killed, 0 survived" printed over a sabotaged guard is
  # exactly the reassuring output somebody would walk away from.
  HARNESS_BEFORE="$(macrel_harness_fingerprint)"
  echo "=== can this guard actually fail? ======================================="
  echo
  echo "Baseline (the real guard):"
  BASE_OUT="$MWORK/base.txt"
  MACREL_GUARD="$DIR/release-identity.sh" "$DIR/test-release-identity.sh" >"$BASE_OUT" 2>&1
  BASE_RC=$?
  BASE_LINE="$(grep -E '^=== [0-9]+ passed' "$BASE_OUT" | sed -E 's/=+//g; s/^ *| *$//g')"
  echo "  $BASE_LINE  (exit $BASE_RC)"
  if [ "$BASE_RC" -ne 0 ]; then
    echo "  the real guard is already failing its own suite — fix that before proving anything" >&2
    exit 1
  fi
  echo
  KILLED=0
  SURVIVED=0
  # <function>|<line planted at the top of it>. Most guards decay by always agreeing,
  # which `return 0` models. A guard that PRINTS its verdict decays differently: it
  # keeps answering, and the answer is always the permissive one. Both are modelled.
  for spec in \
    "macrel_porcelain|return 0" \
    "macrel_yml_sha|return 0" \
    "macrel_head|return 0" \
    "macrel_marketing_version|return 0" \
    "macrel_build_number|return 0" \
    "macrel_is_valid_commit|return 0" \
    "macrel_describe_bad_commit|return 0" \
    "macrel_validate_commit_for_repo|return 0" \
    "macrel_assert|return 0" \
    "macrel_assert_production_ready|return 0" \
    "macrel_dirty_path_verdict|printf 'SAFE nothing here can reach the DMG'; return 0" \
    "macrel_dirty_path_verdict|return 0" \
    "macrel_assert_built_identity|return 0" \
    "macrel_write_identity_manifest|return 0"
  do
    fn="${spec%%|*}"
    planted="${spec#*|}"
    MUTANT="$MWORK/$fn.$(printf '%s' "$planted" | tr -c 'a-zA-Z0-9' '_' | cut -c1-24).sh"
    # Plant the line immediately after the function's opening brace, so the check is
    # present, sourced, called — and toothless. That is the realistic decay mode: a
    # guard that still runs and always agrees.
    # Deliberately does NOT require a newline after the brace. macrel_head is written on
    # one line, and the earlier `\{\n` form silently failed to plant anything in it. The
    # "could not mutate" branch below caught that rather than reporting a false KILLED —
    # but a mutant the harness cannot plant is an untested guard either way, which is the
    # same "looked for nothing" shape as the bug this round is about.
    perl -0pe "s/^\\Q${fn}\\E\\(\\) \\{/${fn}() {\\n  ${planted}\\n/m" \
      "$DIR/release-identity.sh" > "$MUTANT"
    # A mutation that did not land would look exactly like a killed mutant for the
    # wrong reason, so confirm the file actually changed before drawing a conclusion.
    if diff -q "$DIR/release-identity.sh" "$MUTANT" >/dev/null 2>&1; then
      echo "ERROR  could not mutate $fn — the function signature did not match" >&2
      SURVIVED=$((SURVIVED + 1))
      continue
    fi
    OUT="$MWORK/$fn.txt"
    MACREL_GUARD="$MUTANT" "$DIR/test-release-identity.sh" >"$OUT" 2>&1
    RC=$?
    LINE="$(grep -E '^=== [0-9]+ passed' "$OUT" | sed -E 's/=+//g; s/^ *| *$//g')"
    if [ "$RC" -ne 0 ]; then
      printf 'KILLED    %-32s %-46s -> %s\n' "$fn" "{ $planted }" "${LINE:-suite aborted}"
      KILLED=$((KILLED + 1))
    else
      printf 'SURVIVED  %-32s %-46s -> %s\n' "$fn" "{ $planted }" "${LINE:-?}"
      echo "          Nothing in the suite depends on this check refusing anything."
      SURVIVED=$((SURVIVED + 1))
    fi
  done
  echo
  HARNESS_AFTER="$(macrel_harness_fingerprint)"
  if [ "$HARNESS_AFTER" != "$HARNESS_BEFORE" ]; then
    {
      echo "HARNESS FAULT: these scripts changed while the run was in progress."
      echo
      diff <(printf '%s\n' "$HARNESS_BEFORE") <(printf '%s\n' "$HARNESS_AFTER") | sed 's/^/    /'
      echo
      echo "  Why this is checked: a mutation run that reports mutants killed while having"
      echo "  left one planted is the worst possible output — it reads as reassurance over a"
      echo "  disabled guard, and the next publish.sh would pass checks that are no longer"
      echo "  running."
      echo
      echo "  BUT THIS CANNOT TELL WHO CHANGED THEM, and the two causes want opposite"
      echo "  responses. A planted mutant should be discarded. A concurrent edit — another"
      echo "  session, or your own work in progress — must NOT be, and twice on 2026-09-07 a"
      echo "  reader assumed 'modified' meant 'leftover mutant' and destroyed real work with"
      echo "  a blanket checkout. Working-tree state has no reflog."
      echo
      echo "  So READ THE DIFF FIRST. A planted mutant is a bare 'return 0' (or a printf of a"
      echo "  fixed verdict) inserted immediately after a function's opening brace, and"
      echo "  nothing else. Anything that looks like real work is real work."
      echo "    git -C \"$DIR/..\" diff -- scripts/"
    } >&2
    exit 1
  fi
  echo "  harness hygiene ok: release-identity.sh, test-release-identity.sh and publish.sh"
  echo "  are byte-identical to what they were before the run"
  echo
  echo "=== $KILLED mutants killed, $SURVIVED survived ==========================="
  [ "$SURVIVED" -eq 0 ]
  exit $?
fi

# The guard under test. Overridable so `--prove-it` below can point the whole suite
# at a deliberately broken copy and check that the suite notices — see there for why
# that is not a curiosity but the only evidence these cases are load-bearing.
GUARD="${MACREL_GUARD:-$DIR/release-identity.sh}"
# shellcheck source=/dev/null
. "$GUARD"

WORK="$(mktemp -d -t baton-release-identity-test)"
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/out.txt"
PASS=0
FAIL=0

yml() {  # $1 = version, $2 = build -> an app/project.yml shaped like the real one
  cat <<EOF
name: Baton
settings:
  base:
    SWIFT_VERSION: "6.0"
    MARKETING_VERSION: "$1"
    CURRENT_PROJECT_VERSION: "$2"
    BATON_SOURCE_COMMIT: ""
EOF
}

# A built Baton.app, in miniature: the only part the guard reads is Contents/Info.plist.
# $1 = bundle dir, $2 = version, $3 = build, $4 = the BatonSourceCommit value
# (pass the literal string __ABSENT__ to omit the key entirely).
built_app() {
  local app="$1" ver="$2" build="$3" commit="$4"
  rm -rf "$app"; mkdir -p "$app/Contents"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "  <key>CFBundleShortVersionString</key><string>$ver</string>"
    echo "  <key>CFBundleVersion</key><string>$build</string>"
    if [ "$commit" != "__ABSENT__" ]; then
      # Escape the one character that would break the XML; nothing we pass needs more.
      echo "  <key>BatonSourceCommit</key><string>$(printf '%s' "$commit" | sed 's/&/\&amp;/g')</string>"
    fi
    echo '</dict></plist>'
  } > "$app/Contents/Info.plist"
  printf '%s' "$app"
}

fresh_repo() {  # a repo on branch release-0.17.13 at 0.17.13/98, plus a main at 0.17.12/97
  local r="$WORK/repo"
  rm -rf "$r"; mkdir -p "$r/app"
  git -C "$r" init -q -b main
  git -C "$r" config user.email t@example.com
  git -C "$r" config user.name t
  yml "0.17.12" "97" > "$r/app/project.yml"
  # The two version-pinned surfaces publish.sh rewrites in place mid-run, shaped so the
  # real sed expressions in steps 4c/4d match them.
  mkdir -p "$r/Casks" "$r/website" "$r/Shared" "$r/app/Sources/Baton"
  cat > "$r/Casks/baton.rb" <<'CASK'
cask "baton" do
  version "0.17.12,97"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  url "https://baton.tonebox.io/Baton-#{version.csv.first}.dmg"
end
CASK
  cat > "$r/website/index.html" <<'SITE'
<p class="eyebrow">Version 0.17.12</p>
<a href="https://baton.tonebox.io/Baton-0.17.12.dmg">Download for macOS</a>
SITE
  echo "// compiled source" > "$r/Shared/CrashReporting.swift"
  echo "// compiled source" > "$r/app/Sources/Baton/App.swift"
  # The two build inputs that live at the repo ROOT: the Sync Help guides pre-build
  # script copies these into the bundle, so a dirty one changes the shipped app.
  echo "# Baton help" > "$r/HELP.md"
  echo "# Baton FAQ" > "$r/FAQ.md"
  git -C "$r" add -A && git -C "$r" commit -qm "0.17.12"
  git -C "$r" checkout -q -b release-0.17.13
  yml "0.17.13" "98" > "$r/app/project.yml"
  git -C "$r" add -A && git -C "$r" commit -qm "0.17.13"
  printf '%s' "$r"
}

# publish.sh steps 4c and 4d, in miniature — the SAME sed expressions, against the
# same two paths, leaving them modified and uncommitted exactly as the real run does.
publish_bookkeeping_edits() {  # $1 = repo, $2 = version, $3 = build, $4 = dmg sha256
  local r="$1" version="$2" build="$3" sha="$4"
  /usr/bin/sed -i '' -E \
      -e "s/^  version \"[0-9.]+(,[0-9]+)?\"/  version \"${version},${build}\"/" \
      -e "s/^  sha256 \"[0-9a-f]{64}\"/  sha256 \"${sha}\"/" \
      "$r/Casks/baton.rb"
  /usr/bin/sed -i '' -E \
      -e "s|(<p class=\"eyebrow\">Version )[0-9]+\.[0-9]+\.[0-9]+(</p>)|\1${version}\2|" \
      -e "s|Baton-[0-9]+\.[0-9]+\.[0-9]+\.dmg|Baton-${version}.dmg|g" \
      "$r/website/index.html"
}

# Run a guard and keep everything it printed, discarding its exit status — for the
# cases that assert on WHAT a refusal says rather than on the fact that it refused.
# Note the shape: a refusal's non-zero exit is expected here, so the output is captured
# first and matched separately. Piping the guard into grep would hand the pipeline the
# guard's own exit status under `pipefail` and report a correct diagnosis as a failure.
say() {
  local out
  out="$("$@" 2>&1)" || true
  printf '%s' "$out"
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

echo "=== macOS release identity guard: does it actually fire? ================"
echo

# ============================================================ the identity rule
# Cheapest layer first: the predicate every other check is built on.
for good in \
  "83ccbe9d8bb707cf937a6a1f6f9836f1f2bf7b11" \
  "0000000000000000000000000000000000000000" \
  "ffffffffffffffffffffffffffffffffffffffff"
do
  expect green "commit rule accepts 40-char lowercase hex ($( printf '%.8s' "$good")…)" -- \
    macrel_is_valid_commit "$good"
done

for bad in \
  "" \
  '$(BATON_SOURCE_COMMIT)' \
  "unknown" \
  "HEAD" \
  "83ccbe9d" \
  "83ccbe9d8bb707cf937a6a1f6f9836f1f2bf7b1" \
  "83ccbe9d8bb707cf937a6a1f6f9836f1f2bf7b111" \
  "83CCBE9D8BB707CF937A6A1F6F9836F1F2BF7B11" \
  "83ccbe9d8bb707cf937a6a1f6f9836f1f2bf7b1Z" \
  "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
do
  expect red "commit rule refuses '${bad:-<empty>}'" -- macrel_is_valid_commit "$bad"
done

echo

# ================================ the enumerator must FIND, not merely not accuse
# THE VACUOUS-PASS CLASS. A guard that decides by enumerating bad things and passing
# when the list is empty treats "found nothing" and "looked for nothing" as the same
# answer. macrel_porcelain used to pipe through `sort`, so with sort absent from PATH
# the last stage produced no stdout, `2>/dev/null` hid the reason, and a demonstrably
# dirty tree was declared clean. Measured before the fix: PATH=/tmp/emptybin turned
# "refused" into "PASSED".
#
# Every other case in this file asserts that a guard REFUSES. None asserted that the
# enumerator FINDS, which is why nothing caught it. These do.
shadow_bin() {  # a PATH entry whose tools all fail, so a dependency on them is visible
  local b="$WORK/shadowbin" t
  mkdir -p "$b"
  for t in sort awk shasum; do
    printf '#!/bin/sh\necho "%s: deliberately broken" >&2\nexit 127\n' "$t" > "$b/$t"
    chmod +x "$b/$t"
  done
  printf '%s' "$b"
}

R="$(fresh_repo)"
macrel_pin "$R" "$R/app/project.yml" >/dev/null
echo "// an uncommitted source change" > "$R/app/Sources/Baton/Dirty.swift"

enumerator_finds_the_dirty_path() { grep -q "app/Sources/Baton/Dirty.swift" <<<"$(say macrel_porcelain "$R")"; }
expect green "PRODUCTIVITY: the enumerator actually finds a known dirty path" -- \
  enumerator_finds_the_dirty_path

# The same, with sort/awk/shasum replaced by stubs that fail. Proves the enumeration
# does not depend on anything a broken PATH can take away.
SHADOW="$(shadow_bin)"
enumerator_finds_it_without_coreutils() {
  ( export PATH="$SHADOW:$PATH"; grep -q "app/Sources/Baton/Dirty.swift" <<<"$(say macrel_porcelain "$R")" )
}
refuses_without_coreutils() { ( export PATH="$SHADOW:$PATH"; ! macrel_assert_production_ready >/dev/null 2>&1 ); }
expect green "the enumerator still finds it with sort/awk/shasum broken" -- \
  enumerator_finds_it_without_coreutils
expect green "the production check still refuses with sort/awk/shasum broken" -- \
  refuses_without_coreutils

# And when git itself cannot be reached, it must FAIL CLOSED — an unreadable tree and a
# clean tree produce identical empty output, so the status is the only thing that
# separates them.
mkdir -p "$WORK/emptybin"
refuses_when_git_is_unreachable() {
  ( export PATH="$WORK/emptybin"; ! macrel_assert_production_ready >/dev/null 2>&1 )
}
enumerator_reports_failure_not_cleanliness() {
  ( export PATH="$WORK/emptybin"; ! macrel_porcelain "$R" >/dev/null 2>&1 )
}
expect green "the enumerator returns non-zero when git cannot be run" -- \
  enumerator_reports_failure_not_cleanliness
expect green "FAILS CLOSED: an unreadable tree is refused, not read as clean" -- \
  refuses_when_git_is_unreachable

git -C "$R" checkout -q -- . 2>/dev/null; rm -f "$R/app/Sources/Baton/Dirty.swift"
expect green "a genuinely clean tree still passes (status 0, empty output)" -- \
  macrel_assert_production_ready
expect red "the enumerator returns non-zero for a directory that is not a repo" -- \
  macrel_porcelain "$WORK"

# ------------------------------------------------- the digest is a detector too
# Same class, quieter symptom: macrel_yml_sha was `shasum | awk`, so with either tool
# missing it returned "". The pin and every later assertion would both hold "", "" would
# compare equal to "", and the project.yml digest check would report ok forever while
# detecting nothing. A detector that cannot read its input must say so.
yml_sha_is_64_hex() {
  local d; d="$(macrel_yml_sha "$R/app/project.yml")"
  [ "${#d}" -eq 64 ] && [ -z "${d//[0-9a-f]/}" ]
}
yml_sha_says_unreadable_without_shasum() {
  ( export PATH="$SHADOW:$PATH"; [ "$(macrel_yml_sha "$R/app/project.yml")" = "<unreadable>" ] )
}
pin_refuses_an_unreadable_digest() {
  ( export PATH="$SHADOW:$PATH"; ! macrel_pin "$R" "$R/app/project.yml" >/dev/null 2>&1 )
}
expect green "the digest is a real 64-char hex value" -- yml_sha_is_64_hex
expect green "the digest reports <unreadable> rather than empty when shasum is gone" -- \
  yml_sha_says_unreadable_without_shasum
expect green "the pin refuses an unreadable digest instead of comparing it to itself" -- \
  pin_refuses_an_unreadable_digest

echo

# ============================================== the identity rule, per LOCALE
# A shell bracket RANGE is collation-driven. Under en_US.UTF-8 the collation
# interleaves the cases (a, A, b, B, c, C …), so `[a-f]` also spans A-E, and
# `macrel_is_valid_commit` ACCEPTED 40-character uppercase hashes — the exact thing it
# exists to refuse. The uppercase case above passed anyway, for the wrong reason: its
# fixture contains an `F`, and F alone sorts outside the collated range. So test an
# uppercase hash with NO `F`, and test under a UTF-8 locale explicitly rather than
# whatever the runner happens to have set.
with_locale() {  # $1 = locale, rest = the command to run under it
  local loc="$1"; shift
  ( export LC_ALL="$loc"; "$@" )
}
refuses_commit() { ! macrel_is_valid_commit "$1"; }
describes_as() {  # $1 = candidate, $2 = substring the diagnosis must contain
  grep -q "$2" <<<"$(say macrel_describe_bad_commit "$1")"
}

# Which of the locales we care about this machine actually has. tr_TR.UTF-8 is the
# classic case-folding locale and was added on lane-5102's evidence after it tested
# there and I had not.
#
# A loop over locales is itself a place a suite can pass vacuously: if none of them
# resolved, every case below would silently not run and the suite would still be green
# — the same "looked for nothing" shape as the porcelain bug. So collect what is
# present and assert the count, rather than trusting the loop to have had something to
# iterate over.
# Note the shape: `locale -a` is captured FIRST and matched with a case, rather than
# piped into `grep -qx`. Under `pipefail` that pipeline returns 141 on success — grep -q
# exits the moment it matches, `locale -a` dies on the closed pipe with SIGPIPE, and the
# pipeline reports the signal rather than the match. Written the obvious way, every
# locale was reported absent and this whole matrix silently collapsed to C. Which is the
# same class as the bug this round is about: a status that does not mean what it looks
# like, quietly emptying an enumeration.
MACREL_TEST_LOCALES="C"
MACREL_LOCALES_AVAILABLE="$(locale -a 2>/dev/null)" || MACREL_LOCALES_AVAILABLE=""
for loc in en_US.UTF-8 tr_TR.UTF-8; do
  case "
$MACREL_LOCALES_AVAILABLE
" in
    (*"
$loc
"*) MACREL_TEST_LOCALES="$MACREL_TEST_LOCALES $loc" ;;
  esac
done
enough_locales_to_be_meaningful() {
  # C alone cannot see a collation bug — under C the broken and fixed guards agree —
  # so at least one UTF-8 locale must have resolved for these cases to mean anything.
  [ "$(printf '%s\n' $MACREL_TEST_LOCALES | wc -l | tr -d ' ')" -ge 2 ]
}
expect green "at least one UTF-8 locale resolved (C alone cannot see a collation bug)" -- \
  enough_locales_to_be_meaningful
echo "      locales under test: $MACREL_TEST_LOCALES"

for loc in $MACREL_TEST_LOCALES; do
  # 40 chars, all uppercase hex, deliberately containing no F.
  expect green "LC_ALL=$loc: uppercase hash with no F is refused" -- \
    with_locale "$loc" refuses_commit "83CCBE9D8BB707C0937A6A1E6E9836E1E2BE7B11"
  expect green "LC_ALL=$loc: uppercase hash containing F is refused" -- \
    with_locale "$loc" refuses_commit "83CCBE9D8BB707CF937A6A1F6F9836F1F2BF7B11"
  expect green "LC_ALL=$loc: a real lowercase commit is still accepted" -- \
    with_locale "$loc" macrel_is_valid_commit "83ccbe9d8bb707cf937a6a1f6f9836f1f2bf7b11"
done

# ------------------------------------------------- what the refusal SAYS
# Exit-status assertions cannot see any of this: macrel_describe_bad_commit only
# prints. That is why the collation bug survived — nothing asserted on the message, so
# every abbreviated lowercase hash reported itself as "uppercase hex" and the reader
# was sent after a spelling problem that did not exist.
for loc in $MACREL_TEST_LOCALES; do
  expect green "LC_ALL=$loc: an abbreviated LOWERCASE hash is described by its length" -- \
    with_locale "$loc" describes_as "83ccbe9d" "characters, not 40"
  expect green "LC_ALL=$loc: an abbreviated hash of only b-f chars is described by length" -- \
    with_locale "$loc" describes_as "bcdef" "characters, not 40"
  expect green "LC_ALL=$loc: a genuinely uppercase hash is described as uppercase" -- \
    with_locale "$loc" describes_as "83CCBE9D8BB707C0937A6A1E6E9836E1E2BE7B11" "uppercase hex"
done
expect green "an empty value is described as empty" -- describes_as "" "empty"
expect green "an unexpanded template is described as unexpanded" -- \
  describes_as '$(BATON_SOURCE_COMMIT)' "unexpanded"
expect green "a placeholder is named as a placeholder" -- describes_as "unknown" "placeholder"
expect green "a non-hex string is described as non-hex" -- \
  describes_as "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" "not hexadecimal"

echo

# ====================================================================== the pin
R="$(fresh_repo)"
expect green "pin succeeds on a real checkout" -- \
  macrel_pin "$R" "$R/app/project.yml"

expect red "pin refuses a directory that is not a git checkout" -- \
  macrel_pin "$WORK" "$R/app/project.yml"

# A 40-hex string that is not a commit HERE. The shape is right, so only resolving it
# against the repo can tell — and no real checkout can be put into this state, which
# is why the admission test is its own function rather than inlined into the pin.
R="$(fresh_repo)"
expect red "a well-formed sha that is not a commit in this repo" -- \
  macrel_validate_commit_for_repo "$R" "dead00beef00dead00beef00dead00beef00dead"
expect green "the repo's own HEAD passes the admission test" -- \
  macrel_validate_commit_for_repo "$R" "$(git -C "$R" rev-parse HEAD)"

echo

# ========================================================== the moving-tree cases
# ------------------------------------------------------------------ green baseline
R="$(fresh_repo)"
macrel_pin "$R" "$R/app/project.yml" >/dev/null
expect green "nothing moves: an ordinary run passes the checkpoint" -- \
  macrel_assert "before packaging"

# ----------------------------------- the TBX-5058 shape, on the Mac release path
# Pin on the release branch, then `git checkout main` mid-run. Version, build and
# HEAD all move. On iPhone this shipped a second, different 1.0.13; on the Mac it
# would publish a DMG advertised as one release and built from another.
R="$(fresh_repo)"
macrel_pin "$R" "$R/app/project.yml" >/dev/null
git -C "$R" checkout -q main
expect red "git checkout main mid-run (0.17.13 -> 0.17.12)" -- \
  macrel_assert "before packaging"

# ------------------------------------------ same version, different code (HEAD)
# Two commits carrying identical version strings. This is precisely what makes the
# version pair useless as an identity, and precisely what the commit pin catches.
R="$(fresh_repo)"
macrel_pin "$R" "$R/app/project.yml" >/dev/null
git -C "$R" checkout -q -b hotfix
echo "# unrelated change" >> "$R/app/other.txt"
git -C "$R" add -A && git -C "$R" commit -qm "same version, different tree"
expect red "moved to a different commit at the same version (commit signal)" -- \
  macrel_assert "before the DMG"

# ----------------------------------------------- build number moved on its own
# Sparkle keys updates on CURRENT_PROJECT_VERSION alone, so this one moving is a
# release that installed copies would never be offered — 0.14.0 and 0.15.0 both
# shipped as build 57 exactly this way.
R="$(fresh_repo)"
macrel_pin "$R" "$R/app/project.yml" >/dev/null
yml "0.17.13" "99" > "$R/app/project.yml"
git -C "$R" add -A && git -C "$R" commit -qm "bump build only"
expect red "CURRENT_PROJECT_VERSION changed under the run" -- \
  macrel_assert "before the appcast"

# ---------------------------------------------- project.yml digest, version held
# A change that keeps both version strings but alters signing, the bundle id or the
# Sparkle public key. Uncommitted, so HEAD does not move either — the digest is the
# only signal left.
R="$(fresh_repo)"
macrel_pin "$R" "$R/app/project.yml" >/dev/null
printf '    SUPublicEDKey: "somebodyElsesKey="\n' >> "$R/app/project.yml"
expect red "project.yml changed under the run, versions unchanged (digest signal)" -- \
  macrel_assert "before the DMG"

# ------------------------------------------------ production bar: a dirty tree
R="$(fresh_repo)"
macrel_pin "$R" "$R/app/project.yml" >/dev/null
expect green "production check passes on a clean tree" -- macrel_assert_production_ready
echo "scratch" > "$R/app/uncommitted.txt"
expect red "production check refuses a dirty tree (stamp would be a false claim)" -- \
  macrel_assert_production_ready

# ------------------------------------------ the release's OWN mid-run edits
# THE REGRESSION. publish.sh rewrites Casks/baton.rb and website/index.html in place
# at steps 4c/4d and commits neither — the operator does that after the run. The
# production gate at step 6 then saw a dirty tree and aborted the release on the
# script's own edits, AFTER the build, the signing, the notarization and the DMG.
# No synthetic bundle test could have caught it: the guard was correct, its position
# relative to those seds was not.
# ---------------------------------------- the classifier, path by path
# The rule is about reachability, so state the verdicts outright before testing the
# behaviour built on them. The default matters most: unclassified must be FATAL.
verdict_is() {  # $1 = expected leading word, $2 = path
  [ "$(macrel_dirty_path_verdict "$2" | awk '{print $1}')" = "$1" ]
}
for p in \
  "app/project.yml" \
  "app/Sources/Baton/App.swift" \
  "Shared/CrashReporting.swift" \
  "Packages/BatonPlaybackKit/Sources/X.swift" \
  "scripts/publish.sh"
do
  expect green "classifier: $p can reach the DMG (FATAL)" -- verdict_is FATAL "$p"
done
# The two build inputs that live at the repo ROOT, copied into the bundle by the
# Sync Help guides pre-build script. A deny-list of source directories misses both,
# which is the concrete reason this is not a rule about directories.
for p in "HELP.md" "FAQ.md"; do
  expect green "classifier: $p is a root-level build input (FATAL)" -- verdict_is FATAL "$p"
done
for p in "Casks/baton.rb" "website/index.html"; do
  expect green "classifier: $p provably cannot reach the DMG (SAFE)" -- verdict_is SAFE "$p"
done
# Fail closed. Each of these is a path nobody has classified; a deny-list of known
# build roots would wave all four through.
for p in \
  "Core/NewModule.swift" \
  "Casks/other.rb" \
  "website/pricing.html" \
  "README.md"
do
  expect green "classifier: unclassified $p fails closed (FATAL)" -- verdict_is FATAL "$p"
done

# ------------------------------------------ the release's OWN mid-run edits
# THE REGRESSION. publish.sh rewrites Casks/baton.rb and website/index.html in place
# at steps 4c/4d and commits neither — the operator does that after the run. The
# production gate at step 6 then saw a dirty tree and aborted the release on the
# script's own edits, AFTER the build, the signing, the notarization and the DMG.
# No synthetic bundle test could have caught it: the guard was correct, its position
# relative to those seds was not.
R="$(fresh_repo)"
macrel_pin "$R" "$R/app/project.yml" >/dev/null
publish_bookkeeping_edits "$R" "0.17.13" "98" "$(printf 'a%.0s' $(seq 64))"
expect green "DIRECTION 1: the real cask+site sed sequence does NOT abort" -- \
  macrel_assert_production_ready

# DIRECTION 2 — the one that goes quietly green if the narrowing was actually a
# weakening. A real source change arriving AFTER the seds, on top of the tolerated
# bookkeeping, must still stop the release.
echo "// a genuine mid-run edit" >> "$R/Shared/CrashReporting.swift"
expect red "DIRECTION 2: a mid-run change to Shared/ after the seds still aborts" -- \
  macrel_assert_production_ready
names_the_real_change() {
  grep -q "Shared/CrashReporting.swift" <<<"$(say macrel_assert_production_ready)"
}
separates_the_harmless_paths() {
  grep -q "cannot reach the DMG, so they are fine" <<<"$(say macrel_assert_production_ready)"
}
gives_the_reason_it_is_fatal() {
  grep -q "compiled into Baton.app" <<<"$(say macrel_assert_production_ready)"
}
expect green "the abort names the file that actually drifted" -- names_the_real_change
expect green "the abort still lists the harmless bookkeeping separately" -- separates_the_harmless_paths
expect green "the abort says WHY the drifted file is fatal" -- gives_the_reason_it_is_fatal
git -C "$R" checkout -q -- Shared/CrashReporting.swift

echo "// a genuine mid-run edit" >> "$R/app/Sources/Baton/App.swift"
expect red "DIRECTION 2: a mid-run change to app/ after the seds still aborts" -- \
  macrel_assert_production_ready
git -C "$R" checkout -q -- app/Sources/Baton/App.swift

# A root-level build input, dirtied after the seds. This is the case a deny-list of
# source directories waves through while the app it ships has different help in it.
echo "extra help" >> "$R/HELP.md"
expect red "DIRECTION 2: a mid-run change to HELP.md after the seds still aborts" -- \
  macrel_assert_production_ready
git -C "$R" checkout -q -- HELP.md

# An untracked stray parses through the same `?? ` path and is unclassified.
echo "scratch" > "$R/app/stray.txt"
expect red "an untracked stray file still aborts" -- macrel_assert_production_ready
rm -f "$R/app/stray.txt"
expect green "removing the stray leaves only the harmless bookkeeping" -- \
  macrel_assert_production_ready

# SAFE is per exact path, not per directory: naming the cask does not bless its siblings.
echo "x" > "$R/Casks/other.rb"
expect red "a sibling of a SAFE path is not itself SAFE" -- macrel_assert_production_ready
rm -f "$R/Casks/other.rb"

# ------------------------------------------------- drift between script and rule
# The classifier is only right while it still covers what publish.sh actually edits in
# place. Resolve every `sed -i ''` target out of the REAL script and require each to be
# classified SAFE, so a third in-place edit added later fails here rather than aborting
# a real release forty minutes in.
REAL_PUBLISH="$DIR/publish.sh"
every_in_place_edit_is_classified_safe() {
  [ -f "$REAL_PUBLISH" ] || return 1
  local var path found=0
  # Each `sed -i ''` block ends with its target on its own line, as "$CASK" / "$SITE".
  for var in $(grep -oE '^ *"\$[A-Z_]+"$' "$REAL_PUBLISH" | tr -d ' "$'); do
    path="$(grep -E "^${var}=\"" "$REAL_PUBLISH" | head -1 | sed -E 's/^[A-Z_]+="([^"]*)".*/\1/')"
    [ -n "$path" ] || return 1
    verdict_is SAFE "$path" || return 1
    found=$((found + 1))
  done
  [ "$found" -gt 0 ]
}
expect green "every path publish.sh edits in place is classified SAFE" -- \
  every_in_place_edit_is_classified_safe

# ------------------------------------------------- SIGPIPE under pipefail
# `something | grep -q PATTERN` returns 141 when it SUCCEEDS: grep -q exits on the
# first match, the producer dies on the closed pipe, and `pipefail` reports the signal
# instead of the match. Whether it fires depends on whether the output fits the pipe
# buffer before grep exits — a size-dependent flake, which is the worst kind on a
# release path. Two of these existed here: one would have aborted a good release
# claiming a missing entitlement, and one would have reported "origin verify FAILED"
# on a verification that passed, after the DMG and appcast were already live.
#
# Capture first and match with a herestring instead. Checked structurally so it cannot
# creep back into any of the three scripts.
no_sigpipe_grep_pipelines() {
  local f
  for f in publish.sh release-identity.sh test-release-identity.sh; do
    [ -f "$DIR/$f" ] || continue
    # Lines with a pipe into `grep -q`, ignoring anything after a '#'.
    grep -nE '^[^#]*\| *grep -q' "$DIR/$f" >/dev/null && return 1
  done
  return 0
}
# Label deliberately avoids spelling the pattern: an earlier wording contained the
# literal sequence and the check matched its own label, which is a test matching the
# wrong site — the same family as everything else found in this lane.
expect green "no producer-piped-into-quiet-grep pipelines survive (SIGPIPE under pipefail)" -- \
  no_sigpipe_grep_pipelines

echo

# ================================================ what was ACTUALLY compiled
# The checks above say what the tree claims. These read the bundle, which is the
# only source a tree that moved and moved back cannot fool.
R="$(fresh_repo)"
macrel_pin "$R" "$R/app/project.yml" >/dev/null
PINNED="$MACREL_COMMIT"

expect green "the bundle carries the pinned commit, version and build" -- \
  macrel_assert_built_identity "$(built_app "$WORK/ok.app" "0.17.13" "98" "$PINNED")"

# The state the live 0.17.12 build is actually in: version strings, no identity.
expect red "the bundle has no BatonSourceCommit key at all (the 0.17.12 state)" -- \
  macrel_assert_built_identity "$(built_app "$WORK/nokey.app" "0.17.13" "98" "__ABSENT__")"

expect red "the bundle has an empty BatonSourceCommit" -- \
  macrel_assert_built_identity "$(built_app "$WORK/empty.app" "0.17.13" "98" "")"

# The two blank states look identical to PlistBuddy and are different bugs: no key
# means app/project.yml never declared it, an empty key means the build setting never
# reached xcodebuild. A diagnosis that sends you to the wrong file is worse than none,
# so the wording is pinned rather than left to drift.
#
# Note the shape: the guard's own non-zero exit is expected here (both bundles are
# bad), so its output is captured first and matched separately. Piping it into grep
# would hand the pipeline the guard's exit status under `pipefail` and report a
# correct diagnosis as a failure.
missing_key_names_the_project_file() {
  grep -q "no such key" <<<"$(say macrel_assert_built_identity "$(built_app "$WORK/nokey2.app" "0.17.13" "98" "__ABSENT__")")"
}
empty_key_says_it_is_present() {
  grep -q "present but empty" <<<"$(say macrel_assert_built_identity "$(built_app "$WORK/empty2.app" "0.17.13" "98" "")")"
}
expect green "a missing key is diagnosed as a missing key, not as an empty one" -- \
  missing_key_names_the_project_file
expect green "an empty key is diagnosed as empty, not as absent" -- \
  empty_key_says_it_is_present

# The failure that reads as success at a glance: the key is present and holds its
# own template, because the build setting never reached xcodebuild.
expect red "the bundle holds an unexpanded \$(BATON_SOURCE_COMMIT)" -- \
  macrel_assert_built_identity "$(built_app "$WORK/tmpl.app" "0.17.13" "98" '$(BATON_SOURCE_COMMIT)')"

expect red "the bundle holds a placeholder ('unknown')" -- \
  macrel_assert_built_identity "$(built_app "$WORK/placeholder.app" "0.17.13" "98" "unknown")"

expect red "the bundle holds an abbreviated hash" -- \
  macrel_assert_built_identity "$(built_app "$WORK/short.app" "0.17.13" "98" "${PINNED:0:12}")"

expect red "the bundle holds the right commit in uppercase" -- \
  macrel_assert_built_identity "$(built_app "$WORK/upper.app" "0.17.13" "98" "$(printf '%s' "$PINNED" | tr 'a-f' 'A-F')")"

expect red "the bundle holds a non-hex string of the right length" -- \
  macrel_assert_built_identity "$(built_app "$WORK/nonhex.app" "0.17.13" "98" "$(printf 'z%.0s' $(seq 40))")"

# Well-formed, canonical, and simply not this build. A tree that moved and moved
# back passes every source-side check above and fails only here.
expect red "the bundle holds a valid but different commit" -- \
  macrel_assert_built_identity "$(built_app "$WORK/other.app" "0.17.13" "98" "0000000000000000000000000000000000000001")"

expect red "the bundle holds the right commit at the wrong version" -- \
  macrel_assert_built_identity "$(built_app "$WORK/wrongver.app" "0.17.12" "98" "$PINNED")"

expect red "the bundle holds the right commit at the wrong build number" -- \
  macrel_assert_built_identity "$(built_app "$WORK/wrongbuild.app" "0.17.13" "97" "$PINNED")"

expect red "there is no bundle to read (nothing to prove the release with)" -- \
  macrel_assert_built_identity "$WORK/missing.app"

echo

# ======================================================== the published mapping
MAN="$WORK/identity.txt"
macrel_write_identity_manifest "$MAN" "/x/Baton-0.17.13.dmg" "abc123" "42" >/dev/null
manifest_names_the_commit() { grep -q "^source_commit: $PINNED\$" "$MAN"; }
manifest_names_the_version() { grep -q "^version: 0.17.13\$" "$MAN" && grep -q "^build: 98\$" "$MAN"; }
expect green "identity manifest records the full 40-char commit" -- manifest_names_the_commit
expect green "identity manifest records the version and build it belongs to" -- manifest_names_the_version

echo
echo "=== $PASS passed, $FAIL failed =========================================="
[ "$FAIL" -eq 0 ]
