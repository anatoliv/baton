#!/bin/bash
#
# Named locks for native resources that projects on this Mac share. (TBX-11003)
#
# Source this file from bash (3.2 is enough). Each resource has its own lock, so a run
# holds only what it actually uses, and only for the step that uses it:
#
#   mac-app-host          an app-hosted Mac XCTest run of Baton.app, and the reaping of a
#                         leftover test host. Kept at ${BATON_GATE_LOCK:-/tmp/baton-gate.lock}
#                         with its five-line record, because Tonebox's hosted-test controller
#                         reads that exact file.
#   sim-<UDID>            one simulator device
#   physical-iphone       the owner's iPhone, its installs and Mirroring
#   screen-input          the frontmost app, keyboard, mouse and screen
#   derived-data-<hex12>  one writer for one DerivedData directory (native_lock_derived_name)
#
# Everything except mac-app-host lives in $NATIVE_LOCK_DIR (default /tmp/native-locks; when a
# caller points BATON_GATE_LOCK somewhere else, the directory beside it, so a test that moves
# one lock can never touch the real others).
#
#   native_lock_acquire NAME KIND DERIVED   0 once held; 1 after a refusal, timeout or interrupt
#   native_lock_release NAME                release one lock this shell holds
#   native_lock_release_all                 release everything, and withdraw any release intent
#   native_lock_inherit NAME                0 when this script's direct parent is a live
#                                           release that owns NAME and exported it to us
#
# OWNERSHIP. The kernel lock is a BSD flock-style lock on the file (the kind `lockf -k` takes,
# so older scripts that run under `lockf -k` and this helper exclude each other). The acquiring
# shell starts a small holder process (this file run as a script) in the background. The
# holder opens the file on its own descriptor, locks that descriptor with `lockf -t 0 FD`, and
# keeps it. It writes the record naming the acquiring shell (its real pid, even in a subshell)
# and then watches it.
#
#   * Only the owner releases: it drops a release marker and sends USR1, after checking the
#     holder's pid and start time. The holder ignores INT, QUIT, HUP and TERM, so a signal sent
#     to the whole process group (a timeout, a tree kill, a terminal closing) leaves the lock
#     with its owner. Measured 2026-10-16: after group INT, QUIT, HUP or TERM to an owner that
#     traps them, a contender is still refused.
#   * The owner's death, even by SIGKILL, ends the holder within about 0.2 s, which frees the
#     kernel lock. Its record stays behind and the next owner reports it as stale.
#   * If the holder alone is SIGKILLed, the kernel lock is free but the record still names a
#     live owner, so every contender treats the resource as busy; the owner's own release
#     then clears the record.
#
# Children of the owner never get the locked descriptor; the holder closes it for its own.
# Record, one field per line: owner pid, owner start time (`ps -o lstart=`), working
# directory at acquisition, derived-data path, owner kind. The pid and start time together
# identify a live owner even after pid reuse.
#
# WAITING. BATON_GATE_LOCK_WAIT seconds (default 3600) bounds the wait; the holder is printed
# once and again only when it changes. BATON_GATE_LOCK_WAIT=0 refuses at once, as the gate
# always did, with the same message. NATIVE_LOCK_POLL sets the waiter's poll (default 1 s).
#
# RELEASE PRIORITY. A release (kind release, or BATON_GATE_LOCK_PRIORITY=release) that has to
# wait writes $NATIVE_LOCK_DIR/<name>.release-intent with the same five-line record. Any other
# acquisition of that resource waits while the intent's owner is alive, and an intent whose
# owner has died or whose pid was reused is removed by whoever reads it. Releases do not
# yield to each other. A release's direct child inherits the parent's mac-app-host lock
# before any intent is consulted, so priority cannot deadlock a release against its own gate.
#
# ORDER. Acquire in this order and never hold a later lock while waiting for an earlier one:
# a release's own derived data, mac-app-host, sim-<UDID>, then test derived data. Every
# Baton caller takes one step's locks and releases them before the next step.
#
# OLDER SCRIPTS. A checkout from before TBX-11003 holds /tmp/baton-gate.lock for its whole run,
# under `lockf -k`, and takes nothing else. While such a run is alive (its recorded pid is a
# live child of lockf), every resource here is treated as held by it, as before.

