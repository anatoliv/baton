#!/bin/bash
#
# testflight.sh says what happened, and its exit code agrees. (TBX-5317, D-F3/D-F4/D-F5)
#
# WHY THIS EXISTS. Three defects in the same script, all of the same family: the log said
# one thing and the exit status said another, and nothing anywhere could tell.
#
#   D-F3  Under `set -euo pipefail` the App Store metadata step read
#             python3 app-store-metadata.py push >"$META_LOG" 2>&1
#             push_rc=$?
#             sed 's/^/  /' "$META_LOG"
#             [ "$push_rc" = 0 ] || die "App Store metadata push failed"
#         A failing simple command ends the script on the spot, so the assignment, the
#         log print and the `die` were all unreachable. A listing edited in Apple's web
#         form stopped the release with no message and left the diagnosis in a temp file
#         nobody was told the name of. The same shape covered `check --strict`, which is
#         the drift check the whole CLAUDE.md section is about.
#
#   D-F4  The INCOMPLETE branch printed "uploaded but NOT attached to a beta group" and
#         then ended on an `echo`, so `$?` was 0. Build 1786444631 finished exactly that
#         way on 2026-08-11 and was reported as a success to anything reading the status.
#
#   D-F5  SKIP_TESTS, SKIP_UI_TESTS, SKIP_METADATA and SKIP_UPLOAD never reached the
#         summary, so `SKIP_TESTS=1 ./testflight.sh` ended with the same DONE line as a
#         run that passed the whole 14-minute gate.
#
# HOW IT TESTS THEM. It runs the REAL blocks out of testflight.sh, extracted by their own
# anchors, with `python3` replaced by a stub that fails on demand. Nothing here is a copy
# of the logic: rewrite the metadata step back into the `cmd; rc=$?` shape and case 1 goes
# red. That is the rule test-gate-counts.sh states for itself, for the same reason.
#
# What it cannot cover: the parts of the script that need Apple, a keychain or an archive.
# The three defects are all in shell control flow, which is exactly what this can reach.
#
# No Xcode, no network, no Apple, well under a second.
set -uo pipefail
cd "$(dirname "$0")"
DIR="$PWD"
REAL_PYTHON="$(command -v python3)"
# The subject is overridable so a mutant copy can be driven through this same harness,
# which is how each of the three fixes was shown red before it was written. See
# test-release-guard-mutants.sh for the same idea applied to the release guard:
#   sed 's/  exit 2/  :/' testflight.sh > /tmp/m.sh
#   BATON_TESTFLIGHT_SUBJECT=/tmp/m.sh ./ios/scripts/test-testflight-exits.sh
SUBJECT="${BATON_TESTFLIGHT_SUBJECT:-$DIR/testflight.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '\033[32mok    %s\033[0m\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '\033[31mFAIL  %s\033[0m\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- extracting the real blocks ---------------------------------------------------------
#
# By anchor, not by line number, so an edit above them does not silently make this harness
# test the wrong lines. Each extractor fails loudly if its anchor is gone, which is the
# case where the subject was restructured and this file needs a human.

METADATA_BLOCK="$(awk '/^if \[ "\$\{SKIP_METADATA:-0\}" != "1" \]; then$/,/^fi$/' "$SUBJECT")"
SUMMARY_BLOCK="$(awk '/^if \[ "\$ATTACHED" = 1 \]; then$/,/^fi$/' "$SUBJECT")"
PRINT_SKIPPED="$(awk '/^print_skipped\(\) \{$/,/^\}$/' "$SUBJECT")"
# The summary calls this too, so the endings cannot be run without it. (TBX-5372)
DSYM_STATE_FN="$(awk '/^print_dsym_state\(\) \{$/,/^\}$/' "$SUBJECT")"

for name in METADATA_BLOCK SUMMARY_BLOCK PRINT_SKIPPED DSYM_STATE_FN; do
  eval "body=\$$name"
  if [ -z "$body" ]; then
    bad "$name: anchor not found in testflight.sh; the script was restructured"
    echo "      this harness tests the real blocks by anchor; update the anchors." >&2
    exit 1
  fi
