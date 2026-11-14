#!/usr/bin/env python3
"""Package an existing TalkTalk release and sign its archive/feed; never build or publish.

The private key stays in the login Keychain. Sparkle's tools access it directly; this script
only reads the public key and refuses to sign with a key that differs from the app's pin.
"""

import argparse
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
import hashlib
import html
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
FEED_URL = "https://github.com/aaajiao/talktalk/releases/latest/download/appcast.xml"
RELEASES_URL = "https://github.com/aaajiao/talktalk/releases"
UPDATE_MINIMUM_SYSTEM_VERSION = "26.4.0"  # supported user OS; compiler deployment target remains 26.0
MANUAL_FLAGS = ("SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates", "SUSendProfileInfo")
VERIFY_FLAGS = ("SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed")


def read_config(path=ROOT / "scripts/lib/updates.sh"):
    """Read public literal pins without executing a shell or expanding environment values."""
    result = dict(re.findall(r'^(TT_[A-Z_]+)="([^"\n]*)"$', path.read_text(), re.MULTILINE))
    for key in ("TT_UPDATE_FEED_URL", "TT_UPDATE_PUBLIC_KEY", "TT_UPDATE_KEYCHAIN_ACCOUNT"):
        if not result.get(key):
            raise ValueError(f"missing updater configuration: {key}")
    if result["TT_UPDATE_FEED_URL"] != FEED_URL:
        raise ValueError("unexpected updater feed URL")
    try:
        public = base64.b64decode(result["TT_UPDATE_PUBLIC_KEY"], validate=True)
    except ValueError as error:
        raise ValueError("invalid updater public key") from error
    if len(public) != 32:
        raise ValueError("updater public key must contain 32 bytes")
    return result


def validate_bundle(app: Path, config: dict) -> dict:
    if app.name != "TalkTalk.app" or not app.is_dir():
        raise ValueError("only an existing release TalkTalk.app can be packaged")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != "com.aaajiao.talktalk":
        raise ValueError("bundle is not the TalkTalk release application")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", str(info.get("CFBundleShortVersionString", ""))):
        raise ValueError("release version must be major.minor.patch")
    if not re.fullmatch(r"[1-9][0-9]*", str(info.get("CFBundleVersion", ""))):
        raise ValueError("release build number must be a positive integer")
    if info.get("LSMinimumSystemVersion") != "26.0":
        raise ValueError("unexpected compiler deployment target; update the packaging policy first")
    for field, expected in (("SUFeedURL", config["TT_UPDATE_FEED_URL"]),
                            ("SUPublicEDKey", config["TT_UPDATE_PUBLIC_KEY"])):
        if info.get(field) != expected:
            raise ValueError(f"bundle {field} differs from updater configuration")
    for field in MANUAL_FLAGS:
        if info.get(field) is not False:
            raise ValueError(f"bundle {field} must be false")
    for field in VERIFY_FLAGS:
        if info.get(field) is not True:
            raise ValueError(f"bundle {field} must be true")
    expiration = info.get("SUSignedFeedFailureExpirationInterval")
    if type(expiration) is not int or expiration != 0:
        raise ValueError("bundle SUSignedFeedFailureExpirationInterval must be integer zero")
    if not (app / "Contents/MacOS/TalkTalk").is_file():
        raise ValueError("application executable missing")
    framework = app / "Contents/Frameworks/Sparkle.framework"
    if not (framework / "Versions/Current").is_symlink() or not (framework / "Sparkle").is_symlink():
        raise ValueError("Sparkle version symlinks missing")
    with (framework / "Resources/Info.plist").open("rb") as stream:
        sparkle = plistlib.load(stream)
    if sparkle.get("CFBundleShortVersionString") != config.get("TT_SPARKLE_VERSION", "2.10.1"):
        raise ValueError("embedded Sparkle does not match the pinned version")
    return info


def make_appcast(info: dict, archive: Path, signature: str, notes: str) -> bytes:
    ET.register_namespace("sparkle", SPARKLE_NS)
    sparkle = lambda name: f"{{{SPARKLE_NS}}}{name}"
    version = info["CFBundleShortVersionString"]
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "TalkTalk Updates"
    ET.SubElement(channel, "link").text = RELEASES_URL
    ET.SubElement(channel, "description").text = "TalkTalk application updates"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"TalkTalk {version}"
    ET.SubElement(item, "link").text = f"{RELEASES_URL}/tag/v{version}"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc), usegmt=True)
    ET.SubElement(item, sparkle("version")).text = str(info["CFBundleVersion"])
    ET.SubElement(item, sparkle("shortVersionString")).text = version
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = UPDATE_MINIMUM_SYSTEM_VERSION
    ET.SubElement(item, sparkle("hardwareRequirements")).text = "arm64"
    if notes.strip():
        # Notes are plain text, not executable HTML; embed so the signed feed covers them.
        ET.SubElement(item, "description").text = "<p>" + html.escape(notes).replace("\n", "<br />") + "</p>"
    ET.SubElement(item, "enclosure", {
        "url": f"{RELEASES_URL}/download/v{version}/{archive.name}",
        sparkle("edSignature"): signature,
        "length": str(archive.stat().st_size),
        "type": "application/octet-stream",
    })
    ET.indent(rss, space="  ")
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True) + b"\n"


