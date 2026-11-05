#!/usr/bin/env python3
"""Acoustic features of cloned clips against the user's reference (voice-m2, "sounds like me").

  <engine>/venv/bin/python3 -I -B tools/bench/voice_acoustics.py t7 --out tools/bench/results/t7lite_acoustics_<date>.jsonl
  <engine>/venv/bin/python3 -I -B tools/bench/voice_acoustics.py t1 \
      --sim tools/bench/results/t1lite_voice_similarity_<date>.jsonl --out tools/bench/results/t1lite_acoustics_<date>.jsonl
  <engine>/venv/bin/python3 -I -B tools/bench/voice_acoustics.py temperature \
      --sweep tools/bench/results/temperature_<date>.jsonl --out tools/bench/results/temperature_acoustics_<date>.jsonl

`temperature` reads the rows of `tts_bench.py temperature --save-audio` (clips under
TalkTalk-bench/audio/temperature-<t>/), prints one line per temperature and applies the adoption
rule of m0-results ("Sounds like me" within ICL, step 1) against the first (baseline) temperature.

Per clip: F0 median (autocorrelation, 40 ms frames, 70–400 Hz) and its offset from the reference in
semitones, F0 spread (p90 − p10), pace (s per word), spectral tilt (energy > 3 kHz over < 1 kHz, dB)
and speech RMS. Joined with the user's T7 scores or T1's x-vector similarity, then Pearson and
partial correlations are printed. Reads audio from the bench dir and voice/reference.wav; writes
numbers only (no audio, no text) to --out. CPU only; no engine, no GPU.
"""
import argparse
import csv
import json
import os
import wave
from pathlib import Path

import statistics

SUPPORT = Path(os.path.expanduser("~/Library/Application Support"))
BENCH = SUPPORT / "TalkTalk-bench"
VOICE = SUPPORT / "TalkTalk" / "voice"
CORPUS = Path(__file__).resolve().parent / "corpus"


def _np():
    import numpy as np   # audio features only; the sweep rules and their tests need no numpy
    return np


def load(path):
    np = _np()
    with wave.open(str(path)) as w:
        sr = w.getframerate()
        a = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
    return a, sr


def f0_track(a, sr):
    np = _np()
    fr, hop = int(0.04 * sr), int(0.01 * sr)
    lo, hi = int(sr / 400), int(sr / 70)
    out = []
    for i in range(0, len(a) - fr, hop):
        x = a[i:i + fr] - a[i:i + fr].mean()
        if np.sqrt((x * x).mean()) < 0.01:
            continue
        ac = np.correlate(x, x, "full")[fr - 1:]
        k = lo + int(np.argmax(ac[lo:hi]))
        if ac[k] / (ac[0] + 1e-9) > 0.45:
            out.append(sr / k)
    return np.array(out)


