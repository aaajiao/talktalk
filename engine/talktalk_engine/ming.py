"""Ming 3.0 0.5B adapter over the pinned MLX-Audio BailingMM implementation.

The upstream ``generate(stream=True)`` blocks until a whole text fragment is decoded.
Here ``sample`` advances one latent at a time on TalkTalk's shared GPU scheduler, so
ASR and cancellation keep their existing scheduling boundaries. A completed fragment
is decoded once, resampled to 24 kHz and drained in at most 160 ms PCM chunks before
the next fragment starts. This is fragment synthesis, not low-latency codec streaming.

No imports of MLX/MLX-Audio at module import time, no downloads and no audio devices.
"""
import hashlib
import json
import math
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from .tts import FRAME_HZ, SAMPLE_RATE, expected_seconds
from .voice import _encode_safetensors

MODEL_KEY = "tts-ming3-0.5b-bf16"
VOICE_FORMAT = "ming3-reference-v1"
MAX_REFERENCE_S = 30
MAX_FRAGMENT_UNITS = 24
MAX_FRAGMENT_LATENTS = 400
MIN_OUTPUT_LATENTS = 16


class ReferenceBudgetError(ValueError):
    code = "voice_reference_too_long"

    def __init__(self):
        super().__init__("Ming reference and text leave too little context; use a shorter voice reference")


@dataclass
class MingVoice:
    key: str
    model_key: str
    ref_text: str
    reference24k: object
    prompt_latent: object
    speaker_embed: object
    meta: dict = field(default_factory=dict)
    family: str = VOICE_FORMAT

    @property
    def key8(self):
        return hashlib.sha256(self.key.encode()).hexdigest()[:8]

    @property
    def ref_frames(self):
        return int(self.prompt_latent.shape[1])


def _validate_arrays(reference, latent, speaker):
    if reference.dtype != np.float32 or reference.ndim != 1 or not 0 < reference.size <= MAX_REFERENCE_S * SAMPLE_RATE:
        raise ValueError("invalid Ming reference PCM")
    if latent.dtype != np.float32 or latent.ndim != 3 or latent.shape[0] != 1 or not 0 < latent.shape[1] <= 512:
        raise ValueError("invalid Ming reference latent")
    if not 0 < latent.shape[2] <= 1024:
        raise ValueError("invalid Ming latent width")
    if speaker.dtype != np.float32 or speaker.shape != (1, 192):
        raise ValueError("invalid Ming speaker embedding")
    if not all(np.isfinite(a).all() for a in (reference, latent, speaker)):
        raise ValueError("nonfinite Ming voice conditioning")


def voice_to_blob(voice):
    def float32(value):
        if isinstance(value, np.ndarray):
            return np.asarray(value, dtype=np.float32)
        # NumPy cannot interpret MLX's bfloat16 buffer, even with dtype=float32 passed to
        # asarray. Convert on the GPU side first, as the existing Qwen serializer does.
        import mlx.core as mx
        return np.asarray(value.astype(mx.float32))
    tensors = {"reference24k": float32(voice.reference24k),
               "prompt_latent": float32(voice.prompt_latent),
               "speaker_embed": float32(voice.speaker_embed)}
    _validate_arrays(tensors["reference24k"], tensors["prompt_latent"], tensors["speaker_embed"])
    return _encode_safetensors(tensors, {"family": VOICE_FORMAT, "model_key": voice.model_key,
                                        "key": voice.key, "ref_text": voice.ref_text,
                                        "meta": json.dumps(voice.meta)})


def voice_from_tensors(tensors, meta):
    if meta.get("model_key") != MODEL_KEY or not meta.get("ref_text", "").strip():
        raise ValueError("invalid Ming voice identity")
    if set(tensors) != {"reference24k", "prompt_latent", "speaker_embed"}:
        raise ValueError("invalid Ming conditioning tensors")
    _validate_arrays(tensors["reference24k"], tensors["prompt_latent"], tensors["speaker_embed"])
    import mlx.core as mx
    return MingVoice(key=meta["key"], model_key=meta["model_key"], ref_text=meta["ref_text"],
                     reference24k=tensors["reference24k"].copy(), prompt_latent=mx.array(tensors["prompt_latent"]),
                     speaker_embed=mx.array(tensors["speaker_embed"]), meta=json.loads(meta.get("meta", "{}")))


