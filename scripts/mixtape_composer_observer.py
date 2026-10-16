"""Disposable loopback HTTP observer; never a service activation path."""
import hmac
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import re
import threading
from urllib.parse import urlsplit

ID = r"[A-Za-z0-9_-]{22}"
CONTROL = "/_baton_mixtape_fixture"
MAX_BODY = 26_214_400


class ComposerObserver:
    def __init__(self, backend, token):
        target = urlsplit(backend)
        if target.scheme != "http" or target.hostname != "127.0.0.1" or not target.port or \
                target.path or target.query or target.fragment or target.username or target.password:
            raise ValueError("Exact owned loopback backend required")
        self.backend, self.port, self.token = backend, target.port, token
        self.lock = threading.Lock()
        self.counts = {"creates": 0, "tracks": 0, "finalizes": 0}
        self.lose = False
        observer = self

        class Handler(BaseHTTPRequestHandler):
            def setup(self):
                super().setup(); self.connection.settimeout(20)
            def log_message(self, *_): pass
            def do_GET(self): self.forward()
            def do_POST(self): self.forward()
            def do_PUT(self): self.forward()
            def do_PATCH(self): self.forward()
            def do_DELETE(self): self.forward()
            def forward(self):
                connection = None
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    if not 0 <= length <= MAX_BODY: raise ValueError()
                    body = self.rfile.read(length)
                    if len(body) != length: raise ValueError()
                    if self.path == CONTROL:
                        if not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + observer.token):
                            self.send_error(401); return
                        with observer.lock:
                            if self.command == "POST":
                                if length > 128: raise ValueError()
                                control = json.loads(body)
                                if control not in [{"loseFinalization": True}, {"release": True}]: raise ValueError()
                                observer.lose = "loseFinalization" in control
                            elif self.command != "GET": raise ValueError()
                            result = dict(observer.counts, losingFinalization=observer.lose)
                        self.respond(200, [("Content-Type", "application/json")], json.dumps(result).encode()); return
                    path = urlsplit(self.path).path
                    # No arbitrary absolute-form URLs or redirects are followed.
                    if not self.path.startswith("/") or self.path.startswith("//") or len(self.path) > 512:
                        raise ValueError()
                    create = self.command == "POST" and path == "/v1/share/mixtapes"
                    track = self.command == "PUT" and re.fullmatch(r"/v1/share/mixtapes/" + ID + "/tracks/" + ID, path)
                    finalize = self.command == "POST" and re.fullmatch(r"/v1/share/mixtapes/" + ID + "/finalize", path)
                    owner_read = self.command == "GET" and re.fullmatch(r"/v1/share/mixtapes/" + ID, path)
                    with observer.lock:
                        for name, matched in [("creates", create), ("tracks", track), ("finalizes", finalize)]:
                            if matched: observer.counts[name] += 1
                        lose = observer.lose and (finalize or owner_read)
                    headers = {key: value for key, value in self.headers.items()
                               if key.lower() not in ["host", "connection", "transfer-encoding"]}
                    connection = http.client.HTTPConnection("127.0.0.1", observer.port, timeout=15)
                    connection.request(self.command, self.path, body=body, headers=headers)
                    response = connection.getresponse()
                    data = response.read(MAX_BODY + 1)
                    if len(data) > MAX_BODY: raise ValueError()
                    if lose:
                        # The service accepted it, but its acknowledgment is unavailable.
                        # An explicit bounded refusal settles background URLSession work;
                        # a headerless disconnect can remain in daemon connectivity retries.
                        self.respond(503, [("Content-Type", "application/json")],
                                     b'{"code":"unavailable","error":"Synthetic acknowledgment unavailable."}')
                        return
                    if create and response.status == 201:
                        payload = json.loads(data)
                        if not re.fullmatch(ID, payload.get("id", "")) or payload.get("url") != observer.backend + "/m/" + payload["id"]:
                            raise ValueError()
                        # Fixture-only canonical origin translation. This does not test
                        # foreign returned URL acceptance; the client rejects those separately.
                        payload["url"] = observer.base + "/m/" + payload["id"]
                        data = json.dumps(payload).encode()
                    self.respond(response.status, response.getheaders(), data)
                except (ValueError, OSError, http.client.HTTPException, json.JSONDecodeError):
                    self.send_error(502, "Owned fixture request refused")
                finally:
                    if connection: connection.close()
            def respond(self, status, headers, data):
                self.send_response(status)
                for key, value in headers:
                    if key.lower() not in ["content-length", "transfer-encoding", "connection"]:
                        self.send_header(key, value)
                self.send_header("Content-Length", str(len(data))); self.end_headers()
                self.wfile.write(data)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.base = "http://127.0.0.1:" + str(self.server.server_port)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
    def close(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(timeout=2)
        self.token = ""
        return not self.thread.is_alive() and self.server.socket.fileno() == -1
