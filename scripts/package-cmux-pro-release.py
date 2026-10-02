#!/usr/bin/env python3
"""Package an already verified arm64 Release build for the cmux-pro fork."""

import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path


def run(*args):
    subprocess.run(args, check=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--native-source-commit", required=True)
    args = parser.parse_args()
    source = args.app.resolve()
    native = source / "Contents/MacOS/cmux"
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(source))
    architectures = subprocess.check_output(
        ["/usr/bin/lipo", "-archs", str(native)], text=True
    ).strip()
    if architectures != "arm64":
        parser.error("this packaging recipe requires the verified arm64 build")
    source_info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
    if source_info["CFBundleIdentifier"] != "com.cmuxterm.app.staging.zmx":
        parser.error("expected the isolated native zmx Release build")
    args.out.mkdir(parents=True, exist_ok=True)
    dmg = args.out / "cmux-macos.dmg"
    if dmg.exists():
        parser.error("refusing to overwrite an existing release asset")
    with tempfile.TemporaryDirectory(prefix="cmux-pro-package-") as temporary:
        root = Path(temporary)
        volume = root / "volume"
        volume.mkdir()
        app = volume / "cmux.app"
        run("/usr/bin/ditto", str(source), str(app))
        info_path = app / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleName"] = info["CFBundleDisplayName"] = "cmux"
        # Retain the validated namespace so the installed VM layout restores.
        # This identity also keeps upstream Sparkle releases from replacing the fork.
        info["LSEnvironment"] = {
            "CMUX_BUNDLE_ID": info["CFBundleIdentifier"],
            "CMUX_SOCKET_PATH": "/tmp/cmux-staging-zmx.sock",
        }
        info["SUEnableAutomaticChecks"] = False
        info.pop("SUFeedURL", None)
        info.pop("SUPublicEDKey", None)
        info["CMUXForkRepository"] = "https://github.com/Kushalkhemka/cmux-pro"
        info["CMUXForkRelease"] = args.tag
        info["CMUXNativeSourceCommit"] = args.native_source_commit
        info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        run("/usr/bin/codesign", "--force", "--deep", "--sign", "-", "--timestamp=none", str(app))
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
        (volume / "Applications").symlink_to("/Applications")
        shutil.copyfile(Path(__file__).resolve().parents[1] / "LICENSE", volume / "LICENSE")
        (volume / "README.txt").write_text(
            "cmux — cmux-pro fork with native remote zmx mapping\n\n"
            "Drag cmux to Applications. Apple Silicon; macOS 14 or later.\n"
            "This build is locally ad-hoc signed and is not Apple notarized.\n"
            "Updates are installed manually from the fork's GitHub releases.\n"
            "Use SSH ZMX in the command palette or cmux ssh-zmx your-ssh-alias.\n\n"
            "Source and GPL license: https://github.com/Kushalkhemka/cmux-pro\n"
            f"Release: {args.tag}\nNative source: {args.native_source_commit}\n"
        )
        run("/usr/bin/hdiutil", "create", "-volname", "cmux", "-srcfolder", str(volume),
            "-format", "UDZO", "-ov", str(dmg))
    run("/usr/bin/hdiutil", "verify", str(dmg))
    manifest = {
        "repository": "Kushalkhemka/cmux-pro",
        "release": args.tag,
        "packaging_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
        "native_source_commit": args.native_source_commit,
        "native_binary_sha256_before_packaging": digest(native),
        "architecture": architectures,
        "app_name": "cmux",
        "bundle_identifier": source_info["CFBundleIdentifier"],
        "version": source_info["CFBundleShortVersionString"],
        "signing": "ad-hoc",
        "notarized": False,
        "dmg_sha256": digest(dmg),
    }
    (args.out / "release-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (args.out / "SHA256SUMS").write_text(f"{manifest['dmg_sha256']}  cmux-macos.dmg\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
