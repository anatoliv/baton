"""Bounded completed-upload quota acceptance against the accepted offline AMD64 image.

Only synthetic public fixtures; no database queries, published ports, builds or live traffic.
Run with the bundled Python containing cryptography and a NEW /private/tmp output directory.
"""
import base64
import concurrent.futures
import hashlib
import json
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUTPUT = Path(sys.argv[1]).resolve()
if not str(OUTPUT).startswith('/private/tmp/') or OUTPUT.exists():
    raise SystemExit('requires a new disposable /private/tmp output directory')
OUTPUT.mkdir(mode=0o700)
sys.path.insert(0, str(ROOT / 'specs/share-crypto'))
from make_vectors import seal

SOURCE = '8a709bc33175f1e3ded788ef22ea070aa077aee4'
IMAGE = 'sha256:07c35879df1af2b2787c1907ce3291f110f1b1962ae8c380988bf500cc234521'
BINARY = '4fce2934ebe7ef8ef0525917d97de0ee8c3c323618d4f1795ffa637f269b0b97'
NAME = 'baton-tbx-9253-quota-' + uuid.uuid4().hex[:10]
# Public constants, never owner credentials or content.
OWNER = base64.urlsafe_b64encode(bytes(range(32))).rstrip(b'=').decode()
OTHER = base64.urlsafe_b64encode(bytes(range(32, 64))).rstrip(b'=').decode()
CIPHER = seal(bytes(range(16)), 'audio', bytes(range(12)), 65536,
              b'Synthetic completed upload.' * 50000)
ART = b'\xff\xd8\xff\xe0' + b'a' * 1020
QUOTA = 2 * len(CIPHER) + 1024
START = time.monotonic()
receipt = {'source': SOURCE, 'image': IMAGE, 'binarySHA256': BINARY,
           'ownerStateTouched': False, 'deployment': False, 'checks': [],
           'phases': [], 'publicFixture': {'ciphertextBytes': len(CIPHER),
           'ciphertextSHA256': hashlib.sha256(CIPHER).hexdigest(),
           'artBytes': 1024, 'quotaBytes': QUOTA, 'playableMedia': False}}
started = False


def invoke(args, **kwargs):
    return subprocess.run(args, check=True, timeout=min(30, max(.1, 180 - (time.monotonic() - START))),
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)


def check(name, passed):
    receipt['checks'].append({'name': name, 'passed': bool(passed)})
    assert passed, name


def request(path, method='GET', body=None, owner=None, barrier=None):
    token = uuid.uuid4().hex
    if isinstance(body, dict):
        body = json.dumps(body).encode()
    lines = ['url = ' + json.dumps('http://127.0.0.1:8790' + path),
             'request = ' + json.dumps(method)]
    if owner:
        lines.append('header = ' + json.dumps('Authorization: Bearer ' + owner))
    if body is not None:
        invoke(['docker', 'exec', '-i', NAME, 'sh', '-c',
                'umask 077; cat > /tmp/' + token + '.body'], input=body)
        lines += ['header = "Content-Type: application/octet-stream"',
                  'data-binary = "@/tmp/' + token + '.body"']
    if barrier:
        barrier.wait(timeout=10)
    before = time.monotonic()
    result = invoke(['docker', 'exec', '-i', NAME, 'curl', '--silent', '--show-error',
                     '--max-time', '10', '--limit-rate', '5M', '--dump-header',
                     '/tmp/' + token + '.headers', '--output', '/tmp/' + token + '.response',
                     '--write-out', '%{http_code}', '--config', '-'],
                    input=('\n'.join(lines) + '\n').encode())
    after = time.monotonic()
    value = invoke(['docker', 'exec', NAME, 'cat', '/tmp/' + token + '.response']).stdout
    headers = invoke(['docker', 'exec', NAME, 'cat', '/tmp/' + token + '.headers']).stdout.decode()
    return {'status': int(result.stdout), 'body': value, 'headers': headers,
            'start': before - START, 'end': after - START}


