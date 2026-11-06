"""Fake TTS / ASR models with the real generator contracts (tts.py, asr.py)."""
import sys
import time
import types

import numpy as np

from talktalk_engine import tts as real_tts

SAMPLE_RATE = 24000
FRAME_HZ = 12.5


class FakeTTSModel:
    def __init__(self, key, path, rev):
        self.key, self.path, self.rev = key, path, rev
        self.stats = {"speaker_embed_calls": 0, "speaker_embed_hits": 0}

    def load(self):
        import mlx.core as mx   # first import happens here, on the GPU thread (T0 audit)
        self.mx = mx
        return self

    def speaker_cosine(self, ref_pcm, sample_pcm):
        """Fake x-vector: a 16-band energy profile, so identical clips score 1.0."""
        def prof(a):
            a = np.asarray(a, np.float64)
            v = np.array([float(np.sum(b ** 2)) for b in np.array_split(a, 16)]) + 1e-9
            return v / np.linalg.norm(v)
        return float(prof(ref_pcm) @ prof(sample_pcm))

    def build_voice(self, ref_pcm, ref_text, key):
        from talktalk_engine.voice import Voice
        frames = max(2, int(len(ref_pcm) / SAMPLE_RATE * FRAME_HZ))
        codes = np.arange(16 * frames, dtype=np.int32).reshape(1, 16, frames) % 2048
        voice = Voice(key=key, ref_text=ref_text, ref_codes=codes, ref_text_ids=np.arange(8, dtype=np.int32)[None, :],
                      speaker_embed=np.ones((1, 4), np.float32), meta={"ref_s": round(len(ref_pcm) / SAMPLE_RATE, 3)})
        return voice, {"encode_ms": 1.0, "text_ids_ms": 0.1, "speaker_embed_ms": 0.5}

    def stream(self, text, voice, language, interval=0.16, compiled=False, temperature=None, top_k=None,
               top_p=None, repetition_penalty=None, seed=None, max_frames=None, stats=None, prime=True,
               capture_codes=False):
        st = stats if stats is not None else {}
        print(f"fake tts: generating {len(text)} chars")   # library chatter on fd 1
        n = max(3, int(real_tts.expected_seconds(text, language) * FRAME_HZ))
        if max_frames:
            n = min(n, max_frames)
        per_chunk = max(1, int(round(interval * FRAME_HZ)))
        t0 = time.perf_counter()
        st.update(frames=0, frame_ms=[], chunk_at_ms=[], cb0=[], eos=True, runaway=False, compiled=compiled,
                  prepare_ms=0.2, prime_ms=0.1, prefill_ms=0.3, chunk_frames=per_chunk, prompt_len=8)
        pending = 0
        for i in range(n):
            ts = time.perf_counter()
            time.sleep(0.002)
            st["frames"] += 1
            st["cb0"].append((i * 7919 + 13) % 2003)   # no short period: the cb0 loop guard must not trip
            st["frame_ms"].append((time.perf_counter() - ts) * 1e3)
            pending += 1
            if pending == per_chunk or i == n - 1:
                t = (np.arange(pending * 1920) / SAMPLE_RATE).astype(np.float32)
                st["chunk_at_ms"].append((time.perf_counter() - t0) * 1e3)
                pending = 0
                yield (0.2 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
            else:
                yield None
        st["total_ms"] = (time.perf_counter() - t0) * 1e3


class FakeASRModel:
    def __init__(self, key, path, rev):
        self.key, self.path, self.rev = key, path, rev

    def load(self):
        time.sleep(0.05)
        return self

    def stream(self, pcm16k, hint=None, context=None, max_tokens=256, stats=None):
        st = stats if stats is not None else {}
        st.update(step_ms=[], tokens=0)
        for _ in range(min(4, max_tokens)):
            ts = time.perf_counter()
            time.sleep(0.002)
            st["step_ms"].append((time.perf_counter() - ts) * 1e3)
            yield None
        yield {"text": "我们下周二上午十点开会。", "language": hint or "zh",
               "timing": {"total_ms": 10.0, "first_step_ms": 2.0, "tokens": 4}}


def install():
    fake_tts = types.ModuleType("talktalk_engine.tts")
    fake_tts.TTSModel = FakeTTSModel
    for name in ("expected_seconds", "echo_features", "LANGUAGES", "SAMPLE_RATE", "FRAME_HZ",
                 "CONTINUATION_MAX_FRAMES", "CONTINUATION_MAX_TEXT"):
        setattr(fake_tts, name, getattr(real_tts, name))
    fake_asr = types.ModuleType("talktalk_engine.asr")
    fake_asr.ASRModel = FakeASRModel
    sys.modules["talktalk_engine.tts"] = fake_tts
    sys.modules["talktalk_engine.asr"] = fake_asr
