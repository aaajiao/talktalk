"""Ming adapter, voice isolation and cooperative cancellation without MLX/Metal."""
import ast
import importlib.util
import queue
import sys
import time
import types
import typing
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np

from talktalk_engine.guards import Guarded, Policy, Progress, fade_out
from talktalk_engine.main import EngineState
from talktalk_engine.ming import (MODEL_KEY, VOICE_FORMAT, ForwardTrim, MingTTSModel, MingVoice, StreamResampler,
                                   resample)
from talktalk_engine.scheduler import GpuScheduler, Job, P0, P1
from talktalk_engine.tts import TTSModel
from talktalk_engine import voice as V


# The pinned mlx-audio _trim_trailing_silence; PinnedUpstreamTests checks it against the installed
# source, and the fake one-pass decode trims with it as ming.py does.
TRIM_SOURCE = '''
def _trim_trailing_silence(
    speech: mx.array,
    sample_rate: int,
    threshold: float = 1e-3,
    tail_seconds: float = 0.3,
) -> mx.array:
    """Cut trailing near-silence, keeping a fixed tail."""
    frame = int(sample_rate * 0.1)
    tail = int(sample_rate * tail_seconds)
    if speech.shape[-1] < frame:
        return speech
    num_frames = speech.shape[-1] // frame
    # Discard any incomplete analysis frame.
    speech = speech[: num_frames * frame]
    scores = np.abs(np.array(speech, dtype=np.float32))
    scores = scores.reshape(num_frames, frame).mean(axis=-1)
    loud = np.nonzero(scores > threshold)[0]
    if loud.size == 0:
        return speech[:tail]
    return speech[: int(loud[-1]) * frame + frame + tail]
'''
_trim_namespace = {"np": np, "mx": SimpleNamespace(array=np.ndarray)}
exec(TRIM_SOURCE, _trim_namespace)
upstream_trim = _trim_namespace["_trim_trailing_silence"]

# The pinned mlx-audio AudioVAE.encode_latent, also AST-locked. Evaluated with NumPy, it gives the
# prompt latent the adapter's cached path must reproduce.
ENCODE_LATENT_SOURCE = '''
def encode_latent(
    self, waveform: mx.array, waveform_length: mx.array
) -> Tuple[mx.array, mx.array]:
    frame_num = mx.ceil(
        waveform_length / self.config["enc_kwargs"]["input_dim"]
    ).astype(mx.int32)
    if self.patch_size != -1:
        frame_num = mx.ceil(frame_num / self.patch_size).astype(mx.int32)
    h = self.encoder(waveform)  # (B, T, 2*latent)
    h = h.transpose(0, 2, 1)
    mu, logvar = mx.split(h, 2, axis=1)
    std = mx.exp(0.5 * mx.clip(logvar, -30, 20))
    latent = mu + std * mx.random.normal(mu.shape, dtype=mu.dtype)
    latent = latent.transpose(0, 2, 1)
    return latent, frame_num
'''

# Fake decoder geometry per native rate: samples per 80 ms latent and the first streaming
# decode's ISTFT pad. 44.1 kHz is Ming 3.0's (3528 = 4 x 882 hop, pad (3528 - 882) / 2).
GEOMETRY = {24000: (1920, 600), 44100: (3528, 1323)}
# Fake encoder logvar per reference frame, including values outside encode_latent's clip.
FAKE_LOGVAR = np.linspace(-40, 25, 10, dtype=np.float32)


class FakeRandom:
    def __init__(self):
        self.seeds = []
        self.rng = np.random.default_rng(0)

    def seed(self, value):
        self.seeds.append(value)
        self.rng = np.random.default_rng(value)

    def normal(self, shape, dtype=np.float32):
        return self.rng.standard_normal(tuple(shape)).astype(dtype)


class FakeMX:
    array = staticmethod(np.array)
    concatenate = staticmethod(np.concatenate)
    eval = staticmethod(lambda *args: None)
    split = staticmethod(np.split)
    exp = staticmethod(np.exp)
    clip = staticmethod(np.clip)
    float32 = np.float32
    int32 = np.int32

    def __init__(self):
        self.random = FakeRandom()
        self.seeds = self.random.seeds


