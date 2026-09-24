#!/bin/bash
# Source-level contract for the credential-free preproduction archive command.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

SUBJECT="ios/scripts/crashbox-preproduction.sh"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok    $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

if grep -qF 'BATON_INTERNAL_DIAGNOSTICS=NO' "$SUBJECT" && \
   grep -qF -- '--provider disabled' "$SUBJECT" && \
   grep -qF 'CODE_SIGNING_ALLOWED=NO' "$SUBJECT"; then
  ok "candidate is reporting-disabled, diagnostics-disabled, and unsigned"
else
  bad "candidate no longer fixes all three source-safe policies"
fi

if grep -qF 'build must be newer than the installed build' "$SUBJECT" && \
   grep -qF 'COMMIT="$(git -C "$REPO" rev-parse HEAD)"' "$SUBJECT" && \
   grep -qF 'release=$RELEASE' "$SUBJECT"; then
  ok "candidate identity is exact, release-bound, and newer than the supplied rollback pin"
else
  bad "candidate identity or monotonic-build guard is missing"
fi

if grep -Eq 'altool|notarytool|simctl install|devicectl device install' "$SUBJECT"; then
  bad "candidate command gained an installation or publication path"
elif grep -Eq 'Crashbox\.local|ArtifactUpload\.local|P12_|ASC_' "$SUBJECT"; then
  bad "candidate command gained a credential path"
else
  ok "candidate command has no installation, publication, or credential path"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
