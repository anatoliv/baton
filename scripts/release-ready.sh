#!/bin/bash
#
# Is this Mac ready to release Baton? One list, before anything starts. (TBX-11003)
#
#   scripts/release-ready.sh            # from the release checkout
#
# On 2026-10-16 the releases stopped one surprise at a time: a locked vault, the gate lock
# held by another run, a public-mirror refusal after the Mac release had shipped. Each was
# knowable in a second before the first step. This reads every precondition it can without
# changing anything, and prints a line for each: ok, WARN (worth knowing) or FAIL (a release
# would stop on it). Exit 1 when any line is FAIL.
#
# It never prints a secret value: credentials are checked by path, owner and mode; the vault by
# whether it answers and whether the named item exists. It reads the gate lock's record and
# never takes, signals or edits the lock.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"

FAILS=0
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; }
fail() { FAILS=$((FAILS + 1)); printf '  FAIL  %s\n' "$*"; }

# shellcheck source=scripts/native-lock.sh
. "$ROOT/scripts/native-lock.sh"

echo "Baton release readiness, $(date '+%Y-%m-%d %H:%M %Z')"

# --- Source -------------------------------------------------------------------------------
head="$(git rev-parse HEAD 2>/dev/null || true)"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  fail "tree: $ROOT has uncommitted changes; a release needs a clean, committed tree"
else
  ok "tree: clean at ${head:0:12}"
fi
if git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
  ok "source: HEAD is on origin/main (as of the last fetch)"
else
  fail "source: HEAD is not on origin/main as of the last fetch; the main guard will refuse it"
fi
if receipt="$("$ROOT/scripts/gate-receipt.sh" check "$ROOT" --require-clean \
     --needs iphone-tests,watch,linux-gateway 2>&1)"; then
  ok "gate: $receipt"
else
  warn "gate: ${receipt#gate receipt not used: }. Run CLEAN=1 ./scripts/test.sh once in a release checkout with WEB01 set, and both releases reuse it"
fi
if public="$("$ROOT/scripts/lint-public-safe.sh" 2>&1)"; then
  ok "public mirror: publish-repo.sh's secrets guard passes on the whole tree"
else
  fail "public mirror: publish-repo.sh would refuse this tree:"
  printf '%s\n' "$public" | grep -E '^[^ ]+:[0-9]+:' | sed 's/^/          /' | head -10
fi

canonical="${BATON_NATIVE_LOCK_CANONICAL:-$HOME/Projects/_method/tools/native-lock.sh}"
if [ ! -f "$canonical" ]; then
  warn "native-lock.sh: no shared copy at $canonical yet; Baton's vendored copy is the only one"
elif cmp -s "$canonical" "$ROOT/scripts/native-lock.sh"; then
  ok "native-lock.sh: byte-identical to the shared copy ($(shasum -a 256 "$canonical" | cut -c1-12))"
else
  fail "native-lock.sh: differs from the shared copy at $canonical; projects would disagree on the lock protocol"
fi

# --- Credentials (paths and modes only) -------------------------------------------------
cred_dir="${BATON_RELEASE_READY_CREDENTIAL_DIR:-$HOME/.config/crashbox}"
if [ -d "$cred_dir" ] && [ "$(stat -f %Lp "$cred_dir")" = 700 ]; then
  ok "credentials: $cred_dir is 0700"
elif [ -d "$cred_dir" ]; then
  fail "credentials: $cred_dir is $(stat -f %Lp "$cred_dir"), not 0700"
else
  fail "credentials: $cred_dir does not exist"
fi
for name in baton-macos-artifact-upload.json baton-ios-artifact-upload.json; do
  f="$cred_dir/$name"
  if [ ! -f "$f" ]; then
    fail "credentials: $name is missing from $cred_dir"
  elif [ "$(stat -f %Lp "$f")" != 600 ]; then
    fail "credentials: $name is mode $(stat -f %Lp "$f"), not 0600"
  elif [ "$(stat -f %Su "$f")" != "$(id -un)" ]; then
    fail "credentials: $name is not owned by $(id -un)"
  else
    ok "credentials: $name present, 0600"
  fi
done

# vault-find prints item names only; its output is matched here and never echoed.
vault_item="${BATON_RELEASE_VAULT_ITEM:-Apple - TestFlight env (baton)}"
if command -v vault-find >/dev/null 2>&1; then
  vault_out="$(vault-find "$vault_item" 2>/dev/null </dev/null)"; vault_rc=$?
  if [ "$vault_rc" = 3 ]; then
    fail "vault: locked; run secrets-unlock in a terminal tab (TestFlight reads \"$vault_item\")"
  elif [ "$vault_rc" != 0 ]; then
    fail "vault: vault-find failed (exit $vault_rc)"
  elif printf '%s' "$vault_out" | grep -qF -- "$vault_item"; then
    ok "vault: unlocked, \"$vault_item\" found"
  else
    fail "vault: unlocked, but no item named \"$vault_item\""
  fi
