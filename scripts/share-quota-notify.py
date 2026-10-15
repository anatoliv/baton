#!/usr/bin/env python3
"""SES first, restricted Tonebox push on failure; inactive until owner setup."""

from __future__ import annotations

import argparse
import fcntl
import importlib.util
import json
import os
import re
import stat
import subprocess
import sys
import urllib.request
import uuid
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "quota_ses", Path(__file__).with_name("share-quota-notify-ses.py")
)
ses = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ses)
ENDPOINT = "https://api.tonebox.io/api/v1/quota-push/events"
LIMIT = 4096
_GRANT = re.compile(r"tbqp1\.[A-Za-z0-9_-]{43}\Z")


def private_json(path: Path) -> dict:
    if not path.is_absolute():
        raise ValueError("private path must be absolute")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) != 0o600
        ):
            raise ValueError("private input must be an owned mode-0600 file")
        raw = stream.read(LIMIT + 1)
    if len(raw) > LIMIT:
        raise ValueError("private input too large")
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("object required")
    return value


def push_input(event: dict, request_id: str) -> dict:
    ses.build_message(event)  # Existing aggregate-only validation; no SMTP.
    used = capacity = None
    if event["level"] != "unknown":
        match = re.fullmatch(
            r"(?:WARNING|OK) share quota: ([0-9]+) of ([0-9]+) bytes "
            r"\([0-9]+\.[0-9]%\); threshold ([0-9]+)%",
            event["message"],
        )
        used, capacity, threshold = map(int, match.groups())
        if threshold != 80 or not 0 <= used < 2**63 or not 1 <= capacity < 2**63:
            raise ValueError("invalid quota measurement")
        if (used * 100 >= capacity * 80) != (event["level"] == "warning"):
            raise ValueError("measurement disagrees with level")
    return {
        "request_id": request_id,
        "service": "baton-share",
        "level": event["level"],
        "used_bytes": used,
        "capacity_bytes": capacity,
        "threshold": 80,
    }


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def send_push(event: dict, request_id: str, config_path: Path) -> None:
    config = private_json(config_path)
    if (
        set(config) != {"grant"}
        or not isinstance(config["grant"], str)
        or not _GRANT.fullmatch(config["grant"])
    ):
        raise ValueError("invalid restricted grant input")
    request = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(push_input(event, request_id)).encode(),
        headers={
            "Authorization": "Bearer " + config["grant"],
            "Content-Type": "application/json",
            "User-Agent": "Baton-quota-monitor/1",
        },
        method="POST",
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
    with opener.open(request, timeout=4) as response:
        raw = response.read(LIMIT + 1)
        if response.status != 200 or len(raw) > LIMIT:
            raise ValueError("push unavailable")
        receipt = json.loads(raw)
    if (
        not isinstance(receipt, dict)
        or set(receipt) != {"accepted", "duplicate", "delivered", "targets", "failed"}
        or receipt["accepted"] is not True
        or not isinstance(receipt["duplicate"], bool)
        or any(
            type(receipt[k]) is not int or not 0 <= receipt[k] <= 10000
            for k in ("delivered", "targets", "failed")
        )
        or receipt["delivered"] < 1
        or receipt["targets"] != receipt["delivered"] + receipt["failed"]
    ):
        raise ValueError("no accepted push target")


def send_primary(event: dict, command: Path) -> bool:
    try:
        info = command.lstat()
        if (
            not command.is_absolute()
            or not stat.S_ISREG(info.st_mode)
            or info.st_mode & 0o022
            or not os.access(command, os.X_OK)
        ):
            return False  # Never execute an unsafe primary; fallback remains scoped.
        result = subprocess.run(
            [str(command)],
            input=json.dumps(event),
            text=True,
            capture_output=True,
            timeout=6,
        )
        return result.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def route(
    event: dict, state_path: Path, primary_command: Path, config_path: Path
) -> None:
    push_input(event, str(uuid.uuid4()))  # Validate before either provider.
    parent = state_path.parent.stat()
    if (
        not state_path.is_absolute()
        or not stat.S_ISDIR(parent.st_mode)
        or parent.st_uid != os.geteuid()
        or stat.S_IMODE(parent.st_mode) & 0o077
    ):
        raise ValueError("private state directory required")
    descriptor = os.open(
        state_path.with_suffix(".lock"),
        os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
        0o600,
    )
    with os.fdopen(descriptor, "w") as lock:
        info = os.fstat(lock.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
            raise ValueError("private regular lock required")
        os.fchmod(lock.fileno(), 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = (
            private_json(state_path)
            if state_path.exists()
            else {"push_open": False, "pending": None}
        )
        if set(state) != {"push_open", "pending"} or not isinstance(
            state["push_open"], bool
        ):
            raise ValueError("invalid route state")
        pending = state["pending"]
        if pending is not None:
            if (
                not isinstance(pending, dict)
                or set(pending) != {"event", "request_id", "primary_accepted"}
                or not isinstance(pending["primary_accepted"], bool)
            ):
                raise ValueError("invalid pending route")
            if (
                not isinstance(pending["request_id"], str)
                or str(uuid.UUID(pending["request_id"])) != pending["request_id"]
            ):
                raise ValueError("invalid request identity")
            push_input(pending["event"], pending["request_id"])
        if pending is None or pending["event"]["level"] != event["level"]:
            pending = {
                "event": event,
                "request_id": str(uuid.uuid4()),
                "primary_accepted": False,
            }
        state["pending"] = pending

        def save():
            fd = os.open(
                state_path.with_suffix(".new"),
                os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW,
                0o600,
            )
            with os.fdopen(fd, "w") as output:
                os.fchmod(output.fileno(), 0o600)
                json.dump(state, output)
                output.flush()
                os.fsync(output.fileno())
            os.replace(state_path.with_suffix(".new"), state_path)

        save()
        if not pending["primary_accepted"]:
            pending["primary_accepted"] = send_primary(
                pending["event"], primary_command
            )
            save()
        needs_push = not pending["primary_accepted"] or (
            event["level"] == "ok" and state["push_open"]
        )
        if needs_push:
            if event["level"] != "ok":
                state["push_open"] = True  # Also compensate an uncertain push timeout.
                save()
            send_push(pending["event"], pending["request_id"], config_path)
            if event["level"] == "ok":
                state["push_open"] = False
        state["pending"] = None
        save()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--state",
        type=Path,
        default=Path.home() / "baton-share/monitor/route-state.json",
    )
    parser.add_argument(
        "--ses-command",
        type=Path,
        default=Path(__file__).with_name("share-quota-notify-ses.py"),
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=Path.home() / "baton-share/monitor/tonebox-push.json",
    )
    args = parser.parse_args()
    try:
        raw = sys.stdin.buffer.read(LIMIT + 1)
        if len(raw) > LIMIT:
            raise ValueError("event too large")
        route(json.loads(raw), args.state, args.ses_command, args.config)
        print("Baton quota notifier: accepted route; human receipt unverified")
        return 0
    except (OSError, ValueError, TypeError, RecursionError, subprocess.SubprocessError):
        print("Baton quota notifier: route unavailable", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
