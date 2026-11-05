#!/usr/bin/env python3
"""talktalk-engine entry point (ARCHITECTURE.md §4.4, §7.6).

Started by the app (or a bench) as:
  <engine>/venv/bin/python3 -I -B talktalk_engine.py --models-dir <dir> --roles tts,asr \
      --tts <model key> --asr <model key> [--warmup-dir <dir>]

fd 1 is the handshake pipe. The very first thing we do is keep a private copy of it and point
fd 1 at stderr, so any library print() (mlx-audio prints on every ICL generation) lands in the
engine log instead of filling a pipe nobody reads and stalling the single GPU thread.
"""
import os
import sys

_HANDSHAKE_FD = os.dup(1)
os.dup2(2, 1)
sys.stdout.reconfigure(line_buffering=True)   # library prints reach the log promptly, in order

# -I drops the script directory from sys.path; add our own package directory explicitly.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from talktalk_engine import main  # noqa: E402  (must follow the fd swap)

if __name__ == "__main__":
    sys.exit(main.run(_HANDSHAKE_FD, sys.argv[1:]))
