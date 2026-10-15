#!/usr/bin/env python3
"""Loopback-only deterministic model for the real iPhone Friend sharing tool path."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import argparse
import json


class Model(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        messages = body.get("messages", [])
        tools = body.get("tools", [])
        advertised = {tool.get("function", {}).get("name") for tool in tools}
        if messages and messages[-1].get("role") == "tool":
            content = messages[-1].get("content", "")
            # Echo the real tool outcome; never invent success when the client refused.
            message = {"role": "assistant", "content": "Local friend result: " + content}
        elif "music_share" in advertised:
            message = {"role": "assistant", "content": None, "tool_calls": [{
                "id": "sharing_fixture_call", "type": "function", "function": {
                    "name": "music_share", "arguments": json.dumps({"query": "iPhone Sharing",
                        "note": "Friend fixture note", "expires_days": 1, "hide_details": False})}}]}
        else:
            message = {"role": "assistant", "content": "Fixture error: music_share was not advertised."}
        data = json.dumps({"id": "sharing_fixture", "object": "chat.completion", "choices": [
            {"index": 0, "message": message, "finish_reason": "tool_calls" if "tool_calls" in message else "stop"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass  # No request messages, credentials or headers go to stdout.


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=4643)
    args = parser.parse_args()
    ThreadingHTTPServer(("127.0.0.1", args.port), Model).serve_forever()