NATIVE_LOCK_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
if [ -z "${NATIVE_LOCK_DIR:-}" ]; then
  if [ -n "${BATON_GATE_LOCK:-}" ]; then
    NATIVE_LOCK_DIR="$(dirname "$BATON_GATE_LOCK")/native-locks"
  else
    NATIVE_LOCK_DIR=/tmp/native-locks
  fi
fi
NL_HELD_NAMES=""
NL_OWN_INTENTS=""

_nl_red() {
  if declare -F red >/dev/null; then red "$@"; else printf '%s\n' "$*" >&2; fi
}
_nl_yellow() {
  if declare -F yellow >/dev/null; then yellow "$@"; else printf '%s\n' "$*" >&2; fi
}

# `ps -o lstart=` comes from the kernel. Pairing it with the pid distinguishes a live owner
# from a later process that happens to reuse the same pid.
native_lock_start() {   # $1 = pid
  ps -o lstart= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

native_lock_path() {   # $1 = resource name
  case "$1" in
    mac-app-host) printf '%s\n' "${BATON_GATE_LOCK:-/tmp/baton-gate.lock}" ;;
    *) printf '%s/%s.lock\n' "$NATIVE_LOCK_DIR" "$1" ;;
  esac
}

native_lock_intent_path() {   # $1 = resource name
  printf '%s/%s.release-intent\n' "$NATIVE_LOCK_DIR" "$1"
}

# One lock per DerivedData directory, named by a digest of its physical path so that
# /tmp/x and /private/tmp/x are the same writer.
native_lock_derived_name() {   # $1 = derived-data path
  local path="$1" parent
  if parent="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)"; then
    path="$parent/$(basename "$path")"
  fi
  printf 'derived-data-%s\n' "$(printf '%s' "$path" | shasum -a 256 | cut -c1-12)"
}

_nl_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }

# The real pid of the calling shell, a subshell included ($$ names the parent there, and
# bash 3.2 has no BASHPID). A direct child reports its parent. Sets NL_SELF.
NL_SELF=""
_nl_set_self() {
  local f
  f="$(mktemp -t native-lock-self.XXXXXX)" || { NL_SELF="$$"; return 0; }
  # shellcheck disable=SC2016 # $PPID is the child's to expand
  sh -c 'echo "$PPID"' >"$f"
  read -r NL_SELF <"$f" || NL_SELF="$$"
  rm -f "$f"
}

# A live run of an older Baton script holds every resource for its whole run (see OLDER
# SCRIPTS above). 0 when one does and it is not one of our own ancestors.
_nl_legacy_holder() {
  local file pid parent comm p _
  file="$(native_lock_path mac-app-host)"
  _nl_record_live "$file" || return 1
  pid="$(sed -n '1p' "$file" 2>/dev/null || true)"
  parent="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  [ -n "$parent" ] || return 1
  comm="$(ps -o comm= -p "$parent" 2>/dev/null)"
  case "$comm" in lockf|*/lockf) ;; *) return 1 ;; esac
  p="${NL_SELF:-$$}"
  for _ in $(seq 1 64); do
    [ "$p" = "$pid" ] && return 1
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    [ -n "$p" ] && [ "$p" -gt 1 ] || break
  done
  return 0
}

# Sleep so that a signal the caller traps ends the wait. A foreground `sleep` defers the
# trap until it finishes, and a trap that does not exit (test.sh's and publish.sh's release
# their locks and carry on) would then send a waiting run round the loop again; `wait`
# returns as soon as a trapped signal arrives. Nonzero when interrupted.
_nl_sleep() {   # $1 = seconds
  local pid rc=0
  sleep "$1" &
  pid=$!
  wait "$pid" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ]; then
    kill "$pid" 2>/dev/null || true
    return 1
  fi
  return 0
}

