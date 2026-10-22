#!/bin/bash
#
# Would the public mirror accept this tree? Ask at merge, not at publish.
#
#   scripts/lint-public-safe.sh                 # the whole tree (tracked + untracked, not ignored)
#   scripts/lint-public-safe.sh --diff BASE     # only files changed since BASE, committed or not
#   scripts/lint-public-safe.sh --root DIR ...  # another checkout
#
# On 2026-10-16 scripts/publish-repo.sh's secrets guard stopped the public mirror twice after
# the Mac release had already shipped: a LAN address left as a script default,
# then house machine names in test fixtures and comments. Both had been merged days earlier.
#
# This runs THE SAME GUARD. It does not keep a copy of the patterns: it extracts publish-repo.sh's
# EXCLUDES list, its purge of excluded paths, its PUBLIC_DOCS list, its task-tag strip and its
# whole "Secrets guard" section by their anchors and runs them over a staged copy of what the mirror would receive.
# publish-repo.sh keeps that guard unchanged as the final barrier; this is the early warning.
# The staging, the --diff scope and the reporting are the release kit's lib/public-safe.sh
# (rule: the public-safe lint at merge, ~/Projects/_method/docs/standards/release.md); the
# two hooks below are Baton's. scripts/test-lint-public-safe.sh proves the extraction still
# finds every block.
#
# Exit 0 clean, 1 a finding (printed with paths relative to the tree), 2 usage or extraction.
set -euo pipefail

# shellcheck source=scripts/release-kit/lib/public-safe.sh
. "$(cd "$(dirname "$0")" && pwd)/release-kit/lib/public-safe.sh"

RK_PUBLIC_SAFE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RK_PUBLIC_SAFE_LABEL="public mirror guard"
RK_PUBLIC_SAFE_NAME="publish-repo.sh"
GUARD_SOURCE="${BATON_PUBLIC_GUARD_SOURCE:-$(cd "$(dirname "$0")" && pwd)/publish-repo.sh}"

EXCLUDES_BLOCK="$(rk_extract_block "$GUARD_SOURCE" '^EXCLUDES=[(]$' '^[)]$' 'the EXCLUDES list')"
PURGE_BLOCK="$(rk_extract_block "$GUARD_SOURCE" '^for exclude in "[$][{]EXCLUDES\[@\][}]"; do$' '^done   # end of the purge of excluded paths$' 'the purge of excluded paths')"
DOCS_BLOCK="$(rk_extract_block "$GUARD_SOURCE" '^PUBLIC_DOCS=[(]$' '^[)]$' 'the PUBLIC_DOCS list')"
TAGS_BLOCK="$(rk_extract_block "$GUARD_SOURCE" '^bold "==> Stripping internal task tags"$' '^# end of the task-tag strip$' 'the task-tag strip')"
GUARD_BLOCK="$(rk_extract_block "$GUARD_SOURCE" '^# 3[.] Secrets guard' '^echo "    clean"$' 'the Secrets guard section')"

# What publish-repo.sh would copy into its mirror: its excludes, its purge, its public docs.
public_safe_stage() {   # $1 = tree, $2 = mirror
  local ROOT="$1" MIRROR="$2" d
  eval "$EXCLUDES_BLOCK"
  eval "$DOCS_BLOCK"
  # shellcheck disable=SC2154 # EXCLUDES and PUBLIC_DOCS come from the extracted blocks
  /usr/bin/rsync -a "${EXCLUDES[@]}" "$ROOT/" "$MIRROR/"
  eval "$PURGE_BLOCK"
  mkdir -p "$MIRROR/docs"
  for d in "${PUBLIC_DOCS[@]}"; do
    [ -f "$ROOT/docs/$d" ] && cp "$ROOT/docs/$d" "$MIRROR/docs/$d"
  done
  return 0
}

# publish-repo.sh's own guard, after its own task-tag strip.
public_safe_guard() {   # $1 = mirror
  # shellcheck disable=SC2034 # the extracted blocks read MIRROR
  local MIRROR="$1"
  # shellcheck disable=SC2329 # called by the extracted guard block
  bold() { printf '\033[1m%s\033[0m\n' "$*"; }
  # shellcheck disable=SC2329 # called by the extracted guard block
  fail() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
  # The mirror strips internal task tags before its guard runs; do the same, so a hit inside
  # a tag the mirror would have removed is not reported.
  ( eval "$TAGS_BLOCK" ) >/dev/null 2>&1 || true
  eval "$GUARD_BLOCK"
}

rk_public_safe "$@"
