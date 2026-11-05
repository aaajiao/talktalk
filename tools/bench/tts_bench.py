#!/usr/bin/env python3
"""M0-T1 TTS Base ICL bench through the engine's HTTP API (ARCHITECTURE.md §14, T1).

  <engine>/venv/bin/python3 -I -B tools/bench/tts_bench.py refs        # synthetic 6/8/10/12 s refs (say)
  <engine>/venv/bin/python3 -I -B tools/bench/tts_bench.py run --tts tts-qwen3-1.7b-base-8bit \
      --corpus tools/bench/corpus --out tools/bench/results/t1_<model>_<date>.jsonl [--phases A,B,C,D]
  <engine>/venv/bin/python3 -I -B tools/bench/tts_bench.py summarize <jsonl> [...]

run and t7 render the raw model (`guards: false`) unless --guards: with the guards on, retries hide
the runaways and echoes T1 labels. Rows record attempts / echo_aborts / whole / held_s either way,
and rtf uses the GPU time of every attempt (`timing.gpu_ms_all_attempts`). temperature renders
with the guards on (the product path) and records the same fields.
summarize judges runaway / short by the M0 criteria recomputed from each row (`m0_flags`) and
reports the row modes (m0 / raw / guards), so old and new files compare on one basis.

Phases (one engine per model; restart per model, never per sentence):
  A  main: ref 10 s, interval 0.16, compile off, all en+de sentences, debug (cb0/echo), ASR read-back
  B  interval 0.08 / 0.16 / 0.32 x compile off / on, 20-sentence subset, timing only
  C  ref 6 / 8 / 10 / 12 s, interval 0.16, 20-sentence subset, ASR read-back
  D  soak: 500 requests cycling the corpus, active memory before / after (growth)
  user-refs: cut user-6/8/10/12s from the enrolled take (voice/reference.wav + script.txt), see cut_candidates
  guard-cal: guards-off renders (cb0, frames, EOS) for guards_eval.py (M2 guard calibration)
  temperature --out tools/bench/results/temperature_<date>.jsonl [--temperatures 0.9,0.7,0.5] [--save-audio]:
      T1 >= 5-word (40) + T7 (60) sentences per talker temperature, x-vector cosine to reference.wav
References: until the user records their own (§9.2, `--bench enroll`), the refs are synthetic
`say -v Tingting` readings of the §9.1 script at four speaking rates; rows carry ref_kind so the
user-voice rerun is comparable. No audio is written to the repo: refs live in the bench dir,
results hold numbers and ASR read-back text of the fixed corpus sentences only.
"""
import argparse
import json
import re
import statistics
import subprocess
import sys
import time
import unicodedata
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "engine"))

import numpy as np  # noqa: E402

from talktalk_engine.client import Engine, EngineError  # noqa: E402
from talktalk_engine.tts import expected_seconds  # noqa: E402

BENCH = Path.home() / "Library/Application Support/TalkTalk-bench"
ENGINE_HOME = Path.home() / "Library/Application Support/TalkTalk/engine"
REF_TARGETS = (6, 8, 10, 12)
CJK = re.compile(r"[㐀-鿿]")


def ref_text():
    m = re.search(r'WARMUP_REF_TEXT="([^"]+)"', (ROOT / "scripts/install-engine.sh").read_text())
    if not m:
        sys.exit("cannot find WARMUP_REF_TEXT in install-engine.sh")
    return m.group(1)


def wav_seconds(p):
    with wave.open(str(p), "rb") as w:
        return w.getnframes() / w.getframerate()


def read_wav(p):
    with wave.open(str(p), "rb") as w:
        sr = w.getframerate()
        a = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768.0
    return a, sr


def say(text, rate, out):
    subprocess.run(["/usr/bin/say", "-v", "Tingting", "-r", str(int(rate)), "--file-format=WAVE",
                    "--data-format=LEI16@24000", "-o", str(out), text], check=True)


def cmd_refs(a):
    d = BENCH / "refs"
    d.mkdir(parents=True, exist_ok=True)
    text = ref_text()
    probe = d / "probe.wav"
    say(text, 175, probe)
    base = wav_seconds(probe)
    probe.unlink()
    rows = []
    for target in REF_TARGETS:
        rate = 175 * base / target
        out = d / f"synth-{target}s.wav"
        for _ in range(4):   # say's rate is not exactly linear; converge to within 0.3 s
            say(text, rate, out)
            got = wav_seconds(out)
            if abs(got - target) <= 0.3:
                break
            rate *= got / target
        (d / f"synth-{target}s.txt").write_text(text)
        rows.append({"target_s": target, "got_s": round(wav_seconds(out), 2), "rate": round(rate)})
    print(json.dumps({"refs": rows, "dir": str(d)}, ensure_ascii=False))


