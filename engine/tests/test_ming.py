"""Ming adapter, voice isolation and cooperative cancellation without MLX/Metal."""
import queue
import sys
import time
import types
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np

from talktalk_engine.guards import Guarded, Policy, Progress
from talktalk_engine.main import EngineState
from talktalk_engine.ming import MODEL_KEY, VOICE_FORMAT, MingTTSModel, MingVoice, resample
from talktalk_engine.scheduler import GpuScheduler, Job, P0, P1
from talktalk_engine.tts import TTSModel
from talktalk_engine import voice as V


class FakeMX:
    array = staticmethod(np.array)
    concatenate = staticmethod(np.concatenate)
    eval = staticmethod(lambda *args: None)
    float32 = np.float32
    int32 = np.int32

    def __init__(self):
        self.seeds = []
        self.random = SimpleNamespace(seed=self.seeds.append)


class FakeModel:
    latent_dim = 2
    sample_rate = 24000

    def __init__(self, steps=4, natural_stop=True):
        self.steps, self.natural_stop = steps, natural_stop
        self.closed = 0
        self.calls = []
        self.decode_calls = 0
        self.nonfinite = False
        self.reference_encodes = 0
        self.audio = SimpleNamespace(decode=self.decode)

    def _speaker_embeddings(self, embedding, zero):
        return [embedding]

    def _encode(self, text):
        return text.split()

    def _encode_prompt_latent(self, audio):
        self.reference_encodes += 1
        return np.full((1, 10, 2), self.reference_encodes, np.float32)

    def sample(self, **kwargs):
        self.calls.append(kwargs)
        try:
            for step in range(min(self.steps, kwargs["max_decode_steps"])):
                yield np.ones((1, 1, 2), np.float32), self.natural_stop and step == self.steps - 1
        finally:
            self.closed += 1

    def decode(self, latents, **kwargs):
        self.decode_calls += 1
        if kwargs != {"use_cache": False, "last_chunk": True}:
            raise AssertionError("Ming must decode each completed fragment without shared decoder cache")
        pcm = np.full((1, latents.shape[1] * 1920), np.nan if self.nonfinite else 0.2, np.float32)
        return pcm, None, None


def adapter(**kwargs):
    tts = MingTTSModel(MODEL_KEY, "/unused", "rev")
    tts.mx = FakeMX()
    tts.model = FakeModel(**kwargs)
    tts.native_rate = 24000
    tts._languages = {"de": "German"}
    tts._add_period = lambda text: text
    tts._split_fragments = lambda text, limit: text.split("|")
    tts._trim_silence = lambda audio, rate: audio
    tts._resample_reference = resample
    return tts


def voice():
    return MingVoice("human", MODEL_KEY, "Human reference.", np.ones(24000, np.float32) * 0.1,
                     np.ones((1, 10, 2), np.float32), np.ones((1, 192), np.float32),
                     {"native_rate": 24000, "ref_s": 1.0})


