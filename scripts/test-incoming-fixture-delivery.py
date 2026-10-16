"""Disposable loopback control tests; no simulator, app, build, external network or secrets."""
import json
from pathlib import Path
import socket
import tempfile
import threading
import unittest
from unittest.mock import Mock
from urllib.error import HTTPError
from urllib.request import build_opener, ProxyHandler, Request
from incoming_fixture_delivery import DeliveryControl, application_pid, invitation_commands
from incoming_fixture_lifecycle import Deadline, FixtureTimeout


class DeliveryTests(unittest.TestCase):
    def make(self, root, pids=(42,42)):
        outputs=iter(pids); calls=[]
        def command(argv, cap):
            self.assertEqual(cap,3); calls.append(argv)
            if argv[2]=='spawn': return (f'{next(outputs)} 0 UIKitApplication:io.tonebox.baton[fixture]\n'.encode(),0)
            return b'',0
        control=DeliveryControl(root,'owned-simulator',[
            'baton://share/'+'a'*22+'#'+'b'*22,'baton://share/'+'c'*22+'#'+'d'*22],command,Deadline())
        self.addCleanup(control.server.server_close)
        return control,calls
    def request(self, control, payload, token=None, path=None):
        result={}
        def client():
            try:
                request=Request(path or control.url,data=json.dumps(payload).encode(),
                    headers={'Authorization':'Bearer '+(token if token is not None else control.token)})
                with build_opener(ProxyHandler({})).open(request,timeout=2) as response:
                    result.update(status=response.status,body=json.load(response))
            except HTTPError as error:
                with error: result.update(status=error.code,body=json.load(error))
            except Exception as error: result['error']=type(error).__name__
        thread=threading.Thread(target=client);thread.start()
        control.serve_one();thread.join(timeout=3)
        self.assertFalse(thread.is_alive());return result
    def test_actual_loopback_authenticated_delivery_preserves_exact_pid_and_invitation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);control,calls=self.make(root)
            response=self.request(control,{'command':'B'})
            self.assertEqual(response['status'],200);self.assertTrue(response['body']['accepted'])
            self.assertEqual(calls[1][:4],['xcrun','simctl','openurl','owned-simulator'])
            self.assertEqual(calls[1][4],control.urls['B'])
            receipt=(root/'delivery-events.json').read_text()
            self.assertNotIn('baton://',receipt);self.assertNotIn(control.token,receipt)
            self.assertTrue(json.loads(receipt)[0]['unchanged'])
    def test_authentication_unknown_commands_and_extra_route_arguments_launch_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            control,calls=self.make(Path(temporary))
            self.assertEqual(self.request(control,{'command':'A'},token='wrong')['status'],401)
            for data in [{'command':'arbitraryURL'},{'command':'A','simulator':'other'},[]]:
                self.assertEqual(self.request(control,data)['status'],400)
            self.assertEqual(calls,[])
    def test_pid_restart_is_failure_and_retained_receipt_is_not_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);control,_=self.make(root,pids=(42,43))
            response=self.request(control,{'command':'A'})
            self.assertEqual(response['status'],400);self.assertFalse(response['body']['accepted'])
            self.assertFalse(json.loads((root/'delivery-events.json').read_text())[0]['unchanged'])
    def test_post_confirmation_verification_checks_pid_without_redelivering(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);control,calls=self.make(root,pids=(42,42,42))
            self.assertEqual(self.request(control,{'command':'A'})['status'],200)
            response=self.request(control,{'command':'verify'})
            self.assertEqual(response['status'],200)
            self.assertEqual(response['body']['pid'],42)
            self.assertEqual(sum(c[2]=='openurl' for c in calls),1)
            self.assertTrue(json.loads((root/'delivery-events.json').read_text())[0]['confirmedUnchanged'])
    def test_post_confirmation_verification_rejects_no_delivery_and_restart(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);control,calls=self.make(root,pids=(42,42,43))
            self.assertEqual(self.request(control,{'command':'verify'})['status'],400)
            self.assertEqual(calls,[])
            self.assertEqual(self.request(control,{'command':'A'})['status'],200)
            self.assertEqual(self.request(control,{'command':'verify'})['status'],400)
            event=json.loads((root/'delivery-events.json').read_text())[0]
            self.assertFalse(event['confirmedUnchanged'])
            self.assertEqual(event['pidAfterConfirmation'],43)
    def test_missing_or_duplicate_running_app_is_rejected(self):
        valid='42 0 UIKitApplication:io.tonebox.baton[fixture]\n'
        self.assertEqual(application_pid(valid),42)
        for output in ['',valid+valid,valid.replace('42','-'),valid.replace('io.tonebox.baton[','other.app[')]:
            with self.assertRaises(ValueError): application_pid(output)
    def test_expired_deadline_refuses_listener_work(self):
        now=[0.0];control=DeliveryControl.__new__(DeliveryControl)
        control.deadline=Deadline(total=10,reserve=2,clock=lambda:now[0]);control.server=Mock()
        now[0]=8
        with self.assertRaises(FixtureTimeout): control.serve_one()
        control.server.handle_request.assert_not_called()
    def test_wrong_key_command_is_only_retained_a_with_canonical_wrong_fragment(self):
        commands=invitation_commands(['baton://share/a#keyA','baton://share/b#keyB'])
        self.assertEqual(set(commands),{'A','B','wrongA'})
        self.assertEqual(commands['wrongA'],'baton://share/a#AAAAAAAAAAAAAAAAAAAAAA')
        with self.assertRaises(ValueError): invitation_commands(['https://outside.invalid/a#key','baton://share/b#key'])
    def test_close_shuts_actual_owned_listener_and_records_absence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);control,_=self.make(root);port=control.server.server_port
            self.assertTrue(control.close())
            with socket.socket() as connection:
                connection.settimeout(.2)
                self.assertNotEqual(connection.connect_ex(('127.0.0.1',port)),0)
            self.assertTrue(json.loads((root/'delivery-control-ownership.json').read_text())['closed'])


if __name__=='__main__': unittest.main()
