#!/usr/bin/env python3
"""Prepare an offline physical-proof verifier; no provider or device operation."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import time


def private_directory(path):
    info = path.lstat()
    if (path.resolve() != path or not stat.S_ISDIR(info.st_mode) or
            info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700):
        raise ValueError('Compiler output directory qualification refused')


def prepare_output(output):
    if not output.is_absolute() or output.resolve() != output:
        raise ValueError('Compiler destination must be canonical and absolute')
    private_directory(output.parent)
    if os.path.lexists(output):
        raise ValueError('Compiler destination already exists')
    output.mkdir(mode=0o700)
    private_directory(output)
    cache = output / 'module-cache'
    if os.path.lexists(cache):
        raise ValueError('Compiler module cache already exists')
    cache.mkdir(mode=0o700)
    private_directory(cache)
    return cache


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dependency-checkout", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    output = args.destination
    # Use an attempt-local module cache; retain any refused partial output.
    cache = prepare_output(output)
    repo = Path(__file__).resolve().parents[2]
    products = args.dependency_checkout / "gateway/.build/out/Products/Debug"
    helper = repo / "ios/scripts/app-attest-offline-proof.swift"
    assert json.loads((repo / "gateway/Package.resolved").read_text())["pins"] == json.loads(
        (args.dependency_checkout / "gateway/Package.resolved").read_text())["pins"]
    sharing = list((repo / "Packages/BatonShareKit/Sources/BatonShareKit").glob("*.swift"))
    verifiers = [repo / "gateway/Sources/BatonShareServer" / name for name in
                 ["AppAttestVerifier.swift", "AppAttestReceipt.swift", "AppAttestCBOR.swift"]]
    accessor = args.dependency_checkout / (
        "gateway/.build/out/Intermediates.noindex/baton-gateway.build/Debug/"
        "BatonShareServer-t.build/DerivedSources/resource_bundle_accessor.swift")
    # Public package resources only, never app/provider configuration or credentials.
    resource = products / "baton-gateway_BatonShareServer.bundle"
    for name in ["Apple_App_Attestation_Root_CA.pem", "AppleRootCA-G3.cer"]:
        actual = resource / "Contents/Resources/AttestationRoots" / name
        expected = repo / "gateway/Sources/BatonShareServer/AttestationRoots" / name
        assert hashlib.sha256(actual.read_bytes()).digest() == hashlib.sha256(expected.read_bytes()).digest()
    shutil.copytree(resource, output / resource.name)
    objects = [products / (name + ".o") for name in [
        "Crypto", "X509", "SwiftASN1", "_CryptoExtras", "_CertificateInternals",
        "CCryptoBoringSSL", "CCryptoBoringSSLShims", "CryptoBoringWrapper"]]
    commands = [
        ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-module-cache-path", str(cache), "-emit-library",
         "-emit-module", "-module-name", "BatonShareKit", *map(str, sharing),
         "-emit-module-path", str(output / "BatonShareKit.swiftmodule"),
         "-o", str(output / "libBatonShareKit.dylib")],
        ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-module-cache-path", str(cache),
         "-I", str(output), "-I", str(products), "-L", str(output), "-lBatonShareKit",
         "-Xlinker", "-rpath", "-Xlinker", str(output), *map(str, verifiers),
         str(accessor), str(helper), *map(str, objects), "-o", str(output / "verify-proof")],
    ]
    started = time.monotonic()
    results = []
    for index, command in enumerate(commands):
        with (output / ("compile-" + str(index) + ".log")).open("xb") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=120)
        results.append({"stage": index, "exit": result.returncode})
        if result.returncode:
            break
    receipt = {
        "observedAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "stages": results, "seconds": round(time.monotonic() - started, 3),
        "sourceSHA256": {str(path.relative_to(repo)): hashlib.sha256(path.read_bytes()).hexdigest()
                         for path in [*verifiers, *sharing]},
        "helperSHA256": hashlib.sha256(helper.read_bytes()).hexdigest(),
        "dependencyPinsMatch": True, "deviceActions": 0,
    }
    binary = output / "verify-proof"
    if binary.exists():
        receipt["binarySHA256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
    if len(results) == 2 and all(row["exit"] == 0 for row in results):
        runtime = ["verify-proof", "libBatonShareKit.dylib", *[
            resource.name + "/Contents/Resources/AttestationRoots/" + name
            for name in ["Apple_App_Attestation_Root_CA.pem", "AppleRootCA-G3.cer"]]]
        receipt["runtimeSHA256"] = {name: hashlib.sha256((output / name).read_bytes()).hexdigest()
                                    for name in runtime}
    (output / "compile-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt))
    raise SystemExit(0 if len(results) == 2 and all(row["exit"] == 0 for row in results) else 1)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"result": "FAIL", "errorClass": type(error).__name__,
                          "privateDetailsWithheld": True}))
        raise SystemExit(1)
