#!/usr/bin/env python3
"""Replay the TTS guards (engine/talktalk_engine/guards.py) on `tts_bench.py guard-cal` rows.

Every row is a legit render (guards off, EOS reached). For each clip the guard's checks run at
every chunk boundary (2 frames) exactly as Guarded does: runaway cap, codebook-0 loop, slow and
short; any runaway verdict here is a false positive. Also prints, per loop period, the longest
repeating run found in legit speech (the margin under `loop_frames`).

  python3 -I -B tools/bench/guards_eval.py tools/bench/results/guard_cal_<date>.jsonl
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "engine"))
from talktalk_engine import guards  # noqa: E402
from talktalk_engine.tts import expected_seconds  # noqa: E402

CHUNK = 2


def longest_runs(cb0, max_period):
    """For each period p, the longest stretch where cb0[i] == cb0[i - p]  (+p = frames covered)."""
    best = {}
    for p in range(1, max_period + 1):
        run = top = 0
        for i in range(p, len(cb0)):
            run = run + 1 if cb0[i] == cb0[i - p] else 0
            top = max(top, run)
        best[p] = top + p if top else 0
    return best


def main(path):
    rows = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
    p = guards.Policy()
    out = {"n": len(rows), "eos": sum(1 for r in rows if r["eos"]), "loop_fp": [], "cap_fp": [], "slow": [],
           "short": [], "longest_run_by_period": {}}
    worst = {q: (0, None) for q in range(1, p.loop_max_period + 1)}
    for r in rows:
        cb0 = r["cb0"]
        exp = expected_seconds("x " * max(1, r["words"]), r["lang"]) if "expected_s" not in r else r["expected_s"]
        cap = guards.runaway_cap_frames(exp, p)
        for end in range(CHUNK, len(cb0) + 1, CHUNK):
            if guards.cb0_loop(cb0[:end], p.loop_frames, p.loop_max_period):
                out["loop_fp"].append({"id": r["id"], "at_frame": end, "frames": len(cb0)})
                break
        if r["frames"] > cap:
            out["cap_fp"].append({"id": r["id"], "frames": r["frames"], "cap": cap})
        if r["frames"] / guards.FRAME_HZ > p.slow_ratio * exp:
            out["slow"].append(r["id"])
        if r["audio_s"] < p.short_factor * exp:
            out["short"].append(r["id"])
        for q, n in longest_runs(cb0, p.loop_max_period).items():
            if n > worst[q][0]:
                worst[q] = (n, r["id"])
    out["longest_run_by_period"] = {q: {"frames": n, "id": i, "flag_at": max(p.loop_frames, 2 * q)}
                                    for q, (n, i) in worst.items()}
    out["loop_fp_n"] = len(out["loop_fp"])
    out["cap_fp_n"] = len(out["cap_fp"])
    print(json.dumps(out, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main(sys.argv[1])
