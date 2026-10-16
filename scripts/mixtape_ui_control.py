"""Preparation-only seam for synthetic mixtape UI fixtures.

The future owned controller calls serve_one on its original thread while waiting
for XCTest. This module never creates a child, obtains a guard, reads credentials
or supplies a supervisor. Fixture capabilities are injected in memory by that
controller; they are never sent to Baton or written in receipts.
"""
import base64
import hmac
from http.server import BaseHTTPRequestHandler
import json
import re
import time
import uuid
from urllib.parse import urlsplit
from mixtape_owned_lifecycle import write_receipt
from mixtape_owned_http import OwnedHTTPListener, OwnedHTTPOutbound

ID = r"[A-Za-z0-9_-]{22}"


def origin(value):
    parsed = urlsplit(value)
    if (parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or
            not parsed.port or parsed.path or parsed.query or parsed.fragment or
            parsed.username or parsed.password):
        raise ValueError("Exact owned loopback origin required")
    return parsed


def invitation(value, base):
    parsed, target = urlsplit(value), origin(base)
    if (parsed.scheme != target.scheme or parsed.netloc != target.netloc or
            not re.fullmatch("/m/" + ID, parsed.path) or parsed.query or
            not re.fullmatch(ID, parsed.fragment)):
        raise ValueError("Owned canonical mixtape invitation required")
    key = base64.urlsafe_b64decode(parsed.fragment + "==")
    if len(key) != 16 or base64.urlsafe_b64encode(key).decode().rstrip("=") != parsed.fragment:
        raise ValueError("Canonical invitation key required")
    return parsed.path[3:], parsed.fragment


def application_pid(output, allow_absent=False):
    matches = re.findall(r'^\s*(\d+)\s+[+-]?\d+\s+UIKitApplication:io\.tonebox\.baton(?:\[|$)', output, re.MULTILINE)
    if allow_absent and not matches: return None
    if len(matches) != 1 or int(matches[0]) <= 0:
        raise ValueError("One original fixture application required")
    return int(matches[0])


