#!/usr/bin/env bash
# Upload one retained dSYM archive to Crashbox, on purpose and never by accident.
#
#   ./scripts/upload-dsym.sh dist/dsym/Baton-0.19.3+103-<uuid>.dSYM.zip baton-macos
#
# The release scripts do not call this. A release must not contact a reporting
# provider implicitly, so publish.sh and testflight.sh only retain the verified
# dSYM and print the command; a person runs it afterwards and records the receipt
# on the task.
#
# Everything that touches the Crashbox host runs as the crashbox service account
# through systemd-run. Running a Crashbox CLI under plain sudo compiles bytecode
# into the release tree and the release verifier then refuses to start the units:
# that took ingest down for 26 minutes on 2026-09-09. This script never runs a
# Crashbox command any other way, and it counts the .pyc files afterwards to prove
# it left none.
set -euo pipefail

usage() {
  echo "usage: $0 <dSYM.zip> <baton-macos|baton-ios>" >&2
  echo "  env: CRASHBOX_SSH_HOST or WEB01 (the Crashbox host, required), CRASHBOX_REMOTE_DIR (default /tmp)" >&2
  exit 64
}

[ "$#" -eq 2 ] || usage
ZIP="$1"
SLUG="$2"
HOST="${CRASHBOX_SSH_HOST:-${WEB01:-}}"
[ -n "$HOST" ] || { echo "set CRASHBOX_SSH_HOST or WEB01 to the Crashbox host" >&2; exit 64; }
REMOTE_DIR="${CRASHBOX_REMOTE_DIR:-/tmp}"
VENV="/opt/crashbox/current/.venv/bin"

case "$SLUG" in
  baton-macos|baton-ios) ;;
  *) echo "refusing: '$SLUG' is not a Baton Crashbox project" >&2; exit 64 ;;
esac
[ -f "$ZIP" ] || { echo "refusing: $ZIP is not a regular file" >&2; exit 1; }
case "$ZIP" in *.zip) ;; *) echo "refusing: $ZIP is not a .zip archive" >&2; exit 1 ;; esac

# One helper for every remote Crashbox command, so there is exactly one place
# where the invocation form can be got wrong.
crashbox_run() {
  # shellcheck disable=SC2029  # the command is built here on purpose
  ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" \
    "sudo systemd-run --uid=crashbox --gid=crashbox \
       -p EnvironmentFile=/etc/crashbox/crashbox.env \
       --pipe --wait --collect --quiet $VENV/$*"
}

SIZE="$(stat -f%z "$ZIP" 2>/dev/null || stat -c%s "$ZIP")"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

# Read the UUIDs out of the archive rather than trusting the filename. This is the
# only property that decides whether a stored crash can ever be symbolicated, and
# an archive with no DWARF member uploads perfectly happily.
TMP="$(mktemp -d -t baton-dsym-upload)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
unzip -q -o "$ZIP" '*/Contents/Resources/DWARF/*' -d "$TMP" 2>/dev/null || true
UUIDS="$(find "$TMP" -type f -path '*/Contents/Resources/DWARF/*' -exec dwarfdump --uuid {} + 2>/dev/null \
  | sed -E 's/^UUID: ([0-9A-Fa-f-]+) \(([^)]+)\).*/\2 \1/' | LC_ALL=C sort || true)"
[ -n "$UUIDS" ] || { echo "refusing: $ZIP carries no dSYM DWARF member with a UUID" >&2; exit 1; }

echo "uploading $(basename "$ZIP") to $SLUG"
echo "  size    ${SIZE} bytes"
echo "  sha256  $SHA"
echo "$UUIDS" | sed 's/^/  UUID    /'

PROJECT_JSON="$(crashbox_run "crashbox-project inspect-fingerprint --project $SLUG")"
PROJECT_ID="$(printf '%s' "$PROJECT_JSON" | sed -E 's/.*"project_id":"([0-9a-f-]+)".*/\1/')"
case "$PROJECT_ID" in
  ????????-????-????-????-????????????) ;;
  *) echo "refusing: could not resolve a project id for $SLUG" >&2; exit 1 ;;
esac
echo "  project $SLUG -> $PROJECT_ID"

REMOTE="$REMOTE_DIR/$(basename "$ZIP")"
scp -q "$ZIP" "$HOST:$REMOTE"
# The upload runs as crashbox and reads this file, so it has to be world readable
# for the length of the upload and gone straight afterwards.
ssh -o BatchMode=yes "$HOST" "chmod 0644 '$REMOTE'"
RC=0
RECEIPT="$(crashbox_run "crashbox-artifact-upload dsym --project $PROJECT_ID --file $REMOTE")" || RC=$?
ssh -o BatchMode=yes "$HOST" "rm -f '$REMOTE'" || true

if [ "$RC" -ne 0 ]; then
  echo "upload failed (exit $RC)" >&2
  exit "$RC"
fi

# The release tree must be exactly as clean as it was before this ran.
PYC="$(ssh -o BatchMode=yes "$HOST" "sudo find /opt/crashbox/current/ -name '*.pyc' | wc -l" | tr -d ' ')"

# The receipt is written next to the archive, and that file is what publish.sh and
# testflight.sh read to decide whether their DONE line says "uploaded" or "NOT
# uploaded". Without it a release has no way to tell the two apart and says nothing,
# which is how the last dSYM went stale.
printf '%s\n' "$RECEIPT" > "$ZIP.receipt.json"

echo
echo "receipt: $RECEIPT"
echo "  written to $ZIP.receipt.json"
echo "  pyc under /opt/crashbox/current: $PYC (must be 0)"
[ "$PYC" = 0 ] || { echo "the upload left bytecode in the release tree; tell the Crashbox owner" >&2; exit 1; }
echo "Record the receipt, the UUIDs and the size on the task. Never paste file contents."