_nl_valid_name() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) _nl_red "✗ native lock: invalid resource name '$1'"; return 1 ;;
  esac
}

# 0 when the record's first two lines name a live process with that start time.
_nl_record_live() {   # $1 = record file
  local pid started
  pid="$(sed -n '1p' "$1" 2>/dev/null || true)"
  started="$(sed -n '2p' "$1" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
    && [ "$(native_lock_start "$pid")" = "$started" ]
}

_nl_list_add() {   # $1 = list variable, $2 = word
  local current="${!1:-}"
  case " $current " in *" $2 "*) return 0 ;; esac
  printf -v "$1" '%s' "${current:+$current }$2"
}

_nl_list_remove() {   # $1 = list variable, $2 = word
  local word out=""
  for word in ${!1:-}; do
    [ "$word" = "$2" ] || out="${out:+$out }$word"
  done
  printf -v "$1" '%s' "$out"
}

# --- Release intent ---------------------------------------------------------------------

# 0 when another live process holds a release intent for this resource. A dead or reused
# owner's intent is removed here, by whoever reads it first.
_nl_intent_blocks() {   # $1 = name, $2 = our owner pid
  local intent pid content moved
  intent="$(native_lock_intent_path "$1")"
  [ -s "$intent" ] || return 1
  pid="$(sed -n '1p' "$intent" 2>/dev/null || true)"
  [ "$pid" != "$2" ] || return 1
  if _nl_record_live "$intent"; then
    return 0
  fi
  # Move it aside before removing it, and put it back if a release replaced it in the
  # meantime, so a fresh intent is never deleted as somebody else's stale one.
  content="$(cat "$intent" 2>/dev/null || true)"
  moved="$intent.stale.$2"
  mv -f "$intent" "$moved" 2>/dev/null || return 1
  if [ "$(cat "$moved" 2>/dev/null || true)" = "$content" ]; then
    rm -f "$moved"
    _nl_yellow "  clearing a stale release intent (recorded pid ${pid:-unknown}): $intent"
  else
    [ -e "$intent" ] || mv -f "$moved" "$intent" 2>/dev/null || true
    rm -f "$moved"
  fi
  return 1
}

# Record (or keep) this release's intent. Another live release's intent is left alone:
# releases compete as equals, and either intent holds ordinary runs back.
_nl_intent_ensure() {   # $1 = name, $2 = kind, $3 = derived
  local intent tmp pid self="${NL_SELF:-$$}"
  intent="$(native_lock_intent_path "$1")"
  pid="$(sed -n '1p' "$intent" 2>/dev/null || true)"
  if [ "$pid" = "$self" ]; then return 0; fi
  if [ -n "$pid" ] && _nl_record_live "$intent"; then return 0; fi
  mkdir -p "$NATIVE_LOCK_DIR" 2>/dev/null || true
  tmp="$intent.$self"
  printf '%s\n%s\n%s\n%s\n%s\n' "$self" "$(native_lock_start "$self")" "$PWD" "$3" "$2" >"$tmp" 2>/dev/null \
    && mv -f "$tmp" "$intent" 2>/dev/null \
    && _nl_list_add NL_OWN_INTENTS "$1"
  return 0
}

_nl_intent_withdraw() {   # $1 = name
  local intent
  intent="$(native_lock_intent_path "$1")"
  if [ "$(sed -n '1p' "$intent" 2>/dev/null || true)" = "${NL_SELF:-$$}" ]; then
    rm -f "$intent"
  fi
  _nl_list_remove NL_OWN_INTENTS "$1"
}

# --- Messages ---------------------------------------------------------------------------

