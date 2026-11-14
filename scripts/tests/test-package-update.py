#!/usr/bin/env python3
"""Offline signed-release packaging fixtures; no Keychain, compiler, network or app IO."""

import base64
import hashlib
import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("package_update", ROOT / "scripts/package-update.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
PUBLIC = base64.b64encode(b"p" * 32).decode()
SIGNATURE = base64.b64encode(b"s" * 64).decode()


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tt-update-package-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "input with spaces/TalkTalk.app"
        self.out = self.root / "releases/v1.2.3"
        self.tools = self.root / "tools"
        self.tools.mkdir()
        for name in ("generate_keys", "sign_update"):
            (self.tools / name).write_text("fixture only")
        self.config = {"TT_UPDATE_FEED_URL": module.FEED_URL, "TT_UPDATE_PUBLIC_KEY": PUBLIC,
                       "TT_UPDATE_KEYCHAIN_ACCOUNT": "fixture-account", "TT_SPARKLE_VERSION": "2.10.1"}
        self.info = {"CFBundleIdentifier": "com.aaajiao.talktalk", "CFBundleShortVersionString": "1.2.3",
                     "CFBundleVersion": "80", "LSMinimumSystemVersion": "26.0", "SUFeedURL": module.FEED_URL,
                     "SUPublicEDKey": PUBLIC, "SUSignedFeedFailureExpirationInterval": 0, **{field: False for field in module.MANUAL_FLAGS},
                     **{field: True for field in module.VERIFY_FLAGS}}
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/MacOS/TalkTalk").write_bytes(b"fixture binary")
        self.write_info(self.app, self.info)
        framework = self.app / "Contents/Frameworks/Sparkle.framework"
        (framework / "Versions/B/Resources").mkdir(parents=True)
        (framework / "Versions/B/Sparkle").write_bytes(b"fixture framework")
        (framework / "Versions/Current").symlink_to("B")
        (framework / "Sparkle").symlink_to("Versions/Current/Sparkle")
        (framework / "Resources").symlink_to("Versions/Current/Resources")
        with (framework / "Resources/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleShortVersionString": "2.10.1"}, stream)
        self.calls = []
        self.public = PUBLIC
        self.signature = SIGNATURE
        self.fail = None
        self.mutate_snapshot = False

    @staticmethod
    def write_info(app, info):
        with (app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump(info, stream)

    def runner(self, args, **kwargs):
        self.assertIs(kwargs.get("check"), True)
        self.assertIs(kwargs.get("capture_output"), True)
        self.assertIs(kwargs.get("text"), True)
        self.assertNotIn("shell", kwargs)
        self.calls.append(args)
        exe = Path(args[0]).name
        if self.fail and self.fail(args):
            raise subprocess.CalledProcessError(1, args, stderr="fixture failure")
        output = ""
        if exe == "generate_keys":
            self.assertEqual(args[1:], ["--account", "fixture-account", "-p"])
            output = self.public + "\n"
        elif exe == "ditto":
            if "-c" in args:
                Path(args[-1]).write_bytes(b"fixture signed archive bytes")
            else:
                shutil.copytree(args[1], args[2], symlinks=True)
                if self.mutate_snapshot:
                    changed = dict(self.info, CFBundleVersion="81")
                    self.write_info(Path(args[2]), changed)
        elif exe == "sign_update":
            self.assertEqual(args[1:3], ["--account", "fixture-account"])
            if "-p" in args:
                output = self.signature + "\n"
            elif "--verify" not in args:
                path = Path(args[-1])
                path.write_bytes(path.read_bytes() + b"<!-- fixture signed feed -->\n")
        else:
            self.assertEqual(exe, "codesign")
        return subprocess.CompletedProcess(args, 0, stdout=output, stderr="")

    def package(self, **kwargs):
        return module.package_update(self.app, self.out, self.tools, self.config,
                                     notes="Notes <script>alert('x')</script>\nsecond line", runner=self.runner, **kwargs)

    def assert_no_output(self):
        self.assertFalse(self.out.exists())
        if self.out.parent.exists():
            self.assertEqual(list(self.out.parent.glob(".talktalk-update-*")), [])

    def test_complete_package_covers_feed_and_archive_and_preserves_notes_as_text(self):
        self.assertEqual(self.package(), self.out.resolve())
        names = {path.name for path in self.out.iterdir()}
        self.assertEqual(names, {"TalkTalk-1.2.3-macOS-arm64.zip", "SHA256SUMS.txt", "appcast.xml"})
        checksums = (self.out / "SHA256SUMS.txt").read_text().splitlines()
        self.assertEqual(len(checksums), 2)
        for line in checksums:
            digest, name = line.split("  ", 1)
            self.assertEqual(digest, hashlib.sha256((self.out / name).read_bytes()).hexdigest())
        tree = ET.fromstring((self.out / "appcast.xml").read_bytes())
        item = tree.find("channel/item")
        self.assertEqual(item.find(f"{{{module.SPARKLE_NS}}}version").text, "80")
        self.assertEqual(item.find(f"{{{module.SPARKLE_NS}}}hardwareRequirements").text, "arm64")
        self.assertEqual(item.find(f"{{{module.SPARKLE_NS}}}minimumSystemVersion").text, "26.4.0")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"), "https://github.com/aaajiao/talktalk/releases/download/v1.2.3/TalkTalk-1.2.3-macOS-arm64.zip")
        self.assertEqual(enclosure.get(f"{{{module.SPARKLE_NS}}}edSignature"), SIGNATURE)
        self.assertNotIn("<script>", item.find("description").text)
        self.assertIn("&lt;script&gt;", item.find("description").text)
        verifies = [args for args in self.calls if Path(args[0]).name == "sign_update" and "--verify" in args]
        self.assertEqual(len(verifies), 2)
        self.assertEqual(verifies[0][-1], SIGNATURE)
        self.assertTrue(verifies[1][-1].endswith("appcast.xml"))
        self.assertEqual((self.app / "Contents/MacOS/TalkTalk").read_bytes(), b"fixture binary")

    def test_key_mismatch_fails_before_creating_output_or_snapshot(self):
        self.public = base64.b64encode(b"q" * 32).decode()
        with self.assertRaisesRegex(ValueError, "Keychain public key"):
            self.package()
        self.assert_no_output()
        self.assertFalse(any(Path(args[0]).name == "ditto" for args in self.calls))

    def test_each_required_security_flag_cannot_be_missing_or_disabled(self):
        for field in module.VERIFY_FLAGS:
            for replacement in (None, False, 1):
                with self.subTest(field=field, replacement=replacement):
                    changed = dict(self.info)
                    if replacement is None:
                        del changed[field]
                    else:
                        changed[field] = replacement
                    self.write_info(self.app, changed)
                    with self.assertRaisesRegex(ValueError, field):
                        self.package()
                    self.assert_no_output()
        self.assertEqual(self.calls, [])

    def test_feed_signing_failure_cannot_expire(self):
        field = "SUSignedFeedFailureExpirationInterval"
        for value in (None, 1, -1, False):
            with self.subTest(value=value):
                changed = dict(self.info)
                if value is None:
                    del changed[field]
                else:
                    changed[field] = value
                self.write_info(self.app, changed)
                with self.assertRaisesRegex(ValueError, field):
                    self.package()
                self.assert_no_output()
        self.assertEqual(self.calls, [])

    def test_silent_install_or_profile_sharing_flags_are_rejected(self):
        for field in module.MANUAL_FLAGS:
            with self.subTest(field=field):
                self.write_info(self.app, dict(self.info, **{field: True}))
                with self.assertRaisesRegex(ValueError, field):
                    self.package()
        self.assertEqual(self.calls, [])

    def test_snapshot_changed_during_packaging_is_not_signed(self):
        self.mutate_snapshot = True
        with self.assertRaisesRegex(ValueError, "changed while packaging"):
            self.package()
        self.assert_no_output()
        self.assertFalse(any(Path(args[0]).name == "sign_update" for args in self.calls))

    def test_failed_signature_verification_leaves_no_release_directory(self):
        self.fail = lambda args: Path(args[0]).name == "sign_update" and "--verify" in args
        with self.assertRaises(subprocess.CalledProcessError):
            self.package()
        self.assert_no_output()

    def test_failed_feed_signing_leaves_no_release_directory(self):
        self.fail = lambda args: Path(args[0]).name == "sign_update" and args[-1].endswith("appcast.xml")
        with self.assertRaises(subprocess.CalledProcessError):
            self.package()
        self.assert_no_output()

    def test_invalid_signature_output_is_rejected(self):
        for signature in ("", "not base64", base64.b64encode(b"short").decode()):
            with self.subTest(signature=signature):
                self.signature = signature
                with self.assertRaisesRegex(ValueError, "invalid archive signature"):
                    self.package()
                self.assert_no_output()

    def test_existing_output_is_never_modified(self):
        self.out.mkdir(parents=True)
        sentinel = self.out / "existing.zip"
        sentinel.write_bytes(b"keep")
        with self.assertRaisesRegex(ValueError, "output already exists"):
            self.package()
        self.assertEqual(sentinel.read_bytes(), b"keep")
        self.assertEqual(self.calls, [])

    def test_dev_bundle_or_changed_feed_fails_before_keychain_lookup(self):
        for changes in ({"CFBundleIdentifier": "com.aaajiao.talktalk.dev"}, {"SUFeedURL": "https://example.com/feed.xml"},
                        {"SUPublicEDKey": base64.b64encode(b"x" * 32).decode()}):
            with self.subTest(changes=changes):
                self.write_info(self.app, dict(self.info, **changes))
                with self.assertRaises(ValueError):
                    self.package()
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
