#!/usr/bin/env python3
"""M0-T2 GPU topology and M0-T3 non-preemptible step bounds (ARCHITECTURE.md §14, §6.1).

  <engine>/venv/bin/python3 -I -B tools/bench/corun_bench.py --topology A --horizons 1000,1500,2000 \
      --minutes 10 --ref "$V/reference.wav:$V/script.txt" --out tools/bench/results/t2_<date>.jsonl
  (V = ~/Library/Application Support/TalkTalk/voice, the enrolled voice; without --ref the synthetic
  warmup reference is used and rows say ref_kind "synthetic")

Load (T2 row): TTS renders clauses back to back while a simulated player drains them in real time
and reports bufferedMs to /v1/playout every 50 ms (the app's PlayoutStage does the same), so the
render horizon and the 250 ms / admission rules are live; meanwhile an ASR segment (1.5-6 s,
rotating) is sent every 1.5 s at SPEAK priority (P1). SPEAK is marked active (P2 paused).
Topologies:
  A  one engine, one GPU thread, cooperative EDF (the design)
  B  one engine, ASR on a second MLX thread (`--asr-thread separate`)
  C  two engines: roles=tts and roles=asr (two processes)
Per (topology, horizon) it writes one JSON summary line:
  underruns (buffer hit 0 inside a clause after its first chunk), lead_min_ms (min buffer inside
  clauses), asr whole-call p50/p95/p99, and T3 per-step p99 from /v1/stats.
Pass (A): underruns 0, lead_min >= 150 ms, ASR p95 <= 250 ms; T3: every step kind p99 <= 150 ms.
Uses only the synthetic warmup references unless --ref is given. Runs outside the sandbox (Metal).
"""
import argparse
import json
import sys
import threading
import time
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "engine"))

import numpy as np  # noqa: E402

from talktalk_engine.client import Engine  # noqa: E402

ENGINE_HOME = Path.home() / "Library/Application Support/TalkTalk/engine"
BENCH = Path.home() / "Library/Application Support/TalkTalk-bench"


def read_wav(p):
    with wave.open(str(p), "rb") as w:
        sr = w.getframerate()
        a = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768.0
    return a, sr


def pct(xs, q):
    xs = sorted(xs)
    return round(xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))], 2) if xs else None


class Player:
    """Real-time drain of received TTS audio; reports bufferedMs like PlayoutStage."""

    def __init__(self):
        self.lock = threading.Lock()
        self.received_ms = 0.0
        self.played_ms = 0.0
        self.t_last = None
        self.in_clause = False
        self.clause_started = False
        self.underruns = 0
        self._was_empty = False
        self.lead_min = None
        self.lead_samples = []

    def _advance(self, now):
        if self.t_last is not None:
            self.played_ms = min(self.received_ms, self.played_ms + (now - self.t_last) * 1e3)
        self.t_last = now

    def buffered(self):
        with self.lock:
            now = time.perf_counter()
            self._advance(now)
            b = self.received_ms - self.played_ms
            if self.in_clause and self.clause_started:
                if b <= 0.0 and not self._was_empty:
                    self.underruns += 1
                self._was_empty = b <= 0.0
                self.lead_min = b if self.lead_min is None else min(self.lead_min, b)
                self.lead_samples.append(b)
            return b

    def add(self, samples):
        with self.lock:
            self._advance(time.perf_counter())
            self.received_ms += samples / 24.0
            self.clause_started = True
            self._was_empty = False

    def begin(self):
        with self.lock:
            self.in_clause, self.clause_started, self._was_empty = True, False, False

    def end(self):
        with self.lock:
            self.in_clause = False


def ref_kind(ref):
    """'synthetic' (warmup reference), 'user' (the enrolled voice under TalkTalk/voice) or 'custom'."""
    if not ref:
        return "synthetic"
    return "user" if "/TalkTalk/voice/" in ref.split(":", 1)[0] else "custom"