# The refusal for mac-app-host keeps the gate's original wording word for word: tests and
# Tonebox's controller may read it.
native_lock_refusal() {   # $1 = name, $2 = record file to describe (default: the lock)
  local name="$1" source="${2:-}" pid started cwd derived kind
  [ -n "$source" ] || source="$(native_lock_path "$name")"
  pid="$(sed -n '1p' "$source" 2>/dev/null || true)"
  started="$(sed -n '2p' "$source" 2>/dev/null || true)"
  cwd="$(sed -n '3p' "$source" 2>/dev/null || true)"
  derived="$(sed -n '4p' "$source" 2>/dev/null || true)"
  kind="$(sed -n '5p' "$source" 2>/dev/null || true)"
  if [ "$name" = mac-app-host ]; then
    kind="${kind:-gate or release}"
    _nl_red "✗ another Baton $kind is running (pid ${pid:-unknown}, started ${started:-unknown}, ${cwd:-unknown})"
    _nl_red "  Its derived data: ${derived:-unknown}"
    _nl_red "  Baton gates and releases app-host the same Baton.app. Starting or reaping a"
    _nl_red "  second copy makes the other run report a runner death against an unrelated test."
    _nl_red "  This run stopped before it could share derived data or kill that host. (TBX-5291)"
    _nl_red "  Wait for it, or stop it, then run again. BATON_ALLOW_CONCURRENT_GATE=1 overrides."
  else
    _nl_red "✗ another ${kind:-run} holds $name (pid ${pid:-unknown}, started ${started:-unknown}, ${cwd:-unknown})"
    _nl_red "  Its derived data: ${derived:-unknown}"
    _nl_red "  Wait for it, or set BATON_GATE_LOCK_WAIT to wait longer, then run again."
  fi
}

# --- The holder (this file run as a script) ---------------------------------------------

_nl_mark() {   # state, holder pid, stale pid, holder start
  printf '%s\n%s\n%s\n%s\n' "$1" "${2:-}" "${3:-}" "${4:-}" >"$NL_MARKER.tmp" \
    && mv -f "$NL_MARKER.tmp" "$NL_MARKER"
}

# ps and sed without the locked descriptor, so no helper process ever holds the lock.
_nl_start_nofd() {   # $1 = pid
  { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; } 9>&-
}

_nl_serve() {
  # Only the owner releases (USR1 plus the release marker). Interrupts, hangups and TERM sent
  # to the owner's whole process group are the owner's to handle: Tonebox's controller traps
  # them and keeps custody, so the holder must not drop the lock underneath it.
  trap '' HUP INT QUIT TERM
  local prev_pid prev_start stale="" released=0 n=0 nap="" usr1=0
  trap 'usr1=1' USR1
  exec 9>>"$NL_FILE" || { _nl_mark locked; return 0; }
  if ! /usr/bin/lockf -s -t 0 9 9>&9; then
    _nl_mark locked
    return 0
  fi
  prev_pid="$(sed -n '1p' "$NL_FILE" 2>/dev/null || true)"
  prev_start="$(sed -n '2p' "$NL_FILE" 2>/dev/null || true)"
  # A live owner named in the record without the kernel lock: a gate from a checkout with
  # the older pidfile guard, or an owner whose holder was killed underneath it. Either way it
  # still believes it owns the resource, so this is busy, not stale.
  if [ -n "$prev_pid" ] && [ "$prev_pid" != "$NL_OWNER_PID" ] \
     && kill -0 "$prev_pid" 2>/dev/null \
     && [ "$(_nl_start_nofd "$prev_pid")" = "$prev_start" ]; then
    _nl_mark busy
    return 0
  fi
  # Checked again under the kernel lock, so an ordinary run that slipped in just as a
  # release registered its intent steps back instead of overtaking it.
  if [ "$NL_PRIORITY" != release ] && _nl_intent_blocks "$NL_NAME" "$NL_OWNER_PID" >/dev/null 2>&1 9>&-; then
    _nl_mark yield
    return 0
  fi
  if [ -n "$prev_pid" ] && [ "$prev_pid" != "$NL_OWNER_PID" ]; then
    stale="$prev_pid"
  fi
  # Truncate in place: every contender must lock this same inode.
  printf '%s\n%s\n%s\n%s\n%s\n' \
    "$NL_OWNER_PID" "$NL_OWNER_START" "$NL_CWD" "$NL_DERIVED" "$NL_KIND" >"$NL_FILE"
  _nl_mark active "$$" "$stale" "$(_nl_start_nofd $$)"
  while [ "$released" = 0 ]; do
    if [ "$usr1" = 1 ]; then
      usr1=0
      if [ -e "$NL_MARKER.release" ]; then released=1; break; fi
    fi
    kill -0 "$NL_OWNER_PID" 2>/dev/null || break
    n=$((n + 1))
    if [ $((n % 25)) = 0 ] && [ "$(_nl_start_nofd "$NL_OWNER_PID")" != "$NL_OWNER_START" ]; then
      break
    fi
    sleep 0.2 9>&- &
    nap=$!
    wait "$nap" 2>/dev/null || true
  done
  [ -z "$nap" ] || kill "$nap" 2>/dev/null || true
  # An owner that died leaves its record for the next acquirer to report as stale.
  if [ "$released" = 1 ] && [ "$(sed -n '1p' "$NL_FILE" 2>/dev/null)" = "$NL_OWNER_PID" ]; then
    : >"$NL_FILE"
  fi
  return 0
}

