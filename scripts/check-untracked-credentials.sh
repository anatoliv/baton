#!/bin/bash
#
# Refuse when a credential-looking file sits in the working tree where the next
# `git add -A` would take it, or is staged as a new file. (TBX-7289)
#
#   scripts/check-untracked-credentials.sh [repo-root]
#
# Exit 0 when nothing is found, 1 when something is, 2 when the check could not run.
#
# Why this exists: a live Crashbox upload credential sat at
# ios/Config/CrashboxArtifactUpload.local.json for over a week, untracked and NOT
# ignored, because .gitignore then named only the two Crashbox.local.xcconfig files.
# Nothing refused it. `git add -A` would have committed it, and publish-repo.sh
# rsyncs the WORKING TREE into the public mirror, so a gitignore rule is the only
# thing between a file like that and the public repository. This check does not
# trust the rule to exist: it looks at what is actually lying around.
#
# A file is suspect when its name matches *.local.json, *.p12, *.p8, *credential*,
# *secret* or *token* (case-insensitive), or when it is JSON whose top-level object
# has a `token` key. Only key names are inspected; no value is printed. Source and
# prose files (.swift, .py, .sh, .md) are exempt from the name patterns alone: a new
# SecretStore.swift is not a secret, and this very script matches *credential*, so
# without the exemption the gate would refuse ordinary work before its first commit.
#
# The fix for a hit is to move the file outside every checkout (for the Crashbox
# upload credentials, see docs/CRASHBOX-REPORTING.md) or, for a file that must stay
# in the tree, to add a .gitignore rule for it. Ignored files are deliberately not
# reported: an ignored file is the protected state this check is asking for.
set -euo pipefail

ROOT="${1:-}"
if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "check-untracked-credentials: not inside a git repository" >&2
    exit 2
  }
fi
cd "$ROOT" 2>/dev/null || { echo "check-untracked-credentials: no such directory: $ROOT" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "check-untracked-credentials: not a git repository: $ROOT" >&2
  exit 2
}

# Prints "token" when the file is JSON whose top-level object has a `token` key.
# Keys only: nothing from the document reaches stdout or stderr.
json_has_top_level_token() {
  python3 - "$1" <<'PY' 2>/dev/null || true
import json, os, sys
path = sys.argv[1]
try:
    if os.path.getsize(path) > 1024 * 1024:
        sys.exit(0)
    with open(path, "rb") as handle:
        document = json.load(handle)
except Exception:
    sys.exit(0)
if isinstance(document, dict) and "token" in document:
    print("token")
PY
}

candidates="$(mktemp -t baton-credential-guard)"
trap 'rm -f "$candidates"' EXIT
{
  git ls-files -z --others --exclude-standard
  git diff --cached -z --name-only --diff-filter=A 2>/dev/null || true
} >"$candidates" || { echo "check-untracked-credentials: git could not list files" >&2; exit 2; }

hits=0
while IFS= read -r -d '' path; do
  [ -n "$path" ] || continue
  name="${path##*/}"
  lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  reason=""
  case "$lower" in
    *.local.json|*.p12|*.p8) reason="name matches a credential file pattern" ;;
    *.swift|*.py|*.sh|*.md) ;;
    *credential*|*secret*|*token*) reason="name matches a credential file pattern" ;;
  esac
  if [ -z "$reason" ] && [[ "$lower" == *.json ]] && [ -f "$path" ] && [ ! -L "$path" ]; then
    if [ "$(json_has_top_level_token "$path")" = token ]; then
      reason="JSON with a top-level \"token\" key"
    fi
  fi
  if [ -n "$reason" ]; then
    if git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
      where="staged as a new file"
    else
      where="untracked and not ignored"
    fi
    echo "credential-looking file is $where: $path ($reason)" >&2
    hits=$((hits + 1))
  fi
done <"$candidates"

if [ "$hits" -gt 0 ]; then
  {
    echo "Refusing: $hits credential-looking file(s) would be taken by the next 'git add -A'."
    echo "Move each one outside every checkout (Crashbox upload credentials: see"
    echo "docs/CRASHBOX-REPORTING.md), or add a .gitignore rule if it must stay in the tree."
  } >&2
  exit 1
fi
echo "No untracked, unignored credential-looking files."