class FakeModel:
    latent_dim = 2
    sample_rate = 24000

    def __init__(self, steps=4, natural_stop=True, signal=None, native_rate=24000):
        self.steps, self.natural_stop = steps, natural_stop
        self.samples_per_latent, self.lag = GEOMETRY[native_rate]
        self.signal = signal or (lambda index: 0.2 + 0.05 * np.sin(index * 0.01))
        self.closed = 0
        self.calls = []
        self.decode_calls = 0
        self.stream_calls = []
        self.nonfinite = False
        self.reference_encodes = 0
        self.audio = SimpleNamespace(decode=self.decode, encoder=self.encoder)

    def _speaker_embeddings(self, embedding, zero):
        return [embedding]

    def _encode(self, text):
        return text.split()

    def _pad_prompt_waveform(self, audio):
        return np.asarray(audio)[None, :]

    def encoder(self, waveform):
        # (B, T, 2 * latent_dim): mu is the first reference sample, logvar FAKE_LOGVAR per frame.
        self.reference_encodes += 1
        hidden = np.zeros((1, 10, 4), np.float32)
        hidden[..., :2] = waveform[0, 0]
        hidden[0, :, 2:] = FAKE_LOGVAR[:, None]
        return hidden

    def sample(self, **kwargs):
        self.calls.append(kwargs)
        try:
            for step in range(min(self.steps, kwargs["max_decode_steps"])):
                yield np.ones((1, 1, 2), np.float32), self.natural_stop and step == self.steps - 1
        finally:
            self.closed += 1

    def wave(self, start, stop):
        index = np.arange(start, stop)
        if self.nonfinite:
            return np.full((1, index.size), np.nan, np.float32)
        return self.signal(index).astype(np.float32)[None, :]

    def decode(self, latents, past_key_values=None, use_cache=False, stream_state=(None, None, None),
               last_chunk=False):
        """One-pass decode, or the upstream streaming API's sample accounting: a call returns
        the audio of the latents of earlier calls minus the first call's ISTFT pad, and the
        last call flushes the rest."""
        self.decode_calls += 1
        count = latents.shape[1]
        if not use_cache:
            if not last_chunk or past_key_values is not None:
                raise AssertionError("a whole clause decodes each completed fragment once, without decoder cache")
            return self.wave(0, count * self.samples_per_latent), None, None
        started = isinstance(stream_state, dict)
        if past_key_values != ("cache" if started else None):
            raise AssertionError("the decoder cache must carry over between calls of one fragment")
        state = dict(stream_state) if started else {"seen": 0, "emitted": 0}
        before = state["seen"]
        state["seen"] += count
        per_latent = self.samples_per_latent
        target = state["seen"] * per_latent if last_chunk else max(0, before * per_latent - self.lag)
        out = self.wave(state["emitted"], target)
        state["emitted"] = target
        self.stream_calls.append((count, last_chunk))
        return out, None if last_chunk else state, "cache"


def adapter(native_rate=24000, **kwargs):
    tts = MingTTSModel(MODEL_KEY, "/unused", "rev")
    tts.mx = FakeMX()
    tts.model = FakeModel(native_rate=native_rate, **kwargs)
    tts.native_rate = native_rate
    tts._languages = {"de": "German", "fr": "French"}
    tts._add_period = lambda text: text
    tts._split_fragments = lambda text, limit: text.split("|")
    tts._trim_silence = upstream_trim
    tts._resample_reference = resample
    tts._decode_lag = tts.model.lag
    return tts


def pcm_of(items):
    return np.concatenate([item for item in items if isinstance(item, np.ndarray)])


def voice(native_rate=24000):
    return MingVoice("human", MODEL_KEY, "Human reference.", np.ones(24000, np.float32) * 0.1,
                     np.ones((1, 10, 2), np.float32), np.ones((1, 192), np.float32),
                     {"native_rate": native_rate, "ref_s": 1.0})


