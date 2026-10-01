#!/usr/bin/env python3
"""Package a signed, notarized release and generate its signed Sparkle appcast.
Does not build, run the application, upload files or deploy the website.
"""
import argparse
import plistlib
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

FEED = "https://www.webframes.pro/updates/appcast.xml"
ACCOUNT = "app.essazanov.webframes"
# Written by hand after the private key has been exported to a safe place
# (see Tools/updates/README.md, "Back up the signing key"). Contains the public
# key the backup belongs to, so a regenerated key cannot pass on a stale marker.
BACKUP_MARKER = Path.home() / "Library/Application Support/Web Frames/sparkle-key-backup.txt"

def run(*args):
    return subprocess.run([str(x) for x in args], check=True, text=True, capture_output=True).stdout.strip()

def require_key_backup(public_key, skip):
    if skip:
        print("WARNING: skipping the Sparkle key backup check.", file=sys.stderr)
        return
    if not BACKUP_MARKER.exists():
        raise ValueError(
            "No Sparkle key backup recorded. Export the private key and write the marker first "
            f"(README, 'Back up the signing key'): {BACKUP_MARKER}")
    if public_key not in BACKUP_MARKER.read_text():
        raise ValueError(
            "The recorded Sparkle key backup is for a different key. Back up the current key "
            f"and rewrite {BACKUP_MARKER} before publishing.")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Exported Developer ID .app with notarization ticket stapled")
    parser.add_argument("updates", type=Path, help="Directory retaining published ZIPs and appcast.xml")
    parser.add_argument("--sparkle-bin", required=True, type=Path, help="Sparkle artifact bin directory from Xcode SourcePackages")
    parser.add_argument("--skip-backup-check", action="store_true", help="Publish without a recorded private-key backup (not recommended)")
    args = parser.parse_args()
    app = args.app.resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != ACCOUNT or info.get("SUFeedURL") != FEED:
        raise ValueError("Choose the Web Frames release configured for the production update feed.")
    key = run(args.sparkle_bin / "generate_keys", "--account", ACCOUNT, "-p")
    if key != info.get("SUPublicEDKey"):
        raise ValueError("The release public key does not match the signing key in Keychain.")
    require_key_backup(key, args.skip_backup_check)
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", build) or not re.fullmatch(r"[0-9A-Za-z._-]+", version):
        raise ValueError("Use a numeric increasing build number and a filename-safe marketing version.")
    updates = args.updates.resolve()
    feed = updates / "appcast.xml"
    if feed.exists():
        ns = {"s": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
        previous = [v.text for v in ET.parse(feed).findall("./channel/item/s:version", ns)]
        def version_key(value):
            parts = [int(p) for p in value.split(".")]
            while len(parts) > 1 and parts[-1] == 0: parts.pop()
            return tuple(parts)
        if any(version_key(build) <= version_key(v) for v in previous if v):
            raise ValueError("Increase CURRENT_PROJECT_VERSION above all published build numbers.")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    run("/usr/sbin/spctl", "--assess", "--type", "execute", app)
    run("/usr/bin/xcrun", "stapler", "validate", app)
    updates.mkdir(parents=True, exist_ok=True)
    archive = updates / f"WebFrames-{version}-{build}.zip"
    if archive.exists():
        raise ValueError(f"Refusing to replace an existing release: {archive.name}")
    # generate_appcast links release notes that sit next to the archive with
    # the same name; render them from CHANGELOG.md's "## <version> (<build>)".
    notes = archive.with_suffix(".html")
    if not notes.exists():
        notes.write_text(run(sys.executable, Path(__file__).with_name("release_notes.py"), version, build) + "\n")
    run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
    run(args.sparkle_bin / "generate_appcast", "--account", ACCOUNT,
        "--download-url-prefix", "https://www.webframes.pro/updates/",
        "--link", "https://www.webframes.pro", "--maximum-deltas", "0", updates)
    print(f"Prepared {archive.name} and appcast.xml in {updates}")
    print("Publish the ZIP first, then the appcast. Nothing has been uploaded.")

if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, ET.ParseError, subprocess.CalledProcessError) as error:
        print(getattr(error, "stderr", None) or str(error), file=sys.stderr)
        sys.exit(1)
