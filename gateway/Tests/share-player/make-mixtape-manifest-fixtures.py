#!/usr/bin/env python3
"""Independent Python BSH1/HKDF fixture generation; does not use browser code."""
from pathlib import Path
import sys, json, base64, copy
repo = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(repo / 'specs/share-crypto'))
from make_vectors import seal, b64u
from make_mixtape_vectors import derive
vectors = json.loads((repo / 'specs/share-crypto/mixtape-vectors.json').read_text())
root = bytes(range(16))
tracks = []
for v in reversed(vectors['positive'][:2]):
    tracks.append({'id': v['trackID'], 'metadata': {'title': 'Second' if not tracks else 'First', 'durationSeconds': 10},
                   'audioBytes': len(base64.b64decode(v['ciphertext'])), 'audioSHA256': v['ciphertextSHA256']})
manifest = {'schema': 'baton-mixtape-1', 'title': 'Independent ordered fixture', 'tracks': tracks}
def fixture(value):
    encrypted = seal(derive(root, b'baton-share mixtape v1 manifest'), 'meta', bytes(range(12,24)), 1024, json.dumps(value, separators=(',', ':')).encode())
    return {'schema': 'baton-mixtape-1', 'encryptedManifest': base64.b64encode(encrypted).decode(),
            'tracks': {t['id']: {'audioBytes': t['audioBytes'], 'audioSHA256': t['audioSHA256']} for t in value['tracks']}}
maximum = copy.deepcopy(manifest)
maximum['tracks'] = [dict(copy.deepcopy(tracks[i % 2]), id=b64u(bytes([i + 1]) * 16)) for i in range(12)]
fixtures = {'rootKey': b64u(root), 'valid': fixture(manifest), 'maximum': fixture(maximum), 'invalid': {}}
for name in ['duplicate', 'one', 'thirteen', 'duration', 'metadata', 'size']:
    m = copy.deepcopy(manifest)
    if name == 'duplicate': m['tracks'][1]['id'] = m['tracks'][0]['id']
    if name == 'one': m['tracks'] = m['tracks'][:1]
    if name == 'thirteen': m['tracks'] = m['tracks'] * 6 + m['tracks'][:1]
    if name == 'duration': m['tracks'][0]['metadata']['durationSeconds'] = 1200
    if name == 'metadata': m['tracks'][0]['metadata']['title'] = 'bad\x01title'
    if name == 'size': m['tracks'][0]['audioBytes'] = 26214401
    fixtures['invalid'][name] = fixture(m)
Path(__file__).with_name('mixtape-manifest-fixtures.json').write_text(json.dumps(fixtures, indent=2) + '\n')