class MingStreamTests(unittest.TestCase):
    def test_french_uses_target_language_prompt_and_existing_voice(self):
        tts, v = adapter(), voice()
        audio = [item for item in tts.stream("Merci à tous.", v, "fr", seed=42) if item is not None]
        self.assertGreater(sum(map(len, audio)), 0)
        self.assertIn("Target language: French.\n", tts.model.calls[0]["prompt"])
        self.assertEqual(v.key, "human")

    def test_latents_yield_before_decode_and_fragment_pcm_drains_before_next_fragment(self):
        tts, v, stats = adapter(), voice(), {}
        stream = tts.stream("First.|Second.", v, "de", seed=42, max_frames=20, stats=stats)
        for index in range(4):
            self.assertIsNone(next(stream))
            self.assertEqual(stats["frames"], index + 1)
            self.assertEqual(stats["progress_steps"], index + 1)
            self.assertEqual(tts.model.decode_calls, 0)
        # 4 latents = 7680 samples; the pinned trim keeps three whole 0.1 s frames.
        self.assertEqual(next(stream).shape, (3840,))
        self.assertEqual(next(stream).shape, (3360,))
        self.assertEqual(len(tts.model.calls), 1)
        rest = list(stream)
        self.assertEqual(sum(item is None for item in rest), 4)
        self.assertEqual([len(item) for item in rest if item is not None], [3840, 3360])
        self.assertEqual(stats["audio_samples"], 14400)
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

    def test_reference_encoder_runs_once_per_reference_and_noise_follows_each_seed(self):
        tts, v = adapter(), voice()

        def latent(seed, reference=v):
            list(tts.stream("A sentence.", reference, "en", seed=seed))
            return tts.model.calls[-1]["prompt_latent"]
        def upstream(seed, reference=v):
            # The pinned encode_latent itself, with NumPy as mx, seeded like the job.
            mx = FakeMX()
            mx.ceil, mx.array = np.ceil, np.ndarray
            namespace = {"mx": mx, "Tuple": typing.Tuple}
            exec(ENCODE_LATENT_SOURCE, namespace)
            vae = SimpleNamespace(config={"enc_kwargs": {"input_dim": 4}}, patch_size=4,
                                  encoder=FakeModel().encoder)
            waveform = FakeModel()._pad_prompt_waveform(resample(reference.reference24k, 24000, 24000))
            mx.random.seed(seed)
            return namespace["encode_latent"](vae, waveform, np.array([waveform.shape[1]]))[0]
        first, again, other = latent(7), latent(7), latent(8)
        self.assertEqual(tts.model.reference_encodes, 1)
        np.testing.assert_array_equal(first, again)
        self.assertFalse(np.array_equal(first, other))
        np.testing.assert_array_equal(first, upstream(7))
        np.testing.assert_array_equal(other, upstream(8))
        changed = voice()
        changed.reference24k = changed.reference24k * 2
        np.testing.assert_array_equal(latent(7, changed), upstream(7, changed))
        self.assertEqual(tts.model.reference_encodes, 2)

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
        for release in (None, 0.64):
            with self.subTest(release_s=release):
                tts = adapter(steps=14)
                tts.model.nonfinite = True
                stream = tts.stream("A sentence.", voice(), "en", release_s=release)
                with self.assertRaisesRegex(ValueError, "nonfinite"):
                    for item in stream:
                        self.assertNotIsInstance(item, np.ndarray)

    def test_incremental_decode_releases_the_hold_two_latents_after_the_first_decode(self):
        signals = (("speech", None), ("trailing silence", lambda i: np.where(i < 40000, 0.2, 0.0)))
        for rate, (name, signal) in [(rate, item) for rate in (24000, 44100) for item in signals]:
            with self.subTest(native_rate=rate, signal=name):
                whole = adapter(rate, steps=30, signal=signal)
                expected = pcm_of(whole.stream("A long sentence.", voice(rate), "en", seed=5, max_frames=60))
                tts, stats = adapter(rate, steps=30, signal=signal), {}
                stream = tts.stream("A long sentence.", voice(rate), "en", seed=5, max_frames=60, stats=stats,
                                    release_s=0.64)
                items, pcm_at = [], []
                for item in stream:
                    items.append(item)
                    if isinstance(item, np.ndarray):
                        pcm_at.append((stats["frames"], len(item)))
                # 10 latents first: the second decode, at 12 latents, returns 10 latents of audio
                # minus the ISTFT pad; whole 0.1 s frames minus the release hold still exceed
                # 0.64 s at 24 kHz (15624 samples at a 24 kHz native rate, 16160 at 44.1 kHz).
                self.assertEqual(pcm_at[0][0], 12)
                self.assertGreaterEqual(sum(length for frames, length in pcm_at if frames == 12), 15360)
                self.assertEqual(tts.model.stream_calls, [(10, False), (2, False)] + [(4, False)] * 4 + [(2, True)])
                emitted = pcm_of(items)
                # The forward trim and (at 44.1 kHz) the streaming resampler give the one-pass
                # result exactly when the decoder returns the same samples.
                np.testing.assert_array_equal(emitted, expected)
                self.assertTrue(stats["eos"])
                self.assertEqual(stats["fragments"], 1)
                self.assertEqual(stats["audio_samples"], expected.size)
                self.assertTrue(all(len(x) <= 3840 for x in items if isinstance(x, np.ndarray)))

    def test_whole_clause_keeps_one_decode_per_fragment(self):
        tts = adapter(steps=30)
        list(tts.stream("A long sentence.", voice(), "en", max_frames=60, release_s=None))
        self.assertEqual(tts.model.stream_calls, [])
        self.assertEqual(tts.model.decode_calls, 1)

    def test_generation_cut_before_eos_fades_the_audio_already_decoded(self):
        tts, stats = adapter(steps=40, natural_stop=False), {}
        guarded = Guarded(lambda seed, cap, inner: tts.stream("A long sentence.", voice(), "en", seed=seed,
                                                              max_frames=20, stats=inner, release_s=0.64),
                          "A long sentence.", 10.0, 3, policy=Policy(max_attempts=1))
        items = list(guarded)
        pcm = pcm_of(items)
        # Decodes of 10, 2, 4 and 4 latents; 16 x 1920 - 600 decoded samples keep 12 whole frames.
        # The last 1176 (RELEASE_HOLD) were never released, so the 25 ms fade covers 600 of them.
        self.assertEqual(tts.model.stream_calls, [(10, False), (2, False), (4, False), (4, False)])
        self.assertEqual(pcm.size, 28800)
        self.assertEqual(len([x for x in items if isinstance(x, np.ndarray)][-1]), 1176)
        np.testing.assert_array_equal(pcm[:27624], tts.model.wave(0, 27624)[0])
        np.testing.assert_array_equal(pcm[27624:], fade_out(tts.model.wave(27624, 28800)[0], 25.0))
        self.assertEqual(pcm[-1], 0.0)
        self.assertTrue(guarded.stats["runaway"])
        self.assertFalse(guarded.stats["eos"])
        self.assertTrue(guarded.report["runaway"])
        self.assertEqual(guarded.report["audio_s"], 1.2)
        # At 44.1 kHz the held-back 1176 input samples are 640 output samples: still >= 600.
        tts = adapter(44100, steps=40, natural_stop=False)
        items = list(tts.stream("A long sentence.", voice(44100), "en", max_frames=20, release_s=0.64))
        last = [x for x in items if isinstance(x, np.ndarray)][-1]
        self.assertGreaterEqual(len(last), 600)
        self.assertEqual(last[-1], 0.0)
        self.assertTrue(np.isfinite(pcm_of(items)).all())

    def test_first_decode_is_sized_from_the_hold_at_the_native_rate(self):
        tts = adapter()
        tts.native_rate, tts._decode_lag = 44100, 1323   # Ming 3.0: 3528 samples per latent
        # 0.64 s at 24 kHz is 28224 input samples; plus the 1176-sample hold that is 7 whole
        # 4410-sample frames, which 10 x 3528 - 1323 decoded samples reach.
        self.assertEqual(tts._first_decode_latents(0.64), 10)
        self.assertEqual(tts._first_decode_latents(0.0), 2)
        with self.assertRaisesRegex(ValueError, "release hold"):
            next(adapter().stream("A sentence.", voice(), "en", release_s=float("nan")))