done

# --- a stub python3 that fails on the subcommand we name --------------------------------
#
# `push` and `check` are separate cases because they were separate defects: the first
# stops a release that cannot write its listing, the second stops one whose listing was
# edited behind the repo's back.
make_stub() {   # $1 = subcommand to fail on, or "none"
  mkdir -p "$WORK/bin"
  cat >"$WORK/bin/python3" <<STUB
#!/bin/bash
# args: <script> <subcommand> [...]
sub="\${2:-}"
echo "stub app-store-metadata.py \$sub: three fields differ from App Store Connect"
if [ "\$sub" = "$1" ]; then
  echo "stub: refusing, the live listing was edited in the web form" >&2
  exit 1
fi
exit 0
STUB
  chmod +x "$WORK/bin/python3"
}

run_metadata() {   # $1 = subcommand the stub fails on; prints output, returns the status
  make_stub "$1"
  cat >"$WORK/metadata.sh" <<PRELUDE
set -euo pipefail
DIR="$DIR"
die() { echo "ERROR: \$*" >&2; exit 1; }
SKIPPED=()
$PRINT_SKIPPED
PRELUDE
  printf '%s\n' "$METADATA_BLOCK" >>"$WORK/metadata.sh"
  PATH="$WORK/bin:$PATH" bash "$WORK/metadata.sh" 2>&1
}

run_summary() {   # $1 = ATTACHED, $2 = SKIP_ATTACH, rest = skipped entries
  local attached="$1" skip_attach="$2"; shift 2
  {
    echo 'set -euo pipefail'
    echo 'BUILD=1786444631'
    echo "ATTACHED=$attached"
    echo "SKIP_ATTACH=$skip_attach"
    echo 'SKIPPED=()'
    local s
    for s in "$@"; do echo "SKIPPED+=(\"$s\")"; done
    printf '%s\n' "$PRINT_SKIPPED"
    echo 'RETAINED_DSYM=""'
    printf '%s\n' "$DSYM_STATE_FN"
    printf '%s\n' "$SUMMARY_BLOCK"
  } >"$WORK/summary.sh"
  bash "$WORK/summary.sh" 2>&1
}

# --- D-F3: a failing metadata push must print the log and die ---------------------------

out="$(run_metadata push)"; rc=$?
if [ "$rc" != 1 ]; then
  bad "D-F3 push: exit status is $rc, wanted 1"
elif ! grep -q <<<"$out" "ERROR: App Store metadata push failed"; then
  bad "D-F3 push: no die message. Got: $out"
elif ! grep -q <<<"$out" "refusing, the live listing was edited"; then
  bad "D-F3 push: the tool's own output was swallowed. Got: $out"
else
  ok "D-F3 push failure prints the log and dies with its message"
fi

# --- D-F3: and the same for `check --strict`, the drift half ----------------------------

out="$(run_metadata check)"; rc=$?
if [ "$rc" != 1 ]; then
  bad "D-F3 check: exit status is $rc, wanted 1"
elif ! grep -q <<<"$out" "could not be reconciled"; then
  bad "D-F3 check: no die message. Got: $out"
elif ! grep -q <<<"$out" "SKIP_METADATA=1 to override"; then
  bad "D-F3 check: the override hint never reaches the operator. Got: $out"
else
  ok "D-F3 check --strict drift prints the log and dies with the override hint"
fi

# --- the healthy path still passes through ----------------------------------------------

out="$(run_metadata none)"; rc=$?
if [ "$rc" != 0 ]; then
  bad "metadata clean run: exit status is $rc, wanted 0. Got: $out"
elif ! grep -q <<<"$out" "  stub app-store-metadata.py push"; then
  bad "metadata clean run: the push log is not indented into the release log. Got: $out"
elif ! grep -q <<<"$out" "  stub app-store-metadata.py check"; then
  bad "metadata clean run: the check log is not indented into the release log. Got: $out"
