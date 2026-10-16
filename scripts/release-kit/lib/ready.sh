#!/usr/bin/env bash
# ready.sh: is this machine ready to release? One list, before anything starts.
# Part of the release kit (~/Projects/_method/release-kit.md); the rule it implements is
# "the readiness check" in ~/Projects/_method/docs/standards/release.md.
#
# A release that stops one surprise at a time (a locked vault, a lock held by another run, a
# public-mirror refusal after the app already shipped) wastes the steps before each stop. A
# readiness check reads every precondition it can without changing anything and prints one
# line per item: ok, WARN (worth knowing) or FAIL (a release would stop on it).
#
# The scaffold, for a project's own scripts/release-ready.sh:
#
#   . scripts/release-kit/lib/ready.sh
#   ready_source() { rk_ready_tree "$ROOT"; rk_ready_on_main "$ROOT"; ... }
#   ready_tools()  { ... rk_ready_ok/rk_ready_warn/rk_ready_fail "label: what" ... }
#   rk_ready_run "App release readiness" "Both releases can run side by side." ready_source ready_tools
#
#   rk_ready_run TITLE READY-NOTE HOOK...   prints TITLE and the date, runs each hook (a shell
#                                           function the project defines) in order, then
#                                           READY or NOT READY. Returns 1 on any FAIL, and
#                                           FAILs a hook that is not defined.
#   rk_ready_ok|warn|fail TEXT              one line each; fail counts toward NOT READY
#   rk_ready_tree REPO                      clean, committed tree
#   rk_ready_on_main REPO [REF]             HEAD is on REF (default origin/main, last fetch)
#   rk_ready_credential_dir DIR             exists and is 0700
#   rk_ready_credential_file DIR NAME       exists, 0600, owned by this user. Never read.
#   rk_ready_vault ITEM READER              the vault answers and holds ITEM, by name only
#                                           (RK_READY_VAULT_CMD, default vault-find; its exit
#                                           3 means locked). READER says who needs it.
#   rk_ready_lock_record FILE LABEL         a lock record: free, stale or held (and by whom)
#   rk_ready_native_locks                   mac-app-host, a waiting release intent, every held
#                                           sim-* lock (needs lib/native-lock.sh, sourced
#                                           first with the project's configuration)
#
# It never prints a secret value: credentials are checked by path, owner and mode, the vault
# by whether it answers and whether the named item exists. It reads lock records and never
# takes, signals or edits a lock.

RK_READY_FAILS=0
rk_ready_ok()   { printf '  ok    %s\n' "$*"; }
rk_ready_warn() { printf '  WARN  %s\n' "$*"; }
rk_ready_fail() { RK_READY_FAILS=$((RK_READY_FAILS + 1)); printf '  FAIL  %s\n' "$*"; }

rk_ready_tree() {   # $1 = repo
  local head
  head="$(git -C "$1" rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]; then
    rk_ready_fail "tree: $1 has uncommitted changes; a release needs a clean, committed tree"
  else
    rk_ready_ok "tree: clean at ${head:0:12}"
  fi
}

rk_ready_on_main() {   # $1 = repo, $2 = ref (default origin/main)
  local ref="${2:-origin/main}"
  if git -C "$1" merge-base --is-ancestor HEAD "$ref" 2>/dev/null; then
    rk_ready_ok "source: HEAD is on $ref (as of the last fetch)"
  else
    rk_ready_fail "source: HEAD is not on $ref as of the last fetch; the main guard will refuse it"
  fi
}

rk_ready_credential_dir() {   # $1 = directory
  if [ -d "$1" ] && [ "$(stat -f %Lp "$1")" = 700 ]; then
    rk_ready_ok "credentials: $1 is 0700"
  elif [ -d "$1" ]; then
    rk_ready_fail "credentials: $1 is $(stat -f %Lp "$1"), not 0700"
  else
    rk_ready_fail "credentials: $1 does not exist"
  fi
}

