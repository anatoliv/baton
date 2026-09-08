#!/usr/bin/env bash
# Select Crashbox, or reporting-disabled, for one build. Prints only the mode;
# the DSN is written to the caller's mode-0600 temporary xcconfig and never
# echoed. No hosted-provider input is read or accepted.
set -euo pipefail

[ "$#" -eq 2 ] || { echo "usage: $0 <app-or-ios-dir> <output-xcconfig>" >&2; exit 64; }
ROOT="$1"
OUTPUT="$2"
CONFIG="$ROOT/Config"
CRASHBOX_FILE="$CONFIG/Crashbox.local.xcconfig"

die() { echo "crash reporting configuration refused: $*" >&2; exit 1; }

check_private() {
  local file="$1" mode numeric owner
  [ -f "$file" ] || return 0
  [ ! -L "$file" ] || die "protected input must not be a symbolic link"
  mode="$(stat -f '%Lp' "$file" 2>/dev/null)" || die "cannot inspect protected input permissions"
  owner="$(stat -f '%u' "$file" 2>/dev/null)" || die "cannot inspect protected input owner"
  [ "$owner" = "$(id -u)" ] || die "protected input must be owned by the invoking user"
  case "$mode" in (*[!0-7]*|'') die "cannot inspect protected input permissions";; esac
  numeric=$((8#$mode))
  (( (numeric & 077) == 0 )) || die "protected input must not grant group or other access"
}

read_one() {
  local file="$1" primary="$2" count value unknown
  [ -f "$file" ] || return 0
  check_private "$file"
  count="$(awk -v key="$primary" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { n += 1 }
    END { print n + 0 }
  ' "$file")"
  [ "$count" -le 1 ] || die "duplicate protected input setting"
  unknown="$(awk -v key="$primary" '
    /^[[:space:]]*(\/\/|#|$)/ { next }
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ {
      name = $0
      sub(/^[[:space:]]*/, "", name)
      sub(/[[:space:]]*=.*/, "", name)
      if (name != key) print name
    }
  ' "$file")"
  [ -z "$unknown" ] || die "protected input contains an unsupported setting"
  value="$(awk -v key="$primary" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "")
      sub("[[:space:]]*$", "")
      print
    }
  ' "$file")"

  printf '%s' "$value"
}

valid_dsn() {
  local value="$1"
  # Schemeless is mandatory because `//` starts an xcconfig comment. The
  # runtime adds HTTPS and independently parses the same constrained shape.
  [[ "$value" =~ ^[A-Za-z0-9._~-]+@[A-Za-z0-9.-]+(:[0-9]{1,5})?/[A-Za-z0-9._~/-]+$ ]]
}

crashbox="$(read_one "$CRASHBOX_FILE" CRASHBOX_DSN)"

[ -z "$crashbox" ] || valid_dsn "$crashbox" || die "Crashbox DSN has an unsafe or malformed shape"

provider="disabled"
dsn=""
if [ -n "$crashbox" ]; then
  provider="crashbox"
  dsn="$crashbox"
fi

umask 077
temporary="${OUTPUT}.tmp.$$"
trap 'rm -f "$temporary"' EXIT HUP INT TERM
{
  if [ "$provider" = disabled ]; then
    printf 'CRASH_REPORTING_DSN =\n'
    printf 'CRASH_REPORTING_PROVIDER =\n'
    printf 'CRASH_REPORTING_ENVIRONMENT =\n'
  else
    printf 'CRASH_REPORTING_DSN = %s\n' "$dsn"
    printf 'CRASH_REPORTING_PROVIDER = %s\n' "$provider"
    printf 'CRASH_REPORTING_ENVIRONMENT = production\n'
  fi
} > "$temporary"
chmod 600 "$temporary"
mv -f "$temporary" "$OUTPUT"
trap - EXIT HUP INT TERM
printf '%s\n' "$provider"
