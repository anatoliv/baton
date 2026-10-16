#!/usr/bin/env python3
"""Public HTTP qualification of the disposable composer observer only."""
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading
import unittest
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from mixtape_composer_observer import ComposerObserver


class ObserverTests(unittest.TestCase):
    def setUp(self):
        self.accepted = 0
        self.foreign = False
        fixture = self
        class Backend(BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0")); self.rfile.read(length)
                fixture.accepted += 1
                if self.path == "/v1/share/mixtapes":
                    payload = {"id": "AAAAAAAAAAAAAAAAAAAAAA", "url": ("https://untrusted.invalid" if fixture.foreign else fixture.backend)
                        + "/m/AAAAAAAAAAAAAAAAAAAAAA", "uploads": {"BBBBBBBBBBBBBBBBBBBBBA": "/owned-relative"}}
                    status = 201
                else: payload, status = {"accepted": True}, 200
                data = json.dumps(payload).encode()
                self.send_response(status); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
            def do_GET(self):
                data = b'{"status":"ready"}'
                self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Backend)
        self.backend = "http://127.0.0.1:" + str(self.server.server_port)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()
        self.observer = ComposerObserver(self.backend, "synthetic-control-not-provider-material")
    def tearDown(self):
        self.assertTrue(self.observer.close())
        self.server.shutdown(); self.server.server_close(); self.thread.join(timeout=2)
        self.assertFalse(self.thread.is_alive())
    def request(self, path, body=None, control=False):
        request = Request(self.observer.base + path, data=json.dumps(body).encode() if body is not None else None)
        if control: request.add_header("Authorization", "Bearer synthetic-control-not-provider-material")
        with urlopen(request, timeout=2) as response:
            return response.status, json.load(response)
    def testCanonicalCreateOriginTranslatesWithoutChangingRelativeUploads(self):
        status, result = self.request("/v1/share/mixtapes", {})
        self.assertEqual(status, 201)
        self.assertEqual(result["url"], self.observer.base + "/m/AAAAAAAAAAAAAAAAAAAAAA")
        self.assertEqual(result["uploads"], {"BBBBBBBBBBBBBBBBBBBBBA": "/owned-relative"})
        _, counts = self.request("/_baton_mixtape_fixture", control=True)
        self.assertEqual(counts["creates"], 1)
        self.assertEqual(self.accepted, 1)
    def testUncertainFinalizeIsAcceptedOnceAndOwnerRefusesUntilExplicitRelease(self):
        self.request("/_baton_mixtape_fixture", {"loseFinalization": True}, control=True)
        with self.assertRaises(HTTPError) as refusal:
            self.request("/v1/share/mixtapes/AAAAAAAAAAAAAAAAAAAAAA/finalize", {})
        self.assertEqual(refusal.exception.code, 503)
        self.assertLessEqual(len(refusal.exception.read()), 4096)
        self.assertEqual(self.accepted, 1)
        with self.assertRaises(HTTPError) as refusal:
            self.request("/v1/share/mixtapes/AAAAAAAAAAAAAAAAAAAAAA")
        self.assertEqual(refusal.exception.code, 503)
        self.assertLessEqual(len(refusal.exception.read()), 4096)
        self.request("/_baton_mixtape_fixture", {"release": True}, control=True)
        status, result = self.request("/v1/share/mixtapes/AAAAAAAAAAAAAAAAAAAAAA")
        self.assertEqual(status, 200); self.assertEqual(result["status"], "ready")
        _, counts = self.request("/_baton_mixtape_fixture", control=True)
        self.assertEqual(counts["finalizes"], 1)
    def testForeignCreateOriginAndUnauthenticatedControlRefuse(self):
        self.foreign = True
        with self.assertRaises(HTTPError) as refusal: self.request("/v1/share/mixtapes", {})
        self.assertEqual(refusal.exception.code, 502)
        with self.assertRaises(HTTPError) as refusal: self.request("/_baton_mixtape_fixture", {"loseFinalization": True})
        self.assertEqual(refusal.exception.code, 401)
        self.assertFalse(self.observer.lose)


if __name__ == "__main__": unittest.main()
