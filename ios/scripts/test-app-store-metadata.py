#!/usr/bin/env python3
"""Drive `app-store-metadata.py` against a mock App Store Connect.

    python3 ios/scripts/test-app-store-metadata.py

No network, no Apple credentials, no live listing touched, about a second. That matters
more here than usual: the thing under test *writes to the App Store listing*, so the only
honest way to watch its failure paths is against a server that is not Apple's.

The mock implements the four GETs and two PATCHes the tool uses, and lets each test set the
version state — which is the pivot the whole tool turns on and cannot otherwise be exercised,
since the real app has exactly one version and it is READY_FOR_SALE.
"""
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "app-store-metadata.py")

LIVE = {
    "name": "Baton Music",
    "subtitle": "Navidrome & Subsonic player",
    "privacyPolicyUrl": "https://batonmusic.app/privacy.html",
    "description": "Baton plays the music you host yourself.",
    "keywords": "navidrome,subsonic,music,player,self-hosted",
    "promotionalText": "Your library, your server, your phone.",
    "marketingUrl": "https://batonmusic.app",
    "supportUrl": "https://batonmusic.app/help.html",
}

INFO_FIELDS = ("name", "subtitle", "privacyPolicyUrl")


class Mock(http.server.BaseHTTPRequestHandler):
    """Enough of the ASC API to be wrong in the same ways the real one can be."""

    state = "READY_FOR_DISTRIBUTION"
    # Settable so a test can put Apple on a DIFFERENT version from the one the snapshot
    # describes, which is the only way to exercise the version-boundary rule.
    version = "1.0"
    values = {}
    patches = []

    def log_message(self, *args):
        pass

    def _send(self, payload, code=200):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path.lstrip("/")
        if path == "apps":
            return self._send({"data": [{"id": "APPID", "attributes": {
                "bundleId": "io.tonebox.baton"}}]})
        if path == "apps/APPID/appInfos":
            return self._send({"data": [{"id": "INFO", "attributes": {"state": Mock.state}}]})
        if path == "apps/APPID/appStoreVersions":
            return self._send({"data": [{"id": "VER", "attributes": {
                "versionString": Mock.version, "appVersionState": Mock.state}}]})
        if path == "appInfos/INFO/appInfoLocalizations":
            return self._send({"data": [{"id": "ILOC", "attributes": dict(
                {"locale": "en-US"}, **{f: Mock.values[f] for f in INFO_FIELDS})}]})
        if path == "appStoreVersions/VER/appStoreVersionLocalizations":
            return self._send({"data": [{"id": "VLOC", "attributes": dict(
                {"locale": "en-US"},
                **{f: v for f, v in Mock.values.items() if f not in INFO_FIELDS})}]})
        self._send({"errors": [{"detail": f"no route {path}"}]}, 404)

    def do_PATCH(self):
        path = urllib.parse.urlparse(self.path).path.lstrip("/")
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length))
        attributes = body["data"]["attributes"]
        if path not in ("appInfoLocalizations/ILOC", "appStoreVersionLocalizations/VLOC"):
            return self._send({"errors": [{"detail": "no such localization"}]}, 404)
        Mock.patches.append((path, dict(attributes)))
        Mock.values.update(attributes)
        self._send({"data": {"id": body["data"]["id"], "attributes": attributes}})


def start_server():
    server = http.server.HTTPServer(("127.0.0.1", 0), Mock)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_port}"


# --- harness ------------------------------------------------------------------------------

PASSED = FAILED = 0
KEY_PATH = None


def document(desired=None, snapshot=None):
    return {
        "appId": "APPID", "bundleId": "io.tonebox.baton", "locale": "en-US",
        "desired": dict(desired or LIVE),
        "_live": {"observedAt": "2026-01-01T00:00:00Z", "appStoreVersion": "1.0",
                  "versionState": "READY_FOR_DISTRIBUTION",
                  "values": dict(snapshot if snapshot is not None else LIVE)},
    }


