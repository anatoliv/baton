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
    # The iPhone carries the association in every build. The Mac carries it only in Release
    # (Developer ID, signed by scripts/publish.sh with the "Baton Mac Developer ID" profile):
    # no Mac App Development profile has Associated Domains, so Debug, test and probe builds
    # keep the core-only Baton.entitlements, or AMFI refuses to launch them (TBX-8693).
    def domains(path):
        with (ROOT / path).open("rb") as file:
            return plistlib.load(file).get("com.apple.developer.associated-domains")

    phone = (ROOT / "ios/project.yml").read_text()
    assert domains("ios/BatonMobile.entitlements") == DOMAINS, f"ios: associated domains must be {DOMAINS}"
    assert "com.apple.developer.associated-domains: [" + ", ".join(DOMAINS) + "]" in phone, \
        "ios/project.yml must declare the same associated domains"
    mac = (ROOT / "app/project.yml").read_text()
    assert domains("app/Baton.Release.entitlements") == DOMAINS, f"app: Release associated domains must be {DOMAINS}"
    assert domains("app/Baton.entitlements") is None, "app: Debug/test entitlements must stay without associated domains"
    assert re.search(r"\n        CODE_SIGN_ENTITLEMENTS: Baton\.entitlements\n", mac), \
        "app/project.yml must give the Baton target the core-only entitlements by default"
    assert re.search(r"\n        Release:\n          CODE_SIGN_ENTITLEMENTS: Baton\.Release\.entitlements\n", mac), \
        "app/project.yml must give Release builds the associated-domain entitlements"
    assert "\n    entitlements:\n      path: Baton.entitlements" not in mac, \
        "XcodeGen's entitlements: key would override the Release entitlements"
    for source in (phone, mac):
        assert "../Shared/SharedWithYouModel.swift" in source and "../Shared/SharedWithYouView.swift" in source
    nginx = (ROOT / "deploy/nginx/default.conf").read_text()
    location = re.search(r"location = /\.well-known/apple-app-site-association\s*\{([^}]+)\}", nginx)
    assert location and "default_type application/json;" in location[1] and "try_files $uri =404;" in location[1]
    assert "add_header" not in location[1], "association route must inherit security and cache headers"
    assert re.search(r'"/\.well-known/apple-app-site-association"\s+"no-cache";', nginx)
    publish = (ROOT / "scripts/publish-site.sh").read_text()
    assert 'website/.well-known/ "$WEB01:$REMOTE_DIR/site/.well-known/"' in publish, "rsync must preserve the hidden directory"
    assert '"/.well-known/apple-app-site-association|no-cache|200"' in publish
    print("Association source checks passed (AASA, iPhone entitlement and project, Mac Release entitlement and Debug exclusion, nginx MIME/cache, publication path).")
    print("Installed association and signed-profile acceptance remain separate device gates.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mac-app-id", help="exact profile-qualified Mac App ID; never inferred from Team ID")
    args = parser.parse_args()
    check(args.mac_app_id)