else
  ok "metadata clean run indents both logs and continues"
fi

# --- D-F4: INCOMPLETE must not exit 0 ----------------------------------------------------

out="$(run_summary 0 0)"; rc=$?
if [ "$rc" = 0 ]; then
  bad "D-F4: INCOMPLETE exited 0, so a wrapper reads an unattached build as shipped"
elif ! grep -q <<<"$out" "INCOMPLETE: build 1786444631 uploaded but NOT attached"; then
  bad "D-F4: the INCOMPLETE line is gone. Got: $out"
else
  ok "D-F4 INCOMPLETE exits $rc, and the line still names the build"
fi

# --- D-F4: the two deliberate outcomes stay exit 0 ---------------------------------------

out="$(run_summary 1 0)"; rc=$?
if [ "$rc" != 0 ]; then
  bad "D-F4: a fully attached build exited $rc, wanted 0. Got: $out"
elif ! grep -q <<<"$out" "DONE: build 1786444631 is on TestFlight and installable"; then
  bad "D-F4: the DONE line is gone. Got: $out"
else
  ok "D-F4 an attached build still exits 0"
fi

out="$(run_summary 0 1)"; rc=$?
if [ "$rc" != 0 ]; then
  bad "D-F4: SKIP_ATTACH=1 exited $rc; that skip is deliberate and should stay 0. Got: $out"
elif ! grep -q <<<"$out" "DONE (upload only)"; then
  bad "D-F4: the upload-only line is gone. Got: $out"
else
  ok "D-F4 SKIP_ATTACH=1 stays exit 0, since the operator asked for it"
fi

# --- D-F5: the summary names the stages that were skipped --------------------------------

out="$(run_summary 1 0 "shared-core test gate (SKIP_TESTS=1)" "phone UI tests, release set (SKIP_UI_TESTS=1)")"
if ! grep -q <<<"$out" "skipped in this run:"; then
  bad "D-F5: the DONE line says nothing about the skipped stages. Got: $out"
elif ! grep -q <<<"$out" "shared-core test gate (SKIP_TESTS=1)"; then
  bad "D-F5: SKIP_TESTS is not named in the summary. Got: $out"
elif ! grep -q <<<"$out" "phone UI tests, release set (SKIP_UI_TESTS=1)"; then
  bad "D-F5: SKIP_UI_TESTS is not named in the summary. Got: $out"
else
  ok "D-F5 the summary names every skipped stage"
fi

# --- D-F5: a clean run says nothing extra ------------------------------------------------

out="$(run_summary 1 0)"
if grep -q <<<"$out" "skipped in this run:"; then
  bad "D-F5: a run that skipped nothing still printed a skip list. Got: $out"
else
  ok "D-F5 a run that skipped nothing prints no skip list"
fi

# --- D-F5: SKIP_ATTACH reaches the list too, since it is a skip --------------------------

out="$(run_summary 0 1)"
if ! grep -q <<<"$out" "attach to the internal beta group (SKIP_ATTACH=1)"; then
  bad "D-F5: SKIP_ATTACH is not in the skip list. Got: $out"
else
  ok "D-F5 SKIP_ATTACH appears in the skip list"
fi

# --- every hatch in the script is accounted for -----------------------------------------
#
# The defect was a hatch that never reached the summary, so the guard that matters most is
# the one that notices a NEW hatch arriving with the same gap. Every SKIP_* the script
# reads must also be pushed onto SKIPPED somewhere.
hatches="$(grep -o 'SKIP_[A-Z_]*' "$SUBJECT" | sort -u)"
missing=""
for h in $hatches; do
  grep -q "SKIPPED+=(.*$h=1)" "$SUBJECT" || missing="$missing $h"
done
if [ -n "$missing" ]; then
  bad "D-F5: these hatches never reach the summary:$missing"
else
  ok "D-F5 every SKIP_* hatch in testflight.sh pushes onto the skip list"
fi

