#!/usr/bin/env python3
"""Attach-only native share -> browser -> server receipt check; synthetic localhost only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler, ProxyHandler


class ProbeFailure(Exception):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, newurl):
        raise ProbeFailure("A local fixture attempted an HTTP redirect; refusing")


OPENER = build_opener(ProxyHandler({}), NoRedirect())


def require(condition, message):
    if not condition:
        raise ProbeFailure(message)


def temporary_path(value, must_exist=True):
    path = Path(value).resolve()
    roots = [Path("/tmp").resolve(), Path(tempfile.gettempdir()).resolve()]
    require(any(path != root and root in path.parents for root in roots), "All fixture and evidence paths must be temporary; owner storage refused")
    require(not must_exist or path.exists(), "A required temporary fixture path is missing")
    return path


def private_json(path):
    path = temporary_path(path)
    require(stat.S_IMODE(path.stat().st_mode) == 0o600, "Fixture/discovery/credential JSON must be mode 0600")
    try:
        return json.loads(path.read_text())
    except Exception:
        raise ProbeFailure("Invalid fixture JSON; contents withheld") from None


def loopback_url(value, allow_path=False):
    try:
        url = urlsplit(value)
        port = url.port
    except Exception:
        raise ProbeFailure("Invalid fixture URL; contents withheld") from None
    require(url.scheme == "http" and url.hostname in ("127.0.0.1", "::1"), "Only literal HTTP loopback fixture addresses are allowed")
    require(port and not url.username and not url.password and not url.query and not url.fragment, "Fixture URL must have an explicit port and no credentials/query/fragment")
    require(allow_path or url.path in ("", "/"), "Fixture base must be an origin")
    return value.rstrip("/")


def validate_config(raw):
    suite = raw.get("suite", "")
    require(bool(re.fullmatch(r"probe-[A-Za-z0-9._-]{1,58}", suite)), "defaultsSuite must be an isolated probe-* suite")
    config = dict(raw)
    for key in ("supportDirectory", "dataDirectory"):
        require(key in config, "Missing fixture supportDirectory/dataDirectory")
        config[key] = temporary_path(config[key])
    for key in ("shareBase", "navidromeBase"):
        config[key] = loopback_url(config.get(key, ""))
    if "sharerCredentialFile" in config:
        config["sharerCredentialFile"] = temporary_path(config["sharerCredentialFile"])
        credential = private_json(config["sharerCredentialFile"])
        require(isinstance(credential.get("secret"), str) and bool(re.fullmatch(r"[A-Za-z0-9_-]{43}", credential["secret"])), "Synthetic sharer credential must contain one 32-byte base64url secret")
        require(credential.get("suite") == suite and credential.get("shareBase") == config["shareBase"]
                and temporary_path(credential.get("dataDirectory", "")) == config["dataDirectory"],
                "Synthetic sharer credential must be explicitly scoped to this probe suite, service and temporary database")
    require(isinstance(config.get("query"), str) and bool(config["query"].strip()), "Fixture must name its synthetic song query")
    require(config.get("browser", "webkit") in ("chromium", "firefox", "webkit"), "Probe browser must be chromium, firefox or webkit")
    return config


def argument(args, key):
    require(args.count(key) == 1 and args.index(key) + 1 < len(args), "Probe process is missing an expected isolation argument")
    return args[args.index(key) + 1]


def attach(config):
    discovery = private_json(config["supportDirectory"] / "mcp.json")
    require(discovery.get("app", {}).get("bundleId") == "io.tonebox.baton", "Discovery does not belong to Baton")
    pid = discovery.get("pid")
    require(isinstance(pid, int) and pid > 1, "Invalid probe PID")
    # Read only this discovered probe's command; never enumerate or print other apps.
    command = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True, timeout=5)
    require(command.returncode == 0 and command.stdout.strip(), "The discovered probe process is no longer running")
    args = shlex.split(command.stdout)
    require(argument(args, "-baton.defaultsSuite") == config["suite"], "Discovered process uses a different defaultsSuite")
    executable = temporary_path(args[0])
    require(executable.name == "Baton" and "Debug" in executable.parts, "Attach requires the temporary Debug probe build, not an installed or Release app")
    require(temporary_path(argument(args, "-baton.supportDirectory")) == config["supportDirectory"], "Discovered process uses a different support directory")
    # The DEBUG share base override is an environment key. Inspect only this already
    # validated probe PID, keep the output in memory and never print/store its environment.
    environment = subprocess.run(["ps", "eww", "-p", str(pid), "-o", "command="], capture_output=True, text=True, timeout=5)
    override = re.search(r"(?:^|\s)baton\.share\.baseURL=(\S+)(?:\s|$)", environment.stdout)
    require(environment.returncode == 0 and override and loopback_url(override[1]) == config["shareBase"], "Probe does not use the declared loopback DEBUG share service")
    discovery["url"] = loopback_url(discovery.get("url", ""), allow_path=True)
    require(urlsplit(discovery["url"]).path == "/mcp", "Unexpected probe MCP path")
    require(isinstance(discovery.get("token"), str) and len(discovery["token"]) >= 32, "Probe MCP credential is absent")
    preferences = subprocess.run(["defaults", "export", config["suite"], "-"], capture_output=True, timeout=5)
    require(preferences.returncode == 0, "Cannot read isolated probe preferences")
    try:
        prefs = plistlib.loads(preferences.stdout)
        servers = prefs.get("tonebox.navidrome.servers")
        servers = json.loads(servers) if isinstance(servers, (bytes, str)) else servers
        urls = [server["urlString"] for server in servers] if servers else [prefs.get("tonebox.navidrome.url", "")]
    except Exception:
        raise ProbeFailure("Cannot verify the probe's synthetic Navidrome configuration") from None
    require(urls and all(loopback_url(url) == config["navidromeBase"] for url in urls), "Probe Navidrome configuration does not match the declared local fixture")
    # No consent write, no UI simulation: a real first manual share is a prerequisite.
    require(prefs.get("baton.share.disclosureSeen") is True,
            "Manual first-share consent is absent. Use the isolated probe's Share composer, review the disclosure and send its synthetic song once; then rerun. This script never sets consent.")
    return discovery


class MCP:
    def __init__(self, discovery):
        self.url = discovery["url"]
        self.headers = {"Authorization": "Bearer " + discovery["token"], "Content-Type": "application/json", "Accept": "application/json, text/event-stream"}

    def call(self, method, params, identifier):
        payload = json.dumps({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params}).encode()
        with OPENER.open(Request(self.url, data=payload, headers=self.headers, method="POST"), timeout=90) as response:
            if response.headers.get("Mcp-Session-Id"):
                self.headers["Mcp-Session-Id"] = response.headers["Mcp-Session-Id"]
            text = response.read().decode()
        if text.startswith("data:"):
            text = "\n".join(line[5:].strip() for line in text.splitlines() if line.startswith("data:"))
        return json.loads(text)


def save_private(path, value):
    path = temporary_path(path, must_exist=False)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w") as output:
        json.dump(value, output, indent=2)


def share_row(config, share_id):
    db = temporary_path(config["dataDirectory"] / "share.sqlite")
    with sqlite3.connect(db.as_uri() + "?mode=ro", uri=True) as connection:
        row = connection.execute("SELECT status, plays, listened30, expires_at FROM shares WHERE id=?", (share_id,)).fetchone()
    require(row is not None, "MCP-created share did not arrive in the declared local service")
    return row


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture")
    parser.add_argument("evidence", nargs="?")
    parser.add_argument("--validate-only", action="store_true")
    args = parser.parse_args(argv)
    evidence = None
    stage = "validate"
    try:
        config = validate_config(private_json(args.fixture))
        discovery = attach(config)
        if args.validate_only:
            print("PASS isolated probe prerequisites; no MCP calls, uploads or browser actions")
            return 0
        evidence = temporary_path(args.evidence, must_exist=False) if args.evidence else Path(tempfile.mkdtemp(prefix="baton-share-probe-evidence-"))
        evidence.mkdir(mode=0o700, parents=True, exist_ok=True)
        stage = "MCP share"
        mcp = MCP(discovery)
        mcp.call("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "sharing-probe", "version": "1"}}, 1)
        response = mcp.call("tools/call", {"name": "music_share", "arguments": {"query": config["query"], "note": "Synthetic local probe", "expires_days": 1}}, 2)
        result = response.get("result", {})
        require(not response.get("error") and not result.get("isError"), "Probe music_share refused; inspect its isolated UI/configuration. No MCP payload was printed")
        try:
            payload = json.loads("\n".join(item.get("text", "") for item in result.get("content", [])))
            link = payload["link"]
            parsed = urlsplit(link)
        except Exception:
            raise ProbeFailure("Probe did not return a share link; payload withheld") from None
        require(parsed.scheme == "http" and f"{parsed.scheme}://{parsed.netloc}" == config["shareBase"], "MCP returned a non-fixture link; browser refused")
        require(bool(re.fullmatch(r"/s/[A-Za-z0-9_-]{22}", parsed.path)) and bool(re.fullmatch(r"[A-Za-z0-9_-]{22}", parsed.fragment)), "MCP link is incomplete; contents withheld")
        share_id = parsed.path.rsplit("/", 1)[-1]
        stage = "ledger ready"
        ledger = private_json(config["supportDirectory"] / "SongShares.json")
        record = next((row for row in ledger.get("records", []) if row.get("id") == share_id), None)
        require(record and record.get("link") == link, "Probe ledger did not preserve the newly-created complete link")
        require(share_row(config, share_id)[0] == "ready", "MCP-created service record is not ready")
        link_file = evidence / "link.json"
        save_private(link_file, {"url": link, "dataDirectory": str(config["dataDirectory"])})
        stage = "browser"
        runner = Path(__file__).resolve().parent.parent / "gateway/Tests/share-player/play-link.mjs"
        browser_evidence = evidence / "browser"
        completed = subprocess.run([config.get("nodeExecutable", "node"), str(runner), str(link_file), str(browser_evidence), config.get("browser", "webkit")], capture_output=True, text=True, timeout=120)
        # The helper's output is redacted; retain it privately and print aggregates only.
        save_private(evidence / "browser-run.json", {"returncode": completed.returncode, "stdout": completed.stdout, "stderr": completed.stderr})
        require(completed.returncode == 0, "Local browser walk failed; read redacted browser result.json")
        browser_result = json.loads((browser_evidence / "result.json").read_text())
        require(browser_result.get("passed") and browser_result.get("receivedEvents", {}).get("play_30s", 0) >= 1, "Browser did not prove the service received a 30-second listen")
        row = share_row(config, share_id)
        require(row[1] >= 1 and row[2] >= 1, "Synthetic service counters did not match browser playback")
        skips = ["manual composer/disclosure, menu and Shared Links UI are prerequisites, not automated by this script"]
        lifecycle = "skipped; no supplied synthetic sharer credential"
        if config.get("sharerCredentialFile"):
            stage = "extend/revoke"
            secret = private_json(config["sharerCredentialFile"])["secret"]
            digest = hashlib.sha256(b"baton-share secret v1\0" + secret.encode()).hexdigest()
            with sqlite3.connect(temporary_path(config["dataDirectory"] / "share.sqlite").as_uri() + "?mode=ro", uri=True) as connection:
                owner = connection.execute("SELECT sharer_digest FROM shares WHERE id=?", (share_id,)).fetchone()
            require(owner and owner[0] == digest, "Supplied synthetic credential does not own the fresh share; refusing lifecycle mutations")
            headers = {"Authorization": "Bearer " + secret, "Content-Type": "application/json"}
            endpoint = config["shareBase"] + "/v1/share/shares/" + share_id
            with OPENER.open(Request(endpoint, data=json.dumps({"extendBySeconds": 86400}).encode(), headers=headers, method="PATCH"), timeout=10) as changed:
                require(changed.status == 200, "Synthetic share extension failed")
            require(share_row(config, share_id)[3] > row[3], "Synthetic share expiry did not increase")
            with OPENER.open(Request(endpoint, headers=headers, method="DELETE"), timeout=10) as revoked:
                require(revoked.status == 204, "Synthetic share revocation failed")
            require(share_row(config, share_id)[0] == "revoked", "Synthetic service did not revoke the share")
            lifecycle = "API extend/revoke verified; app UI/ledger refresh not automated"
        else:
            skips.append("API extend/revoke: no supplied synthetic sharer credential; no keychain reads")
        summary = {"passed": True, "nativeMCPShare": True, "ledgerPreservedKey": True,
                   "browser": browser_result["engine"], "fixtureBuild": "DEBUG attach-only; signed Release and device acceptance remain separate",
                   "serviceReady": True, "browserPlaybackSeconds": browser_result["actualPlaybackSeconds"],
                   "servicePlays": row[1], "serviceListened30s": row[2], "receivedEvents": browser_result["receivedEvents"],
                   "lifecycle": lifecycle, "skips": skips}
        save_private(evidence / "result.json", summary)
        print(json.dumps(summary))
        return 0
    except ProbeFailure as error:
        summary = {"passed": False, "stage": stage, "message": str(error)}
    except Exception as error:
        # urllib/JSON/process exceptions can embed URLs or payloads. Keep only category.
        summary = {"passed": False, "stage": stage, "message": type(error).__name__ + "; sensitive details withheld"}
    if evidence:
        save_private(evidence / "result.json", summary)
    print(json.dumps(summary), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
