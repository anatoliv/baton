"""App Store Connect API: authentication and a small JSON client.

Extracted from `attach-build.py` when `app-store-metadata.py` needed the same JWT and the
same request plumbing. Two copies of a signing routine is how one of them quietly stops
matching the other, and this one is release-critical in both callers.

Deliberately dependency-free — no PyJWT, no requests. This runs on a release machine, and a
release script that needs `pip install` first is a release script that fails at the worst
possible moment.

Credentials come from the environment, the same ones the upload already uses:

    ASC_ISSUER_ID    the issuer UUID, from scripts/.testflight.env
    ASC_KEY_ID       the key id (default A9SQS39C62)
    ASC_KEY_PATH     defaults to ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
    ASC_API_BASE     override the endpoint; exists so the tests can point at a mock server
                     instead of Apple, and must never be set in a real run
"""
# `from __future__ import annotations`, and it is load-bearing rather than tidiness.
#
# `testflight.sh` prepends /usr/bin to PATH so Apple's rsync wins the lookup during
# -exportArchive. That also makes `python3` resolve to macOS's own 3.9.6 for the whole
# release, while a laptop shell finds Homebrew's 3.14. Python evaluates annotations at
# def time before 3.10, so `status: int | None` raised
#
#     TypeError: unsupported operand type(s) for |: 'type' and 'NoneType'
#
# on import, under the release and nowhere else. This import defers every annotation to a
# string and the file loads on both. Keep it, and keep new 3.10+ syntax out of the release
# scripts: they run on whatever Python the release machine's PATH hands them.
from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

DEFAULT_API = "https://api.appstoreconnect.apple.com/v1"


class ASCError(RuntimeError):
    """An App Store Connect request failed. Carries the HTTP status when there was one.

    A raised error rather than a bare `sys.exit`: `attach-build.py` wants a release script's
    fail-and-stop, but the metadata tool has to tell "Apple said no" apart from "Apple was
    unreachable" and act differently on each, which it cannot do if the exit happens
    somewhere below it.
    """

    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def token(key_id: str, key_path: str, issuer: str) -> str:
    """An ES256 JWT for the App Store Connect API.

    Signed with `openssl` rather than a Python crypto dependency. The DER signature openssl
    emits has to be converted to the raw r||s pair JWS wants.
    """
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    payload = b64url(json.dumps({
        "iss": issuer,
        "exp": int(time.time()) + 900,
        "aud": "appstoreconnect-v1",
    }).encode())
    signing_input = f"{header}.{payload}"

    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input.encode(), capture_output=True, check=True,
    ).stdout

    # SEQUENCE { INTEGER r, INTEGER s } -> r||s, each left-padded to 32 bytes.
    if not der or der[0] != 0x30:
        raise ASCError("unexpected signature encoding from openssl")
    i = 2 if der[1] < 0x80 else 3
    r_len = der[i + 1]
    r = der[i + 2:i + 2 + r_len]
    j = i + 2 + r_len
    s_len = der[j + 1]
    s = der[j + 2:j + 2 + s_len]
    r = r.lstrip(b"\x00").rjust(32, b"\x00")
    s = s.lstrip(b"\x00").rjust(32, b"\x00")
    return f"{signing_input}.{b64url(r + s)}"


class Client:
    """A thin JSON:API client. Every method raises ASCError rather than exiting."""

    def __init__(self, key_id: str, key_path: str, issuer: str, api: str | None = None,
                 timeout: int = 30):
        self.key_id, self.key_path, self.issuer = key_id, key_path, issuer
        self.api = (api or os.environ.get("ASC_API_BASE") or DEFAULT_API).rstrip("/")
        self.timeout = timeout

    def _request(self, method: str, path: str, body=None):
        request = urllib.request.Request(
            f"{self.api}/{path}",
            data=json.dumps(body).encode() if body is not None else None,
            headers={
                "Authorization": f"Bearer {token(self.key_id, self.key_path, self.issuer)}",
                "Content-Type": "application/json",
            },
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            detail = error.read().decode()[:500]
            raise ASCError(f"{method} {path} -> {error.code}: {detail}", status=error.code)
        except urllib.error.URLError as error:
            # No status: the request never reached Apple. Callers that must not fail a build
            # on a dead network key off `status is None` to skip instead.
            raise ASCError(f"{method} {path} -> unreachable: {error.reason}")
        except TimeoutError as error:
            raise ASCError(f"{method} {path} -> timed out after {self.timeout}s: {error}")

    def get(self, path):
        return self._request("GET", path)

    def post(self, path, body):
        return self._request("POST", path, body)

    def patch(self, path, body):
        return self._request("PATCH", path, body)


def credentials(key_id: str | None = None) -> tuple[str, str, str]:
    """(key_id, key_path, issuer), or ASCError naming what is missing.

    Raises rather than exits so a caller can decide whether absent credentials mean "fail"
    (a release) or "skip" (a developer's laptop with no ASC key). Getting that backwards in
    either direction is a real cost: a gate that fails without credentials is one everybody
    learns to bypass, and a release that skips without them ships unchecked.
    """
    key_id = key_id or os.environ.get("ASC_KEY_ID", "A9SQS39C62")
    issuer = os.environ.get("ASC_ISSUER_ID")
    if not issuer:
        raise ASCError("ASC_ISSUER_ID not set")
    key_path = os.environ.get(
        "ASC_KEY_PATH",
        os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8"),
    )
    if not os.path.exists(key_path):
        raise ASCError(f"ASC API key not found at {key_path}")
    return key_id, key_path, issuer


def find_app(client: Client, bundle_id: str) -> str:
    for app in client.get("apps").get("data", []):
        if app["attributes"].get("bundleId") == bundle_id:
            return app["id"]
    raise ASCError(f"no app record for {bundle_id}")
