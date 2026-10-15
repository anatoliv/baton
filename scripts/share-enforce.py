#!/usr/bin/env python3
"""Private host-only operator client. Default: read-only plan, saved for review.

No token provisioning, remote shell, notification or legal policy. Applying requires
--apply and the exact mode-0600 signed plan file. Credentials and bodies go only to
curl stdin inside the existing container. The server capability is off by default.
"""
from __future__ import annotations
import argparse
import base64
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import uuid

ACTIONS = {"disable-share", "restore-share", "suspend-sharer", "unsuspend-sharer", "purge-disabled-share", "review-preservation"}
PRESERVATION_FIELDS = {"reviewUntil", "preservationDeadline", "courtReviewRequired", "expectedRevision"}
PRESERVATION_METADATA = {"remainingLifetimeSeconds", "preservationStartedAt", "preservationCeiling", "reviewUntil", "courtReviewRequired"}
DAY = 86400
REFERENCE = re.compile(r"[A-Za-z0-9_-]{1,64}\Z")
SHARE_ID = re.compile(r"[A-Za-z0-9_-]{22}\Z")
LIMIT = 65536


def private_read(path: Path) -> str:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "r", encoding="utf-8") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise ValueError("private file must be owned by this user and mode 0600")
        text = stream.read(LIMIT + 1)
        if len(text.encode()) > LIMIT:
            raise ValueError("private file is oversized")
        return text


def capability(path: Path) -> str:
    values = {}
    for line in private_read(path).splitlines():
        if line.startswith("BATON_SHARE_") and "=" in line:
            key, value = line.split("=", 1)
            if key in values:
                raise ValueError("duplicate configuration")
            values[key] = value
    token = values.get("BATON_SHARE_OPERATOR_TOKEN", "")
    if values.get("BATON_SHARE_ENFORCEMENT_ENABLED") != "1" or not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", token):
        raise ValueError("explicit operator capability unavailable")
    if token == values.get("BATON_SHARE_ADMIN_TOKEN"):
        raise ValueError("statistics capability cannot authorize writes")
    return token


def canonical_reference(value: object) -> bool:
    if not isinstance(value, str) or not SHARE_ID.fullmatch(value):
        return False
    raw = base64.urlsafe_b64decode(value + "==")
    return len(raw) == 16 and base64.urlsafe_b64encode(raw).decode().rstrip("=") == value


def validate_request(request: object) -> dict:
    common = {"operationID", "action", "caseReference", "reasonCode"}
    if not isinstance(request, dict) or set(request) - PRESERVATION_FIELDS not in (common | {"shareID"}, common | {"suspensionReference"}) or request.get("action") not in ACTIONS:
        raise ValueError("invalid operator request")
    if not all(isinstance(value, str) for key, value in request.items() if key not in PRESERVATION_FIELDS):
        raise ValueError("invalid operator request")
    if "suspensionReference" in request:
        if request["action"] != "unsuspend-sharer" or not canonical_reference(request["suspensionReference"]):
            raise ValueError("invalid suspension reference")
    elif not SHARE_ID.fullmatch(request["shareID"]):
        raise ValueError("invalid operator reference")
    if not all(REFERENCE.fullmatch(request[k]) for k in ("caseReference", "reasonCode")):
        raise ValueError("invalid operator reference")
    if str(uuid.UUID(request["operationID"])) != request["operationID"]:
        raise ValueError("operation UUID must be canonical")
    fields = set(request) & PRESERVATION_FIELDS
    if fields:
        if request["action"] not in {"disable-share", "suspend-sharer", "review-preservation"}:
            raise ValueError("invalid preservation action")
        if fields & {"reviewUntil", "preservationDeadline"} and not {"reviewUntil", "preservationDeadline"} <= fields:
            raise ValueError("preservation requires both reviewed dates")
        for key in fields - {"courtReviewRequired"}:
            maximum = 253402127999 if key == "reviewUntil" else 253402300799
            if type(request[key]) is not int or not 1 <= request[key] <= maximum:
                raise ValueError("invalid preservation bound")
        if "courtReviewRequired" in fields and type(request["courtReviewRequired"]) is not bool:
            raise ValueError("invalid court review state")
        if "expectedRevision" in fields and request["action"] != "review-preservation":
            raise ValueError("revision applies only to a case review")
        if "reviewUntil" in fields and request["preservationDeadline"] < request["reviewUntil"] + 2 * DAY:
            raise ValueError("preservation requires the review buffer")
    if request["action"] == "review-preservation" and fields != PRESERVATION_FIELDS:
        raise ValueError("case review requires dates, court state and revision")
    return request


