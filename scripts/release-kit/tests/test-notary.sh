#!/usr/bin/env bash
# test-notary.sh: prove rk_notarize bounds each attempt, retries only what the clock ended and
# fails closed, stops at once on a rejection, needs the verdict "Accepted" to pass, never
# signals a notarization it did not start, and refuses to run without a real clock.
#
# Hermetic: xcrun, pkill and killall are stubs on PATH, attempts are shortened to 1 second,
# and a decoy process whose command line reads "notarytool submit" stands in for another
# app's release. Nothing reaches Apple. RK_NOTARIZE_SUBJECT points at a mutated copy.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUBJECT="${RK_NOTARIZE_SUBJECT:-$HERE/../lib/notarize.sh}"
[ -f "$SUBJECT" ] || { echo "FAIL  no module at $SUBJECT"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/rk-notary.XXXXXX")"
DECOY=""
cleanup() { [ -z "$DECOY" ] || kill "$DECOY" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

REAL=""
for t in timeout gtimeout; do
  b="$(type -P "$t" 2>/dev/null)" || continue
  grep -q coreutils <<<"$("$b" --version 2>/dev/null)" && { REAL="$b"; break; }
done
[ -n "$REAL" ] || { echo "SKIP  GNU timeout is not installed (brew install coreutils)"; exit 0; }

STUBS="$WORK/stubs"; mkdir -p "$STUBS"
CALLS="$WORK/xcrun.log"; KILLS="$WORK/kills.log"; CHILD="$WORK/child.pid"
DMG="$WORK/App.dmg"; : >"$DMG"
ln -s "$REAL" "$STUBS/timeout"
for k in pkill killall; do printf '#!/bin/sh\necho "%s $*" >>"%s"\nexit 0\n' "$k" "$KILLS" >"$STUBS/$k"; done
# xcrun stub. XCRUN_MODE: hang (starts a child and waits on it, so the test can see
# whether the clock reaps it), reject (a login Apple refuses: exit 1, no verdict),
# invalid (exit 0 with the verdict Invalid), ok-on-N (hang until attempt N, then Accepted),
# wait-expired (notarytool's own --timeout ran out: exit 1, status In Progress), stubborn
# (ignores TERM, so only the clock's -k KILL ends it: timeout exits 137).
cat >"$STUBS/xcrun" <<EOF
#!/bin/bash
echo "xcrun \$*" >>"$CALLS"
n=\$(wc -l <"$CALLS" | tr -d ' ')
hang() { sleep 300 & echo \$! >>"$CHILD"; wait; }
case "\${XCRUN_MODE:-reject}" in
  hang) hang ;;
  ok-on-*) [ "\$n" -ge "\${XCRUN_MODE#ok-on-}" ] || hang
    echo '{"id":"stub-0001","status":"Accepted","message":"Processing complete"}'; exit 0 ;;
  invalid) echo '{"id":"stub-0002","status":"Invalid","message":"Processing complete"}'; exit 0 ;;
  wait-expired) echo '{"id":"stub-0003","status":"In Progress","message":"Timeout waiting for submission"}'; exit 1 ;;
  stubborn) trap '' TERM; sleep 300 & echo \$! >>"$CHILD"; wait ;;
  *) echo "Error: HTTP status code: 401. Unable to authenticate." >&2; exit 1 ;;
