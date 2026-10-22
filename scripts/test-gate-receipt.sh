#!/bin/bash
#
# A full gate that passed once at a commit is reused by both releases, and by nothing that
# differs from what passed. (TBX-11003) Drives scripts/gate-receipt.sh against a planted
# repository, a stub `xcodebuild -version` and a temporary receipt directory. About a second.
# shellcheck disable=SC2016 # stubs and greps carry literal $NAMES
set -uo pipefail
cd "$(dirname "$0")/.." || exit
ROOT="$PWD"
RECEIPT="$ROOT/scripts/gate-receipt.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '\033[32mok    %s\033[0m\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '\033[31mFAIL  %s\033[0m\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export BATON_GATE_RECEIPT_DIR="$WORK/receipts"
mkdir -p "$WORK/bin"
printf '#!/bin/bash\nprintf "Xcode %%s\\nBuild version 17A1\\n" "${STUB_XCODE:-26.6}"\n' >"$WORK/bin/xcodebuild"
chmod +x "$WORK/bin/xcodebuild"
export PATH="$WORK/bin:$PATH"

R="$WORK/repo"
mkdir -p "$R/scripts"
git -C "$R" init -q
git -C "$R" config user.email t@example.invalid
git -C "$R" config user.name test
printf '#!/bin/bash\necho gate v1\n' >"$R/scripts/test.sh"
printf '**/Config/*.local.*\n' >"$R/.gitignore"
mkdir -p "$R/app/Config" "$R/ios/Config"
printf 'MAC_FAKE\n' >"$R/app/Config/Crashbox.local.xcconfig"
printf 'IOS_FAKE\n' >"$R/ios/Config/Crashbox.local.xcconfig"
git -C "$R" add -A && git -C "$R" commit -qm one
# This planted repo plays the Mac release checkout.
export BATON_MAC_RELEASE_CHECKOUT="$R" BATON_IOS_RELEASE_CHECKOUT="$WORK/no-ios-checkout"

out="$("$RECEIPT" check "$R" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q <<<"$out" "no passing full gate is recorded"; then
  ok "no receipt: the release is told it must run the gate"
else
  bad "a missing receipt was not reported. Got: $out"
fi

"$RECEIPT" write "$R" --clean 0 --mac "1200 tests: 1200 passed, 0 failed, 3 skipped" \
  --ios "240 tests" --gateway "57" --skips "linux-gateway" >/dev/null 2>&1
file="$BATON_GATE_RECEIPT_DIR/$(git -C "$R" rev-parse HEAD)-incremental.json"
if [ -f "$file" ] && [ "$(stat -f %Lp "$file")" = 600 ] \
   && python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["commit"] and r["gateScriptSHA256"] and r["xcode"].startswith("Xcode 26.6") and r["counts"]["mac"].startswith("1200") and r["passedAt"] and r["skipped"]==["linux-gateway"] and r["checkoutRole"]=="mac-release" and len(r["configs"]["app/Config/Crashbox.local.xcconfig"])==64' "$file" \
   && ! grep -q 'MAC_FAKE\|IOS_FAKE' "$file"; then
  ok "a receipt records commit, gate digest, Xcode, counts, skips, checkout role, config digests and time, mode 0600, and no config contents"
else
  bad "the receipt is missing a field or is not private: $(cat "$file" 2>/dev/null)"
fi

out="$("$RECEIPT" check "$R" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q <<<"$out" "gate receipt reused" && grep -q <<<"$out" "skipped: linux-gateway"; then
  ok "TestFlight's check accepts a matching incremental receipt and says what it reuses"
else
  bad "a matching receipt was not accepted. Got: $out"
fi

out="$("$RECEIPT" check "$R" --require-clean 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q <<<"$out" "a release needs CLEAN=1"; then
  ok "the Mac release refuses an incremental receipt and says it needs CLEAN=1"
else
  bad "--require-clean accepted an incremental run. Got: $out"
fi

"$RECEIPT" write "$R" --clean 1 --mac "1200" --ios "240" --gateway "57" >/dev/null 2>&1
out="$("$RECEIPT" check "$R" --require-clean 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q <<<"$out" "CLEAN=1"; then
  ok "the Mac release accepts a CLEAN=1 receipt for the same commit"
