"""GpuScheduler rules (§6.1), driven through _pick with synthetic jobs (no GPU, no MLX)."""
import threading
import time
import unittest

from talktalk_engine.scheduler import (DEFAULT_FIRST_COST_MS, P0, P1, P2, P3, GpuScheduler, Job, _now_ms,
                                       step_class)


def job(kind, prio, deadline=None):
    return Job(kind, prio, lambda: iter(()), deadline_ms=deadline)


class PickTests(unittest.TestCase):
    def setUp(self):
        self.s = GpuScheduler(horizon_ms=1500)

    def test_no_playout_report_runs_tts_first_by_deadline(self):
        t = job("tts", P0)
        a = job("asr", P1, deadline=_now_ms() + 10_000)
        self.s.jobs = [a, t]
        self.assertIs(self.s._pick(_now_ms()), t)

    def test_rule0_horizon_holds_tts(self):
        t = job("tts", P0)
        bg = job("bg", P3, deadline=_now_ms() + 60_000)
        self.s.jobs = [t, bg]
        self.s.report_playout(2000)
        self.assertIs(self.s._pick(_now_ms()), bg)

    def test_parked_tts_keeps_decoder_but_allows_asr(self):
        t = job("tts", P0)
        t.gen = (None for _ in range(2))
        next(t.gen)                              # decoder state exists across the next yield
        warm = job("voice_warmup", P3, deadline=float("inf"))
        asr = job("asr", P1, deadline=_now_ms() - 1000)
        self.s.jobs = [t, warm, asr]
        self.s.report_playout(2000)
        self.assertIs(self.s._pick(_now_ms()), asr)
        self.s._retire(asr)
        self.assertIsNone(self.s._pick(_now_ms()))  # warmup cannot reset the parked TTS decoder
        self.assertEqual(self.s.health()["parked"], 2)
        self.s.report_playout(0)
        self.assertIs(self.s._pick(_now_ms()), t)
        self.assertEqual(self.s.health()["parked"], 1)  # active owner is never hidden as a waiter
        self.s._retire(t)
        self.assertIs(self.s._pick(_now_ms()), warm)
        self.assertEqual(self.s.health()["parked"], 0)

    def test_started_warmup_owns_decoder_until_cancelled_generator_closes(self):
        trace = []

        def warm_frames():
            trace.append("started")
            try:
                yield None
                yield None
            finally:
                trace.append("closed")

        warm = Job("voice_warmup", P3, warm_frames, deadline_ms=float("inf"))
        warm.gen = warm.factory()
        next(warm.gen)
        t = job("tts", P0)
        listen = job("asr", P2, deadline=_now_ms() + 10_000)
        self.s.jobs = [warm, t, listen]
        self.s.report_playout(0)
        self.assertIs(self.s._pick(_now_ms()), warm)  # low-buffer P0 cannot reset warmup's decoder
        self.assertEqual(self.s.health()["parked"], 2)  # P0 waits; P2 still sees queued P0
        self.assertEqual(trace, ["started"])
        warm.cancel()
        self.assertIs(self.s._pick(_now_ms()), warm)
        self.s._retire(warm, err="cancelled")
        self.assertEqual(trace, ["started", "closed"])
        self.assertIs(self.s._pick(_now_ms()), t)

    def test_rule1_low_buffer_tts_wins(self):
        t = job("tts", P0)
        a = job("asr", P1, deadline=_now_ms() - 1000)
        self.s.jobs = [a, t]
        self.s.report_playout(100)
        self.assertIs(self.s._pick(_now_ms()), t)

    def test_rule2_admission_blocks_expensive_step(self):
        t = job("tts", P0)
        a = job("asr", P1, deadline=_now_ms() - 1000)
        self.s.cost_ms("asr.first")
        for _ in range(10):
            self.s.step_cost["asr.first"].add(400.0)
        self.s.jobs = [t, a]
        self.s.report_playout(500)        # 500 < 400 + 150 -> ASR not admitted
        self.assertIs(self.s._pick(_now_ms()), t)
        self.s.report_playout(1400)       # 1400 >= 550 -> ASR (earlier deadline) admitted
        self.assertIs(self.s._pick(_now_ms()), a)

    def costs(self, cls, ms, n=10):
        self.s.cost_ms(cls)
        for _ in range(n):
            self.s.step_cost[cls].add(ms)

    def test_rule2_cost_is_per_step_class(self):
        """A started ASR job pays its decode-step p95, a fresh one its first-step (encode) p95."""
        t = job("tts", P0)
        fresh = job("asr", P1, deadline=_now_ms() - 1000)
        running = job("asr", P1, deadline=_now_ms() - 900)
        running.steps = 3
        self.assertEqual(step_class(fresh), "asr.first")
        self.assertEqual(step_class(running), "asr")
        self.costs("asr.first", 400.0)
        self.costs("asr", 10.0)
        self.s.jobs = [t, fresh]
        self.s.report_playout(500)        # 500 < 400 + 150: the encode step is not admitted
        self.assertIs(self.s._pick(_now_ms()), t)
        self.s.jobs = [t, running]
        self.s.report_playout(500)        # 500 >= 10 + 150: the decode step is
        self.assertIs(self.s._pick(_now_ms()), running)

    def test_rule2_unmeasured_first_step_uses_conservative_default(self):
        t = job("tts", P0)
        a = job("asr", P1, deadline=_now_ms() - 1000)
        self.s.jobs = [t, a]
        self.s.report_playout(DEFAULT_FIRST_COST_MS + 100)    # below 150 + 150
        self.assertIs(self.s._pick(_now_ms()), t)
        self.s.report_playout(DEFAULT_FIRST_COST_MS + 200)
        self.assertIs(self.s._pick(_now_ms()), a)

    def test_rule6_p2_paused_while_tts_queued(self):
        """SPEAK counts as active while any TTS job is queued, even one parked at the horizon."""
        t = job("tts", P0)
        p2 = job("asr", P2, deadline=_now_ms() + 10_000)
        self.s.jobs = [t, p2]
        self.s.report_playout(2000)       # TTS over the horizon: not runnable, but queued
        self.assertIsNone(self.s._pick(_now_ms()))
        self.s.jobs = [p2]
        self.assertIs(self.s._pick(_now_ms()), p2)

    def test_rule7_paused_p2_still_expires(self):
        p2 = job("asr", P2, deadline=_now_ms() - 1)
        self.s.jobs = [p2]
        self.s.set_session(True)
        self.assertIs(self.s._pick(_now_ms()), p2)
        self.assertTrue(p2.expired)
        self.assertEqual(self.s.expired_dropped, 1)

    def test_rule7_running_p2_dropped_before_next_step(self):
        p2 = job("asr", P2, deadline=_now_ms() - 1)
        p2.steps = 5
        self.s.jobs = [p2]
        self.assertIs(self.s._pick(_now_ms()), p2)
        self.assertTrue(p2.cancelled.is_set() and p2.expired)
        self.assertEqual(self.s.expired_dropped, 1)

    def test_rule7_p0_p1_p3_never_dropped_for_lateness(self):
        for prio in (P0, P1, P3):
            s = GpuScheduler()
            j = job("x", prio, deadline=_now_ms() - 10_000)
            j.steps = 2
            s.jobs = [j]
            self.assertIs(s._pick(_now_ms()), j)
            self.assertFalse(j.cancelled.is_set())
            self.assertEqual(s.expired_dropped, 0)

    def test_rule6_p2_paused_during_speak(self):
        p2 = job("asr", P2, deadline=_now_ms() + 10_000)
        self.s.jobs = [p2]
        self.s.set_session(True)
        self.assertIsNone(self.s._pick(_now_ms()))
        self.s.set_session(False)
        self.assertIs(self.s._pick(_now_ms()), p2)

    def test_rule7_expired_p2_dropped(self):
        p2 = job("asr", P2, deadline=_now_ms() - 1)
        self.s.jobs = [p2]
        self.assertIs(self.s._pick(_now_ms()), p2)
        self.assertTrue(p2.cancelled.is_set())
        self.assertEqual(self.s.expired_dropped, 1)

    def test_cancel_scopes(self):
        a, b, c = job("tts", P0), job("asr", P1), job("asr", P2)
        self.s.jobs = [a, b, c]
        self.assertEqual(self.s.cancel(scope="listen"), 1)
        self.assertTrue(c.cancelled.is_set())
        self.assertEqual(self.s.cancel(scope="speak"), 2)