class ForwardDecodeTests(unittest.TestCase):
    def test_forward_trim_keeps_exactly_what_the_pinned_trim_keeps(self):
        rng = np.random.default_rng(11)
        rate = 44100
        silence = np.zeros(20000, np.float32)   # longer than the 0.3 s tail: the verdict sets the cut
        signals = [np.zeros(1000, np.float32), np.full(4000, 0.3, np.float32), np.zeros(30000, np.float32)]
        signals += [np.concatenate([np.full(4410, level, np.float32), silence])
                    for level in (0.0011, 0.0010002, 0.001, 0.0009998, 0.0009)]
        for _ in range(60):
            parts = []
            for _ in range(int(rng.integers(1, 7))):
                size = int(rng.integers(50, 25000))
                level = rng.choice([0.1, 1e-5, 0.00101, 0.0010002, 0.0009998, 0.00099, 0.0])
                if rng.random() < 0.5:   # constant magnitude: whole frames score exactly the level
                    parts.append((rng.choice([-1.0, 1.0], size) * level).astype(np.float32))
                else:
                    parts.append((rng.standard_normal(size) * level).astype(np.float32))
            signals.append(np.concatenate(parts))
        for index, signal in enumerate(signals):
            with self.subTest(case=index):
                final = upstream_trim(signal, rate).shape[-1]
                trim, offset, safe = ForwardTrim(rate), 0, 0
                while offset < signal.size:
                    step = int(rng.integers(1, 9000))
                    trim.push(signal[offset:offset + step])
                    offset += step
                    self.assertGreaterEqual(trim.kept(), safe)
                    safe = trim.kept()
                    self.assertLessEqual(safe, final)
                self.assertEqual(trim.kept(final=True), final)

    def test_stream_resampler_matches_whole_fragment_resampling(self):
        rng = np.random.default_rng(13)
        for case in range(12):
            with self.subTest(case=case):
                signal = (rng.standard_normal(int(rng.integers(100, 60000))) * 0.2).astype(np.float32)
                resampler, pushed, limit, out = StreamResampler(44100, 24000, 1176), 0, 0, []
                while pushed < signal.size:
                    step = int(rng.integers(1, 12000))
                    resampler.push(signal[pushed:pushed + step])
                    pushed = min(signal.size, pushed + step)
                    limit = int(rng.integers(limit, pushed + 1))
                    out.append(resampler.take(limit))
                final = int(rng.integers(limit, signal.size + 1))
                out.append(resampler.take(final, final=True))
                streamed = np.concatenate(out)
                whole = resample(signal[:final], 44100, 24000)
                self.assertEqual(streamed.dtype, np.float32)
                self.assertEqual(streamed.shape, whole.shape)
                np.testing.assert_array_equal(streamed, whole)

    def test_resampling_preserves_duration_and_float32_contract(self):
        audio = np.sin(np.arange(44100, dtype=np.float32) * (2 * np.pi * 440 / 44100))
        converted = resample(audio, 44100, 24000)
        self.assertEqual(converted.dtype, np.float32)
        self.assertEqual(converted.shape, (24000,))
        self.assertTrue(np.isfinite(converted).all())

    def test_missing_speaker_asset_fails_before_import_or_download(self):
        with self.assertRaisesRegex(ValueError, "not installed"):
            MingTTSModel(MODEL_KEY, "/missing-ming-model", "rev").load()


