#!/usr/bin/env python3
"""Create synthetic Navidrome/share fixtures; secrets stay in a private JSON file.

Run before SongSharingFlowUITests. Pass its private fixture environment via the
generated test scheme EnvironmentVariables dictionary; do not place credentials in argv.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import urllib.parse
import urllib.request
import uuid


def wait_for(url, tries=60):
    for _ in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=2) as response:
                if response.status == 200:
                    return
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(1)
    raise RuntimeError("synthetic fixture did not become ready")


def write_private(path, state):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as output:
        json.dump(state, output)
    path.chmod(0o600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--service-binary", type=Path, required=True)
    parser.add_argument("--nav-port", type=int, default=4641)
    parser.add_argument("--share-port", type=int, default=4642)
    parser.add_argument("--model-port", type=int, default=4643)
    parser.add_argument("--upload-gate-port", type=int, help="optional loopback pending-upload UI regression gate")
    args = parser.parse_args()
    root = args.root.resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    for folder in ("music", "navidrome", "service"):
        (root / folder).mkdir(mode=0o700)
    nav = f"http://127.0.0.1:{args.nav_port}"
    share = f"http://127.0.0.1:{args.share_port}"
    user = "iphone-sharing-probe"
    password = os.urandom(24).hex()
    token = os.urandom(32).hex()
    container = "baton-share-ios-nav-" + uuid.uuid4().hex[:8]
    state = {
        "fixture_root": str(root), "navidrome_container": container,
        "environment": {
            "SONG_SHARING_FLOW_TESTS": "1", "SONG_SHARING_NAV_URL": nav,
            "SONG_SHARING_NAV_USER": user, "SONG_SHARING_NAV_SECRET": password,
            "SONG_SHARING_SHARE_URL": share, "SONG_SHARING_ADMIN_TOKEN": token,
            "SONG_SHARING_MODEL_URL": f"http://127.0.0.1:{args.model_port}/v1",
        },
    }
    # Store generated credentials before starting either fixture. Never print them.
    state_file = root / "fixture.json"
    write_private(state_file, state)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i",
                    "sine=frequency=330:duration=40", "-metadata", "title=iPhone Sharing Probe Song",
                    "-metadata", "artist=iPhone Sharing Probe", "-metadata", "album=iPhone Sharing Probe Album",
                    "-b:a", "192k", str(root / "music/song.mp3")], check=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i",
                    "color=c=0xe98345:s=600x600", "-frames:v", "1", str(root / "music/cover.png")], check=True)
    subprocess.run(["docker", "run", "-d", "--name", container,
                    "-p", f"127.0.0.1:{args.nav_port}:4533", "-e", "ND_LOGLEVEL=warn",
                    "-v", str(root / "music") + ":/music:ro", "-v", str(root / "navidrome") + ":/data",
                    "deluan/navidrome:latest"], check=True, stdout=subprocess.DEVNULL)
    wait_for(nav + "/ping")
    request = urllib.request.Request(nav + "/auth/createAdmin", method="POST",
                                     data=json.dumps({"username": user, "password": password}).encode(),
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=10) as response:
        response.read()

    def sub(endpoint, **args):
        salt = os.urandom(8).hex()
        digest = hashlib.md5((password + salt).encode()).hexdigest()
        query = {"u": user, "t": digest, "s": salt, "v": "1.16.1", "f": "json", "c": "iphone-sharing-fixture", **args}
        with urllib.request.urlopen(nav + "/rest/" + endpoint + "?" + urllib.parse.urlencode(query), timeout=8) as response:
            return json.load(response)["subsonic-response"]

    sub("startScan")
    for _ in range(60):
        songs = sub("search3", query="iPhone Sharing", songCount=10).get("searchResult3", {}).get("song", [])
        if songs:
            state["song_id"] = songs[0]["id"]
            break
        time.sleep(1)
    else:
        raise RuntimeError("synthetic song was not indexed")
    if args.upload_gate_port:
        gate = f"http://127.0.0.1:{args.upload_gate_port}"
        state["environment"]["SONG_SHARING_SHARE_URL"] = gate
        state["environment"]["SONG_SHARING_UPLOAD_GATE_URL"] = gate
        with (root / "upload-gate.log").open("ab") as log:
            process = subprocess.Popen([os.sys.executable, str(Path(__file__).with_name("song-sharing-upload-gate.py")),
                "--port", str(args.upload_gate_port), "--backend", share], stdout=log, stderr=log, start_new_session=True)
        state["upload_gate_pid"] = process.pid
        write_private(state_file, state)
        wait_for(gate + "/_baton_probe_upload_gate", 10)
    source = args.service_binary.resolve()
    shutil.copy2(source, root / "service/baton-share")
    # SwiftPM resource suffix is .bundle on macOS, .resources on Linux.
    bundle = source.parent / "baton-gateway_BatonShareServer.bundle"
    shutil.copytree(bundle, root / "service" / bundle.name)
    env = {**os.environ, "BATON_SHARE_DATA": str(root / "shares"),
           "BATON_SHARE_BIND": "127.0.0.1", "BATON_SHARE_PORT": str(args.share_port), "BATON_SHARE_PUBLIC_BASE": state["environment"]["SONG_SHARING_SHARE_URL"],
           "BATON_SHARE_BLOB_DELIVERY": "direct", "BATON_SHARE_ADMIN_TOKEN": token}
    with (root / "service.log").open("ab") as log:
        process = subprocess.Popen([str(root / "service/baton-share")], env=env, stdout=log, stderr=log, start_new_session=True)
    state["service_pid"] = process.pid
    write_private(state_file, state)
    wait_for(share + "/health", 30)
    with (root / "model.log").open("ab") as log:
        model = subprocess.Popen([os.sys.executable, str(Path(__file__).with_name("song-sharing-model-fixture.py")),
                                  "--port", str(args.model_port)], stdout=log, stderr=log, start_new_session=True)
    state["model_pid"] = model.pid
    write_private(state_file, state)
    print(json.dumps({"fixture_file": str(state_file), "nav_url": nav, "share_url": share, "ready": True}))


if __name__ == "__main__":
    main()
