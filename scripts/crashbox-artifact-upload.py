#!/usr/bin/env python3
"""Validate Baton's upload credential and send one exact retained dSYM.

The credential is read through a held descriptor and is passed to curl on
standard input as configuration. It never appears in argv, stdout, stderr, or
the receipt written beside the archive.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
from typing import Any
from uuid import UUID


MAX_CREDENTIAL_BYTES = 8_192
MAX_ARCHIVE_BYTES = 128 * 1024 * 1024
MAX_RESPONSE_BYTES = 8_192
DSYM_URL = "https://ingest.crashbox.dev/artifacts/v1/dsym"
SOURCE_MAP_URL = "https://ingest.crashbox.dev/artifacts/v1/source-map"
TOKEN = re.compile(r"cbu1_[A-Za-z0-9_-]{43}\Z")
RELEASE = re.compile(
    r"io\.tonebox\.baton@[0-9]+(?:\.[0-9]+)*\+[0-9]+\.[0-9a-f]{40}\Z"
)
ARCHIVE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,254}\.dSYM\.zip\Z")
EXPECTED_CREDENTIAL_KEYS = {
    "dsym_url",
    "expires_at",
    "label",
    "project_id",
    "project_slug",
    "scope",
    "source_map_url",
    "token",
    "version",
}
EXPECTED_RECEIPT_KEYS = {
    "artifact_id",
    "project_id",
    "release",
    "sha256",
    "state",
    "type",
}
LEGACY_RECEIPT_KEYS = {"artifact_id", "project_id", "sha256", "type"}


class Refused(Exception):
    """One stable, payload-free local refusal."""


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    document: dict[str, Any] = {}
    for key, value in pairs:
        if key in document:
            raise ValueError("duplicate key")
        document[key] = value
    return document


def _open_held(path: Path, maximum: int, *, private: bool) -> tuple[int, os.stat_result]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise Refused("file_unavailable") from exc
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise Refused("file_not_regular")
        if private and (
            before.st_uid != os.geteuid() or stat.S_IMODE(before.st_mode) != 0o600
        ):
            raise Refused("credential_permissions_invalid")
        if not 1 <= before.st_size <= maximum:
            raise Refused("file_size_invalid")
        return descriptor, before
    except Exception:
        os.close(descriptor)
        raise


def _read_held(path: Path, maximum: int, *, private: bool) -> tuple[bytes, int]:
    descriptor, before = _open_held(path, maximum, private=private)
    try:
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(remaining, 64 * 1024))
            if not chunk:
                raise Refused("file_changed_during_read")
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = b"".join(chunks)
        after = os.fstat(descriptor)
        if (
            after.st_dev != before.st_dev
            or after.st_ino != before.st_ino
            or after.st_size != before.st_size
            or after.st_mtime_ns != before.st_mtime_ns
        ):
            raise Refused("file_changed_during_read")
        os.lseek(descriptor, 0, os.SEEK_SET)
        return payload, descriptor
    except Exception:
        os.close(descriptor)
        raise


def _credential(path: Path, expected_project: str) -> tuple[dict[str, Any], int]:
    payload, descriptor = _read_held(path, MAX_CREDENTIAL_BYTES, private=True)
    try:
        try:
            document = json.loads(payload, object_pairs_hook=_unique_object)
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            raise Refused("credential_shape_invalid") from exc
        if not isinstance(document, dict) or set(document) != EXPECTED_CREDENTIAL_KEYS:
            raise Refused("credential_shape_invalid")
        if (
            type(document["version"]) is not int
            or document["version"] != 1
            or document["scope"] != "upload"
            or document["project_slug"] != expected_project
            or document["dsym_url"] != DSYM_URL
            or document["source_map_url"] != SOURCE_MAP_URL
            or not isinstance(document["label"], str)
            or not 1 <= len(document["label"].encode("utf-8")) <= 64
            or not isinstance(document["project_id"], str)
            or not isinstance(document["expires_at"], str)
            or not isinstance(document["token"], str)
            or TOKEN.fullmatch(document["token"]) is None
        ):
            raise Refused("credential_shape_invalid")
        try:
            project_id = str(UUID(document["project_id"]))
            expires_at = datetime.strptime(
                document["expires_at"], "%Y-%m-%dT%H:%M:%SZ"
            ).replace(tzinfo=timezone.utc)
        except (TypeError, ValueError) as exc:
            raise Refused("credential_shape_invalid") from exc
        if project_id != document["project_id"]:
            raise Refused("credential_shape_invalid")
        if expires_at <= datetime.now(timezone.utc):
            raise Refused("credential_expired")
        return document, descriptor
    except Exception:
        os.close(descriptor)
        raise


def _archive(path: Path) -> tuple[str, int]:
    if ARCHIVE_NAME.fullmatch(path.name) is None:
        raise Refused("archive_name_invalid")
    descriptor, before = _open_held(path, MAX_ARCHIVE_BYTES, private=False)
    digest = hashlib.sha256()
    try:
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        after = os.fstat(descriptor)
        if (
            after.st_dev != before.st_dev
            or after.st_ino != before.st_ino
            or after.st_size != before.st_size
            or after.st_mtime_ns != before.st_mtime_ns
        ):
            raise Refused("file_changed_during_read")
        os.lseek(descriptor, 0, os.SEEK_SET)
        return digest.hexdigest(), descriptor
    except Exception:
        os.close(descriptor)
        raise


def _receipt(
    payload: bytes, *, project_id: str, release: str, digest: str
) -> dict[str, str]:
    if not 1 <= len(payload) <= MAX_RESPONSE_BYTES:
        raise Refused("response_size_invalid")
    try:
        document = json.loads(payload, object_pairs_hook=_unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise Refused("response_invalid") from exc
    if not isinstance(document, dict) or set(document) != EXPECTED_RECEIPT_KEYS:
        raise Refused("response_invalid")
    if not all(isinstance(value, str) for value in document.values()):
        raise Refused("response_invalid")
    try:
        artifact_id = str(UUID(document["artifact_id"]))
    except (TypeError, ValueError) as exc:
        raise Refused("response_invalid") from exc
    if (
        artifact_id != document["artifact_id"]
        or document["project_id"] != project_id
        or document["release"] != release
        or document["sha256"] != digest
        or document["state"] != "ready"
        or document["type"] != "apple_dsym"
    ):
        raise Refused("response_mismatch")
    return document


def _write_receipt(path: Path, document: dict[str, str]) -> None:
    payload = (
        json.dumps(document, separators=(",", ":"), sort_keys=True).encode("utf-8")
        + b"\n"
    )
    if path.exists() or path.is_symlink():
        descriptor = -1
        try:
            existing_payload, descriptor = _read_held(
                path, MAX_RESPONSE_BYTES, private=False
            )
            metadata = os.fstat(descriptor)
            os.close(descriptor)
            descriptor = -1
            existing = json.loads(existing_payload, object_pairs_hook=_unique_object)
        except (
            OSError,
            UnicodeDecodeError,
            json.JSONDecodeError,
            ValueError,
            Refused,
        ) as exc:
            raise Refused("receipt_conflict") from exc
        finally:
            if descriptor >= 0:
                os.close(descriptor)
        if metadata.st_uid != os.geteuid():
            raise Refused("receipt_conflict")
        mode = stat.S_IMODE(metadata.st_mode)
        if existing == document:
            if mode != 0o600:
                raise Refused("receipt_conflict")
            return
        legacy = {key: document[key] for key in LEGACY_RECEIPT_KEYS}
        if existing != legacy or mode not in {0o600, 0o644}:
            raise Refused("receipt_conflict")
        # `scripts/upload-dsym.sh` wrote this exact four-key receipt before the
        # CI credential path existed. Only an exact identity match may migrate
        # it, and only after Crashbox has returned the current six-key receipt.
        # The atomic replacement below both adds release/state provenance and
        # narrows the old mode-0644 file to the current mode-0600 contract.
    temporary = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0)
    descriptor = -1
    try:
        descriptor = os.open(temporary, flags, 0o600)
        written = 0
        while written < len(payload):
            count = os.write(descriptor, payload[written:])
            if count <= 0:
                raise OSError("short receipt write")
            written += count
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.replace(temporary, path)
    except OSError as exc:
        raise Refused("receipt_write_failed") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _safe_summary(document: dict[str, Any]) -> dict[str, Any]:
    return {
        "configured": True,
        "expires_at": document["expires_at"],
        "label": document["label"],
        "project_id": document["project_id"],
        "project_slug": document["project_slug"],
        "scope": document["scope"],
    }


def _check(path: Path, expected_project: str) -> int:
    document, descriptor = _credential(path, expected_project)
    os.close(descriptor)
    print(json.dumps(_safe_summary(document), separators=(",", ":"), sort_keys=True))
    return 0


def _upload(
    credential_path: Path,
    archive_path: Path,
    release: str,
    expected_project: str,
) -> int:
    if RELEASE.fullmatch(release) is None:
        raise Refused("release_invalid")
    credential, credential_descriptor = _credential(credential_path, expected_project)
    archive_descriptor = -1
    try:
        digest, archive_descriptor = _archive(archive_path)
        curl = shutil.which("curl")
        if curl is None:
            raise Refused("curl_unavailable")
        authorization = (
            f'header = "Authorization: Bearer {credential["token"]}"\n'.encode("ascii")
        )
        try:
            result = subprocess.run(
                (
                    curl,
                    "--fail-with-body",
                    "--silent",
                    "--show-error",
                    "--request",
                    "POST",
                    "--proto",
                    "=https",
                    "--tlsv1.2",
                    "--connect-timeout",
                    "10",
                    "--max-time",
                    "300",
                    "--max-filesize",
                    str(MAX_RESPONSE_BYTES),
                    "--config",
                    "-",
                    "--header",
                    "Content-Type: application/octet-stream",
                    "--header",
                    f"X-Crashbox-Filename: {archive_path.name}",
                    "--header",
                    f"X-Crashbox-Release: {release}",
                    "--data-binary",
                    f"@/dev/fd/{archive_descriptor}",
                    credential["dsym_url"],
                ),
                input=authorization,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=330,
                check=False,
                pass_fds=(archive_descriptor,),
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise Refused("upload_transport_failed") from exc
        if result.returncode != 0:
            raise Refused("upload_transport_failed")
        receipt = _receipt(
            result.stdout,
            project_id=credential["project_id"],
            release=release,
            digest=digest,
        )
        _write_receipt(Path(f"{archive_path}.receipt.json"), receipt)
        print(json.dumps(receipt, separators=(",", ":"), sort_keys=True))
        return 0
    finally:
        os.close(credential_descriptor)
        if archive_descriptor >= 0:
            os.close(archive_descriptor)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Upload one Baton dSYM to Crashbox")
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("check")
    check.add_argument("credential_file", type=Path)
    check.add_argument(
        "--project", choices=("baton-macos", "baton-ios"), required=True
    )
    upload = commands.add_parser("upload")
    upload.add_argument("credential_file", type=Path)
    upload.add_argument("archive", type=Path)
    upload.add_argument("release")
    upload.add_argument(
        "--project", choices=("baton-macos", "baton-ios"), required=True
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "check":
            return _check(args.credential_file, args.project)
        return _upload(
            args.credential_file,
            args.archive,
            args.release,
            args.project,
        )
    except Refused as exc:
        print(f"Crashbox artifact upload refused: {exc}", file=sys.stderr)
        return 1
    except Exception:
        print("Crashbox artifact upload refused: internal_error", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
