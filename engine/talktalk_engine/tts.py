"""Qwen3-TTS Base ICL, streamed one frame per scheduler step (§4.4, §6.1, C10).

`TTSModel.stream()` is a generator: each next() runs one codec frame (12.5 Hz) and yields either
None (no audio yet) or a float32 PCM chunk (24 kHz) every `interval * 12.5` frames. The first
step contains the ICL prefill. The loop mirrors mlx-audio's `_generate_icl` at the pinned commit
(f65753b: #1096 decoder priming with the reference tail, #1117 sliding window); the M0 bench
checks it against upstream with greedy decoding (identical codes). Owning the loop gives the
scheduler per-frame preemption, cancellation at frame boundaries, per-frame timing for M0-T1/T3,
runaway caps, and an optional mx.compile'd code-predictor step (§6.4 ladder step 1).

Everything here must run on the single GPU thread (MLX streams are thread-local).
"""
import hashlib
import time
from pathlib import Path

import numpy as np

SAMPLE_RATE = 24000
FRAME_HZ = 12.5
LANGUAGES = {"en": "english", "de": "german", "zh": "chinese"}


def _load_expected_duration():
    import json

    d = json.loads(Path(__file__).with_name("expected_duration.json").read_text(encoding="utf-8"))
    langs = {k: (float(v["intercept_s"]), float(v["per_word_s"])) for k, v in d["languages"].items()}
    return langs, d["default"]


# One data file shared with Swift's ExpectedDuration (speak-playout's parity test reads it too).
_EXPECTED, _EXPECTED_DEFAULT = _load_expected_duration()


def expected_seconds(text, lang):
    """Expected spoken duration for the runaway cap and the `short` flag:
    intercept + per_word x max(1, whitespace words), coefficients from expected_duration.json."""
    words = max(1, len(text.split()))
    intercept, per_word = _EXPECTED.get(lang, _EXPECTED[_EXPECTED_DEFAULT])
    return intercept + per_word * words


