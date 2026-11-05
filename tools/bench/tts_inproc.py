#!/usr/bin/env python3
"""M0-T1 in-process checks that do not go through the engine's HTTP API.

  <engine>/venv/bin/python3 -I -B tools/bench/tts_inproc.py parity --model-dir <dir> --ref <wav> --ref-text <txt>
      Our frame-stepped loop (engine/talktalk_engine/tts.py) vs upstream mlx-audio
      `generate(ref_audio=..., stream=True)` with greedy decoding (temperature 0): the decoded audio
      must match (same codes, same decoder). Also checks memoised vs fresh speaker embedding,
      and compiled vs plain code predictor under greedy decoding (the T1 "compile step" rule
      needs "greedy output identical").
  ... customvoice --model-dir <CustomVoice dir> --sentences t1_en.json [t1_de.json]
      Baseline RTF of Qwen3-TTS-1.7B-CustomVoice-8bit on the new pin (non-streaming generate, as
      readread measured RTF 0.22 on mlx-audio 0.6.0), same sentences as T1. (Dropped from the slimmed
      M0, 2026-11-04; kept for M2.)
  ... similarity --model-dir <dir> --ref voice/reference.wav --dir <saved T1 audio>
      Speaker-change label for T1 lite (x-vector cosine to the reference, robust outlier rule).

Prints one JSON object per line on stdout. Runs outside the Claude Code sandbox (Metal).
Never touches the network (HF_HUB_OFFLINE) or the Keychain.
"""
import argparse
import json
import os
import sys
import time
import wave
from pathlib import Path

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "engine"))

import numpy as np  # noqa: E402

from talktalk_engine import stubs  # noqa: E402

stubs.install()   # keep mlx_audio from importing the real sounddevice (no Core Audio client)


def read_wav(path):
    with wave.open(str(path), "rb") as w:
        sr = w.getframerate()
        a = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768.0
    if sr != 24000:
        from scipy.signal import resample_poly
        a = resample_poly(a, 24000, sr).astype(np.float32)
    return a


def emit(obj):
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def ours(tm, text, voice, lang, interval, compiled=False):
    st = {}
    chunks = [c for c in tm.stream(text, voice, lang, interval=interval, compiled=compiled, temperature=0.0,
                                   seed=0, stats=st) if c is not None]
    return (np.concatenate(chunks) if chunks else np.zeros(0, np.float32)), st


def cmd_parity(a):
    import mlx.core as mx

    from talktalk_engine.tts import LANGUAGES, TTSModel

    tm = TTSModel("bench", a.model_dir, "local").load()
    ref = read_wav(a.ref)
    ref_text = Path(a.ref_text).read_text().strip()
    voice, timings = tm.build_voice(ref, ref_text, key="parity")
    emit({"check": "build_voice", **{k: round(v, 2) for k, v in timings.items()}})

    # memoised speaker embedding == fresh one
    fresh = tm._orig_extract(mx.array(ref))
    memo1 = tm.model.extract_speaker_embedding(mx.array(ref))
    memo2 = tm.model.extract_speaker_embedding(mx.array(ref))
    mx.eval(fresh, memo1, memo2)
    emit({"check": "speaker_embed_memo", "equal": bool(np.array_equal(np.array(fresh), np.array(memo2))),
          "stats": dict(tm.stats)})

    sentences = [("en", "Thanks, everyone. Let me walk you through where the project stands."),
                 ("de", "Danke Ihnen allen. Ich gebe Ihnen kurz einen Überblick."),
                 ("en", "Yes.")]
    for lang, text in sentences:
        mine, st = ours(tm, text, voice, lang, a.interval)
        t0 = time.perf_counter()
        up = []
        for r in tm.model.generate(text=text, ref_audio=mx.array(ref), ref_text=ref_text, lang_code=LANGUAGES[lang],
                                   temperature=0.0, stream=True, streaming_interval=a.interval):
            up.append(np.array(r.audio))
        up_ms = (time.perf_counter() - t0) * 1e3
        upstream = np.concatenate(up) if up else np.zeros(0, np.float32)
        n = min(len(mine), len(upstream))
        diff = float(np.max(np.abs(mine[:n] - upstream[:n]))) if n else None
        emit({"check": "parity", "lang": lang, "words": len(text.split()), "ours_samples": len(mine),
              "upstream_samples": len(upstream), "max_abs_diff": diff,
              "match": len(mine) == len(upstream) and diff is not None and diff < 1e-3,
              "ours_total_ms": round(st.get("total_ms", 0.0), 1), "upstream_total_ms": round(up_ms, 1)})
        plain, _ = mine, st
        comp, stc = ours(tm, text, voice, lang, a.interval, compiled=True)
        m = min(len(plain), len(comp))
        emit({"check": "compiled_greedy", "lang": lang, "same_length": len(plain) == len(comp),
              "max_abs_diff": float(np.max(np.abs(plain[:m] - comp[:m]))) if m else None,
              "plain_total_ms": round(st.get("total_ms", 0.0), 1), "compiled_total_ms": round(stc.get("total_ms", 0.0), 1),
              "compiled_flag": stc.get("compiled")})


