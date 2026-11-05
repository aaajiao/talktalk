"""Engine-side watchdogs (§7.6): stdin EOF -> exit; orphaned (ppid 1) -> exit; SIGTERM -> exit <1 s.

All exits use os._exit so they work even when the GPU thread is stuck inside a Metal call.
"""
import os
import signal
import sys
import threading
import time


def _stdin_watch():
    try:
        while True:
            chunk = os.read(0, 4096)
            if not chunk:
                break
    except OSError:
        pass
    sys.stderr.write("engine: stdin closed, exiting\n")
    sys.stderr.flush()
    os._exit(0)


def _orphan_watch(interval):
    while True:
        time.sleep(interval)
        if os.getppid() == 1:
            sys.stderr.write("engine: parent gone, exiting\n")
            sys.stderr.flush()
            os._exit(0)


def _on_term(signum, frame):
    sys.stderr.write(f"engine: signal {signum}, exiting\n")
    sys.stderr.flush()
    os._exit(0)


def install(watch_stdin=True, orphan_interval=2.0):
    signal.signal(signal.SIGTERM, _on_term)
    signal.signal(signal.SIGHUP, _on_term)
    if watch_stdin:
        threading.Thread(target=_stdin_watch, name="stdin-watchdog", daemon=True).start()
    threading.Thread(target=_orphan_watch, args=(orphan_interval,), name="orphan-watchdog", daemon=True).start()