else
  fail "vault: vault-find is not on PATH"
fi

ids="$(security find-identity -v -p codesigning 2>/dev/null | grep -c 'Developer ID Application' || true)"
if [ "${ids:-0}" -gt 0 ]; then
  ok "signing: $ids Developer ID Application identity(ies) in the keychain"
else
  fail "signing: no Developer ID Application identity in the keychain"
fi

# --- Tools ---------------------------------------------------------------------------------
first_rsync="$(command -v rsync 2>/dev/null || true)"
if [ "$first_rsync" = /usr/bin/rsync ]; then
  ok "rsync: /usr/bin/rsync is first on PATH"
else
  warn "rsync: ${first_rsync:-none} is first on PATH; exportArchive needs /usr/bin/rsync (testflight.sh prepends /usr/bin itself)"
fi
sparkle="${SPARKLE_BIN:-}"
if [ -z "$sparkle" ]; then
  sparkle="$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 6 -path '*/Baton-*/SourcePackages/artifacts/sparkle/Sparkle/bin' -type d 2>/dev/null | head -1)"
fi
if [ -n "$sparkle" ] && [ -x "$sparkle/sign_update" ] && [ -x "$sparkle/generate_keys" ]; then
  ok "sparkle: $sparkle"
else
  fail "sparkle: no Baton Sparkle bin with sign_update and generate_keys (resolve packages in the Mac release checkout)"
fi
xcode="$(xcodebuild -version 2>/dev/null | head -1)"
if [ -n "$xcode" ]; then ok "xcode: $xcode"; else fail "xcode: xcodebuild -version failed"; fi

# --- Shared native resources (read only) ------------------------------------------------
describe_record() {   # $1 = record file, $2 = label
  local pid kind cwd
  pid="$(sed -n '1p' "$1" 2>/dev/null || true)"
  kind="$(sed -n '5p' "$1" 2>/dev/null || true)"
  cwd="$(sed -n '3p' "$1" 2>/dev/null || true)"
  if [ -z "$pid" ]; then
    ok "$2: free (no owner recorded)"
  elif _nl_record_live "$1"; then
    warn "$2: held by ${kind:-unknown} pid $pid from ${cwd:-unknown}; a release waits for it (BATON_GATE_LOCK_WAIT)"
  else
    ok "$2: free (stale record of pid $pid, cleared by the next owner)"
  fi
}
describe_record "$(native_lock_path mac-app-host)" "gate lock (mac-app-host)"
intent="$(native_lock_intent_path mac-app-host)"
if [ -s "$intent" ] && _nl_record_live "$intent"; then
  warn "gate lock: release pid $(sed -n '1p' "$intent") from $(sed -n '3p' "$intent") is already waiting for it"
fi
for f in "$NATIVE_LOCK_DIR"/sim-*.lock; do
  [ -e "$f" ] || continue
  if _nl_record_live "$f"; then describe_record "$f" "$(basename "$f" .lock)"; fi
done

sims="$(xcrun simctl list devices available -j 2>/dev/null | python3 -c '
import json, sys
try: d = json.load(sys.stdin)["devices"]
except Exception: print("0 0"); sys.exit()
phones = sum(1 for r, e in d.items() if "iOS" in r for x in e if "iPhone" in x["name"])
watches = sum(1 for r, e in d.items() if "watchOS" in r for x in e)
print(phones, watches)' 2>/dev/null || echo "0 0")"
phones="${sims% *}"; watches="${sims#* }"
if [ "${phones:-0}" -gt 0 ]; then
  ok "simulators: $phones iPhone simulator(s) available"
else
  fail "simulators: no iPhone simulator available; the gate and the release UI set need one"
fi
if [ "${watches:-0}" -gt 0 ]; then
  ok "simulators: watchOS runtime available (a CLEAN=1 gate requires it)"
else
  fail "simulators: no watchOS simulator; a CLEAN=1 gate refuses without ALLOW_WATCH_SKIP=1"
fi

# --- The owner's Baton ------------------------------------------------------------------
running="$(pgrep -lf 'MacOS/Baton' 2>/dev/null | grep -v 'baton-dd/Build/Products' || true)"
if [ -n "$running" ]; then
  warn "owner's Baton: running ($(printf '%s\n' "$running" | awk '{print $2}' | sort -u | tr '\n' ' ')); quit it before the Mac release reaches packaging (step 4)"
else
  ok "owner's Baton: not running, so packaging will not stop on it"
fi
installed="/Applications/Baton.app/Contents/Info.plist"
if [ -f "$installed" ]; then
  ok "owner's Baton: /Applications has $(defaults read "${installed%.plist}" CFBundleShortVersionString 2>/dev/null || echo unknown)"
fi

echo
if [ "$FAILS" -gt 0 ]; then
  echo "NOT READY: $FAILS item(s) above would stop a release."
  exit 1
fi
echo "READY: nothing above would stop a release. Mac and TestFlight can run side by side."