VOICE_DIR = Path.home() / "Library/Application Support/TalkTalk/voice"
PUNCT = "，。、；！？,.;!?"


def pauses(pcm, sr, min_ms=150, frame_ms=20):
    """Interior pauses as (start_s, end_s), from 20 ms RMS frames below max(-45 dBFS, floor + 6 dB)."""
    n = int(sr * frame_ms / 1000)
    frames = pcm[: len(pcm) // n * n].reshape(-1, n)
    db = 20 * np.log10(np.sqrt((frames ** 2).mean(axis=1)) + 1e-9)
    thr = max(-45.0, float(np.percentile(db, 10)) + 6.0)
    voiced = np.nonzero(db > thr)[0]
    if voiced.size == 0:
        return [], 0.0, 0.0
    first, last = voiced[0], voiced[-1]
    out, start = [], None
    for i in range(first, last + 1):
        if db[i] <= thr and start is None:
            start = i
        elif db[i] > thr and start is not None:
            if (i - start) * frame_ms >= min_ms:
                out.append((start * frame_ms / 1000, i * frame_ms / 1000))
            start = None
    return out, first * frame_ms / 1000, (last + 1) * frame_ms / 1000


def cut_candidates(pcm, sr, script):
    """Prefixes of the user's take that end at a punctuation mark of the fixed script (§9.1).

    The k interior punctuation marks are matched, in order, to the k longest interior pauses
    (sorted by time). The text of a prefix is the script up to and including that mark, so
    ref_text always covers exactly the audio (a partial transcript degrades ICL, research F3/#921).
    Returns [(seconds, text, end_sample)], the full take last. Empty prefix list when the take
    has fewer clear pauses than the script has marks (the mapping would be a guess)."""
    marks = [i for i, ch in enumerate(script.rstrip(PUNCT)) if ch in PUNCT]
    ps, t0, t1 = pauses(pcm, sr)
    full = (round(t1 - t0, 2), script, int(t1 * sr))
    if len(ps) < len(marks) or not marks:
        return [full], t0
    chosen = sorted(sorted(ps, key=lambda p: p[1] - p[0], reverse=True)[: len(marks)])
    out = []
    for (ps_, pe), m in zip(chosen, marks):
        end = min(pe, ps_ + 0.10)                  # keep 100 ms of the pause
        out.append((round(end - t0, 2), script[: m + 1], int(end * sr)))
    return out + [full], t0


def cmd_user_refs(a):
    """Cuts the 6/8/10/12 s T1 sweep references out of the user's enrolled take (read-only)."""
    vdir = Path(a.voice_dir)
    wav, txt = vdir / "reference.wav", vdir / "script.txt"
    if not wav.is_file() or not txt.is_file():
        sys.exit(f"no enrolled voice in {vdir} (record it with TalkTalk-Dev --bench enroll first)")
    pcm, sr = read_wav(wav)
    script = txt.read_text().strip()
    cands, t0 = cut_candidates(pcm, sr, script)
    d = BENCH / "refs"
    d.mkdir(parents=True, exist_ok=True)
    d.chmod(0o700)
    used, rows = set(), []
    for target in REF_TARGETS:
        best = min(cands, key=lambda c: abs(c[0] - target))
        if abs(best[0] - target) > 1.5 or best[0] in used:
            rows.append({"target_s": target, "available": False})
            continue
        used.add(best[0])
        seg = pcm[int(t0 * sr): best[2]]
        seg = np.concatenate([seg, np.zeros(int(0.5 * sr), np.float32)])     # +0.5 s tail silence (F3)
        out = d / f"user-{target}s.wav"
        with wave.open(str(out), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(sr)
            w.writeframes((np.clip(seg, -1, 1) * 32767).astype("<i2").tobytes())
        out.chmod(0o600)
        (d / f"user-{target}s.txt").write_text(best[1])
        rows.append({"target_s": target, "available": True, "got_s": best[0], "chars": len(best[1])})
    print(json.dumps({"take_s": cands[-1][0], "prefixes": len(cands) - 1, "refs": rows}, ensure_ascii=False))


def corpus(dirpath):
    out = []
    for lang in ("en", "de"):
        data = json.loads((Path(dirpath) / f"t1_{lang}.json").read_text())
        out += [{"id": it["id"], "text": it["text"], "words": it["words"], "lang": lang} for it in data["items"]]
    return out


def words(s):
    s = unicodedata.normalize("NFKC", s).lower()
    return re.findall(r"[\w']+", s)


def wer(ref, hyp):
    r, h = words(ref), words(hyp)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = d[j]
            d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev = cur
    return d[len(h)] / max(1, len(r))


def write_wav(path, pcm, sr=24000):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes((np.clip(pcm, -1, 1) * 32767).astype("<i2").tobytes())
    Path(path).chmod(0o600)


def private_dir(path):
    path.mkdir(parents=True, exist_ok=True)
    path.chmod(0o700)
    return path


def to16k(pcm):
    from scipy.signal import resample_poly
    return resample_poly(pcm, 2, 3).astype(np.float32)


def guard_fields(tail):
    """Per-row guard outcome: with guards on, retries hide runaways and echoes unless recorded."""
    t = tail.get("timing", {})
    return {"attempts": tail.get("attempts"), "echo_aborts": tail.get("echo_aborts"), "whole": tail.get("whole"),
            "held_s": tail.get("held_s"), "runaway": tail.get("runaway"), "short": tail.get("short"),
            "slow": tail.get("slow"), "gpu_ms_all_attempts": t.get("gpu_ms_all_attempts"), "frames": tail.get("frames")}


M0_FRAME_HZ = 12.5


def m0_cap_frames(expected_s):
    """The M0 engine's runaway cap (tts.py before 0c91692): max_frames = int(12.5 x (3 x expected + 2))."""
    return int(M0_FRAME_HZ * (3.0 * expected_s + 2.0))


def row_frames(r):
    """Frames rendered: the tail's count when the row has it (rows since 00f65f3 re-review), else
    from the audio length."""
    return r["frames"] if r.get("frames") is not None else round(r["audio_s"] * M0_FRAME_HZ)


def m0_flags(r):
    """(runaway, short) by the M0 criteria, recomputed from the row so M0 files, raw rows (the
    default since 78c5753: Policy.raw gives no runaway/short verdicts) and --guards rows are judged
    alike. M0 engine: short = audio below 0.35 x expected; runaway = the clip reached the M0 cap
    (`m0_cap_frames`), whatever cap the stream itself had. A guarded row's own runaway verdict
    (every attempt failed) also counts."""
    exp = r.get("expected_s")
    short = bool(exp) and r["audio_s"] < 0.35 * exp
    runaway = (bool(exp) and row_frames(r) >= m0_cap_frames(exp)) or bool(r.get("guards") and r.get("runaway"))
    return runaway, short


def capped_early(r):
    """No EOS, but stopped below the M0 cap (the stream's own token cap hit first): M0 cannot say
    whether it would have run away, so it is counted apart."""
    exp = r.get("expected_s")
    return r.get("eos") is False and bool(exp) and row_frames(r) < m0_cap_frames(exp)


def row_mode(r):
    """'m0' (rows from before the guards field), 'raw' or 'guards'."""
    return "m0" if "guards" not in r else ("guards" if r["guards"] else "raw")


def rtf_all_attempts(tail, audio_s):
    """GPU time of every attempt (not just the last) over the released audio."""
    t = tail.get("timing", {})
    ms = t.get("gpu_ms_all_attempts", t.get("total_ms"))
    return round(ms / 1e3 / audio_s, 4) if audio_s and ms is not None else None


class Runner:
    def __init__(self, a):
        self.a = a
        # Measurements are of the raw model unless --guards: the guards retry runaways and echoes
        # away, which would hide exactly what T1 labels.
        self.guards = bool(getattr(a, "guards", False))
        self.out = open(a.out, "a", encoding="utf-8")
        home = Path(a.engine_home)
        dirs = [home / "models", BENCH / "models"]
        log = Path.home() / "Library/Logs/TalkTalk/engine-bench-t1.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        self.eng = Engine(home / "venv/bin/python3", ROOT / "engine", dirs, roles="tts,asr", tts=a.tts, asr=a.asr,
                          warmup_dir=home / "warmup", log_path=log)
        self.voices = {}

    def emit(self, row):
        row = {"tts": self.a.tts, **row}
        self.out.write(json.dumps(row, ensure_ascii=False) + "\n")
        self.out.flush()

    def voice(self, label, wav, txt):
        if label not in self.voices:
            pcm, sr = read_wav(wav)
            if sr != 24000:
                from scipy.signal import resample_poly
                pcm = resample_poly(pcm, 24000, sr).astype(np.float32)
            t0 = time.perf_counter()
            head, blob = self.eng.build_voice(pcm, Path(txt).read_text().strip())
            build_ms = (time.perf_counter() - t0) * 1e3
            self.voices[label] = blob
            self.emit({"phase": "voice", "ref": label, "ref_s": round(len(pcm) / 24000, 2),
                       "build_client_ms": round(build_ms, 1), "build": head["ms"], "ref_frames": head["frames"]})
        t0 = time.perf_counter()
        self.eng.load_voice(self.voices[label])
        self.emit({"phase": "voice_load", "ref": label, "load_to_ready_ms": round((time.perf_counter() - t0) * 1e3, 1)})

    def one(self, phase, it, ref, interval=0.16, compiled=False, readback=False, debug=False, seed=0, save=None):
        req = {"text": it["text"], "lang": it["lang"], "seed": seed, "interval": interval, "compiled": compiled,
               "debug": debug, "guards": self.guards}
        pcm, tail, timing = self.eng.tts(req)
        t = tail["timing"]
        row = {"phase": phase, "id": it["id"], "lang": it["lang"], "words": it["words"], "ref": ref,
               "ref_kind": "synthetic" if ref.startswith("synth") else "user", "interval": interval,
               "compiled": compiled, "seed": seed, "ttfa_ms": round(timing["ttfa_ms"], 1) if timing["ttfa_ms"] else None,
               "first_byte_ms": round(timing["first_byte_ms"], 1) if timing["first_byte_ms"] else None,
               "audio_s": round(timing["audio_s"], 3), "expected_s": tail["expected_s"],
               "rtf": rtf_all_attempts(tail, timing["audio_s"]), "guards": self.guards,
               "eos": tail["eos"], **guard_fields(tail), **{f"t_{k}": v for k, v in t.items()}}
        arr = timing["chunk_arrival_ms"]
        gaps = np.diff(arr) if len(arr) > 1 else np.array([])
        row["client_gap_ms_p99"] = round(float(np.percentile(gaps, 99)), 1) if gaps.size else None
        if debug:
            row["echo"] = tail.get("echo")
            row["cb0_head"] = tail.get("cb0", [])[:16]
        if save is not None:
            write_wav(save, pcm)
        if readback and len(pcm) > 2400:
            r = self.eng.asr(to16k(pcm), hint="")
            row["readback"] = r["text"]
            row["readback_lang"] = r.get("language")
            row["readback_wer"] = round(wer(it["text"], r["text"]), 3)
            row["readback_cjk"] = bool(CJK.search(r["text"]))
        self.emit(row)
        return row

    def mem(self, label):
        h = self.eng.health()
        self.emit({"phase": "mem", "label": label, **h["mem"], "speaker_embed": h["hygiene"]["speaker_embed"],
                   "gpu": h["gpu"]})
        return h["mem"]

    def run(self):
        a = self.a
        items = corpus(a.corpus)
        subset = items[::5]
        refs = {f"synth-{s}s": (BENCH / f"refs/synth-{s}s.wav", BENCH / f"refs/synth-{s}s.txt") for s in REF_TARGETS}
        for s_ in REF_TARGETS:     # cut by `tts_bench.py user-refs` from the user's enrolled take
            if (BENCH / f"refs/user-{s_}s.wav").is_file():
                refs[f"user-{s_}s"] = (BENCH / f"refs/user-{s_}s.wav", BENCH / f"refs/user-{s_}s.txt")
        vdir = Path(a.voice_dir)
        if (vdir / "reference.wav").is_file() and (vdir / "script.txt").is_file():
            refs["voice"] = (vdir / "reference.wav", vdir / "script.txt")   # the enrolled take, read-only
        if a.user_ref:
            for spec in a.user_ref:          # label=wav:txt (the user's own recordings, §9.2)
                label, rest = spec.split("=", 1)
                wav, txt = rest.split(":", 1)
                refs[label] = (Path(wav), Path(txt))
        main_ref = a.main_ref
        phases = a.phases.split(",")
        self.eng.start(timeout=600)
        self.emit({"phase": "ready", "ready_s": round(self.eng.ready_s, 2), "ready": self.eng.ready})
        self.eng.wait_asr(timeout=600)
        self.mem("after_load")
        try:
            if main_ref not in refs:
                raise SystemExit(f"reference {main_ref!r} not found (have: {sorted(refs)})")
            if "A" in phases:
                self.voice(main_ref, *refs[main_ref])
                adir = private_dir(BENCH / "audio" / f"t1-{main_ref}") if a.save_audio else None
                for it in items:
                    self.one("A", it, main_ref, readback=True, debug=True,
                             save=(adir / f"{it['id']}.wav") if adir else None)
            if "B" in phases:
                self.voice(main_ref, *refs[main_ref])
                for interval in (0.08, 0.16, 0.32):
                    for compiled in (False, True):
                        for it in subset:
                            self.one("B", it, main_ref, interval=interval, compiled=compiled)
            if "C" in phases:
                for label in refs:
                    self.voice(label, *refs[label])
                    for it in subset:
                        self.one("C", it, label, readback=True, debug=True)
            if "D" in phases:
                self.voice(main_ref, *refs[main_ref])
                before = self.mem("soak_before")
                for i in range(a.soak):
                    self.one("D", items[i % len(items)], main_ref, seed=i)
                after = self.mem("soak_after")
                self.emit({"phase": "soak", "n": a.soak, "growth_bytes": after["active"] - before["active"]})
            self.emit({"phase": "stats", "steps": self.eng.json("GET", "/v1/stats")})
        finally:
            self.mem("end")
            self.eng.stop()


def cmd_guard_cal(a):
    """Guard calibration (M2): the T1 corpus + the T7 sentences in the enrolled voice, guards off
    (`guards: false`), seed 0. One row per clip with the full codebook-0 sequence, frames, EOS and
    audio length: numbers only, no audio. `guards_eval.py` replays the guard rules on these rows."""
    vdir = Path(a.voice_dir)
    if not (vdir / "reference.wav").is_file():
        sys.exit(f"no enrolled voice in {vdir}")
    items = corpus(a.corpus)
    for lang in ("en", "de"):
        data = json.loads((Path(a.corpus) / f"t7_{lang}.json").read_text())
        items += [{"id": it["id"], "text": it["text"], "words": len(it["text"].split()), "lang": lang}
                  for it in data["items"]]
    home = Path(a.engine_home)
    eng = Engine(home / "venv/bin/python3", ROOT / "engine", [home / "models"], roles="tts", tts=a.tts,
                 warmup_dir=home / "warmup", log_path=Path.home() / "Library/Logs/TalkTalk/engine-bench-guards.log")
    with open(a.out, "a", encoding="utf-8") as out:
        try:
            eng.start(timeout=600)
            pcm, sr = read_wav(vdir / "reference.wav")
            if sr != 24000:
                from scipy.signal import resample_poly
                pcm = resample_poly(pcm, 24000, sr).astype(np.float32)
            _, blob = eng.build_voice(pcm, (vdir / "script.txt").read_text().strip())
            eng.load_voice(blob)
            for it in items:
                audio, tail, timing = eng.tts({"text": it["text"], "lang": it["lang"], "seed": 0,
                                               "guards": False, "debug": True})
                out.write(json.dumps({"id": it["id"], "lang": it["lang"], "words": it["words"], "chars": len(it["text"]),
                                      "expected_s": tail["expected_s"], "frames": tail["frames"], "eos": tail["eos"],
                                      "audio_s": round(len(audio) / 24000, 3), "cb0": tail.get("cb0", [])}) + "\n")
                out.flush()
        finally:
            eng.stop()


def cmd_temperature(a):
    """Talker temperature sweep (voice-m2 request): the T1 sentences with >= 5 words plus all T7
    sentences, in the enrolled voice, at each temperature (default 0.9 / 0.7 / 0.5), seed 0, guards
    on (the product path). Per clip: x-vector cosine to reference.wav via /v1/voice/similarity
    (the model's own speaker encoder), plus duration, frames and guard verdicts. Numbers only, no
    audio in the repo. The last row per temperature is a summary (median, p10, min cosine). With
    --save-audio each clip is also kept at TalkTalk-bench/audio/temperature-<t>/<id>.wav (dirs 0700,
    files 0600) for voice_acoustics.py (F0 contour); rows then carry its path relative to audio/."""
    vdir = Path(a.voice_dir)
    if not (vdir / "reference.wav").is_file():
        sys.exit(f"no enrolled voice in {vdir}")
    items = [it for it in corpus(a.corpus) if it["words"] >= 5]
    for lang in ("en", "de"):
        data = json.loads((Path(a.corpus) / f"t7_{lang}.json").read_text())
        items += [{"id": it["id"], "text": it["text"], "words": len(it["text"].split()), "lang": lang}
                  for it in data["items"]]
    temps = [float(t) for t in a.temperatures.split(",")]
    home = Path(a.engine_home)
    eng = Engine(home / "venv/bin/python3", ROOT / "engine", [home / "models"], roles="tts", tts=a.tts,
                 warmup_dir=home / "warmup", log_path=Path.home() / "Library/Logs/TalkTalk/engine-bench-temperature.log")
    with open(a.out, "a", encoding="utf-8") as out:
        try:
            eng.start(timeout=600)
            ref, sr = read_wav(vdir / "reference.wav")
            if sr != 24000:
                from scipy.signal import resample_poly
                ref = resample_poly(ref, 24000, sr).astype(np.float32)
            _, blob = eng.build_voice(ref, (vdir / "script.txt").read_text().strip())
            eng.load_voice(blob)
            for t in temps:
                sims, gf = [], []
                adir = private_dir(BENCH / "audio" / f"temperature-{t:g}") if a.save_audio else None
                for it in items:
                    audio, tail, timing = eng.tts({"text": it["text"], "lang": it["lang"], "seed": 0, "temperature": t})
                    gf.append(guard_fields(tail))
                    if adir is not None:
                        write_wav(adir / f"{it['id']}.wav", audio)
                    cos = eng.similarity(ref, audio) if len(audio) >= 24000 * 0.5 else None
                    if cos is not None:
                        sims.append(cos)
                    out.write(json.dumps({"temperature": t, "id": it["id"], "lang": it["lang"], "words": it["words"],
                                          "cosine": None if cos is None else round(cos, 4),
                                          "audio_s": round(len(audio) / 24000, 3), "expected_s": tail.get("expected_s"),
                                          "frames": tail.get("frames"), "eos": tail.get("eos"),
                                          **guard_fields(tail), "rtf": rtf_all_attempts(tail, len(audio) / 24000),
                                          "wav": f"temperature-{t:g}/{it['id']}.wav" if adir else None}) + "\n")
                    out.flush()
                out.write(json.dumps({"temperature": t, "summary": True, "n": len(sims), "clips": len(gf),
                                      "runaway": sum(bool(x["runaway"]) for x in gf),
                                      "retried": sum((x["attempts"] or 1) > 1 for x in gf),
                                      "echo_aborts": sum(x["echo_aborts"] or 0 for x in gf),
                                      "cosine_median": round(statistics.median(sims), 4) if sims else None,
                                      "cosine_p10": pct(sims, 0.10), "cosine_min": round(min(sims), 4) if sims else None})
                          + "\n")
                out.flush()
        finally:
            eng.stop()


def cmd_t7(a):
    """T7 lite: blind-listening set (ICL, the enrolled voice), random order, key kept apart."""
    import random

    vdir = Path(a.voice_dir)
    if not (vdir / "reference.wav").is_file():
        sys.exit(f"no enrolled voice in {vdir}")
    items = []
    for lang in ("en", "de"):
        data = json.loads((Path(a.corpus) / f"t7_{lang}.json").read_text())
        items += [{"id": it["id"], "text": it["text"], "lang": lang} for it in data["items"][: a.n]]
    random.Random(a.seed).shuffle(items)
    out = private_dir(BENCH / "t7")
    home = Path(a.engine_home)
    eng = Engine(home / "venv/bin/python3", ROOT / "engine", [home / "models"], roles="tts,asr", tts=a.tts,
                 asr=a.asr, warmup_dir=home / "warmup",
                 log_path=Path.home() / "Library/Logs/TalkTalk/engine-bench-t7.log")
    key = []
    try:
        eng.start(timeout=600)
        eng.wait_asr(timeout=600)
        pcm, sr = read_wav(vdir / "reference.wav")
        if sr != 24000:
            from scipy.signal import resample_poly
            pcm = resample_poly(pcm, 24000, sr).astype(np.float32)
        _, blob = eng.build_voice(pcm, (vdir / "script.txt").read_text().strip())
        eng.load_voice(blob)
        for n, it in enumerate(items, 1):
            audio, tail, timing = eng.tts({"text": it["text"], "lang": it["lang"], "seed": 0, "guards": bool(a.guards)})
            name = f"{n:02d}.wav"
            write_wav(out / name, audio)
            r = eng.asr(to16k(audio), hint="") if len(audio) > 2400 else {"text": ""}
            key.append({"file": name, **it, "audio_s": round(timing["audio_s"], 2), "guards": bool(a.guards),
                        **guard_fields(tail),
                        "readback_wer": round(wer(it["text"], r["text"]), 3), "readback_cjk": bool(CJK.search(r["text"]))})
    finally:
        eng.stop()
    (out / "key.json").write_text(json.dumps(key, ensure_ascii=False, indent=1))
    (out / "key.json").chmod(0o600)
    with open(out / "scores.csv", "w", encoding="utf-8") as f:
        f.write("file,lang,sounds_like_me_1to5,accent_ok_1to5,notes\n")
        for k in key:
            f.write(f"{k['file']},{k['lang']},,,\n")
    print(json.dumps({"dir": str(out), "files": len(key),
                      "how": "listen in order, fill scores.csv (5 = sounds exactly like me / no accent); "
                             "do not open key.json until scored"}, ensure_ascii=False))


def cmd_t7_score(a):
    import csv

    out = BENCH / "t7"
    key = {k["file"]: k for k in json.loads((out / "key.json").read_text())}
    rows = list(csv.DictReader(open(out / "scores.csv", encoding="utf-8")))
    res = {}
    for lang in ("en", "de"):
        r = [x for x in rows if x["lang"] == lang and x["accent_ok_1to5"].strip()]
        if r:
            acc = [float(x["accent_ok_1to5"]) for x in r]
            like = [float(x["sounds_like_me_1to5"]) for x in r if x["sounds_like_me_1to5"].strip()]
            res[lang] = {"n": len(r), "accent_mean": round(statistics.mean(acc), 2),
                         "like_me_mean": round(statistics.mean(like), 2) if like else None,
                         "readback_wer_mean": round(statistics.mean(key[x["file"]]["readback_wer"] for x in r), 3)}
            res[lang]["decision"] = "ICL" if res[lang]["accent_mean"] >= 3 else "try x-vector, then English reference"
    print(json.dumps(res, ensure_ascii=False, indent=1))


def pct(xs, q):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    return round(xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))], 4)


