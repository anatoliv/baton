#!/usr/bin/env python3
"""Local synthetic media fixture; independent Python crypto, no browser encryption."""
import sys, json, base64, hashlib, subprocess, os
from pathlib import Path
repo = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(repo / 'specs/share-crypto'))
from make_vectors import b64u, seal
from make_mixtape_vectors import derive
root = Path(sys.argv[1]).resolve()
if not str(root).startswith('/private/tmp/') or root.exists():
    raise SystemExit('requires new /private/tmp fixture directory')
root.mkdir(mode=0o700)
key = bytes(range(16)); tracks = []; blobs = {}
for i, frequency in enumerate([330, 660]):
    path = root / f'track-{i}.mp3'
    subprocess.run(['ffmpeg', '-loglevel', 'error', '-f', 'lavfi', '-i', f'sine=frequency={frequency}:duration=18', '-c:a', 'libmp3lame', '-b:a', '96k', str(path)], check=True)
    track_id = bytes(range(16 + i * 16, 32 + i * 16)); identifier = b64u(track_id)
    encrypted = seal(derive(key, b'baton-share mixtape v1 track\0' + track_id), 'audio', bytes(range(i * 12, i * 12 + 12)), 65536, path.read_bytes())
    blobs[identifier] = base64.b64encode(encrypted).decode()
    tracks.append({'id': identifier, 'metadata': {'title': ['First synthetic', 'Second synthetic'][i], 'artist': 'Fixture', 'durationSeconds': 18},
                   'audioBytes': len(encrypted), 'audioSHA256': hashlib.sha256(encrypted).hexdigest()})
# Deliberately reverse insertion order: authenticated order is not the public map order.
manifest = {'schema': 'baton-mixtape-1', 'title': 'Ordered synthetic mixtape', 'tracks': list(reversed(tracks))}
encrypted = seal(derive(key, b'baton-share mixtape v1 manifest'), 'meta', bytes(range(24,36)), 65536, json.dumps(manifest, separators=(',', ':')).encode())
ordered = [{'id':t['id'], 'title':t['metadata']['title'], 'durationSeconds':18, 'plaintextFile':str(root / ('track-1.mp3' if t['metadata']['title'].startswith('Second') else 'track-0.mp3')), 'plaintextSHA256':hashlib.sha256((root / ('track-1.mp3' if t['metadata']['title'].startswith('Second') else 'track-0.mp3')).read_bytes()).hexdigest(), 'ciphertextSHA256':t['audioSHA256']} for t in manifest['tracks']]
result = {'orderedTracks':ordered, 'rootKey': b64u(key), 'encryptedManifest': base64.b64encode(encrypted).decode(), 'tracks': {t['id']: {'audioBytes': t['audioBytes'], 'audioSHA256': t['audioSHA256']} for t in tracks}, 'blobs': blobs}
path = root / 'material.json'
with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as f:
    json.dump(result, f)
print('synthetic material ready')
