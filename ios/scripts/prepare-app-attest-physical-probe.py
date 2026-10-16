#!/usr/bin/env python3
"""Generate a private opt-in XcodeGen spec from an already qualified Debug spec.

No device, signing-provider, keychain, network or project generation action occurs.
The resulting source paths are relative to ios; use xcodegen --project-root there.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import stat


def prepare(template, destination, suite):
    if not re.fullmatch(r"probe-attest-[A-Za-z0-9._-]{1,40}", suite):
        raise ValueError("A unique probe-attest suite is required")
    info = template.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("Template must be an owned regular owner-only file")
    spec = json.loads(template.read_text())
    targets = spec["targets"]
    for name, identifier in [("BatonMobile", "io.tonebox.baton"), ("BatonWidgets", "io.tonebox.baton.widgets")]:
        settings = targets[name]["settings"]
        if settings["base"]["PRODUCT_BUNDLE_IDENTIFIER"] != identifier:
            raise ValueError("Unexpected signing target")
        debug = settings["configs"]["Debug"]
        if debug.get("CODE_SIGN_STYLE") != "Manual" or not debug.get("PROVISIONING_PROFILE_SPECIFIER"):
            raise ValueError("Qualified per-target Debug profile selection is required")
    host = "BatonAppAttestPhysicalHost"
    name = "BatonAppAttestPhysicalTests"
    if host in targets or name in targets or "BatonAppAttestPhysical" in spec["schemes"]:
        raise ValueError("Probe host, target or scheme already exists")
    # Same approved App ID/profile, but no normal app source/model/package/framework
    # initialization. Keep the existing widget extension embedded without changing it.
    # BatonShare (io.tonebox.baton.share) is embedded by BatonMobile only; the probe host
    # does not embed it, so it needs no Debug profile here (TBX-10944).
    debug = copy.deepcopy(targets["BatonMobile"]["settings"]["configs"]["Debug"])
    targets[host] = {
        "type": "application", "platform": "iOS",
        "sources": [{"path": "Tests/BatonAppAttestPhysicalHost"}],
        "dependencies": [{"target": "BatonWidgets"}],
        "settings": {"base": {
            "PRODUCT_BUNDLE_IDENTIFIER": "io.tonebox.baton",
            "PRODUCT_NAME": "BatonPhysicalProbe",
            "PRODUCT_MODULE_NAME": host,
            "GENERATE_INFOPLIST_FILE": True,
            "INFOPLIST_KEY_UILaunchScreen_Generation": True,
        }, "configs": {"Debug": debug}},
        "info": {"path": str(destination / "PhysicalProbeInfo.plist"), "properties": {
            "CFBundleDisplayName": "Baton Attest Probe",
            "CFBundleShortVersionString": "$(MARKETING_VERSION)",
            "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
            "BatonSourceCommit": "$(BATON_SOURCE_COMMIT)",
            "BatonPhysicalAttestProbe": True,
        }},
    }
    target = copy.deepcopy(targets["BatonMobileTests"])
    target["sources"] = [{"path": "Tests/BatonAppAttestPhysicalTests"}]
    target["dependencies"] = [{"target": host}]
    target["settings"] = {"base": {
        "GENERATE_INFOPLIST_FILE": True,
        "BUNDLE_LOADER": "$(TEST_HOST)",
        "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/BatonPhysicalProbe.app/BatonPhysicalProbe",
        "PRODUCT_BUNDLE_IDENTIFIER": "io.tonebox.baton.physical-tests",
    }}
    targets[name] = target
    spec["schemes"]["BatonAppAttestPhysical"] = {
        "build": {"targets": {host: "all", name: ["test"]}},
        "test": {"config": "Debug", "targets": [name], "environmentVariables": {
            "BATON_APP_ATTEST_PHYSICAL_ACCEPTANCE": "1", "baton.defaultsSuite": suite,
        }},
    }
    # Every signed product the probe scheme builds must be one checked above. Refuse a
    # spec whose build reaches another target, such as BatonShare without a profile.
    closure, pending = set(), [host, name]
    while pending:
        current = pending.pop()
        if current not in closure:
            closure.add(current)
            pending += [item["target"] for item in targets[current].get("dependencies", [])
                        if "target" in item]
    if closure != {host, name, "BatonWidgets"}:
        raise ValueError("Probe build must embed only the qualified widget extension")
    destination.mkdir(mode=0o700)  # Refuse reuse rather than overwrite another run.
    result = destination / "physical-probe-spec.json"
    data = json.dumps(spec, sort_keys=True, indent=2).encode()
    fd = os.open(result, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
    return {"spec": str(result), "sha256": hashlib.sha256(data).hexdigest(),
            "scheme": "BatonAppAttestPhysical", "testCount": 1,
            "installed": False, "launched": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--suite", required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(prepare(args.template, args.destination, args.suite), indent=2))
    except (ValueError, KeyError, OSError, json.JSONDecodeError):
        raise SystemExit("Probe preparation refused; private input details withheld")
