#!/bin/bash
#
# Drives scripts/check-untracked-credentials.sh against throwaway repositories with
# planted FAKE credentials. No real credential is read or needed. (TBX-7289)
#
# The first case reproduces the state that was found on 2026-09-23: the .gitignore of
# that day, which named only the two Crashbox.local.xcconfig files, and an upload
# credential sitting untracked in ios/Config/. The guard must refuse it. The rest pin
# each pattern, the keys-only JSON rule, staged additions, the exemptions, the current
# .gitignore, and the wiring into publish-repo.sh and the test gate.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/scripts/check-untracked-credentials.sh"
WORK="$(mktemp -d -t baton-credential-guard-test)"
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0
ok()  { passed=$((passed + 1)); echo "ok   $*"; }
bad() { failed=$((failed + 1)); echo "FAIL $*"; }

# Deliberately not the 43-character shape of a real token, so publish-repo.sh guard (b2)
# has nothing to say about this file.
FAKE_TOKEN="cbu1_FAKE_TEST_VALUE_NOT_A_TOKEN"
fake_credential() {
  printf '{"dsym_url":"https://example.test/dsym","expires_at":"2099-01-01T00:00:00Z","label":"fake","project_id":"00000000-0000-4000-8000-000000000000","project_slug":"fake","scope":"upload","source_map_url":"https://example.test/map","token":"%s","version":1}\n' "$FAKE_TOKEN"
}

# A fresh repo with one commit. $1 is the .gitignore to use.
fresh_repo() {
  local repo="$WORK/repo.$RANDOM$RANDOM"
  mkdir -p "$repo/app/Config" "$repo/ios/Config"
  git init -q -b main "$repo"
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name t
  printf '%s' "$1" >"$repo/.gitignore"
  printf 'tracked\n' >"$repo/README"
  printf 'template\n' >"$repo/ios/Config/CrashboxArtifactUpload.local.json.example"
  git -C "$repo" add .gitignore README ios/Config/CrashboxArtifactUpload.local.json.example
  git -C "$repo" commit -qm initial
  printf '%s\n' "$repo"
}

# Runs the guard; sets rc and out (stdout+stderr).
run_guard() {
  out="$("$GUARD" "$1" 2>&1)"
  rc=$?
}

expect_refused() {
  local label="$1" repo="$2" name="$3"
  run_guard "$repo"
  if [ "$rc" != 1 ]; then
    bad "$label: expected exit 1, got $rc. Output: $out"
  elif ! printf '%s' "$out" | grep -qF "$name"; then
    bad "$label: refused but did not name $name. Output: $out"
  elif printf '%s' "$out" | grep -qF "$FAKE_TOKEN"; then
    bad "$label: the guard printed the credential value"
  else
    ok "$label"
  fi
}

expect_clean() {
  local label="$1" repo="$2"
  run_guard "$repo"
  if [ "$rc" = 0 ]; then ok "$label"; else bad "$label: expected exit 0, got $rc. Output: $out"; fi
}

PRE_FIX_IGNORE='# Protected Crashbox DSNs. Hosted-provider inputs are deliberately unsupported.
app/Config/Crashbox.local.xcconfig
ios/Config/Crashbox.local.xcconfig
'
CURRENT_IGNORE="$(cat "$ROOT/.gitignore")
"

# --- The state found on 2026-09-23 -----------------------------------------------------
repo="$(fresh_repo "$PRE_FIX_IGNORE")"
expect_clean "a clean tree under the pre-fix .gitignore passes" "$repo"
fake_credential >"$repo/ios/Config/CrashboxArtifactUpload.local.json"
chmod 600 "$repo/ios/Config/CrashboxArtifactUpload.local.json"
expect_refused "RED on the pre-fix state: an unignored ios/Config credential is refused" \
  "$repo" "ios/Config/CrashboxArtifactUpload.local.json"

