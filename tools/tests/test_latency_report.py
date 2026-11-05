"""tools/latency_report.py against synthetic event logs with hand-computed results.

Run: python3 -I -B -m unittest discover -s tools/tests -t tools
"""
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import latency_report as lr  # noqa: E402

BASE = 10 ** 12   # host ns: an arbitrary uptime
MS = lr.MS


def ev(t_ms, name, **fields):
    e = {"t": BASE + int(t_ms * MS), "ev": name}
    e.update(fields)
    return e


def m1_log():
    """One en LISTEN run with a cloud primary. Hand-computed values in TestM1."""
    return [
        ev(0, "meeting.start"),
        ev(10, "listen.start", lang="en", primary=True, apple=True),
        # 1: first word 1000, trigger 4000, closed 4200; draft shown 1900; openai final 5000 (1000 ms).
        ev(1900, "mt.draft", sentence=1, ms=300),
        ev(3000, "mt.draft", sentence=1, ms=250),
        ev(4000, "listen.finalize", sentence=1, trigger="punctPause"),
        ev(4200, "listen.sentence", sentence=1, trigger="punctPause", words=12, final_timeout=False,
           trigger_to_final_ms=200, first_word_to_trigger_ms=3000),
        ev(5000, "mt.final", sentence=1, engine="openai", approx=False, trigger_to_text_ms=1000,
           number_warning=False, met_deadline=True, chars=20),
        ev(5100, "listen.revise", sentence=1, erased=4),
        # 2: first word 6000, last word 8500, trigger 9000; draft only after close; openai late (2500 ms).
        ev(9000, "listen.sentence", sentence=2, trigger="silence", words=8, final_timeout=False,
           trigger_to_final_ms=0, first_word_to_trigger_ms=3000, last_word_to_trigger_ms=500),
        ev(9500, "mt.draft", sentence=2, ms=400),
        ev(11500, "mt.final", sentence=2, engine="openai", approx=False, trigger_to_text_ms=2500,
           number_warning=False, met_deadline=False, chars=10),
        # 3: first word 12000, trigger 13000; listen.draft_shown wins over mt.draft; Apple final.
        ev(12400, "mt.draft", sentence=3, ms=200),
        ev(12600, "listen.draft_shown", sentence=3),
        ev(13100, "listen.sentence", sentence=3, trigger="asrFinal", words=4, final_timeout=False,
           trigger_to_final_ms=100, first_word_to_trigger_ms=1000),
        ev(14000, "mt.final", sentence=3, engine="apple", approx=True, trigger_to_text_ms=1000,
           number_warning=False, met_deadline=True, chars=8),
        # 4: echo of our own TTS: left out.
        ev(16000, "listen.sentence", sentence=4, trigger="silence", words=3, final_timeout=False,
           trigger_to_final_ms=0, first_word_to_trigger_ms=900),
        ev(16000, "listen.echo_drop", sentence=4, reason="text", overlap=0.9),
        # 5: spans a sleep: left out.
        ev(20500, "sys.sleep"),
        ev(20600, "sys.wake"),
        ev(21000, "listen.sentence", sentence=5, trigger="silence", words=5, final_timeout=False,
           trigger_to_final_ms=0, first_word_to_trigger_ms=800),
        ev(22000, "mt.final", sentence=5, engine="openai", approx=False, trigger_to_text_ms=1000,
           number_warning=False, met_deadline=True, chars=9),
        ev(23000, "listen.stop", sentences=5, revisions=7),
    ]


def m2_log():
    """Four presses. Hand-computed values in TestM2."""
    return [
        # press 1: hold 2.5 s; disclosure 3600..5100 excluded; clause 1 src_t0 1150, clause 2 approx.
        ev(1000, "key.down"),
        ev(1100, "mic.onset"),
        ev(2000, "seg.commit", clause=1, src_t0=BASE + 1150 * MS),
        ev(3000, "seg.commit", clause=2),
        ev(3500, "key.up"),
        ev(3600, "out.first_audible", disclosure=True, dur_ms=1500),
        ev(4000, "out.underrun"),                  # inside the disclosure: excluded
        ev(5600, "out.first_audible", clause=1),
        ev(6000, "out.underrun"),                  # counted
        ev(7000, "out.first_audible", clause=2),
        # press 2: hold 9 s (over 8 s); passthrough yield+open 19200..20000 excluded.
        ev(10000, "key.down"),
        ev(18000, "seg.commit", clause=3, src_t0=BASE + 10100 * MS),
        ev(19000, "key.up"),
        ev(19500, "pt.open", waitMs=300),
        ev(20000, "pt.close", reason="keyUp", heldMs=500),
        ev(21000, "out.first_audible", clause=3),
        # press 3: chord cancel. press 4: no output.
        ev(30000, "key.down"),
        ev(30200, "key.chordCancel"),
        ev(30300, "key.up"),
        ev(40000, "key.down"),
        ev(41000, "key.up"),
    ]


