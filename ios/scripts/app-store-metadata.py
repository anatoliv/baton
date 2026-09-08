#!/usr/bin/env python3
"""The App Store listing, reconciled between the repo and App Store Connect.

    python3 ios/scripts/app-store-metadata.py check    # what differs, and why
    python3 ios/scripts/app-store-metadata.py pull     # adopt live as both desired and observed
    python3 ios/scripts/app-store-metadata.py push     # apply desired to live, where editable

## Why the file has two halves

TBX-5074 put the listing in the repo as a mirror of live. A drift check over a mirror can
only say "these differ", and that single answer covers two situations that need opposite
responses:

  - Someone edited the listing in App Store Connect by hand. The repo is now a lie, the
    tests are guarding a value nobody ships, and this must fail loudly.
  - We changed the repo and live has not caught up, because name, subtitle and keywords are
    only writable on a version in "Prepare for Submission". That is normal and can last
    weeks.

A check that fails on both is red for a month and then ignored, which is how a gate stops
being a gate. So `en-US.json` carries `desired` (what we intend to ship) and `_live` (what
Apple actually had at the last reconciliation). Three states, all distinguishable:

  live != _live                  DRIFT    someone edited the web form   -> fail
  desired != live, live == _live PENDING  waiting on a release          -> report
  all three equal                CLEAN

`push` applies desired and then rewrites `_live`, so the snapshot is only ever updated by
an operation that actually looked at Apple.

One exception, and it is the difference between a working release and an aborted one: the
version-scoped fields cannot be called DRIFT while the snapshot describes a *different*
version from the one being read. See `crossing_versions`.

## Credentials, and the skip that is allowed to happen

Same key the upload uses (`ASC_ISSUER_ID` + `~/.appstoreconnect/private_keys/`), so this
adds no new secrets. Without them, or with no network, `check` prints SKIP and exits 0 —
because a laptop with no ASC key must not fail the whole test suite, and a check everyone
learns to bypass is worse than no check. `--strict` turns that skip into a failure, and
that is what a release runs: a release that skipped its metadata check shipped unchecked.
"""
# `from __future__ import annotations` is load-bearing here, not tidiness: a release runs
# these on macOS's Python 3.9, which evaluates annotations at def time. See asc.py.
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc import ASCError, Client, credentials, find_app  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# `BATON_METADATA_FILE` exists so the test suite can drive a throwaway copy. Overriding it
# in a real run points the tool at a file the tests do not guard, so don't.
METADATA = os.environ.get("BATON_METADATA_FILE") or os.path.join(REPO, "ios", "metadata", "en-US.json")

# Which ASC resource owns which field. Splitting the listing across two resources is Apple's
# design, not ours: the app's identity (name, subtitle) belongs to the app, while the text
# that ships with a build belongs to the version. They also become editable at different
# moments, which is why `push` reports them separately rather than as one result.
APP_INFO_FIELDS = ("name", "subtitle", "privacyPolicyUrl")
VERSION_FIELDS = ("description", "keywords", "promotionalText", "marketingUrl", "supportUrl")
ALL_FIELDS = APP_INFO_FIELDS + VERSION_FIELDS

# States in which Apple accepts a metadata write. Anything not listed is treated as locked,
# which is the safe direction: the cost of being wrong here is a PATCH that Apple rejects
# with a clear error, versus silently reporting success for a write that never landed.
EDITABLE_STATES = {
    "PREPARE_FOR_SUBMISSION",
    "DEVELOPER_REJECTED",
    "REJECTED",
    "METADATA_REJECTED",
    "INVALID_BINARY",
}

CLEAN, PENDING, DRIFT = "clean", "pending", "drift"


# --- the file ---------------------------------------------------------------------------

def load() -> dict:
    with open(METADATA, encoding="utf-8") as handle:
        return json.load(handle)


def save(document: dict) -> None:
    """Write the file back, preserving key order and ending with a newline.

    `indent=2` and `ensure_ascii=False` so the result stays a readable diff — the whole
    point of the file is that a metadata change is reviewable, and an escaped-unicode blob
    is not.
    """
    with open(METADATA, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2, ensure_ascii=False)
        handle.write("\n")


# --- reading Apple ----------------------------------------------------------------------

