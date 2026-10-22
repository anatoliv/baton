#!/usr/bin/env bash
# public-safe.sh: would the public mirror accept this tree? Ask at merge, not at publish.
# Part of the release kit (~/Projects/_method/release-kit.md); the rule it implements is
# "the public-safe lint at merge" in ~/Projects/_method/docs/standards/release.md.
#
# A project that publishes a filtered public copy of itself keeps a guard in its publish
# script that refuses house addresses, machine names and the like. When that guard is the
# only check, a leak merged days earlier stops the mirror after the app has already shipped.
# This runs THE SAME GUARD early, over a staged copy of what the mirror would receive. It
# keeps no copy of the patterns: the project's hooks extract them from the publish script by
# their anchors (rk_extract_block), so the patterns keep one home. The publish script keeps
# its guard unchanged as the final barrier; this is the early warning.
#
#   rk_public_safe [--diff BASE] [--root DIR]
#       The whole tree (tracked, and untracked but not ignored), or with --diff only the files
#       changed since BASE, committed or not. Exit 0 clean, 1 a finding (printed with paths
#       relative to the tree), 2 usage or extraction.
#   rk_extract_block FILE START-REGEX END-REGEX WHAT
#       Prints FILE from the first line matching START through the first later line matching
#       END. Exits 2, naming WHAT, if either anchor is missing, so a renamed block cannot
#       pass silently. Call it from a hook or at the top of the project's script.
#
# Hooks the project defines before calling rk_public_safe (both run in a subshell):
#   public_safe_stage ROOT MIRROR   copy into MIRROR what the publish script would publish,
#                                   with its excludes and purges (RK_PUBLIC_SAFE_ROOT
#                                   is ROOT). The kit then keeps only files git would carry,
#                                   or with --diff only changed ones.
#   public_safe_guard MIRROR        run the publish script's guard over MIRROR; exit nonzero
#                                   on a finding.
#
# Configuration: RK_PUBLIC_SAFE_ROOT (default: the current repository's top level),
# RK_PUBLIC_SAFE_LABEL (default "public mirror guard") and RK_PUBLIC_SAFE_NAME, the publish
# script's name in the refusal (default "the publish script").

rk_extract_block() {   # $1 = file, $2 = start regex, $3 = end regex, $4 = what
  local block
  block="$(XS="$2" XE="$3" awk '
    !on && $0 ~ ENVIRON["XS"] { on = 1; print; next }
    on { print; if ($0 ~ ENVIRON["XE"]) exit }
  ' "$1")"
  if [ -z "$block" ] || ! printf '%s\n' "$block" | tail -1 | grep -qE -- "$3"; then
    echo "lint-public-safe: cannot find $4 in $1" >&2
    exit 2
  fi
  printf '%s\n' "$block"
}

rk_public_safe() (
  set -euo pipefail
  local root="${RK_PUBLIC_SAFE_ROOT:-}" diff_base="" stage mirror rc scope
  local label="${RK_PUBLIC_SAFE_LABEL:-public mirror guard}" name="${RK_PUBLIC_SAFE_NAME:-the publish script}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --diff) diff_base="${2:?--diff needs a base}"; shift 2 ;;
      --root) root="$(cd "${2:?--root needs a directory}" && pwd)"; shift 2 ;;
      *) echo "usage: lint-public-safe.sh [--diff BASE] [--root DIR]" >&2; exit 2 ;;
    esac
  done
  [ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  for hook in public_safe_stage public_safe_guard; do
    declare -F "$hook" >/dev/null || { echo "lint-public-safe: the project defines no $hook" >&2; exit 2; }
  done

  stage="$(mktemp -d -t rk-public-safe.XXXXXX)"
  # shellcheck disable=SC2064 # expand now: the path is fixed for this run
  trap "rm -rf '$stage'" EXIT
  mirror="$stage/mirror"
  mkdir -p "$mirror"
  RK_PUBLIC_SAFE_ROOT="$root" public_safe_stage "$root" "$mirror"

  # Keep only what git would carry (tracked, or untracked and not ignored); with --diff, only
  # what changed since the base. Build output and local state are not a merge's business.
  # NUL-separated (-z): without it git quotes a path with non-ASCII or special characters
  # ("caf\303\251.md"), the quoted name matches no staged file, and that file is dropped
  # from the stage unscanned. Both sides are compared in NFC: with core.precomposeunicode
  # (git's macOS default) git lists a name composed while the stage holds the decomposed
  # bytes on disk.
  ( cd "$root"
    if [ -n "$diff_base" ]; then
      git diff -z --name-only "$diff_base" --; git ls-files -z -o --exclude-standard
    else
      git ls-files -z -co --exclude-standard
    fi ) >"$stage/keep"
  python3 - "$mirror" "$stage/keep" <<'PY'
import os, sys, unicodedata
def nfc(p):
    return unicodedata.normalize("NFC", os.fsdecode(p))
mirror, keep_file = os.fsencode(sys.argv[1]), sys.argv[2]
keep = set(nfc(p) for p in open(keep_file, "rb").read().split(b"\0") if p)
for base, dirs, files in os.walk(mirror):
    for name in files:
        path = os.path.join(base, name)
        if nfc(os.path.relpath(path, mirror)) not in keep:
            os.remove(path)
PY

  scope="the whole tree"; [ -z "$diff_base" ] || scope="files changed since $diff_base"
  # The guard prints its hits with the staging path; show them relative to the tree instead.
  set +e
  ( public_safe_guard "$mirror" ) > >(sed "s#$mirror/##") 2>&1
  rc=$?
  set -e
  wait
  if [ "$rc" = 0 ]; then
    echo "  $label: clean ($scope)"
  else
    echo "  $label: $name would refuse $scope (above). Use the generic" >&2
    echo "  fixtures its comments name, or keep the file out of the mirror." >&2
  fi
  exit "$rc"
)
