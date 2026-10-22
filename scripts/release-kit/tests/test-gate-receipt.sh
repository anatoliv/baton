#!/usr/bin/env bash
# test-gate-receipt.sh: a full gate that passed once at a commit is reused by every release,
# and by nothing that differs from what passed: another commit, a dirty tree, another gate
# script or toolchain, an incremental run where a clean one is required, a development
# checkout, another release configuration, or a skipped stage the release needs. Planted
# repository, stub `xcodebuild -version`, temporary receipt store. RK_GATE_RECEIPT_SUBJECT
# points at a mutated copy. About two seconds.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUBJECT="${RK_GATE_RECEIPT_SUBJECT:-$HERE/../lib/gate-receipt.sh}"
[ -f "$SUBJECT" ] || { echo "FAIL  no module at $SUBJECT"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

unset RK_GATE_ENV RK_GATE_RECEIPT_ANY_CHECKOUT RK_GATE_RECEIPT_ALLOW_SKIPS RK_GATE_TOOL_CMD
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/rk-gate-receipt.XXXXXX")" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT INT TERM
export RK_GATE_RECEIPT_DIR="$WORK/receipts"
mkdir -p "$WORK/bin"
printf '#!/bin/bash\nprintf "Xcode %%s\\nBuild version 17A1\\n" "${STUB_XCODE:-26.6}"\n' >"$WORK/bin/xcodebuild"
chmod +x "$WORK/bin/xcodebuild"
export PATH="$WORK/bin:$PATH"

R="$WORK/repo"
mkdir -p "$R/scripts" "$R/app/Config" "$R/ios/Config"
git -C "$R" init -q
git -C "$R" config user.email t@example.invalid
git -C "$R" config user.name test
printf '#!/bin/bash\necho gate v1\n' >"$R/scripts/test.sh"
printf '**/Config/*.local.*\n' >"$R/.gitignore"
printf 'APP_FAKE_SETTING\n' >"$R/app/Config/Release.local.xcconfig"
printf 'PHONE_FAKE_SETTING\n' >"$R/ios/Config/Release.local.xcconfig"
git -C "$R" add -A && git -C "$R" commit -qm one
export RK_GATE_CONFIGS="app/Config/Release.local.xcconfig ios/Config/Release.local.xcconfig"
export RK_GATE_RELEASE_CHECKOUTS="mac-release=$R ios-release=$WORK/no-ios-checkout"
export RK_GATE_COUNT_LABELS="mac=Mac iphone=iPhone"
G() { bash "$SUBJECT" "$@"; }   # the runnable form; the sourced form is checked below

out="$(G check "$R" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q "no passing full gate is recorded" <<<"$out" \
  && ok "no receipt: the release is told to run its gate" || bad "a missing receipt was not reported. Got: $out"

G write "$R" --clean 0 --count "mac=1200 tests: 1200 passed, 0 failed, 3 skipped" --count "iphone=240 tests" \
  --skips linux-build >/dev/null 2>&1
file="$RK_GATE_RECEIPT_DIR/$(git -C "$R" rev-parse HEAD)-incremental.json"
if [ -f "$file" ] && [ "$(stat -f %Lp "$file")" = 600 ] && [ "$(stat -f %Lp "$RK_GATE_RECEIPT_DIR")" = 700 ] \
   && python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["schema"]==1 and r["commit"] and len(r["gateScriptSHA256"])==64 and r["xcode"].startswith("Xcode 26.6") and r["counts"]["mac"].startswith("1200") and r["counts"]["iphone"]=="240 tests" and r["passedAt"] and r["skipped"]==["linux-build"] and r["checkoutRole"]=="mac-release" and len(r["configs"]["app/Config/Release.local.xcconfig"])==64' "$file" \
   && ! grep -q 'APP_FAKE_SETTING\|PHONE_FAKE_SETTING' "$file"; then
  ok "a receipt records commit, gate digest, toolchain, counts, skips, role and config digests; 0600 in a 0700 store; no config contents"
else
  bad "the receipt is missing a field or is not private: $(cat "$file" 2>/dev/null)"
fi

out="$(G check "$R" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "gate receipt reused: [0-9a-f]\{12\} passed at .* (incremental). Mac: 1200 tests: 1200 passed, 0 failed, 3 skipped; iPhone: 240 tests; skipped: linux-build" <<<"$out"; then
  ok "a matching incremental receipt is reused, with its counts in the project's order and its skips"
else
  bad "a matching receipt was not accepted as expected. Got: $out"
fi
out="$(G check "$R" --require-clean 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q "only an incremental run passed at .*; a release needs CLEAN=1" <<<"$out" \
  && ok "--require-clean refuses an incremental receipt and says why" || bad "--require-clean accepted an incremental run. Got: $out"
G write "$R" --clean 1 --count mac=1200 >/dev/null 2>&1
out="$(G check "$R" --require-clean 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q "(CLEAN=1)" <<<"$out" && grep -q "iPhone: ?" <<<"$out" \
  && ok "a clean receipt is accepted; a count the gate did not report prints as ?" || bad "a clean receipt was not accepted. Got: $out"

printf 'scratch\n' >"$R/notes.txt"
out="$(G check "$R" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q "the tree is dirty (?? notes.txt" <<<"$out" \
  && ok "a dirty tree refuses the receipt and names the path" || bad "a dirty tree reused a receipt. Got: $out"
out="$(G write "$R" --clean 1 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q "not written: the tree is dirty" <<<"$out" \
  && ok "no receipt is written over a dirty tree" || bad "a receipt was written over a dirty tree. Got: $out"
rm -f "$R/notes.txt"

# A corrupt index: HEAD resolves but git status exits 128 and prints nothing. That is an
# unreadable tree, not a clean one, in both the runnable and the sourced `||` form (where
# set -e is off), and with a matching receipt already in the store.
cp "$R/.git/index" "$WORK/index.good"
printf 'not an index' >"$R/.git/index"
out="$(G check "$R" 2>&1)"; rc=$?
sourced="$(bash -c '. "$1"; rk_gate_receipt check "$2" || echo "fell back to the gate"' _ "$SUBJECT" "$R" 2>&1)"
wrote="$(RK_GATE_RECEIPT_DIR="$WORK/corrupt-store" G write "$R" --clean 1 2>&1)"; wrc=$?
if [ "$rc" = 1 ] && grep -q "not used: git status failed" <<<"$out" \
   && grep -q "fell back to the gate" <<<"$sourced" && ! grep -q "reused" <<<"$sourced" \
   && [ "$wrc" = 1 ] && grep -q "not written: git status failed" <<<"$wrote" && [ ! -d "$WORK/corrupt-store" ]; then
  ok "a tree git cannot read refuses the receipt and writes none"
else
  bad "a failed git status passed for a clean tree. Check ($rc): $out Sourced: $sourced Write ($wrc): $wrote"
fi
cp "$WORK/index.good" "$R/.git/index"

out="$(STUB_XCODE=26.7 G check "$R" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q "Xcode changed since it passed (Xcode 26.6 Build version 17A1, now Xcode 26.7" <<<"$out" \
  && ok "another toolchain refuses the receipt and names both versions" || bad "a receipt from another Xcode was reused. Got: $out"
out="$(RK_GATE_TOOL_CMD='echo swift 6.3' RK_GATE_TOOL_LABEL=Swift G check "$R" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q "Swift changed since it passed" <<<"$out" \
  && ok "a project names its own toolchain command and label" || bad "RK_GATE_TOOL_CMD was ignored. Got: $out"

python3 -c 'import json,sys; p=sys.argv[1]; r=json.load(open(p)); r["gateScriptSHA256"]="0"*64; json.dump(r,open(p,"w"))' \
  "$RK_GATE_RECEIPT_DIR/$(git -C "$R" rev-parse HEAD)-clean.json"
out="$(G check "$R" --require-clean 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q "scripts/test.sh changed since it passed" <<<"$out" \
  && ok "a receipt for another gate script is refused by name" || bad "a gate-digest mismatch was accepted. Got: $out"
rm -f "$RK_GATE_RECEIPT_DIR/$(git -C "$R" rev-parse HEAD)-clean.json"   # so check reads the incremental one
python3 -c 'import json,sys; p=sys.argv[1]; r=json.load(open(p)); r["commit"]="f"*40; json.dump(r,open(p,"w"))' "$file"
out="$(G check "$R" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q "it is for commit ffff" <<<"$out" \
  && ok "a receipt whose recorded commit differs from its file name is refused" || bad "a mislabeled receipt was accepted. Got: $out"
printf 'not json' >"$file"
out="$(G check "$R" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q "unreadable receipt" <<<"$out" && ok "an unreadable receipt is refused, not trusted" || bad "garbage was accepted. Got: $out"

printf '#!/bin/bash\necho gate v2\n' >"$R/scripts/test.sh"
git -C "$R" commit -qam two
out="$(G check "$R" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q "no passing full gate is recorded for $(git -C "$R" rev-parse HEAD)" <<<"$out" \
  && ok "a new commit has no receipt until its own gate passes" || bad "a receipt crossed commits. Got: $out"

# Where it ran, and what it skipped.
G write "$R" --clean 1 --skips linux-build >/dev/null 2>&1
out="$(G check "$R" --needs phone-tests,linux-build 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q "the gate skipped linux-build, which this release needs (RK_GATE_RECEIPT_ALLOW_SKIPS=linux-build accepts it)" <<<"$out" \
  && ok "a skipped stage the release needs refuses the receipt, naming it and the opt-in" || bad "a needed skipped stage was accepted. Got: $out"
out="$(RK_GATE_RECEIPT_ALLOW_SKIPS=linux-build G check "$R" --needs phone-tests,linux-build 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "the ALLOW_SKIPS opt-in accepts a named skipped stage" || bad "the skip opt-in was ignored. Got: $out"
printf 'PHONE_OTHER\n' >"$R/ios/Config/Release.local.xcconfig"
out="$(G check "$R" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q "ios/Config/Release.local.xcconfig differs (gate: sha256 " <<<"$out" \
  && ! grep -q 'PHONE_OTHER\|PHONE_FAKE' <<<"$out" \
  && ok "another release configuration refuses the receipt, by digest only" || bad "a changed configuration was accepted. Got: $out"
rm -f "$R/ios/Config/Release.local.xcconfig"
out="$(G check "$R" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q "this checkout: absent" <<<"$out" \
  && ok "a configuration missing on one side refuses the receipt" || bad "a missing configuration was accepted. Got: $out"
printf 'PHONE_FAKE_SETTING\n' >"$R/ios/Config/Release.local.xcconfig"
out="$(RK_GATE_RELEASE_CHECKOUTS="mac-release=$WORK/elsewhere" G write "$R" --clean 1 >/dev/null 2>&1; G check "$R" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q "it ran in $R, not a release checkout (RK_GATE_RECEIPT_ANY_CHECKOUT=1 accepts it)" <<<"$out" \
  && ok "a receipt from a development checkout is refused in a release" || bad "a development checkout's receipt was accepted. Got: $out"
out="$(RK_GATE_RECEIPT_ANY_CHECKOUT=1 G check "$R" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "ANY_CHECKOUT=1 is the explicit opt-in for another checkout" || bad "the checkout opt-in was ignored. Got: $out"

# The sourced form, under a project's own prefix and store.
out="$( unset RK_GATE_RECEIPT_DIR
  # shellcheck disable=SC2034 # read by the sourced module
  RK_GATE_ENV=DEMO_RECEIPT DEMO_RECEIPT_DIR="$WORK/demo-store" DEMO_RECEIPT_ANY_CHECKOUT=1
  export DEMO_RECEIPT_DIR DEMO_RECEIPT_ANY_CHECKOUT
  # shellcheck source=../lib/gate-receipt.sh
  . "$SUBJECT"
  rk_gate_receipt write "$R" --clean 1 --count mac=9 >/dev/null 2>&1
  rk_gate_receipt check "$R" --require-clean 2>&1; echo "rc=$?"
  rk_gate_receipt bogus "$R" 2>&1; echo "rc=$?" )"
if grep -q "gate receipt reused" <<<"$out" && grep -q "^rc=0$" <<<"$out" \
   && ls "$WORK/demo-store"/*-clean.json >/dev/null 2>&1 && grep -q "^rc=2$" <<<"$out"; then
  ok "sourced, rk_gate_receipt honors a project's prefix and store, and a bad command is a usage error"
else
  bad "the sourced form misbehaved. Got: $out"
fi

echo "gate-receipt: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
