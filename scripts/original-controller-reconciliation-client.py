"""UNADMITTED root witness client; never signals or waits on the target."""
import hashlib,json,os,stat,subprocess,sys,time
from pathlib import Path
PACKET=Path('/private/tmp/baton-original-parent-reconciliation-preparation-20261007-v3')
PLAN_SHA='dcd36a3a13001e6ceb281f71ff1aaac10142e5ad8adc7757a69365337846192d'
PYTHON=Path('/opt/homebrew/Cellar/python@3.14/3.14.7/Frameworks/Python.framework/Versions/3.14/bin/python3.14')
PYTHON_SHA='87d4df53fd91304be5bac391fb204643c36b7df2023c04a0953bcbc7d4fdf634'

def require(value):
    if not value:raise ValueError()

def owned(path,uid,mode,bound):
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    try:
        s=os.fstat(fd);require(stat.S_ISREG(s.st_mode) and s.st_uid==uid and stat.S_IMODE(s.st_mode)==mode and s.st_nlink==1 and s.st_size<=bound)
        with os.fdopen(fd,'rb',closefd=False) as stream:raw=stream.read(bound+1)
        require(len(raw)<=bound);return raw
    finally:os.close(fd)

def digest(raw):return hashlib.sha256(raw).hexdigest()

def metadata(argv):
    # Timeout may terminate/reap ONLY this fresh root-client-owned ps child.
    result=subprocess.run(argv,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env={'PATH':'/usr/bin:/bin','LC_ALL':'C','TZ':'America/New_York'},timeout=3,check=True)
    require(len(result.stdout)<=2*1024*1024);return result.stdout.decode('ascii')

def identity(plan):
    parts=metadata(['/bin/ps','-p','70695','-o','uid=,ppid=,lstart=,command=']).strip().split(None,7)
    require(len(parts)==8 and parts[0]=='501' and parts[1]=='70681' and ' '.join(parts[2:7])=='Wed Oct 7 05:50:23 2026' and digest(parts[7].encode())==plan['expectedCommandSHA256'])

def group_rows():
    rows=[]
    for line in metadata(['/bin/ps','-axo','pid=,ppid=,pgid=,stat=']).splitlines():
        p=line.split();require(len(p)==4)
        pid,ppid,pgid=map(int,p[:3])
        if pgid==70700:rows.append({'pid':pid,'ppid':ppid,'pgid':pgid,'stat':p[3]})
    require(len(rows)<=64);return rows

def root_new(name,value,public=False):
    raw=(json.dumps(value,sort_keys=True,indent=2)+'\n').encode();require(len(raw)<=8192)
    fd=os.open(PACKET/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as stream:
        s=os.fstat(stream.fileno());require(s.st_uid==0 and stat.S_IMODE(s.st_mode)==0o600 and s.st_nlink==1)
        stream.write(raw);stream.flush();os.fsync(stream.fileno())
        # Only completed non-secret witness files get this explicit exception.
        if public:os.fchmod(stream.fileno(),0o644)

def main():
    require(os.getuid()==0 and os.geteuid()==0 and sys.version_info[:2]==(3,14) and sys.flags.isolated and sys.flags.no_site and sys.dont_write_bytecode)
    require(Path(sys.executable).resolve()==PYTHON and digest(PYTHON.read_bytes())==PYTHON_SHA)
    s=PACKET.lstat();require(PACKET.resolve()==PACKET and stat.S_ISDIR(s.st_mode) and s.st_uid==501 and stat.S_IMODE(s.st_mode)==0o700)
    raw=owned(PACKET/'plan.json',501,0o600,16384);require(digest(raw)==PLAN_SHA);plan=json.loads(raw)
    require(plan['targetPID']==70695 and plan['targetUID']==501 and plan['targetPPID']==70681 and plan['childPID']==70700 and plan['packetROOT']==str(PACKET))
    for name,key in [('core.py','coreSHA256'),('payload.py','payloadSHA256'),('input-lengths.json','inputLengthsSHA256')]:require(digest(owned(PACKET/name,501,0o600,65536))==plan[key])
    original=Path(plan['originalROOT'])
    require(digest(owned(original/'controller.py',501,0o600,65536))==plan['controllerSHA256'] and digest(owned(original/'input-pins.json',501,0o600,65536))==plan['inputPinsSHA256'])
    identity(plan)
    for name in ['schedule-attempted.json','before-request.json','before-witness.json','after-request.json','after-witness.json','partial-reap.json','reconciliation-complete.json','staged-driver-finished','phase-failure.json']:require(not (PACKET/name).exists())
    root_new('schedule-attempted.json',{'nonce':plan['nonce'],'targetPID':70695,'planSHA256':PLAN_SHA,'clientUID':0,'noRetry':True})
    sys.remote_exec(70695,str(PACKET/'payload.py'))
    # Scheduling return is NOT callback execution or cleanup proof.
    for phase in ['before','after']:
        end=time.monotonic()+40;request=None
        while time.monotonic()<end:
            try:
                request_raw=owned(PACKET/(phase+'-request.json'),501,0o600,8192)
                try:request=json.loads(request_raw)
                except json.JSONDecodeError:time.sleep(.025);continue
                break
            except FileNotFoundError:time.sleep(.025)
        require(type(request) is dict and request['nonce']==plan['nonce'] and request['phase']==phase and request['targetPID']==70695 and request['childPID']==70700)
        require(0<=time.time_ns()-request['requestedAtNs']<=15_000_000_000)
        identity(plan);rows=group_rows();observed=time.time_ns()
        if phase=='before':require(len(rows)==1 and rows[0]['pid']==70700 and rows[0]['ppid']==70695 and rows[0]['pgid']==70700 and rows[0]['stat'].startswith('Z'))
        else:require(rows==[])
        root_new(phase+'-witness.json',{'nonce':plan['nonce'],'phase':phase,'requestSHA256':digest(request_raw),'requestedAtNs':request['requestedAtNs'],'observedAtNs':observed,'clientUID':0,'controllerIdentityVerified':True,'groupRows':rows},public=True)
    # Original parent, not this client, is the strict cleanup/release authority.
    return 0

if __name__=='__main__':
    try:raise SystemExit(main())
    except BaseException as error:
        if isinstance(error,SystemExit):raise
        try:print('Reconciliation request incomplete; target completion and guard release are not established.',file=sys.stderr)
        except BaseException:pass
        raise SystemExit(1)
