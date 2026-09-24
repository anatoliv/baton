#!/bin/bash
#
# TBX-5483's local upload contract. No network, release, or real credential.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '\033[32mok    %s\033[0m\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '\033[31mFAIL  %s\033[0m\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PYTHON="$(command -v python3)"
HELPER="$PWD/scripts/crashbox-artifact-upload.py"
TOKEN='cbu1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
PROJECT='11111111-2222-4333-8444-555555555555'
CREDENTIAL="$WORK/credential.json"
ARCHIVE="$WORK/Baton-0.20.0+120-AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE.dSYM.zip"
RELEASE='io.tonebox.baton@0.20.0+120.0123456789abcdef0123456789abcdef01234567'
EXPECTED_PROJECT='baton-macos'
CREDENTIAL_PROJECT='baton-macos'

write_credential() {
  cat >"$CREDENTIAL" <<EOF
{"dsym_url":"https://ingest.crashbox.dev/artifacts/v1/dsym","expires_at":"2099-01-01T00:00:00Z","label":"baton-publish","project_id":"$PROJECT","project_slug":"$CREDENTIAL_PROJECT","scope":"upload","source_map_url":"https://ingest.crashbox.dev/artifacts/v1/source-map","token":"$TOKEN","version":1}
EOF
  chmod 600 "$CREDENTIAL"
}

write_credential
printf 'bounded fake dSYM bytes\n' >"$ARCHIVE"

out="$($PYTHON "$HELPER" check "$CREDENTIAL" --project "$EXPECTED_PROJECT" 2>"$WORK/check.err")"
rc=$?
if [ "$rc" -ne 0 ]; then
  bad "a generated mode-0600 Baton credential passes preflight"
elif printf '%s' "$out" | grep -qF "$TOKEN" || grep -qF "$TOKEN" "$WORK/check.err"; then
  bad "credential preflight printed its token"
elif ! printf '%s' "$out" | grep -qF '"project_slug":"baton-macos"'; then
  bad "credential preflight did not return safe project identity"
else
  ok "a generated mode-0600 Baton credential passes without printing its token"
fi

chmod 644 "$CREDENTIAL"
$PYTHON "$HELPER" check "$CREDENTIAL" --project "$EXPECTED_PROJECT" >"$WORK/mode.out" 2>"$WORK/mode.err"
rc=$?
if [ "$rc" -eq 0 ] || ! grep -qF 'credential_permissions_invalid' "$WORK/mode.err"; then
  bad "a credential readable by other users is refused"
else
  ok "a credential readable by other users is refused before upload"
fi

write_credential
ln -s "$CREDENTIAL" "$WORK/credential-link.json"
$PYTHON "$HELPER" check "$WORK/credential-link.json" --project "$EXPECTED_PROJECT" >"$WORK/link.out" 2>"$WORK/link.err"
rc=$?
if [ "$rc" -eq 0 ]; then
  bad "a credential symlink is refused"
else
  ok "a credential symlink is refused"
fi

sed -i '' 's/2099-01-01T00:00:00Z/2000-01-01T00:00:00Z/' "$CREDENTIAL"
$PYTHON "$HELPER" check "$CREDENTIAL" --project "$EXPECTED_PROJECT" >"$WORK/expired.out" 2>"$WORK/expired.err"
rc=$?
if [ "$rc" -eq 0 ] || ! grep -qF 'credential_expired' "$WORK/expired.err"; then
  bad "an expired credential is refused"
else
  ok "an expired credential is refused"
fi
write_credential

sed -i '' 's/"version":1/"version":1,"version":1/' "$CREDENTIAL"
$PYTHON "$HELPER" check "$CREDENTIAL" --project "$EXPECTED_PROJECT" >"$WORK/duplicate.out" 2>"$WORK/duplicate.err"
rc=$?
if [ "$rc" -eq 0 ] || ! grep -qF 'credential_shape_invalid' "$WORK/duplicate.err"; then
  bad "a credential with a duplicate JSON key is refused"