# One non-blocking try. 0 = held; 1 = kernel lock busy; 2 = a live owner without the kernel
# lock; 3 = yielded to a release intent.
_nl_attempt() {   # name kind derived priority
  local name="$1" file marker pid state holder stale hstart key
  file="$(native_lock_path "$name")"
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  marker="$(mktemp -t native-lock.XXXXXX)" || return 1
  printf 'waiting\n' >"$marker"
  NATIVE_LOCK_SERVE=1 NL_NAME="$name" NL_FILE="$file" NL_MARKER="$marker" \
    NL_OWNER_PID="$NL_SELF" NL_OWNER_START="$(native_lock_start "$NL_SELF")" NL_CWD="$PWD" \
    NL_DERIVED="$3" NL_KIND="$2" NL_PRIORITY="$4" NATIVE_LOCK_DIR="$NATIVE_LOCK_DIR" \
    /bin/bash "$NATIVE_LOCK_SH" </dev/null >/dev/null 2>&1 &
  pid=$!
  while :; do
    state="$(sed -n '1p' "$marker" 2>/dev/null || true)"
    case "$state" in active|busy|yield|locked) break ;; esac
    if ! kill -0 "$pid" 2>/dev/null; then
      state="$(sed -n '1p' "$marker" 2>/dev/null || true)"
      break
    fi
    sleep 0.01
  done
  if [ "$state" = active ]; then
    holder="$(sed -n '2p' "$marker" 2>/dev/null || true)"
    stale="$(sed -n '3p' "$marker" 2>/dev/null || true)"
    hstart="$(sed -n '4p' "$marker" 2>/dev/null || true)"
    key="$(_nl_key "$name")"
    # pid, marker, then the holder's start time (which may contain spaces) last.
    printf -v "NL_HELD_$key" '%s %s %s' "$holder" "$marker" "$hstart"
    _nl_list_add NL_HELD_NAMES "$name"
    if [ -n "$stale" ]; then
      if [ "$name" = mac-app-host ]; then
        _nl_yellow "  clearing a stale gate lock (recorded pid $stale): $file"
      else
        _nl_yellow "  clearing a stale $name lock (recorded pid $stale): $file"
      fi
    fi
    return 0
  fi
  wait "$pid" 2>/dev/null || true
  rm -f "$marker" "$marker.tmp"
  case "$state" in
    busy) return 2 ;;
    yield) return 3 ;;
    *) return 1 ;;
  esac
}

