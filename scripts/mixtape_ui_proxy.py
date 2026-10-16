"""Original-thread synthetic proxy using the accepted shared HTTP custody."""
import hmac
from http.server import BaseHTTPRequestHandler
import json
import re
from urllib.parse import urlsplit
from mixtape_owned_http import OwnedHTTPListener, OwnedHTTPOutbound
from mixtape_ui_control import ID, origin

MAX_BODY = 26_214_400
CONTROL = '/_baton_mixtape_fixture'


def adapted_creation(data, backend, frontend):
    payload = json.loads(data)
    if not isinstance(payload, dict) or not re.fullmatch(ID, payload.get('id', '')) or payload.get('url') != backend + '/m/' + payload['id']:
        raise ValueError('Canonical owned create response required')
    payload['url'] = frontend + '/m/' + payload['id']
    return json.dumps(payload).encode()


class MixtapeUIProxy(OwnedHTTPListener):
    def __init__(self, root, backend, token, deadline):
        self.backend = backend
        self.port = origin(backend).port
        if not re.fullmatch(r'[A-Za-z0-9_-]{32,256}', token): raise ValueError('Synthetic control required')
        self.token = token
        self.outbound = OwnedHTTPOutbound(deadline)
        self.counts = {'creates': 0, 'tracks': 0, 'finalizes': 0}
        proxy = self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self): self.forward()
            def do_POST(self): self.forward()
            def do_PUT(self): self.forward()
            def do_PATCH(self): self.forward()
            def do_DELETE(self): self.forward()
            def forward(self):
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 <= size <= MAX_BODY: raise ValueError('Bounded synthetic request required')
                body = self.rfile.read(size)
                if len(body) != size: raise ValueError('Complete synthetic request required')
                if self.path == CONTROL:
                    if not hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + proxy.token):
                        self.respond(401, [], b'{}'); return
                    if self.command == 'POST':
                        if size > 128 or json.loads(body) != {'release': True}:
                            raise ValueError('Only ordinary composer control supported')
                    elif self.command != 'GET': raise ValueError('Unsupported composer control')
                    self.respond(200, [('Content-Type', 'application/json')],
                        json.dumps(dict(proxy.counts, losingFinalization=False)).encode()); return
                parsed = urlsplit(self.path)
                if not self.path.startswith('/') or self.path.startswith('//') or len(self.path) > 512 or parsed.scheme or parsed.netloc or parsed.fragment:
                    raise ValueError('Origin-form owned path required')
                create = self.command == 'POST' and parsed.path == '/v1/share/mixtapes'
                track = self.command == 'PUT' and re.fullmatch('/v1/share/mixtapes/' + ID + '/tracks/' + ID, parsed.path)
                finalize = self.command == 'POST' and re.fullmatch('/v1/share/mixtapes/' + ID + '/finalize', parsed.path)
                for key, matched in [('creates', create), ('tracks', track), ('finalizes', finalize)]:
                    if matched: proxy.counts[key] += 1
                headers = {key: value for key, value in self.headers.items()
                    if key.lower() not in ['host', 'connection', 'transfer-encoding']}
                connection = proxy.open_outbound()
                primary = None
                try:
                    connection.request(self.command, self.path, body=body, headers=headers)
                    response = proxy.outbound.response(connection); data = response.read(MAX_BODY + 1)
                    if len(data) > MAX_BODY: raise ValueError('Bounded synthetic response required')
                    if create and response.status == 201:
                        data = adapted_creation(data, proxy.backend, proxy.base)
                    self.respond(response.status, response.getheaders(), data)
                except BaseException as error:
                    primary = error
                cleanup_error = proxy.close_outbound(connection)
                if primary is not None: raise primary
                if cleanup_error is not None: raise cleanup_error
            def respond(self, status, headers, body):
                self.send_response(status)
                for key, value in headers:
                    if key.lower() not in ['content-length', 'connection', 'transfer-encoding']:
                        self.send_header(key, value)
                self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
        super().__init__(root, deadline, Handler, 'mixtape-ui-proxy-ownership.json')
    def open_outbound(self): return self.outbound.open(self.port)
    def close_outbound(self, connection): return self.outbound.close(connection)
    def additional_status(self): return self.outbound.status()
    def close(self):
        closed = super().close()
        self.token = ''
        return closed
