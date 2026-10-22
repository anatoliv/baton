#!/usr/bin/env bash
# test-ready.sh: the readiness scaffold names every precondition on its own line, counts only
# FAILs toward NOT READY, prints no secret, and reads lock records without taking a lock.
# Stubs stand in for the vault; credentials, repository and locks are temporary.
# RK_READY_SUBJECT points at a mutated copy. About two seconds.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUBJECT="${RK_READY_SUBJECT:-$HERE/../lib/ready.sh}"
[ -f "$SUBJECT" ] || { echo "FAIL  no module at $SUBJECT"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

unset NATIVE_LOCK_ENV NATIVE_LOCK_HOST_VAR NATIVE_LOCK_HOST_DEFAULT NATIVE_LOCK_WAIT RK_READY_VAULT_CMD
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/rk-ready.XXXXXX")" && pwd -P)"
STANDIN=""
trap '[ -z "$STANDIN" ] || kill "$STANDIN" 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM
export NATIVE_LOCK_HOST_FILE="$WORK/host.lock" NATIVE_LOCK_DIR="$WORK/native-locks"
mkdir -p "$WORK/bin" "$NATIVE_LOCK_DIR"
printf '#!/bin/bash\ncase "${STUB_VAULT:-open}" in locked) echo "vault is locked" >&2; exit 3;; broken) exit 7;; open) echo "Release env (demo)  [Developer Tools]";; esac\n' >"$WORK/bin/vault-find"
printf '#!/bin/bash\necho "lockf called" >>"%s/lockf.log"; exit 1\n' "$WORK" >"$WORK/bin/lockf"
chmod +x "$WORK/bin/vault-find" "$WORK/bin/lockf"
export PATH="$WORK/bin:$PATH"

R="$WORK/repo"; mkdir -p "$R"
git -C "$R" init -q; git -C "$R" config user.email t@example.invalid; git -C "$R" config user.name test
echo one >"$R/a"; git -C "$R" add -A; git -C "$R" commit -qm one
git -C "$R" update-ref refs/remotes/origin/main HEAD

CRED="$WORK/creds"; mkdir -p "$CRED"; chmod 700 "$CRED"
TOKEN="tok_THIS-MUST-NEVER-APPEAR-IN-OUTPUT"
printf '{"token": "%s"}\n' "$TOKEN" >"$CRED/good.json"; chmod 600 "$CRED/good.json"
printf '{"token": "%s"}\n' "$TOKEN" >"$CRED/loose.json"; chmod 644 "$CRED/loose.json"

sleep 60 & STANDIN=$!
disown "$STANDIN" 2>/dev/null || true
printf '%s\n%s\n%s\n%s\n%s\n' "$STANDIN" "$(ps -o lstart= -p "$STANDIN" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" \
  /tmp/another-checkout /tmp/app-dd gate >"$NATIVE_LOCK_HOST_FILE"
cp "$NATIVE_LOCK_HOST_FILE" "$NATIVE_LOCK_DIR/sim-AAAA.lock"
printf '%s\n%s\n%s\n%s\n%s\n' "$$" "Mon Jan  1 00:00:00 2001" /tmp/old /tmp/app-dd gate >"$NATIVE_LOCK_DIR/sim-OLD.lock"
lock_before="$(cksum <"$NATIVE_LOCK_HOST_FILE")"

run() {   # the project's script, as a project would write it
  /bin/bash -c '
    tests="$1" repo="$2" creds="$3"; shift 3
    . "$tests/../lib/native-lock.sh" 2>/dev/null || true
    . "$SUBJECT"
    hook_source() { rk_ready_tree "$repo"; rk_ready_on_main "$repo"; }
    hook_creds() { rk_ready_credential_dir "$creds"; rk_ready_credential_file "$creds" good.json
      rk_ready_credential_file "$creds" loose.json; rk_ready_credential_file "$creds" missing.json
      rk_ready_vault "Release env (demo)" "The phone release"; }
    hook_locks() { rk_ready_native_locks; }
    hook_tools() { rk_ready_warn "rsync: something worth knowing"; }
    rk_ready_run "Demo release readiness" "Both can run side by side." hook_source hook_creds hook_locks hook_tools "$@"
  ' _ "$HERE" "$R" "$CRED" "$@" 2>&1
}
export SUBJECT

