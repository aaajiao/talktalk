#!/usr/bin/env python3
"""Installer smoke run (ARCHITECTURE.md §7.3 steps 2-7). install.json is written only if this passes.

  venv/bin/python3 -I -B smoke_engine.py --engine-home <engine> --engine-src <src> --profile max \
      --tts <key> [--asr <key>]

Uses only the synthetic `say` references in <engine>/warmup (never a real person's voice).
Prints one JSON summary line on stdout; exit 0 on pass.
"""
import argparse
import json
import os
import subprocess
import sys
import time
import unicodedata
import wave
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np  # noqa: E402

from talktalk_engine.client import Engine  # noqa: E402
from talktalk_engine.tts import expected_seconds  # noqa: E402


def read_wav(path):
    with wave.open(str(path), "rb") as w:
        sr = w.getframerate()
        a = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768.0
    return a, sr


def cer(ref, hyp):
    norm = lambda s: [c for c in unicodedata.normalize("NFKC", s) if not unicodedata.category(c).startswith(("P", "Z"))]  # noqa: E731
    r, h = norm(ref), norm(hyp)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = d[j]
            d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev = cur
    return d[len(h)] / max(1, len(r))


def lsof_ok(pid, port):
    out = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-i", "-p", str(pid)], capture_output=True, text=True).stdout
    listens, bad = [], []
    for line in out.splitlines()[1:]:
        name = line.split()[-2] if line.endswith(")") else line.split()[-1]
        if "(LISTEN)" in line:
            listens.append(name)
        elif not (name.startswith("127.0.0.1:") or "->127.0.0.1:" in name):
            bad.append(name)
    return listens == [f"127.0.0.1:{port}"] and not bad, {"listen": listens, "other": bad}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine-home", required=True)
    ap.add_argument("--engine-src", required=True)
    ap.add_argument("--profile", default="max")
    ap.add_argument("--tts", required=True)
    ap.add_argument("--asr", default="")
    a = ap.parse_args()
    home = Path(a.engine_home)
    warm = home / "warmup"
    roles = "tts,asr" if a.asr else "tts"
    result = {"profile": a.profile, "roles": roles, "ok": False}
    eng = Engine(home / "venv/bin/python3", a.engine_src, [home / "models"], roles=roles, tts=a.tts,
                 asr=a.asr or None, warmup_dir=warm,
                 cache_dir=Path.home() / "Library/Caches/TalkTalk",
                 log_path=Path.home() / "Library/Logs/TalkTalk/engine-install.log")
    Path.home().joinpath("Library/Logs/TalkTalk").mkdir(parents=True, exist_ok=True)
    try:
        eng.start()
        result["ready_s"] = round(eng.ready_s, 2)
        if a.asr:
            eng.wait_asr()
            pcm, sr = read_wav(warm / "sample-zh.wav")
            assert sr == 16000, "sample must be 16 kHz"
            r = eng.asr(pcm, hint="zh")
            ref = (warm / "sample-zh.txt").read_text()
            result["asr_cer"] = round(cer(ref, r["text"]), 3)
            assert result["asr_cer"] <= 0.15, f"ASR CER {result['asr_cer']} > 0.15"
        ref_pcm, sr = read_wav(warm / "ref-zh.wav")
        assert sr == 24000, "warmup reference must be 24 kHz"
        _, blob = eng.build_voice(ref_pcm, (warm / "ref-zh.txt").read_text().strip())
        eng.load_voice(blob)
        result["tts"] = {}
        for lang, text in (("en", "Thanks, everyone. Let me quickly walk you through where the project stands today."),
                           ("de", "Danke Ihnen allen. Ich gebe Ihnen kurz einen Überblick über den aktuellen Stand des Projekts.")):
            pcm, tail, timing = eng.tts({"text": text, "lang": lang, "seed": 0})
            exp = expected_seconds(text, lang)
            ratio = timing["audio_s"] / exp
            result["tts"][lang] = {"audio_s": round(timing["audio_s"], 2), "ratio": round(ratio, 2),
                                   "rtf": round(tail["timing"]["total_ms"] / 1e3 / max(1e-6, timing["audio_s"]), 3)}
            assert 0.7 <= ratio <= 1.4, f"{lang}: duration ratio {ratio:.2f} outside 0.7-1.4"
        ok, detail = lsof_ok(eng.pid, eng.port)
        result["lsof"] = detail
        assert ok, f"unexpected sockets: {detail}"
        t = time.perf_counter()
        eng.proc.stdin.close()
        try:
            eng.proc.wait(1.0)
        except Exception:  # noqa: BLE001
            raise AssertionError("engine did not exit within 1 s of stdin EOF")
        result["exit_after_eof_ms"] = round((time.perf_counter() - t) * 1e3)
        result["ok"] = True
    except Exception as e:  # noqa: BLE001
        result["error"] = f"{type(e).__name__}: {e}"
    finally:
        eng.stop()
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
