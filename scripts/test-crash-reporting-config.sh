#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/prepare-crash-reporting.sh"
TMP="$(mktemp -d -t baton-reporting-test)"
trap 'rm -rf "$TMP"' EXIT
passed=0

fresh() {
  rm -rf "$TMP/case"
  mkdir -p "$TMP/case/Config"
}

expect_ok() {
  local expected="$1" output="$TMP/selected.xcconfig" actual
  actual="$($SCRIPT "$TMP/case" "$output")"
  [ "$actual" = "$expected" ] || return 1
  [ "$(stat -f '%Lp' "$output")" = 600 ]
  passed=$((passed + 1))
}

expect_refused() {
  if "$SCRIPT" "$TMP/case" "$TMP/selected.xcconfig" >/dev/null 2>&1; then
    echo "expected configuration to be refused" >&2
    exit 1
  fi
  passed=$((passed + 1))
}

fresh
expect_ok disabled
grep -q '^CRASH_REPORTING_DSN =$' "$TMP/selected.xcconfig"

fresh
printf 'CRASHBOX_DSN = public@crash.example.invalid/42\n' > "$TMP/case/Config/Crashbox.local.xcconfig"
chmod 600 "$TMP/case/Config/Crashbox.local.xcconfig"
expect_ok crashbox
grep -q '^CRASH_REPORTING_PROVIDER = crashbox$' "$TMP/selected.xcconfig"

fresh
printf 'CRASHBOX_DSN = http://public@crash.example.invalid/42\n' > "$TMP/case/Config/Crashbox.local.xcconfig"
chmod 600 "$TMP/case/Config/Crashbox.local.xcconfig"
expect_refused

fresh
printf 'CRASHBOX_DSN = public@crash.example.invalid/42\n' > "$TMP/case/Config/Crashbox.local.xcconfig"
chmod 644 "$TMP/case/Config/Crashbox.local.xcconfig"
expect_refused

fresh
printf 'CRASHBOX_DSN = public@crash.example.invalid/42\nCRASHBOX_DSN = other@crash.example.invalid/43\n' > "$TMP/case/Config/Crashbox.local.xcconfig"
chmod 600 "$TMP/case/Config/Crashbox.local.xcconfig"
expect_refused

fresh
printf 'SENTRY_DSN = public@hosted.example.invalid/42\n' > "$TMP/case/Config/Crashbox.local.xcconfig"
chmod 600 "$TMP/case/Config/Crashbox.local.xcconfig"
expect_refused

fresh
printf 'CRASHBOX_DSN = public@crash.example.invalid/42\n' > "$TMP/real-input"
chmod 600 "$TMP/real-input"
ln -s "$TMP/real-input" "$TMP/case/Config/Crashbox.local.xcconfig"
expect_refused

echo "$passed passed, 0 failed — crash-reporting configuration cases"
