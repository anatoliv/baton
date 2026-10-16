#!/usr/bin/env python3
"""Independent synthetic MP3/BSH1 fixture only; no app, server or network launch."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / 'specs/share-crypto'))
from make_vectors import b64u, seal
from make_mixtape_vectors import derive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    root = Path(args.output).resolve()
    if root.parent != Path('/private/tmp') or root.exists():
        parser.error('Requires a fresh direct /private/tmp fixture directory')
    os.umask(0o077); root.mkdir(mode=0o700)
    key = secrets.token_bytes(16); tracks = []; blobs = {}; codec = []
    # Public expectations are independent constants, not derived from native output.
    for index, (seconds, frequency, title) in enumerate([
            (35, 330, 'Long synthetic MP3'), (2, 660, 'Short synthetic MP3')]):
        encoded = subprocess.run(['ffmpeg', '-nostdin', '-loglevel', 'error', '-f', 'lavfi',
            '-i', 'sine=frequency=%s:duration=%s' % (frequency, seconds),
            '-c:a', 'libmp3lame', '-b:a', '96k', '-f', 'mp3', 'pipe:1'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15, check=True).stdout
        decoded = subprocess.run(['ffmpeg', '-nostdin', '-loglevel', 'error', '-f', 'mp3',
            '-i', 'pipe:0', '-ac', '1', '-ar', '8000', '-f', 's16le', 'pipe:1'],
            input=encoded, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15, check=True).stdout
        duration = len(decoded) / 16000
        if not seconds <= duration <= seconds + .2:
            raise RuntimeError('Synthetic decoded MP3 duration outside fixed tolerance')
        raw_id = bytes(range(16 + 16 * index, 32 + 16 * index)); identifier = b64u(raw_id)
        encrypted = seal(derive(key, b'baton-share mixtape v1 track\0' + raw_id),
                         'audio', secrets.token_bytes(12), 65536, encoded)
        blobs[identifier] = base64.b64encode(encrypted).decode()
        tracks.append({'id':identifier, 'metadata':{'title':title, 'artist':'Synthetic fixture',
            'durationSeconds':seconds}, 'audioBytes':len(encrypted),
            'audioSHA256':hashlib.sha256(encrypted).hexdigest()})
        codec.append({'title':title, 'declaredSeconds':seconds,
            'decodedSeconds':duration, 'encodedBytes':len(encoded),
            'plaintextSHA256':hashlib.sha256(encoded).hexdigest()})
    manifest = {'schema':'baton-mixtape-1', 'title':'Independent native MP3 fixture',
                'tracks':list(reversed(tracks))}
    encrypted_manifest = seal(derive(key, b'baton-share mixtape v1 manifest'), 'meta',
        secrets.token_bytes(12), 65536, json.dumps(manifest,separators=(',',':')).encode())
    result = {'schema':'baton-native-mixtape-media-fixture-1', 'rootKey':b64u(key),
        'containerID':b64u(bytes(range(48,64))), 'publicShare':{'schema':'baton-mixtape-1',
        'status':'ready','encryptedManifest':base64.b64encode(encrypted_manifest).decode(),
        'tracks':{t['id']:{'audioBytes':t['audioBytes'],'audioSHA256':t['audioSHA256']} for t in tracks},
        'expiresAt':'2099-01-01T00:00:00Z','remainingPlays':2}, 'blobs':blobs,
        'expected':{'orderedTitles':['Short synthetic MP3','Long synthetic MP3'],
            'declaredDurations':[2,35], 'firstSessionEvents':{'play_started':1,'play_30s':1,'play_completed':1},
            'renewedSessionBeforeAllTracksEvents':{'play_started':1,'play_30s':0,'play_completed':0}},
        'codecFacts':codec}
    path = root/'media.json'
    with os.fdopen(os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600),'w') as stream:
        json.dump(result,stream,separators=(',',':'));stream.write('\n')
    # No plaintext audio files, key, fragment or session authority is printed.
    print(json.dumps({'tracks':2,'declaredSeconds':[35,2],'decodedSeconds':[c['decodedSeconds'] for c in codec],
        'mediaFileSHA256':hashlib.sha256(path.read_bytes()).hexdigest(),'mediaFileMode':path.stat().st_mode & 0o777}))


if __name__ == '__main__': main()
