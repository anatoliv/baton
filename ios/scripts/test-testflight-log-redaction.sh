#!/bin/bash
#
# testflight.sh's run log never carries the Crashbox DSN, and is owner-only.
#
# WHY THIS EXISTS. The owner runs the release as
#     secrets-run ... -- ./ios/scripts/testflight.sh > <log> 2>&1
# and six of those logs held CRASH_REPORTING_DSN in plain text, two lines each, some of
# them world-readable in /tmp. Both lines came from the `xcodebuild archive` stage:
#   1. xcodebuild's "Build settings from configuration file" banner, which prints every
#      setting in the `-xcconfig` that prepare-crash-reporting.sh writes. An #include
#      wrapper or XCODE_XCCONFIG_FILE prints them all the same (tried, 2026-10-22).
#   2. The environment dump xcodebuild prints before each Run Script phase, which
#      exports every build setting, the DSN among them ("Sync Help guides").
#
# HOW IT TESTS THEM. It runs the REAL archive block out of testflight.sh, extracted by its
# anchors, against the REAL xcodebuild, with a fake DSN in a throwaway xcconfig. There is
# no project in the work directory, so xcodebuild prints its settings banner and fails in
# about a second: the banner is the leak, and the failure must still reach the caller.
# The env-dump line shape is fed through the script's own filter, and project.yml must
# keep the Run Script phase from dumping its environment at all.
#
# Fake values only. Nothing here reads a real xcconfig, a credential or a past log, and
# the leak is measured with `grep -c`, never printed.
#
# No Apple, no network, no archive. Skips honestly where xcodebuild is absent.
set -uo pipefail
cd "$(dirname "$0")"
DIR="$PWD"
IOS="$(cd "$DIR/.." && pwd)"
# Overridable so a mutant copy can be driven through this harness, as in
# test-testflight-exits.sh.
SUBJECT="${BATON_TESTFLIGHT_SUBJECT:-$DIR/testflight.sh}"
PROJECT_YML="${BATON_PROJECT_YML_SUBJECT:-$IOS/project.yml}"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '\033[32mok    %s\033[0m\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '\033[31mFAIL  %s\033[0m\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf '\033[33mSKIP  %s\033[0m\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MARKER="fakekey-tbx1000000666"
# `//` starts an xcconfig comment, so a URL value is written with an empty `$()` between
# the slashes, the way a real one has to be.
FAKE_XCCONFIG_DSN="https:/\$()/$MARKER@example.invalid/1"

# --- extracting the real blocks ---------------------------------------------------------
# By anchor, not line number. The filter is optional here on purpose: before the fix it did
# not exist, and the archive block running unfiltered is exactly the red case.
FILTER_BLOCK="$(awk '/^redact_build_settings\(\) \{$/,/^\}$/' "$SUBJECT")"
ARCHIVE_BLOCK="$(awk '/^REPORTING_XCCONFIG="\$\(mktemp -t baton-crashbox-xcconfig\)"$/,/^REPORTING_XCCONFIG=""$/' "$SUBJECT")"
STDOUT_BLOCK="$(awk '/^# TBX-1000000666: owner-only run log$/,/^done$/' "$SUBJECT")"

if [ -z "$ARCHIVE_BLOCK" ]; then
  bad "archive block anchors not found in $SUBJECT; the script was restructured and this harness needs a human"
  printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"; exit 1
fi

# --- case 1: the real archive stage, real xcodebuild, fake DSN ----------------------------
mkdir -p "$WORK/repo/scripts" "$WORK/ios"
cat > "$WORK/repo/scripts/test-crash-reporting-config.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$WORK/repo/scripts/prepare-crash-reporting.sh" <<EOF
#!/bin/bash
# Stub: the real one's output shape, with a fake value.
out="\${@: -1}"
{
  printf 'CRASH_REPORTING_DSN = %s\n' '$FAKE_XCCONFIG_DSN'
  printf 'CRASH_REPORTING_PROVIDER = crashbox\n'
  printf 'CRASH_REPORTING_ENVIRONMENT = production\n'
} > "\$out"
printf 'crashbox\n'
EOF
chmod +x "$WORK/repo/scripts/"*.sh

cat > "$WORK/archive.sh" <<EOF
set -euo pipefail
die() { echo "ERROR: \$*" >&2; exit 1; }
REPO="$WORK/repo"; IOS="$WORK/ios"; SKIP_UPLOAD=0
BUILD=1; RG_COMMIT=0000000; INTERNAL_DIAGNOSTICS=0; IDENTITY=none; KC=none.keychain
cd "$WORK/ios"
$FILTER_BLOCK
$ARCHIVE_BLOCK
EOF

if ! command -v xcodebuild >/dev/null 2>&1; then
  skip "archive stage with the real xcodebuild: xcodebuild not installed"
else
  bash "$WORK/archive.sh" > "$WORK/archive.log" 2>&1
  rc=$?
  leaks="$(grep -c "$MARKER" "$WORK/archive.log")"
  if [ "$leaks" != 0 ]; then
    bad "archive stage: the fake DSN reached the run log on $leaks line(s)"
  else
    ok "archive stage: the fake DSN is not in the run log (grep -c = 0)"
  fi
  if [ "$rc" = 0 ]; then
    bad "archive stage: xcodebuild failed but the stage returned 0; the filter swallowed the status"
  else
    ok "archive stage: xcodebuild's failure still ends the stage (rc=$rc)"
  fi
  if grep -q "does not exist" "$WORK/archive.log"; then
    ok "archive stage: xcodebuild's own error still reaches the log"
  else
    bad "archive stage: xcodebuild's error message was lost"
  fi
  if grep -q "CRASH_REPORTING_PROVIDER = crashbox" "$WORK/archive.log"; then
    ok "archive stage: non-secret settings are still shown"
  else
    bad "archive stage: the filter dropped non-secret settings too"
  fi
fi

# --- case 2: the Run Script environment-dump shape through the script's filter -----------
if [ -z "$FILTER_BLOCK" ]; then
  bad "no redact_build_settings() in $SUBJECT; nothing filters the archive output"
else
  sample="$(printf '%s\n' \
    "    export CP\\=/bin/cp" \
    "    export CRASH_REPORTING_DSN\\=https\\://$MARKER@example.invalid/1" \
    "    CRASH_REPORTING_DSN = https:/\$()/$MARKER@example.invalid/1" \
    "    export SOME_SERVICE_TOKEN\\=$MARKER" \
    "    setenv CRASH_REPORTING_DSN https://$MARKER@example.invalid/1" \
    "    setenv CRASH_REPORTING_DSN \"https://$MARKER@example.invalid/1\"" \
    "    export CRASH_REPORTING_PROVIDER\\=crashbox")"
  filtered="$(bash -c "$FILTER_BLOCK"$'\n'"redact_build_settings" <<<"$sample")"
  n="$(grep -c "$MARKER" <<<"$filtered")"
  if [ "$n" = 0 ]; then ok "filter: export, setenv (plain and quoted), banner and token lines carry no value"
  else bad "filter: $n secret value line(s) survived"; fi
  if grep -qx '    export CP\\=/bin/cp' <<<"$filtered" \
     && grep -qx '    export CRASH_REPORTING_PROVIDER\\=crashbox' <<<"$filtered"; then
    ok "filter: ordinary lines pass through unchanged"
  else
    bad "filter: an ordinary line was altered"
  fi
  if [ "$(grep -c 'CRASH_REPORTING_DSN.*<redacted>' <<<"$filtered")" = 4 ]; then
    ok "filter: the key stays visible, so a reader knows a DSN was set"
  else
    bad "filter: the redacted DSN lines no longer name their key"
  fi
fi

# --- case 3: the Run Script phase does not dump its environment ---------------------------
sync_phase="$(awk '/- name: Sync Help guides$/,/script: \|$/' "$PROJECT_YML")"
if grep -q 'showEnvVars: false' <<<"$sync_phase"; then
  ok "project.yml: the Sync Help guides phase sets showEnvVars: false"
else
  bad "project.yml: the Sync Help guides phase still prints every build setting to the log"
fi

# --- case 4: whatever file the caller redirected into is made owner-only ------------------
if [ -z "$STDOUT_BLOCK" ]; then
  bad "no owner-only run-log block in $SUBJECT"
else
  log="$WORK/run.log"
  ( umask 022; bash -c "set -euo pipefail"$'\n'"$STDOUT_BLOCK"$'\n'"echo ran" > "$log" 2>&1 )
  mode="$(stat -f '%Lp' "$log")"
  if [ "$mode" = 600 ] && grep -qx ran "$log"; then
    ok "run log: a 0644 redirect target is 0600 once the script starts"
  else
    bad "run log: mode is $mode, or the script did not run past the block"
  fi
  out="$(bash -c "set -euo pipefail"$'\n'"$STDOUT_BLOCK"$'\n'"echo ran" 2>&1 | cat)"
  if [ "$out" = ran ]; then ok "run log: a pipe or terminal is left alone"
  else bad "run log: the block broke a non-file stdout"; fi
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ]