class MixtapeUIActions:
    def __init__(self, root, simulator, base, backend, command, deadline, admin, operator,
                 pending=None, request=None, now=time.time, expected_pid=None):
        origin(base); origin(backend)
        if admin == operator or any(not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", x) for x in (admin, operator)):
            raise ValueError("Separate synthetic capabilities required")
        if pending is not None: invitation(pending, base)
        self.root, self.simulator, self.base, self.backend = root, simulator, base, backend
        self.command, self.deadline, self.admin, self.operator = command, deadline, admin, operator
        self.pending, self.request, self.now = pending, request or self.http, now
        self.selected = None
        self.last = None
        self.events = []
        self.expected_pid = expected_pid
        self.launch_armed = False
        self.http_custody = OwnedHTTPOutbound(deadline)

    def http(self, method, path, token, body=None):
        port = origin(self.backend).port
        encoded = None if body is None else json.dumps(body).encode()
        def action(connection):
            connection.request(method, path, body=encoded,
                headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
            response = self.http_custody.response(connection); data = response.read(65_537)
            if response.status != 200 or len(data) > 65_536:
                raise ValueError("Synthetic service request refused")
            return json.loads(data)
        return self.http_custody.run(port, action)

    def observed_pid(self, allow_absent=False):
        output, _ = self.command(["xcrun", "simctl", "spawn", self.simulator, "launchctl", "list"], cap=3)
        return application_pid(output.decode(), allow_absent=allow_absent)
    def pid(self):
        observed = self.observed_pid()
        if self.expected_pid is None or observed != self.expected_pid:
            raise ValueError("Bound original launch PID required")
        return observed

    def dispatch(self, body):
        self.deadline.remaining()
        if not isinstance(body, dict): raise ValueError("Object required")
        if set(body) == {"command", "pid"} and body['command'] == 'bindLaunch':
            initial = body['pid']
            if not self.launch_armed or type(initial) is not int or initial <= 0 or self.observed_pid() != initial:
                raise ValueError("Actual initial launch observation required")
            self.expected_pid = initial
            self.launch_armed = False
            self.selected = None; self.last = None
            write_receipt(self.root / 'mixtape-ui-launch.json', {'boundPID': initial, 'observedMatches': True})
            return {'accepted': True, 'pid': initial}
        if set(body) == {"command", "url"} and body["command"] == "register":
            self.selected = invitation(body["url"], self.base)
            self.last = None
            return {"accepted": True}
        if set(body) != {"command"} or not isinstance(body["command"], str):
            raise ValueError("Exact command required")
        name = body["command"]
        if name == 'beginLaunch':
            if self.observed_pid(allow_absent=True) is not None:
                raise ValueError('Prior app must be absent before a new launch')
            self.expected_pid = None; self.launch_armed = True
            self.selected = None; self.last = None
            return {'accepted': True}
        if name == "stats":
            report = self.request("GET", "/v1/share/admin/stats", self.admin)
            fields = [("playsStarted", "listening"), ("listened30s", "listening"), ("reactions", "engagement")]
            result = {}
            for field, section in fields:
                value = report[section][field]
                if type(value) is not int or value < 0: raise ValueError("Invalid aggregate counter")
                result[field] = value
            return dict(result, accepted=True)
        if self.selected is None: raise ValueError("App-created invitation must be registered first")
        if name == "hold":
            now = int(self.now())
            request = dict(operationID=str(uuid.uuid4()), action="disable-share", shareID=self.selected[0],
                caseReference="synthetic-mixtape-ui", reasonCode="fixture-review",
                reviewUntil=now + 20 * 86400, preservationDeadline=now + 22 * 86400)
            plan = self.request("POST", "/v1/share/admin/enforcement/plan", self.operator, request)
            # Do not apply a plan expanded to another container or operation.
            if plan.get("request") != request or len(plan.get("affected", [])) != 1 or plan["affected"][0].get("id") != self.selected[0]:
                raise ValueError("Unexpected synthetic hold scope")
            receipt = self.request("POST", "/v1/share/admin/enforcement/apply", self.operator, plan)
            if receipt.get("operationID") != request["operationID"] or receipt.get("affectedCount") != 1:
                raise ValueError("Unexpected hold receipt")
            return {"accepted": True}
        if name == "verify":
            if self.last is None: raise ValueError("No delivery to verify")
            pid = self.pid()
            if pid != self.last["pidBefore"]: raise ValueError("Original app replaced")
            self.last["confirmedUnchanged"] = True
            write_receipt(self.root / "mixtape-ui-delivery.json", self.events)
            return {"accepted": True, "pid": pid}
        if name not in ("ready", "wrong", "unknown", "incomplete", "pending"):
            raise ValueError("Unknown command")
        identifier, key = self.selected
        if name == "wrong": key = "AAAAAAAAAAAAAAAAAAAAAA" if key != "AAAAAAAAAAAAAAAAAAAAAA" else "AQEBAQEBAQEBAQEBAQEBAQ"
        if name == "unknown": identifier = "______________________" if identifier != "______________________" else "AAAAAAAAAAAAAAAAAAAAAA"
        if name == "incomplete": key = None
        if name == "pending":
            if self.pending is None: raise ValueError("Qualified pending fixture required")
            identifier, key = invitation(self.pending, self.base)
        url = "baton://mixtape/" + identifier + ("#" + key if key is not None else "")
        before = self.pid()
        self.command(["xcrun", "simctl", "openurl", self.simulator, url], cap=3)
        after = self.pid()
        if before != after: raise ValueError("Original app replaced")
        self.last = dict(command=name, pidBefore=before, pidAfter=after, unchanged=True)
        self.events.append(self.last)
        write_receipt(self.root / "mixtape-ui-delivery.json", self.events)
        return {"accepted": True, "pid": after}


class MixtapeUIControl(OwnedHTTPListener):
    def __init__(self, actions, token):
        if not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", token): raise ValueError("Private synthetic control required")
        self.actions, self.token = actions, token
        control = self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_POST(self):
                status, payload = 400, {"accepted": False}
                try:
                    size = int(self.headers.get("Content-Length", "0"))
                    if self.path != "/mixtape-ui" or not 0 < size <= 4096: raise ValueError()
                    if not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + control.token):
                        status = 401; raise ValueError()
                    data = self.rfile.read(size)
                    if len(data) != size: raise ValueError()
                    payload = control.actions.dispatch(json.loads(data)); status = 200
                # Ownership/deadline/receipt failures must reach the original
                # controller and its retain_custody path, never be swallowed as
                # an ordinary refused HTTP request while a child is uncertain.
                except (ValueError, KeyError, TypeError, json.JSONDecodeError):
                    if not control.actions.http_custody.qualified(): raise
                encoded = json.dumps(payload).encode()
                self.send_response(status); self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded))); self.end_headers(); self.wfile.write(encoded)
        super().__init__(actions.root, actions.deadline, Handler, "mixtape-ui-control-ownership.json")
    def additional_status(self): return self.actions.http_custody.status()
    def start(self):
        super().start()
        self.url = self.base + "/mixtape-ui"
    def close(self):
        closed = super().close()
        self.token = ""; self.actions.admin = ""; self.actions.operator = ""
        self.actions.selected = None; self.actions.pending = None
        return closed