# --- TBX-5372: the archive's dSYM is copied out before the archive is gone ---------------
#
# WHY. testflight.sh removed build/Baton.xcarchive at the top of every archive step, so the
# "retained in the archive" dSYM lasted exactly one release. The Mac side lost 0.19.2's the
# same way, and the first real crash Crashbox ever stored could not be symbolicated. The
# dSYM is now copied to dist/dsym/ under a name carrying the version, the build and the
# UUID, and every DONE line says whether it has been uploaded.
#
# dwarfdump is stubbed. What is under test is the copy, the name, the mismatch refusal and
# the wording of the DONE lines; none of that needs a real Mach-O.

RETAIN_FN="$(awk '/^retain_dsym\(\) \{$/,/^\}$/' "$SUBJECT")"
UUID_FN="$(awk '/^dsym_uuid_lines\(\) \{$/,/^\}$/' "$SUBJECT")"

for name in RETAIN_FN UUID_FN; do
  eval "body=\$$name"
  if [ -z "$body" ]; then
    bad "$name: anchor not found in testflight.sh; the dSYM retention was restructured"
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
    exit 1
  fi
done

make_dwarfdump() {
  rm -rf "$WORK/dbin"; mkdir -p "$WORK/dbin"
  cat >"$WORK/dbin/dwarfdump" <<'EOF'
#!/bin/bash
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

# A throwaway archive. dist/ is left alone between calls on purpose: a fixture that wiped
# it would be destroying the previous release's dSYM itself, which is the very thing the
# first case is meant to prove the script no longer does.
make_archive() {   # $1 = repo root, $2 = app UUID lines, $3 = dSYM UUID lines
  rm -rf "$1/ios/build"
  mkdir -p "$1/dist" \
           "$1/ios/build/Baton.xcarchive/Products/Applications/Baton.app" \
           "$1/ios/build/Baton.xcarchive/dSYMs/Baton.app.dSYM/Contents/Resources/DWARF"
  echo "not a real mach-o" >"$1/ios/build/Baton.xcarchive/Products/Applications/Baton.app/Baton"
  echo "not a real dwarf"  >"$1/ios/build/Baton.xcarchive/dSYMs/Baton.app.dSYM/Contents/Resources/DWARF/Baton"
  printf '%s\n' "$2" >"$1/ios/build/Baton.xcarchive/Products/Applications/Baton.app/Baton.uuids"
  printf '%s\n' "$3" >"$1/ios/build/Baton.xcarchive/dSYMs/Baton.app.dSYM.uuids"
}

run_retain() {   # $1 = repo root, $2 = version, $3 = build
  { echo 'set -uo pipefail'
    echo "REPO='$1'; IOS='$1/ios'"
    echo 'DSYM_DIR="$REPO/dist/dsym"; RETAINED_DSYM=""'
    printf '%s\n' "$UUID_FN"
    printf '%s\n' "$RETAIN_FN"
    echo 'if retain_dsym "$IOS/build/Baton.xcarchive/Products/Applications/Baton.app" \'
    echo '     "$IOS/build/Baton.xcarchive/dSYMs/Baton.app.dSYM" '"'$2' '$3'"'; then'
    echo '  echo "RETAINED=${RETAINED_DSYM#$REPO/}"'
    echo 'else'
    echo '  echo "RETAIN_REFUSED"'
    echo 'fi'; } >"$WORK/t5372.sh"
  make_dwarfdump
  PATH="$WORK/dbin:$PATH" bash "$WORK/t5372.sh" 2>&1
}

ROOT="$WORK/repo"
mkdir -p "$ROOT"
make_archive "$ROOT" "arm64 0FA94179-912F-36BF-9C92-F66D1B6E525D" "arm64 0FA94179-912F-36BF-9C92-F66D1B6E525D"
out="$(run_retain "$ROOT" 1.1 1788988354)"
if ! grep -q <<<"$out" 'RETAINED=dist/dsym/BatonMobile-1.1+1788988354-0FA94179-912F-36BF-9C92-F66D1B6E525D.dSYM.zip'; then
  bad "TBX-5372: the retained archive is not named for this version, build and UUID. Got: $out"
elif [ ! -s "$ROOT/dist/dsym/BatonMobile-1.1+1788988354-0FA94179-912F-36BF-9C92-F66D1B6E525D.dSYM.zip" ]; then
  bad "TBX-5372: nothing was written at the retained path. Got: $out"
else
  make_archive "$ROOT" "arm64 22222222-3333-4444-5555-666666666666" "arm64 22222222-3333-4444-5555-666666666666"
  out2="$(run_retain "$ROOT" 1.1 1788999999)"
  if [ ! -s "$ROOT/dist/dsym/BatonMobile-1.1+1788988354-0FA94179-912F-36BF-9C92-F66D1B6E525D.dSYM.zip" ]; then
    bad "TBX-5372: the next release destroyed the previous build's dSYM, which is the whole defect. Got: $out2"
  elif [ ! -s "$ROOT/dist/dsym/BatonMobile-1.1+1788999999-22222222-3333-4444-5555-666666666666.dSYM.zip" ]; then
    bad "TBX-5372: the second release retained nothing. Got: $out2"
  else
    ok "TBX-5372 a retained dSYM survives the next TestFlight build, under its own name"
  fi
fi

make_archive "$ROOT" "arm64 0FA94179-912F-36BF-9C92-F66D1B6E525D" "arm64 77777777-8888-9999-aaaa-bbbbbbbbbbbb"
out="$(run_retain "$ROOT" 1.2 1789000000)"
if ! grep -q <<<"$out" "RETAIN_REFUSED"; then
  bad "TBX-5372: a dSYM whose UUIDs are not the archived app's was retained anyway. Got: $out"
elif ! grep -q <<<"$out" "not the archived app"; then
  bad "TBX-5372: the refusal does not say the UUIDs disagree. Got: $out"
elif ls "$ROOT/dist/dsym/BatonMobile-1.2+"*.dSYM.zip >/dev/null 2>&1; then
  bad "TBX-5372: a mismatched dSYM was still filed under this build's name. Got: $out"
else
  ok "TBX-5372 a dSYM that is not this archive's is refused rather than filed under its name"
fi

run_dsym_state() {   # $1 = RETAINED_DSYM, $2 = 1 to plant a receipt
  { echo 'set -uo pipefail'
    echo "RETAINED_DSYM='$1'"
    printf '%s\n' "$DSYM_STATE_FN"
    echo 'print_dsym_state'; } >"$WORK/t5372s.sh"
  if [ -n "$1" ]; then
    mkdir -p "$(dirname "$1")"
    if [ "$2" = 1 ]; then printf '{"artifact_id":"stub"}\n' >"$1.receipt.json"
    else rm -f "$1.receipt.json"; fi
  fi
  bash "$WORK/t5372s.sh" 2>&1
}

REL="$ROOT/dist/dsym/BatonMobile-1.1+1788988354-0FA94179-912F-36BF-9C92-F66D1B6E525D.dSYM.zip"
out="$(run_dsym_state "$REL" 0)"
if ! grep -q <<<"$out" "NOT uploaded to Crashbox"; then
  bad "TBX-5372: a build that never uploaded its dSYM does not say so. Got: $out"
elif ! grep -q <<<"$out" "./scripts/upload-dsym.sh $REL baton-ios"; then
  bad "TBX-5372: the DONE line does not name the command that uploads it. Got: $out"
else
  ok "TBX-5372 a build whose dSYM was never uploaded says so and names the command"
fi

out="$(run_dsym_state "$REL" 1)"
if grep -q <<<"$out" "NOT uploaded"; then
  bad "TBX-5372: a dSYM with a receipt beside it still reads as not uploaded. Got: $out"
elif ! grep -q <<<"$out" "uploaded to Crashbox"; then
  bad "TBX-5372: an uploaded dSYM is not reported as uploaded. Got: $out"
else
  ok "TBX-5372 a dSYM with a receipt beside it is reported as uploaded"
fi

out="$(run_dsym_state "" 0)"
if ! grep -q <<<"$out" "NONE retained"; then
  bad "TBX-5372: a build that retained no dSYM at all is silent about it. Got: $out"
elif ! grep -q <<<"$out" "never be symbolicated"; then
  bad "TBX-5372: the no-dSYM case does not say what it costs. Got: $out"
else
  ok "TBX-5372 a build that retained nothing says so, in the same line as the skip list"
fi

# Wiring. Same lesson as D-F5: a summary that does not carry the fact is a summary nobody
# can use, and a retention nothing calls is the old step 4b all over again.
if grep -q 'retain_dsym "\$IOS/build/Baton.xcarchive/Products/Applications/Baton.app"' "$SUBJECT"; then
  ok "TBX-5372 wiring: the archive step copies the dSYM out before anything can remove the archive"
else
  bad "TBX-5372 wiring: the archive step no longer calls retain_dsym"
fi
dsym_endings="$(grep -c '^  print_dsym_state$' "$SUBJECT")"
if [ "$dsym_endings" -ge 4 ]; then
  ok "TBX-5372 wiring: all four endings of testflight.sh state the dSYM and its upload state ($dsym_endings)"
else
  bad "TBX-5372 wiring: only $dsym_endings of the endings say whether the dSYM was uploaded; expected 4"
fi
artifact_upload_line="$(grep -n 'crashbox-artifact-upload.py" upload' "$SUBJECT" | awk -F: 'NR == 1 { print $1 }')"
testflight_upload_line="$(grep -n 'xcrun altool --upload-app' "$SUBJECT" | awk -F: 'NR == 1 { print $1 }')"
if [ -n "$artifact_upload_line" ] && [ -n "$testflight_upload_line" ] && \
   [ "$artifact_upload_line" -lt "$testflight_upload_line" ] && \
   grep -q -- '--project baton-ios' "$SUBJECT" && \
   grep -qF 'iPhone Crashbox artifact credential is required before a TestFlight upload' "$SUBJECT" && \
   grep -qF 'TestFlight was not contacted' "$SUBJECT"; then
  ok "TBX-5498 testflight.sh uploads the exact iPhone dSYM before contacting TestFlight"
else
  bad "TBX-5498: the iPhone dSYM no longer gates the TestFlight upload"
fi

if grep -q 'BATON_INTERNAL_DIAGNOSTICS="$INTERNAL_DIAGNOSTICS"' "$SUBJECT" && \
   grep -q 'ENABLE_CRASH_CANARY must be 0 or 1' "$SUBJECT" && \
   grep -q 'ENABLE_CRASH_CANARY=1 requires a Crashbox-backed TestFlight upload' "$SUBJECT"; then
  ok "TBX-5498 the destructive canary is explicit, bounded to Crashbox TestFlight, and off by default"
else
  bad "TBX-5498: the destructive canary build flag is no longer fail-closed"
fi

# --- TBX-1000000480: the signing setup and its cleanup leave the machine as they found it --
#
# The real stretch from the end of the metadata step through the project.yml patch is run
# as one piece: the per-run temp state, cleanup(), its trap, the temp keychain and the
# signing patch. `security` and `xcodegen` are stubs that record what they were asked and
# touch nothing; the patch is the real python3 over a copy of the real project.yml, in a
# throwaway git repository.
SIGNING_REGION="$(awk '
  /^if \[ "\$\{SKIP_METADATA:-0\}" != "1" \]; then$/ { m = 1 }
  m == 1 && /^fi$/ { m = 2; next }
  m == 2 { print }
  m == 2 && /^PY$/ { exit }' "$SUBJECT")"
if ! grep -q <<<"$SIGNING_REGION" '^cleanup() {$' \
   || ! grep -q <<<"$SIGNING_REGION" '^PY$'; then
  bad "TBX-1000000480: signing region anchors not found in testflight.sh; update the anchors"
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

mkdir -p "$WORK/tbin"
cat >"$WORK/tbin/security" <<'EOF'
#!/bin/bash
# Records into $STUB_STATE; never prints or logs a password, never touches a keychain file.
s="$STUB_STATE"; cmd="$1"; shift
case "$cmd" in
  list-keychains)
    if [ "$*" = "-d user" ]; then
      while IFS= read -r k; do printf '    "%s"\n' "$k"; done <"$s/list"
    else
      shift 3; printf '%s\n' "$@" >"$s/list"; printf '%s\n' "$*" >>"$s/sets"
    fi ;;
  create-keychain) printf '%s' "$2" >"$s/kcpass"; printf '%s\n' "$3" >>"$s/created" ;;
  delete-keychain) printf '%s\n' "$1" >>"$s/deleted" ;;
  find-identity) printf '  1) ABCDEF "%s"\n' "$STUB_IDENTITY" ;;
