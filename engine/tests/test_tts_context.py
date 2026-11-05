"""Bounded clause continuation through EngineState + real Guarded, without MLX or audio IO."""
import queue
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np

from talktalk_engine.main import EngineState
from talktalk_engine.scheduler import GpuScheduler
from talktalk_engine.tts import TTSModel
from talktalk_engine.voice import Voice


class FakeTTS(TTSModel):
    def __init__(self):
        super().__init__("model", "/unused", "rev")
        self.mx = SimpleNamespace(array=np.array, concatenate=np.concatenate, int32=np.int32,
                                  eval=lambda *args: None)
        self.tokenized = []
        self.model = SimpleNamespace(tokenizer=SimpleNamespace(encode=self.encode))
        self.voices = []
        self.plans = []

    def encode(self, text):
        self.tokenized.append(text)
        return [1, 2, 3, len(text), 4, 5]

    def stream(self, text, voice, language, *, stats, capture_codes, **kwargs):
        self.voices.append(voice)
        frames, eos, start = self.plans.pop(0) if self.plans else (10, True, 100 * len(self.voices))
        cb0 = list(range(start, start + frames))
        stats.update(frames=frames, eos=eos, runaway=not eos, cb0=cb0)
        if capture_codes and eos and frames:
            stats["generated_codes"] = np.broadcast_to(np.array(cb0, np.int32)[None, None, :],
                                                       (1, 16, frames)).copy()
        if frames:
            yield np.full(frames * 1920, 0.1, np.float32)


def make_state():
    s = EngineState(SimpleNamespace(horizon_ms=1000, asr_thread="shared"))
    s.sched = s.asr_sched = GpuScheduler()
    s.tts = FakeTTS()
    codes = np.broadcast_to(np.arange(10, dtype=np.int32)[None, None, :], (1, 16, 10)).copy()
    s.voice = Voice("human", "Human reference.", codes, np.array([[7]], np.int32), np.ones((1, 4)))
    s.voice_state = "ready"
    return s


def request(s, job, previous=None, context="turn", **overrides):
    req = dict(job=job, text="A clear phrase.", lang="en", voice_key=s.voice.key,
               context_id=context, previous_job=previous, seed=42, max_attempts=1)
    req.update(overrides)
    out = queue.Queue()
    return s.tts_job(req, out), out


def drain(s, pair, finish=True):
    job, out = pair
    job.gen = job.factory()
    for item in job.gen:
        if item is not None:
            job.on_item(item)
    # Match _retire's ordering; cancellation must still find this job before on_done.
    s.sched.jobs.remove(job)
    if not finish:
        return None
    job.on_done(None)
    return [payload for kind, payload in list(out.queue) if kind == "tail"][0]


