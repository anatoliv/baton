#!/usr/bin/env python3
"""Read-only inverse extraction proof against the retained accepted source."""
import ast
import hashlib
from pathlib import Path
import sys
import textwrap

old=Path(sys.argv[1]).read_text()
new=Path('scripts/mixtape_owned_http.py').read_text()
a=ast.parse(old);b=ast.parse(new)
old_control=next(n for n in a.body if isinstance(n,ast.ClassDef) and n.name=='MixtapeUIControl')
old_server=next(n for n in ast.walk(old_control) if isinstance(n,ast.ClassDef) and n.name=='Server')
new_server=next(n for n in b.body if isinstance(n,ast.ClassDef) and n.name=='OwnedHTTPServer')
new_listener=next(n for n in b.body if isinstance(n,ast.ClassDef) and n.name=='OwnedHTTPListener')
def method(cls,name): return next(n for n in cls.body if isinstance(n,ast.FunctionDef) and n.name==name)
def code(src,node): return textwrap.dedent("\n".join(src.splitlines()[node.lineno-1:node.end_lineno]))
def shape(src): return ast.dump(ast.parse(src),include_attributes=False)
checks=[]
for name in ['get_request','shutdown_request','_handle_request_noblock','handle_error']:
    before=code(old,method(old_server,name)).replace('control.actions.deadline','self.deadline')
    after=code(new,method(new_server,name))
    assert shape(before)==shape(after),name
    checks.append(name)
# Constructor gains only the explicit deadline field/keyword parameter.
before=code(old,method(old_server,'__init__'))
after=code(new,method(new_server,'__init__')).replace('*args, deadline, **kwargs','*args, **kwargs').replace('    self.deadline = deadline\n','')
assert shape(before)==shape(after);checks.append('server-init')
for name in ['start','serve_one','close']:
    before=code(old,method(old_control,name)).replace('self.actions.root','self.root').replace('self.actions.deadline','self.deadline').replace('"mixtape-ui-control-ownership.json"','self.receipt_name')
    after=code(new,method(new_listener,name))
    if name=='start':
        before=before.replace('self.url =','self.base =').replace(' + "/mixtape-ui"','')
        after=after.replace('deadline=self.deadline, ','')
    if name=='close':
        before=before.replace('    self.token = ""; self.actions.admin = ""; self.actions.operator = ""\n','').replace('    self.actions.selected = None; self.actions.pending = None\n','')
        after=after.replace('    additional = self.additional_status()\n','').replace(' and additional["additionalResourcesClosed"]','').replace(', **additional','')
    assert shape(before)==shape(after),name
    checks.append(name)
legacy=Path('scripts/test-mixtape-native-stage.sh').read_bytes()
wrapper=Path('scripts/probe-mixtape-ui-walks.sh').read_bytes()
restored=wrapper.replace(b'if python3 -B "$SCRIPT_DIR/probe-mixtape-ui-walks.py" --qualify-release',b'if python3 -B "$SCRIPT_DIR/mixtape_owned_lifecycle.py" --qualify-release').replace(b'probe-mixtape-ui-walks.py',b'test-mixtape-native-stage.py')
assert restored==legacy;checks.append('whole-shell-inverse')
print('Inverse source proof: '+str(len(checks))+' passed; accepted HTTP bodies and whole ordinary guard/custody shell reconstruct.')
print('Accepted shell SHA256: '+hashlib.sha256(legacy).hexdigest())