def pick_version(versions: list[dict]) -> dict:
    """The version this tool acts on: the editable one if there is one, else the newest.

    Both cases are real. During a release there is a draft to write to; the rest of the time
    the only version is the live one, and reading it is how drift is detected at all.
    """
    editable = [v for v in versions if version_state(v) in EDITABLE_STATES]
    if editable:
        return editable[0]
    if not versions:
        raise ASCError("the app has no App Store versions at all")
    return sorted(versions, key=lambda v: v["attributes"].get("versionString", ""))[-1]


def version_state(version: dict) -> str:
    """`appVersionState` when Apple sends it, `appStoreState` otherwise.

    Apple is mid-migration between the two and returns both on most records. Preferring the
    newer one and falling back keeps this working either side of the switch.
    """
    attributes = version["attributes"]
    return attributes.get("appVersionState") or attributes.get("appStoreState") or "UNKNOWN"


def read_live(client: Client, bundle_id: str, locale: str) -> dict:
    """Everything in ALL_FIELDS as Apple currently holds it, plus the ids needed to write.

    Returns the localization record ids alongside the values so `push` does not have to walk
    the same four requests again — and so it cannot walk them a second time and get a
    different answer than the one `check` reported.
    """
    app_id = find_app(client, bundle_id)

    infos = client.get(f"apps/{app_id}/appInfos").get("data", [])
    if not infos:
        raise ASCError("the app has no appInfo record")
    # Same rule as versions: prefer an editable appInfo, since during a release there are two.
    editable_infos = [i for i in infos if (i["attributes"].get("state")
                                           or i["attributes"].get("appStoreState")) in EDITABLE_STATES]
    info = (editable_infos or infos)[0]
    info_state = info["attributes"].get("state") or info["attributes"].get("appStoreState") or "UNKNOWN"

    version = pick_version(client.get(f"apps/{app_id}/appStoreVersions").get("data", []))

    info_loc = localization(client, f"appInfos/{info['id']}/appInfoLocalizations", locale,
                            "app info")
    version_loc = localization(client, f"appStoreVersions/{version['id']}/appStoreVersionLocalizations",
                               locale, "app store version")

    values = {}
    for field in APP_INFO_FIELDS:
        values[field] = info_loc["attributes"].get(field)
    for field in VERSION_FIELDS:
        values[field] = version_loc["attributes"].get(field)

    return {
        "appId": app_id,
        "values": values,
        "appInfoLocalizationId": info_loc["id"],
        "versionLocalizationId": version_loc["id"],
        "appInfoState": info_state,
        "versionState": version_state(version),
        "versionString": version["attributes"].get("versionString"),
    }


def localization(client: Client, path: str, locale: str, what: str) -> dict:
    for record in client.get(path).get("data", []):
        if record["attributes"].get("locale") == locale:
            return record
    raise ASCError(f"no {what} localization for {locale}")


# --- comparing --------------------------------------------------------------------------

def compare(desired: dict, live: dict, observed: dict | None,
            new_version: bool = False) -> tuple[str, dict, dict]:
    """(verdict, drifted, pending) — the whole decision, as a pure function.

    Kept free of the network on purpose: this is the part with the interesting logic, and it
    is the part a test can drive exhaustively without Apple or a mock.

    `new_version` says the version being read is not the one the snapshot was taken against.
    See `crossing_versions` for why that disqualifies the version-scoped half from drift.
    """
    drifted, pending = {}, {}
    for field in ALL_FIELDS:
        want, have = desired.get(field), live.get(field)
        was = (observed or {}).get(field)

        # Version-scoped fields on a version the snapshot has never seen. `_live` holds the
        # PREVIOUS version's localization, which is a different record on Apple's side, so a
        # difference here is not evidence that anybody edited anything.
        across = new_version and field in VERSION_FIELDS

        # No snapshot for this field yet — a field added to the tool after the last
        # reconciliation. It cannot be called drift, because nothing was ever recorded to
        # drift from. Treat a difference as pending and let `pull` or `push` establish it.
        if not across and observed is not None and field in observed and have != was:
            drifted[field] = {"observed": was, "live": have}
        elif want != have:
            pending[field] = {"desired": want, "live": have}

    if drifted:
        return DRIFT, drifted, pending
    return (PENDING if pending else CLEAN), drifted, pending


def show(label: str, changes: dict, keys: tuple[str, str]) -> None:
    for field, change in sorted(changes.items()):
        print(f"  {label} {field}")
        print(f"      {keys[0]}: {abbreviate(change[keys[0]])}")
        print(f"      {keys[1]}: {abbreviate(change[keys[1]])}")


