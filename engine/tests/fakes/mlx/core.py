"""Fake mlx.core: numpy-backed, enough for main.py / voice.py in the engine process tests."""
import numpy as np

__version__ = "0.0.0-fake"
int32 = np.int32
float32 = np.float32
_peak = 0


def array(x, dtype=None):
    return np.asarray(x, dtype=dtype)


def eval(*args):  # noqa: A001
    return None


def set_cache_limit(n):
    return 0


def clear_cache():
    return None


def set_wired_limit(n):
    return 0


def get_active_memory():
    return 123_000_000


def get_cache_memory():
    return 0


def get_peak_memory():
    return 456_000_000
