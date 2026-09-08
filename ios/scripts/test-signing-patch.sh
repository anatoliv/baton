#!/bin/bash
#
# Drive testflight.sh's step-2 manual-signing patch against copies of the real
# ios/project.yml. No build, no signing, no Apple — under a second.
#
#   ./ios/scripts/test-signing-patch.sh
#
# The patch inserts CODE_SIGN_IDENTITY and a PROVISIONING_PROFILE_SPECIFIER per
# target. Commit 2914b744 committed that transient edit into project.yml, so those
# keys are in the tracked file today and inserting them blind gave every release
# since 0.16.10 a project.yml holding each key twice (TBX-5066). The patch now
# rewrites a key that is present instead of adding a second copy.
#
# The case that matters most is the last one: a patch that stops inserting is worse
# than one that inserts twice, so the file with the keys stripped out — what the
# patch actually exists for — is exercised here too.
#
# The Python is EXTRACTED FROM testflight.sh rather than copied, so this cannot
# drift into testing a stale duplicate of the logic. Exit 0 = every case held.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS="$(cd "$DIR/.." && pwd)"

IDENTITY="Apple Distribution: Anatoli Vishnyakov (Q8822GNL2H)"
APP_PROFILE="Baton App Store"
WIDGET_PROFILE="Baton Widgets App Store"

WORK="$(mktemp -d -t baton-signing-patch-test)"
trap 'rm -rf "$WORK"' EXIT
PATCH="$WORK/patch.py"
PASS=0
FAIL=0

awk "/<<'PY'\$/{f=1;next} f&&/^PY\$/{exit} f" "$DIR/testflight.sh" > "$PATCH"
[ -s "$PATCH" ] || { echo "could not extract the step-2 patch from testflight.sh" >&2; exit 1; }

apply() {  # $1 = project.yml to patch in place, $2 = WITH_ENTITLEMENTS (default 1)
  python3 "$PATCH" "$1" "$APP_PROFILE" "$WIDGET_PROFILE" "$IDENTITY" "${2:-1}" >/dev/null
}

count() {  # $1 = file, $2 = key -> how many lines declare it
  grep -c "^ *$2:" "$1"
}

check() {  # $1 = description, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    echo "  ok   $1"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL $1 — expected '$2', got '$3'"
  fi
}

single_keys() {  # $1 = description prefix, $2 = file
  check "$1: one CODE_SIGN_IDENTITY"                1 "$(count "$2" CODE_SIGN_IDENTITY)"
  check "$1: one CODE_SIGN_STYLE"                   1 "$(count "$2" CODE_SIGN_STYLE)"
  check "$1: two PROVISIONING_PROFILE_SPECIFIER"    2 "$(count "$2" PROVISIONING_PROFILE_SPECIFIER)"
}

signing_values() {  # $1 = description prefix, $2 = file
  check "$1: signing is manual" \
    "    CODE_SIGN_STYLE: Manual" "$(grep -m1 '^ *CODE_SIGN_STYLE:' "$2")"
  check "$1: identity is the distribution cert" \
    "    CODE_SIGN_IDENTITY: \"$IDENTITY\"" "$(grep -m1 '^ *CODE_SIGN_IDENTITY:' "$2")"
  check "$1: app profile" \
    "        PROVISIONING_PROFILE_SPECIFIER: \"$APP_PROFILE\"" \
    "$(grep -A4 '^ *PRODUCT_BUNDLE_IDENTIFIER: io.tonebox.baton$' "$2" |
       grep -m1 'PROVISIONING_PROFILE_SPECIFIER')"
  check "$1: widget profile" \
    "        PROVISIONING_PROFILE_SPECIFIER: \"$WIDGET_PROFILE\"" \
    "$(grep -A4 '^ *PRODUCT_BUNDLE_IDENTIFIER: io.tonebox.baton.widgets$' "$2" |
       grep -m1 'PROVISIONING_PROFILE_SPECIFIER')"
}

# ---------------------------------- case 1: today's committed file, patched once
echo "== the committed project.yml, patched once =="
cp "$IOS/project.yml" "$WORK/once.yml"
apply "$WORK/once.yml"
single_keys "committed" "$WORK/once.yml"
signing_values "committed" "$WORK/once.yml"

# ------------------------------------------------- case 2: patched twice running
echo "== the same file, patched twice =="
cp "$IOS/project.yml" "$WORK/twice.yml"
apply "$WORK/twice.yml"
apply "$WORK/twice.yml"
single_keys "idempotent" "$WORK/twice.yml"
signing_values "idempotent" "$WORK/twice.yml"
check "idempotent: second run changed nothing" \
  "same" "$(cmp -s "$WORK/once.yml" "$WORK/twice.yml" && echo same || echo differs)"

# ------------------- case 3: the keys absent — the case the patch exists for
# This is what project.yml looks like once the committed signing keys are removed,
# and what it looked like before 0.16.10. The patch must still insert them.
echo "== a clean project.yml with the signing keys stripped out =="
grep -v -e '^    CODE_SIGN_IDENTITY:' -e '^        PROVISIONING_PROFILE_SPECIFIER:' \
  "$IOS/project.yml" > "$WORK/clean.yml"
check "stripped: no CODE_SIGN_IDENTITY to start"             0 "$(count "$WORK/clean.yml" CODE_SIGN_IDENTITY)"
check "stripped: no PROVISIONING_PROFILE_SPECIFIER to start" 0 "$(count "$WORK/clean.yml" PROVISIONING_PROFILE_SPECIFIER)"
apply "$WORK/clean.yml"
single_keys "stripped" "$WORK/clean.yml"
signing_values "stripped" "$WORK/clean.yml"
apply "$WORK/clean.yml"
single_keys "stripped, patched twice" "$WORK/clean.yml"

# ------------------------------------- case 4: the WITH_ENTITLEMENTS=0 escape hatch
echo "== WITH_ENTITLEMENTS=0 (App Group dropped) =="
cp "$IOS/project.yml" "$WORK/noent.yml"
apply "$WORK/noent.yml" 0
single_keys "no entitlements" "$WORK/noent.yml"
signing_values "no entitlements" "$WORK/noent.yml"
check "no entitlements: App Group gone" 0 \
  "$(grep -c 'application-groups' "$WORK/noent.yml")"

echo
echo "=== $PASS passed, $FAIL failed ==========================================="
[ "$FAIL" -eq 0 ]
