import hashlib,importlib.util,json,os,stat,sys,time,types
from pathlib import Path
PACKET=Path('/private/tmp/baton-original-parent-reconciliation-preparation-20261007-v3')
EXPECTED_NONCE='92227d8d426e42d6b604f950f4cd84b4'

def require(value):
    if not value: raise ValueError()

def read_owned(path,owner,mode,bound):
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    try:
        st=os.fstat(fd);require(stat.S_ISREG(st.st_mode) and st.st_uid==owner and stat.S_IMODE(st.st_mode)==mode and st.st_nlink==1 and st.st_size<=bound)
        with os.fdopen(fd,'rb',closefd=False) as stream:raw=stream.read(bound+1)
        require(len(raw)<=bound);return raw
    finally:os.close(fd)

def write_new(root,name,value):
    raw=value if type(value) is bytes else (json.dumps(value,sort_keys=True,indent=2)+'\n').encode()
    require(len(raw)<=65536)
    fd=os.open(root/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as stream:
        require(os.fstat(stream.fileno()).st_uid==501 and stat.S_IMODE(os.fstat(stream.fileno()).st_mode)==0o600)
        stream.write(raw);stream.flush();os.fsync(stream.fileno())

CURRENT_PHASE='ADMISSION'
PHASES={'ADMISSION','PACKET','ORIGINAL_FRAMES','SOURCE_CLOSURE','RESERVATION','PRE_REAP_WITNESS','REAP','POST_REAP_WITNESS','RECEIPTS','STRICT_PREVALIDATION','EXIT_COMMIT'}

def mark_phase(phase,error=None):
    global CURRENT_PHASE
    if phase in PHASES:CURRENT_PHASE=phase
    try:
        require(CURRENT_PHASE in PHASES and os.getpid()==70695 and os.getuid()==501)
        st=PACKET.lstat();require(PACKET.resolve()==PACKET and stat.S_ISDIR(st.st_mode) and st.st_uid==501 and stat.S_IMODE(st.st_mode)==0o700)
        kind=type(error).__name__ if error is not None else None
        if kind not in {None,'ValueError','PermissionError','FileNotFoundError','TimeoutError','ChildProcessError','OSError'}:kind='Other'
        value={'phase':CURRENT_PHASE,'errorClass':kind,'observationOnly':True,'releaseEstablished':False}
        write_new(PACKET,'phase-failure.json' if error is not None else 'phase-'+CURRENT_PHASE.lower()+'.json',value)
    except BaseException:pass

def main():
    require(os.getpid()==70695 and os.getppid()==70681 and os.getuid()==501 and os.geteuid()==501 and sys.version_info[:2]==(3,14))
    mark_phase('PACKET')
    st=PACKET.lstat();require(PACKET==PACKET.resolve() and stat.S_ISDIR(st.st_mode) and st.st_uid==501 and stat.S_IMODE(st.st_mode)==0o700)
    plan=json.loads(read_owned(PACKET/'plan.json',501,0o600,16384));require(plan['nonce']==EXPECTED_NONCE and plan['coreSHA256']=='4ca214a20be5567f77eff68ee5dcc76f84d7b1e7500d4885468adb501ab05a3f' and plan['originalROOT']=='/private/tmp/baton-tbx8711-next-runtime-20261007-41988bf2')
    raw=read_owned(PACKET/'core.py',501,0o600,16384);require(hashlib.sha256(raw).hexdigest()=='4ca214a20be5567f77eff68ee5dcc76f84d7b1e7500d4885468adb501ab05a3f')
    protocol=types.ModuleType('original_reconciliation_private');exec(compile(raw,str(PACKET/'core.py'),'exec'),protocol.__dict__)
    root=Path(plan['originalROOT']);rs=root.lstat();require(root.resolve()==root and stat.S_ISDIR(rs.st_mode) and rs.st_uid==501 and stat.S_IMODE(rs.st_mode)==0o700)
    for name in ['compile-supervision.json','safe-run-receipt.json','cleanup-complete','driver-finished']:require(not (root/name).exists())
    controller=str(root/'controller.py');adapter='/private/tmp/baton-tbx-8711-next-attempt/ios/scripts/app_attest_owned_controller.py'
    mark_phase('ORIGINAL_FRAMES')
    frames=[];frame=sys._getframe()
    for _ in range(128):
        if frame is None:break
        if (frame.f_code.co_filename,frame.f_code.co_name) in [(controller,'run'),(adapter,'stage')]:frames.append(frame)
        frame=frame.f_back
    require(frame is None and len(frames)==2)
    run=next(f for f in frames if f.f_code.co_name=='run');stage=next(f for f in frames if f.f_code.co_name=='stage')
    require(str(run.f_globals['ROOT'])==str(root) and str(stage.f_globals['ROOT'])==str(root))
    custody=run.f_locals['custody'];runner=run.f_locals['runner'];child=stage.f_locals['child']
    require(type(custody) is dict and custody.get('unknown') is True and custody.get('launchUncertain') is False and custody.get('sessionVerified') is True and custody.get('candidatePID')==70700)
    require(stage.f_locals['custody'] is custody and stage.f_locals['runner'] is runner and stage.f_locals['name']=='compile')
    processes=custody['_processes'];require(type(processes) is list and len(processes)==1 and processes[0] is child)
    popen=sys.modules['subprocess'].Popen;require(type(child) is popen)
    attrs=object.__getattribute__(child,'__dict__');require(attrs.get('pid')==70700 and attrs.get('returncode') is None and attrs.get('_child_created') is True)
    original=dict(custody['lastOutcome']);require(original.get('errorClass')=='PermissionError' and original.get('testExit')==1 and original.get('timedOut') is False and original.get('cleanupComplete') is False and original.get('leaderReaped') is False and original.get('ownedGroupPending') is True and original.get('inspectionProcessPending') is False)
    wait_owned=object.__getattribute__(runner,'__dict__')['wait_owned'];require(type(wait_owned) is types.FunctionType and wait_owned.__code__.co_filename=='/private/tmp/baton-tbx-9312/scripts/mixtape_owned_supervision.py')
    pending=wait_owned.__globals__['PENDING_INSPECTIONS'];require(type(pending) is list and pending==[])
    original_report=run.f_locals['report'];require(type(original_report) is dict and original_report['phases']==[] and original_report['acceptedSuccess'] is False and original_report['deviceActions']==0 and original_report['providerActions']==0)
    input_raw=read_owned(root/'input-pins.json',501,0o600,65536);require(hashlib.sha256(input_raw).hexdigest()==plan['inputPinsSHA256']);pins=json.loads(input_raw)['inputSHA256'];require(type(pins) is dict and len(pins)==64)
    length_raw=read_owned(PACKET/'input-lengths.json',501,0o600,7741);require(hashlib.sha256(length_raw).hexdigest()=='061a13f7c2e4fdd8b60f85922bb3799cce995c31f4a38c078be888c022c52ead')
    lengths=json.loads(length_raw);require(type(lengths) is dict and set(lengths)==set(pins) and all(type(n) is int and n>=0 for n in lengths.values()))
    def sources():
        mark_phase('SOURCE_CLOSURE')
        require(hashlib.sha256(read_owned(root/'input-pins.json',501,0o600,65536)).hexdigest()==plan['inputPinsSHA256'])
        for name,expected in pins.items():
            path=Path(name);exact=lengths[name]
            fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
            try:
                st=os.fstat(fd);require(stat.S_ISREG(st.st_mode) and st.st_uid==501 and st.st_nlink==1 and st.st_size==exact)
                digest=hashlib.sha256();count=0
                with os.fdopen(fd,'rb',closefd=False) as stream:
                    while count<exact:
                        chunk=stream.read(min(65536,exact-count));require(bool(chunk));digest.update(chunk);count+=len(chunk)
                    require(stream.read(1)==b'')
                require(count==exact and digest.hexdigest()==expected)
            finally:os.close(fd)
        for name,key in [(root/'controller.py','controllerSHA256'),(Path(adapter),'adapterSHA256'),(Path(wait_owned.__code__.co_filename),'supervisorSHA256'),(root/'compile-readiness.sh','shellSHA256')]:require(hashlib.sha256(name.read_bytes()).hexdigest()==plan[key])
    def exited():
        mark_phase('RESERVATION')
        require(child.returncode is None)
        result=os.waitid(os.P_PID,70700,os.WEXITED|os.WNOHANG|os.WNOWAIT)
        require(result is not None and result.si_pid==70700 and result.si_code==os.CLD_EXITED and result.si_status==1)
    def witness(phase):
        mark_phase('PRE_REAP_WITNESS' if phase=='before' else 'POST_REAP_WITNESS')
        request={'nonce':EXPECTED_NONCE,'phase':phase,'targetPID':70695,'childPID':70700,'requestedAtNs':time.time_ns()}
        write_new(PACKET,phase+'-request.json',request)
        raw=read_owned(PACKET/(phase+'-request.json'),501,0o600,8192);request['sha256']=hashlib.sha256(raw).hexdigest()
        deadline=time.monotonic()+15
        while time.monotonic()<deadline:
            path=PACKET/(phase+'-witness.json')
            try:
                st=path.lstat()
                if st.st_uid==0 and stat.S_IMODE(st.st_mode)==0o644:
                    raw=read_owned(path,0,0o644,8192);value=json.loads(raw)
                    protocol.validate_witness(value,request,time.time_ns())
                    return {'sha256':hashlib.sha256(raw).hexdigest(),'observedAtNs':value['observedAtNs'],'phase':phase}
            except FileNotFoundError:pass
            time.sleep(.025)
        raise TimeoutError()
    def partial():
        try:write_new(PACKET,'partial-reap.json',{'originalControllerPID':70695,'originalChildPID':70700,'returncode':child.returncode,'leaderReaped':True,'releaseQualified':False,'noSignals':True})
        except BaseException:pass
    def pending_empty():require(pending==[] and custody['_processes'][0] is child and child.returncode==1)
    def receipts(before,after):
        mark_phase('RECEIPTS')
        proof={'nonce':EXPECTED_NONCE,'before':before,'after':after,'originalControllerPID':70695,'originalChildPID':70700,'noSignals':True,'originalOutcome':original,'originalCompileExitCode':1}
        row={'phase':'compile','ownedPID':70700,**original,'testExit':1,'timedOut':False,'cleanupComplete':True,'leaderReaped':True,'ownedGroupPending':False,'inspectionProcessPending':False,'reconciliation':proof}
        report={key:original_report[key] for key in ['startedAtUTC','SDKWindowSeconds','deviceActions','providerActions']}
        report.update(phases=[row],result='FAIL',acceptedSuccess=False,allReadinessPhasesPassed=False,allOwnedCleanupVerified=True,ownedCleanupState={'unknown':False,'launchUncertain':False,'sessionVerified':True,'candidatePID':70700,'phase':'compile','lastOutcome':row},cancellationRequested=False,finishedAtUTC=run.f_globals['datetime'].datetime.now(run.f_globals['datetime'].timezone.utc).isoformat(),seconds=round(time.monotonic()-run.f_locals['start'],3),reconciliation=proof)
        # Cancellation is sampled through the original, reviewed function.
        report['cancellationRequested']=bool(run.f_globals['cancel_requested']())
        write_new(root,'compile-supervision.json',row);write_new(root,'safe-run-receipt.json',report)
        write_new(root,'cleanup-complete',b'owned-cleanup-verified\n')
    qualifier=run.f_globals['qualify_release'];require(type(qualifier) is types.FunctionType and qualifier.__code__.co_filename==controller)
    original_read=run.f_globals['qualified_file'];require(type(original_read) is types.FunctionType and original_read.__code__.co_filename==controller)
    original_exit=os._exit;require(type(original_exit) is types.BuiltinFunctionType and original_exit.__module__=='posix' and original_exit.__name__=='_exit' and original_exit is sys.modules['posix']._exit)
    require(sys.gettrace() is None and sys.getprofile() is None)
    def qualify():
        mark_phase('STRICT_PREVALIDATION')
        # Run unchanged strict code with ONLY the not-yet-published marker read staged.
        # Active globals/source stay untouched. Every other read is the original reader.
        require(not (root/'driver-finished').exists())
        write_new(PACKET,'staged-driver-finished',b'finished\n')
        def staged_read(name,bound):
            if name=='driver-finished':return read_owned(PACKET/'staged-driver-finished',501,0o600,bound)
            return original_read(name,bound)
        staged_globals=dict(qualifier.__globals__);staged_globals['qualified_file']=staged_read
        staged=types.FunctionType(qualifier.__code__,staged_globals,qualifier.__name__,qualifier.__defaults__,qualifier.__closure__)
        require(staged()==0)
        require(not (root/'driver-finished').exists())
        write_new(PACKET,'reconciliation-complete.json',{'failedCompiler':True,'cleanupQualified':True,'strictLogicPrevalidated':True,'markerPublished':False,'controllerExitCommitted':False,'originalControllerPID':70695,'originalChildPID':70700})
    def commit():
        mark_phase('EXIT_COMMIT')
        # All owned work is absent and all fallible prevalidation is complete.
        # From here even open/write/fsync/close failure commits original self-exit1.
        # No diagnostics, strict qualification or hold return follows publication.
        try:write_new(root,'driver-finished',b'finished\n')
        finally:original_exit(1)
    def reap():
        mark_phase('REAP')
        return child.wait(timeout=0.5)
    actions=types.SimpleNamespace(sources=sources,exited_reserved_child=exited,witness=witness,reap_original=reap,partial_reap_notice=partial,pending_empty=pending_empty,failed_receipts=receipts,qualify_original_release=qualify,exit_original_failed=commit)
    protocol.reconcile(actions)

try:main()
except BaseException as error:
    mark_phase(CURRENT_PHASE,error)
    # Return to the ORIGINAL unmodified controller's hold, including partial reap.
    # Never reset Popen.returncode, release guards, signal or schedule a retry.
    pass