def run(args, doc, base, expect_exit, name, expect_in=(), expect_not_in=()):
    """Run the tool over a throwaway metadata file and assert on exit code and output."""
    global PASSED, FAILED
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        json.dump(doc, handle)
        path = handle.name
    environment = dict(os.environ,
                       BATON_METADATA_FILE=path,
                       ASC_API_BASE=base,
                       ASC_ISSUER_ID="00000000-0000-0000-0000-000000000000",
                       ASC_KEY_ID="TESTKEY",
                       ASC_KEY_PATH=KEY_PATH)
    result = subprocess.run([sys.executable, TOOL] + args, capture_output=True, text=True,
                            env=environment)
    output = result.stdout + result.stderr
    problems = []
    if result.returncode != expect_exit:
        problems.append(f"exit {result.returncode}, wanted {expect_exit}")
    for needle in expect_in:
        if needle not in output:
            problems.append(f"missing {needle!r}")
    for needle in expect_not_in:
        if needle in output:
            problems.append(f"unexpected {needle!r}")

    if problems:
        FAILED += 1
        print(f"FAIL  {name}")
        for problem in problems:
            print(f"        {problem}")
        print("      ---- output ----")
        print("      " + output.strip().replace("\n", "\n      ")[:1600])
    else:
        PASSED += 1
        print(f"ok    {name}")
    with open(path, encoding="utf-8") as handle:
        written = json.load(handle)
    os.unlink(path)
    return written


def check(condition, name):
    global PASSED, FAILED
    if condition:
        PASSED += 1
        print(f"ok    {name}")
    else:
        FAILED += 1
        print(f"FAIL  {name}")


# --- the pure comparison, driven directly ------------------------------------------------

