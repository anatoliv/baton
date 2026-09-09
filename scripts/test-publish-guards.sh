#!/bin/bash
#
# publish.sh's two silent-degradation guards. (TBX-5317, D-F8 and D-F9)
#
# WHY THIS EXISTS. Both defects had the same shape as the ones in testflight.sh: a
# protection that stopped protecting without the log looking any different.
#
#   D-F8  The notarize wall clock was armed by
#             command -v timeout >/dev/null || timeout() { shift; "$@"; }   # run bare
#         `timeout` is not a macOS builtin; it comes from Homebrew's coreutils. On a Mac
#         without it the shim ate the `900` and ran `xcrun notarytool submit` unbounded,
#         restoring the 69-minute hang the comment above it says it removes. Nothing
#         printed differently, so the machine that lost the protection looked exactly like
#         the machine that had it.
#
#   D-F9  A failed Gatekeeper assessment was a `warn` while every other artifact check in
#         the script is fatal: entitlements, both staples, the DMG verify, the origin hash.
#         `spctl` failing is the closest proxy there is for "the user's Mac will refuse
#         this download", and it printed one yellow line in the middle of a twenty-minute
#         log, above a publish and a tag that both went ahead.
#
# HOW IT TESTS THEM. It extracts the REAL blocks out of publish.sh by their own anchors and
# runs them against stubs, the same way test-testflight-exits.sh does. Nothing is copied:
# put the old one-line shim back, or turn the spctl check back into a warn, and this goes
# red.
#
# What it cannot cover: Apple, a signing identity, a DMG. Both defects are shell control
# flow, which is what this can reach.
#
# No Xcode, no network, no Apple, about two seconds.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
SUBJECT="${BATON_PUBLISH_SUBJECT:-$ROOT/scripts/publish.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '\033[32mok    %s\033[0m\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '\033[31mFAIL  %s\033[0m\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- the real blocks, by anchor ---------------------------------------------------------

TIMEOUT_BLOCK="$(awk '/^if command -v timeout >\/dev\/null; then$/,/^fi$/' "$SUBJECT")"
NOTARIZE_FN="$(awk '/^notarize\(\) \{$/,/^\}$/' "$SUBJECT")"
SPCTL_BLOCK="$(awk '/^  if ! spctl -a -t open /,/^  fi$/' "$SUBJECT")"

for name in TIMEOUT_BLOCK NOTARIZE_FN SPCTL_BLOCK; do
  eval "body=\$$name"
  if [ -z "$body" ]; then
    bad "$name: anchor not found in publish.sh; the script was restructured"
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
    exit 1
  fi
done

PRELUDE='set -uo pipefail
warn() { printf "  ! %s\n" "$*"; }
'

# A PATH with nothing on it but what we put there, so "coreutils is absent" is a fact
# rather than a hope.
bare_path() {   # $@ = names to provide from the real PATH
  rm -rf "$WORK/bin"; mkdir -p "$WORK/bin"
  local n src
  for n in bash sed awk grep printf sleep "$@"; do
    src="$(command -v "$n" 2>/dev/null)" && [ -n "$src" ] && ln -sf "$src" "$WORK/bin/$n"
  done
  printf '%s' "$WORK/bin"
}

# --- D-F8: no coreutils, and perl is there ----------------------------------------------
#
# The fallback has to do the job, not merely exist. `sleep 30` stands in for a hung
# `notarytool submit`: with a working wall clock it dies in about a second, and without one
# this case would take thirty and then pass, which is the whole difference.

{ printf '%s' "$PRELUDE"; printf '%s\n' "$TIMEOUT_BLOCK"
  echo 'timeout 1 sleep 30; echo "rc=$?"'; } >"$WORK/t8.sh"

P="$(bare_path perl)"
start_s=$(date +%s)
out="$(PATH="$P" bash "$WORK/t8.sh" 2>&1)"
elapsed=$(( $(date +%s) - start_s ))

if ! printf '%s' "$out" | grep -q "using perl's alarm"; then
  bad "D-F8: no coreutils and no warning that the fallback is in use. Got: $out"
elif printf '%s' "$out" | grep -q "rc=0"; then
  bad "D-F8: the perl fallback let a hanging command finish, so it is not a wall clock"
elif [ "$elapsed" -gt 5 ]; then
  bad "D-F8: the fallback took ${elapsed}s to stop a 1-second timeout; it is not bounding anything"
else
  ok "D-F8 without coreutils the perl alarm bounds the submit (killed in ${elapsed}s) and says so"
fi

# --- D-F8: nothing to arm it with at all -------------------------------------------------
#
# Running bare is then the only option left, and the point of the fix is that it stops
# being silent about it.

P="$(bare_path)"
out="$(PATH="$P" bash "$WORK/t8.sh" 2>&1)"
if ! printf '%s' "$out" | grep -q "NO WALL CLOCK ON NOTARIZATION"; then
  bad "D-F8: with no timeout, gtimeout or perl the submit runs unbounded silently. Got: $out"