class TTSContextTests(unittest.TestCase):
    def test_matching_previous_uses_human_plus_only_one_clause_and_combined_echo_reference(self):
        s = make_state()
        human = s.voice
        self.assertFalse(drain(s, request(s, "one"))["context_used"])
        first = s.tts_context["codes"].copy()
        self.assertTrue(drain(s, request(s, "two", "one"))["context_used"])
        used = s.tts.voices[-1]
        np.testing.assert_array_equal(used.ref_codes, np.concatenate([human.ref_codes, first], axis=2))
        self.assertIs(used.speaker_embed, human.speaker_embed)
        self.assertEqual(s.tts.tokenized,
                         ["<|im_start|>assistant\nHuman reference. A clear phrase.<|im_end|>\n"])
        second = s.tts_context["codes"].copy()
        self.assertTrue(drain(s, request(s, "three", "two"))["context_used"])
        np.testing.assert_array_equal(s.tts.voices[-1].ref_codes,
                                      np.concatenate([human.ref_codes, second], axis=2))
        self.assertEqual(s.voice.ref_codes.shape[2], 10)
        self.assertEqual(s.tts_context["codes"].shape[2], 10)

        # Repeating the previous generated CB0 must be checked against the combined reference,
        # even though the temporary voice retains the same key as the human memo.
        prior = s.tts_context["codes"][0, 0, 0]
        s.tts.plans = [(10, True, int(prior))]
        tail = drain(s, request(s, "echo", "three"))
        self.assertTrue(tail["context_used"])
        self.assertEqual(tail["echo_aborts"], 1)
        self.assertIsNone(s.tts_context)

    def test_missing_or_mismatched_context_is_fresh_and_no_context_does_not_promote(self):
        for field, value in (("context_id", "other"), ("previous_job", "missing"),
                             ("lang", "de"), ("previous_job", None)):
            with self.subTest(field=field, value=value):
                s = make_state()
                drain(s, request(s, "one"))
                tail = drain(s, request(s, "two", "one", **{field: value}))
                self.assertFalse(tail["context_used"])
                self.assertIs(s.tts.voices[-1], s.voice)
        s = make_state()
        drain(s, request(s, "one"))
        cached = s.tts_context
        self.assertFalse(drain(s, request(s, "audition", "one", context=None))["context_used"])
        self.assertIs(s.tts_context, cached)
        s.voice_gen += 1
        self.assertFalse(drain(s, request(s, "new-generation", "one"))["context_used"])

    def test_only_successful_complete_first_attempt_within_both_limits_is_retained(self):
        cases = [([(0, True, 100)], {}), ([(1, True, 100)], {}),
                 ([(10, False, 100)], {}), ([(101, True, 100)], {"text": "word " * 30}),
                 ([(10, True, 100)], {"text": "x" * 513}),
                 ([(1, True, 100), (10, True, 200)], {"max_attempts": 2})]
        for plans, options in cases:
            with self.subTest(plans=plans, options=options):
                s = make_state()
                s.tts.plans = plans.copy()
                drain(s, request(s, "one", **options))
                self.assertIsNone(s.tts_context)

    def test_cancel_handoff_and_voice_lifecycle_fence_old_completion(self):
        s = make_state()
        old = request(s, "old")
        drain(s, old, finish=False)
        s.cancel(job_id="old")  # already removed from scheduler, on_done still pending
        old[0].on_done(None)
        self.assertIsNone(s.tts_context)
        self.assertTrue([v for k, v in old[1].queue if k == "tail"][0]["cancelled"])

        drain(s, request(s, "new", context="new-turn"))
        new = s.tts_context
        old[0].on_done("cancelled")
        s.cancel(job_id="old")
        self.assertIs(s.tts_context, new)
        s.cancel(scope="listen")
        self.assertIs(s.tts_context, new)
        s.cancel(job_id="new")  # a completed cached job is no longer in the scheduler
        self.assertIsNone(s.tts_context)

        s = make_state()
        drain(s, request(s, "one"))
        build = s.tts.continuation_voice
        def cancel_during_build(*args):
            result = build(*args)
            s.cancel(job_id="one")
            return result
        with patch.object(s.tts, "continuation_voice", side_effect=cancel_during_build):
            self.assertFalse(drain(s, request(s, "two", "one"))["context_used"])
        self.assertIs(s.tts.voices[-1], s.voice)

        s = make_state()
        drain(s, request(s, "one"))
        failed = request(s, "two", "one")
        failed[0].on_done(RuntimeError("failed"))
        self.assertIsNone(s.tts_context)

        for operation in ("speak", "all", "unload", "load", "build"):
            with self.subTest(operation=operation):
                s = make_state()
                drain(s, request(s, "one"))
                pending = request(s, "pending", "one")
                drain(s, pending, finish=False)
                s.sched.call = lambda fn, **kwargs: fn()
                if operation in ("speak", "all"):
                    s.cancel(scope=operation)
                elif operation == "unload":
                    s.unload_voice()
                elif operation == "load":
                    with patch("talktalk_engine.voice.from_blob", return_value=s.voice):
                        s.load_voice(b"fake")
                else:
                    with patch.object(s.tts, "build_voice", return_value=(s.voice, {})), \
                         patch("talktalk_engine.voice.to_blob", return_value=b"fake"):
                        s.build_voice(np.zeros(1, np.float32), "Human reference.")
                self.assertIsNone(s.tts_context)
                pending[0].on_done(None)
                self.assertIsNone(s.tts_context)


if __name__ == "__main__":
    unittest.main()