class LoopTests(unittest.TestCase):
    def test_jobs_run_on_gpu_thread_and_call_works(self):
        s = GpuScheduler()
        s.start()
        seen, done = [], threading.Event()

        def gen():
            for i in range(3):
                seen.append(threading.get_ident())
                yield i

        items = []
        j = Job("bg", P3, gen, on_item=items.append, on_done=lambda e: done.set())
        s.submit(j)
        self.assertTrue(done.wait(2))
        self.assertEqual(items, [0, 1, 2])
        self.assertEqual(set(seen), {s.thread_ident})
        self.assertEqual(s.call(lambda: threading.get_ident()), s.thread_ident)
        self.assertIn("bg", s.stats())

    def test_expired_p2_finishes_with_expired_and_closes(self):
        s = GpuScheduler()
        s.set_session(True)               # paused, so it can only leave by expiring
        s.start()
        closed, done, errs = threading.Event(), threading.Event(), []

        def gen():
            try:
                while True:
                    yield None
            finally:
                closed.set()

        def on_done(e):
            errs.append(e)
            done.set()

        s.submit(Job("asr", P2, gen, deadline_ms=_now_ms() + 30, on_done=on_done))
        self.assertTrue(done.wait(2))
        self.assertEqual(errs, ["expired"])
        self.assertEqual(s.health()["expired_dropped"], 1)

    def test_health_reports_p99_per_step_class(self):
        s = GpuScheduler()
        s.start()
        done = threading.Event()

        def gen():
            for _ in range(4):
                time.sleep(0.002)
                yield None

        s.submit(Job("asr", P1, gen, on_done=lambda e: done.set()))
        self.assertTrue(done.wait(2))
        p99 = s.health()["step_p99"]
        self.assertEqual(set(p99), {"asr.first", "asr"})
        self.assertGreater(p99["asr"], 1.0)
        self.assertEqual(s.stats()["asr"]["n"], 3)
        self.assertEqual(s.stats()["asr.first"]["n"], 1)

    def test_health_counts_tts_parked_at_the_horizon(self):
        s = GpuScheduler(horizon_ms=1000)          # not started: nothing steps
        s.submit(Job("tts", P0, lambda: iter(())))
        s.submit(Job("asr", P2, lambda: iter(()), deadline_ms=_now_ms() + 60_000))
        self.assertEqual(s.health()["parked"], 1)  # no playout report: TTS never held back; P2 is (rule 6)
        s.report_playout(400)
        self.assertEqual(s.health()["parked"], 1)
        s.report_playout(1200)                     # at the horizon (paused playback keeps it there)
        h = s.health()
        self.assertEqual(h["parked"], 2)           # the TTS job, and the P2 held by rule 6 (TTS queued)
        self.assertEqual(sum(h["queue"].values()), 2)

    def test_health_counts_p2_held_by_rule_6(self):
        s = GpuScheduler()                         # not started
        self.assertEqual(s.horizon_ms, 1000.0)     # default = the M2 T2 pick
        s.submit(Job("asr", P2, lambda: iter(()), deadline_ms=_now_ms() + 60_000))
        s.submit(Job("asr", P1, lambda: iter(())))
        self.assertEqual(s.health()["parked"], 0)  # SPEAK idle: P2 may run
        s.set_session(True)
        self.assertEqual(s.health()["parked"], 1)  # rule 6 holds the P2; the P1 still counts as active
        s.set_session(False)
        self.assertEqual(s.health()["parked"], 0)

    def test_cancel_closes_generator(self):
        s = GpuScheduler()
        s.start()
        closed, done = threading.Event(), threading.Event()

        def gen():
            try:
                while True:
                    time.sleep(0.005)
                    yield None
            finally:
                closed.set()

        j = s.submit(Job("bg", P3, gen, on_done=lambda e: done.set()))
        time.sleep(0.05)
        j.cancel()
        self.assertTrue(done.wait(2))
        self.assertTrue(closed.is_set())


if __name__ == "__main__":
    unittest.main()
