"""Required single-song composition check through the production entrypoint, on loopback only.

Usage: python3 single-song-capacity.py REPO BINARY NEW_OUTPUT_DIR SOURCE_PIN
No feature fixture, external service, owner configuration, or deadline rerun is used.
"""
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import tempfile
import time

repo, binary = Path(sys.argv[1]), Path(sys.argv[2])
output = Path(sys.argv[3]).resolve()
pin = sys.argv[4]
if output.exists() or not str(output).startswith('/private/tmp/'):
    raise SystemExit('requires a new disposable /private/tmp output')
output.mkdir(mode=0o700)
work = Path(tempfile.mkdtemp(prefix='baton-single-capacity-', dir='/private/tmp'))
os.chmod(work, 0o700)
with socket.socket() as chooser:
    chooser.bind(('127.0.0.1', 0))
    port = chooser.getsockname()[1]
process = None
peers = []
secret = 'AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM'
receipt = {'sourcePin': pin, 'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
           'productionEntrypoint': True, 'ownerStateTouched': False, 'checks': [],
           'ownedDirectory': str(work), 'ownedPort': port}


def check(name, passed):
    receipt['checks'].append({'name': name, 'passed': bool(passed)})
    assert passed, name


def request(method, path, body=None, owner=False):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
    try:
        headers = {'Authorization': 'Bearer ' + secret} if owner else {}
        if isinstance(body, dict):
            body = json.dumps(body).encode()
            headers['Content-Type'] = 'application/json'
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        return response.status, dict(response.getheaders()), response.read()
    finally:
        connection.close()


def connect(path, declared=None):
    peer = socket.socket()
    peer.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    peer.settimeout(10)
    peer.connect(('127.0.0.1', port))
    peers.append(peer)
    if declared is None:
        peer.sendall(f'GET {path} HTTP/1.1\r\nHost: localhost\r\n\r\n'.encode())
    else:
        peer.sendall(f'PUT {path} HTTP/1.1\r\nHost: localhost\r\nContent-Length: {declared}\r\n\r\nx'.encode())
    return peer


def head(peer):
    data = bytearray()
    while not data.endswith(b'\r\n\r\n') and len(data) < 16384:
        byte = peer.recv(1)
        if not byte:
            break
        data += byte
    lines = bytes(data).decode().split('\r\n')
    headers = dict(line.split(': ', 1) for line in lines[1:] if ': ' in line)
    return int(lines[0].split(' ')[1]), headers