# The same planted file under the current .gitignore is ignored, which is the protected
# state: the guard must pass it rather than complain about a file git will never take.
repo="$(fresh_repo "$CURRENT_IGNORE")"
expect_clean "GREEN: a clean tree under the current .gitignore passes" "$repo"
fake_credential >"$repo/ios/Config/CrashboxArtifactUpload.local.json"
fake_credential >"$repo/app/Config/Other.local.json"
printf 'X=1\n' >"$repo/app/Config/Anything.local.xcconfig"
if [ -n "$(git -C "$repo" ls-files --others --exclude-standard)" ]; then
  bad "current .gitignore: Config/*.local.* files are not all ignored: $(git -C "$repo" ls-files --others --exclude-standard | tr '\n' ' ')"
else
  ok "current .gitignore ignores every Config/*.local.* file"
fi
expect_clean "GREEN: the same credential under the current .gitignore is ignored and passes" "$repo"
printf 'new template\n' >"$repo/app/Config/New.local.json.example"
if [ "$(git -C "$repo" ls-files --others --exclude-standard)" = "app/Config/New.local.json.example" ]; then
  ok "current .gitignore still lets a new Config .example template be added"
else
  bad "current .gitignore hides a new Config .example template"
fi

# --- Each name pattern, outside any ignored directory -----------------------------------
for name in deploy.local.json dist.p12 AuthKey_TEST.p8 release-credential.txt \
            MY_SECRET.env.bak access-token.txt; do
  repo="$(fresh_repo "$PRE_FIX_IGNORE")"
  printf 'fake\n' >"$repo/$name"
  expect_refused "name pattern: $name is refused" "$repo" "$name"
done

# --- The keys-only JSON rule -----------------------------------------------------------
repo="$(fresh_repo "$PRE_FIX_IGNORE")"
fake_credential >"$repo/upload.json"
expect_refused "JSON with a top-level token key is refused under an innocent name" "$repo" "upload.json"

repo="$(fresh_repo "$PRE_FIX_IGNORE")"
printf '{"settings":{"token":"%s"}}\n' "$FAKE_TOKEN" >"$repo/settings.json"
printf 'not json {\n' >"$repo/broken.json"
expect_clean "nested token keys and unparseable JSON are not refused" "$repo"

# --- Staged new files count too --------------------------------------------------------
repo="$(fresh_repo "$PRE_FIX_IGNORE")"
fake_credential >"$repo/ios/Config/CrashboxArtifactUpload.local.json"
git -C "$repo" add ios/Config/CrashboxArtifactUpload.local.json
run_guard "$repo"
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -qF "staged as a new file"; then
  ok "a credential already staged by 'git add -A' is refused and called staged"
else
  bad "a staged credential was not refused as staged (rc=$rc). Output: $out"
fi

# --- Exemptions ------------------------------------------------------------------------
repo="$(fresh_repo "$PRE_FIX_IGNORE")"
printf 'struct SecretStore {}\n' >"$repo/SecretStore.swift"
printf '# tokens\n' >"$repo/token-notes.md"
printf '#!/bin/sh\n' >"$repo/check-credentials.sh"
printf 'pass\n' >"$repo/secret_policy.py"
printf 'template\n' >"$repo/ios/Config/Another.local.json.example"
expect_clean "Swift, Python, shell, Markdown and .example templates are not refused" "$repo"

run_guard "$WORK/not-a-repo"
if [ "$rc" = 2 ]; then ok "a path that is not a repository exits 2, not a false clean"; else bad "non-repository exited $rc"; fi

# --- Wiring ------------------------------------------------------------------------------
if grep -qF 'scripts/check-untracked-credentials.sh" "$SRC"' "$ROOT/scripts/publish-repo.sh"; then
  ok "wiring: publish-repo.sh runs the guard before it copies the tree"
else
  bad "wiring: publish-repo.sh no longer runs check-untracked-credentials.sh"
fi
if grep -qF -- "--exclude='*.local.json'" "$ROOT/scripts/publish-repo.sh"; then
  ok "wiring: publish-repo.sh never copies a *.local.json into the mirror"
else
  bad "wiring: publish-repo.sh no longer excludes *.local.json"
fi
if grep -qE '^for guard in .*test-untracked-credentials' "$ROOT/scripts/test.sh"; then
  ok "wiring: scripts/test.sh runs this test"
else
  bad "wiring: scripts/test.sh does not run test-untracked-credentials"
fi

echo
echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
