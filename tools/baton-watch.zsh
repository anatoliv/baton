# Baton terminal watch mode — speak when a long command finishes.
#
# Opt-in. Add this to ~/.zshrc:
#
#     source /path/to/baton/tools/baton-watch.zsh
#
# and remove that line to uninstall. Nothing here edits your shell configuration for you.
#
# Why a shell hook rather than something watching the terminal: Baton never watches your
# screen. The terminal pushes when it has something to say, which is also the only way to
# catch commands you typed by hand rather than ones an agent ran.
#
# Settings:
#   BATON_WATCH_THRESHOLD   seconds a command must run before it is worth speaking (default 60)
#   BATON_WATCH_LINES       how many trailing lines of a failure to read (default 3)
#   BATON_WATCH_SAY         path to baton-say (default: alongside this file)
#   BATON_WATCH_IGNORE      commands never announced (default: editors, pagers, shells)

# EPOCHSECONDS lives in zsh/datetime, which is NOT loaded by default. Without this the
# elapsed-time arithmetic silently evaluates to nothing and the hook never fires — a failure
# with no error message anywhere, which is the worst kind.
zmodload -i zsh/datetime

: ${BATON_WATCH_THRESHOLD:=60}
: ${BATON_WATCH_LINES:=3}
: ${BATON_WATCH_SAY:="${0:A:h}/baton-say"}
: ${BATON_WATCH_IGNORE:="vim vi nvim emacs nano less more man ssh top htop watch zsh bash tmux claude"}

autoload -Uz add-zsh-hook

_baton_watch_preexec() {
  _BATON_WATCH_CMD="$1"
  _BATON_WATCH_START=$EPOCHSECONDS
}

_baton_watch_precmd() {
  # Capture the exit status FIRST: anything else run here overwrites it.
  local last_status=$?
  [[ -z "$_BATON_WATCH_START" ]] && return
  local elapsed=$(( EPOCHSECONDS - _BATON_WATCH_START ))
  local cmd="$_BATON_WATCH_CMD"
  unset _BATON_WATCH_START _BATON_WATCH_CMD

  (( elapsed < BATON_WATCH_THRESHOLD )) && return
  [[ -x "$BATON_WATCH_SAY" ]] || return

  # Interactive programs are long-running by nature; announcing that you closed your editor
  # after twenty minutes is noise, not news.
  local head_word="${${(z)cmd}[1]}"
  [[ " $BATON_WATCH_IGNORE " == *" $head_word "* ]] && return

  # Speak enough of the command to recognise it. The head word alone turns "swift build" into
  # "swift", which is not what you were waiting for; the whole line could be a paragraph.
  local spoken_cmd="$cmd"
  if (( ${#spoken_cmd} > 40 )); then
    spoken_cmd="${spoken_cmd[1,40]}…"
  fi

  local minutes=$(( elapsed / 60 ))
  local duration
  if (( minutes >= 1 )); then
    duration="$minutes minute$( (( minutes == 1 )) || print -n s )"
  else
    duration="$elapsed seconds"
  fi

  local line
  if (( last_status == 0 )); then
    line="$spoken_cmd finished after $duration."
  else
    line="$spoken_cmd failed after $duration, exit status $last_status."
  fi

  # Background, detached, and never blocking the prompt. baton-say has its own hard timeout
  # and exits quietly when Baton is not running.
  ( "$BATON_WATCH_SAY" --session "shell" --category "ops" --prepare terminal "$line" & ) >/dev/null 2>&1
}

add-zsh-hook preexec _baton_watch_preexec
add-zsh-hook precmd _baton_watch_precmd

# Speak the tail of the last command's output on demand — for when a failure scrolled past.
#   $ some-build 2>&1 | tee /tmp/out; baton-tail /tmp/out
baton-tail() {
  local file="${1:-/dev/stdin}"
  tail -n "${BATON_WATCH_LINES}" "$file" | "$BATON_WATCH_SAY" --stdin --session shell --category alert
}