class Tmp(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)

    def write(self, name, events):
        p = os.path.join(self.dir.name, name)
        with open(p, "w", encoding="utf-8") as f:
            for e in events:
                f.write(json.dumps(e) + "\n")
        return p

    def profile(self, deadline_ms=2000, max_cps=9):
        p = os.path.join(self.dir.name, "profile.json")
        with open(p, "w", encoding="utf-8") as f:
            json.dump({"listen": {"finalMT": {"deadlineMs": deadline_ms}, "display": {"lines": 2, "maxCps": max_cps}}}, f)
        return p


class TestHelpers(unittest.TestCase):
    def test_percentile_linear(self):
        self.assertIsNone(lr.percentile([], 50))
        self.assertEqual(lr.percentile([3.0], 90), 3.0)
        self.assertAlmostEqual(lr.percentile([1, 2, 3, 4], 50), 2.5)
        self.assertAlmostEqual(lr.percentile([0.6, 0.9, 5.5], 90), 4.58)

    def test_overlap_merges_intervals(self):
        iv = [(0, 10), (5, 15), (20, 30)]
        self.assertEqual(lr.overlap_ns(iv, 0, 100), 25)
        self.assertEqual(lr.overlap_ns(iv, 12, 22), 5)
        self.assertEqual(lr.overlap_ns(iv, 15, 20), 0)
        self.assertEqual(lr.overlap_ns([], 0, 5), 0)

    def test_yaal_formula(self):
        r = {"s0": 0, "s1": 3000 * MS, "T": 4000 * MS, "chars": 20}
        self.assertAlmostEqual(lr.yaal(r), 4.0 - 3.0 * 19 / 40)
        r["chars"] = None   # Y → ∞
        self.assertAlmostEqual(lr.yaal(r), 2.5)
        r["chars"] = 1      # one token: ideal delay 0
        self.assertAlmostEqual(lr.yaal(r), 4.0)
        r["s0"] = None
        self.assertIsNone(lr.yaal(r))

    def test_repo_profile_deadline_is_read_not_hardcoded(self):
        with open(lr.DEFAULT_PROFILE, encoding="utf-8") as f:
            raw = json.load(f)
        p = lr.load_profile(lr.DEFAULT_PROFILE)
        self.assertEqual(p["deadline_ms"], raw["listen"]["finalMT"]["deadlineMs"])
        self.assertEqual(p["max_cps"], raw["listen"]["display"]["maxCps"])


