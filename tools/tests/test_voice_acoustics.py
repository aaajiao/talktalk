"""tools/bench/voice_acoustics.py: the temperature-sweep rule and grouping on synthetic rows (no audio).

Run: python3 -I -B -m unittest discover -s tools/tests -t tools
"""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bench"))
import voice_acoustics as va  # noqa: E402


def row(t, i, spread, cosine, **kw):
    r = {"temperature": t, "id": f"c{i}", "lang": "en", "words": 10, "cosine": cosine, "runaway": False, "short": False,
         "attempts": 1, "echo_aborts": 0, "audio_s": 4.0, "f0_st_vs_ref": 0.2, "f0_spread_hz": spread, "s_per_word": 0.4}
    r.update(kw)
    return r


def sweep(base_spread=40.0, low_spread=30.0, base_cos=0.970, low_cos=0.980, low_extra=None):
    rows = [row(0.9, i, base_spread, base_cos) for i in range(5)]
    rows += [row(0.5, i, low_spread, low_cos, **(low_extra or {})) for i in range(5)]
    return rows


class SweepRows(unittest.TestCase):
    def test_last_row_wins_per_temperature_and_id(self):
        lines = [json.dumps({"temperature": 0.9, "id": "a", "wav": "x.wav", "cosine": 0.1}),
                 json.dumps({"temperature": 0.9, "id": "a", "wav": "x.wav", "cosine": 0.2}),   # same-day rerun, appended
                 json.dumps({"temperature": 0.5, "id": "a", "wav": "y.wav", "cosine": 0.3}),
                 json.dumps({"summary": True, "temperature": 0.9}),
                 json.dumps({"temperature": 0.7, "id": "b", "wav": None}),                     # no audio saved
                 "not json"]
        rows = va.sweep_rows(lines)
        self.assertEqual(sorted((r["temperature"], r["cosine"]) for r in rows), [(0.5, 0.3), (0.9, 0.2)])


class Rule(unittest.TestCase):
    def test_adopts_when_spread_and_cosine_move_enough(self):
        s = va.summarize(sweep())
        self.assertEqual(va.adopt(s, 0.9), 0.5)
        self.assertTrue(s[0.5]["passes_rule"])

    def test_spread_drop_below_twenty_percent_is_not_enough(self):
        s = va.summarize(sweep(low_spread=33.0))   # −17.5 %
        self.assertIsNone(va.adopt(s, 0.9))

    def test_cosine_gain_below_threshold_is_not_enough(self):
        s = va.summarize(sweep(low_cos=0.974))
        self.assertIsNone(va.adopt(s, 0.9))

    def test_guard_retries_echo_and_silence_block_adoption(self):
        for extra, key in (({"attempts": 2}, "retried"), ({"echo_aborts": 1}, "echo")):
            s = va.summarize(sweep(low_extra=extra))
            self.assertEqual(s[0.5][key], 5)
            self.assertIsNone(va.adopt(s, 0.9), key)
        rows = sweep()
        rows[-1].update(audio_s=0.0, f0_spread_hz=None, s_per_word=None)
        s = va.summarize(rows)
        self.assertEqual(s[0.5]["silent"], 1)
        self.assertIsNone(va.adopt(s, 0.9))

    def test_silent_clips_stay_out_of_the_pace_median(self):
        rows = [row(0.9, i, 40.0, 0.97) for i in range(3)]
        rows.append(row(0.9, 9, 40.0, 0.97, audio_s=0.0, s_per_word=0.0))
        self.assertEqual(va.summarize(rows)[0.9]["s_per_word"], 0.4)

    def test_runaway_blocks_adoption(self):
        s = va.summarize(sweep(low_extra={"runaway": True}))
        self.assertIsNone(va.adopt(s, 0.9))


if __name__ == "__main__":
    unittest.main()
