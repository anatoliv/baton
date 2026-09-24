#!/bin/bash
# Helpers for driving a *probe* instance of the Mac app next to the owner's own Baton.
# Sourced by scripts/probe-menubar-freeze.sh and scripts/probe-handoff-e2e.sh.
#
# A probe is the shipping app launched with `-baton.defaultsSuite <name>` (TBX-5162): its
# preferences live in that suite, its files under `Application Support/Baton Probes/<name>`,
# and its Keychain secrets under `io.tonebox.secrets.probe.<name>`. Nothing here reads or
# writes the owner's `io.tonebox.baton` domain, their Application Support, their Keychain
# item, or their running app. Every UI action goes to the probe by process id, never by
# bundle identifier, because the probe and the owner's app share one.

PROBE_SUPPORT_ROOT="$HOME/Library/Application Support/Baton Probes"

# A fresh, unused suite name. Lower-case letters, digits and dashes only (BatonStorage refuses
# anything else).
probe_new_suite() {   # $1 = short label
  printf 'probe-%s-%s\n' "$1" "$(date +%s)-$RANDOM"
}

# Launch a new instance of $1 with suite $2 and print its pid. `open -n` because the owner's
# Baton may already be running under the same bundle identifier.
probe_launch() {   # $1 = Baton.app, $2 = suite
  local app="$1" suite="$2" pid="" i
  open -n -a "$app" --args -baton.defaultsSuite "$suite" || return 1
  for i in $(seq 1 40); do
    pid="$(pgrep -f -- "-baton.defaultsSuite $suite" | head -1)"
    [ -n "$pid" ] && break
    sleep 0.5
  done
  [ -n "$pid" ] || { echo "probe did not start" >&2; return 1; }
  printf '%s\n' "$pid"
}

probe_quit() {   # $1 = pid
  local pid="$1" i
  [ -n "$pid" ] || return 0
  kill -TERM "$pid" 2>/dev/null || return 0
  for i in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.25; done
  kill -KILL "$pid" 2>/dev/null || true
}

# HTTP status of an MCP `initialize` against the probe's own server, read from the probe's own
# discovery file. 200 means the main queue is being serviced; 000 means it is not (or no server).
probe_mcp_status() {   # $1 = suite
  local file="$PROBE_SUPPORT_ROOT/$1/mcp.json"
  [ -f "$file" ] || { echo "nofile"; return 0; }
  /usr/bin/python3 - "$file" <<'PY'
import json, subprocess, sys
d = json.load(open(sys.argv[1]))
cfg = 'header = "Authorization: Bearer %s"\n' % d["token"]
body = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
r = subprocess.run(["curl", "-s", "-o", "/dev/null", "-m", "4", "-K", "-", "-X", "POST", d["url"],
                    "-H", "Content-Type: application/json", "-d", body, "-w", "%{http_code}"],
                   input=cfg, capture_output=True, text=True)
print(r.stdout.strip() or "000")
PY
}

# Call one MCP tool on the probe and print the text it returned (for assertions).
probe_mcp_tool() {   # $1 = suite, $2 = tool name
  local file="$PROBE_SUPPORT_ROOT/$1/mcp.json"
  /usr/bin/python3 - "$file" "$2" <<'PY2'
import json, subprocess, sys
d = json.load(open(sys.argv[1]))
cfg = 'header = "Authorization: Bearer %s"\n' % d["token"]
def call(body, sid=None, headers=False):
    args = ["curl", "-s", "-m", "6", "-K", "-", "-X", "POST", d["url"],
            "-H", "Content-Type: application/json", "-H", "Accept: application/json, text/event-stream"]
    args += ["-D", "-"] if headers else []
    args += ["-H", "Mcp-Session-Id: " + sid] if sid else []
    args += ["-d", body]
    return subprocess.run(args, input=cfg, capture_output=True, text=True).stdout
init = call('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}', headers=True)
sid = next((l.split(":", 1)[1].strip() for l in init.splitlines() if l.lower().startswith("mcp-session-id:")), None)
body = call(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": sys.argv[2], "arguments": {}}}), sid)
try:
    print(json.loads(body)["result"]["content"][0]["text"])
except Exception:
    print(body)
PY2
}

# Sheets currently attached to the probe's windows (a SwiftUI .alert on macOS is a sheet).
probe_sheet_count() {   # $1 = pid
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $1)
    set n to 0
    repeat with w in windows
      set n to n + (count of sheets of w)
    end repeat
    return n
  end tell" 2>/dev/null || echo "error"
}

# Press a named button in any sheet of a probe window, by process id. SwiftUI alert buttons carry
# their title in AXDescription, not AXTitle, so both are checked. Prints "pressed", or a dump of
# every button's attributes so a miss says what was actually there.
probe_press_sheet_button() {   # $1 = pid, $2 = button title
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $1)
    set seen to {}
    repeat with w in windows
      repeat with s in sheets of w
        repeat with b in buttons of s
          set t to \"\"
          set d to \"\"
          try
            set t to (value of attribute \"AXTitle\" of b) as text
          end try
          try
            set d to (value of attribute \"AXDescription\" of b) as text
          end try
          set end of seen to t & \"/\" & d
          if t is \"$2\" or d is \"$2\" then
            perform action \"AXPress\" of b
            return \"pressed\"
          end if
        end repeat
      end repeat
    end repeat
    set dump to {}
    repeat with w in windows
      repeat with s in sheets of w
        repeat with b in buttons of s
          set desc to \"[\"
          repeat with a in (attributes of b)
            try
              set desc to desc & (name of a) & \"=\" & ((value of a) as text) & \"; \"
            end try
          end repeat
          try
            set desc to desc & \"kids=\" & ((value of every static text of b) as text)
          end try
          set end of dump to desc & \"]\"
        end repeat
      end repeat
    end repeat
    set AppleScript's text item delimiters to \" \"
    return \"no button $2 among: \" & (dump as text)
  end tell" 2>&1
}

# Remove everything a probe run created: its preferences suite, its files, its Keychain items.
probe_cleanup() {   # $1 = suite
  local suite="$1" service="io.tonebox.secrets.probe.$1"
  defaults delete "$suite" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$suite.plist"
  [ -n "$suite" ] && rm -rf "${PROBE_SUPPORT_ROOT:?}/$suite"
  while security delete-generic-password -s "$service" >/dev/null 2>&1; do :; done
}