esac
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' >"$WORK/tbin/xcodegen"
chmod +x "$WORK/tbin/security" "$WORK/tbin/xcodegen"

# run_signing <tag> <dirty: 0|1> [env assignments...]: prints the run's output
run_signing() {
  local tag="$1" dirty="$2"; shift 2
  local T="$WORK/sign-$tag"
  rm -rf "$T"; mkdir -p "$T/ios" "$T/home/Library/Keychains" "$T/state"
  cp "$DIR/../project.yml" "$T/ios/project.yml"
  git -C "$T/ios" init -q
  git -C "$T/ios" add project.yml
  git -C "$T/ios" -c user.name=t -c user.email=t@example.invalid commit -q -m base
  if [ "$dirty" = 1 ]; then
    printf '# a local edit nobody has committed yet\n' >>"$T/ios/project.yml"
  fi
  cp "$T/ios/project.yml" "$T/project.yml.before"
  printf '%s\n' "$T/home/Library/Keychains/login.keychain-db" \
                "$T/home/Library/Keychains/tonebox-build.keychain-db" >"$T/state/list"
  cp "$T/state/list" "$T/list.before"
  : >"$T/dist.p12"
  { echo 'set -euo pipefail'
    echo "DIR='$DIR'; IOS='$T/ios'; REPO='$T'; HOME='$T/home'"
    echo 'die() { echo "ERROR: $*" >&2; exit 1; }'
    echo 'IDENTITY="Apple Distribution: Test (TEAMID0000)"'
    echo "P12_PATH='$T/dist.p12'; P12_PASSWORD=stub-p12"
    echo 'APP_PROFILE="Baton App Store"; WIDGET_PROFILE="Baton Widgets App Store"'
    echo 'SHARE_PROFILE="Baton Share App Store"; WITH_ENTITLEMENTS=1; BUILD=1789000000'
    grep -E '^(KC|KCPASS)=' "$SUBJECT"
    printf '%s\n' "$SIGNING_REGION"; } >"$T/signing.sh"
  env -u KC -u KCPASS "$@" STUB_STATE="$T/state" STUB_IDENTITY="Apple Distribution: Test (TEAMID0000)" \
    PATH="$WORK/tbin:/usr/bin:/bin:$PATH" bash "$T/signing.sh" 2>&1
}

