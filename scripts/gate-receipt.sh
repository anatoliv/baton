#!/bin/bash
#
# Gate receipts: run the full test gate once per commit and let both releases use the
# result. (TBX-11003)
#
#   gate-receipt.sh write REPO --clean 0|1 --mac TEXT --ios TEXT --gateway TEXT [--skips LIST]
#   gate-receipt.sh check REPO [--require-clean] [--needs STAGE,STAGE]
#
# `write` is called by scripts/test.sh after a passing FULL run (no pass-through arguments,
# no SKIP_IOS, no ALLOW_NO_TESTS, no concurrency override) over a clean tree that did not
# move during the run. It records the commit, a digest of scripts/test.sh, the Xcode
# version, the counts each stage reported, the skipped stages and the time.
#
# `check` is called by scripts/publish.sh and ios/scripts/testflight.sh before their gate.
# It accepts a receipt only for this exact HEAD, on a clean tree, with the same gate-script
# digest and Xcode version (and, with --require-clean, only one written by a CLEAN=1 run).
# It also binds the receipt to where it ran (review findings S3):
#   * the gate must have run in a release checkout (the paths prepare-release-checkouts.sh
#     uses), not a development worktree; BATON_GATE_RECEIPT_ANY_CHECKOUT=1 waives this;
#   * each ignored release configuration a build reads (the two Crashbox.local.xcconfig
#     files) must be present or absent alike, with the same SHA-256, in both checkouts.
#     Only digests are recorded, never contents;
#   * no stage in --needs may have been skipped, unless BATON_GATE_RECEIPT_ALLOW_SKIPS
#     names it (an explicit, logged opt-in).
# It prints the reason for any refusal and exits 1; the caller then runs the gate as it
# always did. A receipt replaces only the shared-core gate: every release-only check still
# runs.
#
# Receipts live outside any checkout, so the Mac and iPhone release checkouts pinned to the
# same commit share one: ${BATON_GATE_RECEIPT_DIR:-~/Library/Caches/Baton/gate-receipts},
# one file per commit and mode, mode 0600. They hold no secrets.
set -euo pipefail

RECEIPT_DIR="${BATON_GATE_RECEIPT_DIR:-$HOME/Library/Caches/Baton/gate-receipts}"

xcode_version() {
  xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

gate_digest() {   # $1 = repo
  shasum -a 256 "$1/scripts/test.sh" | cut -c1-64
}

tree_dirty() {   # $1 = repo; prints the dirty paths
  git -C "$1" status --porcelain --untracked-files=normal 2>/dev/null
}

# The ignored files a release build reads. Recorded by presence and digest only.
RELEASE_CONFIGS="app/Config/Crashbox.local.xcconfig ios/Config/Crashbox.local.xcconfig"
config_digests() {   # $1 = repo; prints "path=sha256|absent" per config
  local c
  for c in $RELEASE_CONFIGS; do
    if [ -f "$1/$c" ]; then
      printf '%s=%s\n' "$c" "$(shasum -a 256 "$1/$c" | cut -c1-64)"
    else
      printf '%s=absent\n' "$c"
    fi
  done
}

checkout_role() {   # $1 = repo; mac-release, ios-release or other
  local here mac ios
  here="$(cd "$1" && pwd -P)"
  mac="$(cd "${BATON_MAC_RELEASE_CHECKOUT:-/private/tmp/baton-rel}" 2>/dev/null && pwd -P || true)"
  ios="$(cd "${BATON_IOS_RELEASE_CHECKOUT:-/private/tmp/baton-release-tf}" 2>/dev/null && pwd -P || true)"
  if [ -n "$mac" ] && [ "$here" = "$mac" ]; then echo mac-release
  elif [ -n "$ios" ] && [ "$here" = "$ios" ]; then echo ios-release
  else echo other
  fi
}

cmd="${1:-}"; repo="${2:-}"
[ -n "$cmd" ] && [ -n "$repo" ] || { echo "usage: gate-receipt.sh write|check REPO ..." >&2; exit 2; }
shift 2
head="$(git -C "$repo" rev-parse HEAD)"

case "$cmd" in
  write)
    clean=0 mac="" ios="" gateway="" skips=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --clean) clean="$2"; shift 2 ;;
        --mac) mac="$2"; shift 2 ;;
        --ios) ios="$2"; shift 2 ;;
        --gateway) gateway="$2"; shift 2 ;;
        --skips) skips="$2"; shift 2 ;;
        *) echo "gate-receipt: unknown option $1" >&2; exit 2 ;;
      esac
    done
    if [ -n "$(tree_dirty "$repo")" ]; then
      echo "gate receipt not written: the tree is dirty" >&2
      exit 1
    fi
    mode=incremental; [ "$clean" = 1 ] && mode=clean
    mkdir -p "$RECEIPT_DIR"
    chmod 700 "$RECEIPT_DIR" 2>/dev/null || true
    out="$RECEIPT_DIR/$head-$mode.json"
    tmp="$out.$$"
    ( umask 077
      RC_COMMIT="$head" RC_DIGEST="$(gate_digest "$repo")" RC_XCODE="$(xcode_version)" \
      RC_CLEAN="$clean" RC_MAC="$mac" RC_IOS="$ios" RC_GATEWAY="$gateway" RC_SKIPS="$skips" \
      RC_REPO="$(cd "$repo" && pwd -P)" RC_ROLE="$(checkout_role "$repo")" \
      RC_CONFIGS="$(config_digests "$repo")" python3 -c '
import json, os, datetime
e = os.environ
print(json.dumps({
    "schema": 1,
    "commit": e["RC_COMMIT"],
    "gateScriptSHA256": e["RC_DIGEST"],
    "xcode": e["RC_XCODE"],
    "clean": e["RC_CLEAN"] == "1",
    "counts": {"mac": e["RC_MAC"], "iphone": e["RC_IOS"], "gateway": e["RC_GATEWAY"]},
    "skipped": [s for s in e["RC_SKIPS"].split(",") if s],
    "checkout": e["RC_REPO"],
    "checkoutRole": e["RC_ROLE"],
    "configs": dict(line.split("=", 1) for line in e["RC_CONFIGS"].splitlines() if line),
    "passedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, indent=2))' >"$tmp" )
    mv -f "$tmp" "$out"
    echo "  gate receipt: $out"
    ;;

  check)
    require_clean=0 needs=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --require-clean) require_clean=1; shift ;;
        --needs) needs="$2"; shift 2 ;;
        *) echo "gate-receipt: unknown option $1" >&2; exit 2 ;;
      esac
    done
    dirty="$(tree_dirty "$repo")"
    if [ -n "$dirty" ]; then
      echo "gate receipt not used: the tree is dirty ($(printf '%s\n' "$dirty" | head -3 | tr '\n' ' '))"
      exit 1
    fi
    file=""
    for mode in clean incremental; do
      [ "$mode" = incremental ] && [ "$require_clean" = 1 ] && continue
      if [ -f "$RECEIPT_DIR/$head-$mode.json" ]; then file="$RECEIPT_DIR/$head-$mode.json"; break; fi
    done
    if [ -z "$file" ]; then
      if [ "$require_clean" = 1 ] && [ -f "$RECEIPT_DIR/$head-incremental.json" ]; then
        echo "gate receipt not used: only an incremental run passed at $head; a release needs CLEAN=1"
      else
        echo "gate receipt not used: no passing full gate is recorded for $head"
      fi
      exit 1
    fi
    RC_FILE="$file" RC_COMMIT="$head" RC_DIGEST="$(gate_digest "$repo")" RC_XCODE="$(xcode_version)" \
      RC_REQUIRE_CLEAN="$require_clean" RC_NEEDS="$needs" RC_CONFIGS="$(config_digests "$repo")" \
      RC_ALLOW_SKIPS="${BATON_GATE_RECEIPT_ALLOW_SKIPS:-}" RC_ANY_CHECKOUT="${BATON_GATE_RECEIPT_ANY_CHECKOUT:-}" \
      python3 -c '
