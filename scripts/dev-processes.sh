#!/usr/bin/env bash
# Helpers for replacing this checkout's own development process.
baton_stop_executable() {
    local executable="$1" pid files
    # Name narrows the inventory; the exact loaded executable authorizes termination.
    # A failed metadata lookup never authorizes a kill. lsof fields preserve spaces.
    while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        files="$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null)" || continue
        if printf '%s\n' "$files" | grep -Fxq "n$executable"; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done < <(pgrep -x Baton 2>/dev/null || true)
}
