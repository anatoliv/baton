"""Extracted accepted in-process HTTP custody; no process supervision."""
from http.server import HTTPServer
import http.client
import socket
import threading
from mixtape_owned_lifecycle import write_receipt


class OwnedHTTPServer(HTTPServer):
    def __init__(self, *args, deadline, **kwargs):
        self.deadline = deadline
        self.accepted_requests = {}
        self.accept_uncertain = False
        super().__init__(*args, **kwargs)
    def get_request(self):
        # Preserve uncertainty before accept, and an exact live object
        # reference before any deadline/timeout operation can fail.
        self.accept_uncertain = True
        connection, address = self.socket.accept()
        self.accepted_requests[id(connection)] = dict(request=connection, closed=False, uncertain=False)
        self.accept_uncertain = False
        connection.settimeout(self.deadline.remaining(2))
        return connection, address
    def shutdown_request(self, request):
        entry = self.accepted_requests.get(id(request))
        if entry is None or entry['request'] is not request or entry['uncertain']:
            raise RuntimeError("Accepted request custody requires reconciliation")
        if entry['closed']: return
        try:
            try: request.shutdown(socket.SHUT_WR)
            except OSError: pass  # A disconnected peer still requires proven close.
            request.close()
            if request.fileno() != -1: raise RuntimeError("Accepted request close unqualified")
            entry['closed'] = True
        except BaseException:
            entry['uncertain'] = True
            raise
    def _handle_request_noblock(self):
        # BaseServer's default catches ordinary exceptions, prints a
        # traceback and returns. Ownership faults must reach the original
        # controller after exact accepted-request cleanup is attempted.
        if self.accept_uncertain or any(not entry['closed'] for entry in self.accepted_requests.values()):
            raise RuntimeError("Earlier accepted request custody requires reconciliation")
        primary = None
        cleanup_error = None
        try:
            request, address = self.get_request()
            if self.verify_request(request, address): self.process_request(request, address)
        except BaseException as error:
            primary = error
        finally:
            for entry in self.accepted_requests.values():
                if entry['closed']: continue
                if entry['uncertain']:
                    cleanup_error = cleanup_error or RuntimeError("Accepted request cleanup unqualified")
                    continue  # No automatic retry after an uncertain close.
                try: self.shutdown_request(entry['request'])
                except BaseException as error: cleanup_error = cleanup_error or error
        if primary is not None: raise primary
        if cleanup_error is not None: raise cleanup_error
        if self.accept_uncertain: raise RuntimeError("Accepted request birth unqualified")
    def handle_error(self, request, address):
        # Fail closed if an inherited path unexpectedly calls this;
        # never print request, authentication, invitation or traceback.
        raise RuntimeError("Unexpected HTTP dispatch error path")


class OwnedHTTPListener:
    def __init__(self, root, deadline, handler_type, receipt_name):
        self.root, self.deadline = root, deadline
        self.handler_type, self.receipt_name = handler_type, receipt_name
        self.server_type = OwnedHTTPServer
        self.server = None
        self.listener_uncertain = False
    def start(self):
        # Keep this object in the original controller's cleanup scope BEFORE
        # binding. A bind/ownership receipt exception must leave it reachable.
        if self.server is not None or self.listener_uncertain or threading.current_thread() is not threading.main_thread():
            raise ValueError("One original-thread control start required")
        self.listener_uncertain = True
        self.server = self.server_type(("127.0.0.1", 0), self.handler_type, deadline=self.deadline, bind_and_activate=False)
        self.listener_uncertain = False
        self.server.server_bind(); self.server.server_activate()
        self.server.timeout = .2
        self.base = "http://127.0.0.1:" + str(self.server.server_port)
        write_receipt(self.root / self.receipt_name, {"closed": False})
    def serve_one(self):
        if self.server is None or threading.current_thread() is not threading.main_thread():
            raise ValueError("Original controller thread required")
        self.deadline.remaining(); self.server.handle_request()
    def additional_status(self):
        return {"additionalResourcesClosed": True}
    def close(self):
        additional = self.additional_status()
        accepted = []
        if self.server is not None:
            accepted = list(self.server.accepted_requests.values())
            for entry in accepted:
                if entry['closed'] or entry['uncertain']: continue
                try: self.server.shutdown_request(entry['request'])
                except BaseException: pass  # Exact entry remains uncertain and unqualified.
        if self.server is not None: self.server.server_close()
        listener_closed = self.server is None or self.server.socket.fileno() == -1
        accept_uncertain = self.server is not None and self.server.accept_uncertain
        requests_closed = all(entry['closed'] and not entry['uncertain'] for entry in accepted)
        closed = listener_closed and requests_closed and not accept_uncertain and not self.listener_uncertain and additional["additionalResourcesClosed"]
        write_receipt(self.root / self.receipt_name,
            {"closed": closed, "listenerClosed": listener_closed, "acceptedRequests": len(accepted),
             "acceptedRequestsClosed": requests_closed, "acceptUncertain": accept_uncertain,
             "listenerUncertain": self.listener_uncertain, **additional})
        return closed


class OwnedHTTPOutbound:
    """One shared exact-reference boundary for every local outbound request."""
    def __init__(self, deadline):
        self.deadline = deadline
        self.connections = {}
        self.birth_uncertain = False
    def qualified(self):
        return not self.birth_uncertain and all(e['closed'] and not e['uncertain'] and not e['responsePending'] for e in self.connections.values())
    def open(self, port):
        if not self.qualified(): raise RuntimeError('Earlier outbound custody requires reconciliation')
        if type(port) is not int or not 1024 <= port <= 65535: raise ValueError('Exact loopback port required')
        timeout = self.deadline.remaining(3)
        self.birth_uncertain = True
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=timeout)
        self.connections[id(connection)] = dict(connection=connection, response=None, responsePending=False, closed=False, uncertain=False)
        self.birth_uncertain = False
        return connection
    def response(self, connection):
        entry = self.connections[id(connection)]
        if entry['connection'] is not connection or entry['response'] is not None or entry['responsePending']:
            raise RuntimeError('Exact outbound response custody required')
        entry['responsePending'] = True
        response = connection.getresponse()
        entry['response'] = response
        entry['responsePending'] = False
        return response
    def close(self, connection):
        entry = self.connections.get(id(connection))
        if entry is None or entry['connection'] is not connection or entry['uncertain'] or entry['responsePending']:
            return RuntimeError('Outbound custody requires reconciliation')
        if entry['closed']: return None
        try:
            if entry['response'] is not None:
                entry['response'].close()
                if entry['response'].isclosed() is not True: raise RuntimeError('Outbound response close unqualified')
            connection.close()
            if connection.sock is not None: raise RuntimeError('Outbound connection close unqualified')
            entry['closed'] = True
        except BaseException as error:
            entry['uncertain'] = True
            return error
        return None
    def run(self, port, action):
        connection = self.open(port)
        primary, result = None, None
        try: result = action(connection)
        except BaseException as error: primary = error
        cleanup_error = self.close(connection)
        if primary is not None: raise primary
        if cleanup_error is not None: raise cleanup_error
        return result
    def status(self):
        for entry in self.connections.values():
            if not entry['closed'] and not entry['uncertain'] and not entry['responsePending']:
                self.close(entry['connection'])
        qualified = self.qualified()
        return {'additionalResourcesClosed': qualified, 'outboundConnections': len(self.connections),
            'outboundResponses': sum(e['response'] is not None for e in self.connections.values()),
            'outboundClosed': qualified, 'outboundBirthUncertain': self.birth_uncertain,
            'outboundResponsePending': any(e['responsePending'] for e in self.connections.values())}
