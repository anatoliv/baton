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
#   TBX-5357  `hdiutil detach` of the read-only verification mount failed once with
#         "Resource busy" and ended a run in which the DMG was already signed, notarized,
#         stapled and verified. There was no retry, and the message was hdiutil's own
#         one-liner, so a transient that had cleared a minute later cost the whole
#         twenty-minute run. Covered here: the retry, the -force fallback, the message
#         that names the resume point, and the RESUME_FROM_STAPLED identity check that
#         makes resuming safe.
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
DETACH_FN="$(awk '/^detach_image\(\) \{$/,/^\}$/' "$SUBJECT")"
DETACH_FAIL_FN="$(awk '/^detach_failed_after_staple\(\) \{$/,/^\}$/' "$SUBJECT")"
RESUME_FN="$(awk '/^resume_assert_stapled_dmg\(\) \{$/,/^\}$/' "$SUBJECT")"

for name in TIMEOUT_BLOCK NOTARIZE_FN SPCTL_BLOCK DETACH_FN DETACH_FAIL_FN RESUME_FN; do
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

# --- TBX-5357: the verification unmount retries before it gives up ----------------------
#
# The real failure was `hdiutil detach` returning 16 with `couldn't unmount "disk12" -
# Resource busy` while a Spotlight importer (most likely) still had the read-only mount
# open. That is faked here rather than planted for real: attaching a genuine image would
# make this harness touch real devices, and what is under test is the retry control flow,
# which the stub reproduces exactly, message and exit status included.
#
# `sleep` is stubbed to a no-op so three attempts cost nothing on a gate that runs this on
# every merge. The wait itself is asserted as text below, so removing it still goes red.

make_hdiutil() {   # $1 = how many plain detaches fail, $2 = exit status of `detach -force`
  rm -rf "$WORK/hbin"; mkdir -p "$WORK/hbin"
  : >"$WORK/hdiutil.calls"; echo 0 >"$WORK/hdiutil.count"
  cat >"$WORK/hbin/hdiutil" <<EOF
#!/bin/bash
echo "\$*" >>"$WORK/hdiutil.calls"
if [ "\$1" = detach ] && [ "\$2" = -force ]; then exit $2; fi
if [ "\$1" = detach ]; then
  c=\$(cat "$WORK/hdiutil.count"); c=\$((c + 1)); echo "\$c" >"$WORK/hdiutil.count"
  if [ "\$c" -le $1 ]; then
    echo 'hdiutil: couldn'"'"'t unmount "disk12" - Resource busy' >&2
    exit 16
  fi
  exit 0
fi
exit 0
EOF
  chmod +x "$WORK/hbin/hdiutil"
  printf '#!/bin/bash\nexit 0\n' >"$WORK/hbin/sleep"; chmod +x "$WORK/hbin/sleep"
}

run_detach() {   # $1 = plain detaches that fail, $2 = force exit status
  make_hdiutil "$1" "$2"
  { printf '%s' "$PRELUDE"
    echo 'DIST=dist; DMG_NAME=Baton-0.19.3.dmg'
    printf '%s\n' "$DETACH_FN"
    printf '%s\n' "$DETACH_FAIL_FN"
    echo 'if detach_image /tmp/vmp "the verification image"; then'
    echo '  echo "DETACH_OK"'
    echo 'else'
    echo '  detach_failed_after_staple /tmp/vmp; echo "DETACH_GAVE_UP"'
    echo 'fi'; } >"$WORK/t5357.sh"
  PATH="$WORK/hbin:$PATH" bash "$WORK/t5357.sh" 2>&1
}

# Two busy answers, then the mount lets go. That is the 0.19.3 case, where one detach by
# hand a minute later worked on the first try.
out="$(run_detach 2 1)"
plain="$(grep -c '^detach /tmp/vmp$' "$WORK/hdiutil.calls" || true)"
forced="$(grep -c '^detach -force' "$WORK/hdiutil.calls" || true)"
if ! printf '%s' "$out" | grep -q "DETACH_OK"; then
  bad "TBX-5357: a busy mount that clears on the third try still failed the release. Got: $out"