else
  ok "a credential with a duplicate JSON key is refused"
fi
write_credential

$PYTHON "$HELPER" check "$CREDENTIAL" --project baton-ios >"$WORK/project.out" 2>"$WORK/project.err"
rc=$?
if [ "$rc" -eq 0 ] || ! grep -qF 'credential_shape_invalid' "$WORK/project.err"; then
  bad "a credential for another Baton project is refused"
else
  ok "a credential for another Baton project is refused before upload"
fi

CREDENTIAL_PROJECT='baton-ios'
EXPECTED_PROJECT='baton-ios'
write_credential
out="$($PYTHON "$HELPER" check "$CREDENTIAL" --project "$EXPECTED_PROJECT" 2>"$WORK/ios-check.err")"
rc=$?
if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | grep -qF '"project_slug":"baton-ios"'; then
  bad "a mode-0600 Baton iPhone credential passes its exact project preflight"
else
  ok "a mode-0600 Baton iPhone credential passes its exact project preflight"
fi

# curl is a deterministic local receiver. It records argv separately from the
# stdin config so the test can prove the bearer never became a process argument.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/curl" <<'EOF'
#!/bin/bash
set -eu
printf '%s\n' "$@" >"$STUB_ARGS"
config="$(/bin/cat)"
printf '%s' "$config" >"$STUB_CONFIG"
[ "${STUB_MODE:-ok}" != transport-fail ] || exit 22
archive=''; release=''
for argument in "$@"; do
  case "$argument" in
    @/dev/fd/*) archive="${argument#@}" ;;
    X-Crashbox-Release:\ *) release="${argument#X-Crashbox-Release: }" ;;
  esac
done
[ -n "$archive" ] && [ -n "$release" ] || exit 64
digest="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
[ "${STUB_MODE:-ok}" != mismatched ] || digest='ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
printf '{"artifact_id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","project_id":"11111111-2222-4333-8444-555555555555","release":"%s","sha256":"%s","state":"ready","type":"apple_dsym"}\n' "$release" "$digest"
EOF
chmod +x "$WORK/bin/curl"

run_upload() {
  PATH="$WORK/bin:/usr/bin:/bin" \
  STUB_ARGS="$WORK/curl.args" STUB_CONFIG="$WORK/curl.config" \
  STUB_MODE="${1:-ok}" \
    "$PYTHON" "$HELPER" upload "$CREDENTIAL" "$ARCHIVE" "$RELEASE" \
      --project "$EXPECTED_PROJECT"
}

RECEIPT="$ARCHIVE.receipt.json"
ARCHIVE_SHA="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"
printf '{"artifact_id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","project_id":"%s","sha256":"%s","type":"apple_dsym"}\n' \
  "$PROJECT" "$ARCHIVE_SHA" >"$RECEIPT"
chmod 644 "$RECEIPT"
out="$(run_upload ok 2>"$WORK/upload.err")"
rc=$?
if [ "$rc" -ne 0 ] || [ ! -f "$RECEIPT" ]; then
  bad "a matching accepted response upgrades a legacy receipt"
elif [ "$(stat -f '%Lp' "$RECEIPT")" != 600 ]; then
  bad "the upgraded receipt is not mode 0600"
elif grep -qF "$TOKEN" "$WORK/curl.args" || printf '%s' "$out" | grep -qF "$TOKEN"; then
  bad "the bearer token reached argv or normal output"
elif ! grep -qF "Authorization: Bearer $TOKEN" "$WORK/curl.config"; then
  bad "the bearer token was not passed through curl's stdin config"
elif ! grep -qF "X-Crashbox-Release: $RELEASE" "$WORK/curl.args"; then
  bad "the upload did not use the exact SDK release string"
elif ! grep -qF '"state":"ready"' "$RECEIPT"; then
  bad "the upgraded receipt does not record Crashbox's ready response"
elif ! grep -qF '"release":"io.tonebox.baton@' "$RECEIPT"; then
  bad "the upgraded receipt does not record release provenance"
else
  ok "an exact legacy receipt upgrades atomically to the mode-0600 current receipt"
fi

rm -f "$RECEIPT"
printf '{"artifact_id":"ffffffff-bbbb-4ccc-8ddd-eeeeeeeeeeee","project_id":"%s","sha256":"%s","type":"apple_dsym"}\n' \
  "$PROJECT" "$ARCHIVE_SHA" >"$RECEIPT"
chmod 644 "$RECEIPT"
before="$(shasum -a 256 "$RECEIPT")"
run_upload ok >"$WORK/identity.out" 2>"$WORK/identity.err"
rc=$?
after="$(shasum -a 256 "$RECEIPT")"
if [ "$rc" -eq 0 ] || [ "$before" != "$after" ] || ! grep -qF receipt_conflict "$WORK/identity.err"; then
  bad "a legacy receipt for another artifact is refused without overwrite"
else
  ok "a legacy receipt for another artifact is refused without overwrite"
fi

printf '{malformed\n' >"$RECEIPT"
chmod 644 "$RECEIPT"
before="$(shasum -a 256 "$RECEIPT")"
run_upload ok >"$WORK/malformed.out" 2>"$WORK/malformed.err"
rc=$?
after="$(shasum -a 256 "$RECEIPT")"
if [ "$rc" -eq 0 ] || [ "$before" != "$after" ] || ! grep -qF receipt_conflict "$WORK/malformed.err"; then
  bad "a malformed legacy receipt is refused without overwrite"
else
  ok "a malformed legacy receipt is refused without overwrite"
fi

printf '{"artifact_id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","project_id":"%s","sha256":"%s","type":"apple_dsym"}\n' \
  "$PROJECT" "$ARCHIVE_SHA" >"$RECEIPT"
chmod 666 "$RECEIPT"
before="$(shasum -a 256 "$RECEIPT")"
run_upload ok >"$WORK/mode-receipt.out" 2>"$WORK/mode-receipt.err"
rc=$?
after="$(shasum -a 256 "$RECEIPT")"
if [ "$rc" -eq 0 ] || [ "$before" != "$after" ] || ! grep -qF receipt_conflict "$WORK/mode-receipt.err"; then
  bad "a legacy receipt with unsafe permissions is refused without overwrite"
else
  ok "a legacy receipt with unsafe permissions is refused without overwrite"
fi

rm -f "$RECEIPT"
printf 'do not replace me\n' >"$WORK/receipt-target"
ln -s "$WORK/receipt-target" "$RECEIPT"
run_upload ok >"$WORK/symlink-receipt.out" 2>"$WORK/symlink-receipt.err"
rc=$?
if [ "$rc" -eq 0 ] || [ "$(cat "$WORK/receipt-target")" != "do not replace me" ] \
   || ! grep -qF receipt_conflict "$WORK/symlink-receipt.err"; then
  bad "a receipt symlink is refused without touching its target"
else
  ok "a receipt symlink is refused without touching its target"
fi

rm -f "$RECEIPT"
run_upload transport-fail >"$WORK/fail.out" 2>"$WORK/fail.err"
rc=$?
if [ "$rc" -eq 0 ] || [ -e "$RECEIPT" ]; then
  bad "a transport failure is fatal and writes no receipt"
elif grep -qF "$TOKEN" "$WORK/fail.out" "$WORK/fail.err"; then
  bad "a transport failure printed its credential"
else
  ok "a transport failure is fatal, payload-free, and writes no receipt"
fi

run_upload mismatched >"$WORK/mismatch.out" 2>"$WORK/mismatch.err"
rc=$?
if [ "$rc" -eq 0 ] || [ -e "$RECEIPT" ]; then
  bad "a response for different bytes is refused and writes no receipt"
elif ! grep -qF 'response_mismatch' "$WORK/mismatch.err"; then
  bad "a mismatched response did not give its stable refusal code"
else
  ok "a response for different bytes is refused and writes no receipt"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