def cmd_customvoice(a):
    import mlx.core as mx
    from mlx_audio.tts.utils import load_model

    model = load_model(Path(a.model_dir))
    speakers = model.get_supported_speakers()
    spk = a.speaker or ("ryan" if "ryan" in [s.lower() for s in speakers] else speakers[0])
    emit({"check": "customvoice_load", "speakers": speakers, "speaker": spk,
          "active_gb": round(mx.get_active_memory() / 1e9, 3)})
    langs = {"en": "english", "de": "german"}
    # warmup (kernel compilation), not counted
    for _ in model.generate(text="Thanks, everyone.", voice=spk, lang_code="english", temperature=0.0):
        pass
    for path in a.sentences:
        data = json.loads(Path(path).read_text())
        lang = data["lang"]
        for it in data["items"][: a.limit or None]:
            t0 = time.perf_counter()
            audio_s = 0.0
            for r in model.generate(text=it["text"], voice=spk, lang_code=langs[lang], temperature=0.0):
                audio_s += r.samples / r.sample_rate
            ms = (time.perf_counter() - t0) * 1e3
            emit({"check": "customvoice_rtf", "id": it["id"], "lang": lang, "words": it.get("words"),
                  "audio_s": round(audio_s, 3), "total_ms": round(ms, 1),
                  "rtf": round(ms / 1e3 / audio_s, 4) if audio_s else None})
    emit({"check": "customvoice_mem", "peak_gb": round(mx.get_peak_memory() / 1e9, 3)})


def cmd_similarity(a):
    """T1 'speaker change' label: cosine similarity between the x-vector (the model's own speaker
    encoder) of each generated clip and of the reference. Flag = robust z below the median > 3
    (median - sim > 3 * 1.4826 * MAD), i.e. an outlier for this voice, not a fixed absolute cut."""
    import mlx.core as mx

    from talktalk_engine.tts import TTSModel

    tm = TTSModel("bench", a.model_dir, "local").load()

    def emb(pcm):
        e = np.array(tm._orig_extract(mx.array(pcm))).reshape(-1).astype(np.float64)
        return e / (np.linalg.norm(e) + 1e-12)

    ref = emb(read_wav(a.ref))
    rows = []
    for f in sorted(Path(a.dir).glob("*.wav")):
        pcm = read_wav(f)
        if len(pcm) < 24000 * 0.5:          # too short for a stable x-vector
            rows.append({"file": f.name, "sim": None, "too_short": True})
            continue
        rows.append({"file": f.name, "sim": round(float(ref @ emb(pcm)), 4)})
    sims = np.array([r["sim"] for r in rows if r["sim"] is not None])
    med = float(np.median(sims)) if sims.size else None
    mad = float(np.median(np.abs(sims - med))) * 1.4826 if sims.size else None
    for r in rows:
        r["speaker_change"] = bool(r["sim"] is not None and mad and (med - r["sim"]) > 3 * mad)
        emit({"check": "similarity", **r})
    emit({"check": "similarity_summary", "n": int(sims.size), "median": round(med, 4) if med else None,
          "mad": round(mad, 4) if mad else None, "flagged": sum(r["speaker_change"] for r in rows),
          "too_short": sum(1 for r in rows if r.get("too_short"))})


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("parity")
    p.add_argument("--model-dir", required=True)
    p.add_argument("--ref", required=True)
    p.add_argument("--ref-text", required=True)
    p.add_argument("--interval", type=float, default=0.16)
    c = sub.add_parser("customvoice")
    c.add_argument("--model-dir", required=True)
    c.add_argument("--sentences", nargs="+", required=True)
    c.add_argument("--speaker")
    c.add_argument("--limit", type=int, default=0)
    m = sub.add_parser("similarity")
    m.add_argument("--model-dir", required=True)
    m.add_argument("--ref", required=True)
    m.add_argument("--dir", required=True, help="directory of generated WAVs (tts_bench.py run --save-audio)")
    a = ap.parse_args()
    {"parity": cmd_parity, "customvoice": cmd_customvoice, "similarity": cmd_similarity}[a.cmd](a)


if __name__ == "__main__":
    main()