rk_ready_credential_file() {   # $1 = directory, $2 = file name; mode and owner only
  local f="$1/$2"
  if [ ! -f "$f" ]; then
    rk_ready_fail "credentials: $2 is missing from $1"
  elif [ "$(stat -f %Lp "$f")" != 600 ]; then
    rk_ready_fail "credentials: $2 is mode $(stat -f %Lp "$f"), not 0600"
  elif [ "$(stat -f %Su "$f")" != "$(id -un)" ]; then
    rk_ready_fail "credentials: $2 is not owned by $(id -un)"
  else
    rk_ready_ok "credentials: $2 present, 0600"
  fi
}

# The vault command prints item names only; its output is matched here and never echoed.
rk_ready_vault() {   # $1 = item name, $2 = who reads it (for the locked message)
  local item="$1" reader="${2:-the release}" cmd="${RK_READY_VAULT_CMD:-vault-find}" out rc
  if ! command -v "$cmd" >/dev/null 2>&1; then
    rk_ready_fail "vault: $cmd is not on PATH"
    return 0
  fi
  out="$("$cmd" "$item" 2>/dev/null </dev/null)"; rc=$?
  if [ "$rc" = 3 ]; then
    rk_ready_fail "vault: locked; run secrets-unlock in a terminal tab ($reader reads \"$item\")"
  elif [ "$rc" != 0 ]; then
    rk_ready_fail "vault: $cmd failed (exit $rc)"
  elif printf '%s' "$out" | grep -qF -- "$item"; then
    rk_ready_ok "vault: unlocked, \"$item\" found"
  else
    rk_ready_fail "vault: unlocked, but no item named \"$item\""
  fi
}

# 0 when the record's first two lines name a live process with that start time.
_rk_ready_record_live() {   # $1 = record file
  local pid started
  pid="$(sed -n '1p' "$1" 2>/dev/null || true)"
  started="$(sed -n '2p' "$1" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
    && [ "$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" = "$started" ]
}

rk_ready_lock_record() {   # $1 = record file, $2 = label
  local pid kind cwd knob=NATIVE_LOCK_WAIT
  declare -F _nl_knob >/dev/null && knob="$(_nl_knob WAIT)"
  pid="$(sed -n '1p' "$1" 2>/dev/null || true)"
  kind="$(sed -n '5p' "$1" 2>/dev/null || true)"
  cwd="$(sed -n '3p' "$1" 2>/dev/null || true)"
  if [ -z "$pid" ]; then
    rk_ready_ok "$2: free (no owner recorded)"
  elif _rk_ready_record_live "$1"; then
    rk_ready_warn "$2: held by ${kind:-unknown} pid $pid from ${cwd:-unknown}; a release waits for it ($knob)"
  else
    rk_ready_ok "$2: free (stale record of pid $pid, cleared by the next owner)"
  fi
}

rk_ready_native_locks() {
  local intent f
  if ! declare -F native_lock_path >/dev/null; then
    rk_ready_fail "locks: lib/native-lock.sh is not loaded, so no lock could be read"
    return 0
  fi
  rk_ready_lock_record "$(native_lock_path mac-app-host)" "gate lock (mac-app-host)"
  intent="$(native_lock_intent_path mac-app-host)"
  if [ -s "$intent" ] && _rk_ready_record_live "$intent"; then
    rk_ready_warn "gate lock: release pid $(sed -n '1p' "$intent") from $(sed -n '3p' "$intent") is already waiting for it"
  fi
  for f in "$NATIVE_LOCK_DIR"/sim-*.lock; do
    [ -e "$f" ] || continue
    if _rk_ready_record_live "$f"; then rk_ready_lock_record "$f" "$(basename "$f" .lock)"; fi
  done
}

rk_ready_run() {   # $1 = title, $2 = note when ready, rest = hook functions in order
  local title="$1" note="$2" hook
  shift 2
  RK_READY_FAILS=0
  echo "$title, $(date '+%Y-%m-%d %H:%M %Z')"
  for hook in "$@"; do
    if declare -F "$hook" >/dev/null; then
      "$hook"
    else
      rk_ready_fail "readiness: the hook $hook is not defined, so its checks did not run"
    fi
  done
  echo
  if [ "$RK_READY_FAILS" -gt 0 ]; then
    echo "NOT READY: $RK_READY_FAILS item(s) above would stop a release."
    return 1
  fi
  echo "READY: nothing above would stop a release.${note:+ $note}"
}
