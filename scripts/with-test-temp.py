#!/usr/bin/env python3
"""Run one validation command with an owned temporary directory, removed on exit.

The short /tmp parent keeps Foundation/Unix-socket fixtures below macOS path limits.
Only this invocation's mkdtemp directory is removed; sibling runs are never scanned.
"""

import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def signal_group(group, signum):
    try:
        os.killpg(group, signum)
        return True
    except ProcessLookupError:
        return False


def stop_group(group):
    """Stop only descendants still in this invocation's dedicated process group."""
    if not signal_group(group, signal.SIGTERM):
        return
    deadline = time.monotonic() + 2
    while signal_group(group, 0):
        if time.monotonic() >= deadline:
            signal_group(group, signal.SIGKILL)
            return
        time.sleep(0.02)


def run(command):
    # Use a canonical path so Python, Foundation and child shells see the same directory.
    directory = Path(tempfile.mkdtemp(prefix="tt-check-", dir="/tmp")).resolve()
    process = None
    interrupted = None
    interrupted_at = None
    code = 127

    def forward(signum, _frame):
        nonlocal interrupted, interrupted_at
        if interrupted is None:
            interrupted = signum
            interrupted_at = time.monotonic()
        if process is not None:
            signal_group(process.pid, signum)

    previous = {sig: signal.signal(sig, forward) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        environment = dict(os.environ, TMPDIR=str(directory) + "/", TMP=str(directory), TEMP=str(directory),
                           TALKTALK_CHECK_TMP_SCOPE="1")
        process = subprocess.Popen(command, env=environment, start_new_session=True)
        if interrupted is not None:
            forward(interrupted, None)
        while True:
            try:
                code = process.wait(timeout=0.1)
                code = 128 - code if code < 0 else code
                break
            except subprocess.TimeoutExpired:
                if interrupted_at is not None and time.monotonic() - interrupted_at >= 2:
                    # A child that ignores cancellation must not keep writing after cleanup.
                    signal_group(process.pid, signal.SIGKILL)
    except OSError as error:
        print(f"test command could not start: {error}", file=sys.stderr)
        code = 127
    finally:
        # Python's finally is the EXIT trap, including command failure and handled signals.
        # Reap/stop the owned group before removing files, including on ordinary exit:
        # a forgotten background fixture must not recreate its directory afterward.
        if process is not None:
            stop_group(process.pid)
        try:
            shutil.rmtree(directory)
        except OSError as error:
            print(f"test temporary directory cleanup failed: {error}", file=sys.stderr)
            if code == 0:
                code = 1
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    return 128 + interrupted if interrupted is not None else code


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("usage: with-test-temp.py command [arguments ...]")
    raise SystemExit(run(sys.argv[1:]))
