"""Bounded private OneDrive transport. No automatic execution on import.

Guard/parser functions reuse the admitted4451200 public reader literally. Four
shared-file fields are selected; config, tokens and signed URLs stay in memory.
"""
import http.client
import json
import os
from pathlib import Path
import re
import ssl
import stat
import time
import urllib.parse

from .backup import require
from .custody import LIMIT

FIELDS = ('M365_TENANT_ID', 'M365_CLIENT_ID', 'M365_CLIENT_SECRET', 'ONEDRIVE_BACKUP_USER')
FIELD_ROLES = dict(zip(FIELDS, ('tenant', 'client', 'secret', 'user')))
UUID = re.compile(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
NAME = re.compile(r'(?:ordinary|case)-[0-9a-f]{32}\.sealed')
OPAQUE = re.compile(r'[A-Za-z0-9!_.\-]{1,256}')
NAMESPACE = 'baton-private-contact'
GRAPH = 'https://graph.microsoft.com'

def stage(progress, value):
    if progress is not None:
        progress['stage'] = value

def fingerprint(s):
    return (s.st_dev, s.st_ino, s.st_mode, s.st_nlink, s.st_uid, s.st_gid,
            s.st_size, s.st_mtime_ns, s.st_ctime_ns)

def decode_json(raw):
    def unique(pairs):
        value = {}
        for key, item in pairs:
            require(key not in value)
            value[key] = item
        return value
    return json.loads(raw, object_pairs_hook=unique)

def admitted_directory(path, uid, gid, mode):
    """Canonical nofollow directory with caller-required exact custody."""
    require(path.is_absolute() and path.resolve() == path)
    before = path.lstat()
    require(stat.S_ISDIR(before.st_mode) and before.st_uid == uid and
            (gid is None or before.st_gid == gid) and stat.S_IMODE(before.st_mode) == mode)
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        require(fingerprint(before) == fingerprint(os.fstat(fd)))
        require(fingerprint(before) == fingerprint(path.lstat()) and path.resolve() == path)
        return fd, before
    except BaseException:
        os.close(fd)
        raise

def stable_directory(path, fd, before):
    require(path.resolve() == path and fingerprint(before) == fingerprint(os.fstat(fd))
            and fingerprint(before) == fingerprint(path.lstat()))

def read_protected(fd, name, uid, gids, modes, limit):
    f = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
    try:
        before = os.fstat(f)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and
                before.st_uid == uid and (gids is None or before.st_gid in gids) and
                stat.S_IMODE(before.st_mode) in modes and 0 < before.st_size <= limit)
        raw = os.read(f, limit + 1)
        require(len(raw) == before.st_size)
        require(fingerprint(before) == fingerprint(os.fstat(f)) and
                fingerprint(before) == fingerprint(os.stat(name, dir_fd=fd, follow_symlinks=False)))
        return raw
    finally:
        os.close(f)

