#!/usr/bin/env python3
"""Pure mocked boundaries only: no child, listener, SDK or service is started."""
import base64
import ast
import inspect
import textwrap
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
from mixtape_ui_proxy import MixtapeUIProxy, adapted_creation
from mixtape_ui_control import MixtapeUIActions, MixtapeUIControl
from mixtape_owned_http import OwnedHTTPOutbound
from mixtape_ui_packages import public_config, public_url, gateway_copy, GATEWAY_VERSIONS
from mixtape_ui_pending import create_pending

BASE = 'http://127.0.0.1:49271'
BACK = 'http://127.0.0.1:49272'
IDENTIFIER = 'AQEBAQEBAQEBAQEBAQEBAQ'
KEY = base64.urlsafe_b64encode(bytes(range(16))).decode().rstrip('=')
class Deadline:
    def remaining(self, cap=None): return cap or 810
    def enter_cleanup(self): pass
    def disarm(self): pass

class Proxy(unittest.TestCase):
    def proxy(self):
        proxy = MixtapeUIProxy(Path('/private/tmp/not-created'), BACK, 'c'*32, Deadline())
        proxy.base = BASE
        handler = object.__new__(proxy.handler_type)
        handler.command, handler.path = 'GET', '/health'
        handler.headers = {}; handler.rfile = io.BytesIO(); handler.respond = Mock()
        return proxy, handler

    def test_close_fault_preserves_original_forwarding_error(self):
        proxy, handler = self.proxy()
        primary = RuntimeError('synthetic forwarding fault')
        connection = Mock(); connection.request.side_effect = primary
        connection.close.side_effect = OSError('synthetic close fault')
        with patch('mixtape_owned_http.http.client.HTTPConnection', return_value=connection):
            with self.assertRaises(RuntimeError) as caught: handler.forward()
        self.assertIs(caught.exception, primary)

    @patch('mixtape_owned_http.write_receipt')
    def test_failed_outbound_close_cannot_qualify_listener_release(self, receipt):
        proxy, handler = self.proxy()
        connection = Mock(); connection.request.side_effect = RuntimeError('synthetic forwarding fault')
        connection.close.side_effect = OSError('synthetic close fault')
        with patch('mixtape_owned_http.http.client.HTTPConnection', return_value=connection):
            with self.assertRaises(BaseException): handler.forward()
        self.assertFalse(proxy.close())
        connection.close.assert_called_once()
        self.assertFalse(receipt.call_args.args[1]['closed'])

    @patch('mixtape_owned_http.write_receipt')
    def test_uncertain_outbound_birth_prevents_empty_release(self, receipt):
        proxy, handler = self.proxy()
        with patch('mixtape_owned_http.http.client.HTTPConnection', side_effect=OSError('synthetic birth interruption')):
            with self.assertRaises(OSError): handler.forward()
        self.assertFalse(proxy.close())
        self.assertTrue(receipt.call_args.args[1]['outboundBirthUncertain'])

    @patch('mixtape_owned_http.write_receipt')
    def test_successful_outbound_close_is_exactly_once_and_qualifies(self, receipt):
        proxy, handler = self.proxy()
        connection=Mock(); connection.sock=None
        response=Mock(); response.isclosed.return_value=True; response.status=200; response.read.return_value=b'{}'; response.getheaders.return_value=[]
        connection.getresponse.return_value=response
        with patch('mixtape_owned_http.http.client.HTTPConnection',return_value=connection): handler.forward()
        self.assertTrue(proxy.close()); connection.close.assert_called_once()
        self.assertTrue(receipt.call_args.args[1]['outboundClosed'])

    def test_canonical_create_rewrite_rejects_foreign_or_decorated_urls(self):
        payload = {'id': IDENTIFIER, 'url': BACK+'/m/'+IDENTIFIER}
        self.assertEqual(json.loads(adapted_creation(json.dumps(payload), BACK, BASE))['url'], BASE+'/m/'+IDENTIFIER)
        for url in [BASE+'/m/'+IDENTIFIER, BACK+'/m/'+IDENTIFIER+'?x=1', BACK+'/s/'+IDENTIFIER]:
            with self.assertRaises(ValueError): adapted_creation(json.dumps(dict(payload,url=url)),BACK,BASE)