import json, os, sys
e = os.environ
try:
    r = json.load(open(e["RC_FILE"]))
except Exception as error:
    print("gate receipt not used: unreadable receipt %s (%s)" % (e["RC_FILE"], error)); sys.exit(1)
checks = [
    (r.get("schema") == 1, "unknown receipt schema %r" % r.get("schema")),
    (r.get("commit") == e["RC_COMMIT"], "it is for commit %s, not %s" % (r.get("commit"), e["RC_COMMIT"])),
    (r.get("gateScriptSHA256") == e["RC_DIGEST"], "scripts/test.sh changed since it passed"),
    (r.get("xcode") == e["RC_XCODE"], "Xcode changed since it passed (%s, now %s)" % (r.get("xcode"), e["RC_XCODE"])),
    (r.get("clean") or e["RC_REQUIRE_CLEAN"] != "1", "it was an incremental run; a release needs CLEAN=1"),
    (r.get("checkoutRole") in ("mac-release", "ios-release") or e["RC_ANY_CHECKOUT"] == "1",
     "it ran in %s, not a release checkout (BATON_GATE_RECEIPT_ANY_CHECKOUT=1 accepts it)" % r.get("checkout")),
]
for passed, reason in checks:
    if not passed:
        print("gate receipt not used: " + reason); sys.exit(1)
here = dict(line.split("=", 1) for line in e["RC_CONFIGS"].splitlines() if line)
there = r.get("configs") or {}
for path in sorted(here):
    if there.get(path) != here[path]:
        def say(v):
            return "absent" if v in (None, "absent") else "sha256 " + v[:12]
        print("gate receipt not used: %s differs (gate: %s, this checkout: %s)" % (path, say(there.get(path)), say(here[path])))
        sys.exit(1)
allowed = set(s for s in e["RC_ALLOW_SKIPS"].split(",") if s)
missing = [s for s in e["RC_NEEDS"].split(",") if s and s in (r.get("skipped") or []) and s not in allowed]
if missing:
    print("gate receipt not used: the gate skipped %s, which this release needs (BATON_GATE_RECEIPT_ALLOW_SKIPS=%s accepts it)" % (", ".join(missing), ",".join(missing)))
    sys.exit(1)
c = r.get("counts", {})
skipped = ", ".join(r.get("skipped") or []) or "nothing"
print("gate receipt reused: %s passed at %s (%s). Mac: %s; iPhone: %s; gateway: %s; skipped: %s" % (
    r["commit"][:12], r.get("passedAt"), "CLEAN=1" if r.get("clean") else "incremental",
    c.get("mac") or "?", c.get("iphone") or "?", c.get("gateway") or "?", skipped))
'
    ;;

  *) echo "usage: gate-receipt.sh write|check REPO ..." >&2; exit 2 ;;
esac
