"""Pure contracts/mocks only: no socket, child, SDK, simulator or guard."""
import base64
from pathlib import Path
import unittest
from unittest.mock import patch
from mixtape_ui_control import MixtapeUIActions, MixtapeUIControl, application_pid, invitation, origin
from mixtape_owned_lifecycle import FixtureDiagnosticFailure

BASE = "http://127.0.0.1:49271"
KEY = base64.urlsafe_b64encode(bytes(range(16))).decode().rstrip("=")
IDENTIFIER = "AQEBAQEBAQEBAQEBAQEBAQ"
LINK = BASE + "/m/" + IDENTIFIER + "#" + KEY


class Deadline:
    def remaining(self, cap=None): return cap or 810


class Contracts(unittest.TestCase):
    def engine(self, command=None, request=None, pending=None):
        return MixtapeUIActions(Path("/private/tmp/not-created"), "synthetic-simulator",
            BASE, "http://127.0.0.1:49272", command or self.command, Deadline(),
            "a" * 32, "o" * 32, pending=pending, request=request, now=lambda: 1000, expected_pid=321)

    def command(self, argv, cap):
        self.commands.append((argv, cap))
        return (b"321 +0 UIKitApplication:io.tonebox.baton[fixture]\n", 0)

    def setUp(self): self.commands = []

    def test_only_canonical_owned_invitation_is_accepted(self):
        self.assertEqual(invitation(LINK, BASE), (IDENTIFIER, KEY))
        for value in [LINK.replace("127.0.0.1", "localhost"), LINK.replace("49271", "49273"),
                      LINK.replace("/m/", "/s/"), LINK + "=", LINK.replace("#", "?x=1#"),
                      LINK.replace(KEY, "AAAAAAAAAAAAAAAAAAAAAB"), LINK.replace(KEY, "tiny")]:
            with self.subTest(kind=value.split("#")[0]):
                with self.assertRaises(ValueError): invitation(value, BASE)

    def test_foreign_or_decorated_backend_is_refused(self):
        for value in ["http://localhost:49271", BASE + "/", BASE + "?x=1", BASE + "#x",
                      "https://127.0.0.1:49271", "http://user@127.0.0.1:49271"]:
            with self.assertRaises(ValueError): origin(value)

    def test_public_commands_require_app_created_registration(self):
        engine = self.engine()
        for name in ["ready", "hold", "verify", "wrong", "pending"]:
            with self.assertRaises(ValueError): engine.dispatch({"command": name})
        self.assertEqual(self.commands, [])
        with self.assertRaises(ValueError): engine.dispatch({"command": "register", "url": LINK, "extra": True})

    @patch("mixtape_ui_control.write_receipt")
    def test_delivery_and_confirmation_keep_original_pid_and_hide_link(self, receipt):
        engine = self.engine(); engine.dispatch({"command": "register", "url": LINK})
        self.assertEqual(engine.dispatch({"command": "ready"}), {"accepted": True, "pid": 321})
        self.assertEqual(engine.dispatch({"command": "verify"}), {"accepted": True, "pid": 321})
        self.assertEqual(len(self.commands), 4)
        self.assertEqual(self.commands[1], (["xcrun", "simctl", "openurl", "synthetic-simulator",
            "baton://mixtape/" + IDENTIFIER + "#" + KEY], 3))
        recorded = repr(receipt.call_args_list)
        self.assertNotIn(KEY, recorded); self.assertNotIn("baton://", recorded)

    @patch("mixtape_ui_control.write_receipt")
    def test_original_app_replacement_never_qualifies_delivery(self, receipt):
        pids = iter([321, 654])
        def command(argv, cap):
            if "openurl" in argv: return (b"", 0)
            return (f"{next(pids)} +0 UIKitApplication:io.tonebox.baton[fixture]\n".encode(), 0)
        engine = self.engine(command=command); engine.dispatch({"command": "register", "url": LINK})
        with self.assertRaises(ValueError): engine.dispatch({"command": "ready"})
        receipt.assert_not_called()
        with self.assertRaises(ValueError): engine.dispatch({"command": "verify"})

    def test_hold_applies_only_exact_single_registered_container(self):
        calls = []
        def request(method, path, token, body=None):
            calls.append((method, path, token, body))
            if path.endswith("plan"): return {"request": body, "affected": [{"id": IDENTIFIER}]}
            return {"operationID": body["request"]["operationID"], "affectedCount": 1}
        engine = self.engine(request=request); engine.dispatch({"command": "register", "url": LINK})
        self.assertEqual(engine.dispatch({"command": "hold"}), {"accepted": True})
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0][2], "o" * 32)
        self.assertEqual(calls[0][3]["shareID"], IDENTIFIER)
        self.assertEqual(calls[0][3]["preservationDeadline"] - calls[0][3]["reviewUntil"], 2 * 86400)
        for affected in [[], [{"id": "foreign"}], [{"id": IDENTIFIER}, {"id": IDENTIFIER}]]:
            calls.clear()
            def refuse_scope(method, path, token, body=None):
                calls.append(path); return {"request": body, "affected": affected}
            engine.request = refuse_scope
            with self.assertRaises(ValueError): engine.dispatch({"command": "hold"})
            self.assertEqual(calls, ["/v1/share/admin/enforcement/plan"])

    def test_stats_return_only_validated_aggregate_numbers(self):
        engine = self.engine(request=lambda *a: {"listening": {"playsStarted": 2, "listened30s": 0},
            "engagement": {"reactions": 1}, "private": {"never": "return"}})
        self.assertEqual(engine.dispatch({"command": "stats"}),
            {"accepted": True, "playsStarted": 2, "listened30s": 0, "reactions": 1})
        engine.request = lambda *a: {"listening": {"playsStarted": True, "listened30s": 0}, "engagement": {"reactions": 1}}
        with self.assertRaises(ValueError): engine.dispatch({"command": "stats"})

    def test_pending_fixture_and_app_identity_must_be_explicit(self):
        engine = self.engine(); engine.dispatch({"command": "register", "url": LINK})
        with self.assertRaises(ValueError): engine.dispatch({"command": "pending"})
        for text in ["", "321 +0 UIKitApplication:foreign[fixture]\n", "321 +0 UIKitApplication:io.tonebox.baton[x]\n654 +0 UIKitApplication:io.tonebox.baton[y]\n"]:
            with self.assertRaises(ValueError): application_pid(text)

    @patch("mixtape_ui_control.write_receipt")
    def test_owned_command_uncertainty_propagates_without_positive_delivery(self, receipt):
        def command(argv, cap): raise FixtureDiagnosticFailure("unclassified", "synthetic unknown cleanup")
        engine = self.engine(command=command); engine.dispatch({"command": "register", "url": LINK})
        with self.assertRaises(FixtureDiagnosticFailure): engine.dispatch({"command": "ready"})
        self.assertIsNone(engine.last); receipt.assert_not_called()

    @patch("mixtape_owned_http.write_receipt", side_effect=[OSError("synthetic receipt failure"), None])
    def test_control_remains_reachable_if_start_receipt_fails(self, receipt):
        class Socket:
            closed = False
            def fileno(self): return -1 if self.closed else 123
        class Server:
            socket = Socket()
            server_port = 49274
            accepted_requests = {}
            accept_uncertain = False
            def __init__(self, *args, **kwargs): pass
            def server_bind(self): pass
            def server_activate(self): pass
            def server_close(self): self.socket.closed = True
        control = MixtapeUIControl(self.engine(), "c" * 32)
        self.assertIsNone(control.server)
        control.server_type = Server
        with self.assertRaises(OSError): control.start()
        self.assertIsNotNone(control.server)
        self.assertTrue(control.close())
        self.assertTrue(receipt.call_args_list[-1].args[1]['closed'])

    def test_serve_refuses_wrong_controller_thread_before_dispatch(self):
        control = MixtapeUIControl(self.engine(), "c" * 32)
        with self.assertRaises(ValueError): control.serve_one()
        control.server = object()
        with patch("mixtape_owned_http.threading.current_thread", return_value=object()):
            with self.assertRaises(ValueError): control.serve_one()
        self.assertEqual(self.commands, [])

    def fake_server(self):
        class Connection:
            closed = False
            def settimeout(self, seconds): pass
            def shutdown(self, how): pass
            def close(self): self.closed = True
            def fileno(self): return -1 if self.closed else 123
        connection = Connection()
        class Listener:
            closed = False
            def accept(self): return connection, ('127.0.0.1', 49123)
            def close(self): self.closed = True
            def fileno(self): return -1 if self.closed else 124
        control = MixtapeUIControl(self.engine(), "c" * 32)
        server = object.__new__(control.server_type)
        server.socket = Listener()
        server.deadline = control.actions.deadline
        server.accepted_requests = {}
        server.accept_uncertain = False
        server.verify_request = lambda *args: True
        control.server = server
        return control, server, connection

    def test_actual_server_dispatch_rethrows_owned_error_after_request_closed(self):
        control, server, connection = self.fake_server()
        primary = FixtureDiagnosticFailure('unclassified', 'synthetic original reservation unknown')
        def process(*args): raise primary
        server.process_request = process
        with patch.object(server, 'handle_error') as trace:
            with self.assertRaises(FixtureDiagnosticFailure) as captured:
                server._handle_request_noblock()
            self.assertIs(captured.exception, primary)
            trace.assert_not_called()
        self.assertTrue(connection.closed)

    def test_post_accept_timeout_fault_does_not_disappear_or_lose_connection(self):
        control, server, connection = self.fake_server()
        with patch.object(control.actions.deadline, 'remaining', side_effect=OSError('synthetic timeout configuration fault')):
            with self.assertRaises(OSError): server._handle_request_noblock()
        self.assertTrue(connection.closed)
        self.assertEqual(len(server.accepted_requests), 1)

    def test_failed_request_shutdown_retains_identity_and_primary_fault(self):
        control, server, connection = self.fake_server()
        primary = RuntimeError('synthetic original fault')
        def process(*args): raise primary
        def refuse(): raise OSError('synthetic close refused')
        server.process_request = process; connection.close = refuse
        with patch.object(server, 'handle_error') as trace:
            with self.assertRaises(RuntimeError) as captured: server._handle_request_noblock()
            self.assertIs(captured.exception, primary); trace.assert_not_called()
        entries = list(server.accepted_requests.values())
        self.assertEqual(len(entries), 1)
        self.assertIs(entries[0]['request'], connection)
        self.assertTrue(entries[0]['uncertain']); self.assertFalse(entries[0]['closed'])

    @patch('mixtape_owned_http.write_receipt')
    def test_control_close_requires_accepted_requests_not_only_listener(self, receipt):
        control, server, connection = self.fake_server()
        calls = []
        def refuse(): calls.append('close'); raise OSError('synthetic close refused')
        connection.close = refuse
        server.process_request = lambda *args: None
        with self.assertRaises(OSError): server._handle_request_noblock()
        self.assertFalse(control.close())
        self.assertEqual(calls, ['close'], 'Uncertain request close must not automatically retry')
        self.assertTrue(server.socket.closed)
        self.assertFalse(receipt.call_args.args[1]['acceptedRequestsClosed'])
        self.assertEqual(receipt.call_args.args[1]['acceptedRequests'], 1)

    @patch('mixtape_owned_http.write_receipt')
    def test_unregistered_accept_uncertainty_prevents_empty_release(self, receipt):
        control, server, connection = self.fake_server()
        def fail(): raise OSError('synthetic accept outcome unknown')
        server.socket.accept = fail
        with self.assertRaises(OSError): server._handle_request_noblock()
        self.assertTrue(server.accept_uncertain)
        self.assertFalse(control.close())
        self.assertTrue(receipt.call_args.args[1]['listenerClosed'])
        self.assertTrue(receipt.call_args.args[1]['acceptUncertain'])

    @patch('mixtape_owned_http.write_receipt')
    def test_listener_birth_before_registration_cannot_qualify_empty_close(self, receipt):
        class RegistrationFault(MixtapeUIControl):
            def __setattr__(self, name, value):
                if name == 'server' and value is not None: raise OSError('synthetic registration interruption')
                super().__setattr__(name, value)
        control = RegistrationFault(self.engine(), 'c' * 32)
        control.server_type = lambda *args, **kwargs: object()
        with self.assertRaises(OSError): control.start()
        self.assertFalse(control.close())
        self.assertTrue(receipt.call_args.args[1]['listenerUncertain'])

    @patch('mixtape_ui_control.write_receipt')
    def test_replacement_between_deliveries_cannot_rebind_original_app(self, receipt):
        engine = self.engine(); engine.dispatch({'command': 'register', 'url': LINK})
        engine.dispatch({'command': 'ready'})
        engine.command = lambda *args, **kwargs: (b'654 +0 UIKitApplication:io.tonebox.baton[replacement]\n', 0)
        with self.assertRaises(ValueError): engine.dispatch({'command': 'ready'})

    @patch('mixtape_ui_control.write_receipt')
    def test_launch_binding_requires_prior_absence_and_exact_initial_pid(self, receipt):
        engine = self.engine(command=lambda *a, **kw: (b'', 0))
        self.assertEqual(engine.dispatch({'command': 'beginLaunch'}), {'accepted': True})
        with self.assertRaises(ValueError): engine.dispatch({'command': 'bindLaunch', 'pid': 321})
        engine.command = self.command
        with self.assertRaises(ValueError): engine.dispatch({'command': 'bindLaunch', 'pid': 654})
        self.assertEqual(engine.dispatch({'command': 'bindLaunch', 'pid': 321}), {'accepted': True, 'pid': 321})
        with self.assertRaises(ValueError): engine.dispatch({'command': 'bindLaunch', 'pid': 321})
        self.assertEqual(receipt.call_args.args[1], {'boundPID': 321, 'observedMatches': True})

    def test_existing_app_cannot_be_claimed_as_new_launch(self):
        engine = self.engine()
        with self.assertRaises(ValueError): engine.dispatch({'command': 'beginLaunch'})
        engine.expected_pid = None
        with self.assertRaises(ValueError): engine.pid()


if __name__ == "__main__": unittest.main()