class PinnedUpstreamTests(unittest.TestCase):
    """ming.py mirrors parts of the pinned mlx-audio BailingMM source. These checks read the
    installed source without importing MLX. After an mlx-audio upgrade a failure means the
    adapter must be verified again on the GPU before the expected source is updated."""

    @classmethod
    def setUpClass(cls):
        spec = importlib.util.find_spec("mlx_audio")
        if spec is None or not spec.submodule_search_locations:
            raise unittest.SkipTest("mlx-audio is not installed in this Python")
        path = Path(list(spec.submodule_search_locations)[0], "tts", "models", "bailingmm", "bailingmm.py")
        cls.tree = ast.parse(path.read_text(encoding="utf-8"))

    def function(self, name, owner=None):
        scopes = [node for node in self.tree.body if isinstance(node, ast.ClassDef) and node.name == owner] \
            if owner else [self.tree]
        found = [node for scope in scopes for node in scope.body
                 if isinstance(node, ast.FunctionDef) and node.name == name]
        self.assertEqual(len(found), 1, f"{owner}.{name}")
        return found[0]

    def assertSource(self, node, expected):
        self.assertEqual(ast.dump(node), ast.dump(ast.parse(expected).body[0]))

    def test_forward_trim_mirrors_the_pinned_trailing_silence_trim(self):
        self.assertSource(self.function("_trim_trailing_silence"), TRIM_SOURCE)

    def test_reference_latent_is_encoder_output_plus_seeded_noise(self):
        # Cached by MingTTSModel._reference_conditioning; only the normal draw stays per job.
        self.assertSource(self.function("encode_latent", "AudioVAE"), ENCODE_LATENT_SOURCE)
        self.assertSource(self.function("_encode_prompt_latent", "Model"), '''
def _encode_prompt_latent(self, prompt_waveform: mx.array) -> mx.array:
    prompt_waveform = self._pad_prompt_waveform(prompt_waveform)
    prompt_waveform_length = mx.array([prompt_waveform.shape[1]], dtype=mx.int32)
    prompt_latent, _ = self.audio.encode_latent(
        prompt_waveform, prompt_waveform_length
    )
    return prompt_latent
''')


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
        self.assertEqual(tail["audio_s"], 0.3)  # 4 latents; the trim keeps whole 0.1 s frames

    def test_engine_state_streams_only_clauses_that_are_not_held_to_their_end(self):
        for whole in (False, True):
            with self.subTest(whole_clause=whole):
                state = EngineState(SimpleNamespace(horizon_ms=1000, asr_thread="shared"))
                state.tts, state.voice, state.voice_state = adapter(steps=16), voice(), "ready"
                out = queue.Queue()
                job = state.tts_job({"job": "ming", "text": "A somewhat longer sentence here.", "lang": "en",
                                     "seed": 42, "voice_key": "human", "whole_clause": whole,
                                     "max_attempts": 1}, out)
                for item in job.factory():
                    if item is not None:
                        job.on_item(item)
                job.on_done(None)
                tail = [value for kind, value in out.queue if kind == "tail"][0]
                # Default policy: a 0.64 s hold, so the first decode takes 10 latents.
                self.assertEqual(state.tts.model.stream_calls, [] if whole else [(10, False), (2, False), (4, True)])
                self.assertEqual(state.tts.model.decode_calls, 1 if whole else 3)
                self.assertGreater(tail["audio_s"], 0)
                self.assertGreaterEqual(tail["timing"]["first_pcm_ms"], tail["timing"]["queue_ms"])

    def test_decode_options_reach_only_ming(self):
        state = EngineState(SimpleNamespace(horizon_ms=1000, asr_thread="shared"))
        state.tts = adapter()
        self.assertEqual(state._decode_options(None), {"release_s": None})
        self.assertEqual(state._decode_options(True), {"release_s": Policy().hold_s})
        self.assertEqual(state._decode_options(0.2), {"release_s": 0.2})
        state.tts = TTSModel("qwen", "/unused", "rev")
        self.assertEqual(state._decode_options(True), {})


if __name__ == "__main__":
    unittest.main()