# --- Public API -------------------------------------------------------------------------

native_lock_held() {   # $1 = name
  local var
  var="NL_HELD_$(_nl_key "$1")"
  [ -n "${!var:-}" ]
}

native_lock_acquire() {   # $1 = name, $2 = owner kind, $3 = derived-data path
  local name="${1:-}" kind="${2:-gate}" derived="${3:-unknown}"
  local wait_s="${BATON_GATE_LOCK_WAIT:-3600}" poll="${NATIVE_LOCK_POLL:-1}"
  local priority=normal rc file source started now last="" id pid cwd hkind
  local grace_until="" announced=0
  _nl_valid_name "$name" || return 1
  case "$wait_s" in
    ''|*[!0-9]*) _nl_red "✗ BATON_GATE_LOCK_WAIT must be whole seconds (got '$wait_s')"; return 1 ;;
  esac
  if [ "$kind" = release ] || [ "${BATON_GATE_LOCK_PRIORITY:-}" = release ]; then
    priority=release
  fi
  native_lock_held "$name" && return 0
  _nl_set_self
  file="$(native_lock_path "$name")"
  started="$(date +%s)"

  # Test-only barrier for the deterministic two-contender proof. Both contenders stop
  # here, then the harness releases them into lockf together against the same inode.
  if [ -n "${BATON_GATE_LOCK_TEST_BARRIER:-}" ]; then
    : >"${BATON_GATE_LOCK_TEST_BARRIER}.ready.$$"
    while [ ! -e "${BATON_GATE_LOCK_TEST_BARRIER}.go" ]; do sleep 0.01; done
  fi

  while :; do
    if [ "$name" != mac-app-host ] && _nl_legacy_holder; then
      rc=4
    elif [ "$priority" != release ] && _nl_intent_blocks "$name" "$NL_SELF"; then
      rc=3
    else
      rc=0
      _nl_attempt "$name" "$kind" "$derived" "$priority" || rc=$?
      if [ "$rc" = 0 ]; then
        _nl_intent_withdraw "$name"
        if [ "$announced" = 1 ]; then
          _nl_yellow "  $name is free after $(( $(date +%s) - started ))s; continuing"
        fi
        return 0
      fi
    fi
    case "$rc" in
      3) source="$(native_lock_intent_path "$name")" ;;
      4) source="$(native_lock_path mac-app-host)" ;;
      *) source="$file" ;;
    esac

    # The kernel lock is held but its record names nobody alive: the holder is on its
    # way out, or the winner has not written its record yet. Give that a bounded moment
    # so a refusal names the actual owner rather than a ghost.
    if [ "$rc" = 1 ] && ! _nl_record_live "$file"; then
      now="$(date +%s)"
      [ -n "$grace_until" ] || grace_until=$((now + 2))
      if [ "$now" -lt "$grace_until" ]; then
        if ! _nl_sleep 0.05; then
          _nl_red "✗ interrupted while waiting for $name"
          _nl_intent_withdraw "$name"
          return 1
        fi
        continue
      fi
    fi

    if [ "$wait_s" = 0 ]; then
      native_lock_refusal "$name" "$source"
      return 1
    fi
    if [ "$priority" = release ]; then
      _nl_intent_ensure "$name" "$kind" "$derived"
    fi
    now="$(date +%s)"
    if [ $((now - started)) -ge "$wait_s" ]; then
      _nl_red "✗ gave up after waiting ${wait_s}s for $name (BATON_GATE_LOCK_WAIT)"
      native_lock_refusal "$name" "$source"
      _nl_intent_withdraw "$name"
      return 1
    fi
    pid="$(sed -n '1p' "$source" 2>/dev/null || true)"
    id="$pid $(sed -n '2p' "$source" 2>/dev/null || true)"
    if [ "$id" != "$last" ]; then
      last="$id"
      cwd="$(sed -n '3p' "$source" 2>/dev/null || true)"
      hkind="$(sed -n '5p' "$source" 2>/dev/null || true)"
      if [ "$rc" = 3 ]; then
        _nl_yellow "  waiting for release pid ${pid:-unknown} from ${cwd:-unknown} (release priority on $name, up to ${wait_s}s)"
      elif [ "$rc" = 4 ]; then
        _nl_yellow "  waiting for ${hkind:-unknown} pid ${pid:-unknown} from ${cwd:-unknown} (an older Baton script holds every resource for its whole run; $name, up to ${wait_s}s)"
      else
        _nl_yellow "  waiting for ${hkind:-unknown} pid ${pid:-unknown} from ${cwd:-unknown} ($name, up to ${wait_s}s)"
      fi
      announced=1
    fi
    # An interrupt or TERM ends the wait: it must stop a queued run, not be absorbed by a
    # caller's trap and send it round the loop again.
    if ! _nl_sleep "$poll"; then
      _nl_red "✗ interrupted while waiting for $name"
      _nl_intent_withdraw "$name"
      return 1
    fi
  done
}

