#!/usr/bin/env python3
"""Run-scoped temporary cleanup, exit status, signals and concurrent isolation."""

import importlib.util
import io
from contextlib import redirect_stderr
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


WRAPPER = Path(__file__).resolve().parents[1] / "with-test-temp.py"
WRITE_TEMP = """
import os, pathlib, signal, socket, sys, tempfile, time
root = pathlib.Path(tempfile.gettempdir())
(root / 'unfinished-fixture').mkdir()
(root / 'unfinished-fixture/data').write_text('temporary fixture')
sock = socket.socket(socket.AF_UNIX)
sock.bind(str(root / 'fixture.sock'))
if sys.argv[2] == 'ignore':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
pathlib.Path(sys.argv[1]).write_text(str(root))
if sys.argv[2] in ('wait', 'ignore'):
    while not pathlib.Path(sys.argv[3]).exists():
        time.sleep(0.01)
else:
    raise SystemExit(int(sys.argv[2]))
"""


class TestTemporaryRuns(unittest.TestCase):
    def setUp(self):
        self.control = tempfile.TemporaryDirectory(prefix="tt-temp-tests-")
        self.addCleanup(self.control.cleanup)
        self.root = Path(self.control.name)
        self.processes = []
        self.addCleanup(self.stop_processes)

    def stop_processes(self):
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=5)

    def start(self, name, action, script=WRITE_TEMP):
        report, release = self.root / (name + ".path"), self.root / (name + ".release")
        process = subprocess.Popen([sys.executable, "-I", "-B", str(WRAPPER),
                                    sys.executable, "-I", "-B", "-c", script,
                                    str(report), action, str(release)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.processes.append(process)
        deadline = time.monotonic() + 5
        while not report.exists():
            if process.poll() is not None and not report.exists():
                self.fail("fixture exited before reporting its temporary directory")
            self.assertLess(time.monotonic(), deadline, "fixture failed to start")
            time.sleep(0.01)
        return process, Path(report.read_text()), release

    def finish(self, process, expected):
        _, error = process.communicate(timeout=5)
        self.assertEqual(process.returncode, expected, error.decode())

    def test_success_and_failure_clean_owned_directory_and_preserve_exit_code(self):
        sentinel = self.root / "unrelated.txt"
        sentinel.write_text("keep")
        for code in (0, 29):
            with self.subTest(code=code):
                process, directory, _ = self.start(str(code), str(code))
                self.finish(process, code)
                self.assertFalse(directory.exists())
                self.assertEqual(sentinel.read_text(), "keep")

    def test_sigint_and_sigterm_clean_owned_directory(self):
        for sig in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=sig):
                process, directory, _ = self.start(str(sig), "wait")
                process.send_signal(sig)
                self.finish(process, 128 + sig)
                self.assertFalse(directory.exists())

    def test_parallel_runs_never_remove_each_others_files(self):
        first, first_directory, release_first = self.start("first", "wait")
        second, second_directory, release_second = self.start("second", "wait")
        self.assertNotEqual(first_directory, second_directory)
        release_first.touch()
        self.finish(first, 0)
        self.assertFalse(first_directory.exists())
        self.assertTrue((second_directory / "unfinished-fixture/data").is_file())
        release_second.touch()
        self.finish(second, 0)
        self.assertFalse(second_directory.exists())

    def test_ignoring_child_is_stopped_before_cleanup(self):
        process, directory, _ = self.start("ignore", "ignore")
        process.terminate()
        self.finish(process, 128 + signal.SIGTERM)
        self.assertFalse(directory.exists())

    def test_background_writer_is_stopped_on_success_and_failure(self):
        script = """
import pathlib, subprocess, sys, tempfile, time
root = pathlib.Path(tempfile.gettempdir())
writer = '''
import pathlib, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
root = pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).touch()
while True:
    root.mkdir(exist_ok=True)
    (root / 'background-file').write_text('fixture')
    time.sleep(0.01)
'''
ready = pathlib.Path(sys.argv[3])
subprocess.Popen([sys.executable, '-I', '-B', '-c', writer, str(root), str(ready)])
while not ready.exists():
    time.sleep(0.01)
pathlib.Path(sys.argv[1]).write_text(str(root))
raise SystemExit(int(sys.argv[2]))
"""
        for code in (0, 29):
            with self.subTest(code=code):
                process, directory, _ = self.start("background" + str(code), str(code), script)
                self.finish(process, code)
                time.sleep(0.05)
                self.assertFalse(directory.exists(), "background writer recreated cleaned directory")

    def test_cleanup_error_fails_success_but_preserves_existing_failure(self):
        spec = importlib.util.spec_from_file_location("test_temp_wrapper", WRAPPER)
        wrapper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(wrapper)
        remove = shutil.rmtree

        def fail_after_removing(directory):
            # Exercise the error status without leaving a deliberately leaked test directory.
            remove(directory)
            raise PermissionError("fixture cleanup failure")

        for command_code, expected in ((0, 1), (29, 29)):
            with self.subTest(code=command_code), patch.object(wrapper.shutil, "rmtree", fail_after_removing):
                error = io.StringIO()
                with redirect_stderr(error):
                    result = wrapper.run([sys.executable, "-I", "-B", "-c", f"raise SystemExit({command_code})"])
                self.assertEqual(result, expected)
                self.assertIn("temporary directory cleanup failed", error.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
