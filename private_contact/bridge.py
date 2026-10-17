"""Authenticated tickets and live share readback. No raw install bearer is stored."""
from __future__ import annotations

import base64
import hashlib
import hmac
import http.client
import json
import re
import secrets

from .service import Denied

PURPOSES = {'enroll', 'verify', 'withdraw', 'status', 'caseAccess'}


def signed(key: bytes, claims: dict) -> str:
    raw = json.dumps(claims, separators=(',', ':'), sort_keys=True).encode()
    payload = base64.urlsafe_b64encode(raw).decode().rstrip('=')
    signature = hmac.new(key, ('baton-contact-v1.' + payload).encode(), hashlib.sha256).hexdigest()
    return payload + '.' + signature


def admitted(key: bytes, ticket: str) -> dict:
    try:
        if not isinstance(ticket, str) or len(ticket) > 32768:
            raise ValueError()
        payload, signature = ticket.split('.')
        expected = hmac.new(key, ('baton-contact-v1.' + payload).encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(signature, expected):
            raise ValueError()
        result = json.loads(base64.urlsafe_b64decode(payload + '=' * (-len(payload) % 4)))
        if not isinstance(result, dict):
            raise ValueError()
        return result
    except Exception:
        raise Denied('unauthorized') from None


class KeyedSecrets:
    def __init__(self, key: bytes):
        if len(key) != 32:
            raise Denied('configuration')
        self.key = key
        self.production_ready = True

    def random(self) -> str:
        return secrets.token_urlsafe(24)

    def verifier(self, purpose: str, value: str) -> str:
        return hmac.new(self.key, (purpose + value).encode(), hashlib.sha256).hexdigest()


class ShareSource:
    """Read-only loopback source; the public process holds only reader's digest."""
    def __init__(self, *, port: int, reader: str):
        self.port, self.reader = port, reader

    def _read(self, route: str, payload: dict) -> dict:
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=4)
        try:
            connection.request('POST', '/v1/share/admin/contact/' + route, json.dumps(payload).encode(),
                               {'Content-Type': 'application/json', 'Authorization': 'Bearer ' + self.reader})
            response = connection.getresponse()
            raw = response.read(65537)
            if response.status != 200 or len(raw) > 65536:
                raise ValueError()
            result = json.loads(raw)
            if not isinstance(result, dict):
                raise ValueError()
            return result
        except Exception:
            raise Denied('sourceUnavailable') from None
        finally:
            connection.close()

    def installation(self, proof: str, purpose: str, now: int) -> dict:
        return self._read('installation', {'authorization': proof, 'purpose': purpose})

    def actions(self, after: str = '') -> dict:
        result = self._read('actions', {'after': after})
        if (set(result) != {'entries', 'next'} or not isinstance(result['entries'], list)
                or len(result['entries']) > 200 or result['next'] not in (None, '') and
                (not isinstance(result['next'], str) or not re.fullmatch(r'[a-f0-9-]{36}', result['next']))):
            raise Denied('sourceUnavailable')
        if result.get('next') == '':
            result['next'] = None
        for entry in result['entries']:
            if (not isinstance(entry, dict) or set(entry) != {'installation', 'case', 'operation', 'share', 'revision'}
                    or not all(isinstance(entry[key], str) for key in ('installation', 'case', 'operation', 'share'))
                    or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', entry['case'])
                    or not re.fullmatch(r'[a-f0-9-]{36}', entry['operation'])
                    or type(entry['revision']) is not int or entry['revision'] < 0
                    or entry['revision'] > 0 and (not re.fullmatch(r'[a-f0-9]{64}', entry['installation'])
                        or not re.fullmatch(r'[A-Za-z0-9_-]{22}', entry['share']))
                    or entry['revision'] == 0 and (entry['share'] or entry['installation'])):
                raise Denied('sourceUnavailable')
        return result

    def action(self, operation: str, share: str, now: int) -> dict:
        result = self._read('action', {'operation': operation, 'share': share})
        if (set(result) != {'installation', 'case', 'operation', 'share', 'created', 'revision', 'action'}
                or result['operation'] != operation or result['share'] != share
                or not isinstance(result['installation'], str) or not re.fullmatch(r'[a-f0-9]{64}', result['installation'])
                or type(result['revision']) is not int or result['revision'] < 1
                or type(result['created']) is not int or result['created'] > now
                or not isinstance(result['case'], str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', result['case'])
                or result['action'] not in {'disable-share', 'restore-share', 'suspend-sharer', 'unsuspend-sharer',
                                           'purge-disabled-share', 'review-preservation'}):
            raise Denied('sourceUnavailable')
        return result


class BridgeAuthority:
    """Replay consumption and reviewed cases live in separate authoritative custody."""
    def __init__(self, *, key: bytes, ledger, source, recipient):
        self.key, self.ledger, self.source, self.recipient = key, ledger, source, recipient
        self.production_ready = True
        self.coverage = {}

    def installation(self, proof: str, purpose: str, now: int) -> str | None:
        try:
            if (purpose not in PURPOSES or not isinstance(proof, str)
                    or not re.fullmatch(r'[A-Za-z0-9_-]{43}', proof)):
                return None
            claims = self.source.installation(proof, purpose, now)
            if (set(claims) != {'installation', 'shares', 'issued', 'expires'} or not isinstance(claims['installation'], str)
                    or not re.fullmatch(r'[a-f0-9]{64}', claims['installation'])
                    or type(claims['issued']) is not int or type(claims['expires']) is not int
                    or claims['expires'] != claims['issued'] + 60 or not claims['issued'] <= now < claims['expires']
                    or not isinstance(claims['shares'], list) or len(claims['shares']) > 200
                    or any(not isinstance(share, str) or not re.fullmatch(r'[A-Za-z0-9_-]{22}', share)
                           for share in claims['shares'])):
                return None
            nonce = hmac.new(self.key, ('grant:' + proof).encode(), hashlib.sha256).hexdigest()
            def consume(state):
                state = state or {'replays': {}, 'cases': {}}
                state['replays'] = {value: expiry for value, expiry in state['replays'].items() if expiry > now}
                if nonce in state['replays'] or len(state['replays']) >= 10000:
                    return False, state
                state['replays'][nonce] = now + 120
                return True, state
            if not self.ledger.transact(consume):
                return None
            self.coverage[nonce] = (claims['shares'], now + 60)
            self.coverage = {value: item for value, item in self.coverage.items() if item[1] > now}
            return self.handle(claims['installation'])
        except Exception:
            return None

    def handle(self, digest: str) -> str:
        return hmac.new(self.key, ('installation:' + digest).encode(), hashlib.sha256).hexdigest()

    def owned(self, proof: str, shares: list, now: int) -> bool:
        nonce = hmac.new(self.key, ('grant:' + proof).encode(), hashlib.sha256).hexdigest()
        covered = self.coverage.pop(nonce, None)
        return bool(covered and covered[1] > now and set(shares) <= set(covered[0]))

    def review(self, scope: dict, now: int) -> str:
        """Called only by the authenticated operator endpoint; not by installation."""
        current = self.source.action(scope['operation'], scope['share'], now)
        current['installation'] = self.handle(current['installation'])
        if any(current.get(key) != scope.get(key) for key in
               ('installation', 'case', 'operation', 'revision', 'share', 'created')):
            raise Denied('conflict')
        if (not isinstance(scope.get('notice'), dict) or set(scope['notice']) != {'instructions', 'location', 'action'}
                or any(not isinstance(value, str) or not 1 <= len(value) <= 8192 for value in scope['notice'].values())
                or scope['notice']['location'] != '/s/' + scope['share']
                or scope['notice']['action'] != current['action']):
            raise Denied('invalid')
        fingerprint = hashlib.sha256(json.dumps(scope, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        def record(state):
            state = state or {'replays': {}, 'cases': {}}
            identity = scope['operation'] + ':' + scope['share']
            existing = state['cases'].get(identity)
            if existing and existing != {'scope': scope, 'fingerprint': fingerprint}:
                raise Denied('conflict')
            if len(state['cases']) >= 10000 and not existing:
                raise Denied('stateLimit')
            state['cases'][identity] = {'scope': scope, 'fingerprint': fingerprint}
            return fingerprint, state
        return self.ledger.transact(record)

    def case(self, proof: str, now: int, scope: dict | None = None) -> bool:
        if scope is None:
            return hmac.compare_digest(proof, self.operator_readback())
        if set(scope) == {'required'}:
            expected = hmac.new(self.key, ('required-actions:' + json.dumps(scope['required'])).encode(), hashlib.sha256).hexdigest()
            return hmac.compare_digest(proof, expected)
        def read(state):
            entry = (state or {}).get('cases', {}).get(scope.get('operation', '') + ':' + scope.get('share', ''))
            return bool(entry and hmac.compare_digest(entry['fingerprint'], proof)
                        and entry['scope'] == scope), state
        return self.ledger.transact(read)

    def current_case(self, scope: dict, now: int) -> bool:
        if set(scope) != {'installation', 'case', 'operation', 'revision', 'share', 'created'}:
            return False
        def read(state):
            entry = (state or {}).get('cases', {}).get(scope['operation'] + ':' + scope['share'])
            return entry['scope'] if entry else None, state
        reviewed = self.ledger.transact(read)
        if not reviewed or any(reviewed.get(key) != value for key, value in scope.items()):
            return False
        current = self.source.action(reviewed['operation'], reviewed['share'], now)
        current['installation'] = self.handle(current['installation'])
        return all(current.get(key) == reviewed[key] for key in
                   ('installation', 'case', 'operation', 'revision', 'share', 'created'))

    def operator_readback(self) -> str:
        return hmac.new(self.key, b'private-operator-readback-v1', hashlib.sha256).hexdigest()

    def required_actions(self, after: str = '') -> tuple[list, str, str | None]:
        inventory = self.source.actions(after)
        required = [(entry['case'], entry['operation'], entry['revision'], entry['share'],
                     self.handle(entry['installation']) if entry['installation'] else '') for entry in inventory['entries']]
        proof = hmac.new(self.key, ('required-actions:' + json.dumps(required)).encode(), hashlib.sha256).hexdigest()
        return required, proof, inventory['next']