native_lock_release() {   # $1 = name
  local name="$1" var held holder marker hstart file _
  var="NL_HELD_$(_nl_key "$name")"
  held="${!var:-}"
  _nl_intent_withdraw "$name"
  [ -n "$held" ] || return 0
  holder="${held%% *}"
  marker="${held#* }"; marker="${marker%% *}"
  hstart="${held#* * }"
  file="$(native_lock_path "$name")"
  # Signal only the holder this shell started: same pid AND same start time.
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null \
     && [ "$(native_lock_start "$holder")" = "$hstart" ]; then
    : >"$marker.release"
    kill -USR1 "$holder" 2>/dev/null || true
    # The holder is our child when this shell acquired it; otherwise look at it directly.
    if ! wait "$holder" 2>/dev/null; then
      for _ in $(seq 1 50); do
        kill -0 "$holder" 2>/dev/null || break
        sleep 0.1
      done
    fi
  else
    # The holder was killed underneath us. The kernel lock is already free, and a live
    # record naming us would hold everyone else back until we exit; clear it now.
    wait "$holder" 2>/dev/null || true
    if [ "$(sed -n '1p' "$file" 2>/dev/null || true)" = "${NL_SELF:-$$}" ]; then
      : >"$file"
    fi
  fi
  rm -f "$marker" "$marker.tmp" "$marker.release"
  printf -v "$var" '%s' ""
  _nl_list_remove NL_HELD_NAMES "$name"
  return 0
}

native_lock_release_all() {
  local name
  for name in $NL_HELD_NAMES; do native_lock_release "$name"; done
  for name in $NL_OWN_INTENTS; do _nl_intent_withdraw "$name"; done
  return 0
}

# A release invokes test.sh directly while retaining ownership. Only that direct,
# still-live parent may be inherited; an environment flag alone would be spoofable and a
# pid alone would be vulnerable to reuse. Consulted before any release intent.
native_lock_inherit() {   # $1 = name
  local file pid started kind
  file="$(native_lock_path "$1")"
  pid="$(sed -n '1p' "$file" 2>/dev/null || true)"
  [ -n "$pid" ] && [ "$pid" = "$PPID" ] || return 1
  started="$(sed -n '2p' "$file" 2>/dev/null || true)"
  # Some constrained shells deny ps even for their own process. In that case both reads
  # are empty, and the direct-parent requirement still makes inheritance safe.
  [ "$(native_lock_start "$pid")" = "$started" ] || return 1
  kind="$(sed -n '5p' "$file" 2>/dev/null || true)"
  [ "$kind" = release ] || return 1
  [ "${BATON_GATE_LOCK_ACTIVE_OWNER_PID:-}" = "$pid" ] || return 1
  return 0
}

if [ "${NATIVE_LOCK_SERVE:-}" = 1 ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _nl_serve
  exit 0
fi
