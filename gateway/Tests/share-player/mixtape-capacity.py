import base64, hashlib, http.client, json, os, socket, subprocess, sys, tempfile, time, uuid, threading, re
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1])/'specs/share-crypto'))
from make_vectors import b64u, seal
from make_mixtape_vectors import derive
repo=Path(sys.argv[1]); binary=sys.argv[2]; output=Path(sys.argv[3])
if not str(output).startswith('/private/tmp/') or not Path(binary).is_file(): raise SystemExit('requires owned /private/tmp output and existing fixture binary')
output.mkdir(mode=0o700)
work=Path(tempfile.mkdtemp(prefix='baton-capacity-',dir='/private/tmp')); os.chmod(work,0o700)
s=socket.socket();s.bind(('127.0.0.1',0));port=s.getsockname()[1];s.close()
base=f'http://127.0.0.1:{port}'; owner=b64u(bytes(range(32))); sockets=[]; process=None; stopSampling=threading.Event(); samples=[]; sampler=None
sourcePin=next((a[len('--source-pin='):] for a in sys.argv[4:] if a.startswith('--source-pin=')),None)
if sourcePin is not None and not re.fullmatch(r'[0-9a-f]{40}',sourcePin):raise SystemExit('requires exact immutable source pin')
receipt={'source':sourcePin or subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(),'binarySHA256':hashlib.sha256(Path(binary).read_bytes()).hexdigest(),'checks':[],'ownerStateTouched':False,'connections':6}
def rss():
    return int(subprocess.check_output(['ps','-o','rss=','-p',str(process.pid)],text=True).strip())*1024
def api(path,method='GET',body=None,headers=None):
    c=http.client.HTTPConnection('127.0.0.1',port,timeout=15)
    try:
        h={'Authorization':'Bearer '+owner};h.update(headers or {})
        if isinstance(body,dict):body=json.dumps(body).encode();h['Content-Type']='application/json'
        c.request(method,path,body,h);r=c.getresponse();result=(r.status,r.read(),dict(r.getheaders()));return result
    finally:c.close()
def check(name, passed):
    receipt['checks'].append({'name':name,'passed':bool(passed)});assert passed,name
def monitor():
    while not stopSampling.wait(.05):
        try:samples.append(rss())
        except Exception:return
def session():
    status,body,_=api(f'/v1/share/m/{identifier}/sessions','POST');assert status==201,(status,'admission');return json.loads(body)['token']
def slow(token):
    c=socket.socket();c.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,4096);c.settimeout(15);c.connect(('127.0.0.1',port))
    c.sendall(f'GET /v1/share/m/{identifier}/tracks/{track} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {token}\r\nConnection: close\r\n\r\n'.encode()); head=b''
    while b'\r\n\r\n' not in head:head+=c.recv(1)
    sockets.append(c);return int(head.split(b' ')[1])