# B-11: under SKIP_UPLOAD=1 a dirty tree is only advisory, so project.yml can hold the
# developer's own uncommitted edits when the patch runs. Cleanup must put those back, not HEAD.
out="$(run_signing dirty 1)"; T="$WORK/sign-dirty"
if ! grep -q <<<"$out" "project.yml patched"; then
  bad "B-11: the signing patch did not run, so this case proves nothing. Got: $out"
elif ! cmp -s "$T/ios/project.yml" "$T/project.yml.before"; then
  bad "B-11: cleanup did not restore project.yml as it was; uncommitted edits were lost"
  diff "$T/project.yml.before" "$T/ios/project.yml" | head -8 | sed 's/^/        /'
else
  ok "B-11 cleanup restores project.yml with the developer's uncommitted edits intact"
fi
out="$(run_signing clean 0)"; T="$WORK/sign-clean"
if cmp -s "$T/ios/project.yml" "$T/project.yml.before" && [ -z "$(git -C "$T/ios" status --porcelain)" ]; then
  ok "B-11 on a clean tree cleanup still leaves project.yml exactly as committed"
else
  bad "B-11: on a clean tree cleanup left project.yml patched or changed. Got: $out"
fi

# B-10: the run prepends its keychain to the user's search list and cleanup puts that list
# back, rather than resetting it to login alone and dropping every other keychain on it
# (a parallel Tonebox release's among them). The keychain lives at a per-run path.
T="$WORK/sign-clean"; KC_USED="$(head -1 "$T/state/created" 2>/dev/null)"
if ! cmp -s "$T/state/list" "$T/list.before"; then
  bad "B-10: cleanup did not restore the keychain search list. Before: $(tr '\n' ' ' <"$T/list.before") After: $(tr '\n' ' ' <"$T/state/list")"