def package_update(app: Path, out: Path, tools_dir: Path, config: dict, notes: str = "", runner=subprocess.run) -> Path:
    app, out, tools_dir = app.resolve(), out.resolve(), tools_dir.resolve()
    if out.exists():
        raise ValueError("output already exists; choose a new release directory")
    if app == out or app in out.parents:
        raise ValueError("output must be outside the application bundle")
    info = validate_bundle(app, config)
    if config["TT_UPDATE_FEED_URL"] != FEED_URL:
        raise ValueError("unexpected updater feed URL")
    generate_keys, sign_update = tools_dir / "generate_keys", tools_dir / "sign_update"
    for tool in (generate_keys, sign_update):
        if not tool.is_file():
            raise ValueError(f"Sparkle tool missing: {tool.name}")

    def run(args):
        return runner([str(value) for value in args], check=True, capture_output=True, text=True)

    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    account = config["TT_UPDATE_KEYCHAIN_ACCOUNT"]
    public = run([generate_keys, "--account", account, "-p"]).stdout.strip()
    if public != info["SUPublicEDKey"]:
        raise ValueError("Keychain public key differs from the key embedded in the app")

    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".talktalk-update-", dir=out.parent) as directory:
        work = Path(directory)
        snapshot = work / "TalkTalk.app"
        # Snapshot and validate first so a concurrent build cannot mix two bundles in the ZIP.
        run(["/usr/bin/ditto", app, snapshot])
        if validate_bundle(snapshot, config) != info:
            raise ValueError("application changed while packaging")
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", snapshot])
        assets = work / "assets"
        assets.mkdir()
        archive = assets / f"TalkTalk-{info['CFBundleShortVersionString']}-macOS-arm64.zip"
        run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", snapshot, archive])
        signature = run([sign_update, "--account", account, "-p", archive]).stdout.strip()
        try:
            signature_bytes = base64.b64decode(signature, validate=True)
        except ValueError as error:
            raise ValueError("Sparkle returned an invalid archive signature") from error
        if len(signature_bytes) != 64:
            raise ValueError("Sparkle returned an invalid archive signature")
        run([sign_update, "--account", account, "--verify", archive, signature])
        appcast = assets / "appcast.xml"
        appcast.write_bytes(make_appcast(info, archive, signature, notes))
        run([sign_update, "--account", account, appcast])
        run([sign_update, "--account", account, "--verify", appcast])
        sums = []
        for path in (archive, appcast):
            with path.open("rb") as stream:
                sums.append(f"{hashlib.file_digest(stream, 'sha256').hexdigest()}  {path.name}\n")
        (assets / "SHA256SUMS.txt").write_text("".join(sums), encoding="utf-8")
        if out.exists():
            raise ValueError("output appeared while packaging; refusing to overwrite it")
        assets.rename(out)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "build/TalkTalk.app")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--notes-file", type=Path, help="plain-text release notes embedded in the signed feed")
    parser.add_argument("--tools-dir", type=Path, help="directory containing Sparkle's sign_update and generate_keys")
    args = parser.parse_args()
    tools_dir = args.tools_dir
    if tools_dir is None:
        candidates = [ROOT / ".build/release/artifacts/sparkle/Sparkle/bin", ROOT / ".build/artifacts/sparkle/Sparkle/bin"]
        tools_dir = next((path for path in candidates if (path / "sign_update").is_file()), candidates[0])
    try:
        result = package_update(args.app, args.out, tools_dir, read_config(),
                                args.notes_file.read_text() if args.notes_file else "")
    except subprocess.CalledProcessError as error:
        # Tool stdout/stderr are deliberately not echoed: signing tool diagnostics must not
        # accidentally leak Keychain material. Public-key lookup/signing failures stay closed.
        parser.exit(1, f"package-update: {Path(error.cmd[0]).name} failed (exit {error.returncode}); no release published\n")
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"package-update: {error}\n")
    print(result)


if __name__ == "__main__":
    main()
