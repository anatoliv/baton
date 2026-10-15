#!/bin/zsh
# test-baton-say.sh — drive tools/baton-say against a throwaway local server that answers
# the way Baton can (TBX-9392). No Baton, no audio, about two seconds.
#
# It checks the things an HTTP 200 used to hide: a JSON-RPC error, an MCP isError result, a
# reply that says nothing about delivery, and an event stream led by an "event:" line. It
# also checks the line arrives in the request body and nowhere in the environment.

emulate -L zsh
setopt pipefail

here="${0:A:h}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home/Library/Application Support/Baton"

cat > "$work/server.py" <<'PY'
import json, sys, http.server, time
mode, out = sys.argv[1], sys.argv[2]
def ok(*delivered):
    return {"result": {"content": [{"type": "text", "text": json.dumps({"status": delivered[0], "delivered": list(delivered)})}]}}
replies = {"speaking": ok("speaking", "notified"), "queued": ok("queued"),
           "iserror": {"result": {"isError": True, "content": [{"type": "text", "text": "x"}]}},
           "rpc": {"error": {"code": -32602, "message": "x"}}, "silent": {"result": {"content": []}},
           "nonobject": {"result": {"content": [{"type": "text", "text": "null"}]}},
           "timeout": ok("speaking")}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.requests += 1
        with open(out, "w") as receipt:
            json.dump({**body["params"]["arguments"], "_requests": self.server.requests}, receipt)
        if mode == "timeout": time.sleep(1.5)
        data = json.dumps(replies[mode.removeprefix("sse-")])
        if mode.startswith("sse-"): data = "event: message\ndata: " + data + "\n\n"
        self.send_response(200); self.end_headers()
        try: self.wfile.write(data.encode())
        except BrokenPipeError: pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
s.requests = 0; s.timeout = 2
print(s.server_port, flush=True); s.handle_request()
if mode == "timeout":
    s.timeout = 0.2; s.handle_request()  # catch an inappropriate replay, with a bounded wait
s.server_close()
PY

pass=0; fail=0
check() {  # check NAME MODE WANT_RC WANT_OUTPUT [baton-say args...]
  local name=$1 mode=$2 want_rc=$3 want=$4; shift 4
  print -r -- '{}' > "$work/args.json"
  python3 "$work/server.py" $mode "$work/args.json" > "$work/ready" &
  local server=$!
  for _ in {1..50}; do [[ -s "$work/ready" ]] && break; sleep 0.05; done
  if [[ ! -s "$work/ready" ]]; then
    kill $server 2>/dev/null; wait $server 2>/dev/null
    (( fail++ )); print "FAIL  $name: fixture did not start"; return
  fi
  local port="$(<"$work/ready")"
  print -r -- "{\"url\":\"http://127.0.0.1:$port/mcp\",\"token\":\"test-only\"}" \
    > "$work/home/Library/Application Support/Baton/mcp.json"
  chmod 600 "$work/home/Library/Application Support/Baton/mcp.json"
  local got rc
  local -a verbosity=(--verbose)
  if [[ "$1" == --quiet ]]; then verbosity=(); shift; fi
  got="$(HOME="$work/home" "$here/baton-say" "${verbosity[@]}" "$@" 2>&1)"; rc=$?
  wait $server 2>/dev/null; : > "$work/ready"
  local requests="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("_requests", 0))' "$work/args.json")"
  if [[ $requests == 1 && $rc == $want_rc && (( -n "$want" && "$got" == *"$want"* ) || ( -z "$want" && -z "$got" )) ]]; then
    (( pass++ )); print "ok    $name"
  else
    (( fail++ )); print "FAIL  $name: rc=$rc output=${(qq)got}"
  fi
}

check "delivered states reported"      speaking     0 "speaking notified" "a line"
check "queued is not called speaking"  queued       0 "queued" "a line"
check "event stream with event: line"  sse-speaking 0 "speaking" "a line"
check "MCP isError is a failure"       iserror      1 "reported an error" "a line"
check "JSON-RPC error is a failure"    rpc          1 "JSON-RPC error" "a line"
check "no delivery state is a failure" silent       1 "did not say" "a line"
check "nonobject result is a failure" nonobject 1 "did not say" "a line"
check "timeout is uncertain, not delivery" timeout 1 "delivery uncertain (timed out)" --timeout 1 "a line"
check "quiet timeout remains silent" timeout 0 "" --quiet --timeout 1 "a line"
print -rn -- "secret-free stdin line" > "$work/in"
check "stdin reaches the body"         speaking     0 "speaking" --stdin < "$work/in"
if grep -q "secret-free stdin line" "$work/args.json"; then (( pass++ )); print "ok    stdin text in request body"
else (( fail++ )); print "FAIL  stdin text missing from request body"; fi
if grep -q "BATON_SAY_TEXT" "$here/baton-say"; then (( fail++ )); print "FAIL  text still passed through the environment"
else (( pass++ )); print "ok    no text environment variable"; fi

print "$pass passed, $fail failed"
(( fail == 0 ))