elif [ "$plain" != 3 ]; then
  bad "TBX-5357: expected 3 ordinary detach attempts, saw $plain. Got: $out"
elif [ "$forced" != 0 ]; then
  bad "TBX-5357: -force was used even though an ordinary detach succeeded. Got: $out"
elif ! printf '%s' "$out" | grep -q "attempt 1 of 3"; then
  bad "TBX-5357: the retries are silent, so a busy mount leaves no trace in the log. Got: $out"
else
  ok "TBX-5357 a busy verification mount is retried and succeeds without -force"
fi

# Never lets go on its own. -force is the next thing tried, not the end of the release.
out="$(run_detach 99 0)"
forced="$(grep -c '^detach -force' "$WORK/hdiutil.calls" || true)"
if ! printf '%s' "$out" | grep -q "DETACH_OK"; then
  bad "TBX-5357: -force was never tried, so a stuck mount still ends a finished release. Got: $out"
elif [ "$forced" != 1 ]; then
  bad "TBX-5357: expected exactly one -force attempt, saw $forced. Got: $out"
elif ! printf '%s' "$out" | grep -q "with -force"; then
  bad "TBX-5357: -force is used silently, so the log does not record it. Got: $out"
else
  ok "TBX-5357 a mount that never clears is detached with -force, and the log says so"
fi

# Nothing works. Then it fails, but it must not read as a failed release.
out="$(run_detach 99 16)"
if ! printf '%s' "$out" | grep -q "DETACH_GAVE_UP"; then
  bad "TBX-5357: an unbreakable mount did not fail. Got: $out"
elif ! printf '%s' "$out" | grep -q "notarized and stapled"; then
  bad "TBX-5357: the failure does not say the DMG is already notarized and stapled. Got: $out"
elif ! printf '%s' "$out" | grep -q "RESUME_FROM_STAPLED=1"; then
  bad "TBX-5357: the failure does not name the resume point. Got: $out"
elif ! printf '%s' "$out" | grep -q "DO NOT REBUILD"; then
  bad "TBX-5357: the failure still reads as a release that has to be started over. Got: $out"
else
  ok "TBX-5357 a hopeless unmount fails saying the artifact is good and naming the resume"
fi

# Wiring, the same shape as the D-F8 one: the helper can be perfect and unreferenced.
if grep -q 'detach_image "\$VERIFY_MP" "the verification image"' "$SUBJECT" \
   && grep -q 'detach_failed_after_staple "\$VERIFY_MP"' "$SUBJECT"; then
  ok "TBX-5357 wiring: step 4a unmounts through detach_image and reports through the resume message"
else
  bad "TBX-5357 wiring: step 4a no longer detaches through the retrying helper"
fi
if printf '%s' "$DETACH_FN" | grep -q '^ *sleep '; then
  ok "TBX-5357 the retry loop still waits between attempts"
else
  bad "TBX-5357: the retry loop no longer sleeps, so three attempts happen in one instant"
fi

# --- TBX-5357: RESUME_FROM_STAPLED only proceeds on this release's artifact --------------
#
# Version strings in dist/ prove nothing, so the resume reads the commit and the version
# back out of the .app inside the image, exactly as macrel_assert_built_identity does on a
# freshly built bundle. Here that bundle is a fixture with a real Info.plist, and hdiutil
# attach is stubbed to drop it at the mount point.

PINNED_COMMIT="914dff0c6f9a1b2c3d4e5f60718293a4b5c6d7e8"

make_fixture() {   # $1 = CFBundleShortVersionString, $2 = CFBundleVersion, $3 = BatonSourceCommit
  rm -rf "$WORK/fixture"; mkdir -p "$WORK/fixture/Baton.app/Contents"
  cat >"$WORK/fixture/Baton.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleShortVersionString</key><string>$1</string>
  <key>CFBundleVersion</key><string>$2</string>
  <key>BatonSourceCommit</key><string>$3</string>
</dict></plist>
EOF
}

