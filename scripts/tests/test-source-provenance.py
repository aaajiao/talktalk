#!/usr/bin/env python3
"""Offline build-input receipts: stale-code detection without recording source content."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("build_source", ROOT / "scripts/source-provenance.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SourceProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tt-build-source-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.app = self.root / "build/TalkTalk.app"
        self.snapshot = self.root / "build/input-snapshot.json"
        for name, content in {
            "Package.swift": "// Package source\n", "Package.resolved": "{}\n",
            "scripts/lib/versions.sh": 'TT_APP_VERSION="1.2.3"\nTT_APP_BUILD="80"\n',
            "Sources/App/main.swift": 'print("original")\n',
            "Resources/prompts/mt.json": '{"prompt":"original"}\n',
            "engine/talktalk_engine/server.py": "value = 1\n",
            "Driver/Sources/Plugin.cpp": "int value = 1;\n",
            "Driver/third_party/libASPL/include/a.hpp": "// Header\n",
            "tools/feedprobe/feedprobe.c": "int main() { return 0; }\n",
            "scripts/build-app.sh": "#!/bin/bash\n",
            "scripts/driver/install-driver.sh": "#!/bin/bash\n",
            "LICENSE": "Fixture license\n", "THIRD_PARTY_NOTICES.md": "Fixture notices\n",
            "docs/maintenance.md": "Bundled maintenance guide\n",
        }.items():
            self.put(name, content)
        module.write_record(self.snapshot, module.fingerprint(self.root))
        module.embed_receipt(self.root, self.snapshot, self.app)

    def put(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def test_receipt_is_deterministic_and_contains_no_paths_or_source_content(self):
        receipt = module.verify_receipt(self.root, self.app)
        self.assertEqual(receipt, module.fingerprint(self.root))
        serialized = (self.app / module.RECEIPT).read_text()
        self.assertNotIn(str(self.root), serialized)
        self.assertNotIn("Sources/", serialized)
        self.assertNotIn("original", serialized)
        self.assertEqual(set(json.loads(serialized)), {"schema", "algorithm", "source_sha256", "file_count"})

    def test_changed_code_resources_driver_or_build_script_invalidates_old_bundle(self):
        for name in ("Sources/App/main.swift", "Resources/prompts/mt.json", "engine/talktalk_engine/server.py",
                     "Driver/Sources/Plugin.cpp", "Driver/third_party/libASPL/include/a.hpp", "tools/feedprobe/feedprobe.c",
                     "scripts/build-app.sh", "scripts/driver/install-driver.sh", "Package.resolved",
                     "docs/maintenance.md", "LICENSE", "THIRD_PARTY_NOTICES.md"):
            with self.subTest(name=name):
                path = self.root / name
                original = path.read_text()
                path.write_text(original + "changed\n")
                with self.assertRaisesRegex(ValueError, "source differs"):
                    module.verify_receipt(self.root, self.app)
                path.write_text(original)

    def test_new_untracked_source_file_is_part_of_the_fingerprint(self):
        self.put("Sources/App/NewFeature.swift", "// not in git yet\n")
        with self.assertRaisesRegex(ValueError, "source differs"):
            module.verify_receipt(self.root, self.app)

    def test_deleted_source_file_invalidates_old_bundle(self):
        (self.root / "Sources/App/main.swift").unlink()
        with self.assertRaisesRegex(ValueError, "source differs"):
            module.verify_receipt(self.root, self.app)

    def test_docs_tests_and_cache_changes_do_not_invalidate_built_code(self):
        for name in ("README.md", "README.zh-CN.md", "docs/releases.md", "docs/remaining-work.md",
                     "Tests/Fixture/test.swift", "engine/tests/test_server.py", "scripts/tests/test-pack.py",
                     "engine/talktalk_engine/__pycache__/server.pyc", "Sources/.DS_Store"):
            self.put(name, "does not ship\n")
        module.verify_receipt(self.root, self.app)

    def test_source_changes_during_compilation_prevent_receipt_embedding(self):
        self.put("Sources/App/main.swift", "// changed during build\n")
        new_app = self.root / "build/new/TalkTalk.app"
        with self.assertRaisesRegex(ValueError, "changed during build"):
            module.embed_receipt(self.root, self.snapshot, new_app)
        self.assertFalse((new_app / module.RECEIPT).exists())

    def test_missing_receipt_requires_rebuild(self):
        (self.app / module.RECEIPT).unlink()
        with self.assertRaisesRegex(ValueError, "receipt missing"):
            module.verify_receipt(self.root, self.app)

    def test_symlinked_source_is_rejected_without_reading_external_target(self):
        external = self.root / "outside.txt"
        external.write_text("must not be included\n")
        link = self.root / "Sources/App/link.swift"
        link.symlink_to(external)
        with self.assertRaisesRegex(ValueError, "must not be a symlink"):
            module.fingerprint(self.root)

    def test_executable_bit_changes_affect_fingerprint(self):
        path = self.root / "scripts/driver/install-driver.sh"
        path.chmod(path.stat().st_mode | 0o100)
        with self.assertRaisesRegex(ValueError, "source differs"):
            module.verify_receipt(self.root, self.app)


if __name__ == "__main__":
    unittest.main(verbosity=2)
