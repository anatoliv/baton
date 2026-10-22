#!/bin/bash
#
# Is this Mac ready to release Baton? One list, before anything starts.
#
#   scripts/release-ready.sh            # from the release checkout
#
# On 2026-10-16 the releases stopped one surprise at a time: a locked vault, the gate lock
# held by another run, a public-mirror refusal after the Mac release had shipped. Each was
# knowable in a second before the first step. This reads every precondition it can without
# changing anything, and prints a line for each: ok, WARN (worth knowing) or FAIL (a release
# would stop on it). Exit 1 when any line is FAIL.
#
# The scaffold and the generic checks are the release kit's lib/ready.sh (rule: the readiness
# check in ~/Projects/_method/docs/standards/release.md); the hooks below are Baton's list.
# It never prints a secret value: credentials are checked by path, owner and mode; the vault by
# whether it answers and whether the named item exists. It reads the gate lock's record and
# never takes, signals or edits the lock.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"

# shellcheck source=scripts/native-lock.sh
. "$ROOT/scripts/native-lock.sh"
# shellcheck source=scripts/release-kit/lib/ready.sh
. "$ROOT/scripts/release-kit/lib/ready.sh"

ready_source() {
  rk_ready_tree "$ROOT"
  rk_ready_on_main "$ROOT"
  local receipt public canonical
  if receipt="$("$ROOT/scripts/gate-receipt.sh" check "$ROOT" --require-clean \
       --needs iphone-tests,watch,linux-gateway 2>&1)"; then
    rk_ready_ok "gate: $receipt"
  else
    rk_ready_warn "gate: ${receipt#gate receipt not used: }. Run CLEAN=1 ./scripts/test.sh once in a release checkout with WEB01 set, and both releases reuse it"
  fi
  if public="$("$ROOT/scripts/lint-public-safe.sh" 2>&1)"; then
    rk_ready_ok "public mirror: publish-repo.sh's secrets guard passes on the whole tree"
  else
    rk_ready_fail "public mirror: publish-repo.sh would refuse this tree:"
    printf '%s\n' "$public" | grep -E '^[^ ]+:[0-9]+:' | sed 's/^/          /' | head -10
  fi
  # The lock protocol is the release kit's module, pinned by its manifest (the pin refuses an
  # edited copy; the gate runs the kit's tests). _method/tools/native-lock.sh is a byte copy
  # of it for projects without the kit; a difference means one side is on another version.
  if bash "$ROOT/scripts/release-kit/lib/pin.sh" "$ROOT/scripts/release-kit" >/dev/null 2>&1; then
    rk_ready_ok "release kit: $(head -1 "$ROOT/scripts/release-kit/VERSION") matches its pin"
  else
    rk_ready_fail "release kit: scripts/release-kit does not match its pin; re-vendor it with the kit's bin/sync.sh"
  fi
  canonical="${BATON_NATIVE_LOCK_CANONICAL:-$HOME/Projects/_method/tools/native-lock.sh}"
  if [ ! -f "$canonical" ]; then
    rk_ready_warn "native-lock: no shared copy at $canonical; the vendored kit module is the only one here"
  elif cmp -s "$canonical" "$ROOT/scripts/release-kit/lib/native-lock.sh"; then
    rk_ready_ok "native-lock: the kit module is byte-identical to the shared copy ($(shasum -a 256 "$canonical" | cut -c1-12))"
  else
    rk_ready_warn "native-lock: the kit module differs from the shared copy at $canonical; one of them is on another kit version"
  fi
}

