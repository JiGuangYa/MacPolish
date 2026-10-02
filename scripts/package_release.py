#!/usr/bin/env python3
"""Build and verify a universal local release before replacing existing output."""
from datetime import datetime, timezone
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

from verify_release import (APP_NAME, ARCHITECTURES, ARCHIVES, BUNDLE_ID, MINIMUM_MACOS, OUTPUTS,
                            ROOT, sha256, supported_localizations, tree_sha256, verify_release)


def checked(command, *, quiet=False):
    subprocess.run([str(arg) for arg in command], cwd=ROOT, check=True,
                   stdout=subprocess.DEVNULL if quiet else None)


def output(command):
    return subprocess.check_output([str(arg) for arg in command], cwd=ROOT, text=True).strip()


def validate_versions(version, build):
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version):
        raise ValueError("APP_VERSION must have three numeric components, such as 1.2.0")
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("APP_BUILD must be a positive integer")


def remove(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)


def publish_outputs(staging, destination, *, replace=os.replace):
    """Rollback a partial publication; never delete the last release before building."""
    if destination.is_symlink():
        raise ValueError("Release output directory must not be a symlink")
    destination.mkdir(parents=True, exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix="MacPolish-previous-release-", dir=staging.parent))
    moved_old, moved_new = [], []
    try:
        for name in OUTPUTS:
            target = destination / name
            if target.exists() or target.is_symlink():
                replace(target, backup / name)
                moved_old.append(name)
            replace(staging / name, target)
            moved_new.append(name)
    except BaseException:
        try:
            for name in reversed(moved_new):
                remove(destination / name)
            for name in reversed(moved_old):
                os.replace(backup / name, destination / name)
        except BaseException as recovery_error:
            # This directory is outside the temporary staging directory and
            # must survive even when recovery fails.
            raise RuntimeError(f"Publication rollback failed; previous files remain at {backup}: {recovery_error}")
        shutil.rmtree(backup)
        raise
    else:
        shutil.rmtree(backup)


def assemble(staging, binary_directory, version, build):
    app = staging / "MacPolish.app"
    resources = app / "Contents/Resources"
    executable_directory = app / "Contents/MacOS"
    resources.mkdir(parents=True)
    executable_directory.mkdir()
    shutil.copy2(binary_directory / APP_NAME, executable_directory / APP_NAME)
    resource_bundle = binary_directory / "MacPolish_MacPolishKit.bundle"
    shutil.copytree(resource_bundle, resources / resource_bundle.name)
    for localization in supported_localizations():
        source = ROOT / "Sources/MacPolishKit/Resources" / f"{localization}.lproj"
        shutil.copytree(source, resources / source.name)

    icon_master = staging / "AppIcon-1024.png"
    iconset = staging / "AppIcon.iconset"
    iconset.mkdir()
    checked(["swift", ROOT / "scripts/generate_app_icon.swift", icon_master])
    for size in (16, 32, 128, 256, 512):
        for scale, suffix in ((1, ""), (2, "@2x")):
            checked(["sips", "-z", size * scale, size * scale, icon_master, "--out",
                     iconset / f"icon_{size}x{size}{suffix}.png"], quiet=True)
    checked(["iconutil", "-c", "icns", iconset, "-o", resources / "AppIcon.icns"])
    info = {
        "CFBundleDevelopmentRegion": "en", "CFBundleDisplayName": APP_NAME,
        "CFBundleExecutable": APP_NAME, "CFBundleIconFile": "AppIcon", "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": APP_NAME,
        "CFBundleLocalizations": supported_localizations(), "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version, "CFBundleVersion": build,
        "LSApplicationCategoryType": "public.app-category.utilities", "LSMinimumSystemVersion": MINIMUM_MACOS,
        "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication",
    }
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info, sort_keys=False))
    checked(["codesign", "--force", "--deep", "--sign", "-", app])
    checked(["ditto", "-c", "-k", "--keepParent", app, staging / "MacPolish.zip"])
    checked(["pkgbuild", "--component", app, "--install-location", "/Applications", "--identifier", BUNDLE_ID,
             "--version", version, staging / "MacPolish.pkg"])
    dmg_root = staging / "dmg-root"
    dmg_root.mkdir()
    shutil.copytree(app, dmg_root / app.name, symlinks=True)
    (dmg_root / "Applications").symlink_to("/Applications")
    checked(["hdiutil", "create", "-volname", APP_NAME, "-srcfolder", dmg_root,
             "-ov", "-format", "UDZO", staging / "MacPolish.dmg"], quiet=True)
    manifest = {
        "schema_version": 1, "version": version, "build": build,
        "built_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "source_revision": output(["git", "rev-parse", "HEAD"]),
        "source_has_uncommitted_changes": bool(output(["git", "status", "--porcelain"])),
        "architectures": sorted(ARCHITECTURES), "minimum_macos": MINIMUM_MACOS,
        "localizations": supported_localizations(), "signing": {"type": "ad-hoc", "notarized": False},
        "app_tree_sha256": tree_sha256(app),
        "archives": {name: {"sha256": sha256(staging / name), "bytes": (staging / name).stat().st_size} for name in ARCHIVES},
    }
    manifest_path = staging / "release-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    checksum_names = (*ARCHIVES, manifest_path.name)
    (staging / "SHA256SUMS").write_text("".join(f"{sha256(staging / name)}  {name}\n" for name in checksum_names))
    verify_release(staging)


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog="Set APP_VERSION=1.2.0 and APP_BUILD=3 to override the default version and build number.")
    parser.parse_args()
    version, build = os.environ.get("APP_VERSION", "1.1.0"), os.environ.get("APP_BUILD", "2")
    try:
        validate_versions(version, build)
        build_arguments = ["swift", "build", "--package-path", ROOT, "--scratch-path", ROOT / ".build/universal",
                           "-c", "release", "--arch", "arm64", "--arch", "x86_64"]
        checked([*build_arguments, "--product", APP_NAME])
        binary_directory = Path(output([*build_arguments, "--show-bin-path"]))
        with tempfile.TemporaryDirectory(prefix="MacPolish-release-", dir=ROOT / ".build") as temporary:
            staging = Path(temporary)
            assemble(staging, binary_directory, version, build)
            publish_outputs(staging, ROOT / "dist")
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Release packaging failed: {error}", file=sys.stderr)
        return 1
    print(f"Verified universal MacPolish {version} ({build}); local ad-hoc signature, not notarized.")
    for name in OUTPUTS:
        print(f"  {ROOT / 'dist' / name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
