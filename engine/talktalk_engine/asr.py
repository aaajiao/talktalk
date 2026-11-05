"""Qwen3-ASR, stepped for the scheduler (§6.1): step 1 = feature extraction + audio encoder +
prompt prefill + first token; then one decode token per step. Runs on the GPU thread only.

M0 note: this uses mlx-audio's `stream_generate`, whose first step bundles encode and prefill. A
leaner loop that splits the encoder into fixed-length blocks is M1 work (§6.1); M0-T3 reports the
first-step and per-token p99 separately, plus the whole-call p99.
"""
import time

import numpy as np

SAMPLE_RATE = 16000
LANG_NAMES = {"zh": "Chinese", "en": "English", "de": "German"}


class ASRModel:
    def __init__(self, key, path, rev):
        self.key = key
        self.path = path
        self.rev = rev
        self.model = None

    def load(self):
        import mlx.core as mx
        from mlx_audio.stt.utils import load_model

        self.mx = mx
        self.model = load_model(str(self.path))
        return self

    def stream(self, pcm16k, hint=None, context=None, max_tokens=256, stats=None):
        """Generator: yields None per decode step; the final yield is the result dict."""
        st = stats if stats is not None else {}
        audio = np.ascontiguousarray(pcm16k, dtype=np.float32)
        lang = LANG_NAMES.get(hint) if hint else None
        t0 = time.perf_counter()
        st.update(step_ms=[], tokens=0, audio_s=round(len(audio) / SAMPLE_RATE, 3))
        tokens = []
        gen = self.model.stream_generate(self.mx.array(audio), max_tokens=max_tokens, language=lang,
                                         system_prompt=context or None)
        try:
            ts = time.perf_counter()
            for token, _ in gen:
                tokens.append(int(token))
                now = time.perf_counter()
                st["step_ms"].append((now - ts) * 1e3)
                if len(tokens) == 1:
                    st["first_step_ms"] = (now - t0) * 1e3
                yield None
                ts = time.perf_counter()
        finally:
            gen.close()
        raw = self.model._tokenizer.decode(tokens, skip_special_tokens=True) if tokens else ""
        detected, text = self.model.extract_language(raw) if hasattr(self.model, "extract_language") else (lang, raw)
        st["tokens"] = len(tokens)
        st["total_ms"] = (time.perf_counter() - t0) * 1e3
        yield {"text": text.strip(), "language": detected if not lang else lang, "timing": {
            "total_ms": round(st["total_ms"], 2), "first_step_ms": round(st.get("first_step_ms", 0.0), 2),
            "tokens": len(tokens)}}