def wait_for(predicate, seconds=5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(.05)
    return False


def close(peers_to_close):
    for peer in peers_to_close:
        peer.close()


try:
    env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
           'BATON_SHARE_DATA': str(work / 'data'), 'BATON_SHARE_PORT': str(port),
           'BATON_SHARE_BIND': '127.0.0.1', 'BATON_SHARE_PUBLIC_BASE': f'http://127.0.0.1:{port}',
           'BATON_SHARE_BLOB_DELIVERY': 'direct'}
    process = subprocess.Popen([str(binary)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    receipt['ownedPID'] = process.pid
    for _ in range(100):
        try:
            if request('GET', '/health')[0] == 200:
                break
        except OSError:
            time.sleep(.05)
    else:
        raise RuntimeError('production entrypoint readiness deadline')

    spec = importlib.util.spec_from_file_location('independent_vectors', repo / 'specs/share-crypto/make_vectors.py')
    vectors = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(vectors)
    ciphertext = vectors.seal(bytes(range(16)), 'audio', bytes(range(12)), 65536, b'x' * (24 * 1024 * 1024))
    create = {'expiresInSeconds': 86400, 'playCap': 100,
              'preview': {'title': 'Single-song capacity', 'durationSeconds': 120},
              'audioBytes': len(ciphertext), 'audioSHA256': hashlib.sha256(ciphertext).hexdigest(),
              'client': {'platform': 'macos', 'appVersion': 'capacity-local'}}
    status, _, body = request('POST', '/v1/share/shares', create, owner=True)
    assert status == 201, 'create did not succeed'
    created = json.loads(body)
    share_id = created['id']
    audio_path = f'/v1/share/p/{share_id}/audio'
    uploaded = request('PUT', created['uploads']['audio'], ciphertext, owner=True)[0]
    finalized = request('POST', f'/v1/share/shares/{share_id}/finalize', owner=True)[0]
    check('production v1 create, streaming upload and finalize', uploaded == finalized == 200)
    receipt['ciphertextBytes'] = len(ciphertext)

    responses = [head(connect(audio_path)) for _ in range(6)]
    statuses = [status for status, _ in responses]
    stats = json.loads(request('GET', '/v1/share/shares', owner=True)[2])['shares'][0]['stats']
    receipt['slowReaders'] = {'statuses': statuses, 'fetches': stats['fetches']}
    check('six single-song slow readers admit two and refuse four before charging',
          statuses == [200, 200, 503, 503, 503, 503] and stats['fetches'] == 2)
    check('refusals carry bounded private retry response',
          all(headers.get('Cache-Control') == 'private, no-store' and headers.get('Retry-After') == '1'
              and int(headers['Content-Length']) < 1024 for status, headers in responses if status == 503))
    check('health, metadata and original HEAD method behavior survive occupied response slots',
          request('GET', '/health')[0] == 200 and request('GET', f'/v1/share/p/{share_id}')[0] == 200
          and request('HEAD', audio_path)[0] == 405)
    aliases = [f'//v1///share//p/{share_id}/audio?ignored=1', f'/v1/share/p/{share_id}/art',
               f'/v1/share/p/{share_id}/card']
    check('equivalent single-song routes and all blob kinds share admission',
          all(request('GET', path)[0] == 503 for path in aliases))

    staging = work / 'data/staging'
    upload_peers = [connect('/v1/share/shares/synthetic/audio', 25 * 1024 * 1024) for _ in range(12)]
    assert wait_for(lambda: len(list(staging.glob('upload-*'))) + len(select.select(upload_peers, [], [], 0)[0]) == 12)
    ready = select.select(upload_peers, [], [], 0)[0]
    refused = [head(peer)[0] for peer in ready]
    sizes = [file.stat().st_size for file in staging.glob('upload-*')]
    receipt['headerFirstStaging'] = {'accepted': len(sizes), 'refused': refused, 'actualStagedBytes': sum(sizes)}
    check('declared staging admission works alongside held single-song responses',
          len(sizes) == 10 and refused == [503, 503] and request('GET', '/health')[0] == 200)
    close(upload_peers)
    check('cancelled production uploads clear their staging files', wait_for(lambda: not list(staging.glob('upload-*'))))
    replacement = connect('/v1/share/shares/synthetic/audio', 25 * 1024 * 1024)
    check('cancelled production staging reservation is reusable',
          wait_for(lambda: len(list(staging.glob('upload-*'))) == 1) and not select.select([replacement], [], [], .1)[0])
    close([replacement])
    assert wait_for(lambda: not list(staging.glob('upload-*')))

    close(peers)
    # Closing the socket, not a 60-second timer, releases the large-response reservation.
    time.sleep(.2)
    status, headers, downloaded = request('GET', audio_path)
    stats = json.loads(request('GET', '/v1/share/shares', owner=True)[2])['shares'][0]['stats']
    check('disconnect releases admission and refused retry returns exact ciphertext with one charge',
          status == 200 and downloaded == ciphertext and headers.get('Cache-Control') == 'private, no-store'
          and stats['fetches'] == 3)
    revoked = request('DELETE', f'/v1/share/shares/{share_id}', owner=True)[0]
    status, _, body = request('GET', audio_path)
    check('single-song revoke still fences subsequent transfer', revoked == 204 and status == 410 and json.loads(body)['code'] == 'expired')
except Exception as error:
    receipt['error'] = str(error)
finally:
    close(peers)
    if process:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    receipt['ownedProcessExited'] = process is None or process.poll() is not None
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=.2):
            receipt['listenerClosed'] = False
    except OSError:
        receipt['listenerClosed'] = True
    receipt['remainingOwnedStagingFiles'] = len(list((work / 'data/staging').glob('upload-*')))
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))
    sys.exit(1 if 'error' in receipt else 0)
