"""Private backup seam. No network, key discovery, scheduler, restore or deletion.

Operator commands use the existing PrivateAPI ticket/replay admission. Catalog,
case reviews and backup receipts stay in its non-restored authoritative ledger.
"""
import copy
import hashlib
import hmac
import json
import uuid

from .custody import LIMIT, _encode, _decode
from .service import Denied, _Refusal

DAY = 86400
PERIOD = 30 * DAY
CASE_KIND = 'baton-private-case-evidence-v1'
JOB_FIELDS = ('identity', 'installation', 'share', 'share_created', 'notice', 'state',
              'created', 'attempts', 'messages', 'delivered', 'history', 'escalations')


class BackupDenied(Denied, _Refusal):
    """Preserve bounded rejection through the existing custody transaction."""


def require(ok, category='custodyReviewRequired'):
    if not ok:
        raise BackupDenied(category)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def case_index(state):
    cases = (state or {}).get('cases', {})
    require(type(cases) is dict and len(cases) <= 10000)
    for identity, entry in cases.items():
        require(type(identity) is str and type(entry) is dict and set(entry) == {'scope', 'fingerprint'})
        scope = entry['scope']
        require(type(scope) is dict and set(scope) == {'installation', 'case', 'operation', 'revision', 'share', 'created', 'notice'})
        require(identity == scope['operation'] + ':' + scope['share'] and entry['fingerprint'] == digest(scope))
    return cases


