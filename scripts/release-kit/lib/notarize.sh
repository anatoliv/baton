#!/usr/bin/env bash
# notarize.sh: submit a file to Apple's notary service with a bounded retry.
# Part of the release kit (~/Projects/_method/release-kit.md). Source it, then:
#   rk_notarize <file> <keychain-profile> || { <print diagnosis>; exit 1; }
#
# Why an outer clock: `notarytool submit --timeout` bounds the wait for Apple's verdict,
# not the upload, and the upload is what hangs. It sits at "initiating connection to the
# Apple notary service" and nothing reaches `notarytool history`. Observed at 69 and 18
# minutes in one afternoon, both killed by hand.
#
# Why no pkill: several apps' releases run on one Mac at once, and
# `pkill -f "notarytool submit"` matches all of them. It is not needed. xcrun execs the
# tool, so notarytool runs as the direct child of GNU timeout and in its process group
# (verified 2026-09-25), and timeout signals that group when the clock fires. The clock
# reaps our attempt and nothing else.
#
# The clock must be real. A `timeout` shell function or stub ahead of coreutils would run
# the attempt unbounded, so the clock is proven first: a 1s limit over a 3s sleep must
# exit 124. Without a working GNU timeout this refuses, having submitted nothing.
#
# Only the clock retries. An attempt the clock ended (timeout's 124, or 137 after its -k
# kill) is resubmitted. Any other ending is Apple's answer or a wrong request (a rejected
# login, a bad profile, an Invalid verdict) and the same submission would get it again, so
# it stops at once. Success needs exit 0 AND the verdict "Accepted", read from notarytool's
# JSON output, so an Invalid verdict cannot pass on its exit status alone. When notarytool's
# own verdict wait runs out first (status "In Progress"), Apple has the upload: that is
# named as such and followed with `notarytool wait`, never resubmitted.
#
# RK_NOTARIZE_ATTEMPTS (3), RK_NOTARIZE_ATTEMPT_SECONDS (900), RK_NOTARIZE_WAIT (12m,
# handed to notarytool as its verdict wait) and RK_NOTARIZE_KILL_AFTER (30, seconds from the
# clock's TERM to its KILL) exist so tests can run the loop in seconds.

# rk_notarize_clock: print the path of a GNU timeout that has been seen to interrupt a
# command, or return 1.
rk_notarize_clock() {
  local t bin rc
  for t in timeout gtimeout; do
    bin="$(type -P "$t" 2>/dev/null)" || continue
    "$bin" --version 2>/dev/null | grep -q coreutils || continue
    "$bin" 1 sleep 3 >/dev/null 2>&1; rc=$?
    if [ "$rc" = 124 ]; then printf '%s\n' "$bin"; return 0; fi
    echo "rk_notarize: $bin did not interrupt a command that outlived it (exit $rc, want 124)." >&2
  done
  return 1
}

rk_notarize() {
  local file="$1" profile="$2" attempt clock out rc verdict status id
  local attempts="${RK_NOTARIZE_ATTEMPTS:-3}" secs="${RK_NOTARIZE_ATTEMPT_SECONDS:-900}"
  local wait="${RK_NOTARIZE_WAIT:-12m}" kill_after="${RK_NOTARIZE_KILL_AFTER:-30}"
  if [ -z "$file" ] || [ -z "$profile" ]; then
    echo "rk_notarize: usage: rk_notarize <file> <keychain-profile>" >&2; return 2
  fi
  [ -f "$file" ] || { echo "rk_notarize: no such file: $file" >&2; return 2; }
  clock="$(rk_notarize_clock)" || {
    echo "rk_notarize: no working GNU timeout (brew install coreutils), so an attempt could not be bounded." >&2
    echo "             Refusing to run one that can hang for an hour. Nothing was submitted." >&2
    return 1
  }
  out="$(mktemp "${TMPDIR:-/tmp}/rk-notary-verdict.XXXXXX")" || return 1
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    echo "    notarizing $(basename "$file"): attempt $attempt/$attempts, up to ${secs}s"
    rc=0
    "$clock" -k "$kill_after" "$secs" xcrun notarytool submit "$file" \
      --keychain-profile "$profile" --wait --timeout "$wait" --output-format json >"$out" || rc=$?
    # "status<TAB>id<TAB>message" from the last JSON object with a status, or empty.
    verdict="$(python3 -c '
import json, sys
text = open(sys.argv[1], errors="replace").read()
for chunk in [text] + text.splitlines()[::-1]:
    try:
        r = json.loads(chunk)
    except ValueError:
        continue
    if isinstance(r, dict) and r.get("status"):
        print("\t".join(str(r.get(k) or "") for k in ("status", "id", "message")))
        break' "$out" 2>/dev/null)"
    status="${verdict%%$'\t'*}"; id="${verdict#*$'\t'}"; id="${id%%$'\t'*}"
    if [ "$rc" = 0 ] && [ "$status" = Accepted ]; then
      echo "    notarized: $(basename "$file") (submission $id, Accepted)"
      rm -f "$out"; return 0
    fi
    case "$rc" in
      124|137)
        echo "    WARNING: notarization attempt $attempt/$attempts of $(basename "$file") did not complete within ${secs}s" >&2
        continue ;;
    esac
    if [ "$status" = "In Progress" ]; then
      echo "rk_notarize: notarytool's own wait (--timeout $wait) ran out with submission ${id:-?} still In Progress." >&2
      echo "             Apple has the upload, so it is not resubmitted. Follow it to its verdict with:" >&2
      echo "             xcrun notarytool wait $id --keychain-profile $profile" >&2
      echo "             (one look: xcrun notarytool info $id --keychain-profile $profile)" >&2
      rm -f "$out"; return 1
    fi
    echo "rk_notarize: notarytool ended with exit $rc${status:+, verdict $status}${id:+ (submission $id)}, not by the clock." >&2
    echo "             A rejected login, a wrong profile or an Invalid verdict comes back the same on" >&2
    echo "             every resubmission, so it is not retried." >&2
    [ -z "$verdict" ] || printf '             notarytool said: %s\n' "${verdict##*$'\t'}" >&2
    [ -z "$id" ] || echo "             xcrun notarytool log $id --keychain-profile $profile" >&2
    rm -f "$out"; return 1
  done
  rm -f "$out"
  echo "rk_notarize: $attempts attempts failed. Did the upload ever land?" >&2
  echo "             xcrun notarytool history --keychain-profile $profile | head -20" >&2
  echo "             Absent from that list = nothing uploaded; waiting longer cannot help." >&2
  return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  rk_notarize "$@"
fi
