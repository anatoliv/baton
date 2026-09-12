#!/bin/bash
#
# Shared admission guard for the Mac and iPhone release scripts.
#
# A release reads its checkout for long enough that using the primary checkout is
# unsafe: a branch switch for unrelated work can change the build underneath it.
# Dedicated clones under /private/tmp are deliberately admitted. Set
# ALLOW_PRIMARY_CHECKOUT=1 only for an intentional emergency override.

release_checkout_realpath() {
  (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
}

release_checkout_first_worktree() {
  git -C "$1" worktree list --porcelain 2>/dev/null \
    | sed -n '1s/^worktree //p'
}

release_checkout_assert_not_primary() {
  local repo="$1" top configured first origin reason=""
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "ERROR: release checkout guard cannot find the repository containing $repo" >&2
    return 1
  }
  top="$(release_checkout_realpath "$top")"
  configured="$(release_checkout_realpath "${BATON_PRIMARY_CHECKOUT:-$HOME/Projects/baton}")"

  if [ "$top" = "$configured" ]; then
    reason="it is the configured primary checkout"
  else
    first="$(release_checkout_first_worktree "$top")"
    [ -n "$first" ] && first="$(release_checkout_realpath "$first")"
    # A standalone clone reports itself as the first and only worktree. The two
    # release clones intentionally have that shape, so /private/tmp is the explicit
    # safe exception. A linked worktree reports the actual primary checkout first.
    case "$top" in
      /private/tmp/*) ;;
      *) [ -n "$first" ] && [ "$top" = "$first" ] && reason="it is git worktree list's first checkout" ;;
    esac
  fi

  [ -n "$reason" ] || return 0

  if [ "${ALLOW_PRIMARY_CHECKOUT:-0}" = "1" ]; then
    echo "WARNING: ALLOW_PRIMARY_CHECKOUT=1 permits release from $top ($reason)." >&2
    return 0
  fi

  origin="$(git -C "$top" remote get-url origin 2>/dev/null || true)"
  [ -n "$origin" ] || origin="<origin>"
  {
    echo "ERROR: refusing to release from the primary checkout: $top"
    echo "  $reason. An unrelated git checkout can change a release while it is building."
    echo "  Recreate the two dedicated release checkouts with these one-line commands:"
    echo "  Mac (/private/tmp/baton-rel):"
    echo "    git clone --branch main $origin /private/tmp/baton-rel && install -m 600 $configured/app/Config/Crashbox.local.xcconfig /private/tmp/baton-rel/app/Config/Crashbox.local.xcconfig"
    echo "  iPhone (/private/tmp/baton-release-tf):"
    echo "    git clone $origin /private/tmp/baton-release-tf && git -C /private/tmp/baton-release-tf checkout --detach origin/main && install -m 600 $configured/ios/Config/Crashbox.local.xcconfig /private/tmp/baton-release-tf/ios/Config/Crashbox.local.xcconfig"
    echo "  Or prepare both safely with: $configured/scripts/prepare-release-checkouts.sh"
    echo "  Set ALLOW_PRIMARY_CHECKOUT=1 only to record an intentional override."
  } >&2
  return 1
}
