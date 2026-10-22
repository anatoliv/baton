#!/usr/bin/env bash
# gate-receipt.sh: run the full test gate once per commit and let every release reuse it.
# Part of the release kit (~/Projects/_method/release-kit.md); the rule it implements is
# "one gate per commit" in ~/Projects/_method/docs/standards/release.md. Source it, then:
#
#   rk_gate_receipt write REPO [--clean 0|1] [--count KEY=TEXT ...] [--skips LIST]
#   rk_gate_receipt check REPO [--require-clean] [--needs STAGE,STAGE]
#
# or run this file with the same arguments. Exit status: 0 written or accepted, 1 refused
# (the reason is printed), 2 usage.
#
# `write` is for the gate itself, after a passing FULL run (no pass-through arguments, no
# skip switches, no concurrency override) over a clean tree that did not move during the run.
# It records the commit, a digest of the gate script, the toolchain version, the counts each
# stage reported, the skipped stages, the checkout and its role, the digests of the ignored
# release configuration files, and the time. Never contents, never secrets.
#
# `check` is for each release, before its own gate. It accepts a receipt only for this exact
# HEAD, on a clean tree, with the same gate-script digest and toolchain version (and, with
# --require-clean, only one written by a clean run). It also binds the receipt to where it ran:
#   * the gate must have run in a release checkout (a path named in RK_GATE_RELEASE_CHECKOUTS),
#     not a development worktree; PREFIX_ANY_CHECKOUT=1 waives this;
#   * each ignored release configuration a build reads must be present or absent alike, with
#     the same SHA-256, in both checkouts;
#   * no stage in --needs may have been skipped, unless PREFIX_ALLOW_SKIPS names it.
# A refusal never stops a release: the caller runs its gate as it always did. A receipt
# replaces only the shared gate; every release-only check still runs.
#
# CONFIGURATION (variables, read when the function runs; a project wrapper sets them):
#   RK_GATE_ENV              prefix of the knobs below (default RK_GATE_RECEIPT):
#                            PREFIX_DIR, PREFIX_ANY_CHECKOUT, PREFIX_ALLOW_SKIPS
#   RK_GATE_DEFAULT_DIR      the store when PREFIX_DIR is unset
#                            (default ~/Library/Caches/release-kit/gate-receipts). Receipts
#                            live outside any checkout, so release checkouts at the same
#                            commit share them: one file per commit and mode, 0600, dir 0700.
#   RK_GATE_SCRIPT           the gate script, relative to REPO (default scripts/test.sh)
#   RK_GATE_TOOL_CMD         prints the toolchain version (default: xcodebuild -version)
#   RK_GATE_TOOL_LABEL       its name in messages (default Xcode)
#   RK_GATE_CONFIGS          ignored release configuration files, relative to REPO
#   RK_GATE_RELEASE_CHECKOUTS  "role=path role=path": the release checkouts, by physical path
#   RK_GATE_COUNT_LABELS     "key=Label key=Label": the counts printed on reuse, in order
#
# Receipt schema 1 keeps the key `xcode` for the toolchain version, so receipts written
# before the kit carried this module stay readable.