def validate_plan(plan: object) -> dict:
    keys = {"request", "plannedAt", "validUntil", "targetFingerprint", "sharerRevision", "affected", "signature"}
    if not isinstance(plan, dict) or set(plan) != keys:
        raise ValueError("invalid reviewed plan")
    validate_request(plan["request"])
    if not isinstance(plan["affected"], list) or len(plan["affected"]) > 200:
        raise ValueError("invalid reviewed scope")
    for field in ("targetFingerprint", "signature"):
        if not isinstance(plan[field], str) or not re.fullmatch(r"[a-f0-9]{64}", plan[field]):
            raise ValueError("invalid plan proof")
    for field in ("plannedAt", "validUntil", "sharerRevision"):
        if type(plan[field]) is not int or plan[field] < 0:
            raise ValueError("invalid plan revision or time")
    if plan["validUntil"] != plan["plannedAt"] + 600:
        raise ValueError("invalid plan lifetime")
    required = {"id", "revision", "stateFingerprint", "expiresAt", "retentionDeadline", "storedBytes", "restorable"}
    seen = set()
    if "suspensionReference" in plan["request"] and plan["affected"]:
        raise ValueError("reversal cannot affect shares")
    for share in plan["affected"]:
        if not isinstance(share, dict) or not required <= set(share) <= required | {"restorationBlock"} | PRESERVATION_METADATA:
            raise ValueError("invalid reviewed share")
        if not isinstance(share["id"], str) or not SHARE_ID.fullmatch(share["id"]) or share["id"] in seen:
            raise ValueError("invalid reviewed share ID")
        seen.add(share["id"])
        if not isinstance(share["stateFingerprint"], str) or not re.fullmatch(r"[a-f0-9]{64}", share["stateFingerprint"]):
            raise ValueError("invalid share proof")
        if any(type(share[k]) is not int or share[k] < 0 for k in ("revision", "expiresAt", "retentionDeadline", "storedBytes")):
            raise ValueError("invalid reviewed share bounds")
        if type(share["restorable"]) is not bool:
            raise ValueError("invalid reviewed retention")
        metadata = set(share) & PRESERVATION_METADATA
        if metadata:
            if metadata != PRESERVATION_METADATA or type(share["courtReviewRequired"]) is not bool:
                raise ValueError("incomplete preservation details")
            if any(type(share[k]) is not int or share[k] <= 0 for k in metadata - {"courtReviewRequired"}):
                raise ValueError("invalid preservation details")
            if not (share["preservationStartedAt"] <= plan["plannedAt"]
                    and share["preservationCeiling"] == share["preservationStartedAt"] + 90 * DAY
                    and share["preservationStartedAt"] < share["retentionDeadline"] <= share["preservationCeiling"]
                    and share["reviewUntil"] + 2 * DAY <= share["retentionDeadline"]
                    and share["remainingLifetimeSeconds"] <= 30 * DAY):
                raise ValueError("invalid preservation ceiling or lifetime")
        elif share["retentionDeadline"] > share["expiresAt"]:
            raise ValueError("legacy retention cannot extend expiry")
        if "restorationBlock" in share and (not isinstance(share["restorationBlock"], str) or not REFERENCE.fullmatch(share["restorationBlock"])):
            raise ValueError("invalid restoration status")
    return plan


def fetch(token: str, route: str, body: dict | None = None, runner=subprocess.run) -> dict:
    if route not in ("plan", "apply", "suspensions") and not re.fullmatch(r"operations/[a-f0-9-]{36}", route) and not (route.startswith("suspensions/") and canonical_reference(route[len("suspensions/"):])):
        raise ValueError("invalid internal route")
    config = 'header = "Authorization: Bearer ' + token + '"\n'
    if body is not None:
        payload = json.dumps(body, separators=(",", ":"), sort_keys=True)
        if len(payload.encode()) > LIMIT:
            raise ValueError("oversized operator body")
        config += 'request = "POST"\nheader = "Content-Type: application/json"\n'
        config += "data = " + json.dumps(payload) + "\n"
    result = runner(["docker", "exec", "-i", "baton-share", "curl", "--disable", "--noproxy", "*", "--silent", "--show-error", "--fail",
                     "--max-time", "10", "--config", "-",
                     "http://127.0.0.1:8790/v1/share/admin/enforcement/" + route],
                    input=config, capture_output=True, text=True, check=True, timeout=15)
    if len(result.stdout.encode()) > LIMIT:
        raise ValueError("oversized operator response")
    response = json.loads(result.stdout)
    if not isinstance(response, dict):
        raise ValueError("invalid operator response")
    return response


def apply(token: str, plan: dict, runner=subprocess.run) -> dict:
    validate_plan(plan)
    try:
        return fetch(token, "apply", plan, runner)
    except (OSError, subprocess.SubprocessError):
        # One receipt lookup first: a lost response must not cause a new operation.
        try:
            return fetch(token, "operations/" + plan["request"]["operationID"], runner=runner)["receipt"]
        except (OSError, subprocess.SubprocessError):
            # Exactly one retry with the identical UUID/body. No unbounded loop.
            return fetch(token, "apply", plan, runner)


