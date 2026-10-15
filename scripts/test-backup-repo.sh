#!/bin/bash
#
# scripts/backup-repo.sh against a local bare remote. (TBX-8430)
#
# WHY THIS EXISTS. The backup was a bare `git push --all`. When this checkout's `main` sat
# behind origin/main (work had landed from a worktree), the push rejected it as
# non-fast-forward and the daily repo-backup failed every night with nothing actually
# missing. These cases pin the three answers a branch can get: pushed, already covered, or
# refused because it diverged. No network, no Xcode, about a second.
set -uo pipefail
cd "$(dirname "$0")/.."
SOURCE="$PWD/scripts/backup-repo.sh"
# backup-repo.sh is private tooling, excluded from the public mirror (publish-repo.sh).
if [ ! -f "$SOURCE" ]; then echo "skipped: scripts/backup-repo.sh is not in this tree"; exit 0; fi

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '\033[32mok    %s\033[0m\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '\033[31mFAIL  %s\033[0m\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

q() { git "$@" >/dev/null 2>&1; }

# A fresh remote, a local clone carrying the script under test, and a second clone that
# plays "another worktree pushed to main".
setup() {
  rm -rf "$WORK/remote.git" "$WORK/local" "$WORK/other"
  q init --bare "$WORK/remote.git"
  q init -b main "$WORK/local"
  q -C "$WORK/local" config user.email backup-test@example.invalid
  q -C "$WORK/local" config user.name "Backup Test"
  q -C "$WORK/local" remote add origin "$WORK/remote.git"
  echo initial > "$WORK/local/data.txt"
  q -C "$WORK/local" add data.txt
  q -C "$WORK/local" commit -m initial
  q -C "$WORK/local" push -u origin main
  mkdir -p "$WORK/local/scripts"
  cp "$SOURCE" "$WORK/local/scripts/backup-repo.sh"
  q clone -b main "$WORK/remote.git" "$WORK/other"
  q -C "$WORK/other" config user.email backup-test@example.invalid
  q -C "$WORK/other" config user.name "Backup Test"
}

commit_in() {   # $1 = clone, $2 = content
  echo "$2" > "$WORK/$1/data.txt"
  q -C "$WORK/$1" commit -am "$2"
  git -C "$WORK/$1" rev-parse HEAD
}

backup() {
  BATON_BACKUP_REMOTE=origin bash "$WORK/local/scripts/backup-repo.sh" \
    >"$WORK/out" 2>"$WORK/err"
}

remote_tip() { git -C "$WORK/local" ls-remote origin "$1" | awk '{print $1}'; }

# 1. The 2026-10-01 failure: local main behind the remote, plus a tag only local has.
#    Must succeed, leave the remote alone, and still push the tag.
setup
ahead="$(commit_in other "remote ahead")"
q -C "$WORK/other" push origin main
q -C "$WORK/local" tag behind-proof
if backup; then ok "local branch behind the remote: exit 0"; else bad "local branch behind the remote: exit $? ($(tail -2 "$WORK/err"))"; fi
grep -q 'already covered: main' "$WORK/out" && ok "reports main as already covered" || bad "no 'already covered: main' line"
[ "$(remote_tip refs/heads/main)" = "$ahead" ] && ok "remote main untouched" || bad "remote main was moved"
[ -n "$(remote_tip refs/tags/behind-proof)" ] && ok "tags still pushed when a branch is behind" || bad "tag not pushed"

# 2. Local ahead, and a branch the remote has never seen: both pushed.
setup
tip="$(commit_in local "local ahead")"
q -C "$WORK/local" branch side
if backup; then ok "local ahead: exit 0"; else bad "local ahead: exit $?"; fi
[ "$(remote_tip refs/heads/main)" = "$tip" ] && ok "local-ahead main pushed" || bad "main not pushed"
[ "$(remote_tip refs/heads/side)" = "$tip" ] && ok "new branch pushed" || bad "new branch not pushed"

# 3. Diverged: refuse, exit non-zero, never rewrite the backup.
setup
ahead="$(commit_in other "remote side")"
q -C "$WORK/other" push origin main
commit_in local "local side" >/dev/null
if backup; then bad "diverged branch: exit 0, should fail"; else ok "diverged branch: exits non-zero"; fi
grep -q 'diverged' "$WORK/err" && ok "says the branch diverged" || bad "no 'diverged' message"
[ "$(remote_tip refs/heads/main)" = "$ahead" ] && ok "remote main preserved" || bad "remote main rewritten"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
