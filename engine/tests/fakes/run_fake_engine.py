#!/usr/bin/env python3
"""Runs the real engine entry (talktalk_engine.py) with fake mlx / mlx_audio / models.
Test-only; the production entry never loads anything from tests/."""
import os
import runpy
import sys

here = os.path.dirname(os.path.abspath(__file__))
engine_dir = os.path.dirname(os.path.dirname(here))
sys.path.insert(0, engine_dir)
sys.path.insert(0, here)

import fake_models  # noqa: E402  (imports the real talktalk_engine package, not mlx)

fake_models.install()
runpy.run_path(os.path.join(engine_dir, "talktalk_engine.py"), run_name="__main__")
