#!/usr/bin/env python3
"""Hold synthetic audio PUTs on loopback until an isolated UI test releases them."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import http.client
import json
import threading
from urllib.parse import urlsplit

CONTROL = '/_baton_probe_upload_gate'
MAX_BODY = 25 * 1024 * 1024


def serve(port, backend):
    target = urlsplit(backend)
    if target.scheme != 'http' or target.hostname != '127.0.0.1' or not target.port or \
            target.path or target.query or target.fragment or target.username or target.password:
        raise ValueError('Exact loopback fixture backend required')
    release = threading.Event()
    lock = threading.Lock()
    entered = 0
    corrupt_next = False
    corrupted = 0

    class Gate(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass  # Requests contain synthetic authorization; never log them.

        def do_GET(self):
            self.forward()

        def do_POST(self):
            self.forward()

        def do_PUT(self):
            self.forward()

        def do_DELETE(self):
            self.forward()

        def forward(self):
            nonlocal entered, corrupt_next, corrupted
            if self.path == CONTROL:
                if self.command == 'POST':
                    try:
                        length = int(self.headers.get('Content-Length', '0'))
                        if not 0 <= length <= 1024:
                            raise ValueError('Bounded synthetic control required')
                        control = json.loads(self.rfile.read(length)) if length else {}
                        if control and control != {'holdNextAudio': True, 'corruptNextAudio': True}:
                            raise ValueError('Exact explicit synthetic fault required')
                        with lock:
                            if control:
                                corrupt_next = True
                                release.clear()
                            else:
                                release.set()
                    except (ValueError, OSError):
                        self.send_error(400, 'Synthetic gate control refused')
                        return
                elif self.command != 'GET':
                    self.send_error(405)
                    return
                with lock:
                    body = json.dumps({'enteredAudioPUTs': entered, 'released': release.is_set(),
                                       'corruptedAudioPUTs': corrupted}).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            try:
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 <= size <= MAX_BODY or self.headers.get('Transfer-Encoding'):
                    raise ValueError('Bounded fixed-length request required')
                body = self.rfile.read(size)
                if len(body) != size:
                    raise ValueError('Incomplete body')
                if self.command == 'PUT' and self.path.startswith('/v1/share/shares/') and self.path.endswith('/audio'):
                    with lock:
                        entered += 1
                        corrupt = corrupt_next
                        corrupt_next = False
                    if not release.wait(90):
                        self.send_error(504, 'Synthetic upload gate expired')
                        return
                    if corrupt:
                        if not body:
                            raise ValueError('Synthetic sealed audio required')
                        body = bytes([body[0] ^ 1]) + body[1:]
                        with lock:
                            corrupted += 1
                excluded = {'host', 'connection', 'transfer-encoding', 'content-length'}
                headers = {k: v for k, v in self.headers.items() if k.lower() not in excluded}
                connection = http.client.HTTPConnection(target.hostname, target.port, timeout=15)
                try:
                    connection.request(self.command, self.path, body=body, headers=headers)
                    response = connection.getresponse()
                    data = response.read(MAX_BODY + 1)
                    if len(data) > MAX_BODY:
                        raise ValueError('Fixture response exceeded bound')
                    self.send_response(response.status)
                    for key, value in response.getheaders():
                        if key.lower() not in {'connection', 'transfer-encoding', 'content-length'}:
                            self.send_header(key, value)
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                finally:
                    connection.close()
            except (OSError, ValueError, http.client.HTTPException):
                self.send_error(502, 'Synthetic fixture request failed')

    server = ThreadingHTTPServer(('127.0.0.1', port), Gate)
    server.daemon_threads = True
    try:
        server.serve_forever()
    finally:
        release.set()
        server.server_close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--backend', required=True)
    args = parser.parse_args()
    try:
        serve(args.port, args.backend)
    except (OSError, ValueError):
        raise SystemExit('Synthetic loopback gate refused; private details withheld')