def resample(pcm, source_rate, target_rate):
    """Offline reference/fragment conversion; no sounddevice or Core Audio initialization."""
    audio = np.asarray(pcm, dtype=np.float32).reshape(-1)
    if source_rate == target_rate:
        return audio
    from scipy.signal import resample_poly
    divisor = math.gcd(int(source_rate), int(target_rate))
    return resample_poly(audio, int(target_rate) // divisor, int(source_rate) // divisor).astype(np.float32)


class MingTTSModel:
    supports_continuation = False

    def __init__(self, key, path, rev):
        if key != MODEL_KEY:
            raise ValueError("unsupported Ming TTS model")
        self.key, self.path, self.rev = key, Path(path), rev
        self.model = None
        self.stats = {"speaker_embed_calls": 0, "speaker_embed_hits": 0}
        self._spk_memo = {}

    def load(self):
        # Native weights must be provisioned by the verified installer. SpeakerEncoder has
        # a download fallback; never call it with a missing local path.
        speaker_path = self.path / "speaker_encoder" / "campplus.safetensors"
        if not speaker_path.is_file():
            raise ValueError("Ming native speaker encoder is not installed")
        import mlx.core as mx
        from mlx_audio.tts.utils import load_model
        from mlx_audio.tts.models.bailingmm.bailingmm import (
            MING3_TARGET_LANGUAGES, _add_period, _split_fragments, _trim_trailing_silence,
        )
        from mlx_audio.tts.models.lingv3_tts.speaker import SpeakerEncoder
        from mlx_audio.resample import resample_audio_array

        self.mx = mx
        self.model = load_model(self.path)
        if not getattr(self.model, "ming3", False):
            raise ValueError("expected Ming 3.0 dense TTS weights")
        self.native_rate = int(self.model.sample_rate)
        self.speaker = SpeakerEncoder(speaker_path)
        self._languages = MING3_TARGET_LANGUAGES
        self._add_period = _add_period
        self._split_fragments = _split_fragments
        self._trim_silence = _trim_trailing_silence
        self._resample_reference = resample_audio_array
        return self

    @property
    def is_icl_capable(self):
        return True

    def _embedding(self, pcm, memoize=False):
        audio = np.ascontiguousarray(pcm, dtype=np.float32)
        self.stats["speaker_embed_calls"] += 1
        key = hashlib.sha256(audio.tobytes()).hexdigest()
        if memoize and key in self._spk_memo:
            self.stats["speaker_embed_hits"] += 1
            return self._spk_memo[key]
        embedding = self.speaker(audio, sample_rate=SAMPLE_RATE)
        self.mx.eval(embedding)
        if memoize:
            # Similarity checks repeat one reference; never accumulate historical voices.
            self._spk_memo = {key: embedding}
        return embedding

    def build_voice(self, ref_pcm, ref_text, key):
        pcm = np.ascontiguousarray(ref_pcm, dtype=np.float32)
        if pcm.ndim != 1 or not 0 < pcm.size <= MAX_REFERENCE_S * SAMPLE_RATE or not np.isfinite(pcm).all():
            raise ValueError("invalid Ming reference PCM")
        if not ref_text.strip():
            raise ValueError("Ming needs the reference transcript")
        start = time.perf_counter()
        # Match MLX-Audio load_audio used for the approved audition, including its sharper
        # reference resampling filter. Output PCM conversion remains a separate operation.
        audio = self.mx.array(self._resample_reference(pcm, SAMPLE_RATE, self.native_rate))
        latent = self.model._encode_prompt_latent(audio)
        self.mx.eval(latent)
        encoded = time.perf_counter()
        embedding = self._embedding(pcm, memoize=True)
        finished = time.perf_counter()
        voice = MingVoice(key, self.key, ref_text, pcm.copy(), latent, embedding,
                          {"ref_s": round(pcm.size / SAMPLE_RATE, 3), "frames": int(latent.shape[1]),
                           "native_rate": self.native_rate})
        self.validate_voice(voice)
        return voice, {"encode_ms": (encoded - start) * 1e3, "text_ids_ms": 0.0,
                       "speaker_embed_ms": (finished - encoded) * 1e3}

    def validate_voice(self, voice):
        if not isinstance(voice, MingVoice) or voice.family != VOICE_FORMAT or voice.model_key != self.key:
            raise ValueError("voice conditioning belongs to a different TTS model")
        if voice.prompt_latent.shape[2] != self.model.latent_dim or voice.meta.get("native_rate") != self.native_rate:
            raise ValueError("Ming voice conditioning does not match this model")
        # A malformed/very long reference must fail before replacing the loaded voice. This
        # brief German phrase includes the longer language instruction; each actual fragment
        # is checked again below because its own text also consumes the shared cache.
        self._check_budget(voice, "Vielen Dank.", self._prompt("de"))

    def _prompt(self, language):
        prompt = "Please generate speech based on the following description.\n"
        if language in self._languages:
            prompt += f"Target language: {self._languages[language]}.\n"
        return prompt

    def _check_budget(self, voice, text, prompt):
        # Exact token pieces from pinned BailingMM._prepare_input_embed, without projecting
        # tensors a second time. Ming3 is the dense chat layout with one latent per patch.
        pieces = ("<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n", "<|im_start|>user\n",
                  prompt, "  speaker_1:", "<|vision_start|>", "<|vision_pad|>", "<|vision_end|>\n",
                  " Text input:\n", voice.ref_text, text, "<|im_end|>\n", "<|im_start|>assistant\n", "<audio>")
        positions = sum(len(self.model._encode(part)) for part in pieces) + voice.ref_frames
        if 512 - positions < MIN_OUTPUT_LATENTS:
            raise ReferenceBudgetError()
        return positions

    def speaker_cosine(self, ref_pcm, sample_pcm):
        def unit(embedding):
            vector = np.asarray(embedding, dtype=np.float64).reshape(-1)
            return vector / (np.linalg.norm(vector) + 1e-12)
        return float(unit(self._embedding(ref_pcm, memoize=True)) @ unit(self._embedding(sample_pcm)))

    def stream(self, text, voice, language, interval=0.16, compiled=False, temperature=None, top_k=None,
               top_p=None, repetition_penalty=None, seed=None, max_frames=None, stats=None, prime=True,
               capture_codes=False):
        """One scheduler step per latent; PCM drain steps never synthesize another fragment.

        ``frames`` counts Ming latents for diagnostics and the hard generation budget.
        ``audio_samples`` is the actual 24 kHz output clock used by duration guards. Ming
        has no Qwen codebook, so no fake CB0 values or synthetic continuation are exposed.
        """
        self.validate_voice(voice)
        if language not in ("zh", "en", "de"):
            raise ValueError("unsupported Ming output language")
        if not math.isfinite(interval) or interval <= 0:
            raise ValueError("invalid Ming chunk interval")
        mx, model = self.mx, self.model
        st = stats if stats is not None else {}
        budget = int(max_frames) if max_frames is not None else int(FRAME_HZ * (3 * expected_seconds(text, language) + 2))
        if budget <= 0:
            raise ValueError("invalid Ming generation budget")
        chunk_samples = max(1, min(3840, int(SAMPLE_RATE * interval)))
        st.update(frames=0, audio_samples=0, eos=False, runaway=False, cb0=[], frame_ms=[], chunk_at_ms=[],
                  fragments=0, decode_ms=[], compiled=False, chunk_frames=None, prime_ms=0.0, progress_steps=0)
        start = time.perf_counter()
        sampler = None
        latents = []
        try:
            if seed is not None:
                mx.random.seed(int(seed))
            prompt = self._prompt(language)
            speaker = model._speaker_embeddings(voice.speaker_embed, False)
            mx.eval(speaker)
            # AudioVAE.encode_latent samples mu + std * normal. The audition seeds before
            # this operation on every request; reusing a latent sampled during enrollment
            # changes both the reference and the subsequent RNG sequence. The blob's latent
            # is only a shape/budget check. Re-encode the original PCM under this job's seed.
            reference = mx.array(self._resample_reference(voice.reference24k, SAMPLE_RATE, self.native_rate))
            prompt_latent = model._encode_prompt_latent(reference)
            mx.eval(prompt_latent)
            fragments = self._split_fragments(self._add_period(text), MAX_FRAGMENT_UNITS)
            st["prepare_ms"] = (time.perf_counter() - start) * 1e3
            for fragment in fragments:
                positions = self._check_budget(voice, fragment, prompt)
                st["prompt_len"] = max(st.get("prompt_len", 0), positions)
                remaining = budget - st["frames"]
                if remaining <= 0:
                    st["runaway"] = True
                    return
                sampler = model.sample(prompt=prompt, text=fragment, instruction=None, prompt_text=voice.ref_text,
                                       max_decode_steps=min(remaining, MAX_FRAGMENT_LATENTS), cfg=2.0, sigma=0.25,
                                       temperature=0.0 if temperature is None else temperature, flow_steps=10,
                                       prompt_latent=prompt_latent, spk_emb=speaker)
                latents = []
                ended = False
                while True:
                    step_start = time.perf_counter()
                    try:
                        latent, is_last = next(sampler)
                    except StopIteration:
                        break
                    mx.eval(latent)
                    latents.append(latent)
                    st["frames"] += 1
                    st["progress_steps"] = st["frames"]
                    st["frame_ms"].append((time.perf_counter() - step_start) * 1e3)
                    if st["frames"] == 1:
                        st["prefill_ms"] = st["frame_ms"][-1]
                    ended = bool(is_last)
                    # Always offer cancellation/ASR a boundary before another latent or decode.
                    yield None
                    if ended:
                        break
                sampler.close()
                sampler = None
                if not ended or not latents:
                    st["runaway"] = True  # Cache exhaustion or the latent budget is not EOS.
                    return
                decode_start = time.perf_counter()
                decoded, _, _ = model.audio.decode(mx.concatenate(latents, axis=1), use_cache=False, last_chunk=True)
                audio = self._trim_silence(decoded[0], self.native_rate)
                mx.eval(audio)
                pcm = resample(np.asarray(audio, dtype=np.float32), self.native_rate, SAMPLE_RATE)
                latents.clear()
                if not np.isfinite(pcm).all():
                    raise ValueError("Ming generated nonfinite audio")
                st["decode_ms"].append((time.perf_counter() - decode_start) * 1e3)
                st["fragments"] += 1
                for offset in range(0, pcm.size, chunk_samples):
                    chunk = pcm[offset:offset + chunk_samples].copy()
                    st["audio_samples"] += int(chunk.size)
                    st["chunk_at_ms"].append((time.perf_counter() - start) * 1e3)
                    yield chunk
            st["eos"] = bool(fragments)
        finally:
            if sampler is not None:
                sampler.close()
            latents.clear()
            st["total_ms"] = (time.perf_counter() - start) * 1e3
