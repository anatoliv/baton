#!/usr/bin/env python3
"""Bounded operator-cron runner; retain one payload-free execution receipt."""
import argparse
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import stat
import subprocess
import uuid


def owned(path, mode, directory=False):
    info = path.lstat()
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if not kind(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != mode:
        raise ValueError("unexpected operator file")


def run(root, scheduled=False, invoke=subprocess.run):
    owned(root, 0o700, True)
    for name in ("share-quota-monitor.py", "share-quota-check.py", "notify", "share-quota-notify-ses.py"):
        owned(root / name, 0o755)
    fd = os.open(root / "runner.lock", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as lock:
        owned(root / "runner.lock", 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0  # Preserve the running invocation's receipt.
        receipt = {"startedAt": datetime.now(timezone.utc).isoformat(),
                   "scheduled": scheduled, "runId": str(uuid.uuid4())}
        try:
            result = invoke(["/usr/bin/python3", str(root / "share-quota-monitor.py"),
                             "--activate", "--container", "--threshold", "80",
                             "--state", str(root / "state.json"),
                             "--notify-command", str(root / "notify")],
                            capture_output=True, text=True, timeout=45)
            receipt["monitorExitCode"] = result.returncode
            receipt["level"] = {0: "ok", 1: "warning", 2: "unknown"}.get(result.returncode, "unavailable")
            receipt["deliveryOrStateUnavailable"] = (
                result.returncode not in (0, 1, 2) or
                result.stdout.strip() == "UNKNOWN share quota monitor: state or approved notifier unavailable")
        except (OSError, subprocess.SubprocessError):
            receipt.update(monitorExitCode=2, level="unavailable", deliveryOrStateUnavailable=True)
        receipt["finishedAt"] = datetime.now(timezone.utc).isoformat()
        fd = os.open(root / "last-run.new", os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as out:
            os.fchmod(out.fileno(), 0o600)
            json.dump(receipt, out, sort_keys=True); out.flush(); os.fsync(out.fileno())
        os.replace(root / "last-run.new", root / "last-run.json")
        return 2 if receipt["deliveryOrStateUnavailable"] else receipt["monitorExitCode"]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scheduled", action="store_true")
    args = parser.parse_args()
    try:
        raise SystemExit(run(Path.home() / "baton-share/monitor", args.scheduled))
    except (OSError, ValueError):
        raise SystemExit(2)  # Never print captured child/provider output.