elif [ "$(head -1 "$T/state/sets")" != "$KC_USED $(tr '\n' ' ' <"$T/list.before" | sed 's/ $//')" ]; then
  bad "B-10: step 1 did not prepend its keychain to the existing list. Set: $(head -1 "$T/state/sets")"
else
  ok "B-10 cleanup restores the whole keychain search list the run started with"
fi
KC_OTHER="$(head -1 "$WORK/sign-dirty/state/created" 2>/dev/null)"
if [ -z "$KC_USED" ] || [ "$KC_USED" = /tmp/baton-build.keychain-db ] || [ "$KC_USED" = "$KC_OTHER" ]; then
  bad "B-10: the temp keychain is at a fixed path two runs share: $KC_USED"
elif [ -e "$(dirname "$KC_USED")" ]; then
  bad "B-10: cleanup left the per-run temp directory behind: $(dirname "$KC_USED")"
else
  ok "B-10 each run's temp keychain has its own path, removed by cleanup"
fi
if grep -n '/tmp/baton-' "$SUBJECT" >"$WORK/fixed-tmp.txt"; then
  bad "B-10: testflight.sh still writes fixed /tmp paths: $(tr '\n' ' ' <"$WORK/fixed-tmp.txt")"
else
  ok "B-10 testflight.sh uses no fixed /tmp path a concurrent run could collide on"
