"""A separate feedback-only Unix listener over the admitted protected runtime.

No operator key, contact route, command body or custody readback is exposed by
this listener. Runtime/manifest construction remains in the protected worker.
"""


def feedback_socket(socket_file, *, group_gid=None, binding=False):
    """Group access is confined to this separate leaf; other paths stay protected."""
    from .runtime import protected_socket
    if group_gid is None:
        return protected_socket(socket_file, binding=binding)
    import os
    from pathlib import Path
    import stat
    from . import Denied
    try:
        if (type(group_gid) is not int or not 0 < group_gid <= 2147483647
                or os.geteuid() != 0 and group_gid not in {os.getegid(), *os.getgroups()}
                or not isinstance(socket_file, str)):
            raise ValueError()
        endpoint = Path(socket_file)
        if not endpoint.is_absolute() or endpoint.resolve() != endpoint:
            raise ValueError()
        parent = endpoint.parent.lstat()
        if (not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.geteuid()
                or parent.st_gid != group_gid or stat.S_IMODE(parent.st_mode) != 0o710):
            raise ValueError()
        try:
            info = endpoint.lstat()
        except FileNotFoundError:
            return endpoint
        if (binding or not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.geteuid()
                or info.st_gid != group_gid or stat.S_IMODE(info.st_mode) != 0o660
                or info.st_nlink != 1):
            raise ValueError()
        return endpoint
    except Exception:
        pass
    raise Denied('configuration') from None


def _group_server(api, socket_file, group_gid):
    import os
    import socketserver
    from .runtime import private_handler
    from . import Denied
    endpoint = feedback_socket(socket_file, group_gid=group_gid, binding=True)
    parent = endpoint.parent.stat()
    parent_identity = (parent.st_dev, parent.st_ino)

    class Server(socketserver.UnixStreamServer):
        def get_request(self):
            connection, address = super().get_request()
            connection.settimeout(5)
            return connection, address

        def server_close(self):
            super().server_close()
            identity = getattr(self, 'endpoint_identity', None)
            if identity is None:
                return
            try:
                feedback_socket(str(endpoint), group_gid=group_gid)
                current_parent, info = endpoint.parent.stat(), endpoint.lstat()
                if ((current_parent.st_dev, current_parent.st_ino) == parent_identity
                        and (info.st_dev, info.st_ino) == identity):
                    endpoint.unlink()
            except (Denied, FileNotFoundError):
                pass  # Keep changed or unsafe endpoints, as the operator contract does.

    previous = os.umask(0o177)  # Bound endpoint is inaccessible until group qualification.
    server = None
    try:
        server = Server(str(endpoint), private_handler(api))
        info = endpoint.lstat()
        server.endpoint_identity = (info.st_dev, info.st_ino)
        os.chown(endpoint, -1, group_gid)
        os.chmod(endpoint, 0o660)
        feedback_socket(str(endpoint), group_gid=group_gid)
        if (endpoint.parent.stat().st_dev, endpoint.parent.stat().st_ino) != parent_identity:
            raise Denied('configuration')
        return server
    except Exception:
        if server is not None:
            # Do not remove an unqualified or changed inode; close the owned fd.
            server.server_close()
        raise Denied('configuration') from None
    finally:
        os.umask(previous)


def feedback_server(api, socket_file, *, group_gid=None):
    from .runtime import private_server

    class FeedbackOnly:
        def handle(self, path, raw):
            if path != '/feedback':
                return 404, {'error': 'invalid'}
            status, result = api.handle('/feedback', raw)
            if (status == 200 and isinstance(result, dict) and set(result) == {'accepted'}
                    and result['accepted'] is True):
                return 200, {'accepted': True}
            if status == 200:
                return 400, {'error': 'rejected'}
            if status in (400, 403, 404):
                return 400, {'error': 'rejected'}
            return 503, {'error': 'unavailable'}

    server = (private_server(FeedbackOnly(), socket_file) if group_gid is None
              else _group_server(FeedbackOnly(), socket_file, group_gid))
    # socketserver's default handle_error prints a traceback after a peer closes
    # during response writing. Feedback errors must not expose private frames.
    server.handle_error = lambda request, client_address: None
    return server
