"""Voice load/unload order (voice-m2, review round 2 item 4): a /v1/voice/load the app gave up on
can still be waiting in `sched.call` (READY's ASR background load holds the shared GPU thread for
seconds). An unload that arrives meanwhile must win: when the load finishes, the voice stays
absent. EngineState with a stub scheduler whose call() blocks until the test releases it."""
import sys
import queue
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from talktalk_engine.main import EngineState  # noqa: E402
from talktalk_engine.server import ApiError  # noqa: E402


class BlockingSched:
    """call() runs the function only after `release`; submit() records jobs."""

    def __init__(self):
        self.entered = threading.Semaphore(0)
        self.release = threading.Event()
        self.jobs = []

    def call(self, fn, long_step=False, timeout=None):
        self.entered.release()
        assert self.release.wait(5), "test never released the GPU thread"
        return object()                  # stands in for the decoded voice

    def submit(self, job):
        self.jobs.append(job)
        return job


def state():
    s = EngineState(SimpleNamespace(horizon_ms=1000.0, asr_thread="shared"))
    s.sched = s.asr_sched = BlockingSched()
    return s


class VoiceLoadUnloadOrderTests(unittest.TestCase):
    def identity_state(self):
        s = state()
        s.sched.call = lambda fn, **kwargs: fn()
        s.tts = SimpleNamespace(key="model-A")
        s.voice = SimpleNamespace(key="voice-A", ref_codes=None)
        s.voice_state = "ready"
        return s

    def test_load_checks_expected_voice_and_model_before_replacing_slot(self):
        s = self.identity_state()
        old = s.voice
        with patch("talktalk_engine.voice.from_blob", return_value=SimpleNamespace(key="voice-B")):
            with self.assertRaises(ApiError) as failed:
                s.load_voice(b"blob", expected_key="voice-A", model="model-A")
            self.assertEqual(failed.exception.code, "voice_key_mismatch")
            self.assertIs(s.voice, old)
            with self.assertRaises(ApiError) as failed:
                s.load_voice(b"blob", expected_key="voice-B", model="model-B")
            self.assertEqual(failed.exception.code, "voice_model_mismatch")
            self.assertEqual(s.sched.jobs, [])
            self.assertTrue(s.load_voice(b"blob", expected_key="voice-B", model="model-A"))
            self.assertEqual(s.voice.key, "voice-B")
            self.assertEqual(s.voice_state, "loading")
            s.sched.jobs[-1].on_done(None)
            self.assertEqual(s.voice_state, "ready")

    def test_tts_requires_matching_ready_voice_and_rechecks_queued_jobs(self):
        s = self.identity_state()
        request = {"text": "A short test sentence.", "lang": "en", "voice_key": "voice-B"}
        with self.assertRaises(ApiError) as failed:
            s.tts_job(request, queue.Queue())
        self.assertEqual(failed.exception.code, "voice_key_mismatch")
        request["voice_key"] = "voice-A"
        s.voice_state = "loading"
        with self.assertRaises(ApiError) as failed:
            s.tts_job(request, queue.Queue())
        self.assertEqual(failed.exception.code, "voice_not_ready")
        self.assertEqual(s.sched.jobs, [])
        s.voice_state = "ready"
        job = s.tts_job(request, queue.Queue())
        ready = job.factory()  # Valid matching request can begin; no GPU iteration is needed.
        ready.close()
        s.unload_voice()
        with self.assertRaises(ApiError) as failed:
            job.factory()
        self.assertEqual(failed.exception.code, "voice_changed")

    def load_in_background(self, s):
        out = {}
        t = threading.Thread(target=lambda: out.setdefault("ok", s.load_voice(b"blob")))
        t.start()
        self.assertTrue(s.sched.entered.acquire(timeout=2))   # the load is now stuck in sched.call
        return t, out

    def test_unload_while_load_is_blocked_wins(self):
        s = state()
        t, out = self.load_in_background(s)
        s.unload_voice()
        self.assertEqual(s.voice_state, "absent")
        s.sched.release.set()                                   # the stale load completes
        t.join(2)
        self.assertFalse(out["ok"])
        self.assertIsNone(s.voice)
        self.assertEqual(s.voice_state, "absent")
        self.assertEqual(s.sched.jobs, [])                     # no warmup for a voice nobody has

    def test_load_without_unload_applies(self):
        s = state()
        s.sched.release.set()
        self.assertTrue(s.load_voice(b"blob"))
        self.assertIsNotNone(s.voice)
        self.assertEqual(s.voice_state, "loading")
        self.assertEqual([j.kind for j in s.sched.jobs], ["voice_warmup"])

    def test_newer_load_wins_over_an_older_one(self):
        s = state()
        t, out = self.load_in_background(s)                     # older load, blocked
        t2, out2 = self.load_in_background(s)                   # newer load, blocked
        s.sched.release.set()
        t.join(2)
        t2.join(2)
        self.assertEqual(sorted([out["ok"], out2["ok"]]), [False, True])
        self.assertTrue(out2["ok"])
        self.assertEqual(s.voice_state, "loading")

    def test_warmup_of_an_unloaded_voice_does_not_set_the_state(self):
        s = state()
        s.sched.release.set()
        s.load_voice(b"blob")
        warm = s.sched.jobs[0]
        s.unload_voice()
        warm.on_done(RuntimeError("warmup failed"))              # was: state "failed" after unload
        self.assertEqual(s.voice_state, "absent")
        warm.on_done(None)
        self.assertEqual(s.voice_state, "absent")


if __name__ == "__main__":
    unittest.main()
