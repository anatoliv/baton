"""Pure command/custody checks for the owning physical controller; no SDK calls."""
import hashlib
import json
import os
from pathlib import Path
import re
import stat

SUITE_PATTERN = r'probe-attest-[a-f0-9]{32}'

def require(value):
    if not value:
        raise ValueError('Synthetic proof custody refused')

def private_directory(path):
    attrs = path.lstat()
    require(path == path.resolve() and stat.S_ISDIR(attrs.st_mode) and
            attrs.st_uid == os.getuid() and stat.S_IMODE(attrs.st_mode) == 0o700)

def command(device, suite, destination, raw):
    """Construct exactly one synthetic source copy, never execute it."""
    destination = Path(destination); raw = Path(raw)
    require(isinstance(device, str) and re.fullmatch(r'[a-zA-Z0-9-]{8,128}', device))
    require(isinstance(suite, str) and re.fullmatch(SUITE_PATTERN, suite))
    private_directory(destination.parent)
    require(destination.name == 'issuance.json' and raw.name == 'copy-raw.json' and
            raw.parent == destination.parent and destination.is_absolute())
    require(not os.path.lexists(destination) and not os.path.lexists(raw))
    source = 'Library/Application Support/Baton Probes/' + suite + '/AppAttestPhysicalEvidence/issuance.json'
    return ['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', device,
            '--domain-type', 'appDataContainer', '--domain-identifier', 'io.tonebox.baton',
            '--source', source, '--destination', str(destination), '--timeout', '20',
            '--json-output', str(raw)]

def receipt(destination):
    destination = Path(destination); private_directory(destination.parent)
    info = destination.lstat()
    require(destination == destination.resolve() and destination.name == 'issuance.json' and
            stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and
            stat.S_IMODE(info.st_mode) == 0o600 and 0 < info.st_size <= 65536)
    return {'syntheticProofOnly': True, 'filesCopied': 1, 'bytes': info.st_size,
            'fileSHA256': hashlib.sha256(destination.read_bytes()).hexdigest(),
            'directoryMode': '0700', 'fileMode': '0600', 'removeExistingContent': False,
            'ownerFilesCopied': 0}

def main():
    # Independent invocation cannot admit an unguarded nested driver.
    raise ValueError('Owning original controller and reviewed binding required')

if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(json.dumps({'result': 'FAIL', 'errorClass': type(error).__name__,
                          'privateDetailsWithheld': True}))
        raise SystemExit(1)
