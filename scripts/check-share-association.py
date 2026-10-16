#!/usr/bin/env python3
"""Validate the source association contract without claiming installed-device activation."""
import json
import pathlib
import plistlib
import re
import argparse
from mac_association_signing import DOMAINS, PHONE_APP_ID, check_aasa

ROOT = pathlib.Path(__file__).resolve().parent.parent

def check(mac_app_id=None):
    aasa = json.loads((ROOT / "website/.well-known/apple-app-site-association").read_text())
    check_aasa(aasa, mac_app_id)
    # The iPhone must carry the association. The Mac may leave it out until its App
    # Development and Developer ID profiles have Associated Domains (TBX-8693); its links
    # open in the browser meanwhile. When the Mac does carry it, it must be exactly right.
    for directory, name, required in [("app", "Baton.entitlements", False),
                                      ("ios", "BatonMobile.entitlements", True)]:
        with (ROOT / directory / name).open("rb") as file:
            domains = plistlib.load(file).get("com.apple.developer.associated-domains")
        source = (ROOT / directory / "project.yml").read_text()
        declared = "com.apple.developer.associated-domains: [" + ", ".join(DOMAINS) + "]" in source
        if required or domains is not None or declared:
            assert domains == DOMAINS, f"{directory}: associated domains must be {DOMAINS}"
            assert declared, f"{directory}/project.yml must declare the same associated domains"
        assert "../Shared/SharedWithYouModel.swift" in source and "../Shared/SharedWithYouView.swift" in source
    nginx = (ROOT / "deploy/nginx/default.conf").read_text()
    location = re.search(r"location = /\.well-known/apple-app-site-association\s*\{([^}]+)\}", nginx)
    assert location and "default_type application/json;" in location[1] and "try_files $uri =404;" in location[1]
    assert "add_header" not in location[1], "association route must inherit security and cache headers"
    assert re.search(r'"/\.well-known/apple-app-site-association"\s+"no-cache";', nginx)
    publish = (ROOT / "scripts/publish-site.sh").read_text()
    assert 'website/.well-known/ "$WEB01:$REMOTE_DIR/site/.well-known/"' in publish, "rsync must preserve the hidden directory"
    assert '"/.well-known/apple-app-site-association|no-cache|200"' in publish
    print("Association source checks passed (AASA, iPhone entitlement and project, Mac when declared, nginx MIME/cache, publication path).")
    print("Installed association and signed-profile acceptance remain separate device gates.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mac-app-id", help="exact profile-qualified Mac App ID; never inferred from Team ID")
    args = parser.parse_args()
    check(args.mac_app_id)