def cmd_summarize(a):
    rows = [json.loads(line) for p in a.files for line in Path(p).read_text().splitlines() if line.strip()]
    out = {}
    for tts in sorted({r["tts"] for r in rows}):
        R = [r for r in rows if r["tts"] == tts]
        gen = [r for r in R if r.get("phase") in ("A", "B", "C", "D")]
        s = {}
        modes = [row_mode(r) for r in gen]
        s["mode"] = {m: modes.count(m) for m in ("m0", "raw", "guards") if m in modes}
        for key, sel in (("A", lambda r: r["phase"] == "A"), ("D", lambda r: r["phase"] == "D")):
            g = [r for r in gen if sel(r)]
            if g:
                s[key] = {"n": len(g), "ttfa_p50": pct([r["ttfa_ms"] for r in g], .5), "ttfa_p95": pct([r["ttfa_ms"] for r in g], .95),
                          "ttfa_mic_est_p50": pct([r["ttfa_ms"] + 10 for r in g if r["ttfa_ms"]], .5),
                          "ttfa_mic_est_p95": pct([r["ttfa_ms"] + 10 for r in g if r["ttfa_ms"]], .95),
                          "rtf_p50": pct([r["rtf"] for r in g], .5), "rtf_p95": pct([r["rtf"] for r in g], .95),
                          # the T1 bound: RTF p95 over clauses of >=5 words (ARCHITECTURE.md decision table)
                          "rtf_p95_ge5w": pct([r["rtf"] for r in g if r["words"] >= 5], .95),
                          "frame_ms_p99": pct([r["t_frame_ms_p99"] for r in g], .99),
                          "first_chunk_ms_p99": pct([r["t_first_chunk_ms"] for r in g], .99),
                          "gap_p99_max": pct([r["t_chunk_gap_ms_p99"] for r in g], 1.0)}
        B = {}
        for r in gen:
            if r["phase"] == "B":
                B.setdefault(f'{r["interval"]}/{"comp" if r["compiled"] else "plain"}', []).append(r)
        s["B"] = {k: {"n": len(v), "ttfa_p50": pct([r["ttfa_ms"] for r in v], .5), "ttfa_p95": pct([r["ttfa_ms"] for r in v], .95),
                      "rtf_p50": pct([r["rtf"] for r in v], .5), "rtf_p95": pct([r["rtf"] for r in v], .95),
                      "frame_ms_p50": pct([r["t_frame_ms_p50"] for r in v], .5)} for k, v in sorted(B.items())}
        C = {}
        for r in gen:
            if r["phase"] == "C":
                C.setdefault(r["ref"], []).append(r)
        s["C"] = {k: {"n": len(v), "ttfa_p50": pct([r["ttfa_ms"] for r in v], .5), "ttfa_p95": pct([r["ttfa_ms"] for r in v], .95),
                      "rtf_p95": pct([r["rtf"] for r in v], .95), "prefill_ms_p50": pct([r["t_prefill_ms"] for r in v], .5),
                      "wer_mean": round(statistics.mean(r["readback_wer"] for r in v if "readback_wer" in r), 3)
                      if any("readback_wer" in r for r in v) else None} for k, v in C.items()}
        rb = [r for r in gen if "readback_wer" in r]
        if rb:
            bad = [r for r in rb if any(m0_flags(r)) or r["readback_cjk"] or r["readback_wer"] > 0.5]
            s["readback"] = {"n": len(rb), "flagged": len(bad), "flagged_rate": round(len(bad) / len(rb), 4),
                             "criteria": "M0: runaway (reached int(12.5 x (3 x expected + 2)) frames), short (<0.35 x expected), CJK echo, WER > 0.5",
                             "runaway_m0": sum(m0_flags(r)[0] for r in rb), "short_m0": sum(m0_flags(r)[1] for r in rb),
                             "capped_early": sum(capped_early(r) for r in rb),
                             "cjk_echo": sum(r["readback_cjk"] for r in rb),
                             "wer_mean": {lang: round(statistics.mean(r["readback_wer"] for r in rb if r["lang"] == lang), 3)
                                          for lang in ("en", "de") if any(r["lang"] == lang for r in rb)},
                             "flagged_ids": [f'{r["phase"]}:{r["ref"]}:{r["id"]}' for r in bad][:40]}
            good = [r for r in rb if not m0_flags(r)[0] and r["readback_wer"] <= 0.2]
            fit = {}
            for lang in ("en", "de"):
                g = [r for r in good if r["lang"] == lang]
                if len(g) >= 5:
                    x = np.array([r["words"] for r in g], float)
                    y = np.array([r["audio_s"] for r in g], float)
                    b, c = np.polyfit(x, y, 1)
                    ratio = y / np.array([expected_seconds("w " * int(w), lang) for w in x])
                    fit[lang] = {"intercept_s": round(float(c), 3), "s_per_word": round(float(b), 3),
                                 "ratio_vs_current_p005": round(float(np.percentile(ratio, 0.5)), 3),
                                 "ratio_vs_current_p995": round(float(np.percentile(ratio, 99.5)), 3)}
            s["expected_fit"] = fit
            echo_rows = [r for r in rb if r.get("echo")]
            if echo_rows:
                lab = [r["readback_cjk"] for r in echo_rows]
                s["echo_detector"] = {"positives": sum(lab), "n": len(lab), "note":
                                      "too few positives to calibrate" if sum(lab) < 5 else "calibrate threshold offline"}
        mems = [r for r in R if r.get("phase") == "mem"]
        soak = [r for r in R if r.get("phase") == "soak"]
        s["mem"] = {m["label"]: {"active_gb": round(m["active"] / 1e9, 3), "peak_gb": round(m["peak"] / 1e9, 3)} for m in mems}
        if soak:
            s["soak_growth_mb"] = round(soak[-1]["growth_bytes"] / 1e6, 1)
        out[tts] = s
    print(json.dumps(out, ensure_ascii=False, indent=1))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("refs")
    u = sub.add_parser("user-refs")
    u.add_argument("--voice-dir", default=str(VOICE_DIR))
    r = sub.add_parser("run")
    r.add_argument("--engine-home", default=str(ENGINE_HOME))
    r.add_argument("--tts", required=True)
    r.add_argument("--asr", default="asr-qwen3-0.6b-8bit")
    r.add_argument("--corpus", default=str(ROOT / "tools/bench/corpus"))
    r.add_argument("--phases", default="A,B,C,D")
    r.add_argument("--main-ref", default="synth-10s")
    r.add_argument("--user-ref", action="append", help="label=wav:txt (the user's own reference)")
    r.add_argument("--soak", type=int, default=500)
    r.add_argument("--voice-dir", default=str(VOICE_DIR))
    r.add_argument("--save-audio", action="store_true", help="keep phase-A audio in the bench dir (similarity)")
    r.add_argument("--guards", action="store_true", help="render with the engine guards on (default: raw model)")
    r.add_argument("--out", required=True)
    t7 = sub.add_parser("t7")
    t7.add_argument("--engine-home", default=str(ENGINE_HOME))
    t7.add_argument("--tts", default="tts-qwen3-1.7b-base-8bit")
    t7.add_argument("--asr", default="asr-qwen3-0.6b-8bit")
    t7.add_argument("--corpus", default=str(ROOT / "tools/bench/corpus"))
    t7.add_argument("--voice-dir", default=str(VOICE_DIR))
    t7.add_argument("--n", type=int, default=10)
    t7.add_argument("--seed", type=int, default=7)
    t7.add_argument("--guards", action="store_true", help="render with the engine guards on (default: raw model)")
    sub.add_parser("t7-score")
    g = sub.add_parser("guard-cal")
    g.add_argument("--engine-home", default=str(ENGINE_HOME))
    g.add_argument("--tts", default="tts-qwen3-1.7b-base-8bit")
    g.add_argument("--corpus", default=str(ROOT / "tools/bench/corpus"))
    g.add_argument("--voice-dir", default=str(VOICE_DIR))
    g.add_argument("--out", required=True)
    tp = sub.add_parser("temperature")
    tp.add_argument("--engine-home", default=str(ENGINE_HOME))
    tp.add_argument("--tts", default="tts-qwen3-1.7b-base-8bit")
    tp.add_argument("--corpus", default=str(ROOT / "tools/bench/corpus"))
    tp.add_argument("--voice-dir", default=str(VOICE_DIR))
    tp.add_argument("--temperatures", default="0.9,0.7,0.5")
    tp.add_argument("--save-audio", action="store_true",
                    help="keep the clips in TalkTalk-bench/audio/temperature-<t>/ (F0 analysis; never in the repo)")
    tp.add_argument("--out", required=True)
    s = sub.add_parser("summarize")
    s.add_argument("files", nargs="+")
    a = ap.parse_args()
    if a.cmd == "refs":
        cmd_refs(a)
    elif a.cmd == "user-refs":
        cmd_user_refs(a)
    elif a.cmd == "t7":
        cmd_t7(a)
    elif a.cmd == "t7-score":
        cmd_t7_score(a)
    elif a.cmd == "guard-cal":
        cmd_guard_cal(a)
    elif a.cmd == "temperature":
        cmd_temperature(a)
    elif a.cmd == "run":
        try:
            Runner(a).run()
        except EngineError as e:
            sys.exit(f"engine error: {e}")
    else:
        cmd_summarize(a)


if __name__ == "__main__":
    main()