class MingStreamTests(unittest.TestCase):
    def test_latents_yield_before_decode_and_fragment_pcm_drains_before_next_fragment(self):
        tts, v, stats = adapter(), voice(), {}
        stream = tts.stream("First.|Second.", v, "de", seed=42, max_frames=20, stats=stats)
        for index in range(4):
            self.assertIsNone(next(stream))
            self.assertEqual(stats["frames"], index + 1)
            self.assertEqual(stats["progress_steps"], index + 1)
            self.assertEqual(tts.model.decode_calls, 0)
        for _ in range(2):
            self.assertEqual(next(stream).shape, (3840,))
            self.assertEqual(len(tts.model.calls), 1)
        rest = list(stream)
        self.assertEqual(sum(item is None for item in rest), 4)
        self.assertEqual([len(item) for item in rest if item is not None], [3840, 3840])
        self.assertEqual(stats["audio_samples"], 15360)
        self.assertEqual(stats["frames"], 8)
        self.assertTrue(stats["eos"])
        self.assertEqual(stats["cb0"], [])
        self.assertNotIn("generated_codes", stats)
        self.assertEqual(tts.mx.seeds, [42])
        self.assertIn("Target language: German.", tts.model.calls[0]["prompt"])
        self.assertIsNot(tts.model.calls[0]["prompt_latent"], v.prompt_latent)
        self.assertEqual(tts.model.reference_encodes, 1)
        self.assertIs(tts.model.calls[0]["prompt_latent"], tts.model.calls[1]["prompt_latent"])
        self.assertEqual(tts.model.closed, 2)

    def test_cancel_after_one_latent_closes_sampler_without_decode(self):
        tts = adapter()
        stream = tts.stream("A sentence.", voice(), "en", seed=3)
        self.assertIsNone(next(stream))
        stream.close()
        self.assertEqual(tts.model.closed, 1)
        self.assertEqual(tts.model.decode_calls, 0)
        # A cancelled request owns no decoder state; the same reference still renders.
        self.assertTrue(any(item is not None for item in tts.stream("Another sentence.", voice(), "en", seed=3)))

    def test_scheduler_can_admit_asr_and_cancel_at_latent_boundary(self):
        tts = adapter()
        scheduler = GpuScheduler()
        job = Job("tts", P0, lambda: tts.stream("A sentence.", voice(), "en"))
        scheduler.submit(job)
        job.gen = job.factory()
        next(job.gen)
        job.steps = 1
        asr = Job("asr", P1, lambda: iter([None]), deadline_ms=0)
        scheduler.submit(asr)
        scheduler.report_playout(800)
        self.assertIs(scheduler._pick(time.monotonic() * 1000), asr)
        job.cancel()
        self.assertIs(scheduler._pick(time.monotonic() * 1000), job)
        scheduler._retire(job, "cancelled")
        self.assertEqual(tts.model.closed, 1)
        self.assertEqual(tts.model.decode_calls, 0)

    def test_budget_exhaustion_is_not_eos_and_never_decodes_truncated_fragment(self):
        for kwargs, budget in (({"steps": 5}, 3), ({"natural_stop": False}, 20)):
            with self.subTest(kwargs=kwargs):
                tts, stats = adapter(**kwargs), {}
                self.assertTrue(all(item is None for item in tts.stream("A sentence.", voice(), "en", max_frames=budget, stats=stats)))
                self.assertTrue(stats["runaway"])
                self.assertFalse(stats["eos"])
                self.assertEqual(tts.model.decode_calls, 0)

    def test_nonfinite_output_is_rejected_before_any_pcm(self):
        tts = adapter()
        tts.model.nonfinite = True
        stream = tts.stream("A sentence.", voice(), "en")
        for _ in range(4):
            self.assertIsNone(next(stream))
        with self.assertRaisesRegex(ValueError, "nonfinite"):
            next(stream)

    def test_resampling_preserves_duration_and_float32_contract(self):
        audio = np.sin(np.arange(44100, dtype=np.float32) * (2 * np.pi * 440 / 44100))
        converted = resample(audio, 44100, 24000)
        self.assertEqual(converted.dtype, np.float32)
        self.assertEqual(converted.shape, (24000,))
        self.assertTrue(np.isfinite(converted).all())

    def test_missing_speaker_asset_fails_before_import_or_download(self):
        with self.assertRaisesRegex(ValueError, "not installed"):
            MingTTSModel(MODEL_KEY, "/missing-ming-model", "rev").load()


class MingVoiceTests(unittest.TestCase):
    def fake_mlx(self):
        core = types.ModuleType("mlx.core")
        core.array, core.float32, core.int32 = np.array, np.float32, np.int32
        package = types.ModuleType("mlx")
        package.core = core
        return patch.dict(sys.modules, {"mlx": package, "mlx.core": core})

    def test_roundtrip_preserves_model_tag_and_independent_reference(self):
        source = voice()
        blob = V.to_blob(source)
        tensors, metadata = V._decode_safetensors(blob)
        self.assertEqual(metadata["family"], VOICE_FORMAT)
        self.assertEqual(metadata["model_key"], MODEL_KEY)
        with self.fake_mlx():
            loaded = V.from_blob(blob)
        adapter().validate_voice(loaded)
        np.testing.assert_array_equal(loaded.reference24k, source.reference24k)
        np.testing.assert_array_equal(loaded.prompt_latent, source.prompt_latent)
        self.assertEqual(loaded.ref_frames, 10)
        self.assertEqual(loaded.key8, source.key8)
        metadata["model_key"] = "tts-qwen3-1.7b-base-8bit"
        with self.assertRaisesRegex(ValueError, "identity"):
            V.from_blob(V._encode_safetensors(tensors, metadata))

    def test_families_cannot_cross_load_and_legacy_qwen_remains_readable(self):
        qwen = TTSModel("qwen", "/unused", "rev")
        with self.assertRaisesRegex(ValueError, "family"):
            qwen.validate_voice(voice())
        tensors = {"ref_codes": np.zeros((1, 16, 4), np.int32), "ref_text_ids": np.ones((1, 3), np.int32),
                   "speaker_embed": np.ones((1, 4), np.float32)}
        with self.fake_mlx():
            legacy = V.from_blob(V._encode_safetensors(tensors, {"key": "legacy", "ref_text": "Original.", "meta": "{}"}))
        qwen.validate_voice(legacy)
        with self.assertRaisesRegex(ValueError, "different TTS model"):
            adapter().validate_voice(legacy)
        legacy.model_key = "another-qwen"
        with self.assertRaisesRegex(ValueError, "different TTS model"):
            qwen.validate_voice(legacy)

    def test_invalid_latent_shape_or_nonfinite_embedding_is_not_serialized(self):
        v = voice()
        v.speaker_embed[0, 0] = np.nan
        with self.assertRaisesRegex(ValueError, "nonfinite"):
            V.to_blob(v)
        v = voice()
        v.prompt_latent = np.ones((1, 0, 2), np.float32)
        with self.assertRaisesRegex(ValueError, "latent"):
            V.to_blob(v)

    def test_bfloat16_latents_are_converted_before_numpy_reads_the_buffer(self):
        class BFloatLatent:
            def __array__(self, *args, **kwargs):
                raise ValueError("bfloat16 is not a NumPy buffer format")

            def astype(self, dtype):
                return np.ones((1, 10, 2), dtype)
        v = voice()
        v.prompt_latent = BFloatLatent()
        with self.fake_mlx():
            blob = V.to_blob(v)
        tensors, _ = V._decode_safetensors(blob)
        self.assertEqual(tensors["prompt_latent"].dtype, np.float32)

    def test_long_reference_fails_budget_validation_before_replacing_voice(self):
        tts = adapter()
        v = voice()
        v.prompt_latent = np.ones((1, 490, 2), np.float32)
        with self.assertRaisesRegex(ValueError, "shorter voice reference") as failed:
            tts.validate_voice(v)
        self.assertEqual(failed.exception.code, "voice_reference_too_long")
        state = EngineState(SimpleNamespace(horizon_ms=1000, asr_thread="shared"))
        state.tts, state.voice, state.voice_state = tts, voice(), "ready"
        state.sched.call = lambda action, **kwargs: action()
        original = state.voice
        with patch("talktalk_engine.voice.from_blob", return_value=v):
            with self.assertRaisesRegex(Exception, "shorter voice reference"):
                state.load_voice(b"invalid-reference")
        self.assertIs(state.voice, original)
        self.assertEqual(state.voice_state, "ready")