out="$(STUB_VAULT=locked run)"; rc=$?
grep -q '^Demo release readiness, [0-9]' <<<"$out" && ok "the report starts with its title and the date" || bad "no title line. Got: $out"
grep -q 'FAIL  vault: locked; run secrets-unlock in a terminal tab (The phone release reads "Release env (demo)")' <<<"$out" \
  && ok "a locked vault is one FAIL naming secrets-unlock and who needs the item" || bad "a locked vault was not reported. Got: $out"
[ "$rc" = 1 ] && grep -q "^NOT READY: 3 item(s) above would stop a release.$" <<<"$out" \
  && ok "FAILs (and only FAILs) are counted: NOT READY with exit 1" || bad "the verdict is wrong (rc $rc). Got: $out"
out="$(STUB_VAULT=broken run)"
grep -q 'FAIL  vault: vault-find failed (exit 7)' <<<"$out" && ok "a vault command that fails otherwise is named with its exit" || bad "a broken vault was not named. Got: $out"
out="$(run)"
grep -q 'ok    vault: unlocked, "Release env (demo)" found' <<<"$out" && ok "an unlocked vault holding the item is ok" || bad "the vault item was not found. Got: $out"
grep -q "ok    tree: clean at [0-9a-f]\{12\}" <<<"$out" && grep -q "ok    source: HEAD is on origin/main (as of the last fetch)" <<<"$out" \
  && ok "a clean tree on origin/main gets two ok lines" || bad "tree or source line missing. Got: $out"
grep -q "ok    credentials: $CRED is 0700" <<<"$out" && grep -q "ok    credentials: good.json present, 0600" <<<"$out" \
  && grep -q "FAIL  credentials: loose.json is mode 644, not 0600" <<<"$out" \
  && grep -q "FAIL  credentials: missing.json is missing from $CRED" <<<"$out" \
  && ok "credential files are checked by presence and mode, each by name" || bad "credential lines are wrong. Got: $out"
if grep -qF "$TOKEN" <<<"$out" || grep -q 'tok_' <<<"$out"; then
  bad "the report printed a credential value"
else
  ok "no credential value appears in the report"
fi
grep -q "WARN  gate lock (mac-app-host): held by gate pid $STANDIN from /tmp/another-checkout; a release waits for it (NATIVE_LOCK_WAIT)" <<<"$out" \
  && grep -q "WARN  sim-AAAA: held by gate pid $STANDIN" <<<"$out" && ! grep -q "sim-OLD" <<<"$out" \
  && ok "held locks are named with their holder; a stale record (reused pid) is not" || bad "lock lines are wrong. Got: $out"
[ "$(cksum <"$NATIVE_LOCK_HOST_FILE")" = "$lock_before" ] && [ ! -e "$WORK/lockf.log" ] \
  && ok "lock records are read, never taken or changed" || bad "the readiness check touched a lock"
grep -q "WARN  rsync: something worth knowing" <<<"$out" && grep -q "^NOT READY: 2 item" <<<"$out" \
  && ok "a WARN is shown but does not count toward NOT READY" || bad "a WARN was counted. Got: $out"

chmod 600 "$CRED/loose.json"; touch "$CRED/missing.json"; chmod 600 "$CRED/missing.json"
out="$(run)"; rc=$?
[ "$rc" = 0 ] && grep -q "^READY: nothing above would stop a release. Both can run side by side.$" <<<"$out" \
  && ok "with no FAIL the report is READY with the project's note, exit 0" || bad "a clean report was not READY (rc $rc). Got: $out"
out="$(run hook_missing)"; rc=$?
[ "$rc" = 1 ] && grep -q "FAIL  readiness: the hook hook_missing is not defined" <<<"$out" \
  && ok "a hook the project forgot to define is a FAIL, not a silent pass" || bad "a missing hook passed. Got: $out"
echo dirty >>"$R/a"; git -C "$R" commit -qam two
out="$(run)"
grep -q "FAIL  source: HEAD is not on origin/main" <<<"$out" && ok "a HEAD that origin/main lacks is a FAIL" || bad "an unmerged HEAD passed. Got: $out"
echo more >>"$R/a"
out="$(run)"
grep -q "FAIL  tree: $R has uncommitted changes" <<<"$out" && ok "a dirty tree is a FAIL" || bad "a dirty tree passed. Got: $out"
git -C "$R" checkout -q -- a
printf 'not an index' >"$R/.git/index"   # corrupt: HEAD resolves, git status exits 128
out="$(run)"
grep -q "FAIL  tree: git status failed in $R" <<<"$out" && ! grep -q "ok    tree:" <<<"$out" \
  && ok "a tree git cannot read is a FAIL, not clean" || bad "a failed git status read as clean. Got: $out"

echo "ready: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
