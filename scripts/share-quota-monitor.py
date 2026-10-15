#!/usr/bin/env python3
"""Inactive by default. --dry-run reads fixture JSON; --activate runs an approved notifier.

The host-only --container source reads the existing mode-0600 share.env and passes
its token via stdin to curl inside the container, never in argv or a shell command.
Only quota aggregates and level transitions reach output, state or the notifier.
"""
from __future__ import annotations

import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

_spec = importlib.util.spec_from_file_location("share_quota_check", Path(__file__).with_name("share-quota-check.py"))
_checker = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_checker)


def fetch_report(env_file: Path, runner=subprocess.run) -> object:
    info = env_file.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise ValueError("environment file must be owned by this user and mode 0600")
    tokens = [line.split("=", 1)[1] for line in env_file.read_text().splitlines()
              if line.startswith("BATON_SHARE_ADMIN_TOKEN=")]
    if len(tokens) != 1 or not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", tokens[0]):
        raise ValueError("invalid admin credential")
    # Curl reads the header from its own stdin. No subprocess argv, environment,
    # remote shell, exception text or output contains the token.
    result = runner(["docker", "exec", "-i", "baton-share", "curl", "--disable", "--noproxy", "*", "--silent", "--show-error",
                     "--fail", "--max-time", "10", "--config", "-",
                     "http://127.0.0.1:8790/v1/share/admin/stats?days=1"],
                    input=f'header = "Authorization: Bearer {tokens[0]}"\n',
                    capture_output=True, text=True, check=True, timeout=15)
    if len(result.stdout) > 1024 * 1024:
        raise ValueError("oversized report")
    return json.loads(result.stdout)


def transition(previous: str | None, current: str, message: str) -> dict | None:
    if previous == current or (previous is None and current == "ok"):
        return None
    return {"service": "baton-share", "event": "recovered" if current == "ok" else "alert",
            "previous": previous, "level": current, "message": message}


def validate_notifier(path: Path) -> None:
    if not path.is_absolute() or not path.is_file():
        raise ValueError("approved notifier must be an absolute executable file")
    info = path.stat()
    if stat.S_IMODE(info.st_mode) & 0o022 or not os.access(path, os.X_OK):
        raise ValueError("notifier must be executable and not writable by group or others")


def notify_hook(path: Path, event: dict) -> None:
    validate_notifier(path)
    subprocess.run([str(path)], input=json.dumps(event), text=True, capture_output=True, check=True, timeout=15)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true", help="no state writes and no notifier execution")
    mode.add_argument("--activate", action="store_true", help="requires approved notifier and state paths")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--report", help="fixture JSON file or - for stdin")
    source.add_argument("--container", action="store_true", help="explicit host-only admin fetch")
    parser.add_argument("--env-file", type=Path, default=Path.home() / "baton-share/share.env")
    parser.add_argument("--threshold", type=int, default=80)
    parser.add_argument("--state", type=Path)
    parser.add_argument("--notify-command", type=Path)
    args = parser.parse_args()
    if args.activate and (args.state is None or args.notify_command is None):
        parser.error("--activate requires --state and an owner-approved --notify-command")
    if args.activate:
        try:
            validate_notifier(args.notify_command)
        except (OSError, ValueError):
            print("UNKNOWN share quota monitor: approved notifier unavailable")
            return 2
    try:
        if args.container:
            report = fetch_report(args.env_file)
        elif args.report == "-":
            report = json.load(sys.stdin)
        else:
            report = json.loads(Path(args.report).read_text())
    except (OSError, ValueError, subprocess.SubprocessError):
        report = {"error": "unavailable"}
    code, message = _checker.assess(report, args.threshold)
    level = {0: "ok", 1: "warning", 2: "unknown"}[code]
    if args.dry_run:
        print(json.dumps({"dryRun": True, "level": level, "message": message,
                          "event": transition(None, level, message)}, sort_keys=True))
        return code
    try:
        if not args.state.is_absolute():
            raise ValueError("state path must be absolute")
        args.state.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if stat.S_IMODE(args.state.parent.stat().st_mode) & 0o077:
            raise ValueError("state directory must be private")
        with open(args.state.with_suffix(".lock"), "a", encoding="utf-8") as lock:
            os.chmod(lock.name, 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX)
            previous = None
            pending = None
            if args.state.exists():
                stored = json.loads(args.state.read_text())
                previous = stored.get("level")
                pending = stored.get("pending")
                if (previous not in ("ok", "warning", "unknown", None)
                        or (previous is None and pending is None)):
                    raise ValueError("invalid monitor state")
                if pending is not None and (not isinstance(pending, dict)
                        or set(pending) != {"level", "previous"}
                        or pending["level"] not in ("ok", "warning", "unknown")
                        or pending["previous"] not in (None, "ok", "warning", "unknown")):
                    raise ValueError("invalid pending transition")

            def save_state(data):
                temporary = args.state.with_suffix(".new")
                descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
                os.fchmod(descriptor, 0o600)
                with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                    json.dump(data, stream)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, args.state)

            basis = previous
            if pending is not None:
                basis = pending["previous"] if pending["level"] == level else pending["level"]
            event = transition(basis, level, message)
            if event is not None:
                # An uncertain provider response might have delivered a warning.
                # Record the attempt without advancing accepted state, so a later
                # recovery is sent even after an initial warning attempt failed.
                save_state({"level": previous, "pending": {"level": level, "previous": basis}})
                notify_hook(args.notify_command, event)
            save_state({"level": level})
        print(message)
        return code
    except (OSError, ValueError, subprocess.SubprocessError):
        print("UNKNOWN share quota monitor: state or approved notifier unavailable")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
