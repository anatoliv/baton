"""Public create-only pending fixture from independently generated material."""
import base64
import hashlib
import re
import uuid
from mixtape_ui_control import ID, invitation


def pending_body(material):
    required = {'orderedTracks', 'rootKey', 'encryptedManifest', 'tracks', 'blobs'}
    if not isinstance(material, dict) or set(material) != required:
        raise ValueError('Reviewed independent material required')
    tracks, ordered = material['tracks'], material['orderedTracks']
    if not isinstance(tracks, dict) or not 2 <= len(tracks) <= 12 or len(ordered) != len(tracks):
        raise ValueError('Bounded ordered material required')
    if {track['id'] for track in ordered} != set(tracks) or len({track['id'] for track in ordered}) != len(ordered):
        raise ValueError('Independent authenticated order required')
    duration = 0
    for track in ordered:
        identifier = track['id']; descriptor = tracks[identifier]
        if not re.fullmatch(ID, identifier) or type(track['durationSeconds']) is not int or track['durationSeconds'] <= 0:
            raise ValueError('Valid generated track required')
        duration += track['durationSeconds']
        blob = base64.b64decode(material['blobs'][identifier], validate=True)
        if len(blob) != descriptor['audioBytes'] or hashlib.sha256(blob).hexdigest() != descriptor['audioSHA256']:
            raise ValueError('Generated ciphertext descriptor mismatch')
    if duration > 1200: raise ValueError('Bounded aggregate duration required')
    manifest = base64.b64decode(material['encryptedManifest'], validate=True)
    if not 80 <= len(manifest) <= 196_608: raise ValueError('Generated encrypted manifest required')
    return {'schema': 'baton-mixtape-1', 'requestID': str(uuid.uuid4()),
        'encryptedManifest': material['encryptedManifest'], 'tracks': tracks,
        'totalDurationSeconds': duration, 'expiresInSeconds': 86400, 'playCap': 100,
        'client': {'platform': 'macos', 'appVersion': 'synthetic-ui-pending'}}


def create_pending(material, backend, frontend, request):
    body = pending_body(material)
    created = request('POST', '/v1/share/mixtapes', body)
    if not isinstance(created, dict) or not re.fullmatch(ID, created.get('id', '')) or created.get('url') != backend + '/m/' + created['id']:
        raise ValueError('Canonical owned pending creation required')
    public = request('GET', '/v1/share/m/' + created['id'])
    if public.get('status') != 'pending' or public.get('encryptedManifest') != body['encryptedManifest'] or public.get('tracks') != body['tracks']:
        raise ValueError('Actual public pending state required')
    url = frontend + '/m/' + created['id'] + '#' + material['rootKey']
    invitation(url, frontend)
    # No upload/finalize route exists in this helper. Nothing is fabricated in
    # the service response, and neither authority nor fragments enter receipts.
    return url
