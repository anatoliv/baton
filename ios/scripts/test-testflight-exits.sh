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
elif ! printf '%s' "$out" | grep -q "ERROR: App Store metadata push failed"; then
  bad "D-F3 push: no die message. Got: $out"
elif ! printf '%s' "$out" | grep -q "refusing, the live listing was edited"; then
  bad "D-F3 push: the tool's own output was swallowed. Got: $out"
else
  ok "D-F3 push failure prints the log and dies with its message"
fi

# --- D-F3: and the same for `check --strict`, the drift half ----------------------------

out="$(run_metadata check)"; rc=$?
if [ "$rc" != 1 ]; then
  bad "D-F3 check: exit status is $rc, wanted 1"
elif ! printf '%s' "$out" | grep -q "could not be reconciled"; then
  bad "D-F3 check: no die message. Got: $out"
elif ! printf '%s' "$out" | grep -q "SKIP_METADATA=1 to override"; then
  bad "D-F3 check: the override hint never reaches the operator. Got: $out"
else
  ok "D-F3 check --strict drift prints the log and dies with the override hint"
fi

# --- the healthy path still passes through ----------------------------------------------

out="$(run_metadata none)"; rc=$?
if [ "$rc" != 0 ]; then
  bad "metadata clean run: exit status is $rc, wanted 0. Got: $out"
elif ! printf '%s' "$out" | grep -q "  stub app-store-metadata.py push"; then
  bad "metadata clean run: the push log is not indented into the release log. Got: $out"
elif ! printf '%s' "$out" | grep -q "  stub app-store-metadata.py check"; then
  bad "metadata clean run: the check log is not indented into the release log. Got: $out"
else
  ok "metadata clean run indents both logs and continues"
fi

# --- D-F4: INCOMPLETE must not exit 0 ----------------------------------------------------

out="$(run_summary 0 0)"; rc=$?
if [ "$rc" = 0 ]; then
  bad "D-F4: INCOMPLETE exited 0, so a wrapper reads an unattached build as shipped"
elif ! printf '%s' "$out" | grep -q "INCOMPLETE: build 1786444631 uploaded but NOT attached"; then
  bad "D-F4: the INCOMPLETE line is gone. Got: $out"
else
  ok "D-F4 INCOMPLETE exits $rc, and the line still names the build"
fi

# --- D-F4: the two deliberate outcomes stay exit 0 ---------------------------------------

out="$(run_summary 1 0)"; rc=$?
if [ "$rc" != 0 ]; then
  bad "D-F4: a fully attached build exited $rc, wanted 0. Got: $out"
elif ! printf '%s' "$out" | grep -q "DONE: build 1786444631 is on TestFlight and installable"; then
  bad "D-F4: the DONE line is gone. Got: $out"
else
  ok "D-F4 an attached build still exits 0"
fi

out="$(run_summary 0 1)"; rc=$?
if [ "$rc" != 0 ]; then
  bad "D-F4: SKIP_ATTACH=1 exited $rc; that skip is deliberate and should stay 0. Got: $out"
elif ! printf '%s' "$out" | grep -q "DONE (upload only)"; then
  bad "D-F4: the upload-only line is gone. Got: $out"
else
  ok "D-F4 SKIP_ATTACH=1 stays exit 0, since the operator asked for it"
fi

# --- D-F5: the summary names the stages that were skipped --------------------------------

out="$(run_summary 1 0 "shared-core test gate (SKIP_TESTS=1)" "phone UI tests, release set (SKIP_UI_TESTS=1)")"
if ! printf '%s' "$out" | grep -q "skipped in this run:"; then
  bad "D-F5: the DONE line says nothing about the skipped stages. Got: $out"
elif ! printf '%s' "$out" | grep -q "shared-core test gate (SKIP_TESTS=1)"; then
  bad "D-F5: SKIP_TESTS is not named in the summary. Got: $out"
elif ! printf '%s' "$out" | grep -q "phone UI tests, release set (SKIP_UI_TESTS=1)"; then
  bad "D-F5: SKIP_UI_TESTS is not named in the summary. Got: $out"
else
  ok "D-F5 the summary names every skipped stage"
fi

# --- D-F5: a clean run says nothing extra ------------------------------------------------

out="$(run_summary 1 0)"
if printf '%s' "$out" | grep -q "skipped in this run:"; then
  bad "D-F5: a run that skipped nothing still printed a skip list. Got: $out"
else
  ok "D-F5 a run that skipped nothing prints no skip list"
fi

# --- D-F5: SKIP_ATTACH reaches the list too, since it is a skip --------------------------

out="$(run_summary 0 1)"
if ! printf '%s' "$out" | grep -q "attach to the internal beta group (SKIP_ATTACH=1)"; then
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
if ! printf '%s' "$out" | grep -q 'RETAINED=dist/dsym/BatonMobile-1.1+1788988354-0FA94179-912F-36BF-9C92-F66D1B6E525D.dSYM.zip'; then
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
if ! printf '%s' "$out" | grep -q "RETAIN_REFUSED"; then
  bad "TBX-5372: a dSYM whose UUIDs are not the archived app's was retained anyway. Got: $out"
elif ! printf '%s' "$out" | grep -q "not the archived app"; then
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
if ! printf '%s' "$out" | grep -q "NOT uploaded to Crashbox"; then
  bad "TBX-5372: a build that never uploaded its dSYM does not say so. Got: $out"
elif ! printf '%s' "$out" | grep -q "./scripts/upload-dsym.sh $REL baton-ios"; then
  bad "TBX-5372: the DONE line does not name the command that uploads it. Got: $out"
else
  ok "TBX-5372 a build whose dSYM was never uploaded says so and names the command"
fi

out="$(run_dsym_state "$REL" 1)"
if printf '%s' "$out" | grep -q "NOT uploaded"; then
  bad "TBX-5372: a dSYM with a receipt beside it still reads as not uploaded. Got: $out"
elif ! printf '%s' "$out" | grep -q "uploaded to Crashbox"; then
  bad "TBX-5372: an uploaded dSYM is not reported as uploaded. Got: $out"
else
  ok "TBX-5372 a dSYM with a receipt beside it is reported as uploaded"
fi

out="$(run_dsym_state "" 0)"
if ! printf '%s' "$out" | grep -q "NONE retained"; then
  bad "TBX-5372: a build that retained no dSYM at all is silent about it. Got: $out"
elif ! printf '%s' "$out" | grep -q "never be symbolicated"; then
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
if grep -q 'upload-dsym.sh' "$SUBJECT" && ! grep -q 'crashbox-artifact-upload' "$SUBJECT"; then
  ok "TBX-5372 testflight.sh points at the upload command without ever running one itself"
else
  bad "TBX-5372: testflight.sh either stopped naming upload-dsym.sh or now uploads implicitly"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