def features(a, sr, ref_f0=None):
    np = _np()
    f0 = f0_track(a, sr)
    fr = int(0.02 * sr)
    r = np.array([np.sqrt((a[i:i + fr] ** 2).mean()) for i in range(0, len(a) - fr, fr)])
    s = r[r > 10 ** (-40 / 20)]
    n = 1024
    spec = [np.abs(np.fft.rfft(a[i:i + n] * np.hanning(n))) ** 2
            for i in range(0, len(a) - n, n // 2) if np.sqrt((a[i:i + n] ** 2).mean()) >= 0.01]
    tilt = None
    if spec:
        S, f = np.mean(spec, axis=0), np.fft.rfftfreq(n, 1 / sr)
        tilt = round(float(10 * np.log10(S[f > 3000].sum() / S[f < 1000].sum())), 2)
    med = float(np.median(f0)) if len(f0) else None
    return {
        "seconds": round(len(a) / sr, 3),
        "f0_median_hz": round(med, 1) if med else None,
        "f0_st_vs_ref": round(12 * np.log2(med / ref_f0), 2) if med and ref_f0 else None,
        "f0_spread_hz": round(float(np.percentile(f0, 90) - np.percentile(f0, 10)), 1) if len(f0) else None,
        "tilt_db": tilt,
        "speech_rms_dbfs": round(float(20 * np.log10(np.sqrt((s ** 2).mean()))), 2) if len(s) else None,
    }


def pearson(x, y):
    np = _np()
    x, y = np.asarray(x, float), np.asarray(y, float)
    return float(np.corrcoef(x, y)[0, 1]) if len(x) > 2 and x.std() > 0 and y.std() > 0 else float("nan")


def partial(x, y, z):
    np = _np()
    rxy, rxz, ryz = pearson(x, y), pearson(x, z), pearson(y, z)
    return (rxy - rxz * ryz) / np.sqrt((1 - rxz ** 2) * (1 - ryz ** 2))


def report(rows, target):
    np = _np()
    rows = [r for r in rows if r.get(target) is not None and r["f0_median_hz"] and r.get("s_per_word")]
    for lang in ("en", "de", None):
        g = [r for r in rows if lang is None or r["lang"] == lang]
        if len(g) < 4:
            continue
        t = [r[target] for r in g]
        line = [f"{lang or 'all'} n={len(g)}"]
        for k in ("f0_st_vs_ref", "f0_spread_hz", "s_per_word", "tilt_db", "speech_rms_dbfs"):
            line.append(f"{k} r={pearson(t, [r[k] for r in g]):+.2f}")
        f0, pace = [r["f0_st_vs_ref"] for r in g], [r["s_per_word"] for r in g]
        line.append(f"partial f0|pace {partial(t, f0, pace):+.2f}, pace|f0 {partial(t, pace, f0):+.2f}")
        print("  ".join(line))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("set", choices=["t7", "t1", "temperature"])
    ap.add_argument("--sweep", help="tts_bench.py temperature jsonl (with --save-audio)")
    ap.add_argument("--ref", default=str(VOICE / "reference.wav"))
    ap.add_argument("--sim", help="T1 similarity jsonl (tts_inproc.py similarity)")
    ap.add_argument("--min-words", type=int, default=5)
    ap.add_argument("--out")
    a = ap.parse_args()

    ref, rsr = load(a.ref)
    rf = features(ref, rsr)
    ref_f0 = rf["f0_median_hz"]
    print(f"reference: f0 {ref_f0} Hz, spread {rf['f0_spread_hz']} Hz, tilt {rf['tilt_db']} dB")
    rows = []
    if a.set == "temperature":
        return temperature(a, ref_f0, rf)
    if a.set == "t7":
        d = BENCH / "t7"
        key = {k["file"]: k for k in json.loads((d / "key.json").read_text())}
        for s in csv.DictReader(open(d / "scores.csv")):
            k = key[s["file"]]
            x, sr = load(d / s["file"])
            words = len(k["text"].split())
            rows.append({"id": k["id"], "lang": k["lang"], "words": words, "sounds_like_me": int(s["sounds_like_me_1to5"]),
                         "s_per_word": round(k["audio_s"] / words, 3), **features(x, sr, ref_f0)})
        target = "sounds_like_me"
    else:
        words = {}
        for lang in ("en", "de"):
            for it in json.loads((CORPUS / f"t1_{lang}.json").read_text())["items"]:
                words[it["id"]] = it["words"]
        sims = {}
        for line in open(a.sim):
            if line.startswith("{"):
                j = json.loads(line)
                if j.get("sim") is not None:
                    sims[j["file"][:-4]] = j["sim"]
        for cid, sim in sorted(sims.items()):
            if words.get(cid, 0) < a.min_words:
                continue
            x, sr = load(BENCH / "audio" / "t1-voice" / f"{cid}.wav")
            f = features(x, sr, ref_f0)
            rows.append({"id": cid, "lang": cid[3:5], "words": words[cid], "similarity": sim,
                         "s_per_word": round(f["seconds"] / words[cid], 3), **f})
        target = "similarity"
    report(rows, target)
    if a.out:
        with open(a.out, "w") as fh:
            fh.write(json.dumps({"reference": rf}) + "\n")
            for r in rows:
                fh.write(json.dumps(r) + "\n")


# Adoption rule (m0-results, plan step 1): against the baseline, median F0 spread −20 % or more and
# median cosine +0.005 or more, with no runaway and no short clip, and no more guard retries, echo
# aborts or silent clips than the baseline (a guard retry hides a runaway from the runaway count).
# Read-back WER is not part of the sweep; the audition check (WER ≤ 15 %) still runs on the chosen
# setting before it ships.
SPREAD_DROP = 0.20
COSINE_GAIN = 0.005
SILENT_S = 0.05


def sweep_rows(lines):
    """Clip rows of a `tts_bench.py temperature` jsonl, one per (temperature, id): the file is
    appended to, so a rerun on the same day repeats rows; the last one wins."""
    out = {}
    for line in lines:
        line = line.strip()
        if not line.startswith("{"):
            continue
        j = json.loads(line)
        if j.get("summary") or j.get("wav") is None:
            continue
        out[(j["temperature"], j["id"])] = j
    return list(out.values())


def silent(r):
    return r.get("audio_s") is not None and r["audio_s"] <= SILENT_S


def _med(rows, k):
    v = [r[k] for r in rows if r.get(k) is not None]
    return float(statistics.median(v)) if v else None


def summarize(rows):
    """Measured rows (features joined) → {temperature: summary}. Silent clips are counted, not
    measured: they stay out of the F0, spread and pace medians."""
    groups = {}
    for r in rows:
        groups.setdefault(r["temperature"], []).append(r)
    summary = {}
    for t, g in groups.items():
        voiced = [r for r in g if not silent(r)]
        summary[t] = {"n": len(g), "f0_st_vs_ref": _med(voiced, "f0_st_vs_ref"), "f0_spread_hz": _med(voiced, "f0_spread_hz"),
                      "share_f0_over_1st": round(sum((r.get("f0_st_vs_ref") or 0) > 1 for r in voiced) / max(1, len(voiced)), 3),
                      "s_per_word": _med(voiced, "s_per_word"), "cosine": _med(g, "cosine"),
                      "runaway": sum(bool(r.get("runaway")) for r in g), "short": sum(bool(r.get("short")) for r in g),
                      "retried": sum((r.get("attempts") or 1) > 1 for r in g),
                      "echo": sum((r.get("echo_aborts") or 0) > 0 for r in g),
                      "silent": sum(silent(r) for r in g)}
    return summary


def adopt(summary, base_t):
    """Marks `passes_rule` on every non-baseline temperature; returns the lowest that passes."""
    base = summary[base_t]
    adopted = None
    for t in sorted(summary):
        if t == base_t:
            continue
        s = summary[t]
        ok = (s["f0_spread_hz"] is not None and base["f0_spread_hz"] is not None
              and s["f0_spread_hz"] <= base["f0_spread_hz"] * (1 - SPREAD_DROP)
              and s["cosine"] is not None and base["cosine"] is not None
              and s["cosine"] >= base["cosine"] + COSINE_GAIN and s["runaway"] == 0 and s["short"] == 0
              and all(s[k] <= base[k] for k in ("retried", "echo", "silent")))
        s["passes_rule"] = ok
        if ok and adopted is None:
            adopted = t   # sorted ascending: the lowest temperature that passes
    return adopted


def temperature(a, ref_f0, rf):
    rows = []
    order = []
    for j in sweep_rows(open(a.sweep)):
        if j["temperature"] not in order:
            order.append(j["temperature"])
        r = {"temperature": j["temperature"], "id": j["id"], "lang": j["lang"], "words": j["words"],
             "cosine": j.get("cosine"), "runaway": bool(j.get("runaway")), "short": bool(j.get("short")),
             "attempts": j.get("attempts"), "echo_aborts": j.get("echo_aborts"), "audio_s": j.get("audio_s")}
        if not silent(r):
            x, sr = load(BENCH / "audio" / j["wav"])
            f = features(x, sr, ref_f0)
            r.update(f)
            r["s_per_word"] = round(f["seconds"] / max(1, j["words"]), 3)
        rows.append(r)
    if not rows:
        raise SystemExit("no rows with audio: run tts_bench.py temperature with --save-audio")
    summary = summarize(rows)
    for t in order:
        s = summary[t]
        print(f"t={t:g} n={s['n']} f0 {s['f0_st_vs_ref']:+.2f} st, spread {s['f0_spread_hz']:.1f} Hz, "
              f">+1 st {s['share_f0_over_1st']:.0%}, {s['s_per_word']:.3f} s/word, cosine {s['cosine']}, "
              f"runaway {s['runaway']}, short {s['short']}, retried {s['retried']}, echo {s['echo']}, silent {s['silent']}")
    base_t = order[0]
    adopted = adopt(summary, base_t)
    print(f"baseline t={base_t:g}; adopt: {adopted if adopted is not None else 'none (keep the baseline)'}")
    if a.out:
        with open(a.out, "w") as fh:
            fh.write(json.dumps({"reference": rf, "baseline": base_t, "adopt": adopted,
                                 "summary": {f"{t:g}": summary[t] for t in order}}) + "\n")
            for r in rows:
                fh.write(json.dumps(r) + "\n")


if __name__ == "__main__":
    main()