def test_compare():
    sys.path.insert(0, HERE)
    import importlib.util
    spec = importlib.util.spec_from_file_location("asm", TOOL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    verdict, drifted, pending = module.compare(LIVE, LIVE, LIVE)
    check(verdict == module.CLEAN and not drifted and not pending, "compare: all equal is CLEAN")

    changed = dict(LIVE, keywords="something,else")
    verdict, drifted, pending = module.compare(LIVE, changed, LIVE)
    check(verdict == module.DRIFT and "keywords" in drifted,
          "compare: live moved away from the snapshot is DRIFT")

    verdict, drifted, pending = module.compare(changed, LIVE, LIVE)
    check(verdict == module.PENDING and "keywords" in pending and not drifted,
          "compare: repo ahead of live is PENDING")

    # Drift wins. If someone edited the web form, that has to surface even when we also have
    # a change waiting — reporting only the pending one would hide the defect behind routine.
    verdict, drifted, pending = module.compare(
        dict(LIVE, name="New Name"), changed, LIVE)
    check(verdict == module.DRIFT and "keywords" in drifted and "name" in pending,
          "compare: drift outranks a pending change, and both are reported")

    # A field the snapshot predates cannot be called drift: nothing was recorded to drift
    # from. Without this a new field in ALL_FIELDS would fail every build until someone pulled.
    partial = {f: v for f, v in LIVE.items() if f != "supportUrl"}
    verdict, drifted, pending = module.compare(LIVE, dict(LIVE, supportUrl="https://new"),
                                               partial)
    check(verdict == module.PENDING and not drifted,
          "compare: a field missing from the snapshot is pending, not drift")

    # The exact shape that fired for real on 2026-09-07: a freshly created App Store version
    # carries the previous version's localization forward EXCEPT promotional text, which
    # starts empty. Compared against a snapshot of the old version that reads as a deletion.
    fresh = dict(LIVE, promotionalText=None)
    verdict, drifted, pending = module.compare(LIVE, fresh, LIVE, True)
    check(verdict == module.PENDING and not drifted and "promotionalText" in pending,
          "compare: an empty field on a NEW version is pending, not drift")

    # And the same input without the version boundary must still be drift, or the fix has
    # simply deleted the check it was meant to narrow.
    verdict, drifted, _ = module.compare(LIVE, fresh, LIVE, False)
    check(verdict == module.DRIFT and "promotionalText" in drifted,
          "compare: the same emptied field on the SAME version is still drift")

    # The app-scoped half lives on `appInfo`, which a new version does not replace. Losing
    # its drift check would mean a hand-edited name shipping unnoticed during a release.
    verdict, drifted, _ = module.compare(LIVE, dict(LIVE, name="Edited"), LIVE, True)
    check(verdict == module.DRIFT and "name" in drifted,
          "compare: a new version does not excuse drift in the app-scoped fields")


# --- the tool, end to end against the mock ------------------------------------------------

def main() -> int:
    global KEY_PATH
    print("=== app-store-metadata ===\n")
    test_compare()

    # A real EC key so the JWT is genuinely signed. Testing against a stub signer would skip
    # the openssl DER-to-JWS conversion, which is the fiddliest code in asc.py.
    with tempfile.TemporaryDirectory() as directory:
        KEY_PATH = os.path.join(directory, "AuthKey_TESTKEY.p8")
        subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt",
                        "ec_paramgen_curve:P-256", "-out", KEY_PATH],
                       check=True, capture_output=True)

        server, base = start_server()
        Mock.values = dict(LIVE)
        Mock.state = "READY_FOR_DISTRIBUTION"

        print("\n-- check --")
        run(["check"], document(), base, 0, "clean listing passes",
            expect_in=["CLEAN"])

        Mock.values = dict(LIVE, subtitle="Edited in the web form")
        run(["check"], document(), base, 1, "a hand-edit in App Store Connect fails",
            expect_in=["DRIFT", "subtitle", "Edited in the web form"])

        Mock.values = dict(LIVE)
        pending_doc = document(desired=dict(LIVE, keywords="navidrome,subsonic,flac,lossless"))
        run(["check"], pending_doc, base, 0, "a change waiting on a release is not a failure",
            expect_in=["PENDING", "keywords"], expect_not_in=["DRIFT"])
        run(["check", "--strict-pending"], pending_doc, base, 1,
            "--strict-pending fails on an unpushed change")

        run(["check"], pending_doc, base, 0, "a locked version says so rather than offering a push",
            expect_in=["Nothing is editable while the version is READY_FOR_DISTRIBUTION"])
        Mock.state = "PREPARE_FOR_SUBMISSION"
        run(["check"], pending_doc, base, 0, "an editable version offers the push",
            expect_in=["A version is editable now"])

        print("\n-- unreachable --")
        dead = "http://127.0.0.1:1"
        run(["check"], document(), dead, 0, "an unreachable Apple skips by default",
            expect_in=["SKIP"])
        run(["check", "--strict"], document(), dead, 1,
            "--strict refuses to skip, which is what a release runs",
            expect_in=["FAIL"])

        print("\n-- push --")
        Mock.state = "READY_FOR_DISTRIBUTION"
        Mock.values, Mock.patches = dict(LIVE), []
        run(["push"], pending_doc, base, 0, "push on a locked version reports and writes nothing",
            expect_in=["Still pending"])
        check(Mock.patches == [], "push on a locked version sent no PATCH")
        run(["push", "--require-all"], pending_doc, base, 1,
            "--require-all makes an unwritable field a failure")

        Mock.state = "PREPARE_FOR_SUBMISSION"
        Mock.values, Mock.patches = dict(LIVE), []
        run(["push", "--dry-run"], pending_doc, base, 0, "--dry-run says what it would send",
            expect_in=["would PATCH", "nothing was sent"])
        check(Mock.patches == [], "--dry-run sent no PATCH")

        Mock.values, Mock.patches = dict(LIVE), []
        written = run(["push"], pending_doc, base, 0, "push applies the change",
                      expect_in=["patched appStoreVersionLocalizations", "keywords"])
        check(len(Mock.patches) == 1 and Mock.patches[0][0] == "appStoreVersionLocalizations/VLOC",
              "push patched only the version localization")
        check(set(Mock.patches[0][1]) == {"keywords"},
              "push sent ONLY the field that differed, not the whole listing")
        check(written["_live"]["values"]["keywords"] == "navidrome,subsonic,flac,lossless",
              "push re-read Apple and updated the snapshot")
        run(["check"], written, base, 0, "the listing is clean straight after a push",
            expect_in=["CLEAN"])

        # A change on each side at once has to reach both resources.
        Mock.values, Mock.patches = dict(LIVE), []
        both = document(desired=dict(LIVE, name="Baton", keywords="flac"))
        run(["push"], both, base, 0, "push writes both resources when both changed",
            expect_in=["patched appInfoLocalizations", "patched appStoreVersionLocalizations"])
        check(len(Mock.patches) == 2, "push made exactly two PATCHes")

        Mock.values, Mock.patches = dict(LIVE), []
        run(["push"], document(), base, 0, "push with nothing to do sends nothing",
            expect_in=["Nothing to push"])
        check(Mock.patches == [], "a no-op push sent no PATCH")

        print("\n-- push refuses to clobber --")
        Mock.values, Mock.patches = dict(LIVE, subtitle="Edited in the web form"), []
        run(["push"], document(desired=dict(LIVE, keywords="flac")), base, 1,
            "push refuses over drift rather than overwriting someone's edit",
            expect_in=["Refusing to push over drift"])
        check(Mock.patches == [], "the refused push sent no PATCH")
        run(["push", "--force"], document(desired=dict(LIVE, keywords="flac")), base, 0,
            "--force pushes anyway", expect_in=["patched"])

        print("\n-- a newly created App Store version --")
        # TBX-3928, 2026-09-07: creating the 1.1 version record put Apple on a version the
        # snapshot had never seen, with an empty promotional text because Apple does not
        # carry that field forward. `check` called it DRIFT and `push` refused, which in a
        # release means `testflight.sh` aborts on a false accusation. These four run the
        # whole path the way the release runs it: push, then check --strict.
        Mock.version = "1.1"
        Mock.state = "PREPARE_FOR_SUBMISSION"
        Mock.values = {f: v for f, v in LIVE.items() if f != "promotionalText"}
        Mock.patches = []
        fresh_doc = document(desired=dict(LIVE, name="Baton: Navidrome Music Player"))
        run(["check"], fresh_doc, base, 0,
            "a new version's empty promotional text is pending, not drift",
            expect_in=["version 1.1", "PENDING", "promotionalText"], expect_not_in=["DRIFT"])

        written = run(["push"], fresh_doc, base, 0,
                      "push writes to the new version instead of refusing over drift",
                      expect_in=["patched appInfoLocalizations",
                                 "patched appStoreVersionLocalizations"],
                      expect_not_in=["Refusing to push over drift"])
        check(written["_live"]["appStoreVersion"] == "1.1",
              "the snapshot now describes the version that was actually written")
        run(["check", "--strict"], written, base, 0,
            "the release's own check --strict passes straight after the push",
            expect_in=["CLEAN"])

        # The boundary is one release wide. Once the snapshot names 1.1, a hand-edit on 1.1
        # is drift again — otherwise the fix would have retired the check rather than scoped it.
        Mock.values["description"] = "Edited in the web form"
        run(["check"], written, base, 1,
            "a hand-edit on the new version, once snapshotted, is drift again",
            expect_in=["DRIFT", "description"])

        Mock.version = "1.0"

        print("\n-- pull --")
        Mock.values = dict(LIVE, subtitle="Edited in the web form")
        written = run(["pull"], document(), base, 0, "pull adopts a deliberate live edit",
                      expect_in=["Pulled"])
        check(written["desired"]["subtitle"] == "Edited in the web form"
              and written["_live"]["values"]["subtitle"] == "Edited in the web form",
              "pull updates both halves of the file")

        Mock.values = dict(LIVE)
        run(["pull"], document(desired=dict(LIVE, keywords="flac")), base, 1,
            "pull refuses to silently discard an unpushed change",
            expect_in=["Refusing to pull"])
        written = run(["pull", "--force"], document(desired=dict(LIVE, keywords="flac")), base,
                      0, "--force discards it on purpose")
        check(written["desired"]["keywords"] == LIVE["keywords"], "--force really discarded it")

        server.shutdown()

    print(f"\n{PASSED} passed, {FAILED} failed")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