class MingGuardTests(unittest.TestCase):
    def test_duration_guards_use_pcm_clock_not_ming_latent_count(self):
        def stream(seed, cap, stats):
            # One latent is not necessarily one Qwen codec frame. Many latents with short
            # decoded audio must not trip the Qwen frame-duration heuristic.
            stats.update(frames=1000, audio_samples=2400, cb0=[], eos=True)
            yield np.ones(2400, np.float32)
        guarded = Guarded(stream, "Hello.", 0.1, 0, policy=Policy(max_attempts=1, hold_s=0))
        audio = [x for x in guarded if isinstance(x, np.ndarray)]
        self.assertEqual(sum(map(len, audio)), 2400)
        self.assertFalse(guarded.report["runaway"])
        self.assertFalse(guarded.report["slow"])

    def test_pcm_runaway_is_rejected_even_with_few_latents(self):
        def stream(seed, cap, stats):
            stats.update(frames=1, audio_samples=24000 * 4, cb0=[], eos=True)
            yield np.ones(24000 * 4, np.float32)
        guarded = Guarded(stream, "Hello.", 1, 0, policy=Policy(max_attempts=1))
        self.assertEqual(list(guarded), [])
        self.assertTrue(guarded.report["runaway"])

    def test_progress_requires_completed_latent_advancement(self):
        def stream(seed, cap, stats):
            stats.update(frames=0, audio_samples=0, eos=True, progress_steps=0)
            yield None
            stats["progress_steps"] = 1
            yield None
            yield None  # No new work: never a heartbeat.
            stats["progress_steps"] = 2
            yield None
        guarded = Guarded(stream, "Hello.", 0, 0, policy=Policy(max_attempts=1, short_factor=0))
        with patch("talktalk_engine.guards.PROGRESS_INTERVAL_S", 0):
            values = list(guarded)
        self.assertIsNone(values[0])
        self.assertIsInstance(values[1], Progress)
        self.assertIsNone(values[2])
        self.assertIsInstance(values[3], Progress)

    def test_progress_is_throttled_and_qwen_none_is_unchanged(self):
        def stream(seed, cap, stats):
            stats.update(frames=0, eos=True)
            for step in range(5):
                if marked:
                    stats["progress_steps"] = step + 1
                yield None
        for marked in (False, True):
            guarded = Guarded(stream, "Hello.", 0, 0, policy=Policy(max_attempts=1, short_factor=0))
            with patch("talktalk_engine.guards.PROGRESS_INTERVAL_S", 100000):
                values = list(guarded)
            self.assertEqual(sum(isinstance(x, Progress) for x in values), int(marked))

    def test_engine_state_ignores_qwen_continuation_for_ming(self):
        state = EngineState(SimpleNamespace(horizon_ms=1000, asr_thread="shared"))
        state.tts, state.voice, state.voice_state = adapter(), voice(), "ready"
        out = queue.Queue()
        job = state.tts_job({"job": "ming", "text": "Hello there.", "lang": "en", "seed": 42,
                             "voice_key": "human", "context_id": "turn", "previous_job": "qwen",
                             "max_attempts": 1, "guards": False}, out)
        self.assertEqual(state.context_jobs, {})
        for item in job.factory():
            if item is not None:
                job.on_item(item)
        job.on_done(None)
        tail = [value for kind, value in out.queue if kind == "tail"][0]
        self.assertFalse(tail["context_used"])
        self.assertIsNone(state.tts_context)
        self.assertEqual(tail["audio_s"], 0.32)


if __name__ == "__main__":
    unittest.main()