def parallel(name, calls):
    barrier = threading.Barrier(len(calls))
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(calls)) as pool:
        futures = [pool.submit(request, barrier=barrier, **call) for call in calls]
        results = [f.result(timeout=30) for f in futures]
    receipt['phases'].append({'name': name, 'requests': [
        {k: r[k] for k in ['status', 'start', 'end']} for r in results],
        'allRequestsOverlap': max(r['start'] for r in results) < min(r['end'] for r in results)})
    assert receipt['phases'][-1]['allRequestsOverlap'], 'requests did not overlap'
    return results


def create_body():
    return {'expiresInSeconds': 86400, 'playCap': 20,
            'preview': {'title': 'Synthetic quota acceptance', 'durationSeconds': 1},
            'audioBytes': len(CIPHER), 'audioSHA256': hashlib.sha256(CIPHER).hexdigest(),
            'client': {'platform': 'macos', 'appVersion': 'synthetic'}}


try:
    unchanged = invoke(['git', '-C', str(ROOT), 'diff', SOURCE, '--', 'gateway/Sources',
                        'Packages/BatonShareKit', 'gateway/Package.swift', 'gateway/Package.resolved']).stdout
    assert unchanged == b'', 'source differs from accepted image'
    invoke(['docker', 'run', '-d', '--platform', 'linux/amd64', '--name', NAME,
            '--cpus=2', '--memory=1g', '--memory-swap=1g', '--network', 'none',
            '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true',
            '--tmpfs', '/var/lib/baton-share:rw,uid=10001,gid=10001,mode=0700',
            '--tmpfs', '/tmp:rw,uid=10001,gid=10001,mode=0700',
            '-e', 'BATON_SHARE_BIND=127.0.0.1',
            '-e', 'BATON_SHARE_PUBLIC_BASE=http://127.0.0.1:8790',
            '-e', 'BATON_SHARE_BLOB_DELIVERY=direct',
            '-e', 'BATON_SHARE_QUOTA_BYTES=' + str(QUOTA), IMAGE])
    started = True
    for _ in range(40):
        try:
            if request('/health')['status'] == 200:
                break
        except (subprocess.CalledProcessError, ValueError):
            time.sleep(.1)
    else:
        raise RuntimeError('runtime readiness deadline')
    actual_binary = invoke(['docker', 'exec', NAME, 'sha256sum', '/usr/local/bin/baton-share']).stdout.decode().split()[0]
    assert actual_binary == BINARY
    receipt['sourceAndArtifactMatched'] = True

    created = parallel('complete competing creates', [
        {'path': '/v1/share/shares', 'method': 'POST', 'body': create_body(), 'owner': OWNER}
        for _ in range(3)])
    check('three completed creates admit exactly two durable audio reservations',
          sorted(r['status'] for r in created) == [201, 201, 503])
    shares = [json.loads(r['body']) for r in created if r['status'] == 201]
    refused = next(r for r in created if r['status'] == 503)
    assert json.loads(refused['body'])['code'] == 'busy'

    damaged = CIPHER[:-1] + bytes([CIPHER[-1] ^ 1])
    response = request(shares[0]['uploads']['audio'], 'PUT', damaged, OWNER)
    check('completed corrupt upload returns checksum422 without adopting bytes',
          response['status'] == 422 and json.loads(response['body'])['code'] == 'checksum')
    response = request(shares[0]['uploads']['audio'], 'PUT', CIPHER, OTHER)
    check('foreign owner cannot consume another reservation or reveal its share', response['status'] == 404)

    uploads = parallel('complete duplicate audio uploads', [
        {'path': share['uploads']['audio'], 'method': 'PUT', 'body': CIPHER, 'owner': OWNER}
        for share in shares for _ in range(2)])
    check('completed duplicate audio uploads adopt each reservation exactly once',
          sorted(r['status'] for r in uploads) == [200, 200, 409, 409])
    art = parallel('complete artwork competing for last1024bytes', [
        {'path': share['uploads']['art'], 'method': 'PUT', 'body': ART, 'owner': OWNER}
        for share in shares])
    check('two completed artwork uploads admit exactly one at quota boundary',
          sorted(r['status'] for r in art) == [200, 503] and
          json.loads(next(r['body'] for r in art if r['status'] == 503))['code'] == 'busy')
    winner = shares[next(i for i, r in enumerate(art) if r['status'] == 200)]
    loser = shares[next(i for i, r in enumerate(art) if r['status'] == 503)]
    fresh = request('/v1/share/p/' + loser['id'])
    check('quota-refused artwork stays absent in fresh public metadata',
          fresh['status'] == 200 and json.loads(fresh['body'])['hasArt'] is False)
    finalize = request('/v1/share/shares/' + winner['id'] + '/finalize', 'POST', owner=OWNER)
    audio = request('/v1/share/p/' + winner['id'] + '/audio')
    image = request('/v1/share/p/' + winner['id'] + '/art')
    check('winning completed material finalizes and reads back exact ciphertext privately',
          finalize['status'] == 200 and audio['status'] == 200 and audio['body'] == CIPHER and
          'cache-control: private, no-store' in audio['headers'].lower() and image['status'] == 200 and image['body'] == ART)
    response = request('/v1/share/shares', 'POST', create_body(), OWNER)
    check('completed material preserves exactly full quota rather than freeing promises', response['status'] == 503)
    response = request('/v1/share/shares/' + winner['id'], 'DELETE', owner=OWNER)
    ended = request('/v1/share/p/' + winner['id'] + '/audio')
    check('revoke closes accepted public audio and releases its quota',
          response['status'] == 204 and ended['status'] == 410 and json.loads(ended['body'])['code'] == 'expired')
    retried = request(loser['uploads']['art'], 'PUT', ART, OWNER)
    finalized = request('/v1/share/shares/' + loser['id'] + '/finalize', 'POST', owner=OWNER)
    audio = request('/v1/share/p/' + loser['id'] + '/audio')
    image = request('/v1/share/p/' + loser['id'] + '/art')
    check('refused artwork retry succeeds after revoke and preserves original audio',
          retried['status'] == 200 and finalized['status'] == 200 and
          audio['status'] == 200 and audio['body'] == CIPHER and image['status'] == 200 and image['body'] == ART)
    listed = request('/v1/share/shares', owner=OWNER)
    statuses = sorted(s['status'] for s in json.loads(listed['body'])['shares'])
    check('fresh owner list reconciles ready and revoked completed workflows', listed['status'] == 200 and statuses == ['ready', 'revoked'])
    metrics = invoke(['docker', 'exec', NAME, 'sh', '-c',
                      "awk '/^(VmRSS|VmHWM|Threads):/{print}' /proc/1/status; cat /sys/fs/cgroup/memory.peak; cat /sys/fs/cgroup/memory.events"]).stdout.decode()
    receipt['allowlistedResourceMetrics'] = metrics
    check('completed handlers leave no owned staging files and health remains available',
          invoke(['docker', 'exec', NAME, 'sh', '-c', 'find /var/lib/baton-share/staging -type f | wc -l']).stdout.strip() == b'0' and
          request('/health')['status'] == 200)
except Exception as error:
    receipt['failure'] = type(error).__name__ + ': ' + str(error)
finally:
    if started:
        subprocess.run(['docker', 'stop', '-t', '2', NAME], timeout=10,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        fmt = '{"status":{{json .State.Status}},"exitCode":{{json .State.ExitCode}},"oomKilled":{{json .State.OOMKilled}},"ports":{{json .HostConfig.PortBindings}},"network":{{json .HostConfig.NetworkMode}},"memory":{{json .HostConfig.Memory}},"nanoCPUs":{{json .HostConfig.NanoCpus}}}'
        receipt['finalContainer'] = json.loads(invoke(['docker', 'inspect', '--format', fmt, NAME]).stdout)
        receipt['syntheticTmpfsReleased'] = receipt['finalContainer']['status'] == 'exited'
    receipt['containerName'] = NAME
    receipt['elapsedSeconds'] = time.monotonic() - START
    receipt['counts'] = {'executed': len(receipt['checks']), 'passed': sum(c['passed'] for c in receipt['checks']),
                         'failed': sum(not c['passed'] for c in receipt['checks']), 'skipped': 0}
    (OUTPUT / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))
raise SystemExit(1 if 'failure' in receipt else 0)