class TTSModel:
    def __init__(self, key, path, rev):
        self.key = key
        self.path = Path(path)
        self.rev = rev
        self.model = None
        self._spk_memo = {}
        self._cp_fns = {}
        self.stats = {"speaker_embed_calls": 0, "speaker_embed_hits": 0}

    # ------------------------------------------------------------------ loading

    def load(self):
        import mlx.core as mx
        from mlx_audio.tts.utils import load_model

        self.mx = mx
        self.model = load_model(self.path)
        self.cfg = self.model.config.talker_config
        self.defaults = self.model._resolve_generation_options(None, None, None, None, None)
        self._patch_speaker_memo()
        return self

    def _patch_speaker_memo(self):
        """mlx-audio recomputes the x-vector on every ICL call (research F9). Memoise it by the
        reference audio's content. Depends on mlx-audio internals, hence the pinned commit and the
        cached-vs-uncached equality check in the M0 bench."""
        orig = self.model.extract_speaker_embedding
        memo = self._spk_memo
        stats = self.stats
        mx = self.mx

        def extract(audio, sr=24000):
            stats["speaker_embed_calls"] += 1
            fp = hashlib.sha256(np.ascontiguousarray(np.asarray(audio), dtype=np.float32).tobytes()).hexdigest()
            hit = memo.get(fp)
            if hit is not None:
                stats["speaker_embed_hits"] += 1
                return hit
            emb = orig(audio, sr=sr)
            mx.eval(emb)
            memo[fp] = emb
            return emb

        self._orig_extract = orig
        self.model.extract_speaker_embedding = extract

    @property
    def is_icl_capable(self):
        st = self.model.speech_tokenizer
        return st is not None and st.has_encoder and getattr(self.model.config, "tts_model_type", "base") == "base"

    # ------------------------------------------------------------------ voice

    def speaker_cosine(self, ref_pcm, sample_pcm):
        """Cosine between the x-vectors (the model's own speaker encoder) of two 24 kHz clips. The
        reference goes through the memoised extractor (it repeats); the sample does not, so the
        memo does not grow with every clip scored."""
        mx = self.mx

        def unit(e):
            v = np.array(e).reshape(-1).astype(np.float64)
            return v / (np.linalg.norm(v) + 1e-12)

        ref = self.model.extract_speaker_embedding(mx.array(np.ascontiguousarray(ref_pcm, dtype=np.float32)))
        smp = self._orig_extract(mx.array(np.ascontiguousarray(sample_pcm, dtype=np.float32)))
        return float(unit(ref) @ unit(smp))

    def build_voice(self, ref_pcm, ref_text, key):
        """ref_pcm: float32 mono 24 kHz numpy. Returns (Voice, timings ms)."""
        from .voice import Voice

        mx = self.mx
        m = self.model
        audio = mx.array(np.ascontiguousarray(ref_pcm, dtype=np.float32))
        t0 = time.perf_counter()
        codes = m.speech_tokenizer.encode(audio[None, None, :])
        mx.eval(codes)
        t1 = time.perf_counter()
        ref_chat = f"<|im_start|>assistant\n{ref_text}<|im_end|>\n"
        ref_ids = mx.array(m.tokenizer.encode(ref_chat))[None, :][:, 3:-2]
        mx.eval(ref_ids)
        t2 = time.perf_counter()
        spk = self._orig_extract(audio)
        mx.eval(spk)
        t3 = time.perf_counter()
        voice = Voice(key=key, ref_text=ref_text, ref_codes=codes, ref_text_ids=ref_ids, speaker_embed=spk,
                      meta={"ref_s": round(len(ref_pcm) / SAMPLE_RATE, 3), "frames": int(codes.shape[2])})
        return voice, {"encode_ms": (t1 - t0) * 1e3, "text_ids_ms": (t2 - t1) * 1e3, "speaker_embed_ms": (t3 - t2) * 1e3}

    # ------------------------------------------------------------------ inputs

    def prepare_inputs(self, text, voice, language):
        """Upstream `_prepare_icl_generation_inputs` steps 2-12, taking the cached reference tensors
        instead of re-encoding audio. Checked against upstream in the M0 bench (allclose)."""
        mx = self.mx
        m = self.model
        cfg = self.cfg
        talker = m.talker
        target_chat = f"<|im_start|>assistant\n{text}<|im_end|>\n<|im_start|>assistant\n"
        target_ids = mx.array(m.tokenizer.encode(target_chat))[None, :]
        text_ids = target_ids[:, 3:-5]
        tts_tokens = mx.array([[m.config.tts_bos_token_id, m.config.tts_eos_token_id, m.config.tts_pad_token_id]])
        tts_embeds = talker.text_projection(talker.get_text_embeddings()(tts_tokens))
        tts_bos_embed, tts_eos_embed, tts_pad_embed = tts_embeds[:, 0:1, :], tts_embeds[:, 1:2, :], tts_embeds[:, 2:3, :]

        combined_text_ids = mx.concatenate([voice.ref_text_ids, text_ids], axis=1)
        text_embed = talker.text_projection(talker.get_text_embeddings()(combined_text_ids))
        text_embed = mx.concatenate([text_embed, tts_eos_embed], axis=1)
        text_lens = text_embed.shape[1]

        ref_codes = voice.ref_codes
        ref_codec_embed = talker.get_input_embeddings()(ref_codes[:, 0, :])
        for i in range(cfg.num_code_groups - 1):
            ref_codec_embed = ref_codec_embed + talker.code_predictor.codec_embedding[i](ref_codes[:, i + 1, :])
        codec_bos_embed = talker.get_input_embeddings()(mx.array([[cfg.codec_bos_id]]))
        codec_embed_icl = mx.concatenate([codec_bos_embed, ref_codec_embed], axis=1)
        codec_lens = codec_embed_icl.shape[1]
        codec_pad_embed = talker.get_input_embeddings()(mx.array([[cfg.codec_pad_id]]))
        text_with_codec_pad = text_embed + mx.broadcast_to(codec_pad_embed, (1, text_lens, codec_pad_embed.shape[-1]))
        codec_with_text_pad = codec_embed_icl + mx.broadcast_to(tts_pad_embed, (1, codec_lens, tts_pad_embed.shape[-1]))
        icl_input_embed = mx.concatenate([text_with_codec_pad, codec_with_text_pad], axis=1)

        language_id = None
        lang_name = LANGUAGES.get(language, language)
        if lang_name and lang_name.lower() != "auto" and cfg.codec_language_id:
            language_id = cfg.codec_language_id.get(lang_name.lower())
        if language_id is None:
            codec_prefill = [cfg.codec_nothink_id, cfg.codec_think_bos_id, cfg.codec_think_eos_id]
        else:
            codec_prefill = [cfg.codec_think_id, cfg.codec_think_bos_id, language_id, cfg.codec_think_eos_id]
        codec_prefix_embed = talker.get_input_embeddings()(mx.array([codec_prefill]))
        codec_prefix_suffix = talker.get_input_embeddings()(mx.array([[cfg.codec_pad_id, cfg.codec_bos_id]]))
        spk = voice.speaker_embed
        if spk is not None:
            spk = spk.astype(codec_prefix_embed.dtype)
            codec_prefix_embed = mx.concatenate([codec_prefix_embed, spk.reshape(1, 1, -1), codec_prefix_suffix], axis=1)
        else:
            codec_prefix_embed = mx.concatenate([codec_prefix_embed, codec_prefix_suffix], axis=1)
        role_embed = talker.text_projection(talker.get_text_embeddings()(target_ids[:, :3]))
        pad_count = codec_prefix_embed.shape[1] - 2
        pad_embeds = mx.broadcast_to(tts_pad_embed, (1, pad_count, tts_pad_embed.shape[-1]))
        combined_prefix = mx.concatenate([pad_embeds, tts_bos_embed], axis=1) + codec_prefix_embed[:, :-1, :]
        input_embeds = mx.concatenate([role_embed, combined_prefix, icl_input_embed], axis=1)
        return input_embeds, tts_pad_embed, tts_pad_embed

    # ------------------------------------------------------------------ code predictor

    def _code_predictor(self, compiled, temperature, top_k, top_p):
        key = (bool(compiled), float(temperature), int(top_k), float(top_p))
        fn = self._cp_fns.get(key)
        if fn is not None:
            return fn
        mx = self.mx
        m = self.model
        cp = m.talker.code_predictor
        emb = m.talker.get_input_embeddings()
        n = self.cfg.num_code_groups

        def predict(code_hidden, next_token):
            cache = cp.make_cache()
            tokens = [next_token]
            codec_embed = emb(next_token)
            for i in range(n - 1):
                if i == 0:
                    inp = mx.concatenate([code_hidden, emb(next_token)], axis=1)
                else:
                    inp = cp.codec_embedding[i - 1](tokens[-1])
                logits, cache, _ = cp(inp, cache=cache, generation_step=i)
                tok = m._sample_token(logits, temperature=temperature, top_k=top_k, top_p=top_p)
                tokens.append(tok)
                codec_embed = codec_embed + cp.codec_embedding[i](tok)
            return mx.concatenate(tokens, axis=1), codec_embed

        if compiled:
            if temperature <= 0:
                fn = mx.compile(predict)
            else:
                state = [mx.random.state]
                fn = mx.compile(predict, inputs=state, outputs=state)
        else:
            fn = predict
        self._cp_fns[key] = fn
        return fn

    # ------------------------------------------------------------------ streaming

    def stream(self, text, voice, language, interval=0.16, compiled=False, temperature=None, top_k=None,
               top_p=None, repetition_penalty=None, seed=None, max_frames=None, stats=None, prime=True):
        """Generator: one codec frame per next(). Yields None or a float32 numpy chunk."""
        mx = self.mx
        m = self.model
        cfg = self.cfg
        st = stats if stats is not None else {}
        d = self.defaults
        temperature = d["temperature"] if temperature is None else temperature
        top_k = d["top_k"] if top_k is None else top_k
        top_p = d["top_p"] if top_p is None else top_p
        rep = d["repetition_penalty"] if repetition_penalty is None else repetition_penalty
        # Honor the checkpoint's generation setting (1.05 for the shipped Base models).
        # Raising it to the MLX ICL floor of 1.5 changed clone timbre in the local A/B;
        # keep the existing recent-token window and output guards instead.
        if max_frames is None:
            max_frames = int(FRAME_HZ * (3.0 * expected_seconds(text, language) + 2.0))
        chunk = max(1, int(interval * FRAME_HZ))
        if seed is not None:
            mx.random.seed(int(seed))
        decoder = m.speech_tokenizer.decoder
        eos = cfg.codec_eos_token_id
        suppress = [i for i in range(cfg.vocab_size - 1024, cfg.vocab_size) if i != eos]
        predict = self._code_predictor(compiled, temperature, top_k, top_p)

        t_start = time.perf_counter()
        st.update(frames=0, eos=False, runaway=False, chunks=0, frame_ms=[], chunk_at_ms=[], cb0=[],
                  max_frames=max_frames, chunk_frames=chunk, compiled=bool(compiled))
        try:
            input_embeds, trailing, pad_embed = self.prepare_inputs(text, voice, language)
            mx.eval(input_embeds)
            t_prep = time.perf_counter()
            st["prepare_ms"] = (t_prep - t_start) * 1e3
            st["prompt_len"] = int(input_embeds.shape[1])
            decoder.reset_streaming_state()
            if prime and voice.ref_codes.shape[2] > 0:
                # #1096: prime the streaming decoder with the reference tail (output discarded).
                mx.eval(decoder.streaming_step(voice.ref_codes[:, :, -25:]))
            t_prime = time.perf_counter()
            st["prime_ms"] = (t_prime - t_prep) * 1e3
            cache = m.talker.make_cache()
            generated = []
            token_ids = []
            decoded = 0
            trailing_idx = 0
            for step in range(max_frames):
                tf = time.perf_counter()
                logits, hidden = m.talker(input_embeds, cache=cache)
                next_token = m._sample_token(logits, temperature=temperature, top_k=top_k, top_p=top_p,
                                             repetition_penalty=rep, generated_tokens=token_ids or None,
                                             suppress_tokens=suppress)
                is_eos = next_token[0, 0] == eos
                all_codes, codec_embed = predict(hidden[:, -1:, :], next_token)
                if trailing_idx < trailing.shape[1]:
                    text_embed = trailing[:, trailing_idx:trailing_idx + 1, :]
                    trailing_idx += 1
                else:
                    text_embed = pad_embed
                input_embeds = text_embed + codec_embed
                mx.eval(input_embeds, is_eos, all_codes)
                if step == 0:
                    st["prefill_ms"] = (time.perf_counter() - t_prime) * 1e3
                if is_eos.item():
                    st["eos"] = True
                    break
                tok0 = int(next_token[0, 0])
                token_ids.append(tok0)
                st["cb0"].append(tok0)
                generated.append(all_codes)
                st["frames"] += 1
                out = None
                if len(generated) - decoded >= chunk:
                    out = self._decode(generated[decoded:])
                    decoded = len(generated)
                st["frame_ms"].append((time.perf_counter() - tf) * 1e3)
                if out is not None:
                    st["chunks"] += 1
                    st["chunk_at_ms"].append((time.perf_counter() - t_start) * 1e3)
                yield out
            else:
                st["runaway"] = True
            if len(generated) > decoded:
                out = self._decode(generated[decoded:])
                st["chunks"] += 1
                st["chunk_at_ms"].append((time.perf_counter() - t_start) * 1e3)
                yield out
        finally:
            decoder.reset_streaming_state()
            mx.clear_cache()
            st["total_ms"] = (time.perf_counter() - t_start) * 1e3

    def _decode(self, codes_list):
        mx = self.mx
        codes = mx.transpose(mx.stack(codes_list, axis=1), (0, 2, 1))
        wav = self.model.speech_tokenizer.decoder.streaming_step(codes)
        audio = wav.squeeze(1)[0]
        mx.eval(audio)
        return np.array(audio, dtype=np.float32)


def echo_features(cb0, ref_cb0, head=16):
    """Codebook-0 features for the start-of-utterance echo detector (§4.4 tts.py; calibrated in
    M0-T1 against ASR read-back labels). Echo = the clone keeps reading the zh reference."""
    g = list(cb0[:head])
    r = list(ref_cb0)
    if len(g) < 2 or len(r) < 2:
        return {"bigram_overlap": 0.0, "longest_run": 0}
    rb = set(zip(r, r[1:]))
    gb = list(zip(g, g[1:]))
    overlap = sum(1 for b in gb if b in rb) / len(gb)
    rset = {}
    for i, t in enumerate(r):
        rset.setdefault(t, []).append(i)
    best = 0
    for i, t in enumerate(g):
        for j in rset.get(t, ()):
            k = 0
            while i + k < len(g) and j + k < len(r) and g[i + k] == r[j + k]:
                k += 1
            best = max(best, k)
    return {"bigram_overlap": round(overlap, 4), "longest_run": best}
