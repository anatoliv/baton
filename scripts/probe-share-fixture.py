#!/usr/bin/env python3
"""Fresh synthetic localhost fixtures, supervised until Ctrl-C; never sets consent."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler, ProxyHandler


class FixtureFailure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise FixtureFailure(message)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, newurl):
        raise FixtureFailure("Fixture redirect refused")


OPENER = build_opener(ProxyHandler({}), NoRedirect())


def clean_environment(root):
    # CLI config/package caches begin in fresh temporary storage. The native
    # app separately needs the OS account home for its normal Keychain session.
    home = root / "home"
    home.mkdir(mode=0o700)
    # Xcode requires a current username even for an isolated source build. Use
    # OS account metadata only; never inherit USER/LOGNAME or the account home.
    username = pwd.getpwuid(os.getuid()).pw_name
    return {"USER": username, "LOGNAME": username, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(home), "TMPDIR": str(root), "LANG": "en_US.UTF-8",
            "DOCKER_HOST": "unix:///var/run/docker.sock", "DOCKER_CONFIG": str(home / ".docker"),
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"}


def native_environment(env, share_base):
    # Security.framework returned -60006 for native writes with a synthetic HOME.
    # Use OS account metadata only for the app; no inherited provider/config env.
    # BatonStorage's required probe suite/support arguments redirect app state and
    # NavidromeKeychain scopes every native-written secret to that random suite.
    return dict(env, HOME=pwd.getpwuid(os.getuid()).pw_dir, **{"baton.share.baseURL": share_base})


def command(argv, env, payload=None, timeout=60):
    process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, env=env, start_new_session=True)
    try:
        output, diagnostic = process.communicate(payload, timeout=timeout)
    except BaseException:
        # Includes interrupted explicit builds; never leave xcodebuild descendants.
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
        raise
    if process.returncode != 0:
        name = Path(argv[0]).name
        name = name if re.fullmatch(r"[A-Za-z0-9._-]{1,32}", name) else "subprocess"
        raise FixtureFailure("Fixture command " + name + " failed (exit " + str(process.returncode) + "); output withheld")
    return output


def save_json(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as output:
        json.dump(value, output, indent=2)


def unused_ports(count=3):
    sockets = []
    try:
        for _ in range(count):
            sock = socket.socket()
            sock.bind(("127.0.0.1", 0))
            sockets.append(sock)
        return [sock.getsockname()[1] for sock in sockets]
    finally:
        for sock in sockets:
            sock.close()


def request(url, body=None):
    parsed = urlsplit(url)
    require(parsed.scheme == "http" and parsed.hostname == "127.0.0.1" and parsed.port,
            "Only literal HTTP loopback requests are permitted")
    headers = {"Content-Type": "application/json"} if body is not None else {}
    data = json.dumps(body).encode() if body is not None else None
    with OPENER.open(Request(url, data=data, headers=headers), timeout=5) as response:
        return response.read()


def await_http(url, child=None):
    for _ in range(60):
        require(child is None or child.poll() is None, "Fixture child exited during startup")
        try:
            return request(url)
        except FixtureFailure:
            raise
        except Exception:
            time.sleep(0.5)
    raise FixtureFailure("Local fixture did not become ready")


def verify_listener(pid, port, env):
    text = command(["lsof", "-nP", "-a", "-p", str(pid), "-iTCP", "-sTCP:LISTEN"], env).decode()
    listeners = [line.split()[-2] for line in text.splitlines()[1:]]
    require(listeners == ["127.0.0.1:" + str(port)], "Service must listen only on its assigned IPv4 loopback port; rebuild with BATON_SHARE_BIND support")


def safe_export(archive, target):
    target = target.resolve()
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        members = tar.getmembers()
        for member in members:
            path = target / member.name
            require(target in path.resolve().parents and (member.isdir() or member.isfile()),
                    "Source export contains an unsafe path or link")
        tar.extractall(target, members=members)
    # probe-build.sh reads only this exported source's Config, never owner inputs.
    for config in target.rglob("*.local.xcconfig"):
        config.unlink()


def build_app(root, env):
    repo = Path(__file__).resolve().parent.parent
    source = root / "source"
    source.mkdir()
    safe_export(command(["git", "-C", str(repo), "archive", "HEAD"], env), source)
    command(["git", "-C", str(source), "init", "-q"], env)
    command(["git", "-C", str(source), "add", "."], env)
    command(["git", "-C", str(source), "-c", "user.name=Sharing Probe", "-c", "user.email=probe@localhost",
             "commit", "-q", "-m", "Synthetic fixture source snapshot"], env)
    # Foreground explicit opt-in Debug build. Override every target's signing
    # settings without consulting an owner signing identity. Xcode documents
    # XCODE_XCCONFIG_FILE as higher priority than command-line/-xcconfig settings.
    # prepare_app later ad-hoc signs only its owned copy; this is not a Release.
    unsigned = root / "unsigned-debug-build.xcconfig"
    unsigned.write_text("CODE_SIGNING_ALLOWED = NO\nCODE_SIGNING_REQUIRED = NO\n")
    unsigned.chmod(0o600)
    try:
        command([str(source / "scripts/probe-build.sh"), str(root / "build")],
                dict(env, XCODE_XCCONFIG_FILE=str(unsigned)), timeout=1200)
    finally:
        unsigned.unlink()
    return root / "build/dd-worktree/Build/Products/Debug/Baton.app"


def prepare_app(source, root, env):
    source = source.resolve()
    require(source.name == "Baton.app" and "Debug" in source.parts,
            "A supplied app must be a Debug/Baton.app product")
    require((source / "Contents/MacOS/Baton").is_file(), "Probe executable is absent")
    # Recent Xcode Debug products put application code in Baton.debug.dylib.
    code = [source / "Contents/MacOS/Baton", source / "Contents/MacOS/Baton.debug.dylib"]
    require(any(path.is_file() and b"baton.share.baseURL" in path.read_bytes() for path in code),
            "Supplied app lacks the DEBUG local share-service override; rebuild current source")
    app = root / "Debug/Baton.app"
    app.parent.mkdir()
    shutil.copytree(source, app, symlinks=True)
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    require(info.get("CFBundleIdentifier") == "io.tonebox.baton", "Unexpected supplied app bundle")
    # Disable external telemetry/update scheduling in the owned COPY, then ad-hoc
    # sign it. This is deliberately a Debug fixture, never Release acceptance.
    for key in ("CrashReportingDSN", "CrashReportingProvider", "CrashReportingEnvironment", "SUFeedURL", "SUPublicEDKey"):
        info[key] = ""
    info["SUEnableAutomaticChecks"] = False
    info_path.write_bytes(plistlib.dumps(info))
    command(["codesign", "--force", "--deep", "--sign", "-", str(app)], env)
    return app


class Supervisor:
    def __init__(self, root, env):
        self.root, self.env = root, env
        self.children = []
        self.container = None
        self.container_id = None
        self.suite = "probe-sharing-" + secrets.token_hex(12)
        self._owned_suite = self.suite
        self.defaults_created = False
        self.keychain_attempted = False

    def start(self, argv, env, label):
        # A future child may log a share link/token. Never collect child logs.
        child = subprocess.Popen(argv, env=env, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
        self.children.append(child)
        return child

    def keychain(self, operation):
        require(operation == "remove" and self.suite == self._owned_suite
                and re.fullmatch(r"probe-sharing-[a-f0-9]{24}", self.suite),
                "Keychain cleanup requires this fixture's exact generated suite")
        # A freshly compiled SecItemDelete helper can fail -25244 when it does not
        # own an item's ACL. The system utility can delete the native-created
        # legacy item without changing its owner or reading its password. It
        # removes one matching item per call; drain this exact service, then prove
        # absence (44 is errSecItemNotFound modulo the process exit-code range).
        # security can print item attributes on success: always capture/discard.
        argv = ["/usr/bin/security", "delete-generic-password", "-s",
                "io.tonebox.secrets.probe." + self.suite]
        env = dict(self.env, HOME=pwd.getpwuid(os.getuid()).pw_dir)
        deadline = time.monotonic() + 15
        for _ in range(32):
            remaining = deadline - time.monotonic()
            require(remaining > 0, "Probe Keychain cleanup timed out; output withheld")
            try:
                result = subprocess.run(argv, env=env, stdin=subprocess.DEVNULL,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        timeout=min(5, remaining), check=False)
            except Exception:
                raise FixtureFailure("Probe Keychain cleanup failed; output withheld") from None
            if result.returncode == 44:
                return
            require(result.returncode == 0, "Probe Keychain cleanup failed; output withheld")
        raise FixtureFailure("Probe Keychain cleanup did not establish absence; output withheld")

    def cleanup(self):
        failures = []
        for child in reversed(self.children):
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
        if self.container_id:
            try:
                command(["docker", "rm", "-f", self.container_id], self.env)
            except Exception:
                failures.append("owned Docker container")
        if self.keychain_attempted:
            try:
                self.keychain("remove")
            except Exception:
                failures.append("own probe Keychain items")
        if self.defaults_created:
            try:
                command(["defaults", "delete", self.suite], self.env)
            except Exception:
                failures.append("own preferences suite")
        # Keep mode-0700 evidence by design; never remove an existing fixture path.
        save_json(self.root / "cleanup.json", {"failures": failures, "childrenStopped": True})
        if failures:
            print("Cleanup incomplete: " + ", ".join(failures), file=sys.stderr)
        return failures


def setup(args, supervisor):
    root, env = supervisor.root, supervisor.env
    require(sys.platform == "darwin", "Native fixture requires macOS")
    command(["docker", "image", "inspect", args.navidrome_image], env)
    source = build_app(root, env) if args.build_app else Path(args.app)
    app = prepare_app(source, root, env)
    for folder in ("music", "navidrome", "app-support", "shares", "service"):
        (root / folder).mkdir(mode=0o700)
    command(["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=330:duration=40",
             "-metadata", "title=Synthetic Sharing Probe Song", "-metadata", "artist=Sharing Probe",
             "-metadata", "album=Sharing Probe Album", "-b:a", "192k", str(root / "music/song.mp3")], env)
    command(["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=0xe98345:s=600x600",
             "-frames:v", "1", str(root / "music/cover.png")], env)
    nav_port, share_port, mcp_port = unused_ports()
    nav_base, share_base = "http://127.0.0.1:" + str(nav_port), "http://127.0.0.1:" + str(share_port)
    supervisor.container = "baton-share-fixture-" + secrets.token_hex(12)
    # Cached official image, synthetic-only mounts and IPv4 loopback publication.
    supervisor.container_id = command(["docker", "create", "--pull=never", "--name", supervisor.container,
            "--network", "bridge", "-p", "127.0.0.1:" + str(nav_port) + ":4533",
            "-e", "ND_LOGLEVEL=error",
            "-v", str(root / "music") + ":/music:ro", "-v", str(root / "navidrome") + ":/data",
            args.navidrome_image], env).decode().strip()
    require(len(supervisor.container_id) == 64 and all(c in "0123456789abcdef" for c in supervisor.container_id), "Invalid fixture container identity")
    command(["docker", "start", supervisor.container_id], env)
    await_http(nav_base + "/ping")
    password, username = secrets.token_hex(24), "sharing-probe"
    request(nav_base + "/auth/createAdmin", dict(username=username, password=password))
    def subsonic(endpoint, **values):
        salt = secrets.token_hex(8)
        token = hashlib.md5((password + salt).encode()).hexdigest()
        query = dict(u=username, t=token, s=salt, v="1.16.1", f="json", c="sharing-probe", **values)
        return json.loads(request(nav_base + "/rest/" + endpoint + "?" + urlencode(query)))["subsonic-response"]
    subsonic("startScan")
    for _ in range(60):
        if subsonic("search3", query="Synthetic Sharing Probe", songCount=2).get("searchResult3", {}).get("song"):
            break
        time.sleep(0.5)
    else:
        raise FixtureFailure("Synthetic song was not indexed")
    binary = Path(args.share_bin).resolve()
    require(binary.name == "baton-share" and binary.is_file(), "Supply a built local baton-share executable")
    resources = binary.parent / "baton-gateway_BatonShareServer.bundle"
    require(resources.is_dir(), "Service resource bundle missing beside the executable")
    shutil.copy2(binary, root / "service/baton-share")
    shutil.copytree(resources, root / resources.name)
    # SwiftPM resolves its resource bundle beside the executable.
    shutil.move(str(root / resources.name), str(root / "service" / resources.name))
    service_env = dict(env, BATON_SHARE_BIND="127.0.0.1", BATON_SHARE_DATA=str(root / "shares"),
                       BATON_SHARE_PORT=str(share_port), BATON_SHARE_PUBLIC_BASE=share_base,
                       BATON_SHARE_BLOB_DELIVERY="direct", BATON_SHARE_ADMIN_TOKEN=secrets.token_hex(32))
    service = supervisor.start([str(root / "service/baton-share")], service_env, "share-service")
    await_http(share_base + "/health", service)
    verify_listener(service.pid, share_port, env)
    preferences = {"baton.mcp.preferredPort": mcp_port, "SUEnableAutomaticChecks": False}
    # A legacy URL/username prefill creates a passwordless migrated profile before
    # manual Connect. Start empty so the real login creates the sole active server.
    preferences_path = root / "preferences.plist"
    preferences_path.write_bytes(plistlib.dumps(preferences))
    preferences_path.chmod(0o600)
    supervisor.defaults_created = True
    command(["defaults", "import", supervisor.suite, str(preferences_path)], env)
    credentials = root / "navidrome-credentials.json"
    save_json(credentials, dict(username=username, password=password, suite=supervisor.suite, navidromeBase=nav_base))
    config = dict(suite=supervisor.suite, supportDirectory=str(root / "app-support"), dataDirectory=str(root / "shares"),
                  shareBase=share_base, navidromeBase=nav_base, query="Synthetic Sharing Probe", navidromeCredentialFile=str(credentials))
    save_json(root / "fixture.json", config)
    supervisor.keychain_attempted = True  # clean only native-written items in this random service
    probe = supervisor.start([str(app / "Contents/MacOS/Baton"), "-baton.defaultsSuite", supervisor.suite,
                              "-baton.supportDirectory", str(root / "app-support")],
                             native_environment(env, share_base), "app")
    for _ in range(60):
        require(probe.poll() is None, "Isolated Debug probe exited during launch")
        if (root / "app-support/mcp.json").is_file():
            break
        time.sleep(0.5)
    else:
        raise FixtureFailure("Probe MCP discovery was not created")
    save_json(root / "state.json", dict(root=str(root), suite=supervisor.suite, appPID=probe.pid,
              servicePID=service.pid, navidromeContainer=supervisor.container_id, mcpRequestedPort=mcp_port))
    print("READY fixture: " + str(root / "fixture.json"), flush=True)
    print("Use CUA to walk only probe PID " + str(probe.pid) + ": log into the local Navidrome using the private navidrome-credentials.json, then share Synthetic Sharing Probe Song and review the disclosure.", flush=True)
    print("Then run scripts/probe-share-e2e.sh with the fixture file above. Keep this supervisor running; Ctrl-C stops its children and removes only its own probe credentials/preferences.", flush=True)
    while True:
        require(all(child.poll() is None for child in supervisor.children), "An owned fixture child exited")
        time.sleep(1)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    app = parser.add_mutually_exclusive_group(required=True)
    app.add_argument("--app", help="Supplied Debug/Baton.app; only an owned copy is modified")
    app.add_argument("--build-app", action="store_true", help="Explicit probe-build.sh run from committed source exported without private configs")
    parser.add_argument("--share-bin", required=True, help="Built loopback-capable baton-share; resource bundle must be adjacent")
    parser.add_argument("--navidrome-image", default="deluan/navidrome:latest", help="Already cached Docker image; pulls forbidden")
    parser.add_argument("--check-only", action="store_true", help="Validate tools/image/app without launching, storing credentials or setting preferences")
    args = parser.parse_args(argv)
    if not args.check_only:
        try:
            owner = Path("/tmp/baton-probe.lock/owner").read_text().split()[0]
        except Exception:
            owner = ""
        require(owner == str(os.getppid()), "Launch requires the machine probe lock; invoke probe-share-fixture.sh")
    os.umask(0o077)
    # Do not inherit a caller's TMPDIR pointing at owner application storage.
    root = Path(tempfile.mkdtemp(prefix="baton-share-fixture-", dir="/private/tmp")).resolve()
    env = clean_environment(root)
    supervisor = Supervisor(root, env)
    def stop(signum, frame):
        raise KeyboardInterrupt
    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(signum, stop)
    rc = 0
    try:
        if args.check_only:
            require(sys.platform == "darwin", "Native fixture requires macOS")
            command(["docker", "image", "inspect", args.navidrome_image], env)
            binary = Path(args.share_bin).resolve()
            require(binary.name == "baton-share" and binary.is_file(), "Built service executable missing")
            require((binary.parent / "baton-gateway_BatonShareServer.bundle").is_dir(), "Service resources missing")
            if args.app:
                prepare_app(Path(args.app), root, env)
            require(shutil.which("ffmpeg", path=env["PATH"]), "FFmpeg is unavailable")
            print("PASS setup prerequisites; no services/app started, no preferences/Keychain writes. Build option and full startup remain unverified.")
        else:
            setup(args, supervisor)
    except KeyboardInterrupt:
        print("Stopping own sharing fixture")
    except Exception as error:
        # Never stringify urllib/subprocess errors: they can contain credentials.
        message = str(error) if isinstance(error, FixtureFailure) else "Unexpected fixture error; contents withheld"
        print("FAIL " + message + "; private evidence directory: " + str(root), file=sys.stderr)
        rc = 1
    finally:
        # Ctrl-C reaches both the shell and Python; the shell may also forward
        # TERM. Once teardown starts, a second signal must not orphan children.
        for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            signal.signal(signum, signal.SIG_IGN)
        if supervisor.cleanup():
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