ready_credentials() {   # paths and modes only
  local cred_dir="${BATON_RELEASE_READY_CREDENTIAL_DIR:-$HOME/.config/crashbox}" name ids
  rk_ready_credential_dir "$cred_dir"
  for name in baton-macos-artifact-upload.json baton-ios-artifact-upload.json; do
    rk_ready_credential_file "$cred_dir" "$name"
  done
  rk_ready_vault "${BATON_RELEASE_VAULT_ITEM:-Apple - TestFlight env (baton)}" TestFlight
  ids="$(security find-identity -v -p codesigning 2>/dev/null | grep -c 'Developer ID Application' || true)"
  if [ "${ids:-0}" -gt 0 ]; then
    rk_ready_ok "signing: $ids Developer ID Application identity(ies) in the keychain"
  else
    rk_ready_fail "signing: no Developer ID Application identity in the keychain"
  fi
}

ready_tools() {
  local first_rsync sparkle xcode
  first_rsync="$(command -v rsync 2>/dev/null || true)"
  if [ "$first_rsync" = /usr/bin/rsync ]; then
    rk_ready_ok "rsync: /usr/bin/rsync is first on PATH"
  else
    rk_ready_warn "rsync: ${first_rsync:-none} is first on PATH; exportArchive needs /usr/bin/rsync (testflight.sh prepends /usr/bin itself)"
  fi
  sparkle="${SPARKLE_BIN:-}"
  if [ -z "$sparkle" ]; then
    sparkle="$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 6 -path '*/Baton-*/SourcePackages/artifacts/sparkle/Sparkle/bin' -type d 2>/dev/null | head -1)"
  fi
  if [ -n "$sparkle" ] && [ -x "$sparkle/sign_update" ] && [ -x "$sparkle/generate_keys" ]; then
    rk_ready_ok "sparkle: $sparkle"
  else
    rk_ready_fail "sparkle: no Baton Sparkle bin with sign_update and generate_keys (resolve packages in the Mac release checkout)"
  fi
  xcode="$(xcodebuild -version 2>/dev/null | head -1)"
  if [ -n "$xcode" ]; then rk_ready_ok "xcode: $xcode"; else rk_ready_fail "xcode: xcodebuild -version failed"; fi
}

ready_resources() {   # read only
  local sims phones watches
  rk_ready_native_locks
  sims="$(xcrun simctl list devices available -j 2>/dev/null | python3 -c '
import json, sys
try: d = json.load(sys.stdin)["devices"]
except Exception: print("0 0"); sys.exit()
phones = sum(1 for r, e in d.items() if "iOS" in r for x in e if "iPhone" in x["name"])
watches = sum(1 for r, e in d.items() if "watchOS" in r for x in e)
print(phones, watches)' 2>/dev/null || echo "0 0")"
  phones="${sims% *}"; watches="${sims#* }"
  if [ "${phones:-0}" -gt 0 ]; then
    rk_ready_ok "simulators: $phones iPhone simulator(s) available"
  else
    rk_ready_fail "simulators: no iPhone simulator available; the gate and the release UI set need one"
  fi
  if [ "${watches:-0}" -gt 0 ]; then
    rk_ready_ok "simulators: watchOS runtime available (a CLEAN=1 gate requires it)"
  else
    rk_ready_fail "simulators: no watchOS simulator; a CLEAN=1 gate refuses without ALLOW_WATCH_SKIP=1"
  fi
}

ready_owner_app() {
  local running installed="/Applications/Baton.app/Contents/Info.plist"
  running="$(pgrep -lf 'MacOS/Baton' 2>/dev/null | grep -v 'baton-dd/Build/Products' || true)"
  if [ -n "$running" ]; then
    rk_ready_warn "owner's Baton: running ($(printf '%s\n' "$running" | awk '{print $2}' | sort -u | tr '\n' ' ')); quit it before the Mac release reaches packaging (step 4)"
  else
    rk_ready_ok "owner's Baton: not running, so packaging will not stop on it"
  fi
  if [ -f "$installed" ]; then
    rk_ready_ok "owner's Baton: /Applications has $(defaults read "${installed%.plist}" CFBundleShortVersionString 2>/dev/null || echo unknown)"
  fi
}

rk_ready_run "Baton release readiness" "Mac and TestFlight can run side by side." \
  ready_source ready_credentials ready_tools ready_resources ready_owner_app