esac
EOF
chmod +x "$STUBS"/*
count() { wc -l <"$1" | tr -d ' '; }

run() {  # run <mode> [VAR=value...]: source the module and call it in a clean shell
  local mode="$1"; shift
  : >"$CALLS"; : >"$KILLS"; : >"$CHILD"
  # The test's own outer limit: a module that fails to bound an attempt must fail this
  # test in seconds, not hang it for the stub's 300s sleep.
  "$REAL" -k 5 30 env "$@" TMPDIR="$WORK" PATH="$STUBS:/usr/bin:/bin" XCRUN_MODE="$mode" RK_NOTARIZE_ATTEMPT_SECONDS=1 \
    bash -c '. "$1"; rk_notarize "$2" prof' _ "$SUBJECT" "$DMG" >"$WORK/out" 2>&1
}

# Another lane's notarization, as `pkill -f "notarytool submit"` would match it.
bash -c 'exec -a "xcrun notarytool submit Other.dmg --wait" sleep 300' &
DECOY=$!
sleep 0.2

# 1. Every attempt hangs: three attempts, fail closed, each bounded by the clock.
start=$SECONDS; run hang; rc=$?; took=$((SECONDS-start))
[ "$rc" = 1 ] && ok "three hung attempts fail closed" || bad "hung attempts returned $rc, want 1"
[ "$(count "$CALLS")" = 3 ] && ok "exactly three attempts are made" || bad "attempts: $(count "$CALLS")"
[ "$took" -lt 20 ] && ok "each attempt is bounded by the clock (${took}s for three 1s attempts)" || bad "three 1s attempts took ${took}s"
grep -q "notarytool history --keychain-profile prof" "$WORK/out" && ok "the failure prints the history diagnosis" || bad "no diagnosis in: $(head -c 300 "$WORK/out")"

# 2. The clock reaps the child it started.
alive=0; while read -r p; do kill -0 "$p" 2>/dev/null && alive=$((alive+1)); done <"$CHILD"
[ -s "$CHILD" ] && [ "$alive" = 0 ] && ok "a hung attempt's own child is reaped" || bad "$alive of $(count "$CHILD") attempt children still running"

# 3. No machine-wide kill, and another lane's notarization survives.
[ ! -s "$KILLS" ] && ok "no pkill or killall is invoked" || bad "invoked: $(tr '\n' ';' <"$KILLS")"
kill -0 "$DECOY" 2>/dev/null && ok "another lane's notarytool process is left running" || bad "the decoy notarization was killed"
code="$(grep -vE '^[[:space:]]*#' "$SUBJECT")"
if grep -qE '(^|[^[:alnum:]_])(pkill|killall)([^[:alnum:]_]|$)' <<<"$code"; then
  bad "pkill or killall is executable code in the module"
else
  ok "the module has no pkill or killall outside comments"
fi

# 4. Only the clock retries: a rejection or an Invalid verdict stops after one submission,
# and exit 0 alone is not a pass. A success after a hung attempt stops the loop.
run reject; rc=$?
[ "$rc" = 1 ] && [ "$(count "$CALLS")" = 1 ] && grep -q "exit 1, not by the clock" "$WORK/out" \
  && ! grep -q "did not complete within" "$WORK/out" \
  && ok "a rejection is not resubmitted and is not reported as a timeout" || bad "reject: rc=$rc calls=$(count "$CALLS") out=$(head -c 400 "$WORK/out")"
run invalid; rc=$?
[ "$rc" = 1 ] && [ "$(count "$CALLS")" = 1 ] && grep -q "verdict Invalid (submission stub-0002)" "$WORK/out" \
  && grep -q "notarytool log stub-0002 --keychain-profile prof" "$WORK/out" \
  && ok "an Invalid verdict fails on exit 0, once, naming the log command" || bad "invalid: rc=$rc calls=$(count "$CALLS") out=$(head -c 400 "$WORK/out")"
run ok-on-2; rc=$?
[ "$rc" = 0 ] && [ "$(count "$CALLS")" = 2 ] && grep -q "notarized: App.dmg (submission stub-0001, Accepted)" "$WORK/out" \
  && ok "an Accepted verdict after a hung attempt returns 0 without a third" || bad "ok-on-2: rc=$rc calls=$(count "$CALLS") out=$(head -c 400 "$WORK/out")"
grep -qF -- "notarytool submit $DMG --keychain-profile prof --wait --timeout 12m --output-format json" "$CALLS" \
  && ok "the file, profile, verdict wait and JSON output reach notarytool" || bad "xcrun got: $(head -1 "$CALLS")"
run wait-expired; rc=$?
[ "$rc" = 1 ] && [ "$(count "$CALLS")" = 1 ] && grep -q "xcrun notarytool wait stub-0003 --keychain-profile prof" "$WORK/out" \
  && ! grep -q "rejected login" "$WORK/out" \
  && ok "notarytool's own wait running out is named as such, points at notarytool wait, and is not resubmitted" \
  || bad "wait-expired: rc=$rc calls=$(count "$CALLS") out=$(head -c 500 "$WORK/out")"
run stubborn RK_NOTARIZE_ATTEMPTS=2 RK_NOTARIZE_KILL_AFTER=1; rc=$?
alive=0; while read -r p; do kill -0 "$p" 2>/dev/null && alive=$((alive+1)); done <"$CHILD"
[ "$rc" = 1 ] && [ "$(count "$CALLS")" = 2 ] && [ "$(grep -c "did not complete within" "$WORK/out")" = 2 ] && [ "$alive" = 0 ] \
  && ok "an attempt that ignores TERM is killed (exit 137), reaped and retried like a timeout" \
  || bad "stubborn: rc=$rc calls=$(count "$CALLS") alive=$alive out=$(head -c 500 "$WORK/out")"
run hang RK_NOTARIZE_ATTEMPTS=5; [ "$(count "$CALLS")" = 5 ] && ok "RK_NOTARIZE_ATTEMPTS sets the attempt count" || bad "5 attempts wanted, got $(count "$CALLS")"
[ -z "$(find "$WORK" -maxdepth 1 -name 'rk-notary-verdict.*')" ] && ok "no verdict file is left behind" || bad "verdict files left: $(ls "$WORK")"

# 5. Bad arguments submit nothing.
: >"$CALLS"
env PATH="$STUBS:/usr/bin:/bin" bash -c '. "$1"; rk_notarize /nonexistent.dmg prof' _ "$SUBJECT" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && [ ! -s "$CALLS" ] && ok "a missing file is refused before any submission" || bad "missing file: rc=$rc calls=$(count "$CALLS")"
env PATH="$STUBS:/usr/bin:/bin" bash -c '. "$1"; rk_notarize "$2" ""' _ "$SUBJECT" "$DMG" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && [ ! -s "$CALLS" ] && ok "a missing profile is refused before any submission" || bad "missing profile: rc=$rc calls=$(count "$CALLS")"

# 6. A fake clock (claims coreutils, does not interrupt) is refused; so is no clock at all.
rm "$STUBS/timeout"
printf '#!/bin/sh\n[ "$1" = --version ] && { echo "timeout (GNU coreutils) 9.9"; exit 0; }\nshift; [ "$1" = -k ] && shift 2\nexec "$@"\n' >"$STUBS/timeout"
chmod +x "$STUBS/timeout"
: >"$CALLS"
env PATH="$STUBS:/usr/bin:/bin" bash -c '. "$1"; rk_notarize "$2" prof' _ "$SUBJECT" "$DMG" >"$WORK/out" 2>&1; rc=$?
if [ -x /usr/bin/timeout ] || [ -x /bin/timeout ]; then
  ok "(a system timeout exists, so the fake-clock case cannot be isolated here)"
else
  [ "$rc" = 1 ] && [ ! -s "$CALLS" ] && grep -q "did not interrupt" "$WORK/out" \
    && ok "a timeout that does not interrupt is refused and nothing is submitted" \
    || bad "fake clock: rc=$rc calls=$(count "$CALLS") out=$(head -c 200 "$WORK/out")"
  rm "$STUBS/timeout"; : >"$CALLS"
  env PATH="$STUBS:/usr/bin:/bin" bash -c '. "$1"; rk_notarize "$2" prof' _ "$SUBJECT" "$DMG" >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 1 ] && [ ! -s "$CALLS" ] && grep -q "could not be bounded" "$WORK/out" \
    && ok "with no GNU timeout it refuses and submits nothing" \
    || bad "no clock: rc=$rc calls=$(count "$CALLS") out=$(head -c 200 "$WORK/out")"
fi

echo "notarize: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