class Packages(unittest.TestCase):
    def test_only_public_pinned_repository_configuration_is_accepted(self):
        url='https://github.com/apple/swift-crypto.git'
        config='[core]\n bare = true\n repositoryformatversion = 0\n[remote "origin"]\n url = '+url+'\n fetch = +refs/*:refs/*\n'
        self.assertEqual(public_config(config,{url}),url)
        for suffix in ['[credential]\n helper = synthetic\n','[http]\n extraHeader = synthetic\n','[include]\n path = synthetic\n','[core]\n hooksPath = synthetic\n']:
            with self.assertRaises(ValueError): public_config(config+suffix,{url})
        for value in ['http://github.com/apple/swift-crypto.git','https://user@github.com/apple/swift-crypto.git',url+'?x=1','file:///private/tmp/source']:
            with self.assertRaises(ValueError): public_url(value)

    def test_gateway_copy_keeps_only_public_source_dependencies_in_fresh_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary).resolve(); cache=root/'cache'; repo=root/'repo'; destination=root/'fresh'
            pins=[]; dependencies=[]
            for index,(identity,version) in enumerate(GATEWAY_VERSIONS.items()):
                url='https://github.com/apple/'+identity+'.git'; revision=str(index)*40
                state={'version':version,'revision':revision}; pins.append({'identity':identity,'location':url,'state':state})
                checkout=cache/'checkouts'/identity; bare=cache/'repositories'/identity
                (checkout/'.git').mkdir(parents=True); bare.mkdir(parents=True)
                config='[core]\n bare = false\n[remote "origin"]\n url = '+url+'\n fetch = +refs/heads/*:refs/remotes/origin/*\n'
                (checkout/'.git/config').write_text(config); (bare/'config').write_text(config)
                (checkout/'Package.swift').write_bytes(b'public synthetic manifest')
                dependencies.append({'packageRef':{'identity':identity,'kind':'remoteSourceControl','location':url},'subpath':identity,'state':{'checkoutState':state}})
            (cache/'workspace-state.json').write_text(json.dumps({'object':{'dependencies':dependencies,'artifacts':[]}}))
            (cache/'old-products').mkdir(); (cache/'old-products/object').write_bytes(b'not copied')
            pinfile=root/'pins.json'; pinfile.write_text(json.dumps({'pins':pins}))
            def command(argv):
                identity=Path(argv[2]).name
                if argv[3:] == ['rev-parse','HEAD']: return next(p['state']['revision'] for p in pins if p['identity']==identity).encode()
                if argv[3]=='show': return b'public synthetic manifest'
                return b''
            receipt=gateway_copy(cache,pinfile,destination,repo,command)
            self.assertTrue(receipt['noBuildProductsCopied']); self.assertEqual(receipt['remotePackages'],3)
            self.assertEqual(set(p.name for p in destination.iterdir()),{'checkouts','repositories','workspace-state.json'})
            with self.assertRaises(ValueError): gateway_copy(cache,pinfile,destination,repo,command)
            extra=cache/'checkouts/swift-crypto/Sources/Untracked.swift';extra.parent.mkdir();extra.write_text('synthetic extra source')
            def dirty_command(argv):
                if argv[3:]==['status','--porcelain=v1','--untracked-files=all','--ignored=matching']:return b'?? Sources/Untracked.swift\n' if Path(argv[2]).name=='swift-crypto' else b''
                return command(argv)
            with self.assertRaises(ValueError): gateway_copy(cache,pinfile,root/'rejected',repo,dirty_command)
            def ignored_command(argv):
                if argv[3:]==['status','--porcelain=v1','--untracked-files=all','--ignored=matching']:return b'!! Sources/Untracked.swift\n' if Path(argv[2]).name=='swift-crypto' else b''
                return command(argv)
            with self.assertRaises(ValueError):gateway_copy(cache,pinfile,root/'ignored-rejected',repo,ignored_command)