else
  bad "a CLEAN=1 receipt was not accepted. Got: $out"
fi

printf 'scratch\n' >"$R/notes.txt"
out="$("$RECEIPT" check "$R" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q <<<"$out" "the tree is dirty"; then
  ok "a dirty tree refuses the receipt and names why"
else
  bad "a dirty tree reused a receipt. Got: $out"
fi
out="$("$RECEIPT" write "$R" --clean 1 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then
  ok "no receipt is written over a dirty tree"
else
  bad "a receipt was written over a dirty tree"
fi
rm -f "$R/notes.txt"

out="$(STUB_XCODE=26.7 "$RECEIPT" check "$R" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q <<<"$out" "Xcode changed since it passed"; then
  ok "a different Xcode refuses the receipt and names both versions"
else
  bad "a receipt from another Xcode was reused. Got: $out"
fi

printf '#!/bin/bash\necho gate v2\n' >"$R/scripts/test.sh"
git -C "$R" commit -qam two
out="$("$RECEIPT" check "$R" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q <<<"$out" "no passing full gate is recorded for $(git -C "$R" rev-parse HEAD)"; then
  ok "a new commit has no receipt until its own gate passes"
else
  bad "a receipt crossed commits. Got: $out"
fi

# A receipt whose recorded gate digest differs (a gate edited and rerun at the same commit
# cannot happen on a clean tree, so plant it) is refused by name.
"$RECEIPT" write "$R" --clean 1 >/dev/null 2>&1
file="$BATON_GATE_RECEIPT_DIR/$(git -C "$R" rev-parse HEAD)-clean.json"
python3 -c 'import json,sys; p=sys.argv[1]; r=json.load(open(p)); r["gateScriptSHA256"]="0"*64; json.dump(r,open(p,"w"))' "$file"
out="$("$RECEIPT" check "$R" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q <<<"$out" "scripts/test.sh changed since it passed"; then
  ok "a receipt for a different gate script is refused by name"
else
  bad "a gate-digest mismatch was not refused. Got: $out"
fi

# --- Where the gate ran (review finding S3) ---------------------------------------------
# A fresh commit and a fresh receipt for the binding checks below.
printf '#!/bin/bash\necho gate v3\n' >"$R/scripts/test.sh"
git -C "$R" commit -qam three
"$RECEIPT" write "$R" --clean 1 --skips linux-gateway >/dev/null 2>&1

out="$("$RECEIPT" check "$R" --needs iphone-tests,linux-gateway 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q <<<"$out" "the gate skipped linux-gateway, which this release needs"; then
  ok "a receipt that skipped a stage the release needs is refused, naming the stage"
else
  bad "a skipped needed stage was accepted. Got: $out"
fi
out="$(BATON_GATE_RECEIPT_ALLOW_SKIPS=linux-gateway "$RECEIPT" check "$R" --needs iphone-tests,linux-gateway 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then
  ok "BATON_GATE_RECEIPT_ALLOW_SKIPS is the explicit opt-in for a skipped stage"
else
  bad "the skip opt-in was not honored. Got: $out"
fi

printf 'IOS_OTHER\n' >"$R/ios/Config/Crashbox.local.xcconfig"
out="$("$RECEIPT" check "$R" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q <<<"$out" "ios/Config/Crashbox.local.xcconfig differs" \
   && ! grep -q <<<"$out" 'IOS_OTHER\|IOS_FAKE'; then
  ok "a release configuration with another digest refuses the receipt, without printing it"
else
  bad "a changed release configuration was accepted. Got: $out"
fi
rm -f "$R/ios/Config/Crashbox.local.xcconfig"
out="$("$RECEIPT" check "$R" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q <<<"$out" "this checkout: absent"; then
  ok "a release configuration missing on one side refuses the receipt"
else
  bad "a missing release configuration was accepted. Got: $out"
fi
printf 'IOS_FAKE\n' >"$R/ios/Config/Crashbox.local.xcconfig"

out="$(BATON_MAC_RELEASE_CHECKOUT="$WORK/elsewhere" "$RECEIPT" write "$R" --clean 1 >/dev/null 2>&1
       "$RECEIPT" check "$R" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q <<<"$out" "not a release checkout"; then
  ok "a receipt from a development checkout is refused in a release"