def abbreviate(value) -> str:
    if value is None:
        return "(none)"
    text = str(value).replace("\n", "\\n")
    return text if len(text) <= 110 else text[:107] + "..."


# --- commands ---------------------------------------------------------------------------

def connect(document: dict) -> tuple[Client, dict]:
    key_id, key_path, issuer = credentials()
    client = Client(key_id, key_path, issuer)
    return client, read_live(client, document["bundleId"], document["locale"])


def command_check(args) -> int:
    document = load()
    try:
        _, live = connect(document)
    except ASCError as error:
        # No status means the request never reached Apple (or credentials were absent), which
        # is not evidence about the metadata either way. Fail only where a skip would let a
        # release through unchecked.
        if args.strict:
            print(f"FAIL: cannot check App Store metadata: {error}", file=sys.stderr)
            return 1
        print(f"SKIP: App Store metadata not checked: {error}")
        return 0

    verdict, drifted, pending = compare(
        document["desired"], live["values"], (document.get("_live") or {}).get("values"),
        crossing_versions(document, live))

    print(f"App Store metadata, {document['locale']}, version {live['versionString']} "
          f"({live['versionState']})")

    if drifted:
        print("\nDRIFT — App Store Connect no longer matches the snapshot in the repo.")
        print("Someone edited the listing outside this repo, so the file and its tests are")
        print("guarding values nobody ships. Reconcile deliberately: keep the live change")
        print("with `pull`, or keep the repo's intent and let the next `push` overwrite it.\n")
        show("~", drifted, ("observed", "live"))

    if pending:
        print("\nPENDING — the repo wants changes Apple has not got yet.\n")
        show("+", pending, ("desired", "live"))
        if version_writable(live) or info_writable(live):
            print("\n  A version is editable now: `app-store-metadata.py push` applies these.")
        else:
            print(f"\n  Nothing is editable while the version is {live['versionState']};")
            print("  these ship with the next release, which pushes them automatically.")

    if verdict == CLEAN:
        print("\nCLEAN — repo, snapshot and App Store Connect all agree.")

    if drifted:
        return 1
    if pending and args.strict_pending:
        print("\nFAIL: --strict-pending, and there are unpushed changes.", file=sys.stderr)
        return 1
    return 0


def command_pull(args) -> int:
    """Adopt live as the truth: both the desired values and the snapshot.

    The escape hatch for a deliberate change made in App Store Connect, and the way the file
    was seeded in the first place. It overwrites intent, so it prints what it is discarding.
    """
    document = load()
    try:
        _, live = connect(document)
    except ASCError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    _, drifted, pending = compare(
        document["desired"], live["values"], (document.get("_live") or {}).get("values"),
        crossing_versions(document, live))
    if pending and not args.force:
        print("Refusing to pull: the repo holds changes that are not live yet, and pulling")
        print("would silently discard them. Push them, or re-run with --force.\n")
        show("+", pending, ("desired", "live"))
        return 1

    document["desired"] = dict(live["values"])
    document["_live"] = snapshot(live)
    save(document)
    print(f"Pulled {len(ALL_FIELDS)} fields from version {live['versionString']} "
          f"into {os.path.relpath(METADATA, REPO)}")
    if drifted:
        print(f"  adopted {len(drifted)} field(s) that had drifted: {', '.join(sorted(drifted))}")
    return 0


