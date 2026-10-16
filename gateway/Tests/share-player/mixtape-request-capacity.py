"""Bounded Linux-only real POSIX parser/staging envelope; never contacts production."""
import concurrent.futures, hashlib, http.client, json, os, select, socket, subprocess, sys, tempfile, threading, time
from pathlib import Path
binary=Path(sys.argv[1]);output=Path(sys.argv[2]).resolve();pin=sys.argv[3]
if not str(output).startswith('/private/tmp/') or output.exists():raise SystemExit('requires new disposable output')
output.mkdir(mode=0o700);work=Path(tempfile.mkdtemp(prefix='baton-request-',dir='/private/tmp'));os.chmod(work,0o700)
s=socket.socket();s.bind(('127.0.0.1',0));port=s.getsockname()[1];s.close();sockets=[];process=None;stop=threading.Event();samples=[];sampler=None
receipt={'source':pin,'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),'ownerStateTouched':False,'checks':[],'phases':[]}
def status():
 c=http.client.HTTPConnection('127.0.0.1',port,timeout=5)
 try:c.request('GET','/health');r=c.getresponse();r.read();return r.status
 finally:c.close()
def metrics():
 fields={}
 for line in Path(f'/proc/{process.pid}/status').read_text().splitlines():
  k,_,v=line.partition(':')
  if k in ['VmRSS','VmHWM','VmSize','Threads']:fields[k]=int(v.strip().split()[0])*(1024 if k!='Threads' else 1)
 for name in ['memory.current','memory.peak','memory.max']:
  p=Path('/sys/fs/cgroup')/name
  if p.exists():fields['cgroup.'+name]=p.read_text().strip()
 return fields
def monitor():
 while not stop.wait(.1):
  try:samples.append(metrics())
  except OSError:return
def check(name,result):
 receipt['checks'].append({'name':name,'passed':bool(result)});assert result,name
def connect():
 c=socket.create_connection(('127.0.0.1',port),timeout=10);c.settimeout(10);sockets.append(c);return c
def closeAll():
 for c in sockets:c.close()
 sockets.clear();time.sleep(.5)
try:
 process=subprocess.Popen([str(binary),str(work/'service'),str(port)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);receipt['ownedPID']=process.pid;receipt['ownedPort']=port
 for _ in range(100):
  try:
   if status()==200:break
  except OSError:time.sleep(.05)
 else:raise RuntimeError('fixture readiness deadline')
 sampler=threading.Thread(target=monitor);sampler.start();receipt['baseline']=metrics()
 payload=b'x'*(1024*1024-4096)
 for phase in ([] if '--staging-only' in sys.argv[4:] else ['ordinary body','unterminated headers']):
  started=time.monotonic();peers=[connect() for _ in range(256)]
  def fill(c):
   if phase=='ordinary body':c.sendall(b'POST /v1/share/shares HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1048576\r\n\r\n'+payload)
   else:c.sendall(b'GET /health HTTP/1.1\r\nX-Fill: '+payload)
  with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:list(pool.map(fill,peers))
  # The withheld tail keeps requests incomplete while measuring the full configured cap.
  for c in peers:c.sendall(b'x')
  time.sleep(.2);m=metrics();refused=status();receipt['phases'].append({'name':phase,'connections':256,'payloadBytesPerConnection':len(payload)+1,'elapsedSeconds':time.monotonic()-started,'metrics':m,'excessHealthStatus':refused})
  check(phase+' at production256 connection ceiling rejects excess without OOM',m['Threads']>=257 and refused==503)
  closeAll();check(phase+' disconnect restores health',status()==200)
 # Header-first near-limit PUTs expose declared staging reservation races without
 # ever completing a request or modifying a share; only disposable staging files.
 declared=25*1024*1024;peers=[];refused=[]
 for _ in range(12):
  c=connect();c.sendall(f'PUT /v1/share/shares/synthetic/audio HTTP/1.1\r\nHost: localhost\r\nContent-Length: {declared}\r\n\r\nx'.encode());peers.append(c)
 # Wait for every header to be decided; a response can arrive after an arbitrary
 # short sleep on a busy constrained container. An undecided connection is not admission.
 stage=work/'service/data/staging'
 for _ in range(100):
  ready=select.select(peers,[],[],.05)[0]
  if len(list(stage.glob('upload-*')))+len(ready)==len(peers):break
 accepted=[]
 for c in peers:
  if select.select([c],[],[],.05)[0]:
   head=c.recv(4096);refused.append(int(head.split(b' ')[1]));c.close()
  else:accepted.append(c)
 receipt['headerAdmission']={'stagedFiles':len(list(stage.glob('upload-*'))),'accepted':len(accepted),'refused':refused}
 chunk=b'x'*(1024*1024)
 def fillStage(c):
  remaining=declared-2
  while remaining:
   n=min(remaining,len(chunk));c.sendall(chunk[:n]);remaining-=n
 with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:list(pool.map(fillStage,accepted))
 stage=work/'service/data/staging'
 for _ in range(100):
  sizes=[p.stat().st_size for p in stage.glob('upload-*')]
  if len(sizes)==len(accepted) and all(x==declared-1 for x in sizes):break
  time.sleep(.05)
 receipt['staging']={'declaredBytesPerPUT':declared,'acceptedIncompletePUTs':len(accepted),'earlyRefusalStatuses':refused,'fileCount':len(sizes),'actualStagedBytes':sum(sizes),'existingCeilingBytes':256*1024*1024,'metrics':metrics()}
 check('declared concurrent staging stays within existing256MiB ceiling',sum(sizes)<=256*1024*1024 and len(accepted)==10 and refused==[503,503])
 check('reserved streaming PUTs leave a connection for health',status()==200)
 closeAll()
 for _ in range(100):
  if not list(stage.glob('upload-*')):break
  time.sleep(.05)
 check('cancelled incomplete PUTs clean owned staging and restore health',not list(stage.glob('upload-*')) and status()==200)
 replacement=connect();replacement.sendall(f'PUT /v1/share/shares/synthetic/audio HTTP/1.1\r\nHost: localhost\r\nContent-Length: {declared}\r\n\r\nx'.encode())
 time.sleep(.2)
 check('cancelled declared reservation can be reused',len(list(stage.glob('upload-*')))==1 and not select.select([replacement],[],[],.1)[0])
 closeAll()
except Exception as e:receipt['error']=str(e)
finally:
 closeAll();stop.set()
 if sampler:sampler.join(timeout=2)
 receipt['sampledPeakRSSBytes']=max((x.get('VmRSS',0) for x in samples),default=0);receipt['sampleCount']=len(samples)
 if process:
  process.terminate()
  try:process.wait(timeout=5)
  except subprocess.TimeoutExpired:process.kill();process.wait(timeout=5)
 receipt['ownedProcessExited']=process is None or process.poll() is not None
 try:test=socket.create_connection(('127.0.0.1',port),timeout=.2);test.close();receipt['listenerClosed']=False
 except OSError:receipt['listenerClosed']=True
 receipt['remainingOwnedStagingFiles']=len(list((work/'service/data/staging').glob('upload-*')))
 (output/'receipt.json').write_text(json.dumps(receipt,indent=2));print(json.dumps(receipt,indent=2));sys.exit(1 if 'error'in receipt else 0)
