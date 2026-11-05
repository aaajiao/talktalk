"""Handshake lines on the private fd (§4.4): PROGRESS {...}, then READY {...} or FATAL {...}."""
import json
import os
import threading

_lock = threading.Lock()
_fd = None
_done = False


def init(fd):
    global _fd
    _fd = fd


def _write(kind, obj):
    global _done
    with _lock:
        if _fd is None or _done:
            return
        line = kind + " " + json.dumps(obj, separators=(",", ":"), ensure_ascii=True) + "\n"
        os.write(_fd, line.encode("ascii"))
        if kind in ("READY", "FATAL"):
            _done = True
            os.close(_fd)


def progress(step, done, count):
    _write("PROGRESS", {"step": step, "done": done, "count": count})


def ready(info):
    _write("READY", info)


def fatal(message):
    _write("FATAL", {"message": str(message)[:500]})