class CaseBackups:
    def __init__(self, api):
        # Actual connected worker seams; no injected approval/qualified flag.
        self.api = api
        self.custody = api.custody
        self.ledger = api.authority.ledger
        require(self.custody.journal is not self.ledger)

    def _catalog(self, state, now):
        cases = case_index(state)
        backup = (state or {}).get('backup')
        require(type(backup) is dict and backup['case_digest'] == digest(cases))
        require(set(backup['records']) == set(cases) and backup['reviewed_at'] <= now < backup['review_until'])
        for identity, record in backup['records'].items():
            require(record['fingerprint'] == cases[identity]['fingerprint'])
            require(record['status'] in ('ordinary', 'held', 'released'))
        return cases, backup

    def handle(self, path, raw):
        if path not in ('/operator/backup-catalog', '/operator/backup-release'):
            return self.api.handle(path, raw)
        try:
            require(type(raw) is bytes and 1 <= len(raw) <= 65536, 'invalid')
            return 200, self.operator(path, json.loads(raw))
        except Denied as error:
            category = str(error)
            if category not in {'invalid', 'unauthorized', 'conflict', 'custodyReviewRequired', 'stateLimit', 'notFound'}:
                category = 'unavailable'
            return (400 if category == 'invalid' else 403 if category == 'unauthorized' else 503), {'error': category}
        except Exception:
            return 503, {'error': 'unavailable'}

    def operator(self, path, body):
        require(path in ('/operator/backup-catalog', '/operator/backup-release'), 'invalid')
        require(type(body) is dict and set(body) == {'authorization'}, 'invalid')
        # Same signature, path binding, expiry and durable nonce consumption as
        # the worker's existing operator commands. Failed commands consume nonce.
        command = self.api._operator(body, path)
        now = int(self.api.clock())
        require(type(command) is dict, 'invalid')
        def apply(state):
            require(type(state) is dict)
            cases = case_index(state)
            old = state.get('backup')
            if path == '/operator/backup-catalog':
                require(set(command) == {'case_digest', 'review_until', 'records'}, 'invalid')
                require(command['case_digest'] == digest(cases), 'conflict')
                require(type(command['review_until']) is int and now < command['review_until'] <= now + PERIOD, 'invalid')
                require(type(command['records']) is dict and set(command['records']) == set(cases), 'invalid')
                records = {}
                for identity, record in command['records'].items():
                    require(type(record) is dict and set(record) == {'fingerprint', 'held'}, 'invalid')
                    require(type(record['held']) is bool and record['fingerprint'] == cases[identity]['fingerprint'], 'conflict')
                    previous = (old or {}).get('records', {}).get(identity)
                    # Refresh must not silently release an existing held case,
                    # even when its reviewed revision/fingerprint changed.
                    require(not previous or previous['status'] != 'held' or record['held'], 'conflict')
                    status = 'held' if record['held'] else (previous['status'] if previous and previous['status'] == 'released' else 'ordinary')
                    records[identity] = dict(fingerprint=record['fingerprint'], status=status,
                                             released_at=previous.get('released_at') if previous else None)
                # Missing/new cases invalidate the old catalog. Existing held
                # records can never disappear by a catalog refresh.
                require(not old or all(identity in records for identity, item in old['records'].items() if item['status'] == 'held'), 'conflict')
                state['backup'] = dict(case_digest=digest(cases), records=records,
                    reviewed_at=now, review_until=command['review_until'],
                    generation=(old['generation'] + 1 if old else 1), artifacts=(old or {}).get('artifacts', {}))
                if old and 'remote_namespace' in old:
                    state['backup']['remote_namespace'] = old['remote_namespace']
            else:
                require(set(command) == {'identity', 'fingerprint', 'generation'}, 'invalid')
                _, backup = self._catalog(state, now)
                require(command['generation'] == backup['generation'], 'conflict')
                record = backup['records'].get(command['identity'])
                require(record and record['status'] == 'held' and record['fingerprint'] == command['fingerprint'], 'conflict')
                record.update(status='released', released_at=now)
                backup['generation'] += 1
            return {'generation': state['backup']['generation']}, state
        return self.ledger.transact(apply)

    def capture(self, now):
        require(type(now) is int and self.custody.reconciled())
        # Match worker lock order: journal -> authority ledger. A single latest
        # authoritative checkpoint is captured under its transaction, not the
        # potentially stale primary cache. Authority/replay state is never exported.
        def journal(history):
            require(type(history) is dict and history.get('version') == 1 and type(history.get('sequence')) is int)
            current = history['state']
            require(type(current) is dict and now >= current.get('time', 0))
            def record(state):
                cases, backup = self._catalog(state, now)
                require(len(backup['artifacts']) < 10000, 'stateLimit')
                files = {}
                ordinary = 'ordinary-' + uuid.uuid4().hex + '.sealed'
                files[ordinary] = self.custody.primary._seal(current, True)
                backup['artifacts'][ordinary] = dict(kind='ordinary', captured=now,
                    sequence=history['sequence'], verified=False, identity=None, fingerprint=None)
                for identity, hold in backup['records'].items():
                    if hold['status'] != 'held':
                        continue
                    scope = cases[identity]['scope']
                    jobs = []
                    for job in current.get('jobs', {}).values():
                        wanted = (scope['case'], scope['operation'], scope['revision'])
                        if (tuple(job['identity'][:3]) == wanted and job['share'] == scope['share']
                                and job['installation'] == scope['installation']):
                            jobs.append({key: copy.deepcopy(job[key]) for key in JOB_FIELDS})
                    # Explicitly omit contacts, addresses, enrollment challenges,
                    # access codes/grants/leases, rates, replay state and other cases.
                    value = dict(kind=CASE_KIND, version=1, captured=now,
                        sequence=history['sequence'], fingerprint=hold['fingerprint'],
                        scope=copy.deepcopy(scope), jobs=jobs)
                    raw = json.dumps(_encode(value), separators=(',', ':')).encode()
                    require(len(raw) <= LIMIT, 'stateLimit')
                    name = 'case-' + uuid.uuid4().hex + '.sealed'
                    files[name] = self.custody.primary.codec.seal(raw)
                    backup['artifacts'][name] = dict(kind='case', captured=now,
                        sequence=history['sequence'], verified=False, identity=identity, fingerprint=hold['fingerprint'])
                for name, sealed in files.items():
                    backup['artifacts'][name]['sealed_sha256'] = hashlib.sha256(sealed).hexdigest()
                require(len(backup['artifacts']) <= 10000, 'stateLimit')
                return files, state
            return self.ledger.transact(record), history
        return self.custody.journal.transact(journal)

    def read_case(self, sealed):
        # Evidence only. Its schema cannot be imported by SQLiteCustody.restore.
        value = _decode(json.loads(self.custody.primary.codec.open(sealed)))
        require(type(value) is dict and set(value) == {'kind', 'version', 'captured', 'sequence', 'fingerprint', 'scope', 'jobs'})
        require(value['kind'] == CASE_KIND and value['version'] == 1 and value['fingerprint'] == digest(value['scope']))
        return value

    def confirm(self, name, sent, downloaded, now):
        # Require actual downloaded bytes, never HTTP success/size or a boolean.
        require(type(sent) is bytes and type(downloaded) is bytes and hmac.compare_digest(sent, downloaded))
        def record(state):
            _, backup = self._catalog(state, now)
            require(name in backup['artifacts'], 'notFound')
            artifact = backup['artifacts'][name]
            require(now >= artifact['captured'] and artifact['sealed_sha256'] == hashlib.sha256(sent).hexdigest())
            artifact.update(verified=True, sealed_sha256=hashlib.sha256(sent).hexdigest())
            return None, state
        return self.ledger.transact(record)

    def expiry_candidates(self, now):
        # This only plans. No local/provider DELETE and no journal restore API.
        def plan(state):
            _, backup = self._catalog(state, now)
            artifacts = backup['artifacts']
            require(any(item['kind'] == 'ordinary' and item['verified'] and
                        now - DAY <= item['captured'] <= now for item in artifacts.values()))
            candidates = []
            for name, item in artifacts.items():
                if not item['verified'] or now < item['captured'] + PERIOD:
                    continue
                if item['kind'] == 'case':
                    record = backup['records'].get(item['identity'])
                    require(record is not None)
                    # A newer re-hold also protects old case evidence. Reviewed
                    # release is required; elapsed review date never lifts a hold.
                    if (record['status'] != 'released' or record['released_at'] > now
                            or record['fingerprint'] != item['fingerprint']):
                        continue
                candidates.append(name)
            return sorted(candidates), state
        return self.ledger.transact(plan)

    def __getattr__(self, name):
        # Preserve existing service/authority/private handler surfaces when the
        # reviewed runtime construction wraps its existing PrivateAPI.
        return getattr(self.api, name)