try:
    process=subprocess.Popen([binary,str(work/'service'),str(port)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);receipt['ownedPID']=process.pid;receipt['ownedPort']=port
    for _ in range(100):
        try:
            if api('/health')[0]==200:break
        except OSError:time.sleep(.05)
    else:raise RuntimeError('readiness deadline')
    key=bytes(range(16)); descriptors={}; blobs={}; tracks=[]
    # Full near-limit encrypted track plus minimum second track; synthetic bytes only.
    # The service knows only declared duration; these bytes test transport, not media.
    for i,size in enumerate([24*1024*1024,1024]):
        tid=bytes(range(16+i*16,32+i*16));t=b64u(tid)
        cipher=seal(derive(key,b'baton-share mixtape v1 track\0'+tid),'audio',bytes(range(i*12,i*12+12)),65536,bytes([i+1])*size)
        descriptors[t]={'audioBytes':len(cipher),'audioSHA256':hashlib.sha256(cipher).hexdigest()};blobs[t]=cipher
        tracks.append({'id':t,'metadata':{'title':'Synthetic capacity','durationSeconds':1},**descriptors[t]})
    encrypted=seal(derive(key,b'baton-share mixtape v1 manifest'),'meta',bytes(range(24,36)),65536,json.dumps({'schema':'baton-mixtape-1','tracks':tracks}).encode())
    status,body,_=api('/v1/share/mixtapes','POST',{'schema':'baton-mixtape-1','requestID':str(uuid.uuid4()),'encryptedManifest':base64.b64encode(encrypted).decode(),'tracks':descriptors,'totalDurationSeconds':2,'expiresInSeconds':86400,'playCap':40,'client':{'platform':'macos','appVersion':'synthetic'}});assert status==201,status
    created=json.loads(body);identifier=created['id'];track=tracks[0]['id']
    for t,cipher in blobs.items():assert api(created['uploads'][t],'PUT',cipher)[0]==200
    assert api(f'/v1/share/mixtapes/{identifier}/finalize','POST')[0]==200
    expectedPrefix=blobs[track][:2048];blobs.clear();time.sleep(.2);receipt['baselineRSSBytes']=rss(); receipt['trackCiphertextBytes']=descriptors[track]['audioBytes']
    sampler=threading.Thread(target=monitor);sampler.start()
    tokens=[session() for _ in range(6)]; before=json.loads(api(f'/v1/share/mixtapes/{identifier}')[1])['share']['stats']['fetches']; statuses=[slow(t) for t in tokens]; time.sleep(.5)
    receipt['slowReaderStatuses']=statuses;receipt['slowReaderRSSBytes']=rss();receipt['healthDuringSlowReaders']=api('/health')[0]
    after=json.loads(api(f'/v1/share/mixtapes/{identifier}')[1])['share']['stats']['fetches'];receipt['capBeforeAfterTrackRequests']=[before,after]
    status,body,_=api(f'/v1/share/m/{identifier}/tracks/{track}','HEAD',headers={'Authorization':'Bearer '+tokens[0]});check('HEAD remains independent while payload slots occupied',status==200 and len(body)==0)
    aliases=[]
    for method,path in [('gEt',f'/v1//share//m/{identifier}//tracks/{track}/?unused=1'),('GET',f'/v1/share/m/{identifier}/tracks/{track}/')]:
        st,body,h=api(path,method,headers={'Authorization':'Bearer '+tokens[2]})
        aliases.append(st==503 and len(body)<4096 and json.loads(body).get('code')=='capacity' and h.get('Cache-Control')=='private, no-store' and h.get('Retry-After')=='1')
    st,_,_=api(f'/v1/share/m/{identifier}/%74racks/{track}',headers={'Authorization':'Bearer '+tokens[2]})
    check('equivalent parsed routes share admission and encoded unsupported route stays refused',all(aliases) and st==404)
    for c in sockets:c.close()
    sockets.clear();time.sleep(.5)
    status,body,headers=api(f'/v1/share/m/{identifier}/tracks/{track}',headers={'Authorization':'Bearer '+tokens[2],'Range':'bytes=0-2047'})
    receipt['afterDisconnect']={'status':status,'bytes':len(body),'privateNoStore':headers.get('Cache-Control')=='private, no-store'}
    check('capacity refusal preserves budget beyond residual second track and exact ciphertext',status==206 and len(body)==2048 and body==expectedPrefix)
    check('track refusal does not admit extra plays',before==after==6)
    passed=statuses[:2]==[200,200] and statuses[2:]==[503]*4
    check('bounded transfers retain reservations through slow writes',passed)
    status,_,_=api(f'/v1/share/m/{identifier}/tracks/{track}',headers={'Authorization':'Bearer '+tokens[0],'Range':'bytes=0-2047'})
    check('cancelled full transfer remains conservatively charged',status==409)
    fresh=session();status,_,_=api(f'/v1/share/m/{identifier}/tracks/{track}',headers={'Authorization':'Bearer '+fresh,'Range':'bytes=0-1,3-4'})
    status2,body,_=api(f'/v1/share/m/{identifier}/tracks/{track}',headers={'Authorization':'Bearer '+fresh,'Range':'bytes=0-1023'})
    check('invalid Range does not spend budget; valid Range preserves ciphertext',status==416 and status2==206 and len(body)==1024)
    if '--without-deadline' not in sys.argv[4:]:
        # Keep peers OPEN without reading, beyond the production absolute sending deadline.
        timeoutTokens=[session() for _ in range(3)];assert slow(timeoutTokens[0])==200 and slow(timeoutTokens[1])==200
        assert slow(timeoutTokens[2])==503
        started=time.monotonic();health=[]
        while time.monotonic()-started < 63:
            health.append(api('/health')[0]);time.sleep(3)
        status,body,_=api(f'/v1/share/m/{identifier}/tracks/{track}',headers={'Authorization':'Bearer '+timeoutTokens[2],'Range':'bytes=0-1023'})
        receipt['deadlineWaitSeconds']=time.monotonic()-started;receipt['healthDuringDeadline']=health;receipt['deadlineRetryStatus']=status;receipt['deadlineRetryBytes']=len(body)
        check('absolute writer deadline frees slots even while silent peers remain open',status==206 and len(body)==1024 and all(x==200 for x in health))
        for c in sockets:c.close()
        sockets.clear()
    # Unchanged single-song direct delivery, using independent encrypted bytes.
    original=b'legacy capacity compatibility'*32768;cipher=seal(key,'audio',bytes(range(12)),65536,original)
    status,body,_=api('/v1/share/shares','POST',{'expiresInSeconds':86400,'playCap':3,'preview':{'title':'Synthetic legacy','durationSeconds':1},'audioBytes':len(cipher),'audioSHA256':hashlib.sha256(cipher).hexdigest(),'client':{'platform':'macos','appVersion':'synthetic'}});assert status==201
    legacy=json.loads(body);assert api(legacy['uploads']['audio'],'PUT',cipher)[0]==200
    assert api(f"/v1/share/shares/{legacy['id']}/finalize",'POST')[0]==200
    status,body,_=api(f"/v1/share/p/{legacy['id']}/audio");check('single-song response keeps exact ciphertext',status==200 and body==cipher)
    assert api(f'/v1/share/mixtapes/{identifier}','DELETE')[0]==204
    status,_,_=api(f'/v1/share/m/{identifier}/tracks/{track}',headers={'Authorization':'Bearer '+fresh})
    check('revoke still fences subsequent track transfer',status==410)

except Exception as e:receipt['error']=str(e)
finally:
    stopSampling.set()
    if sampler:sampler.join(timeout=2)
    receipt['sampledPeakRSSBytes']=max(samples,default=0);receipt['rssSampleCount']=len(samples)
    for c in sockets:c.close()
    if process:
        process.terminate()
        try:process.wait(timeout=5)
        except subprocess.TimeoutExpired:process.kill();process.wait(timeout=5)
    receipt['ownedProcessExited']=process is None or process.poll() is not None
    try:
        test=socket.create_connection(('127.0.0.1',port),timeout=.2);test.close();receipt['listenerClosed']=False
    except OSError:receipt['listenerClosed']=True
    (output/'receipt.json').write_text(json.dumps(receipt,indent=2)); print(json.dumps(receipt,indent=2))
    sys.exit(1 if 'error'in receipt else 0)