elif ! printf '%s' "$out" | grep -q "notarytool history"; then
  bad "D-F8: the warning does not say how to watch the submit by hand. Got: $out"
else
  ok "D-F8 with nothing to arm it, the missing wall clock is stated loudly"
fi

# --- D-F8: with coreutils present, nothing is shadowed -----------------------------------

P="$(bare_path timeout)"
if [ ! -e "$WORK/bin/timeout" ]; then
  ok "D-F8 (skipped: no coreutils timeout on this machine to check the happy path with)"
else
  out="$(PATH="$P" bash "$WORK/t8.sh" 2>&1)"
  if printf '%s' "$out" | grep -q "perl's alarm\|NO WALL CLOCK"; then
    bad "D-F8: a machine that HAS coreutils took a fallback anyway. Got: $out"
  elif printf '%s' "$out" | grep -q "rc=0"; then
    bad "D-F8: the real timeout let a hanging command finish. Got: $out"
  else
    ok "D-F8 with coreutils present the real timeout is used and nothing is printed"
  fi
fi

# --- D-F8: the notarize retry loop still passes the wall clock ---------------------------
#
# The shim can be perfect and unreferenced. This is the assertion that would catch the
# `900` being dropped from the call.
if printf '%s' "$NOTARIZE_FN" | grep -q 'timeout 900 xcrun notarytool submit'; then
  ok "D-F8 wiring: notarize() still calls the submit through a 900-second wall clock"
else
  bad "D-F8 wiring: notarize() no longer wraps the submit in a wall clock"
fi

# --- D-F9: a failed assessment stops the release -----------------------------------------

make_spctl() {   # $1 = exit status
  rm -rf "$WORK/sbin"; mkdir -p "$WORK/sbin"
  printf '#!/bin/bash\necho "stub spctl: rejected"\nexit %s\n' "$1" >"$WORK/sbin/spctl"
  chmod +x "$WORK/sbin/spctl"
}

run_spctl() {   # $1 = spctl exit status, $2 = ALLOW_SPCTL_FAILURE
  make_spctl "$1"
  { printf '%s' "$PRELUDE"
    echo 'DIST=/tmp; DMG_NAME=Baton-0.19.0.dmg'
    printf '%s\n' "$SPCTL_BLOCK"
    echo 'echo "reached the publish"'; } >"$WORK/t9.sh"
  ALLOW_SPCTL_FAILURE="$2" PATH="$WORK/sbin:$PATH" bash "$WORK/t9.sh" 2>&1
}

out="$(run_spctl 3 "")"; rc=$?
if [ "$rc" = 0 ]; then
  bad "D-F9: a rejected DMG still published. Got: $out"
elif printf '%s' "$out" | grep -q "reached the publish"; then
  bad "D-F9: the script carried on past a failed assessment. Got: $out"
elif ! printf '%s' "$out" | grep -q "spctl rejected the notarized DMG"; then
  bad "D-F9: no message saying what was rejected. Got: $out"
else
  ok "D-F9 a failed Gatekeeper assessment stops the release before the upload"
fi

out="$(run_spctl 3 "1")"; rc=$?
if [ "$rc" != 0 ]; then
  bad "D-F9: ALLOW_SPCTL_FAILURE=1 did not let a deliberate override through. Got: $out"
elif ! printf '%s' "$out" | grep -q "reached the publish"; then
  bad "D-F9: the override stopped the release anyway. Got: $out"
elif ! printf '%s' "$out" | grep -q "publishing anyway"; then
  bad "D-F9: the override is silent, so the log does not record that it was used. Got: $out"
else
  ok "D-F9 ALLOW_SPCTL_FAILURE=1 continues, and says in the log that it did"
fi

out="$(run_spctl 0 "")"; rc=$?
if [ "$rc" != 0 ]; then
  bad "D-F9: a passing assessment stopped the release. Got: $out"
elif ! printf '%s' "$out" | grep -q "reached the publish"; then
  bad "D-F9: a passing assessment did not continue. Got: $out"
else
  ok "D-F9 a passing assessment continues, unchanged"
fi

# --- D-F9: and it is still the only one of these checks that is not fatal ----------------
#
# Stated as an assertion rather than a comment, since the argument for making it fatal was
# that every sibling already is.
if printf '%s' "$SPCTL_BLOCK" | grep -q 'exit 1'; then
  ok "D-F9 the assessment block still ends a failed release rather than noting it"
else
  bad "D-F9: the spctl block no longer exits, so a rejected DMG would publish again"
fi
if grep -q 'spctl .*|| warn' "$SUBJECT"; then
  bad "D-F9: an spctl assessment somewhere in publish.sh is back to warn-and-continue"
else
  ok "D-F9 no spctl call in publish.sh degrades to a warning"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