class TestM1(Tmp):
    def report(self, **kw):
        return lr.build([self.write("s.jsonl", m1_log())], self.profile(**kw))["m1"]

    def test_counts_exclude_echo_and_sleep(self):
        self.assertEqual(self.report()["sentences"], 3)

    def test_first_draft(self):
        m = self.report()
        # s1: 1900 − 1000; s3: draft_shown 12600 − 12000; s2's draft finished after close.
        self.assertEqual(m["first_draft_s"]["n"], 2)
        self.assertAlmostEqual(m["first_draft_s"]["p50"], 0.75)
        # first text: s1 0.9, s2 final 11500 − 6000 = 5.5, s3 0.6
        self.assertAlmostEqual(m["first_text_s"]["p50"], 0.9)
        self.assertAlmostEqual(m["first_text_s"]["p90"], 4.58)

    def test_longyaal(self):
        st = self.report()["longyaal_s"]["en"]
        y1 = 4.0 - 3.0 * 19 / 40     # 2.575
        y2 = 5.5 - 2.5 * 9 / 20      # 4.375 (s1 = last word 8500)
        y3 = 2.0 - 1.0 * 7 / 16      # 1.5625
        self.assertEqual(st["n"], 3)
        self.assertAlmostEqual(st["mean"], (y1 + y2 + y3) / 3)
        self.assertAlmostEqual(st["p50"], y1)
        self.assertAlmostEqual(st["p90"], y1 + (y2 - y1) * 0.8)

    def test_ne_and_cps(self):
        m = self.report()
        self.assertAlmostEqual(m["ne"], 4 / 38.0)
        # finals at 5.0 s (20), 11.5 s (10), 14.0 s (8): the last 10 s window holds 38 chars.
        self.assertAlmostEqual(m["cps_max"], 3.8)

    def test_cps_window(self):
        m = lr.build([self.write("s.jsonl", m1_log())], self.profile(), cps_window_s=2.0)["m1"]
        # 2 s windows: 20/2, 10/2, 8/2 → 10.0 (over maxCps 9)
        self.assertAlmostEqual(m["cps_max"], 10.0)
        v = dict((n, ok) for n, _, ok in lr.m1_verdicts(m))
        self.assertFalse(v["chars/s ≤ 9"])

    def test_deadline_share_follows_profile(self):
        d = self.report()["deadline"]
        self.assertEqual((d["n"], d["met"]), (3, 1))          # s2 is 2500 ms, s3 is Apple
        self.assertAlmostEqual(d["share"], 1 / 3.0)
        self.assertEqual(d["engines"], {"apple": 1, "openai": 2})
        d = self.report(deadline_ms=3000)["deadline"]
        self.assertEqual(d["met"], 2)
        d = lr.build([self.write("s.jsonl", m1_log())], self.profile(), deadline_ms=900)["m1"]["deadline"]
        self.assertEqual(d["met"], 0)

    def test_verdicts(self):
        v = dict((n, ok) for n, _, ok in lr.m1_verdicts(self.report()))
        self.assertTrue(v["first draft p50 ≤ 1.2 s"])
        self.assertTrue(v["LongYAAL en ≤ 3.0 s"])
        self.assertFalse(v["LongYAAL en p90 ≤ 4.0 s"])
        self.assertTrue(v["NE ≤ 0.2"])
        self.assertFalse(v["OpenAI final within 2000 ms ≥ 95%"])

    def test_no_primary_means_no_deadline_share(self):
        log = [dict(e, primary=False) if e["ev"] == "listen.start" else e for e in m1_log()]
        m = lr.build([self.write("s.jsonl", log)], self.profile())["m1"]
        self.assertIsNone(m["deadline"]["share"])
        v = dict((n, ok) for n, _, ok in lr.m1_verdicts(m))
        self.assertIsNone(v["OpenAI final within 2000 ms ≥ 95%"])

    def test_missing_chars(self):
        log = [ev(0, "listen.start", lang="de", primary=True),
               ev(2000, "listen.sentence", sentence=1, trigger_to_final_ms=0, first_word_to_trigger_ms=2000),
               ev(3000, "mt.final", sentence=1, engine="openai", trigger_to_text_ms=1000),
               ev(4000, "listen.stop")]
        m = lr.build([self.write("s.jsonl", log)], self.profile())["m1"]
        self.assertAlmostEqual(m["longyaal_s"]["de"]["mean"], 3.0 - 2.0 / 2)
        self.assertIsNone(m["cps_max"])
        self.assertEqual(m["ne"], 0.0)
        self.assertTrue(m["notes"])
        v = dict((n, ok) for n, _, ok in lr.m1_verdicts(m))
        self.assertTrue(v["LongYAAL de ≤ 3.5 s"])

    def test_sentence_ids_restart_per_run(self):
        run = [ev(0, "listen.start", lang="en", primary=True),
               ev(2000, "listen.sentence", sentence=1, trigger_to_final_ms=0, first_word_to_trigger_ms=1000),
               ev(2500, "mt.final", sentence=1, engine="openai", trigger_to_text_ms=500, chars=5),
               ev(3000, "listen.stop")]
        second = [dict(e, t=e["t"] + 10_000 * MS) for e in run]
        m = lr.build([self.write("s.jsonl", run + second)], self.profile())["m1"]
        self.assertEqual(m["sentences"], 2)
        self.assertEqual(m["deadline"]["met"], 2)

    def test_files_and_directories_pool(self):
        self.write("a.jsonl", m1_log())
        self.write("b.jsonl", m1_log())
        rep = lr.build([self.dir.name], self.profile())
        self.assertEqual(rep["files"], 2)
        self.assertEqual(rep["m1"]["sentences"], 6)


