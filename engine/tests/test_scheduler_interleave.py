"""§6.1 thread discipline on real MLX: TTS chunk steps and ASR decode steps interleaved on the one
GPU thread, 10 000 steps in all, with no MLX stream error (mlx-audio #857/#863).

Gated: needs Metal, the installed engine (venv + TTS and ASR models) and the GPU. Skipped unless
TALKTALK_INTERLEAVE=1. Run it outside the Claude Code sandbox, under the quiet lock chain
(build 1-4 + gpu), from engine/:

  TALKTALK_INTERLEAVE=1 python3 -I -B -m unittest discover -s tests -t . -p test_scheduler_interleave.py

Optional: TALKTALK_ENGINE_HOME (default ~/Library/Application Support/TalkTalk/engine),
TALKTALK_INTERLEAVE_STEPS (default 10000). Voice and ASR input are the synthetic warmup files
(`engine/warmup/`, made with `say` at install), so no user audio is involved.

Load: a TTS thread renders en/de clauses back to back while an ASR thread sends the warmup
sample at SPEAK priority (P1), so both generators are alive at once and the scheduler switches
between them mid-stream. No playout reports: bufferedAhead is unknown, so TTS is never parked at
the horizon. Passes when the step count is reached with every request answered, both step kinds
present in /v1/stats, the engine alive and healthy, and no stream error or traceback in its log.
"""
import os
import threading
import time
import unittest
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOME = Path(os.environ.get("TALKTALK_ENGINE_HOME",
                           str(Path.home() / "Library/Application Support/TalkTalk/engine")))
STEPS = int(os.environ.get("TALKTALK_INTERLEAVE_STEPS", "10000"))
GATED = os.environ.get("TALKTALK_INTERLEAVE") == "1"

CLAUSES = [
    ("en", "We can move the review to Thursday afternoon if that works better for everyone here."),
    ("de", "Ich schicke euch die Zahlen noch heute Abend, dann können wir morgen früh entscheiden."),
    ("en", "The latency numbers look fine, but I would like to see the long tail before we ship it."),
    ("de", "Lass uns das Thema am Ende der Woche noch einmal mit dem ganzen Team besprechen."),
]
STREAM_ERRORS = ("There is no Stream", "Stream(gpu", "no stream", "Traceback")


def read_wav(p):
    import numpy as np
    with wave.open(str(p), "rb") as w:
        sr = w.getframerate()
        a = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768.0
    return a, sr


def total_steps(stats):
    return sum(v["n"] for v in stats.get("steps", {}).values())


@unittest.skipUnless(GATED, "real-MLX interleave test: set TALKTALK_INTERLEAVE=1 (outside the sandbox, GPU lock held)")
class InterleaveTest(unittest.TestCase):
    def test_tts_and_asr_steps_interleave_without_stream_errors(self):
        import sys
        sys.path.insert(0, str(ROOT / "engine"))
        from talktalk_engine.client import Engine

        for need in ("venv/bin/python3", "models", "warmup/ref-zh.wav", "warmup/sample-zh.wav"):
            self.assertTrue((HOME / need).exists(), f"engine install incomplete: {HOME / need} missing")
        log = Path.home() / "Library/Logs/TalkTalk/engine-test-interleave.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        if log.exists():
            log.unlink()
        eng = Engine(HOME / "venv/bin/python3", ROOT / "engine", [HOME / "models"], roles="tts,asr",
                     tts="tts-qwen3-1.7b-base-8bit", asr="asr-qwen3-0.6b-8bit", warmup_dir=HOME / "warmup",
                     log_path=log)
        errors, counts = [], {"tts": 0, "asr": 0}
        stop = threading.Event()
        try:
            eng.start(timeout=600)
            eng.wait_asr(timeout=600)
            ref, _ = read_wav(HOME / "warmup/ref-zh.wav")
            _, blob = eng.build_voice(ref, (HOME / "warmup/ref-zh.txt").read_text().strip())
            eng.load_voice(blob)
            sample, sr = read_wav(HOME / "warmup/sample-zh.wav")
            self.assertEqual(sr, 16000)
            eng.json("POST", "/v1/session", {"speak_active": True}, expect=(204,))

            def tts_loop():
                i = 0
                while not stop.is_set():
                    lang, text = CLAUSES[i % len(CLAUSES)]
                    try:
                        _, tail, _ = eng.tts({"text": text, "lang": lang, "seed": i})
                        if not tail or tail.get("frames", 0) <= 0:
                            errors.append(f"tts {i}: empty tail {tail!r}")
                        counts["tts"] += 1
                    except Exception as e:  # noqa: BLE001
                        errors.append(f"tts {i}: {e}")
                    i += 1

            def asr_loop():
                i = 0
                while not stop.is_set():
                    try:
                        r = eng.asr(sample, hint="zh", priority=1)
                        if not r.get("timing", {}).get("tokens"):
                            errors.append(f"asr {i}: no tokens {r!r}")
                        counts["asr"] += 1
                    except Exception as e:  # noqa: BLE001
                        errors.append(f"asr {i}: {e}")
                    i += 1
                    time.sleep(0.2)

            workers = [threading.Thread(target=f, daemon=True) for f in (tts_loop, asr_loop)]
            for w in workers:
                w.start()
            deadline = time.monotonic() + 3600
            while time.monotonic() < deadline and not errors:
                if total_steps(eng.json("GET", "/v1/stats")) >= STEPS:
                    break
                time.sleep(2.0)
            stop.set()
            for w in workers:
                w.join(timeout=120)
            stats = eng.json("GET", "/v1/stats")["steps"]
            health = eng.health()
        finally:
            stop.set()
            eng.stop()
        self.assertEqual(errors, [])
        self.assertGreaterEqual(sum(v["n"] for v in stats.values()), STEPS)
        for cls in ("tts", "tts.first", "asr", "asr.first"):
            self.assertIn(cls, stats)
        self.assertGreater(counts["tts"], 0)
        self.assertGreater(counts["asr"], 0)
        self.assertEqual(health["status"], "ok")
        text = log.read_text(errors="replace") if log.exists() else ""
        bad = [ln for ln in text.splitlines() if any(m in ln for m in STREAM_ERRORS)]
        self.assertEqual(bad, [], "stream errors in the engine log")
        print(f"\ninterleave: {sum(v['n'] for v in stats.values())} steps, tts {counts['tts']} clauses, "
              f"asr {counts['asr']} calls; p99 " + ", ".join(f"{k} {v['p99']}" for k, v in sorted(stats.items())))


if __name__ == "__main__":
    unittest.main()