fi

# B-25: the temp keychain's password is generated per run unless one is given explicitly,
# and never printed. Compared through the stub's record only; nothing here echoes a value.
P1="$(cat "$WORK/sign-clean/state/kcpass" 2>/dev/null)"
P2="$(cat "$WORK/sign-dirty/state/kcpass" 2>/dev/null)"
if [ "${#P1}" -lt 16 ] || [ "$P1" = "$P2" ]; then
  bad "B-25: two runs created their keychains with the same (or a short) default password"
elif grep -qF -- "$P1" "$WORK/sign-clean/signing.sh" \
     || { run_signing pw 0 >"$WORK/sign-pw.out"; P3="$(cat "$WORK/sign-pw/state/kcpass" 2>/dev/null)"
          [ -z "$P3" ] || grep -qF -- "$P3" "$WORK/sign-pw.out"; }; then
  bad "B-25: the generated keychain password is in the script or the run's output"
else
  ok "B-25 each run generates its own keychain password and prints none of it"
fi
run_signing override 0 KCPASS=explicit-override-pass >/dev/null
if [ "$(cat "$WORK/sign-override/state/kcpass" 2>/dev/null)" = explicit-override-pass ]; then
  ok "B-25 an explicit KCPASS is still honoured"
else
  bad "B-25: an explicit KCPASS override was ignored"
fi

if "$REAL_PYTHON" "$DIR/test-attach-build.py" >"$WORK/attach-tests.log" 2>&1; then
  ok "TBX-1000000095 attachment pagination: 8 focused cases, no Apple or credentials"
else
  bad "TBX-1000000095 attachment pagination regression"
  cat "$WORK/attach-tests.log"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
