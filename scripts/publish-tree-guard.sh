#!/usr/bin/env bash
#
# publish_tree_guard <repo> <label> <path>...
#
# A publish that copies files out of a checkout must copy what the commit says. The main
# guard checks HEAD, but scripts/publish-site.sh rsyncs the WORKING TREE, so an uncommitted
# edit or an untracked file under a shipped path went live while the deploy named a commit
# that did not contain it. This refuses when any of the given paths
# differs from HEAD: modified, staged, deleted, or untracked and not ignored.
#
# One exception, and only in its exact shape: publish.sh rewrites website/index.html (step
# 4d) and Casks/baton.rb (step 4c) in place and leaves them for the operator to commit. Such a
# file passes when every changed line is that rewrite, the version string, the DMG name or
# the cask's version and sha256. Any other edit to it is refused like any other path.
#
# Source it, then: publish_tree_guard "$PWD" "the site" website deploy/nginx

# The release rewrite, normalized away: what is left must be identical on both sides.
publish_tree_normalize() {
  sed -E \
    -e 's/Baton-[0-9]+\.[0-9]+\.[0-9]+\.dmg/Baton-<version>.dmg/g' \
    -e 's/(<p class="eyebrow">Version )[0-9]+\.[0-9]+\.[0-9]+(<\/p>)/\1<version>\2/' \
    -e 's/^(  version ")[0-9.]+(,[0-9]+)?"/\1<version>"/' \
    -e 's/^(  sha256 ")[0-9a-f]{64}"/\1<sha256>"/'
}

# publish_tree_rewrite_only <repo> <path>: 0 when the path's only change from HEAD is the rewrite.
# The whole file is normalized on both sides and compared as it stands, line order included: an
# edit that only moves lines (the CSP meta below the inline script) adds and removes the same
# lines, and a comparison of the changed lines alone, sorted or not, cannot see it.
publish_tree_rewrite_only() {
  local repo="$1" path="$2" committed current
  committed="$(git -C "$repo" show "HEAD:$path" | publish_tree_normalize)" || return 1
  current="$(publish_tree_normalize <"$repo/$path")" || return 1
  [ "$committed" = "$current" ]
}

publish_tree_guard() {
  local repo="$1" label="$2" status line path refused="" allowed=""
  shift 2
  if ! status="$(git -C "$repo" status --porcelain --untracked-files=all -- "$@")"; then
    echo "RELEASE REFUSED: could not read git status in $repo, so whether $label matches HEAD is unknown." >&2
    return 1
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line:3}"
    case "${line:0:2}:$path" in
      ("M :website/index.html"|" M:website/index.html"|"MM:website/index.html"|\
       "M :Casks/baton.rb"|" M:Casks/baton.rb"|"MM:Casks/baton.rb")
        if publish_tree_rewrite_only "$repo" "$path"; then
          allowed="${allowed}    ${line}    [publish.sh's version rewrite only]"$'\n'
          continue
        fi ;;
    esac
    refused="${refused}    ${line}"$'\n'
  done <<EOF
$status
EOF
  if [ -n "$refused" ]; then
    {
      echo "RELEASE REFUSED: $label would publish files that are not HEAD ($(git -C "$repo" rev-parse --short HEAD 2>/dev/null))."
      echo "  These differ from the commit, or are not in it at all:"
      printf '%s' "$refused"
      echo "  Commit them (and merge to origin/main) or remove them, then re-run."
    } >&2
    return 1
  fi
  if [ -n "$allowed" ]; then
    echo "  publish tree ok: $label matches HEAD apart from:"
    printf '%s' "$allowed"
  fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "publish-tree-guard.sh is a library: source it and call publish_tree_guard." >&2
  exit 2
fi