def root_ancestors(path):
    """Admit each fixed remote ancestor; retain fds through the operation."""
    require(path.is_absolute() and path.resolve() == path)
    handles = []
    try:
        for item in reversed(path.parents):
            s = item.lstat()
            data_exception = (path == Path('/data/baton-private-contact') and item == Path('/data') and
                              (s.st_uid, s.st_gid, stat.S_IMODE(s.st_mode)) == (1000, 1000, 0o755))
            require(stat.S_ISDIR(s.st_mode) and
                    (data_exception or (s.st_uid == 0 and not stat.S_IMODE(s.st_mode) & 0o022)))
            fd = os.open(item, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            require(fingerprint(s) == fingerprint(os.fstat(fd)))
            handles.append((item, fd, s))
        return handles
    except BaseException:
        for _, fd, _ in handles:
            os.close(fd)
        raise

def parse_fields(raw, progress=None):
    require(len(raw) <= 16384 and b'\0' not in raw)
    values = {}
    for line in raw.decode('utf-8').splitlines():
        # Only recognize these four assignment prefixes. Never parse other values.
        match = re.match(r'^\s*(?:export\s+)?(' + '|'.join(FIELDS) + r')\s*=', line)
        if not match:
            continue
        key = match.group(1)
        role = FIELD_ROLES[key]
        stage(progress, 'config-' + role + '-duplicate')
        require(key not in values)
        stage(progress, 'config-' + role + '-literal')
        value = line[match.end():].strip()
        if len(value) >= 2 and value[0] in "\"'" and value[-1] == value[0]:
            quote = value[0]
            value = value[1:-1]
            require(quote not in value)
        else:
            require(re.fullmatch(r'[A-Za-z0-9_.@+:/=~\-]+', value) is not None)
        # Unsupported expansion/escape syntax refuses; it is never interpreted.
        require(0 < len(value) <= 4096 and not any(c in value for c in '$`\\') and
                all(32 <= ord(c) < 127 for c in value))
        values[key] = value
    for key in FIELDS:
        stage(progress, 'config-' + FIELD_ROLES[key] + '-missing')
        require(key in values)
    for key in FIELDS[:2]:
        stage(progress, 'config-' + FIELD_ROLES[key] + '-identifier')
        require(UUID.fullmatch(values[key]))
    user = values['ONEDRIVE_BACKUP_USER']
    stage(progress, 'config-user-identifier')
    require(valid_user(user))
    return values

def valid_user(user):
    return bool(UUID.fullmatch(user) or re.fullmatch(r'[A-Za-z0-9_.+\-]+@[A-Za-z0-9](?:[A-Za-z0-9.\-]*[A-Za-z0-9])?', user))

def config_fields(progress=None, *, expected_group_gid=None):
    import grp
    path = Path('/etc')
    stage(progress, 'config-ancestors')
    handles = root_ancestors(path)
    fd = None
    try:
        before = path.lstat()
        require(before.st_uid == 0 and not stat.S_IMODE(before.st_mode) & 0o022)
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        require(fingerprint(before) == fingerprint(os.fstat(fd)))
        # 0640 is root:anatoli; 0600 permits the stricter root-only group.
        stage(progress, 'config-file-admission')
        s = os.stat('offsite-backup.env', dir_fd=fd, follow_symlinks=False)
        # Container group names do not establish host-file custody. The job
        # supplies the exact numeric GID from its separately admitted manifest;
        # the original reader's default name lookup remains available.
        require(expected_group_gid is None or type(expected_group_gid) is int and 0 <= expected_group_gid <= 2**32 - 2)
        anatoli_gid = grp.getgrnam('anatoli').gr_gid if expected_group_gid is None else expected_group_gid
        gids = {anatoli_gid} if stat.S_IMODE(s.st_mode) == 0o640 else {0, anatoli_gid}
        raw = read_protected(fd, 'offsite-backup.env', 0, gids, {0o600, 0o640}, 16384)
        stage(progress, 'config-literal-parser')
        values = parse_fields(raw, progress)
        stage(progress, 'config-stability')
        stable_directory(path, fd, before)
        return values
    finally:
        if fd is not None:
            os.close(fd)
        for item, handle, s in handles:
            try:
                stable_directory(item, handle, s)
            finally:
                os.close(handle)


def encoded(value):
    require(type(value) is str and OPAQUE.fullmatch(value))
    return urllib.parse.quote(value, safe='')


def microsoft_url(url, purpose):
    require(type(url) is str and 0 < len(url) <= 16384 and all(33 <= ord(c) < 127 for c in url))
    parts = urllib.parse.urlsplit(url)
    require(parts.scheme == 'https' and not parts.username and not parts.password
            and parts.port is None and not parts.fragment and parts.path.startswith('/'))
    host = parts.hostname
    require(host and re.fullmatch(r'[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?', host))
    allowed = (host.endswith('.sharepoint.com') or
               host.endswith('.files.1drv.com') if purpose == 'download' else
               host.endswith('.sharepoint.com') or host.endswith('.up.1drv.com'))
    require(allowed and '..' not in host)
    return host, parts.path + ('?' + parts.query if parts.query else '')


class HTTPS:
    """One direct request. No redirects, proxy, retry, cookie or error disclosure."""
    def __init__(self, deadline):
        self.deadline = deadline
        self.attempted = 0
        self.completed = 0

    def request(self, method, url, body, headers, accepted, limit):
        require(self.deadline > time.monotonic() and 0 <= limit <= LIMIT + 65536)
        parts = urllib.parse.urlsplit(url)
        require(parts.scheme == 'https' and not parts.username and not parts.password
                and parts.port is None and not parts.fragment)
        require(parts.hostname in ('login.microsoftonline.com', 'graph.microsoft.com') or
                microsoft_url(url, 'download' if method == 'GET' else 'upload'))
        if parts.hostname not in ('login.microsoftonline.com', 'graph.microsoft.com'):
            require(not any(key.lower() == 'authorization' for key in headers))
        connection = http.client.HTTPSConnection(parts.hostname,
            timeout=min(10, self.deadline-time.monotonic()), context=ssl.create_default_context())
        self.attempted += 1
        try:
            path = parts.path + ('?' + parts.query if parts.query else '')
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            require(response.status in accepted)
            length = response.getheader('Content-Length')
            require(length is None or length.isdigit() and int(length) <= limit)
            data = bytearray()
            while len(data) <= limit:
                require(time.monotonic() < self.deadline)
                connection.sock.settimeout(min(10, self.deadline-time.monotonic())) if connection.sock else None
                chunk = response.read(min(65536, limit + 1 - len(data)))
                if not chunk:
                    break
                data.extend(chunk)
            require(len(data) <= limit and (length is None or len(data) == int(length)))
            self.completed += 1
            return response.status, bytes(data)
        finally:
            connection.close()


class OneDrive:
    def __init__(self, fields, http):
        self.http = http
        self.user = urllib.parse.quote(fields['ONEDRIVE_BACKUP_USER'], safe='')
        form = urllib.parse.urlencode({'client_id': fields['M365_CLIENT_ID'],
            'client_secret': fields['M365_CLIENT_SECRET'], 'scope': 'https://graph.microsoft.com/.default',
            'grant_type': 'client_credentials'}).encode()
        status, raw = http.request('POST', 'https://login.microsoftonline.com/' + fields['M365_TENANT_ID'] + '/oauth2/v2.0/token',
            form, {'Content-Type': 'application/x-www-form-urlencoded'}, {200}, 65536)
        token = decode_json(raw).get('access_token')
        require(type(token) is str and 0 < len(token) <= 32768 and all(33 <= ord(c) < 127 for c in token))
        self.headers = {'Authorization': 'Bearer ' + token}
        self.drive = self.folder = None

    def graph(self, method, path, body=None, accepted=frozenset({200}), limit=65536, headers=None):
        require(path.startswith('/v1.0/') and len(path) <= 4096 and '#' not in path)
        return self.http.request(method, GRAPH + path, body,
            dict(self.headers, **(headers or {})), accepted, limit)

    def root_metadata(self, name):
        require(name in ('Backups', 'Backups/' + NAMESPACE))
        status, raw = self.graph('GET', '/v1.0/users/' + self.user + '/drive/root:/' + name + '?$select=id,name,folder,parentReference', accepted={200, 404})
        return None if status == 404 else decode_json(raw)

    @staticmethod
    def folder_meta(value, name):
        require(type(value) is dict and value.get('name') == name and type(value.get('folder')) is dict)
        encoded(value.get('id'))
        parent = value.get('parentReference')
        require(type(parent) is dict)
        encoded(parent.get('driveId'))
        return value['id'], parent['driveId']

    def namespace(self, create):
        parent = self.root_metadata('Backups')
        require(parent is not None)
        parent_id, drive = self.folder_meta(parent, 'Backups')
        value = self.root_metadata('Backups/' + NAMESPACE)
        if value is None:
            require(create)
            body = json.dumps({'name': NAMESPACE, 'folder': {}, '@microsoft.graph.conflictBehavior': 'fail'}).encode()
            status, raw = self.graph('POST', '/v1.0/drives/' + encoded(drive) + '/items/' + encoded(parent_id) + '/children',
                body, accepted={201}, headers={'Content-Type': 'application/json'})
            value = decode_json(raw)
        folder, selected_drive = self.folder_meta(value, NAMESPACE)
        require(selected_drive == drive and value['parentReference'].get('id') == parent_id)
        self.drive, self.folder = drive, folder
        status, raw = self.graph('GET', self.item(folder) + '?$select=id,name,folder,parentReference')
        checked = decode_json(raw)
        require(self.folder_meta(checked, NAMESPACE) == (folder, drive) and checked['parentReference'].get('id') == parent_id)
        return dict(drive=drive, folder=folder)

    def item(self, item_id):
        require(self.drive and self.folder)
        return '/v1.0/drives/' + encoded(self.drive) + '/items/' + encoded(item_id)

    def file_meta(self, value, name):
        require(type(value) is dict and NAME.fullmatch(name) and value.get('name') == name
                and type(value.get('file')) is dict and type(value.get('size')) is int
                and 28 <= value['size'] <= LIMIT + 28)
        item_id = value.get('id')
        encoded(item_id)
        parent = value.get('parentReference')
        require(type(parent) is dict and parent.get('driveId') == self.drive and parent.get('id') == self.folder)
        tag = value.get('eTag')
        require(type(tag) is str and 0 < len(tag) <= 1024 and all(32 <= ord(c) < 127 for c in tag))
        return dict(id=item_id, name=name, size=value['size'], etag=tag, drive=self.drive, folder=self.folder)

    def listing(self):
        prefix = self.item(self.folder) + '/children'
        path = prefix + '?$select=id,name,size,eTag,parentReference,file&$top=200'
        rows, ids = {}, set()
        for _ in range(100):
            status, raw = self.graph('GET', path, limit=1024 * 1024)
            value = decode_json(raw)
            require(type(value) is dict and type(value.get('value')) is list)
            for row in value['value']:
                require(type(row) is dict and type(row.get('name')) is str and len(rows) < 10000)
                # Unknown siblings are retained and never opened/deleted.
                if not NAME.fullmatch(row['name']):
                    continue
                checked = self.file_meta(row, row['name'])
                require(checked['name'] not in rows and checked['id'] not in ids)
                rows[checked['name']] = checked
                ids.add(checked['id'])
            link = value.get('@odata.nextLink')
            if link is None:
                return rows
            require(type(link) is str)
            parts = urllib.parse.urlsplit(link)
            require(parts.scheme == 'https' and parts.netloc == 'graph.microsoft.com' and not parts.fragment
                    and parts.path == prefix and 0 < len(parts.query) <= 2048)
            query = urllib.parse.parse_qs(parts.query, keep_blank_values=True)
            require(set(query) <= {'$skiptoken', '$select', '$top'} and '$skiptoken' in query
                    and all(len(values) == 1 for values in query.values()))
            path = parts.path + '?' + parts.query
        require(False)

    def upload(self, name, sealed):
        require(NAME.fullmatch(name) and type(sealed) is bytes and 28 <= len(sealed) <= LIMIT + 28)
        # Session conflictBehavior=fail is documented. Avoid PUT's default replace
        # semantics and never include Graph bearer on preauthenticated upload URL.
        path = self.item(self.folder) + ':/' + name + ':/createUploadSession'
        body = json.dumps({'item': {'@microsoft.graph.conflictBehavior': 'fail', 'name': name}}).encode()
        status, raw = self.graph('POST', path, body, headers={'Content-Type': 'application/json'})
        url = decode_json(raw).get('uploadUrl')
        microsoft_url(url, 'upload')
        status, raw = self.http.request('PUT', url, sealed,
            {'Content-Length': str(len(sealed)), 'Content-Range': 'bytes 0-' + str(len(sealed)-1) + '/' + str(len(sealed))}, {201}, 65536)
        return self.file_meta(decode_json(raw), name)

    def metadata(self, binding):
        status, raw = self.graph('GET', self.item(binding['id']) + '?$select=id,name,size,eTag,parentReference,file,@microsoft.graph.downloadUrl')
        value = decode_json(raw)
        require(self.file_meta(value, binding['name']) == binding)
        return value

    def download(self, binding):
        value = self.metadata(binding)
        url = value.get('@microsoft.graph.downloadUrl')
        microsoft_url(url, 'download')
        status, raw = self.http.request('GET', url, None, {}, {200}, binding['size'])
        require(len(raw) == binding['size'])
        return raw

    def permanent_delete(self, binding):
        self.metadata(binding)  # exact namespace, ID, tag and size rechecked
        status, raw = self.graph('POST', self.item(binding['id']) + '/permanentDelete',
            accepted={204}, headers={'Accept': 'application/json'})
        require(raw == b'')
        status, raw = self.graph('GET', self.item(binding['id']) + '?$select=id', accepted={404})
        return True
