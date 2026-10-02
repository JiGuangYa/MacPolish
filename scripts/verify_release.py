#!/usr/bin/env python3
"""Inspect the app actually shipped in every MacPolish release container."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
APP_NAME = "MacPolish"
BUNDLE_ID = "com.jiguang.MacPolish"
ARCHITECTURES = {"arm64", "x86_64"}
MINIMUM_MACOS = "13.0"
ARCHIVES = ("MacPolish.pkg", "MacPolish.dmg", "MacPolish.zip")
OUTPUTS = ("MacPolish.app", *ARCHIVES, "release-manifest.json", "SHA256SUMS")


def run(command, *, binary=False):
    result = subprocess.run([str(arg) for arg in command], capture_output=True, timeout=120)
    if result.returncode:
        detail = result.stderr.decode(errors="replace").strip()
        raise RuntimeError(f"{command[0]} failed: {detail}")
    return result.stdout if binary else result.stdout.decode()


def check(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def bundle_tree(bundle):
    entries = {}
    for path in sorted(bundle.rglob("*")):
        relative = str(path.relative_to(bundle))
        if path.is_symlink():
            entries[relative] = ["link", os.readlink(path)]
        elif path.is_file():
            entries[relative] = ["file", sha256(path), stat.S_IMODE(path.stat().st_mode)]
    return entries


def tree_sha256(bundle):
    return hashlib.sha256(json.dumps(bundle_tree(bundle), sort_keys=True).encode()).hexdigest()


def load_strings(path):
    return json.loads(run(["/usr/bin/plutil", "-convert", "json", "-o", "-", path]))


def supported_localizations():
    return (ROOT / "Localization/supported_localizations.txt").read_text().splitlines()


def verify_bundle(bundle, version, build):
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    expected = {
        "CFBundleIdentifier": BUNDLE_ID, "CFBundleExecutable": APP_NAME,
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version,
        "CFBundleVersion": build, "LSMinimumSystemVersion": MINIMUM_MACOS,
        "CFBundleLocalizations": supported_localizations(),
    }
    for key, value in expected.items():
        check(info.get(key) == value, f"Unexpected {key} in {bundle}")
    executable = bundle / "Contents/MacOS" / APP_NAME
    check(os.access(executable, os.X_OK), "Packaged app executable is missing or not executable")
    check(set(run(["/usr/bin/lipo", "-archs", executable]).split()) == ARCHITECTURES,
          "Packaged app must contain both arm64 and x86_64")
    build_info = run(["/usr/bin/xcrun", "vtool", "-show-build", executable])
    check(re.findall(r"\bminos\s+(\S+)", build_info) == [MINIMUM_MACOS] * 2,
          "Both executable slices must target macOS 13.0")
    check(len(re.findall(r"platform\s+MACOS\b", build_info)) == 2, "Expected two macOS slices")
    for architecture in sorted(ARCHITECTURES):
        dependencies = run(["/usr/bin/otool", "-arch", architecture, "-L", executable])
        for line in dependencies.splitlines():
            if " (compatibility version " not in line:
                continue
            dependency = line.strip().split(" (compatibility version ", 1)[0]
            check(dependency.startswith(("/System/Library/", "/usr/lib/")),
                  f"Non-system dependency in {architecture}: {dependency}")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", bundle])
    signature = subprocess.run(["/usr/bin/codesign", "-dv", str(bundle)], capture_output=True, text=True, check=True)
    check("Signature=adhoc" in signature.stderr, "Expected the documented local ad-hoc signature")
    check((bundle / "Contents/Resources/AppIcon.icns").is_file(), "Packaged app icon is missing")

    resource_bundle = bundle / "Contents/Resources/MacPolish_MacPolishKit.bundle"
    resource_files = list(resource_bundle.rglob("Localizable.strings"))
    by_locale = {path.parent.stem.lower(): path for path in resource_files}
    languages = supported_localizations()
    check(len(resource_files) == len(languages) and set(by_locale) == {item.lower() for item in languages},
          "Packaged SwiftPM resources do not contain exactly the supported languages")
    for language in languages:
        source = ROOT / "Sources/MacPolishKit/Resources" / f"{language}.lproj/Localizable.strings"
        expected_strings = load_strings(source)
        check(load_strings(by_locale[language.lower()]) == expected_strings,
              f"Packaged {language} resources differ from the source")
        root_resource = bundle / "Contents/Resources" / f"{language}.lproj/Localizable.strings"
        check(load_strings(root_resource) == expected_strings, f"App-level {language} resources differ from the source")
    return bundle_tree(bundle)


def verify_checksums(directory, manifest):
    check(set(manifest["archives"]) == set(ARCHIVES), "Release manifest has an unexpected archive list")
    expected_lines = []
    for name in ARCHIVES:
        path = directory / name
        metadata = manifest["archives"][name]
        check(path.is_file() and path.stat().st_size == metadata["bytes"], f"Missing or truncated archive: {name}")
        digest = sha256(path)
        check(digest == metadata["sha256"], f"Checksum mismatch: {name}")
        expected_lines.append(f"{digest}  {name}")
    expected_lines.append(f"{sha256(directory / 'release-manifest.json')}  release-manifest.json")
    check((directory / "SHA256SUMS").read_text().splitlines() == expected_lines,
          "SHA256SUMS does not match this release")


def verify_release(directory):
    directory = Path(directory).resolve()
    manifest = json.loads((directory / "release-manifest.json").read_text())
    check(manifest["schema_version"] == 1, "Unsupported release manifest version")
    check(set(manifest["architectures"]) == ARCHITECTURES, "Manifest must describe both architectures")
    check(manifest["minimum_macos"] == MINIMUM_MACOS, "Manifest has an incorrect minimum macOS version")
    check(manifest["localizations"] == supported_localizations(), "Manifest has an incorrect language list")
    check(manifest["signing"] == {"type": "ad-hoc", "notarized": False}, "Unexpected signing claim")
    verify_checksums(directory, manifest)
    app = directory / "MacPolish.app"
    reference = verify_bundle(app, manifest["version"], manifest["build"])
    check(tree_sha256(app) == manifest["app_tree_sha256"], "App bundle does not match the release manifest")
    with tempfile.TemporaryDirectory(prefix="MacPolish-release-check-") as temporary:
        scratch = Path(temporary)
        zip_root = scratch / "zip"
        run(["/usr/bin/ditto", "-x", "-k", directory / "MacPolish.zip", zip_root])
        check(bundle_tree(zip_root / "MacPolish.app") == reference, "ZIP does not contain the verified app bundle")

        pkg_root = scratch / "pkg"
        run(["/usr/sbin/pkgutil", "--expand-full", directory / "MacPolish.pkg", pkg_root])
        info = ET.fromstring((pkg_root / "PackageInfo").read_text())
        for key, value in {"identifier": BUNDLE_ID, "version": manifest["version"],
                           "install-location": "/Applications", "relocatable": "false"}.items():
            check(info.get(key) == value, f"Unexpected installer {key}")
        check(not any((pkg_root / "Scripts").rglob("*")), "Installer must not contain install scripts")
        check(bundle_tree(pkg_root / "Payload/MacPolish.app") == reference, "PKG does not contain the verified app bundle")

        run(["/usr/bin/hdiutil", "verify", directory / "MacPolish.dmg"])
        mountpoint = scratch / "mounted"
        mountpoint.mkdir()
        attached = plistlib.loads(run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
                                      "-mountpoint", mountpoint, "-plist", directory / "MacPolish.dmg"], binary=True))
        device = next(item["dev-entry"] for item in attached["system-entities"] if "dev-entry" in item)
        try:
            check(bundle_tree(mountpoint / "MacPolish.app") == reference, "DMG does not contain the verified app bundle")
            applications = mountpoint / "Applications"
            check(applications.is_symlink() and os.readlink(applications) == "/Applications", "DMG installation shortcut is missing or incorrect")
        finally:
            run(["/usr/bin/hdiutil", "detach", device])
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", nargs="?", type=Path, default=ROOT / "dist")
    arguments = parser.parse_args()
    try:
        manifest = verify_release(arguments.directory)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Release verification failed: {error}\n")
    print(f"Verified MacPolish {manifest['version']} ({manifest['build']}): universal app, 10 languages, signature, PKG, DMG, ZIP, and checksums.")


if __name__ == "__main__":
    main()