else
  bad "a development checkout's receipt was accepted. Got: $out"
fi
out="$(BATON_GATE_RECEIPT_ANY_CHECKOUT=1 "$RECEIPT" check "$R" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then
  ok "BATON_GATE_RECEIPT_ANY_CHECKOUT=1 is the explicit opt-in for another checkout"
else
  bad "the checkout opt-in was not honored. Got: $out"
fi

# Wiring: both releases consult a receipt before their gate, and fall back to running it.
if grep -q -- '--needs iphone-tests,watch,linux-gateway' scripts/publish.sh \
   && grep -q -- 'check "$REPO" --needs iphone-tests' ios/scripts/testflight.sh; then
  ok "wiring: each release names the gate stages it needs"
else
  bad "wiring: a release does not say which gate stages it needs"
fi
if grep -q 'install -m 600 "$IOS_CONFIG" "$MAC_RELEASE/ios/Config/Crashbox.local.xcconfig"' scripts/prepare-release-checkouts.sh \
   && grep -q 'install -m 600 "$MAC_CONFIG" "$IOS_RELEASE/app/Config/Crashbox.local.xcconfig"' scripts/prepare-release-checkouts.sh; then
  ok "wiring: both release checkouts carry both configurations, so one receipt serves both"
else
  bad "wiring: the release checkouts do not carry the same configurations"
fi
if grep -B2 -A8 'gate-receipt.sh" check "$PWD" --require-clean' scripts/publish.sh | grep -q 'CLEAN=1 "$(dirname "$0")/test.sh"'; then
  ok "wiring: publish.sh reuses a CLEAN=1 receipt or runs CLEAN=1 test.sh"
else
  bad "wiring: publish.sh does not check a receipt before its gate"
fi
if grep -A16 'gate-receipt.sh" check "$REPO"' ios/scripts/testflight.sh | grep -q './scripts/test.sh'; then
  ok "wiring: testflight.sh reuses a receipt or runs test.sh"
else
  bad "wiring: testflight.sh does not check a receipt before its gate"
fi
if grep -q 'scripts/gate-receipt.sh write "$PWD"' scripts/test.sh; then
  ok "wiring: a passing full test.sh run writes the receipt"
else
  bad "wiring: test.sh never writes a receipt"
fi

# TBX-1000000503 F-12: a lint-source override points a lint at a planted tree, so a run with
# one set did not lint this tree, and must not write a receipt that says it did. The real
# eligibility function from test.sh, run in the planted (clean) repository.
ELIGIBLE_FN="$(awk '/^gate_receipt_eligible\(\) \{$/,/^\}$/' scripts/test.sh)"
eligible() {   # env assignments ... ; prints yes or no
  ( cd "$R" && env -i PATH="$PATH" HOME="$HOME" "$@" bash -c "set -uo pipefail; $ELIGIBLE_FN
    if gate_receipt_eligible; then echo yes; else echo no; fi" )
}
if [ -z "$ELIGIBLE_FN" ]; then
  bad "F-12: gate_receipt_eligible() not found in scripts/test.sh"
else
  [ "$(eligible)" = yes ] && ok "F-12 a full run over a clean tree is eligible for a receipt" \
    || bad "F-12: a full run over a clean tree was refused a receipt"
  for v in BATON_LINT_SRC BATON_DASH_LINT_SRC BATON_DASH_LINT_ALLOWLIST BATON_IMPORT_LINT_SRC \
           BATON_UITEST_LINT_SRC BATON_GATEWAY_PKG_LINT_ROOT BATON_SCHEME_LINT_PROJECT_YML; do
    if [ "$(eligible "$v=/tmp/planted")" = yes ]; then
      bad "F-12: a run with $v set would write a reusable receipt"
    else
      ok "F-12 a run with $v set writes no receipt"
    fi
  done
  [ "$(eligible BATON_LINT_SRC=)" = yes ] && ok "F-12 an empty override is not an override" \
    || bad "F-12: an empty BATON_LINT_SRC refused the receipt"
fi
grep -q '^if gate_receipt_eligible "\$@"; then$' scripts/test.sh \
  && ok "F-12 wiring: test.sh decides the receipt with gate_receipt_eligible" \
  || bad "F-12 wiring: test.sh does not use gate_receipt_eligible"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
