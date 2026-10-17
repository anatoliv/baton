#!/bin/bash
#
# scripts/release-ready.sh names every release precondition up front, prints no secret, and
# reads the gate lock without taking it. (TBX-11003) Stubs stand in for the vault, the
# keychain, simulators and processes; the lock and credentials are temporary. A few seconds.
# shellcheck disable=SC2016 # stubs and greps carry literal $NAMES
set -uo pipefail
cd "$(dirname "$0")/.." || exit
ROOT="$PWD"
READY="$ROOT/scripts/release-ready.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '\033[32mok    %s\033[0m\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '\033[31mFAIL  %s\033[0m\n' "$1"; }

WORK="$(mktemp -d)"
STANDIN=""
trap '[ -z "$STANDIN" ] || kill "$STANDIN" 2>/dev/null; rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"
stub() { printf '#!/bin/bash\n%s\n' "$2" >"$BIN/$1"; chmod +x "$BIN/$1"; }
stub vault-find 'case "${STUB_VAULT:-open}" in locked) echo "vault is locked" >&2; exit 3;; open) echo "Apple - TestFlight env (baton)  [Developer Tools]";; esac'
stub security 'echo "  1) ABC \"Developer ID Application: Example (TEAMID)\""'
stub xcrun 'echo "{\"devices\": {\"com.apple.CoreSimulator.SimRuntime.iOS-26-5\": [{\"name\": \"iPhone 17\", \"udid\": \"A\"}], \"com.apple.CoreSimulator.SimRuntime.watchOS-26-5\": [{\"name\": \"Watch\", \"udid\": \"W\"}]}}"'
stub pgrep 'exit 1'
stub lockf 'echo "lockf called" >>"$LOCKF_LOG"; exit 1'
mkdir -p "$WORK/sparkle"
stub_sparkle() { printf '#!/bin/bash\n' >"$WORK/sparkle/$1"; chmod +x "$WORK/sparkle/$1"; }
stub_sparkle sign_update; stub_sparkle generate_keys

CRED="$WORK/crashbox"; mkdir -p "$CRED"; chmod 700 "$CRED"
TOKEN="cbu1_THIS-MUST-NEVER-APPEAR-IN-OUTPUT"
printf '{"token": "%s"}\n' "$TOKEN" >"$CRED/baton-macos-artifact-upload.json"
printf '{"token": "%s"}\n' "$TOKEN" >"$CRED/baton-ios-artifact-upload.json"
chmod 600 "$CRED/baton-macos-artifact-upload.json"
chmod 644 "$CRED/baton-ios-artifact-upload.json"

LOCK="$WORK/gate.lock"
# The stand-in holder lives as long as this test, not for a fixed time: a slow run cannot
# outlive it, and it goes away by itself if the test dies without its EXIT trap.
( while kill -0 "$$" 2>/dev/null; do sleep 1; done ) & STANDIN=$!
disown "$STANDIN" 2>/dev/null || true
printf '%s\n%s\n%s\n%s\n%s\n' "$STANDIN" \
  "$(ps -o lstart= -p "$STANDIN" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" \
  "/tmp/another-checkout" "/tmp/baton-dd" gate >"$LOCK"
lock_before="$(cksum <"$LOCK")"

cp "$ROOT/scripts/release-kit/lib/native-lock.sh" "$WORK/canonical-native-lock.sh"
run() {
  BATON_NATIVE_LOCK_CANONICAL="$WORK/canonical-native-lock.sh" \
  PATH="$BIN:$PATH" BATON_GATE_LOCK="$LOCK" NATIVE_LOCK_DIR="$WORK/native-locks" \
    BATON_GATE_RECEIPT_DIR="$WORK/receipts" BATON_RELEASE_READY_CREDENTIAL_DIR="$CRED" \
    SPARKLE_BIN="$WORK/sparkle" LOCKF_LOG="$WORK/lockf.log" "$READY" 2>&1
}

out="$(STUB_VAULT=locked run)"; rc=$?
if printf '%s' "$out" | grep -q "FAIL  vault: locked; run secrets-unlock"; then
  ok "a locked vault is one FAIL line naming secrets-unlock"
else
  bad "a locked vault was not reported. Got: $out"
fi
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "NOT READY"; then
  ok "any FAIL makes the report NOT READY with exit 1"
else
  bad "a failing report exited $rc. Got: $out"
fi

out="$(run)"
if printf '%s' "$out" | grep -q 'ok    vault: unlocked, "Apple - TestFlight env (baton)" found'; then
  ok "an unlocked vault with the TestFlight item is ok"
else
  bad "the unlocked vault was not recognized. Got: $out"
fi
if printf '%s' "$out" | grep -q "FAIL  credentials: baton-ios-artifact-upload.json is mode 644, not 0600" \
   && printf '%s' "$out" | grep -q "ok    credentials: baton-macos-artifact-upload.json present, 0600"; then
  ok "credential files are checked by mode, each by name"
else
  bad "credential modes were not reported. Got: $out"
fi
if printf '%s' "$out" | grep -qF "$TOKEN" || printf '%s' "$out" | grep -q 'cbu1_'; then
  bad "the report printed a credential value"
else
  ok "no credential value appears in the report"
fi
if printf '%s' "$out" | grep -q "WARN  gate lock (mac-app-host): held by gate pid $STANDIN from /tmp/another-checkout"; then
  ok "a held gate lock is named with its holder"
else
  bad "the gate lock holder was not named. Got: $out"
fi
if [ "$(cksum <"$LOCK")" = "$lock_before" ] && [ ! -e "$WORK/lockf.log" ]; then
  ok "the gate lock is read, never taken or changed"
else
  bad "release-ready touched the gate lock"
fi
for line in "ok    sparkle: $WORK/sparkle" "ok    simulators: 1 iPhone simulator(s) available" \
            "ok    simulators: watchOS runtime available" "ok    signing: 1 Developer ID Application" \
            "owner's Baton: not running"; do
  printf '%s' "$out" | grep -qF -- "$line" || missing="${missing:-} [$line]"
done
if [ -z "${missing:-}" ]; then
  ok "Sparkle tools, simulators, signing and the owner's Baton each get a line"
else
  bad "missing readiness lines:$missing"
fi
if printf '%s' "$out" | grep -qE "(ok|WARN)  +gate: |(ok|FAIL)  +public mirror: |(ok|WARN)  +rsync: |(ok|FAIL)  +tree: "; then
  ok "the gate receipt, public mirror guard, rsync and tree are reported"
else
  bad "a source or tool line is missing. Got: $out"
fi

if printf '%s' "$out" | grep -q "ok    native-lock: the kit module is byte-identical to the shared copy"; then
  ok "the kit's native-lock module is compared with the shared _method copy by digest"
else
  bad "the kit's native-lock module was not compared with the shared copy. Got: $out"
fi
if printf '%s' "$out" | grep -q "ok    release kit: .* matches its pin"; then
  ok "the vendored release kit is checked against its pin"
else
  bad "the vendored release kit's pin was not checked. Got: $out"
fi
printf '# drift\n' >>"$WORK/canonical-native-lock.sh"
out="$(run)"
if printf '%s' "$out" | grep -q "WARN  native-lock: the kit module differs from the shared copy"; then
  ok "a shared copy on another kit version is named as a WARN (the kit pin is the hard check)"
else
  bad "a differing shared copy was not reported. Got: $out"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
