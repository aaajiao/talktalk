#!/usr/bin/env python3
"""Offline publisher fixtures. Every git, GitHub and signing command is simulated."""

import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("publish_release", ROOT / "scripts/publish-release.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
HEAD = "a" * 40


class PublisherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tt-release-publish-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / "scripts/lib").mkdir(parents=True)
        (self.root / "scripts/lib/versions.sh").write_text('TT_APP_VERSION="1.2.3"\nTT_APP_BUILD="80"\n')
        (self.root / "Package.swift").write_text("// fixture package\n")
        (self.root / "Package.resolved").write_text("{}\n")
        (self.root / "Sources/Fixture").mkdir(parents=True)
        (self.root / "Sources/Fixture/main.swift").write_text("print(1)\n")
        self.app = self.root / "build/TalkTalk.app"
        (self.app / "Contents").mkdir(parents=True)
        with (self.app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "com.aaajiao.talktalk", "CFBundleShortVersionString": "1.2.3",
                          "CFBundleVersion": "80"}, stream)
        module.provenance.write_record(self.app / module.provenance.RECEIPT, module.provenance.fingerprint(self.root))
        self.notes = self.root / "build/release notes 'quote'.md"
        self.notes.write_text("A concrete change.\n\nValidation and limitations.\n")
        self.out = self.root / "build/releases/v1.2.3"
        self.calls = []
        self.dirty = False
        self.branch = "main"
        self.origin = "https://github.com/aaajiao/talktalk.git"
        self.remote_head = HEAD
        self.local_tag = False
        self.remote_tag = False
        self.release_status = 404
        self.draft_release = False
        self.tamper_digest = False
        self.tamper_size = False
        self.extra_asset = False
        self.fail_upload = False
        self.move_remote_after_upload = False
        self.uploaded = False
        self.published = False

    def runner(self, args, **kwargs):
        self.calls.append(args)
        self.assertEqual(kwargs["cwd"], self.root)
        self.assertTrue(kwargs["capture_output"] and kwargs["text"])
        self.assertNotIn("shell", kwargs)
        stdout, status = "", 0
        if args[:2] == ["git", "symbolic-ref"]:
            stdout = self.branch + "\n"
        elif args[:2] == ["git", "status"]:
            stdout = " M source.swift\n" if self.dirty else ""
        elif args[:3] == ["git", "remote", "get-url"]:
            stdout = self.origin + "\n"
        elif args[:2] == ["git", "rev-parse"]:
            stdout = HEAD + "\n"
        elif args[:2] == ["git", "ls-remote"]:
            if args[-1] == "refs/heads/main":
                head = "b" * 40 if self.uploaded and self.move_remote_after_upload else self.remote_head
                stdout = f"{head}\trefs/heads/main\n"
            elif self.remote_tag:
                stdout = f"{HEAD}\trefs/tags/v1.2.3\n"
        elif args[:2] == ["git", "show-ref"]:
            status = 0 if self.local_tag else 1
        elif args[:2] == ["gh", "api"]:
            if args[2].endswith("/releases"):
                stdout = json.dumps([[{"tag_name": "v1.2.3", "draft": True}]] if self.draft_release else [[]])
            else:
                status = 0 if self.release_status == 200 else 1
                stdout = f"HTTP/2.0 {self.release_status} Fixture\n\n{{}}"
        elif any(Path(arg).name == "package-update.py" for arg in args):
            output = Path(args[args.index("--out") + 1])
            self.assertEqual(Path(args[args.index("--notes-file") + 1]), self.notes)
            output.mkdir(parents=True)
            (output / "TalkTalk-1.2.3-macOS-arm64.zip").write_bytes(b"signed fixture archive")
            (output / "appcast.xml").write_bytes(b"signed fixture appcast")
            (output / "SHA256SUMS.txt").write_text("fixture checksums\n")
        elif args[:3] == ["gh", "release", "upload"]:
            if self.fail_upload:
                raise subprocess.CalledProcessError(1, args, stderr="fixture upload failed")
            self.uploaded = True
        elif args[:3] == ["gh", "release", "edit"]:
            self.published = True
        elif args[:3] == ["gh", "release", "view"]:
            expected = module.asset_metadata(list(self.out.iterdir()))
            assets = [{"name": name, "state": "uploaded", "size": size, "digest": digest}
                      for name, (size, digest) in expected.items()]
            if self.tamper_digest:
                assets[0]["digest"] = "sha256:" + "0" * 64
            if self.tamper_size:
                assets[0]["size"] += 1
            if self.extra_asset:
                assets.append({"name": "unexpected.zip", "state": "uploaded", "size": 1, "digest": "bad"})
            stdout = json.dumps({"tagName": "v1.2.3", "isDraft": not self.published, "isPrerelease": False,
                                 "url": "https://github.com/aaajiao/talktalk/releases/tag/v1.2.3", "assets": assets})
        elif args[:2] == ["git", "tag"] or args[:2] == ["git", "push"] or args[:3] == ["gh", "release", "create"]:
            pass
        else:
            self.fail(f"Unexpected command: {args}")
        if status and kwargs.get("check"):
            raise subprocess.CalledProcessError(status, args, output=stdout)
        return subprocess.CompletedProcess(args, status, stdout=stdout, stderr="")

    def publish(self):
        return module.publish(self.root, self.app, self.notes, runner=self.runner)

    def mutations(self):
        return [args for args in self.calls if args[:2] in (["git", "tag"], ["git", "push"])
                or args[:3] in (["gh", "release", "create"], ["gh", "release", "upload"], ["gh", "release", "edit"])]

    def test_success_uploads_only_signed_assets_then_verifies_before_publish(self):
        self.assertEqual(self.publish(), "https://github.com/aaajiao/talktalk/releases/tag/v1.2.3")
        self.assertTrue(self.published)
        tag = next(args for args in self.calls if args[:2] == ["git", "tag"])
        self.assertEqual(tag[-1], HEAD)
        create = next(args for args in self.calls if args[:3] == ["gh", "release", "create"])
        self.assertIn("--draft", create)
        self.assertIn("--verify-tag", create)
        self.assertEqual(create[create.index("--notes-file") + 1], str(self.notes))
        upload = next(args for args in self.calls if args[:3] == ["gh", "release", "upload"])
        self.assertNotIn("--clobber", upload)
        self.assertEqual({Path(name).name for name in upload[4:7]},
                         {"TalkTalk-1.2.3-macOS-arm64.zip", "SHA256SUMS.txt", "appcast.xml"})
        events = [args[2] for args in self.calls if args[:2] == ["gh", "release"]]
        self.assertEqual(events, ["create", "upload", "view", "edit", "view"])
        edit = next(args for args in self.calls if args[:3] == ["gh", "release", "edit"])
        self.assertIn("--draft=false", edit)
        self.assertIn("--latest", edit)

    def test_dirty_or_unpushed_sources_never_prepare_or_publish(self):
        for changed in ("dirty", "remote_head"):
            with self.subTest(changed=changed):
                self.calls = []
                self.dirty = changed == "dirty"
                self.remote_head = "b" * 40 if changed == "remote_head" else HEAD
                with self.assertRaises(module.ReleaseError):
                    self.publish()
                self.assertEqual(self.mutations(), [])
                self.assertFalse(self.out.exists())

    def test_wrong_branch_or_origin_is_rejected(self):
        for branch, origin in (("feature", self.origin), ("main", "https://github.com/other/repository.git")):
            with self.subTest(branch=branch, origin=origin):
                self.calls = []
                self.branch, self.origin = branch, origin
                with self.assertRaises(module.ReleaseError):
                    self.publish()
                self.assertEqual(self.mutations(), [])

    def test_existing_local_or_remote_tag_and_release_are_never_overwritten(self):
        for existing in ("local", "remote", "release"):
            with self.subTest(existing=existing):
                self.calls = []
                self.local_tag = existing == "local"
                self.remote_tag = existing == "remote"
                self.release_status = 200 if existing == "release" else 404
                with self.assertRaises(module.ReleaseError):
                    self.publish()
                self.assertEqual(self.mutations(), [])
                self.assertFalse(self.out.exists())

    def test_unpublished_draft_without_remote_tag_is_not_overlooked(self):
        self.draft_release = True
        with self.assertRaisesRegex(module.ReleaseError, "including drafts"):
            self.publish()
        self.assertEqual(self.mutations(), [])
        self.assertFalse(self.out.exists())

    def test_api_failure_is_not_treated_as_missing_release(self):
        for status in (401, 403, 429, 500):
            with self.subTest(status=status):
                self.calls = []
                self.release_status = status
                with self.assertRaisesRegex(module.ReleaseError, "expected HTTP 404"):
                    self.publish()
                self.assertEqual(self.mutations(), [])

    def test_bundle_version_mismatch_fails_before_git_or_network(self):
        with (self.app / "Contents/Info.plist").open("rb") as stream:
            metadata = plistlib.load(stream)
        metadata["CFBundleVersion"] = "79"
        with (self.app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump(metadata, stream)
        with self.assertRaisesRegex(module.ReleaseError, "identity"):
            self.publish()
        self.assertEqual(self.calls, [])

    def test_same_version_source_change_cannot_publish_an_old_bundle(self):
        (self.root / "Sources/Fixture/main.swift").write_text("print(2)\n")
        with self.assertRaisesRegex(ValueError, "source differs"):
            self.publish()
        self.assertEqual(self.calls, [])

    def test_missing_source_receipt_cannot_publish(self):
        (self.app / module.provenance.RECEIPT).unlink()
        with self.assertRaisesRegex(ValueError, "receipt missing"):
            self.publish()
        self.assertEqual(self.calls, [])

    def test_documentation_only_commit_does_not_invalidate_build(self):
        (self.root / "README.md").write_text("Updated download link\n")
        (self.root / "docs").mkdir()
        (self.root / "docs/releases.md").write_text("Release process update\n")
        self.assertEqual(self.publish(), "https://github.com/aaajiao/talktalk/releases/tag/v1.2.3")

    def test_remote_asset_digest_mismatch_keeps_release_in_draft(self):
        self.tamper_digest = True
        with self.assertRaisesRegex(module.ReleaseError, "asset verification failed"):
            self.publish()
        self.assertTrue(self.uploaded)
        self.assertFalse(self.published)
        self.assertFalse(any(args[:3] == ["gh", "release", "edit"] for args in self.calls))

    def test_remote_asset_size_mismatch_keeps_release_in_draft(self):
        self.tamper_size = True
        with self.assertRaisesRegex(module.ReleaseError, "asset verification failed"):
            self.publish()
        self.assertFalse(self.published)

    def test_unexpected_remote_asset_keeps_release_in_draft(self):
        self.extra_asset = True
        with self.assertRaisesRegex(module.ReleaseError, "three prepared files"):
            self.publish()
        self.assertFalse(self.published)

    def test_failed_upload_does_not_publish_or_delete_anything(self):
        self.fail_upload = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.assertFalse(self.published)
        self.assertFalse(any("delete" in args or "--delete" in args for args in self.calls))

    def test_remote_main_moving_during_upload_prevents_latest_release(self):
        self.move_remote_after_upload = True
        with self.assertRaisesRegex(module.ReleaseError, "origin/main"):
            self.publish()
        self.assertTrue(self.uploaded)
        self.assertFalse(self.published)

    def test_existing_release_directory_is_preserved_before_git_or_network(self):
        self.out.mkdir(parents=True)
        (self.out / "keep").write_text("old package")
        with self.assertRaisesRegex(module.ReleaseError, "already exists"):
            self.publish()
        self.assertEqual((self.out / "keep").read_text(), "old package")
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
