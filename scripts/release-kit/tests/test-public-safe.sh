#!/usr/bin/env bash
# test-public-safe.sh: the public-safe lint runs a publish script's own guard, extracted by its
# anchors, over a staged copy of what the mirror would receive: it refuses what the guard
# refuses with paths relative to the tree, honors the excludes and .gitignore, checks only a
# branch's own changes with --diff (untracked files included), and fails loudly (exit 2) when
# an anchor or a hook is missing. Planted trees and a planted publish script; nothing is
# published. RK_PUBLIC_SAFE_SUBJECT points at a mutated copy. About two seconds.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUBJECT="${RK_PUBLIC_SAFE_SUBJECT:-$HERE/../lib/public-safe.sh}"
[ -f "$SUBJECT" ] || { echo "FAIL  no module at $SUBJECT"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/rk-public-safe.XXXXXX")" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT INT TERM
export SUBJECT

# A publish script in the shape the lint expects: an excludes list and a guard section,
# each between anchors. The forbidden word is assembled so this file never carries one.
word="private"; word="$word-hostname"
cat >"$WORK/publish.sh" <<PUB
#!/bin/bash
EXCLUDES=(
  --exclude=.git
  --exclude=docs/internal/
)
rsync -a "\${EXCLUDES[@]}" ./ "\$MIRROR/"
# Guard: begin
hits="\$(grep -rnE '$word-[0-9]+' "\$MIRROR" || true)"
if [ -n "\$hits" ]; then printf '%s\n' "\$hits" >&2; exit 1; fi
echo "guard clean"
# Guard: end
PUB

# The project's lint, as a project writes it: extract at the top, two hooks, one call.
cat >"$WORK/lint.sh" <<'LINT'
#!/bin/bash
set -euo pipefail
. "$SUBJECT"
RK_PUBLIC_SAFE_NAME="publish.sh"
EXCLUDES_BLOCK="$(rk_extract_block "$GUARD_SOURCE" '^EXCLUDES=[(]$' '^[)]$' 'the EXCLUDES list')"
GUARD_BLOCK="$(rk_extract_block "$GUARD_SOURCE" '^# Guard: begin$' '^# Guard: end$' 'the guard section')"
public_safe_stage() {
  eval "$EXCLUDES_BLOCK"
  /usr/bin/rsync -a "${EXCLUDES[@]}" "$1/" "$2/"
}
public_safe_guard() { local MIRROR="$1"; eval "$GUARD_BLOCK"; }
[ -z "${DROP_HOOK:-}" ] || unset -f "$DROP_HOOK"
rk_public_safe "$@"
LINT
chmod +x "$WORK/lint.sh"
export GUARD_SOURCE="$WORK/publish.sh"
mkdir -p "$WORK/tmp"
L() { TMPDIR="$WORK/tmp" "$WORK/lint.sh" "$@" 2>&1; }   # its own TMPDIR, to see what is left

T="$WORK/tree"
mkdir -p "$T/scripts" "$T/docs/internal" "$T/build"
git -C "$T" init -q; git -C "$T" config user.email t@example.invalid; git -C "$T" config user.name test
printf 'echo hello\n' >"$T/scripts/tool.sh"
printf 'build/\n' >"$T/.gitignore"
git -C "$T" add -A && git -C "$T" commit -qm base
BASE="$(git -C "$T" rev-parse HEAD)"

out="$(L --root "$T")"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q "public mirror guard: clean (the whole tree)" \
  && ok "a clean tree passes, so both blocks were found and ran" || bad "a clean tree did not pass. Got: $out"

printf 'HOST=${HOST:-%s-01}\n' "$word" >"$T/scripts/probe.sh"
out="$(L --root "$T")"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "^scripts/probe.sh:1:" \
  && printf '%s' "$out" | grep -q "publish.sh would refuse the whole tree" \
  && ok "a hit is refused with its path relative to the tree, naming the publish script" || bad "a hit was not refused as the guard would. Got: $out"
rm -f "$T/scripts/probe.sh"

printf 'notes %s-02\n' "$word" >"$T/docs/internal/notes.md"
printf 'cache %s-03\n' "$word" >"$T/build/out.txt"
out="$(L --root "$T")"; rc=$?
[ "$rc" = 0 ] && ok "the publish script's excludes and the tree's .gitignore both apply" || bad "an excluded or ignored file was scanned. Got: $out"
rm -f "$T/docs/internal/notes.md" "$T/build/out.txt"

printf 'old %s-04\n' "$word" >"$T/scripts/old.sh"
git -C "$T" add -A && git -C "$T" commit -qm "an old leak"
OLD="$(git -C "$T" rev-parse HEAD)"
printf 'echo fine\n' >"$T/scripts/new.sh"
out="$(L --root "$T" --diff "$OLD")"; rc=$?
tree_out="$(L --root "$T")"; tree_rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "clean (files changed since $OLD)" \
   && [ "$tree_rc" = 1 ] && printf '%s' "$tree_out" | grep -q "scripts/old.sh"; then
  ok "--diff checks only the branch's changes; the whole-tree run still sees the old one"
else
  bad "diff ($rc) or tree ($tree_rc) scope is wrong. Diff: $out Tree: $tree_out"
fi
printf 'echo %s-05\n' "$word" >"$T/scripts/new.sh"
out="$(L --root "$T" --diff "$BASE")"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "scripts/new.sh" \
  && ok "--diff includes untracked and uncommitted changes" || bad "an untracked leak escaped --diff. Got: $out"
rm -f "$T/scripts/new.sh"

sed '/^# Guard: begin$/d' "$WORK/publish.sh" >"$WORK/renamed.sh"
out="$(GUARD_SOURCE="$WORK/renamed.sh" L --root "$T")"; rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -q "cannot find the guard section in $WORK/renamed.sh" \
  && ok "a moved or renamed anchor fails with status 2 instead of passing" || bad "a missing anchor did not fail with 2. Got: $out"
sed '/^# Guard: end$/d' "$WORK/publish.sh" >"$WORK/unended.sh"
out="$(GUARD_SOURCE="$WORK/unended.sh" L --root "$T")"; rc=$?
[ "$rc" = 2 ] && ok "a block whose end anchor is gone fails with status 2" || bad "a missing end anchor did not fail with 2. Got: $out"
out="$(DROP_HOOK=public_safe_guard L --root "$T")"; rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -q "the project defines no public_safe_guard" \
  && ok "a missing hook fails with status 2" || bad "a missing hook did not fail with 2. Got: $out"
out="$(L --bogus)"; rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -q "usage:" && ok "an unknown option is a usage error" || bad "a bad option was accepted. Got: $out"
[ -z "$(ls -A "$WORK/tmp")" ] && ok "the staging copy is removed after every run" || bad "staging left behind: $(ls -A "$WORK/tmp")"

echo "public-safe: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
