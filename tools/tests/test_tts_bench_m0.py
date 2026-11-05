"""tools/bench/tts_bench.py: the M0 runaway / short criteria recomputed per row (m0_flags), so M0,
raw and guarded result files are judged alike (78c5753 / 00f65f3 reviews). Synthetic rows only.

Run: python3 -I -B -m unittest discover -s tools/tests -t tools
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bench"))
import tts_bench as tb  # noqa: E402


def row(audio_s, expected_s=1.0, eos=True, **kw):
    r = {"audio_s": audio_s, "expected_s": expected_s, "eos": eos, "runaway": False, "short": False}
    r.update(kw)
    return r


class M0FlagsTests(unittest.TestCase):
    def test_m0_cap(self):
        self.assertEqual(tb.m0_cap_frames(1.0), 62)                    # int(12.5 x (3 + 2))
        self.assertEqual(tb.m0_cap_frames(2.0), 100)
        self.assertEqual(tb.m0_cap_frames(2.4), 114)                   # int() truncates, as M0 did

    def test_short_counts_in_raw_rows(self):
        # raw mode (Policy.raw, short_factor 0) never flags short itself; the M0 rule still does
        self.assertEqual(tb.m0_flags(row(0.3, guards=False)), (False, True))
        self.assertEqual(tb.m0_flags(row(0.36, guards=False)), (False, False))

    def test_runaway_is_reaching_the_m0_cap(self):
        self.assertEqual(tb.m0_flags(row(5.0, eos=False, guards=False, frames=62)), (True, False))
        self.assertEqual(tb.m0_flags(row(4.96, eos=False, guards=False)), (True, False))   # frames from audio: 62
        # stopped by the stream's own (token) cap below the M0 cap: not an M0 runaway, counted apart
        early = row(2.0, eos=False, guards=False, frames=25)
        self.assertEqual(tb.m0_flags(early), (False, False))
        self.assertTrue(tb.capped_early(early))
        self.assertFalse(tb.capped_early(row(2.0, frames=25)))         # EOS: a normal ending

    def test_guarded_failure_is_a_runaway(self):
        self.assertEqual(tb.m0_flags(row(0.0, guards=True, runaway=True)), (True, True))
        # a raw row's runaway field means nothing (always False there); an M0 row is judged by frames
        self.assertEqual(tb.m0_flags(row(0.9, runaway=True)), (False, False))

    def test_modes(self):
        self.assertEqual([tb.row_mode(r) for r in (row(1, guards=False), row(1, guards=True), row(1))],
                         ["raw", "guards", "m0"])


if __name__ == "__main__":
    unittest.main()
