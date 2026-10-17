"""No command accepts a credential, address, notice or private key value."""
import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import secrets
import sys

from .runtime import build_runtime, protected_path, protected_read, serve, validate_manifest
from .service import Denied


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--manifest', required=True)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--serve', action='store_true')
    parser.add_argument('--serve-installations', action='store_true')
    parser.add_argument('--serve-feedback', action='store_true')
    parser.add_argument('--installation-port', type=int, default=8791)
    parser.add_argument('--dispatch-once', action='store_true')
    parser.add_argument('--export', action='store_true')
    parser.add_argument('--restore', action='store_true')
    parser.add_argument('--backup-file')
    args = parser.parse_args()
    try:
        if sum((args.check, args.serve, args.serve_installations, args.serve_feedback, args.dispatch_once, args.export, args.restore)) != 1 or bool(args.backup_file) != args.restore:
            raise Denied('configuration')
        if args.serve_installations and args.installation_port != 8791:
            raise Denied('configuration')
        manifest = validate_manifest(args.manifest, Path(__file__).resolve().parent.parent, binding_socket=args.serve, binding_feedback=args.serve_feedback)
        if not manifest['enabled']:
            print('private-contact: disabled')
            return 0 if args.check else 78
        api = build_runtime(manifest, backup=protected_read(args.backup_file, 4 * 1024 * 1024 + 28) if args.restore else None)
        if args.restore:
            print('private-contact: restored; authoritative reconciliation required')
        elif args.check:
            print('private-contact: configuration loaded; transport unverified')
        elif args.serve_feedback:
            from .feedback_ingress import feedback_server
            with feedback_server(api, manifest['feedback_socket_file'], group_gid=manifest['feedback_group_gid']) as server:
                # Same owned signal/cleanup contract as the existing serve path.
                class StopFeedback(BaseException):
                    pass
                import signal
                def stop_feedback(signum, frame):
                    raise StopFeedback()
                previous = signal.signal(signal.SIGTERM, stop_feedback)
                try:
                    server.serve_forever(poll_interval=0.5)
                except (StopFeedback, KeyboardInterrupt):
                    pass
                finally:
                    signal.signal(signal.SIGTERM, previous)
        elif args.serve or args.serve_installations:
            serve(api, manifest['socket_file'], installation_port=args.installation_port if args.serve_installations else None)
        elif args.dispatch_once:
            api.service.dispatch()
            print('private-contact: dispatch cycle completed')
        elif args.export:
            # Separate OneDrive transfer is owner-gated; this command seals one export
            # into the qualified namespace only. It never expires/deletes artifacts.
            api.custody.transact(lambda state: (None, state))
            sealed = api.custody.primary.export()
            root = protected_path(manifest['export_root'], directory=True)
            name = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + secrets.token_hex(8) + '.sealed'
            descriptor = os.open(root / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(descriptor, 'wb') as output:
                output.write(sealed)
                output.flush()
                os.fsync(output.fileno())
            offsite = protected_path(manifest['onedrive_root'], directory=True) / name
            descriptor = os.open(offsite, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(descriptor, 'wb') as output:
                output.write(sealed)
                output.flush()
                os.fsync(output.fileno())
            if offsite.read_bytes() != sealed:
                raise Denied('unavailable')
            print('private-contact: encrypted export staged; remote synchronization unverified')
        return 0
    except Exception:
        print('private-contact: configuration or execution refused', file=sys.stderr)
        return 78


if __name__ == '__main__':
    raise SystemExit(main())
