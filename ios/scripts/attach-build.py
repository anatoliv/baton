#!/usr/bin/env python3
"""Wait for a TestFlight build to finish processing, then add it to the beta group.

Uploading and *distributing* are separate things, and the gap between them is silent:
`altool` reports success, App Store Connect shows the build as VALID, and testers see
nothing at all — because nothing linked the build to a group with a tester on it. Two
Baton builds sat invisible that way before anyone noticed.

Run from `testflight.sh` after the upload, or by hand:

    python3 ios/scripts/attach-build.py --build 1785989968

Needs `ASC_ISSUER_ID` in the environment (or scripts/.testflight.env) and the ASC API
private key at ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 — the same
credentials the upload already uses, so this adds no new secrets.
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def token(key_id: str, key_path: str, issuer: str) -> str:
    """An ES256 JWT for the App Store Connect API.

    Signed with `openssl` rather than a Python crypto dependency: this runs on a release
    machine, and a release script that needs `pip install` first is a release script that
    fails at the worst moment. The DER signature openssl emits has to be converted to the
    raw r||s pair JWS wants.
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
    if der[0] != 0x30:
        fail("unexpected signature encoding from openssl")
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
    def __init__(self, key_id: str, key_path: str, issuer: str):
        self.key_id, self.key_path, self.issuer = key_id, key_path, issuer

    def _request(self, method: str, path: str, body=None):
        request = urllib.request.Request(
            f"{API}/{path}",
            data=json.dumps(body).encode() if body is not None else None,
            headers={
                "Authorization": f"Bearer {token(self.key_id, self.key_path, self.issuer)}",
                "Content-Type": "application/json",
            },
            method=method,
        )
        try:
            with urllib.request.urlopen(request) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            detail = error.read().decode()[:300]
            fail(f"{method} {path} -> {error.code}: {detail}")

    def get(self, path):
        return self._request("GET", path)

    def post(self, path, body):
        return self._request("POST", path, body)


def find_app(client: Client, bundle_id: str) -> str:
    for app in client.get("apps").get("data", []):
        if app["attributes"].get("bundleId") == bundle_id:
            return app["id"]
    fail(f"no app record for {bundle_id}")


def find_build(client: Client, app_id: str, version: str):
    """The build id for an upload's `CURRENT_PROJECT_VERSION`, or None if not visible yet.

    A freshly uploaded build takes a little while to appear at all, which is distinct from
    appearing and then processing — both are normal, and neither is an error.
    """
    for build in client.get(f"apps/{app_id}/builds").get("data", []):
        if build["attributes"].get("version") == version:
            return build
    return None


def internal_group(client: Client, app_id: str) -> str:
    groups = client.get(f"apps/{app_id}/betaGroups").get("data", [])
    for group in groups:
        if group["attributes"].get("isInternalGroup"):
            return group["id"]
    fail("no internal beta group — create one in App Store Connect first")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build", required=True, help="CURRENT_PROJECT_VERSION of the upload")
    parser.add_argument("--bundle-id", default=os.environ.get("APP_BUNDLE", "io.tonebox.baton"))
    parser.add_argument("--key-id", default=os.environ.get("ASC_KEY_ID", "A9SQS39C62"))
    parser.add_argument("--timeout", type=int, default=1800,
                        help="seconds to wait for processing (default 30 min)")
    args = parser.parse_args()

    issuer = os.environ.get("ASC_ISSUER_ID")
    if not issuer:
        fail("ASC_ISSUER_ID not set")
    key_path = os.environ.get(
        "ASC_KEY_PATH",
        os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{args.key_id}.p8"),
    )
    if not os.path.exists(key_path):
        fail(f"ASC API key not found at {key_path}")

    client = Client(args.key_id, key_path, issuer)
    app_id = find_app(client, args.bundle_id)

    # Apple processes for minutes, not seconds. Poll rather than sleep-and-hope, and say
    # what is happening so a long wait doesn't look like a hang.
    deadline = time.time() + args.timeout
    build = None
    last_state = None
    while time.time() < deadline:
        build = find_build(client, app_id, args.build)
        state = build["attributes"].get("processingState") if build else "UPLOADING"
        if state != last_state:
            print(f"    build {args.build}: {state.lower()}")
            last_state = state
        if state == "VALID":
            break
        if state in {"INVALID", "FAILED"}:
            fail(f"build {args.build} finished as {state} — nothing to attach")
        time.sleep(20)
    else:
        fail(f"build {args.build} still {last_state} after {args.timeout}s — attach it later "
             f"with: python3 ios/scripts/attach-build.py --build {args.build}")

    group_id = internal_group(client, app_id)
    attached = {b["id"] for b in client.get(f"betaGroups/{group_id}/builds").get("data", [])}
    if build["id"] in attached:
        print("    already in the internal group")
        return

    client.post(f"betaGroups/{group_id}/relationships/builds",
                {"data": [{"type": "builds", "id": build["id"]}]})
    print("    added to the internal group — testers can install it")


if __name__ == "__main__":
    main()
