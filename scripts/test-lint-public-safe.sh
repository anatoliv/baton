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
if [ "$rc" = 0 ] && grep -q <<<"$out" "clean (the whole tree)"; then
  ok "a clean tree passes, so every block was found in publish-repo.sh"
else
  bad "a clean tree did not pass. Got: $out"
fi

# Shapes taken from the two refusals of 2026-10-16. The address is assembled so this file
# itself never carries one.
lan="192.$((160 + 8)).3.8"
printf 'UPSTREAM="${UPSTREAM:-http://%s:8880}"\n' "$lan" >"$T/scripts/probe.sh"
out="$("$LINT" --root "$T" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q <<<"$out" "^scripts/probe.sh:1:"; then
  ok "a LAN address left as a script default is refused, with its path in the tree"
else
  bad "a LAN script default was not refused as the mirror would. Got: $out"
fi
rm -f "$T/scripts/probe.sh"

machine="web"; machine="$machine-01"
printf '// talks to %s in production\n' "$machine" >"$T/app/Tests/HostTests.swift"
out="$("$LINT" --root "$T" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q <<<"$out" "app/Tests/HostTests.swift"; then
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
if [ "$rc" = 0 ] && [ "$tree_rc" = 1 ] && grep -q <<<"$tree_out" "scripts/old.sh"; then
  ok "--diff checks only the branch's own changes; the whole-tree run still sees the old one"
else
  bad "diff ($rc) or tree ($tree_rc) scope is wrong. Diff: $out Tree: $tree_out"
fi
printf 'echo %s\n' "$machine" >"$T/scripts/new.sh"
out="$("$LINT" --root "$T" --diff "$BASE" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q <<<"$out" "scripts/new.sh"; then
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
if [ "$rc" = 2 ] && grep -q <<<"$out" "cannot find the Secrets guard section"; then
  ok "a moved or renamed guard block fails loudly instead of passing"
else
  bad "a missing guard anchor did not fail with status 2. Got: $out"
fi

# An exclude also needs a purge: rsync protects an excluded path inherited from
# the old public checkout. Exercise the publisher's actual purge on a planted
# old mirror, retaining app source beside the internal evidence fixture.
. "$ROOT/scripts/release-kit/lib/public-safe.sh"
MIRROR="$WORK/inherited-mirror"
mkdir -p "$MIRROR/evidence/old" "$MIRROR/app"
printf 'internal result fixture\n' >"$MIRROR/evidence/old/result-path.txt"
printf 'public app fixture\n' >"$MIRROR/app/Keep.swift"
# The purge is derived from EXCLUDES (TBX-1000000503 F-8), so both blocks run together.
EXCL="$(rk_extract_block "$ROOT/scripts/publish-repo.sh" '^EXCLUDES=[(]$' '^[)]$' 'the EXCLUDES list')"
PURGE="$(rk_extract_block "$ROOT/scripts/publish-repo.sh" '^for exclude in "[$][{]EXCLUDES\[@\][}]"; do$' '^done   # end of the purge of excluded paths$' 'the purge of excluded paths')"
# shellcheck disable=SC2329 # fail is called by the evaluated purge
if [ -n "$EXCL" ] && [ -n "$PURGE" ] && (fail() { exit 1; }; eval "$EXCL"; eval "$PURGE") && \
   [ ! -e "$MIRROR/evidence" ] && [ -f "$MIRROR/app/Keep.swift" ]; then
  ok "the stock purge removes inherited internal evidence and retains app source"
else
  bad "excluded internal evidence survives the public mirror purge"
fi

# TBX-1000000605: GitHub push protection refused a mirror push for a real-shaped Discord bot
# token in a test fixture, which the guard had passed. Each shape it refuses is planted in a
# test file of a fresh tree and must be refused by the same guard; the runtime-assembled form
# fixtures use must pass. Every token here is built from pieces, so no line of this file is one.
T2="$WORK/tokens"
mkdir -p "$T2/app/Tests"
git -C "$T2" init -q
printf 'let ok = true\n' >"$T2/app/Tests/Base.swift"
digits="MTIzNDU2Nzg5""MDEyMzQ1Njc4"
for shape in \
  "discord|bot $digits.GhJkLm.abcdefghijklmnopqrstuvwxyz0123" \
  "google|AIza""SyA1234567890abcdefghijklmnopqrstuvw" \
  "github-user|ghu""_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" \
  "github-fine|github""_pat_11ABCDEFG0123456789_abcdefghij" \
  "slack-webhook|https://hooks.slack"".com/services/T000/B000/abcdefXYZ" \
  "stripe|sk""_live_0123456789abcdefghijABCD" \
  "aws-session|ASIA""IOSFODNN7EXAMPLE" \
  "anthropic|sk-ant""-api03-abcdefghijklmnopqrstuvwxyz0123" \
  "openai|sk-proj-abc""T3Blbk""FJ""xyz" \
  "npm|npm""_abcdefghijklmnopqrstuvwxyz0123456789" \
  "sendgrid|SG"".abcdefghijklmnopqrstuv.abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG" \
  "telegram|123456789"":AAabcdefghijklmnopqrstuvwxyz0123456"; do
  name="${shape%%|*}"; token="${shape#*|}"
  printf 'let fixture = "%s"\n' "$token" >"$T2/app/Tests/TokenFixture.swift"
  out="$("$LINT" --root "$T2" 2>&1)"; rc=$?
  if [ "$rc" = 1 ] && grep -q <<<"$out" "app/Tests/TokenFixture.swift"; then
    ok "a real-shaped $name token in a test fixture is refused"
  else
    bad "a real-shaped $name token was not refused (rc $rc). Got: $out"
  fi
done
printf '%s\n' 'let googleKey = "AIza" + "SyA1234567890abcdefghijklmnopqrstuvw"' \
  'let discordUserID = "MTIzNDU2Nzg5" + "MDEyMzQ1Njc4"' \
  'let dotted = "MyAppDelegate.window.rootViewControllerAndMore"' >"$T2/app/Tests/TokenFixture.swift"
out="$("$LINT" --root "$T2" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then
  ok "fixtures that assemble their tokens at runtime, and dotted identifiers, pass"
else
  bad "a runtime-assembled fixture or a dotted identifier was refused. Got: $out"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