class Pending(unittest.TestCase):
    def material(self):
        ids=[IDENTIFIER,'AgICAgICAgICAgICAgICAg']
        blobs={i:base64.b64encode(bytes([n])*96).decode() for n,i in enumerate(ids)}
        tracks={i:{'audioBytes':96,'audioSHA256':hashlib.sha256(base64.b64decode(blobs[i])).hexdigest()} for i in ids}
        return {'orderedTracks':[{'id':i,'durationSeconds':18} for i in ids], 'rootKey':KEY,
            'encryptedManifest':base64.b64encode(bytes(96)).decode(),'tracks':tracks,'blobs':blobs}
    def test_pending_is_public_create_then_verified_get_without_finalize(self):
        calls=[]
        def request(method,path,body=None):
            calls.append((method,path,body))
            if method=='POST': return {'id':IDENTIFIER,'url':BACK+'/m/'+IDENTIFIER}
            return {'status':'pending','encryptedManifest':calls[0][2]['encryptedManifest'],'tracks':calls[0][2]['tracks']}
        self.assertEqual(create_pending(self.material(),BACK,BASE,request),BASE+'/m/'+IDENTIFIER+'#'+KEY)
        self.assertEqual([(m,p) for m,p,b in calls],[('POST','/v1/share/mixtapes'),('GET','/v1/share/m/'+IDENTIFIER)])
    def test_ready_or_tampered_public_response_cannot_be_called_pending(self):
        for status in ['ready','revoked']:
            material=self.material()
            def request(method,path,body=None):
                if method=='POST': return {'id':IDENTIFIER,'url':BACK+'/m/'+IDENTIFIER}
                return {'status':status,'encryptedManifest':material['encryptedManifest'],'tracks':material['tracks']}
            with self.assertRaises(ValueError): create_pending(material,BACK,BASE,request)
        material=self.material(); material['tracks'][IDENTIFIER]['audioSHA256']='0'*64
        with self.assertRaises(ValueError): create_pending(material,BACK,BASE,Mock())


class OutboundGaps(unittest.TestCase):
    def engine(self):
        return MixtapeUIActions(Path('/private/tmp/not-created'),'synthetic',BASE,BACK,Mock(),Deadline(),'a'*32,'o'*32)
    def test_action_close_fault_preserves_primary_error(self):
        engine=self.engine();connection=Mock();primary=RuntimeError('synthetic action failure')
        connection.request.side_effect=primary;connection.close.side_effect=OSError('synthetic close failure')
        with patch('mixtape_owned_http.http.client.HTTPConnection',return_value=connection):
            with self.assertRaises(RuntimeError) as caught:engine.http('GET','/v1/share/admin/stats','a'*32)
        self.assertIs(caught.exception,primary)
    def test_control_handler_cannot_swallow_value_error_with_unresolved_outbound_custody(self):
        engine=self.engine();control=MixtapeUIControl(engine,'c'*32);handler=object.__new__(control.handler_type)
        payload=b'{"command":"stats"}';handler.path='/mixtape-ui';handler.headers={'Content-Length':str(len(payload)),'Authorization':'Bearer '+'c'*32}
        handler.rfile=io.BytesIO(payload);handler.send_response=Mock()
        response=Mock();response.status=200;response.read.return_value=b'not JSON';response.close.side_effect=OSError('synthetic close failure')
        connection=Mock();connection.getresponse.return_value=response
        with patch('mixtape_owned_http.http.client.HTTPConnection',return_value=connection):
            with self.assertRaises(json.JSONDecodeError):handler.do_POST()
        self.assertFalse(engine.http_custody.qualified());handler.send_response.assert_not_called()

    def test_response_birth_fault_retains_exact_connection_and_refuses_retry(self):
        custody=OwnedHTTPOutbound(Deadline());connection=Mock();connection.getresponse.side_effect=OSError('synthetic response birth fault')
        with patch('mixtape_owned_http.http.client.HTTPConnection',return_value=connection):
            with self.assertRaises(OSError):custody.run(49272,lambda c:custody.response(c))
        self.assertFalse(custody.qualified());connection.close.assert_not_called()
        self.assertIs(next(iter(custody.connections.values()))['connection'],connection)
        with patch('mixtape_owned_http.http.client.HTTPConnection') as factory:
            with self.assertRaises(RuntimeError):custody.open(49272)
            factory.assert_not_called()

    @patch('mixtape_owned_http.write_receipt')
    def test_control_cannot_qualify_failed_action_connection(self,receipt):
        engine=self.engine();control=MixtapeUIControl(engine,'c'*32);connection=Mock()
        connection.request.side_effect=RuntimeError('synthetic action failure');connection.close.side_effect=OSError('synthetic close failure')
        with patch('mixtape_owned_http.http.client.HTTPConnection',return_value=connection):
            with self.assertRaises(BaseException):engine.dispatch({'command':'stats'})
        self.assertFalse(control.close());connection.close.assert_called_once()
        self.assertFalse(receipt.call_args.args[1]['additionalResourcesClosed'])

