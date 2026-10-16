#!/bin/bash
#
# scripts/lint-public-safe.sh runs publish-repo.sh's own secrets guard early, at merge.
# This proves it still finds every block it extracts, refuses what the mirror refuses,
# honors the mirror's excludes, and in --diff mode reports only what a branch changed.
# (TBX-11003) Planted trees only; nothing is published. About two seconds.
# shellcheck disable=SC2016 # stubs and greps carry literal $NAMES
set -uo pipefail
cd "$(dirname "$0")/.." || exit
ROOT="$PWD"
LINT="$ROOT/scripts/lint-public-safe.sh"
export BATON_PUBLIC_GUARD_SOURCE="$ROOT/scripts/publish-repo.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '\033[32mok    %s\033[0m\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '\033[31mFAIL  %s\033[0m\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
T="$WORK/tree"
mkdir -p "$T/scripts" "$T/app/Tests" "$T/docs"
git -C "$T" init -q
git -C "$T" config user.email t@example.invalid
git -C "$T" config user.name test
printf 'echo hello\n' >"$T/scripts/tool.sh"
printf 'let host = "mediabox.local"\n' >"$T/app/Tests/FixtureTests.swift"
git -C "$T" add -A && git -C "$T" commit -qm base
BASE="$(git -C "$T" rev-parse HEAD)"

out="$("$LINT" --root "$T" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "clean (the whole tree)"; then
  ok "a clean tree passes, so every block was found in publish-repo.sh"
else
  bad "a clean tree did not pass. Got: $out"
fi

# Shapes taken from the two refusals of 2026-10-16. The address is assembled so this file
# itself never carries one.
lan="192.$((160 + 8)).3.8"
printf 'UPSTREAM="${UPSTREAM:-http://%s:8880}"\n' "$lan" >"$T/scripts/probe.sh"
out="$("$LINT" --root "$T" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "^scripts/probe.sh:1:"; then
  ok "a LAN address left as a script default is refused, with its path in the tree"
else
  bad "a LAN script default was not refused as the mirror would. Got: $out"
fi
rm -f "$T/scripts/probe.sh"

machine="web"; machine="$machine-01"
printf '// talks to %s in production\n' "$machine" >"$T/app/Tests/HostTests.swift"
out="$("$LINT" --root "$T" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "app/Tests/HostTests.swift"; then
  ok "a house machine name in a test fixture is refused (tests are not exempt from it)"
else
  bad "a machine name in a test was not refused. Got: $out"
fi
rm -f "$T/app/Tests/HostTests.swift"

printf 'web host %s\n' "$machine" >"$T/docs/internal-notes.md"
out="$("$LINT" --root "$T" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then
  ok "the mirror's excludes apply: internal docs may name machines"
else
  bad "an excluded path was scanned. Got: $out"
fi
rm -f "$T/docs/internal-notes.md"

# --diff reports what the branch changed, not what was already there.
printf 'old %s\n' "$machine" >"$T/scripts/old.sh"
git -C "$T" add -A && git -C "$T" commit -qm "an old leak"
OLD="$(git -C "$T" rev-parse HEAD)"
printf 'echo fine\n' >"$T/scripts/new.sh"
out="$("$LINT" --root "$T" --diff "$OLD" 2>&1)"; rc=$?
tree_out="$("$LINT" --root "$T" 2>&1)"; tree_rc=$?
if [ "$rc" = 0 ] && [ "$tree_rc" = 1 ] && printf '%s' "$tree_out" | grep -q "scripts/old.sh"; then
  ok "--diff checks only the branch's own changes; the whole-tree run still sees the old one"
else
  bad "diff ($rc) or tree ($tree_rc) scope is wrong. Diff: $out Tree: $tree_out"
fi
printf 'echo %s\n' "$machine" >"$T/scripts/new.sh"
out="$("$LINT" --root "$T" --diff "$BASE" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "scripts/new.sh"; then
  ok "--diff includes uncommitted and untracked changes"
else
  bad "an untracked leak escaped --diff. Got: $out"
fi

# The mirror strips internal task tags before its guard, so a name inside one never ships.
rm -f "$T/scripts/new.sh"
printf '// keeps the queue moving (W-17 %s)\n' "$machine" >"$T/app/Tagged.swift"
out="$("$LINT" --root "$T" --diff "$OLD" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then
  ok "task tags are stripped before the guard, as the mirror does"
else
  bad "a name inside a stripped task tag was reported. Got: $out"
fi
rm -f "$T/app/Tagged.swift"

# A guard that cannot be found must not read as clean.
sed '/^# 3\. Secrets guard/d' "$ROOT/scripts/publish-repo.sh" >"$WORK/renamed.sh"
out="$(BATON_PUBLIC_GUARD_SOURCE="$WORK/renamed.sh" "$LINT" --root "$T" 2>&1)"; rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q "cannot find the Secrets guard section"; then
  ok "a moved or renamed guard block fails loudly instead of passing"
else
  bad "a missing guard anchor did not fail with status 2. Got: $out"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
