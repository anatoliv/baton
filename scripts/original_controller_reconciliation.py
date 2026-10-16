"""Inert reconciliation protocol for one source-bound original compiler parent."""

def require(value):
    if not value: raise ValueError('reconciliation refused')


def validate_witness(value, request, now_ns):
    require(type(value) is dict and value.get('nonce')==request['nonce'] and value.get('phase')==request['phase'])
    require(value.get('requestSHA256')==request['sha256'] and value.get('requestedAtNs')==request['requestedAtNs'])
    observed=value.get('observedAtNs')
    require(type(observed) is int and request['requestedAtNs']<=observed<=now_ns and now_ns-observed<=3_000_000_000)
    require(value.get('clientUID')==0 and value.get('controllerIdentityVerified') is True)
    rows=value.get('groupRows');require(type(rows) is list)
    if request['phase']=='before':
        require(len(rows)==1 and rows[0].get('pid')==70700 and rows[0].get('ppid')==70695 and rows[0].get('pgid')==70700 and type(rows[0].get('stat')) is str and rows[0]['stat'].startswith('Z'))
    else:
        require(request['phase']=='after' and rows==[])
    return value


def reconcile(actions):
    # Each operation is original-parent-only or a fresh root metadata witness.
    # No signal is ever an operation; a post-reap refusal cannot trigger cleanup.
    actions.sources()
    actions.exited_reserved_child()
    before=actions.witness('before')
    actions.exited_reserved_child()  # Reservation still positive immediately before reap.
    require(actions.reap_original()==1)
    actions.partial_reap_notice()
    after=actions.witness('after')
    actions.pending_empty()
    actions.sources()
    actions.failed_receipts(before,after)
    actions.qualify_original_release()
    actions.exit_original_failed()
    raise RuntimeError('original exit unexpectedly returned')