def save_plan(path: Path, plan: dict) -> None:
    validate_plan(plan)
    info = path.parent.stat()
    if not path.is_absolute() or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise ValueError("plan directory must be absolute, owned and private")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(plan, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())


def receipt_output(receipt: dict) -> dict:
    output = {key: receipt[key] for key in ("operationID", "action", "caseReference", "affectedCount", "outcome")}
    if "suspensionReference" in receipt:
        if receipt["action"] != "suspend-sharer" or not canonical_reference(receipt["suspensionReference"]):
            raise ValueError("invalid suspension receipt")
        output["suspensionReference"] = receipt["suspensionReference"]
    return output


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", type=Path, default=Path.home() / "baton-share/share.env")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true")
    mode.add_argument("--recover")
    mode.add_argument("--list-suspensions", action="store_true")
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--action", choices=sorted(ACTIONS))
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--share-id")
    target.add_argument("--suspension-reference")
    parser.add_argument("--cursor")
    parser.add_argument("--case-reference")
    parser.add_argument("--reason-code")
    parser.add_argument("--review-until", type=int, help="Human-reviewed UTC Unix decision date")
    parser.add_argument("--preservation-deadline", type=int, help="UTC Unix cleanup deadline, at least two days later")
    parser.add_argument("--expected-revision", type=int)
    parser.add_argument("--court-review", choices=["required", "cleared"])
    args = parser.parse_args(argv)
    try:
        token = capability(args.env_file)
        preservation = {key: value for key, value in {
            "reviewUntil": args.review_until, "preservationDeadline": args.preservation_deadline,
            "expectedRevision": args.expected_revision,
            "courtReviewRequired": None if args.court_review is None else args.court_review == "required"}.items() if value is not None}
        if preservation and (args.apply or args.recover or args.list_suspensions):
            raise ValueError("preservation choices belong only to a new reviewed plan")
        if args.apply:
            if args.plan is None or any((args.output, args.action, args.share_id, args.case_reference, args.reason_code, args.suspension_reference, args.cursor)):
                raise ValueError("apply requires only the reviewed private plan")
            receipt = apply(token, validate_plan(json.loads(private_read(args.plan))))
            print(json.dumps(receipt_output(receipt)))
        elif args.recover:
            if str(uuid.UUID(args.recover)) != args.recover or any((args.plan, args.output, args.action, args.share_id, args.case_reference, args.reason_code, args.suspension_reference, args.cursor)):
                raise ValueError("invalid recovery request")
            response = fetch(token, "operations/" + args.recover)
            receipt = response["receipt"]
            print(json.dumps({**receipt_output(receipt),
                              "cleanupPending": response["cleanupPending"], "cleanupFailed": response["cleanupFailed"]}))
        elif args.list_suspensions:
            if any((args.plan, args.output, args.action, args.share_id, args.suspension_reference, args.case_reference, args.reason_code)) or (args.cursor is not None and not canonical_reference(args.cursor)):
                raise ValueError("invalid inventory request")
            response = fetch(token, "suspensions" + ("/" + args.cursor if args.cursor else ""))
            if not set(response) <= {"suspensions", "nextCursor"} or "suspensions" not in response or not isinstance(response["suspensions"], list) or len(response["suspensions"]) > 200:
                raise ValueError("invalid inventory response")
            for entry in response["suspensions"]:
                if not isinstance(entry, dict) or set(entry) != {"reference", "revision"} or not canonical_reference(entry["reference"]) or type(entry["revision"]) is not int or entry["revision"] < 1:
                    raise ValueError("invalid inventory entry")
            if response.get("nextCursor") is not None and (not canonical_reference(response["nextCursor"]) or not response["suspensions"] or response["nextCursor"] != response["suspensions"][-1]["reference"]):
                raise ValueError("invalid inventory cursor")
            print(json.dumps(response))
        else:
            if args.output is None or args.plan is not None or args.cursor is not None:
                raise ValueError("read-only planning requires an output path")
            request = validate_request({"operationID": str(uuid.uuid4()), "action": args.action,
                                        **({"suspensionReference": args.suspension_reference} if args.suspension_reference is not None else {"shareID": args.share_id}), "caseReference": args.case_reference,
                                        "reasonCode": args.reason_code, **preservation})
            plan = validate_plan(fetch(token, "plan", request))
            if plan["request"] != request:
                raise ValueError("returned plan does not match requested target")
            save_plan(args.output, plan)
            print(json.dumps({"dryRun": True, "operationID": plan["request"]["operationID"],
                              "action": plan["request"]["action"], "affectedCount": len(plan["affected"])}))
        return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        # Do not echo subprocess errors, request bodies, headers, or credentials.
        print("Operator operation unavailable; no success is confirmed.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
