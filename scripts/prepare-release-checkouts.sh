#!/bin/bash
# Create or refresh the two dedicated Baton release clones and install their
# gitignored Crashbox inputs with owner-only permissions.
set -euo pipefail
umask 077

PRIMARY="${BATON_PRIMARY_CHECKOUT:-$HOME/Projects/baton}"
MAC_RELEASE="${BATON_MAC_RELEASE_CHECKOUT:-/private/tmp/baton-rel}"
IOS_RELEASE="${BATON_IOS_RELEASE_CHECKOUT:-/private/tmp/baton-release-tf}"

PRIMARY="$(cd "$PRIMARY" 2>/dev/null && pwd -P)" || {
  echo "ERROR: primary checkout not found: ${BATON_PRIMARY_CHECKOUT:-$HOME/Projects/baton}" >&2
  exit 1
}
canonical_target() {
  local path="$1" parent name
  parent="$(dirname "$path")"
  name="$(basename "$path")"
  parent="$(cd "$parent" 2>/dev/null && pwd -P)" || {
    echo "ERROR: parent directory does not exist: $(dirname "$path")" >&2
    return 1
  }
  printf '%s/%s\n' "$parent" "$name"
}

MAC_RELEASE="$(canonical_target "$MAC_RELEASE")"
IOS_RELEASE="$(canonical_target "$IOS_RELEASE")"
[ "$MAC_RELEASE" != "$PRIMARY" ] && [ "$IOS_RELEASE" != "$PRIMARY" ] || {
  echo "ERROR: a release checkout path resolves to the primary checkout: $PRIMARY" >&2
  exit 1
}
[ "$MAC_RELEASE" != "$IOS_RELEASE" ] || {
  echo "ERROR: Mac and iPhone release checkout paths must be different" >&2
  exit 1
}

ORIGIN="${BATON_RELEASE_ORIGIN:-}"
[ -n "$ORIGIN" ] || ORIGIN="$(git -C "$PRIMARY" remote get-url origin 2>/dev/null || true)"
[ -n "$ORIGIN" ] || { echo "ERROR: the primary checkout has no origin remote" >&2; exit 1; }

MAC_CONFIG="$PRIMARY/app/Config/Crashbox.local.xcconfig"
IOS_CONFIG="$PRIMARY/ios/Config/Crashbox.local.xcconfig"
for config in "$MAC_CONFIG" "$IOS_CONFIG"; do
  [ -f "$config" ] || {
    echo "ERROR: required release configuration is missing: $config" >&2
    exit 1
  }
done

assert_refreshable_clone() {
  local path="$1" actual_top actual_origin
  [ -e "$path" ] || return 0
  [ -d "$path" ] || { echo "ERROR: release path exists and is not a directory: $path" >&2; return 1; }
  actual_top="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "ERROR: refusing to replace non-Git directory: $path" >&2
    return 1
  }
  actual_top="$(cd "$actual_top" && pwd -P)"
  [ "$actual_top" = "$(cd "$path" && pwd -P)" ] || {
    echo "ERROR: $path is inside another checkout, not a dedicated release clone" >&2
    return 1
  }
  actual_origin="$(git -C "$path" remote get-url origin 2>/dev/null || true)"
  [ "$actual_origin" = "$ORIGIN" ] || {
    echo "ERROR: refusing to refresh $path because origin is '$actual_origin', expected '$ORIGIN'" >&2
    return 1
  }
  [ -z "$(git -C "$path" status --porcelain)" ] || {
    echo "ERROR: refusing to refresh dirty release checkout: $path" >&2
    return 1
  }
}

prepare_mac() {
  if [ ! -e "$MAC_RELEASE" ]; then
    git clone --quiet --branch main "$ORIGIN" "$MAC_RELEASE"
  else
    assert_refreshable_clone "$MAC_RELEASE"
    git -C "$MAC_RELEASE" fetch --quiet --prune origin main
    git -C "$MAC_RELEASE" checkout --quiet -B main origin/main
    git -C "$MAC_RELEASE" reset --quiet --hard origin/main
  fi
  mkdir -p "$MAC_RELEASE/app/Config"
  install -m 600 "$MAC_CONFIG" "$MAC_RELEASE/app/Config/Crashbox.local.xcconfig"
}

prepare_ios() {
  if [ ! -e "$IOS_RELEASE" ]; then
    git clone --quiet "$ORIGIN" "$IOS_RELEASE"
  else
    assert_refreshable_clone "$IOS_RELEASE"
    git -C "$IOS_RELEASE" fetch --quiet --prune origin main
  fi
  git -C "$IOS_RELEASE" checkout --quiet --detach origin/main
  git -C "$IOS_RELEASE" reset --quiet --hard origin/main
  mkdir -p "$IOS_RELEASE/ios/Config"
  install -m 600 "$IOS_CONFIG" "$IOS_RELEASE/ios/Config/Crashbox.local.xcconfig"
}

prepare_mac
prepare_ios

echo "Prepared Mac release checkout: $MAC_RELEASE ($(git -C "$MAC_RELEASE" rev-parse --short=12 HEAD))"
echo "Prepared iPhone release checkout: $IOS_RELEASE ($(git -C "$IOS_RELEASE" rev-parse --short=12 HEAD), detached)"
echo "Installed both Crashbox.local.xcconfig files with mode 0600."