def run_one(a, topology, horizon):
    home = Path(a.engine_home)
    py, src, dirs = home / "venv/bin/python3", ROOT / "engine", [home / "models", BENCH / "models"]
    log = Path.home() / f"Library/Logs/TalkTalk/engine-bench-t2-{topology}.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    hz = ["--horizon-ms", str(horizon)]
    if topology == "C":
        tts_eng = Engine(py, src, dirs, roles="tts", tts=a.tts, warmup_dir=home / "warmup", log_path=log, extra_args=hz)
        asr_eng = Engine(py, src, dirs, roles="asr", asr=a.asr, log_path=log, extra_args=hz)
        engines = [tts_eng, asr_eng]
    else:
        extra = hz + (["--asr-thread", "separate"] if topology == "B" else [])
        tts_eng = asr_eng = Engine(py, src, dirs, roles="tts,asr", tts=a.tts, asr=a.asr, warmup_dir=home / "warmup",
                                   log_path=log, extra_args=extra)
        engines = [tts_eng]
    for e in engines:
        e.start(timeout=600)
    try:
        asr_eng.wait_asr(timeout=600)
        ref_wav, ref_txt = (a.ref.split(":", 1) if a.ref else (home / "warmup/ref-zh.wav", home / "warmup/ref-zh.txt"))
        ref, _ = read_wav(ref_wav)
        _, blob = tts_eng.build_voice(ref, Path(ref_txt).read_text().strip())
        tts_eng.load_voice(blob)
        sample, _ = read_wav(home / "warmup/sample-zh.wav")
        long_zh = np.tile(sample, 3)
        seg_lengths = [1.5, 3.0, 4.5, 6.0]
        items = []
        for lang in ("en", "de"):
            data = json.loads((Path(a.corpus) / f"t1_{lang}.json").read_text())
            items += [{"text": it["text"], "lang": lang} for it in data["items"] if it["words"] >= 4]
        for e in engines:
            e.json("POST", "/v1/session", {"speak_active": True}, expect=(204,))
        stop = threading.Event()
        player = Player()
        asr_ms, asr_lag, tts_err = [], [], []

        def reporter():
            while not stop.is_set():
                b = player.buffered()
                try:
                    tts_eng.request("POST", "/v1/playout", {"bufferedMs": round(b, 1)}, timeout=5)
                except OSError:
                    pass
                time.sleep(0.05)

        def asr_loop():
            k, due = 0, time.perf_counter()
            while not stop.is_set():
                now = time.perf_counter()
                if now < due:
                    time.sleep(min(0.05, due - now))
                    continue
                asr_lag.append((now - due) * 1e3)
                secs = seg_lengths[k % len(seg_lengths)]
                k += 1
                r = asr_eng.asr(long_zh[: int(secs * 16000)], hint="zh", priority=1)
                asr_ms.append(r["client_ms"])
                due += 1.5

        def tts_loop():
            k = 0
            while not stop.is_set():
                it = items[k % len(items)]
                k += 1
                player.begin()
                try:
                    tts_eng.tts({"text": it["text"], "lang": it["lang"], "seed": k},
                                on_chunk=lambda arr, now: player.add(len(arr)))
                except Exception as e:  # noqa: BLE001
                    tts_err.append(str(e)[:200])
                player.end()

        threads = [threading.Thread(target=f, daemon=True) for f in (reporter, asr_loop, tts_loop)]
        t0 = time.perf_counter()
        for t in threads:
            t.start()
        stop.wait(a.minutes * 60)
        stop.set()
        for t in threads:
            t.join(timeout=30)
        steps = {}
        for e in engines:
            steps.update(e.json("GET", "/v1/stats")["steps"])
        health = [e.health()["gpu"] for e in engines]
        t3_kinds = {k: v["p99"] for k, v in steps.items()}
        row = {"test": "T2", "topology": topology, "horizon_ms": horizon, "minutes": round((time.perf_counter() - t0) / 60, 2),
               "tts": a.tts, "asr": a.asr, "ref_kind": ref_kind(a.ref), "ref": Path(str(ref_wav)).name,
               "underruns": player.underruns,
               "lead_min_ms": round(player.lead_min, 1) if player.lead_min is not None else None,
               "lead_p05_ms": pct(player.lead_samples, 0.05), "lead_max_ms": pct(player.lead_samples, 1.0), "audio_s": round(player.received_ms / 1e3, 1),
               "asr_n": len(asr_ms), "asr_p50_ms": pct(asr_ms, 0.5), "asr_p95_ms": pct(asr_ms, 0.95),
               "asr_p99_ms": pct(asr_ms, 0.99), "asr_lag_p95_ms": pct(asr_lag, 0.95), "tts_errors": tts_err[:5],
               "t3_step_p99_ms": t3_kinds, "steps": steps, "gpu": health}
        row["pass_t2"] = (row["underruns"] == 0 and (row["lead_min_ms"] or 0) >= 150
                          and (row["asr_p95_ms"] or 1e9) <= 250 and not tts_err)
        row["pass_t3"] = all(v <= 150 for v in t3_kinds.values())
        return row
    finally:
        for e in engines:
            e.stop()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine-home", default=str(ENGINE_HOME))
    ap.add_argument("--topology", default="A", help="A, B, C or a comma list")
    ap.add_argument("--horizons", default="1000,1500,2000")
    ap.add_argument("--minutes", type=float, default=10.0)
    ap.add_argument("--tts", default="tts-qwen3-1.7b-base-8bit")
    ap.add_argument("--asr", default="asr-qwen3-0.6b-8bit")
    ap.add_argument("--ref", help="wav:txt reference (default: the synthetic warmup reference)")
    ap.add_argument("--corpus", default=str(ROOT / "tools/bench/corpus"))
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    with open(a.out, "a", encoding="utf-8") as out:
        for topo in a.topology.split(","):
            for h in (float(x) for x in a.horizons.split(",")):
                row = run_one(a, topo.strip(), h)
                out.write(json.dumps(row, ensure_ascii=False) + "\n")
                out.flush()
                print(json.dumps({k: row[k] for k in ("topology", "horizon_ms", "underruns", "lead_min_ms",
                                                      "asr_p95_ms", "pass_t2", "pass_t3")}), flush=True)


if __name__ == "__main__":
    main()
