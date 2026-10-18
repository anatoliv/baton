#!/usr/bin/env python3
"""Exercise TestFlight attachment pagination without Apple or credentials."""
import copy
import importlib.util
import io
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
spec = importlib.util.spec_from_file_location("attach_build", HERE / "attach-build.py")
attach = importlib.util.module_from_spec(spec)
spec.loader.exec_module(attach)

BUILD = {"id": "BUILD", "attributes": {"version": "wanted", "processingState": "VALID"}}
GROUP = {"id": "GROUP", "attributes": {"isInternalGroup": True}}


def page(items, following=None):
    return {"data": items, "links": {"next": following}}


def link(path):
    return "https://api.appstoreconnect.apple.com/v1/" + path


class FakeClient:
    def __init__(self, responses):
        self.responses = responses
        self.gets = []
        self.posts = []

    def get(self, path):
        self.gets.append(path)
        return copy.deepcopy(self.responses[path])

    def post(self, path, body):
        self.posts.append((path, body))
        return {}


class AttachBuildTests(unittest.TestCase):
    def run_main(self, client):
        with patch.object(attach, "credentials", return_value=("unused", "unused", "unused")), \
                patch.object(attach, "Client", return_value=client), \
                patch.object(attach, "find_app", return_value="APP"), \
                patch.object(sys, "argv", ["attach-build.py", "--build", "wanted"]), \
                patch("sys.stdout", new_callable=io.StringIO):
            attach.main()

    def client(self, membership):
        return FakeClient({"apps/APP/builds": page([BUILD]),
                           "apps/APP/betaGroups": page([GROUP]),
                           "betaGroups/GROUP/builds": membership})

    def test_finds_build_on_second_page(self):
        client = FakeClient({"apps/APP/builds": page([], link("apps/APP/builds?cursor=two")),
                             "apps/APP/builds?cursor=two": page([BUILD])})
        self.assertEqual(attach.find_build(client, "APP", "wanted"), BUILD)

    def test_internal_group_may_be_on_second_page(self):
        client = FakeClient({"apps/APP/betaGroups": page([], link("apps/APP/betaGroups?cursor=two")),
                             "apps/APP/betaGroups?cursor=two": page([GROUP])})
        self.assertEqual(attach.internal_group(client, "APP"), "GROUP")

    def test_existing_second_page_membership_does_not_post_again(self):
        client = self.client(page([], link("betaGroups/GROUP/builds?cursor=two")))
        client.responses["betaGroups/GROUP/builds?cursor=two"] = page([BUILD])
        self.run_main(client)
        self.assertEqual(client.posts, [])

    def test_new_membership_is_posted_once(self):
        client = self.client(page([]))
        self.run_main(client)
        self.assertEqual(client.posts, [("betaGroups/GROUP/relationships/builds",
                                       {"data": [{"type": "builds", "id": "BUILD"}]})])

    def test_first_page_build_still_works(self):
        self.assertEqual(attach.find_build(self.client(page([])), "APP", "wanted"), BUILD)

    def test_untrusted_next_url_stops_before_post(self):
        for following in ["https://example.invalid/v1/builds", "http://api.appstoreconnect.apple.com/v1/builds",
                          "https://api.appstoreconnect.apple.com.evil.invalid/v1/builds",
                          "https://user@api.appstoreconnect.apple.com/v1/builds",
                          "https://api.appstoreconnect.apple.com/v2/builds",
                          "https://api.appstoreconnect.apple.com/v1/builds#fragment"]:
            with self.subTest(following=following):
                client = self.client(page([], following))
                with self.assertRaises(attach.ASCError):
                    self.run_main(client)
                self.assertEqual(client.posts, [])

    def test_page_bound_stops_before_post(self):
        path = "betaGroups/GROUP/builds"
        client = self.client(page([], link(path)))
        with self.assertRaises(attach.ASCError):
            self.run_main(client)
        self.assertLessEqual(client.gets.count(path), 20)
        self.assertEqual(client.posts, [])

    def test_missing_build_remains_pending(self):
        client = FakeClient({"apps/APP/builds": page([], link("apps/APP/builds?cursor=two")),
                             "apps/APP/builds?cursor=two": page([])})
        self.assertIsNone(attach.find_build(client, "APP", "wanted"))
        self.assertEqual(len(client.gets), 2)


if __name__ == "__main__":
    unittest.main()