rk_gate_receipt() (
  set -euo pipefail
  local prefix="${RK_GATE_ENV:-RK_GATE_RECEIPT}" var dir script tool_label
  var="${prefix}_DIR"; dir="${!var:-${RK_GATE_DEFAULT_DIR:-$HOME/Library/Caches/release-kit/gate-receipts}}"
  script="${RK_GATE_SCRIPT:-scripts/test.sh}"
  tool_label="${RK_GATE_TOOL_LABEL:-Xcode}"

  _rk_tool_version() {
    if [ -n "${RK_GATE_TOOL_CMD:-}" ]; then
      bash -c "$RK_GATE_TOOL_CMD" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//'
    else
      xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//'
    fi
  }
  _rk_gate_digest() { shasum -a 256 "$1/$script" | cut -c1-64; }
  # Prints the dirty entries. Fails when git cannot read the tree (a corrupt index: HEAD
  # resolves, status exits 128); an empty listing from a failed status is not a clean tree.
  _rk_tree_dirty() { git -C "$1" status --porcelain --untracked-files=normal; }
  _rk_config_digests() {   # prints "path=sha256|absent" per configuration file
    local c
    for c in ${RK_GATE_CONFIGS:-}; do
      if [ -f "$1/$c" ]; then
        printf '%s=%s\n' "$c" "$(shasum -a 256 "$1/$c" | cut -c1-64)"
      else
        printf '%s=absent\n' "$c"
      fi
    done
  }
  _rk_checkout_role() {   # the role whose path is this checkout, or other
    local here pair role path real
    here="$(cd "$1" && pwd -P)"
    for pair in ${RK_GATE_RELEASE_CHECKOUTS:-}; do
      role="${pair%%=*}"; path="${pair#*=}"
      real="$(cd "$path" 2>/dev/null && pwd -P || true)"
      if [ -n "$real" ] && [ "$here" = "$real" ]; then echo "$role"; return 0; fi
    done
    echo other
  }

  local cmd="${1:-}" repo="${2:-}" head
  [ -n "$cmd" ] && [ -n "$repo" ] || { echo "usage: gate-receipt.sh write|check REPO ..." >&2; exit 2; }
  shift 2
  head="$(git -C "$repo" rev-parse HEAD)"

  case "$cmd" in
    write)
      local clean=0 counts="" skips="" mode out tmp dirty
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --clean) clean="$2"; shift 2 ;;
          --count) counts="$counts$2"$'\n'; shift 2 ;;
          --skips) skips="$2"; shift 2 ;;
          *) echo "gate-receipt: unknown option $1" >&2; exit 2 ;;
        esac
      done
      if ! dirty="$(_rk_tree_dirty "$repo")"; then
        echo "gate receipt not written: git status failed in $repo, so the tree cannot be shown clean" >&2
        exit 1
      fi
      if [ -n "$dirty" ]; then
        echo "gate receipt not written: the tree is dirty" >&2
        exit 1
      fi
      mode=incremental; [ "$clean" = 1 ] && mode=clean
      mkdir -p "$dir"
      chmod 700 "$dir" 2>/dev/null || true
      out="$dir/$head-$mode.json"
      tmp="$out.$$"
      ( umask 077
        RC_COMMIT="$head" RC_DIGEST="$(_rk_gate_digest "$repo")" RC_XCODE="$(_rk_tool_version)" \
        RC_CLEAN="$clean" RC_COUNTS="$counts" RC_SKIPS="$skips" \
        RC_REPO="$(cd "$repo" && pwd -P)" RC_ROLE="$(_rk_checkout_role "$repo")" \
        RC_CONFIGS="$(_rk_config_digests "$repo")" python3 -c '
import json, os, datetime
e = os.environ
print(json.dumps({
    "schema": 1,
    "commit": e["RC_COMMIT"],
    "gateScriptSHA256": e["RC_DIGEST"],
    "xcode": e["RC_XCODE"],
    "clean": e["RC_CLEAN"] == "1",
    "counts": dict(line.split("=", 1) for line in e["RC_COUNTS"].splitlines() if "=" in line),
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
      local require_clean=0 needs="" dirty file m roles="" pair
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --require-clean) require_clean=1; shift ;;
          --needs) needs="$2"; shift 2 ;;
          *) echo "gate-receipt: unknown option $1" >&2; exit 2 ;;
        esac
      done
      if ! dirty="$(_rk_tree_dirty "$repo")"; then
        echo "gate receipt not used: git status failed in $repo, so the tree cannot be shown clean"
        exit 1
      fi
      if [ -n "$dirty" ]; then
        echo "gate receipt not used: the tree is dirty ($(printf '%s\n' "$dirty" | head -3 | tr '\n' ' '))"
        exit 1
      fi
      file=""
      for m in clean incremental; do
        [ "$m" = incremental ] && [ "$require_clean" = 1 ] && continue
        if [ -f "$dir/$head-$m.json" ]; then file="$dir/$head-$m.json"; break; fi
      done
      if [ -z "$file" ]; then
        if [ "$require_clean" = 1 ] && [ -f "$dir/$head-incremental.json" ]; then
          echo "gate receipt not used: only an incremental run passed at $head; a release needs CLEAN=1"
        else
          echo "gate receipt not used: no passing full gate is recorded for $head"
        fi
        exit 1
      fi
      for pair in ${RK_GATE_RELEASE_CHECKOUTS:-}; do roles="$roles${pair%%=*},"; done
      local any_var="${prefix}_ANY_CHECKOUT" skips_var="${prefix}_ALLOW_SKIPS"
      RC_FILE="$file" RC_COMMIT="$head" RC_DIGEST="$(_rk_gate_digest "$repo")" RC_XCODE="$(_rk_tool_version)" \
        RC_REQUIRE_CLEAN="$require_clean" RC_NEEDS="$needs" RC_CONFIGS="$(_rk_config_digests "$repo")" \
        RC_ALLOW_SKIPS="${!skips_var:-}" RC_ANY_CHECKOUT="${!any_var:-}" RC_ROLES="$roles" \
        RC_PREFIX="$prefix" RC_SCRIPT="$script" RC_TOOL="$tool_label" \
        RC_LABELS="${RK_GATE_COUNT_LABELS:-}" python3 -c '
import json, os, sys
e = os.environ
try:
    r = json.load(open(e["RC_FILE"]))
except Exception as error:
    print("gate receipt not used: unreadable receipt %s (%s)" % (e["RC_FILE"], error)); sys.exit(1)
roles = [s for s in e["RC_ROLES"].split(",") if s]
p = e["RC_PREFIX"]
checks = [
    (r.get("schema") == 1, "unknown receipt schema %r" % r.get("schema")),
    (r.get("commit") == e["RC_COMMIT"], "it is for commit %s, not %s" % (r.get("commit"), e["RC_COMMIT"])),
    (r.get("gateScriptSHA256") == e["RC_DIGEST"], "%s changed since it passed" % e["RC_SCRIPT"]),
    (r.get("xcode") == e["RC_XCODE"], "%s changed since it passed (%s, now %s)" % (e["RC_TOOL"], r.get("xcode"), e["RC_XCODE"])),
    (r.get("clean") or e["RC_REQUIRE_CLEAN"] != "1", "it was an incremental run; a release needs CLEAN=1"),
    (r.get("checkoutRole") in roles or e["RC_ANY_CHECKOUT"] == "1",
     "it ran in %s, not a release checkout (%s_ANY_CHECKOUT=1 accepts it)" % (r.get("checkout"), p)),
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
    print("gate receipt not used: the gate skipped %s, which this release needs (%s_ALLOW_SKIPS=%s accepts it)" % (", ".join(missing), p, ",".join(missing)))
    sys.exit(1)
c = r.get("counts", {})
labels = [pair.split("=", 1) for pair in e["RC_LABELS"].split() if "=" in pair] or [[k, k] for k in c]
counts = "; ".join("%s: %s" % (label, c.get(key) or "?") for key, label in labels)
skipped = ", ".join(r.get("skipped") or []) or "nothing"
print("gate receipt reused: %s passed at %s (%s). %s; skipped: %s" % (
    r["commit"][:12], r.get("passedAt"), "CLEAN=1" if r.get("clean") else "incremental", counts, skipped))
'
      ;;

    *) echo "usage: gate-receipt.sh write|check REPO ..." >&2; exit 2 ;;
  esac
)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  rk_gate_receipt "$@"
fi