class FixtureQualification(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec=importlib.util.spec_from_file_location('fixture_qualification',Path(__file__).with_name('probe-mixtape-ui-walks.py'))
        cls.module=importlib.util.module_from_spec(spec);spec.loader.exec_module(cls.module)
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(dir='/private/tmp')
        self.root=Path(self.temporary.name).resolve();self.root.chmod(0o700)
        self.calls=[];self.compile_failure=None;self.cli_exit=64;self.tamper=False
        self.args=__import__('types').SimpleNamespace(gateway_cache='synthetic-cache',gateway_pins='synthetic-pins')
    def tearDown(self):self.temporary.cleanup()
    def command(self,argv,cap=120,accept_failure=False):
        self.calls.append(argv)
        if argv[0]=='swift' and '--show-bin-path' not in argv:
            if self.compile_failure:raise self.compile_failure
            import shutil
            directory=self.root/'gateway-build/debug';directory.mkdir(parents=True)
            binary=directory/'baton-mixtape-ui-fixture';binary.write_bytes(b'independent synthetic executable');binary.chmod(0o700)
            resources=directory/'baton-gateway_BatonShareServer.bundle/Contents/Resources'
            resources.mkdir(parents=True)
            for name in ['Web','AttestationRoots']:
                shutil.copytree(self.module.REPO/'gateway/Sources/BatonShareServer'/name,resources/name)
            if self.tamper:(resources/'Web/mixtape.html').write_bytes(b'substituted resource')
            return b'',0
        if argv[0]=='swift':return str(self.root/'gateway-build/debug').encode()+b'\n',0
        return b'mixtape UI fixture: invalid disposable inputs\n',self.cli_exit
    def qualify(self):
        with patch.object(self.module,'gateway_copy',return_value={'noBuildProductsCopied':True}):
            return self.module.qualify_fixture(self.root,self.args,self.command)
    def test_successful_compile_resources_and_four_refusals_produce_admissible_receipt(self):
        receipt=self.qualify()
        binary,readback=self.module.fixture_artifact(self.root/'fixture-artifact.json')
        self.assertEqual(binary.read_bytes(),b'independent synthetic executable')
        self.assertEqual(readback,receipt)
        self.assertEqual(receipt['cliRefusalsPassed'],4)
        self.assertEqual([item['exitCode'] for item in receipt['cliRefusals']],[64,64,64,64])
        self.assertEqual(len([a for a in self.calls if a[0]=='swift']),2)
        self.assertIn('--disable-automatic-resolution',self.calls[0]);self.assertIn('--skip-update',self.calls[0])
        self.assertIn(str(self.root/'gateway-build'),self.calls[0])
    def test_compile_failure_remains_primary_and_never_publishes_receipt(self):
        self.compile_failure=RuntimeError('synthetic compiler failure')
        with self.assertRaises(RuntimeError) as caught:self.qualify()
        self.assertIs(caught.exception,self.compile_failure)
        self.assertFalse((self.root/'fixture-artifact.json').exists());self.assertEqual(len(self.calls),1)
    def test_changed_resource_refuses_artifact_before_cli_execution(self):
        self.tamper=True
        with self.assertRaises(ValueError):self.qualify()
        self.assertFalse((self.root/'fixture-artifact.json').exists());self.assertEqual(len(self.calls),2)
    def test_unexpected_cli_success_never_qualifies_artifact(self):
        self.cli_exit=0
        with self.assertRaises(ValueError):self.qualify()
        self.assertFalse((self.root/'fixture-artifact.json').exists());self.assertEqual(len(self.calls),3)

class Controller(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec=importlib.util.spec_from_file_location('prepared_ui_controller',Path(__file__).with_name('probe-mixtape-ui-walks.py'))
        cls.module=importlib.util.module_from_spec(spec); spec.loader.exec_module(cls.module)
    def setUp(self):
        self.root=Path('/private/tmp/not-created'); self.deadline=Deadline(); self.owned=Mock()
        self.owned.cleanup.return_value={'simulatorAbsent':True,'containerAbsent':True}
    def test_readiness_request_preserves_primary_error_when_context_close_fails(self):
        primary=RuntimeError('synthetic read failure');custody=OwnedHTTPOutbound(self.deadline)
        response=Mock();response.read.side_effect=primary;response.close.side_effect=OSError('synthetic close failure')
        connection=Mock();connection.getresponse.return_value=response
        with patch('mixtape_owned_http.http.client.HTTPConnection',return_value=connection):
            with self.assertRaises(RuntimeError) as caught:self.module.local_request(custody,self.deadline,BASE,'GET','/ping',json_response=False)
        self.assertIs(caught.exception,primary);self.assertFalse(custody.qualified())
        response.close.assert_called_once();connection.close.assert_not_called()
        with patch('mixtape_owned_http.http.client.HTTPConnection') as factory:
            with self.assertRaises(RuntimeError):self.module.local_request(custody,self.deadline,BASE,'GET','/ping',json_response=False)
            factory.assert_not_called()

    def test_incomplete_fixture_source_receipt_cannot_admit_old_binary(self):
        for closure in [{}, {'gateway/Package.swift':'0'*64}]:
            receipt={'qualified':True,'product':'baton-mixtape-ui-fixture','cliRefusalsPassed':4,'sourceSHA256':closure}
            with patch.object(self.module,'owned_json',return_value=receipt):
                with self.assertRaises(ValueError): self.module.fixture_artifact('/private/tmp/not-created')

    def test_plaintext_ping_is_not_interpreted_as_json(self):
        custody=OwnedHTTPOutbound(self.deadline);response=Mock();response.status=200;response.read.return_value=b'pong';response.isclosed.return_value=True
        connection=Mock();connection.sock=None;connection.getresponse.return_value=response
        with patch('mixtape_owned_http.http.client.HTTPConnection',return_value=connection):
            self.assertEqual(self.module.local_request(custody,self.deadline,BASE,'GET','/ping',json_response=False),b'pong')
        self.assertTrue(custody.qualified())
    def test_failed_listener_close_retains_original_parent_before_child_cleanup(self):
        class Hold(BaseException): pass
        listener=Mock();listener.close.return_value=False
        with patch.object(self.module,'hold_original_parent',side_effect=Hold) as hold,patch.object(self.module,'write_receipt') as receipt:
            with self.assertRaises(Hold): self.module.finish(self.root,self.deadline,self.owned,[listener,None],1,'x')
            hold.assert_called_once(); self.owned.cleanup.assert_not_called(); receipt.assert_not_called()
    def test_failed_cleanup_receipt_keeps_original_parent(self):
        class Hold(BaseException): pass
        with patch.object(self.module,'cleanup_qualified',return_value=True),patch.object(self.module,'hold_original_parent',side_effect=Hold) as hold,patch.object(self.module,'write_receipt',side_effect=OSError('synthetic receipt failure')):
            with self.assertRaises(Hold): self.module.finish(self.root,self.deadline,self.owned,[Mock(),Mock()],0,'x')
            hold.assert_called_once()
    def test_retainer_disarm_fault_reaches_nonthrowing_original_parent_park(self):
        class ParkEntered(BaseException): pass
        listener=Mock();listener.close.return_value=False
        self.deadline.disarm=Mock(side_effect=OSError('synthetic disarm failure'))
        with patch.object(self.module,'_park_original_parent',create=True,side_effect=ParkEntered) as park,patch.object(self.module,'write_receipt') as receipt:
            with self.assertRaises(ParkEntered):self.module.finish(self.root,self.deadline,self.owned,[listener,None],1,'x')
            park.assert_called_once();self.owned.cleanup.assert_not_called();receipt.assert_not_called()
    def test_retainer_handler_fault_reaches_nonthrowing_original_parent_park(self):
        class ParkEntered(BaseException): pass
        listener=Mock();listener.close.return_value=False
        with patch('mixtape_owned_lifecycle.signal.signal',side_effect=OSError('synthetic handler failure')),patch.object(self.module,'_park_original_parent',create=True,side_effect=ParkEntered) as park,patch.object(self.module,'write_receipt') as receipt:
            with self.assertRaises(ParkEntered):self.module.finish(self.root,self.deadline,self.owned,[listener,None],1,'x')
            park.assert_called_once();receipt.assert_not_called()
    def test_actual_deadline_alarm_cannot_exit_after_failed_disarm_hold(self):
        from incoming_fixture_lifecycle import Deadline as ActualDeadline
        deadline=ActualDeadline(clock=lambda:0);deadline.clock=lambda:901;deadline.enter_cleanup=Mock()
        listener=Mock();listener.close.return_value=False
        with patch('incoming_fixture_lifecycle.signal.setitimer',side_effect=OSError('synthetic timer failure')),patch.object(self.module,'_park_original_parent',create=True,side_effect=RuntimeError('mock park reached')):
            try:self.module.finish(self.root,deadline,self.owned,[listener,None],1,'x')
            except BaseException:pass
        with patch('incoming_fixture_lifecycle.os._exit') as exited,patch('incoming_fixture_lifecycle.signal.setitimer',side_effect=OverflowError('synthetic infinite timer')):
            try:deadline.alarm(None,None)
            except BaseException:pass
            exited.assert_not_called()

    def test_retainer_diagnostic_exception_is_parked_without_releasing_parent(self):
        class ParkEntered(BaseException):pass
        with patch.object(self.module,'retain_custody',side_effect=OSError('synthetic diagnostic failure')),patch.object(self.module,'_park_original_parent',side_effect=ParkEntered):
            with self.assertRaises(ParkEntered):self.module.hold_original_parent(self.root,self.deadline)
        self.assertTrue(self.deadline.custody_unqualified);self.assertEqual(self.deadline.hard_end,float('inf'))

    def test_latched_alarm_returns_without_rearming_or_raising(self):
        deadline=self.module.Deadline(clock=lambda:0)
        with patch.object(self.module,'retain_custody',side_effect=OSError('synthetic setup failure')),patch.object(self.module,'_park_original_parent',side_effect=RuntimeError('mock park reached')):
            with self.assertRaises(RuntimeError):self.module.hold_original_parent(self.root,deadline)
        with patch('incoming_fixture_lifecycle.signal.setitimer',side_effect=OverflowError('synthetic infinite timer')) as timer,patch('incoming_fixture_lifecycle.os._exit') as exited:
            deadline.alarm(None,None)
            timer.assert_not_called();exited.assert_not_called()

    def test_active_deadline_installs_local_callback_and_preserves_real_bounds(self):
        from incoming_fixture_lifecycle import FixtureTimeout
        deadline=self.module.Deadline(clock=lambda:0)
        self.assertEqual((deadline.active_end,deadline.hard_end,deadline.reserve),(810,900,90))
        with patch('incoming_fixture_lifecycle.signal.signal') as handler,patch('incoming_fixture_lifecycle.signal.setitimer') as timer:
            deadline.arm()
            self.assertEqual(handler.call_args.args[1],deadline.alarm)
            self.assertEqual(timer.call_args.args[1],810)
            deadline.clock=lambda:810
            with self.assertRaises(FixtureTimeout):deadline.alarm(None,None)
            self.assertEqual(timer.call_args.args[1],90)
    def test_latched_actual_callback_after_each_setup_failure_is_inert(self):
        for fault in ['disarm','handler','diagnostic']:
            with self.subTest(fault=fault):
                deadline=self.module.Deadline(clock=lambda:0)
                with patch('incoming_fixture_lifecycle.signal.setitimer'),patch('mixtape_owned_lifecycle.signal.signal') as handler,patch.object(self.module,'_park_original_parent',side_effect=RuntimeError('mock park reached')):
                    if fault=='disarm':deadline.disarm=Mock(side_effect=OSError('synthetic disarm failure'))
                    if fault=='handler':handler.side_effect=OSError('synthetic handler failure')
                    with patch.object(self.module,'retain_custody',side_effect=OSError('synthetic diagnostic failure')) if fault=='diagnostic' else __import__('contextlib').nullcontext():
                        with self.assertRaises(RuntimeError):self.module.hold_original_parent(self.root,deadline)
                deadline.clock=Mock(side_effect=RuntimeError('clock must not run after hold'))
                with patch('incoming_fixture_lifecycle.signal.setitimer',side_effect=OSError('timer must not run')) as timer,patch('incoming_fixture_lifecycle.os._exit') as exited:
                    deadline.alarm(None,None)
                    deadline.clock.assert_not_called();timer.assert_not_called();exited.assert_not_called()

    def test_actual_park_reenters_after_sleep_exceptions(self):
        # A trace escape occurs at the next loop header, outside its protected
        # sleep, only after three mocked interruptions. The real loop is used.
        class ObservedThreeInterruptions(BaseException):pass
        target=self.module._park_original_parent;lines,start=inspect.getsourcelines(target)
        header=next(n for n in ast.walk(ast.parse(textwrap.dedent(''.join(lines)))) if isinstance(n,ast.While)).lineno+start-1
        calls=[]
        def sleep(_seconds):
            calls.append(True)
            raise [KeyboardInterrupt(),OSError('synthetic sleep failure'),ValueError('synthetic callback failure')][min(len(calls)-1,2)]
        def trace(frame,event,arg):
            if frame.f_code is target.__code__ and event=='line' and frame.f_lineno==header and len(calls)==3:raise ObservedThreeInterruptions()
            return trace
        previous=sys.gettrace()
        try:
            with patch.object(self.module.time,'sleep',side_effect=sleep):
                sys.settrace(trace)
                with self.assertRaises(ObservedThreeInterruptions):target()
        finally:sys.settrace(previous)
        self.assertEqual(len(calls),3)

    def test_failure_diagnostic_is_deferred_until_owned_cleanup_is_qualified(self):
        class Hold(BaseException): pass
        with patch.object(self.module,'cleanup_qualified',return_value=False),patch.object(self.module,'hold_original_parent',side_effect=Hold),patch.object(self.module,'write_failure') as failure,patch.object(self.module,'write_receipt'):
            with self.assertRaises(Hold): self.module.finish(self.root,self.deadline,self.owned,[None,None],1,'x',(RuntimeError('synthetic fault'),'ui','command'))
            failure.assert_not_called()

    def test_known_unstarted_listeners_get_explicit_qualified_absence(self):
        with patch.object(self.module,'cleanup_qualified',return_value=True),patch.object(self.module,'hold_original_parent') as hold,patch.object(self.module,'write_receipt') as receipt:
            self.module.finish(self.root,self.deadline,self.owned,[None,None],1,'x')
            hold.assert_not_called()
            names=[c.args[0].name for c in receipt.call_args_list]
            self.assertEqual(names[:2],['mixtape-ui-proxy-ownership.json','mixtape-ui-control-ownership.json'])
            self.assertTrue(all(c.args[1].get('notStarted') is True for c in receipt.call_args_list[:2]))

if __name__=='__main__': unittest.main()