def command_push(args) -> int:
    """Apply desired to Apple, for whichever half is currently writable.

    Writes only fields that differ. A PATCH containing values Apple already holds is not
    harmless: it is indistinguishable in the audit trail from a real change, and it makes a
    no-op run look like a successful edit.
    """
    document = load()
    try:
        client, live = connect(document)
    except ASCError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    verdict, drifted, pending = compare(
        document["desired"], live["values"], (document.get("_live") or {}).get("values"),
        crossing_versions(document, live))

    if drifted and not args.force:
        print("Refusing to push over drift. App Store Connect holds values this repo has")
        print("never seen, so pushing would overwrite somebody's deliberate edit without")
        print("anyone deciding to. Run `check` to see them, then `pull` or --force.\n",
              file=sys.stderr)
        show("~", drifted, ("observed", "live"))
        return 1

    if not pending:
        print("Nothing to push — App Store Connect already matches the repo.")
        return 0

    wrote, blocked = [], []
    for fields, writable, path, kind in (
        (APP_INFO_FIELDS, info_writable(live),
         f"appInfoLocalizations/{live['appInfoLocalizationId']}", "appInfoLocalizations"),
        (VERSION_FIELDS, version_writable(live),
         f"appStoreVersionLocalizations/{live['versionLocalizationId']}",
         "appStoreVersionLocalizations"),
    ):
        changed = {f: document["desired"][f] for f in fields if f in pending}
        if not changed:
            continue
        if not writable:
            blocked.extend(sorted(changed))
            continue
        if args.dry_run:
            print(f"  would PATCH {kind}: {', '.join(sorted(changed))}")
            wrote.extend(sorted(changed))
            continue
        client.patch(path, {"data": {
            "id": path.split("/")[-1], "type": kind, "attributes": changed,
        }})
        print(f"  patched {kind}: {', '.join(sorted(changed))}")
        wrote.extend(sorted(changed))

    if args.dry_run:
        print("\n--dry-run: nothing was sent and the snapshot was not updated.")
        return 0

    if wrote:
        # Re-read rather than assuming the PATCH did what was asked. Apple normalises some
        # fields (whitespace in keywords, for one), so the snapshot has to record what Apple
        # ended up with or the very next `check` reports drift against our own write.
        after = read_live(client, document["bundleId"], document["locale"])
        document["_live"] = snapshot(after)
        save(document)
        print(f"\nPushed {len(wrote)} field(s) and re-read the result into the snapshot.")

    if blocked:
        print(f"\nStill pending, nothing editable to write them to "
              f"(version is {live['versionState']}): {', '.join(blocked)}")
        return 1 if args.require_all else 0
    return 0


def crossing_versions(document: dict, live: dict) -> bool:
    """Is the version we just read a different one from the version the snapshot describes?

    Found by the first real use of this path (TBX-3928, 2026-09-07). Creating the 1.1 App
    Store version made `check` report DRIFT on `promotionalText` and `push` refuse with
    "Refusing to push over drift" — which would have aborted the release, on the strength of
    an accusation that was simply false. Nobody had touched the web form.

    Apple carries most of the previous version's localization into a new one, but NOT
    promotional text, which starts empty on every version. The snapshot said "1.0 had this
    text"; Apple said "1.1 has none"; the tool concluded somebody deleted it. All three
    statements were true and the conclusion did not follow, because they are two different
    `appStoreVersionLocalizations` records and only one of them is the one `_live` observed.

    So drift — which means, precisely, "someone edited the listing outside this repo" — can
    only be asserted about the version the snapshot was taken against. Across a version
    boundary the version-scoped fields fall back to PENDING, which still reports them and
    still pushes them; what is dropped is the accusation, not the reconciliation. The window
    is one release: the first `push` or `pull` re-snapshots against the new version and
    drift detection resumes in full.

    The app-scoped half (name, subtitle, privacy URL) lives on `appInfo`, not on the
    version, so it keeps its drift check across the boundary — those really are the same
    record either side.
    """
    was = (document.get("_live") or {}).get("appStoreVersion")
    return bool(was) and was != live.get("versionString")


def info_writable(live: dict) -> bool:
    return live["appInfoState"] in EDITABLE_STATES


def version_writable(live: dict) -> bool:
    return live["versionState"] in EDITABLE_STATES


def snapshot(live: dict) -> dict:
    return {
        "observedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "appStoreVersion": live["versionString"],
        "versionState": live["versionState"],
        "values": dict(live["values"]),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)

    check = sub.add_parser("check", help="compare repo, snapshot and live")
    check.add_argument("--strict", action="store_true",
                       help="fail instead of skipping when Apple cannot be reached")
    check.add_argument("--strict-pending", action="store_true",
                       help="also fail when the repo holds changes Apple has not got")
    check.set_defaults(func=command_check)

    pull = sub.add_parser("pull", help="adopt live as desired and snapshot")
    pull.add_argument("--force", action="store_true",
                      help="discard unpushed repo changes")
    pull.set_defaults(func=command_pull)

    push = sub.add_parser("push", help="apply desired to Apple where editable")
    push.add_argument("--dry-run", action="store_true", help="say what would be sent")
    push.add_argument("--force", action="store_true", help="push over drift")
    push.add_argument("--require-all", action="store_true",
                      help="fail if some fields could not be written")
    push.set_defaults(func=command_push)

    args = parser.parse_args()
    try:
        return args.func(args)
    except ASCError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
