#!/usr/bin/env python3
"""Source-bound standalone compiler admission; no app-hosted native resources.

The original Python compiler parent holds one private retained inode throughout
reserved-child supervision. Unknown custody must never unwind that parent/lock.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import time
from types import ModuleType

KEYS={'schemaVersion','attemptRoot','repository','controllerPath','guardPath','guardIdentity','sourceSHA256','mode'}

def require(condition):
    if not condition:raise ValueError('offline compiler binding refused')

def regular(path,private=False):
    a=path.lstat()
    require(path.is_absolute() and path.resolve()==path and stat.S_ISREG(a.st_mode) and
            a.st_uid==os.getuid() and a.st_nlink==1 and not path.is_symlink())
    if private:require(stat.S_IMODE(a.st_mode)==0o600)
    return a

def identity(a):
    return {'device':a.st_dev,'inode':a.st_ino,'uid':a.st_uid,'links':a.st_nlink,'mode':stat.S_IMODE(a.st_mode)}

def binding(path,expected):
    require(len(expected)==64 and all(c in '0123456789abcdef' for c in expected))
    a=regular(path,True);require(a.st_size<=65536)
    raw=path.read_bytes();require(hashlib.sha256(raw).hexdigest()==expected)
    data=json.loads(raw);require(set(data)==KEYS and data['schemaVersion']==1 and data['mode']=='offline-compiler-only')
    root=Path(data['attemptRoot']);a=root.lstat()
    require(root.is_absolute() and root.resolve()==root and stat.S_ISDIR(a.st_mode) and
            not root.is_symlink() and a.st_uid==os.getuid() and stat.S_IMODE(a.st_mode)==0o700)
    require(path.parent==root and path.name=='command-binding.json')
    controller=Path(data['controllerPath']);guard=Path(data['guardPath'])
    require(controller==root/'controller.py' and guard==root/'compiler-attempt.lock')
    require(type(data['sourceSHA256']) is dict and str(controller) in data['sourceSHA256'] and
            str(Path(__file__).resolve()) in data['sourceSHA256'])
    controller_source=None
    for name,expected in data['sourceSHA256'].items():
        p=Path(name);regular(p);source=p.read_bytes();require(hashlib.sha256(source).hexdigest()==expected)
        if p==controller:controller_source=source
    regular(controller,True);a=regular(guard,True);require(identity(a)==data['guardIdentity'])
    repo=Path(data['repository']);require(repo.is_absolute() and repo.resolve()==repo and repo.is_dir() and not repo.is_symlink())
    require(controller_source is not None)
    return data,controller_source

def guard(data):
    path=Path(data['guardPath']);require(identity(regular(path,True))==data['guardIdentity'])
    fd=os.open(path,os.O_RDWR|os.O_NOFOLLOW|os.O_CLOEXEC)
    try:
        os.set_inheritable(fd,False)
        require(not os.get_inheritable(fd) and identity(os.fstat(fd))==data['guardIdentity'])
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        # The digest-pinned inode must still be named by the canonical path.
        require(identity(regular(path,True))==identity(os.fstat(fd)))
        return fd
    except BaseException:
        os.close(fd)
        raise

def retain_unknown():
    # No diagnostic or receipt I/O controls original-parent custody. The accepted
    # compiler uses monotonic clocks and never arms a hard-exit alarm here.
    while True:
        try:time.sleep(30)
        except BaseException:pass

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binding',required=True,type=Path)
    parser.add_argument('--sha256',required=True)
    parser.add_argument('--coordinated-go',action='store_true')
    args=parser.parse_args()
    fd=None
    try:
        require(args.coordinated_go)
        data,controller_source=binding(args.binding,args.sha256)
        fd=guard(data)
        # Execute exactly the already hash-qualified controller bytes, never an
        # unpinned pycache or a second path read between admission and import.
        controller=ModuleType('source_bound_offline_compiler')
        controller.__file__=data['controllerPath']
        exec(compile(controller_source,data['controllerPath'],'exec'),controller.__dict__)
        require(controller.ROOT==Path(data['attemptRoot']) and controller.REPO==Path(data['repository']))
        controller.preflight()
    except BlockingIOError:
        print('REFUSED: this exact standalone compiler attempt already has an owner.')
        return 3
    except BaseException:
        if fd is not None:os.close(fd)
        print('REFUSED: standalone compiler source/input/guard admission failed; private details withheld.')
        return 2
    # From this point, no exception or unexpected return may release the owning
    # parent's descriptor. Accepted run() exits only after qualified finalization.
    try:controller.run()
    except BaseException:retain_unknown()
    retain_unknown()

if __name__=='__main__':raise SystemExit(main())