class TestM2(Tmp):
    def report(self):
        return lr.build([self.write("s.jsonl", m2_log())], self.profile())["m2"]

    def test_release_to_first_sound(self):
        m = self.report()
        # press 1: 5600 − 3500 − 1500 disclosure = 0.6 s; press 2: 21000 − 19000 − 800 pt = 1.2 s
        self.assertEqual(m["release_s"]["n"], 2)
        self.assertAlmostEqual(m["release_s"]["p50"], 0.9)
        self.assertAlmostEqual(m["release_s"]["p90"], 1.14)
        self.assertEqual(m["release_short_s"]["n"], 1)      # press 2 held 9 s
        self.assertAlmostEqual(m["release_short_s"]["p50"], 0.6)
        self.assertEqual((m["presses"], m["with_output"]), (4, 2))
        self.assertAlmostEqual(m["excluded_s"], 2.3)

    def test_evs(self):
        m = self.report()
        # clause 1: 5600 − 1150 − 1500 = 2.95; clause 2 (approx, previous commit 2000): 7000 − 2000 − 1500
        # = 3.5; clause 3: 21000 − 10100 − 800 = 10.1
        self.assertEqual(m["evs_s"]["n"], 3)
        self.assertEqual(m["evs_approx"], 1)
        self.assertAlmostEqual(m["evs_s"]["p50"], 3.5)
        self.assertAlmostEqual(m["evs_s"]["mean"], (2.95 + 3.5 + 10.1) / 3)

    def test_underruns(self):
        m = self.report()
        self.assertEqual(m["underruns"], 1)
        self.assertAlmostEqual(m["underrun_rate"], 0.5)
        v = dict((n, ok) for n, _, ok in lr.m2_verdicts(m))
        self.assertFalse(v["underruns = 0"])
        self.assertTrue(v["release → first sound p50 ≤ 2.0 s (≤ 8 s presses)"])

    def test_no_presses(self):
        m = lr.build([self.write("s.jsonl", m1_log())], self.profile())["m2"]
        self.assertEqual(m["presses"], 0)
        self.assertTrue(all(ok is None for _, _, ok in lr.m2_verdicts(m)))


class TestCLI(Tmp):
    def run_main(self, args):
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = lr.main(args)
        return rc, buf.getvalue()

    def test_text_and_json(self):
        p = self.write("s.jsonl", m1_log() + [dict(e, t=e["t"] + 100_000 * MS) for e in m2_log()])
        rc, out = self.run_main([p, "--profile", self.profile()])
        self.assertEqual(rc, 0)
        self.assertIn("deadline 2000 ms from PolicyProfile", out)
        self.assertIn("MISS underruns = 0", out)
        rc, out = self.run_main([p, "--profile", self.profile(), "--json"])
        self.assertEqual(rc, 0)
        j = json.loads(out)
        self.assertEqual(j["m1"]["sentences"], 3)
        self.assertEqual(j["m2"]["underruns"], 1)
        rc, _ = self.run_main([p, "--profile", self.profile(), "--check"])
        self.assertEqual(rc, 1)

    def test_errors_exit_2(self):
        import contextlib
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(lr.main([os.path.join(self.dir.name, "missing.jsonl")]), 2)
            bad = os.path.join(self.dir.name, "bad.jsonl")
            with open(bad, "w") as f:
                f.write("{not json\n")
            self.assertEqual(lr.main([bad, "--profile", self.profile()]), 2)
            self.assertEqual(lr.main(["--bogus"]), 2)

    def test_output_has_no_text_fields(self):
        # Even if a log line carried a text field by mistake, the report never prints it.
        log = m1_log()
        log[5] = dict(log[5], text="SECRET-SENTENCE")
        rc, out = self.run_main([self.write("s.jsonl", log), "--profile", self.profile(), "--json"])
        self.assertEqual(rc, 0)
        self.assertNotIn("SECRET-SENTENCE", out)


if __name__ == "__main__":
    unittest.main()