make_resume_stubs() {   # $1 = exit status of `xcrun stapler validate`
  rm -rf "$WORK/rbin"; mkdir -p "$WORK/rbin"
  cat >"$WORK/rbin/hdiutil" <<EOF
#!/bin/bash
if [ "\$1" = attach ]; then
  mp=""; while [ \$# -gt 0 ]; do [ "\$1" = -mountpoint ] && { mp="\$2"; }; shift; done
  [ -n "\$mp" ] || exit 1
  cp -R "$WORK/fixture/." "\$mp/" || exit 1
  exit 0
fi
if [ "\$1" = detach ]; then rm -rf "\$2"/Baton.app 2>/dev/null; exit 0; fi
exit 0
EOF
  cat >"$WORK/rbin/xcrun" <<EOF
#!/bin/bash
[ "\$1" = stapler ] && exit $1
exit 0
EOF
  chmod +x "$WORK/rbin/hdiutil" "$WORK/rbin/xcrun"
}

run_resume() {   # $1 = version, $2 = build, $3 = commit in the fixture, $4 = stapler status
  make_fixture "$1" "$2" "$3"; make_resume_stubs "$4"
  rm -rf "$WORK/dist"; mkdir -p "$WORK/dist"; echo "not really a dmg" >"$WORK/dist/Baton-0.19.3.dmg"
  { printf '%s' "$PRELUDE"
    echo ". '$ROOT/scripts/release-identity.sh'"
    echo "DIST='$WORK/dist'; DMG_NAME=Baton-0.19.3.dmg"
    echo "MACREL_VERSION=0.19.3; MACREL_BUILD=103; MACREL_COMMIT=$PINNED_COMMIT"
    printf '%s\n' "$DETACH_FN"
    printf '%s\n' "$RESUME_FN"
    echo 'resume_assert_stapled_dmg "before publishing" && echo "RESUME_PROCEEDS"'; } >"$WORK/t5357r.sh"
  PATH="$WORK/rbin:$PATH" bash "$WORK/t5357r.sh" 2>&1
}

out="$(run_resume 0.19.3 103 "$PINNED_COMMIT" 0)"
if ! printf '%s' "$out" | grep -q "RESUME_PROCEEDS"; then
  bad "TBX-5357: a stapled DMG whose .app names the pinned release was refused. Got: $out"
elif ! printf '%s' "$out" | grep -q "read back from Info.plist"; then
  bad "TBX-5357: the resume did not read the identity out of the bundle inside the DMG. Got: $out"
else
  ok "TBX-5357 resume proceeds when the DMG's .app names the pinned version and commit"
fi

out="$(run_resume 0.19.2 102 "$PINNED_COMMIT" 0)"
if printf '%s' "$out" | grep -q "RESUME_PROCEEDS"; then
  bad "TBX-5357: resumed onto a 0.19.2 DMG while releasing 0.19.3. Got: $out"
elif ! printf '%s' "$out" | grep -q "not the version this run started for"; then
  bad "TBX-5357: a version mismatch was refused without saying it was the version. Got: $out"
else
  ok "TBX-5357 resume refuses a DMG whose .app carries a different version"
fi

out="$(run_resume 0.19.3 103 "0000000000000000000000000000000000000000" 0)"
if printf '%s' "$out" | grep -q "RESUME_PROCEEDS"; then
  bad "TBX-5357: resumed onto a DMG built from another commit. Got: $out"
elif ! printf '%s' "$out" | grep -q "not the commit this run started for"; then
  bad "TBX-5357: a commit mismatch was refused without saying it was the commit. Got: $out"
else
  ok "TBX-5357 resume refuses a DMG whose .app was built from a different commit"
fi

out="$(run_resume 0.19.3 103 "$PINNED_COMMIT" 1)"
if printf '%s' "$out" | grep -q "RESUME_PROCEEDS"; then
  bad "TBX-5357: resumed past an unstapled image, which is the state resume exists to skip. Got: $out"
elif ! printf '%s' "$out" | grep -q "no stapled ticket"; then
  bad "TBX-5357: an unstapled DMG was refused without saying why. Got: $out"
else
  ok "TBX-5357 resume refuses a DMG with no stapled ticket"
fi

# Wiring: the skip has to be real, and the pre-publish identity check has to be the DMG's
# on a resume. A resume that ran the gate would be pointless; one that skipped the check
# would be the reason not to have a resume at all.
if grep -q '^if ! resuming; then$' "$SUBJECT" && grep -q 'resume_assert_stapled_dmg "before publishing"' "$SUBJECT"; then
  ok "TBX-5357 wiring: the resume skips steps 0 to 4a and re-asserts identity before publishing"
else
  bad "TBX-5357 wiring: RESUME_FROM_STAPLED no longer skips the build or no longer re-checks identity"
fi

# --- TBX-5372: the dSYM outlives the release that built it ------------------------------
#
# WHY. "Matching dSYM retained locally" named $DD, the one directory every release builds
# into. 0.19.2's dSYM survived about two hours before the 0.19.3 build overwrote it, and
# the first real crash to reach Crashbox came from an installed 0.19.2 and can never be
# symbolicated. The fix is a per-release copy under dist/dsym/ with the UUID in the name,
# plus a DONE line that says out loud whether anyone uploaded it.
#
# dwarfdump is stubbed: what is under test is the copy, the naming, the mismatch refusal
# and the wording, none of which needs a real Mach-O.

RETAIN_FN="$(awk '/^retain_dsym\(\) \{$/,/^\}$/' "$SUBJECT")"
UUID_FN="$(awk '/^dsym_uuid_lines\(\) \{$/,/^\}$/' "$SUBJECT")"
STATE_FN="$(awk '/^dsym_state_line\(\) \{$/,/^\}$/' "$SUBJECT")"
RETAIN_STEP="$(awk '/^step "4b\/6 Retain the matching dSYM/,/^fi$/' "$SUBJECT")"

for name in RETAIN_FN UUID_FN STATE_FN RETAIN_STEP; do
  eval "body=\$$name"
  if [ -z "$body" ]; then
    bad "$name: anchor not found in publish.sh; the dSYM retention was restructured"
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
    exit 1
  fi
done

# A stub dwarfdump that answers from a file of UUID lines named after the path it is
# asked about, so an app and its dSYM can be made to agree or to differ on demand.
make_dwarfdump() {
  rm -rf "$WORK/dbin"; mkdir -p "$WORK/dbin"
  cat >"$WORK/dbin/dwarfdump" <<'EOF'
#!/bin/bash
# usage: dwarfdump --uuid <path>; reads <path>.uuids for its answer
target="$2"
[ -f "$target.uuids" ] || { d="$(dirname "$target")"; [ -f "$d.uuids" ] && target="$d"; }
[ -f "$target.uuids" ] || exit 1
while read -r arch uuid; do
  [ -n "$arch" ] || continue
  echo "UUID: $uuid ($arch) $target"
done < "$target.uuids"
EOF
  chmod +x "$WORK/dbin/dwarfdump"
}

# Build a fake app bundle and dSYM under a throwaway repo root, with the UUID sets given.
make_release_tree() {   # $1 = root, $2 = app UUID lines, $3 = dSYM UUID lines
  # Only the build inputs are rebuilt. dist/ is deliberately left alone, or this
  # fixture would destroy the previous release's archive itself and prove nothing.
  rm -rf "$1/app" "$1/dd"; mkdir -p "$1/dist" "$1/app/Baton.app/Contents/MacOS"
  mkdir -p "$1/dd/Build/Products/Release/Baton.app.dSYM/Contents/Resources/DWARF"
  echo "not a real mach-o" >"$1/app/Baton.app/Contents/MacOS/Baton"
  echo "not a real dwarf"  >"$1/dd/Build/Products/Release/Baton.app.dSYM/Contents/Resources/DWARF/Baton"
  printf '%s\n' "$2" >"$1/app/Baton.app/Contents/MacOS/Baton.uuids"
  printf '%s\n' "$3" >"$1/dd/Build/Products/Release/Baton.app.dSYM.uuids"
}

run_retain() {   # $1 = root, $2 = VERSION, $3 = BUILD
  { echo 'set -uo pipefail'
    echo 'step() { printf "  . %s\n" "$*"; }'
    echo 'warn() { printf "  ! %s\n" "$*"; }'
    echo "cd '$1'"
    echo 'DIST=dist; DSYM_DIR="$DIST/dsym"; RETAINED_DSYM=""'
    echo "VERSION='$2'; BUILD='$3'"
    printf '%s\n' "$UUID_FN"
    printf '%s\n' "$RETAIN_FN"
    echo 'if retain_dsym "app/Baton.app" "dd/Build/Products/Release/Baton.app.dSYM"; then'
    echo '  echo "RETAINED=$RETAINED_DSYM"'
    echo 'else'
    echo '  echo "RETAIN_REFUSED"'
    echo 'fi'; } >"$WORK/t5372.sh"
  make_dwarfdump
  PATH="$WORK/dbin:$PATH" bash "$WORK/t5372.sh" 2>&1
}

BOTH='arm64 BCC315D8-4575-3B47-99E6-2AF8CC7DB0D7
x86_64 4AE12B98-B3E2-3166-BB27-252874ECAF7D'

# The regression itself: build 103, then build 104 on top, and 103's archive is still there.
ROOT="$WORK/rel"
make_release_tree "$ROOT" "$BOTH" "$BOTH"
out="$(run_retain "$ROOT" 0.19.3 103)"
if ! printf '%s' "$out" | grep -q 'RETAINED=dist/dsym/Baton-0.19.3+103-BCC315D8-4575-3B47-99E6-2AF8CC7DB0D7.dSYM.zip'; then
  bad "TBX-5372: the retained archive is not named for this version, build and UUID. Got: $out"
elif [ ! -s "$ROOT/dist/dsym/Baton-0.19.3+103-BCC315D8-4575-3B47-99E6-2AF8CC7DB0D7.dSYM.zip" ]; then
  bad "TBX-5372: nothing was written at the retained path. Got: $out"
else
  # Same tree, next release. This is exactly what destroyed 0.19.2's symbols.
  make_release_tree "$ROOT" "arm64 11111111-2222-3333-4444-555555555555" "arm64 11111111-2222-3333-4444-555555555555"
  out2="$(run_retain "$ROOT" 0.19.4 104)"
  if [ ! -s "$ROOT/dist/dsym/Baton-0.19.3+103-BCC315D8-4575-3B47-99E6-2AF8CC7DB0D7.dSYM.zip" ]; then
    bad "TBX-5372: the next release destroyed the previous release's dSYM, which is the whole defect. Got: $out2"
  elif [ ! -s "$ROOT/dist/dsym/Baton-0.19.4+104-11111111-2222-3333-4444-555555555555.dSYM.zip" ]; then
    bad "TBX-5372: the second release retained nothing. Got: $out2"
  else
    ok "TBX-5372 a retained dSYM survives the next release, under its own version+build+UUID name"
  fi
fi

# The name has to be true. A dSYM that is not this app's must be refused, not filed.
make_release_tree "$ROOT" "$BOTH" "arm64 99999999-8888-7777-6666-555555555555"
out="$(run_retain "$ROOT" 0.19.5 105)"
if ! printf '%s' "$out" | grep -q "RETAIN_REFUSED"; then
  bad "TBX-5372: a dSYM whose UUIDs are not the app's was retained anyway. Got: $out"
elif ! printf '%s' "$out" | grep -q "not the built app"; then
  bad "TBX-5372: the refusal does not say the UUIDs disagree. Got: $out"
elif ls "$ROOT/dist/dsym/Baton-0.19.5+105-"*.dSYM.zip >/dev/null 2>&1; then
  bad "TBX-5372: a mismatched dSYM was still filed under this release's name. Got: $out"
else
  ok "TBX-5372 a dSYM that is not this build's is refused rather than filed under its name"
fi

# The DONE line. Three states, and the one that matters is the middle one.
run_state() {   # $1 = RETAINED_DSYM value, $2 = 1 to plant a receipt
  { echo 'set -uo pipefail'
    echo 'warn() { printf "  ! %s\n" "$*"; }'
    echo "cd '$ROOT'"
    echo "VERSION=0.19.3; BUILD=103; RETAINED_DSYM='$1'"
    printf '%s\n' "$STATE_FN"
    echo 'dsym_state_line'; } >"$WORK/t5372s.sh"
  mkdir -p "$ROOT/$(dirname "$1")" 2>/dev/null || true
  if [ "$2" = 1 ] && [ -n "$1" ]; then
    printf '{"artifact_id":"stub"}\n' >"$ROOT/$1.receipt.json"
  else
    rm -f "$ROOT/$1.receipt.json" 2>/dev/null || true
  fi
  bash "$WORK/t5372s.sh" 2>&1
}

REL="dist/dsym/Baton-0.19.3+103-BCC315D8-4575-3B47-99E6-2AF8CC7DB0D7.dSYM.zip"
out="$(run_state "$REL" 0)"
if ! printf '%s' "$out" | grep -q "NOT uploaded to Crashbox"; then
  bad "TBX-5372: a release that never uploaded its dSYM does not say so. Got: $out"
elif ! printf '%s' "$out" | grep -q "./scripts/upload-dsym.sh $REL baton-macos"; then
  bad "TBX-5372: the DONE line does not name the command that uploads it. Got: $out"
else
  ok "TBX-5372 a release whose dSYM was never uploaded says so and names the command"
fi

out="$(run_state "$REL" 1)"
if ! printf '%s' "$out" | grep -q "uploaded to Crashbox"; then
  bad "TBX-5372: an uploaded dSYM is not reported as uploaded. Got: $out"
elif printf '%s' "$out" | grep -q "NOT uploaded"; then
  bad "TBX-5372: a dSYM with a receipt beside it still reads as not uploaded. Got: $out"
else
  ok "TBX-5372 a dSYM with a receipt beside it is reported as uploaded"
fi

out="$(run_state "" 0)"
if ! printf '%s' "$out" | grep -q "NONE retained"; then
  bad "TBX-5372: a release that retained no dSYM at all is silent about it. Got: $out"
elif ! printf '%s' "$out" | grep -q "never be symbolicated"; then
  bad "TBX-5372: the no-dSYM case does not say what it costs. Got: $out"
else
  ok "TBX-5372 a release that retained nothing says so as loudly as a disabled provider would"
fi

# Wiring. The functions can be perfect and unreferenced, which is how the old step 4b
# managed to claim retention while doing nothing at all.
if printf '%s' "$RETAIN_STEP" | grep -q 'retain_dsym "$APP"'; then
  ok "TBX-5372 wiring: step 4b still copies the built dSYM rather than pointing at \$DD"
else
  bad "TBX-5372 wiring: step 4b no longer calls retain_dsym"
fi
if [ "$(grep -c '^  dsym_state_line$' "$SUBJECT")" -ge 2 ]; then
  ok "TBX-5372 wiring: both endings of publish.sh state the dSYM and its upload state"
else
  bad "TBX-5372 wiring: an ending of publish.sh no longer says whether the dSYM was uploaded"
fi
if grep -q 'upload-dsym.sh' "$SUBJECT" && ! grep -q 'crashbox-artifact-upload' "$SUBJECT"; then
  ok "TBX-5372 publish.sh points at the upload command without ever running one itself"
else
  bad "TBX-5372: publish.sh either stopped naming upload-dsym.sh or now uploads implicitly"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
