#!/usr/bin/env python3
"""Isolated packaging-number fixtures. No Swift/compiler/signing/install command is run."""

import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


REPO = Path(__file__).resolve().parents[2]
GENERATED = (
    "Sources/TalkTalkCore/Generated/EnginePins.swift",
    "Sources/TalkTalkCore/Generated/DriverPins.swift",
    "Driver/Sources/Generated/DriverPins.hpp",
    "Driver/Sources/Generated/DriverPins.h",
    ".python-version",
)


class AppBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tt-app-build-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "project"
        (self.root / "scripts/lib").mkdir(parents=True)
        for name in ("build-app.sh", "reserve-app-build.py", "gen-pins.sh"):
            shutil.copy2(REPO / "scripts" / name, self.root / "scripts" / name)
        for name in ("common.sh", "versions.sh"):
            shutil.copy2(REPO / "scripts/lib" / name, self.root / "scripts/lib" / name)
        self.versions = self.root / "scripts/lib/versions.sh"
        source = self.versions.read_text()
        # A fixture-only semantic version prevents the real installed apps from affecting
        # build-app's default local search. Direct helper tests supply explicit bundle paths.
        source = re.sub(r'^TT_APP_VERSION="[^"]*"', 'TT_APP_VERSION="99.88.77"', source, flags=re.MULTILINE)
        source = re.sub(r'^TT_APP_BUILD="[^"]*"', 'TT_APP_BUILD="7"', source, flags=re.MULTILINE)
        self.versions.write_text(source)
        subprocess.run([str(self.root / "scripts/gen-pins.sh")], check=True, capture_output=True)
        self.original_versions = source
        self.original_generated = {name: (self.root / name).read_bytes() for name in GENERATED}
        self.fake_bin = self.root / "fake-bin"
        self.fake_bin.mkdir()
        self.environment = dict(os.environ, PATH=str(self.fake_bin) + os.pathsep + os.environ["PATH"],
                                TT_FIXTURE_ROOT=str(self.root))
        # Packaging fixtures use the test runner's interpreter and an offline preflight stub;
        # they never download CPython, install dependencies or run a compiler.
        self.python = self.root / ".venv/bin/python3"
        self.python.parent.mkdir(parents=True)
        self.python.symlink_to(sys.executable)
        self.setup_python = self.root / "scripts/setup-dev-python.sh"
        self.setup_python.write_text('#!/bin/bash\n[ "$1" = --check ]\n')
        self.setup_python.chmod(0o755)
        self.write_swift("#!/bin/bash\nexit 77\n")

    def write_swift(self, text):
        swift = self.fake_bin / "swift"
        swift.write_text(text)
        swift.chmod(0o755)

    def build_number(self):
        return int(re.search(r'^TT_APP_BUILD="([0-9]+)"', self.versions.read_text(), re.MULTILINE).group(1))

    def run_pack(self, flavor="release"):
        return subprocess.run([str(self.root / "scripts/build-app.sh"), flavor], env=self.environment,
                              capture_output=True, text=True, timeout=20)

    def reserve(self, *bundles):
        args = [str(self.python), "-I", "-B", str(self.root / "scripts/reserve-app-build.py")]
        for bundle in bundles or (self.root / "no-installed-app.app",):
            args.extend(["--app-bundle", str(bundle)])
        return subprocess.run(args, capture_output=True, text=True, timeout=20)

    def write_bundle(self, path, build, version="99.88.77", identifier="com.aaajiao.talktalk"):
        (path / "Contents").mkdir(parents=True)
        with (path / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
                          "CFBundleVersion": str(build)}, stream)

    def test_successive_reservations_only_change_application_build(self):
        for expected in (8, 9):
            result = self.reserve()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.build_number(), expected)
            generated = (self.root / GENERATED[0]).read_text()
            self.assertIn(f'appBuild = "{expected}"', generated)
        strip_source_build = lambda text: re.sub(r'^TT_APP_BUILD="[0-9]+"', "", text, flags=re.MULTILINE)
        self.assertEqual(strip_source_build(self.versions.read_text()), strip_source_build(self.original_versions))
        strip_generated_build = lambda text: re.sub(r'^    public static let appBuild = "[0-9]+"\n', "", text,
                                                    flags=re.MULTILINE)
        self.assertEqual(strip_generated_build((self.root / GENERATED[0]).read_text()),
                         strip_generated_build(self.original_generated[GENERATED[0]].decode()))
        for name in GENERATED[1:]:
            self.assertEqual((self.root / name).read_bytes(), self.original_generated[name], name)

    def test_failed_packages_consume_their_numbers(self):
        for flavor, expected in (("dev", 8), ("release", 9)):
            result = self.run_pack(flavor)
            self.assertEqual(result.returncode, 77, result.stderr)
            self.assertEqual(self.build_number(), expected)
        self.assertFalse((self.root / "build/TalkTalk.app").exists())

    def test_missing_development_environment_fails_before_reserving_number(self):
        self.setup_python.write_text('#!/bin/bash\necho "run setup-dev-python.sh" >&2\nexit 1\n')
        result = self.run_pack()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("setup-dev-python.sh", result.stderr)
        self.assertEqual(self.build_number(), 7)
        for name in GENERATED:
            self.assertEqual((self.root / name).read_bytes(), self.original_generated[name], name)

    def test_stale_compiled_identity_is_rejected_before_assembly(self):
        self.write_swift('''#!/usr/bin/env python3
import pathlib, sys
scratch = pathlib.Path(sys.argv[sys.argv.index("--scratch-path") + 1])
binary = scratch / "release/TalkTalk"
binary.parent.mkdir(parents=True)
binary.write_text("#!/bin/bash\\nprintf 'TalkTalk 99.88.77 (7) (engine API 2, release, dev hooks: none)\\\\n'\\n")
binary.chmod(0o755)
''')
        result = self.run_pack()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("compiled binary version does not match reserved", result.stderr)
        self.assertEqual(self.build_number(), 8)
        self.assertFalse((self.root / "build/.staging-release").exists())

    def test_existing_same_version_bundles_prevent_build_number_regression(self):
        self.write_bundle(self.root / "build/TalkTalk.app", 20)
        self.write_bundle(self.root / "build/TalkTalk-Dev.app", 25, identifier="com.aaajiao.talktalk.dev")
        installed = self.root / "fixture Applications/TalkTalk.app"
        self.write_bundle(installed, 30)
        other_version = self.root / "other Applications/TalkTalk.app"
        self.write_bundle(other_version, 999, version="88.1.0")
        result = self.reserve(installed, other_version)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.build_number(), 31)

    def test_preexisting_engine_or_driver_drift_is_rejected_without_reservation(self):
        for name in (GENERATED[0], GENERATED[2]):
            with self.subTest(name=name):
                path = self.root / name
                original = path.read_bytes()
                planted = original + b"\n// pre-existing drift\n"
                path.write_bytes(planted)
                result = self.run_pack()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.build_number(), 7)
                self.assertEqual(path.read_bytes(), planted)
                path.write_bytes(original)

    def test_dev_and_release_hold_one_lock_through_the_build(self):
        self.write_swift('''#!/usr/bin/env python3
import os, pathlib, re, sys, time
root = pathlib.Path(os.environ["TT_FIXTURE_ROOT"])
flavor = pathlib.Path(sys.argv[sys.argv.index("--scratch-path") + 1]).name
number = re.search(r'^TT_APP_BUILD="([0-9]+)"', (root / "scripts/lib/versions.sh").read_text(), re.M).group(1)
(root / (flavor + ".entered")).write_text(number)
if flavor == "dev":
    while not (root / "dev.release").exists():
        time.sleep(0.02)
raise SystemExit(77)
''')
        processes = []
        try:
            dev = subprocess.Popen([str(self.root / "scripts/build-app.sh"), "dev"], env=self.environment,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            processes.append(dev)
            deadline = time.monotonic() + 10
            while not (self.root / "dev.entered").exists():
                self.assertIsNone(dev.poll(), "dev fixture exited before reaching the fake compiler")
                self.assertLess(time.monotonic(), deadline, "dev fixture did not start")
                time.sleep(0.02)
            release = subprocess.Popen([str(self.root / "scripts/build-app.sh"), "release"], env=self.environment,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            processes.append(release)
            time.sleep(0.2)
            self.assertFalse((self.root / "release.entered").exists())
            self.assertEqual(self.build_number(), 8)
            (self.root / "dev.release").touch()
            for process in processes:
                _, error = process.communicate(timeout=20)
                self.assertEqual(process.returncode, 77, error.decode())
            self.assertEqual((self.root / "dev.entered").read_text(), "8")
            self.assertEqual((self.root / "release.entered").read_text(), "9")
        finally:
            for process in processes:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                process.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main(verbosity=2)
