"""Bounded, authenticated OS URL delivery to one already-running owned simulator."""
import hmac
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import re
import secrets
from urllib.parse import urlsplit, urlunsplit
from incoming_fixture_lifecycle import write_receipt


def application_pid(output):
    matches=re.findall(r'^\s*(\d+)\s+[+-]?\d+\s+UIKitApplication:io\.tonebox\.baton(?:\[|$)',output,re.MULTILINE)
    if len(matches)!=1 or int(matches[0])<=0:
        raise ValueError('Expected one running fixture application')
    return int(matches[0])


def invitation_commands(urls):
    if len(urls)!=2: raise ValueError('Expected two retained invitations')
    for url in urls:
        parsed=urlsplit(url)
        if parsed.scheme!='baton' or parsed.netloc!='share' or not parsed.path or not parsed.fragment:
            raise ValueError('Expected retained local fixture invitations')
    parsed=urlsplit(urls[0])
    return {'A':urls[0],'B':urls[1],'wrongA':urlunsplit(parsed._replace(fragment='AAAAAAAAAAAAAAAAAAAAAA'))}


class DeliveryControl:
    def __init__(self, root, simulator, urls, command, deadline):
        self.root,self.simulator,self.command,self.deadline=root,simulator,command,deadline
        self.urls=invitation_commands(urls)
        self.token=secrets.token_hex(32)
        self.events=[]
        control=self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args): pass  # Invitations and authentication never enter logs.
            def do_POST(self):
                status=400; payload={'accepted':False}
                try:
                    control.deadline.remaining()
                    length=int(self.headers.get('Content-Length','0'))
                    if self.path!='/deliver' or not 0<length<=256: raise ValueError('Invalid request')
                    if not hmac.compare_digest(self.headers.get('Authorization',''), 'Bearer '+control.token):
                        status=401; raise ValueError('Authentication required')
                    data=self.rfile.read(length)
                    if len(data)!=length: raise ValueError('Truncated request')
                    request=json.loads(data)
                    if not isinstance(request,dict) or set(request)!={'command'}: raise ValueError('Invalid command')
                    name=request['command']
                    if not isinstance(name,str) or name not in (*control.urls, 'verify'): raise ValueError('Unknown command')
                    payload=control.verify() if name=='verify' else control.deliver(name); status=200
                except Exception:
                    pass
                encoded=json.dumps(payload).encode()
                self.send_response(status); self.send_header('Content-Type','application/json')
                self.send_header('Content-Length',str(len(encoded))); self.end_headers()
                self.wfile.write(encoded)
        class Server(HTTPServer):
            def get_request(self):
                socket,address=super().get_request()
                socket.settimeout(control.deadline.remaining(2))
                return socket,address
        self.server=Server(('127.0.0.1',0),Handler)
        self.server.timeout=.2
        self.url='http://127.0.0.1:'+str(self.server.server_port)+'/deliver'
        write_receipt(root/'delivery-control-ownership.json',dict(simulator=simulator,
            address='127.0.0.1',port=self.server.server_port,closed=False))
    def pid(self):
        output,_=self.command(['xcrun','simctl','spawn',self.simulator,'launchctl','list'],cap=3)
        return application_pid(output.decode())
    def deliver(self, name):
        if name not in self.urls: raise ValueError('Unknown retained command')
        before=self.pid()
        self.command(['xcrun','simctl','openurl',self.simulator,self.urls[name]],cap=3)
        after=self.pid()
        event=dict(command=name,pidBefore=before,pidAfter=after,unchanged=before==after)
        self.events.append(event); write_receipt(self.root/'delivery-events.json',self.events)
        if before!=after: raise ValueError('Application restarted during OS delivery')
        return dict(accepted=True,pid=after)
    def verify(self):
        if not self.events or not self.events[-1]['unchanged']:
            raise ValueError('Expected a pending retained delivery')
        event=self.events[-1]
        after=self.pid()
        event.update(pidAfterConfirmation=after,confirmedUnchanged=after==event['pidBefore'])
        write_receipt(self.root/'delivery-events.json',self.events)
        if not event['confirmedUnchanged']: raise ValueError('Application restarted after URL confirmation')
        return dict(accepted=True,pid=after)
    def serve_one(self):
        self.deadline.remaining(); self.server.handle_request()
    def close(self):
        self.server.server_close()
        closed=self.server.socket.fileno()==-1
        write_receipt(self.root/'delivery-control-ownership.json',dict(simulator=self.simulator,
            address='127.0.0.1',port=self.server.server_port,closed=closed))
        self.urls.clear(); self.token=''
        return closed
