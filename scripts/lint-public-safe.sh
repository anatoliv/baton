#!/bin/bash
#
# Would the public mirror accept this tree? Ask at merge, not at publish. (TBX-11003)
#
#   scripts/lint-public-safe.sh                 # the whole tree (tracked + untracked, not ignored)
#   scripts/lint-public-safe.sh --diff BASE     # only files changed since BASE, committed or not
#   scripts/lint-public-safe.sh --root DIR ...  # another checkout
#
# On 2026-10-16 scripts/publish-repo.sh's secrets guard stopped the public mirror twice after
# the Mac release had already shipped: a LAN address left as a script default (TBX-10989),
# then house machine names in test fixtures and comments. Both had been merged days earlier.
#
# This runs THE SAME GUARD. It does not keep a copy of the patterns: it extracts publish-repo.sh's
# EXCLUDES list, its purge of excluded paths, its PUBLIC_DOCS list, its task-tag strip and its
# whole "Secrets guard" section by their anchors and runs them over a staged copy of what the mirror would receive.
# publish-repo.sh keeps that guard unchanged as the final barrier; this is the early warning.
# scripts/test-lint-public-safe.sh proves the extraction still finds every block.
#
# Exit 0 clean, 1 a finding (printed with paths relative to the tree), 2 usage or extraction.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIFF_BASE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --diff) DIFF_BASE="${2:?--diff needs a base}"; shift 2 ;;
    --root) ROOT="$(cd "${2:?--root needs a directory}" && pwd)"; shift 2 ;;
    *) echo "usage: lint-public-safe.sh [--diff BASE] [--root DIR]" >&2; exit 2 ;;
  esac
done
GUARD_SOURCE="${BATON_PUBLIC_GUARD_SOURCE:-$(cd "$(dirname "$0")" && pwd)/publish-repo.sh}"

# Print the lines of $GUARD_SOURCE from the first line matching $1 through the first later line
# matching $2. Fails if either anchor is missing, so a renamed block cannot pass silently.
extract() {   # $1 = start regex, $2 = end regex, $3 = what
  local block
  block="$(XS="$1" XE="$2" awk '
    !on && $0 ~ ENVIRON["XS"] { on = 1; print; next }
    on { print; if ($0 ~ ENVIRON["XE"]) exit }
  ' "$GUARD_SOURCE")"
  if [ -z "$block" ] || ! printf '%s\n' "$block" | tail -1 | grep -qE -- "$2"; then
    echo "lint-public-safe: cannot find $3 in $GUARD_SOURCE" >&2
    exit 2
  fi
  printf '%s\n' "$block"
}

EXCLUDES_BLOCK="$(extract '^EXCLUDES=[(]$' '^[)]$' 'the EXCLUDES list')"
PURGE_BLOCK="$(extract '^rm -rf "[$]MIRROR"/docs ' "-name '[*][.]local[.]json' .*-delete" 'the purge of excluded paths')"
DOCS_BLOCK="$(extract '^PUBLIC_DOCS=[(]$' '^[)]$' 'the PUBLIC_DOCS list')"
TAGS_BLOCK="$(extract '^bold "==> Stripping internal task tags"$' "s/W-\\[0-9\\]\\[0-9\\]\\*//g'$" 'the task-tag strip')"
GUARD_BLOCK="$(extract '^# 3[.] Secrets guard' '^echo "    clean"$' 'the Secrets guard section')"

STAGE="$(mktemp -d -t baton-public-safe)"
trap 'rm -rf "$STAGE"' EXIT
MIRROR="$STAGE/mirror"
mkdir -p "$MIRROR"

eval "$EXCLUDES_BLOCK"
eval "$DOCS_BLOCK"
# shellcheck disable=SC2154 # EXCLUDES and PUBLIC_DOCS come from the extracted blocks
/usr/bin/rsync -a "${EXCLUDES[@]}" "$ROOT/" "$MIRROR/"
eval "$PURGE_BLOCK"
mkdir -p "$MIRROR/docs"
for d in "${PUBLIC_DOCS[@]}"; do
  [ -f "$ROOT/docs/$d" ] && cp "$ROOT/docs/$d" "$MIRROR/docs/$d"
done

# Keep only what git would carry (tracked, or untracked and not ignored); with --diff, only
# what changed since the base. Build output and local state are not a merge's business.
( cd "$ROOT"
  if [ -n "$DIFF_BASE" ]; then
    { git diff --name-only "$DIFF_BASE" --; git ls-files -o --exclude-standard; } | sort -u
  else
    git ls-files -co --exclude-standard
  fi ) >"$STAGE/keep"
python3 - "$MIRROR" "$STAGE/keep" <<'PY'
import os, sys
mirror, keep_file = sys.argv[1], sys.argv[2]
keep = set(line.rstrip("\n") for line in open(keep_file) if line.strip())
for base, dirs, files in os.walk(mirror):
    for name in files:
        path = os.path.join(base, name)
        if os.path.relpath(path, mirror) not in keep:
            os.remove(path)
PY

# shellcheck disable=SC2329 # called by the extracted guard block
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
# shellcheck disable=SC2329 # called by the extracted guard block
fail() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
# The mirror strips internal task tags before its guard runs; do the same, so a hit inside
# a tag the mirror would have removed is not reported.
( eval "$TAGS_BLOCK" ) >/dev/null 2>&1 || true
scope="the whole tree"; [ -z "$DIFF_BASE" ] || scope="files changed since $DIFF_BASE"
# The guard prints its hits with the staging path; show them relative to the tree instead.
set +e
( eval "$GUARD_BLOCK" ) > >(sed "s#$MIRROR/##") 2>&1
rc=$?
set -e
wait
if [ "$rc" = 0 ]; then
  echo "  public mirror guard: clean ($scope)"
else
  echo "  public mirror guard: publish-repo.sh would refuse $scope (above). Use the generic" >&2
  echo "  fixtures its comments name, or keep the file out of the mirror." >&2
fi
exit "$rc"
