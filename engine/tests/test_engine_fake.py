"""Engine process tests with fake models: the real entry, handshake, watchdogs, HTTP API and
scheduler, exercised end to end through the bench/smoke client (no MLX, no GPU, no downloads).

Covers the model-independent half of M0-T0: READY without a voice, voice/load, handshake fd
silent after READY (library prints go to the log), imports on the GPU thread, sounddevice stub,
loopback-only listening socket, FATAL without a token, exit within 1 s after stdin EOF.
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import wave
from pathlib import Path

import numpy as np

ENGINE = Path(__file__).resolve().parents[1]
FAKE_ENTRY = ENGINE / "tests/fakes/run_fake_engine.py"
sys.path.insert(0, str(ENGINE))

from smoke_engine import lsof_ok  # noqa: E402
from talktalk_engine import frames  # noqa: E402
from talktalk_engine.client import Engine, EngineError  # noqa: E402


def can_bind():
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", 0))
        return True
    except PermissionError:
        return False
    finally:
        s.close()


def write_wav(path, seconds, sr):
    t = np.arange(int(seconds * sr)) / sr
    pcm = (0.2 * np.sin(2 * np.pi * 180 * t) * 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())


@unittest.skipUnless(can_bind(), "cannot bind 127.0.0.1 here (Claude Code sandbox); run outside it")
class FakeEngineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.tmp.cleanup)
        root = Path(cls.tmp.name)
        models = root / "models"
        for key in ("tts-fake", "asr-fake"):
            d = models / f"{key}@000000000000"
            d.mkdir(parents=True)
            (d / ".talktalk-verified").write_text(f"{'0' * 40}\nkey={key} repo=fake/{key} verified_at=now\n")
        warm = root / "warmup"
        warm.mkdir()
        write_wav(warm / "ref-zh.wav", 2.0, 24000)
        (warm / "ref-zh.txt").write_text("大家好")
        cls.root = root
        cls.log = root / "engine.log"
        cls.eng = Engine(sys.executable, ENGINE, [models], roles="tts,asr", tts="tts-fake", asr="asr-fake",
                         warmup_dir=warm, cache_dir=root / "cache", log_path=cls.log, entry=FAKE_ENTRY)
        cls.addClassCleanup(cls.eng.stop)
        cls.eng.start(timeout=30)

    def test_1_ready_without_voice(self):
        self.assertEqual(self.eng.ready["voice"]["state"], "absent")
        self.assertEqual(self.eng.health()["voice"]["state"], "absent")
        st, body = self.eng.request("POST", "/v1/tts", {"text": "Hello there", "lang": "en"})
        self.assertEqual(st, 409)
        self.assertEqual(json.loads(body)["error"]["code"], "voice_absent")

    def test_2_voice_load_then_tts_and_silent_handshake(self):
        pcm = (0.1 * np.sin(np.arange(24000 * 3) / 24000 * 2 * np.pi * 200)).astype(np.float32)
        head, blob = self.eng.build_voice(pcm, "大家好，今天")
        self.assertGreater(len(blob), 16)
        self.eng.load_voice(blob)
        self.assertEqual(self.eng.health()["voice"]["state"], "ready")
        for i in range(20):
            pcm, tail, timing = self.eng.tts({"text": "Thanks, everyone, for coming today.", "lang": "en", "seed": i})
            self.assertGreater(timing["audio_s"], 0.3)
            self.assertIn("timing", tail)
            self.assertIsNotNone(timing["ttfa_ms"])
        self.assertEqual(self.eng.handshake_extra_lines(wait=0.2), b"")
        self.assertTrue(self.eng.handshake_closed)
        log = self.log.read_text()
        self.assertIn("fake tts: generating", log)        # library prints went to the log
        self.assertIn("fake mlx_audio imported", log)

    def test_3_hygiene(self):
        h = self.eng.health()
        first = h["hygiene"]["imports_first_thread"]
        self.assertEqual(set(first), {"mlx", "mlx_audio", "transformers"})
        self.assertEqual(set(first.values()), {"gpu"})
        self.assertTrue(h["hygiene"]["sounddevice_stub"])
        ok, detail = lsof_ok(self.eng.pid, self.eng.port)
        self.assertTrue(ok, detail)

    def test_4_asr(self):
        self.eng.wait_asr(timeout=10)
        r = self.eng.asr(np.zeros(16000, np.float32), hint="zh")
        self.assertIn("十点", r["text"])
        self.assertIn("step_ms_p99", r["timing"])

    def test_5_stats(self):
        st = self.eng.json("GET", "/v1/stats")
        self.assertIn("tts", st["steps"])
        self.assertIn("tts.first", st["steps"])
        p99 = self.eng.health()["gpu"]["step_p99"]
        self.assertEqual(p99["tts"], st["steps"]["tts"]["p99"])

    def test_6_voice_similarity(self):
        t = np.arange(24000 * 2) / 24000
        ref = (0.1 * np.sin(t * 2 * np.pi * 200)).astype(np.float32)
        other = (ref * np.linspace(0, 1, len(ref))).astype(np.float32)
        self.assertAlmostEqual(self.eng.similarity(ref, ref), 1.0, places=5)
        self.assertLess(self.eng.similarity(ref, other), 0.99)
        self.assertIn("similarity.first", self.eng.json("GET", "/v1/stats")["steps"])   # one GPU step
        body = frames.encode(frames.JSON_HEAD, {}) + frames.encode(frames.PCM_F32_24K, ref.tobytes())
        st, data = self.eng.request("POST", "/v1/voice/similarity", body, ctype="application/x-talktalk-frames")
        self.assertEqual((st, json.loads(data)["error"]["code"]), (400, "bad_request"))
        short = ref[:6000].tobytes()
        body = frames.encode(frames.JSON_HEAD, {}) + frames.encode(frames.PCM_F32_24K, ref.tobytes()) + \
            frames.encode(frames.PCM_F32_24K, short)
        st, data = self.eng.request("POST", "/v1/voice/similarity", body, ctype="application/x-talktalk-frames")
        self.assertEqual((st, json.loads(data)["error"]["code"]), (400, "audio_too_short"))


@unittest.skipUnless(can_bind(), "cannot bind 127.0.0.1 here (Claude Code sandbox); run outside it")
class FakeEngineLifecycleTests(unittest.TestCase):
    def _spawn(self, env_token):
        r, w = os.pipe()
        env = {"HOME": os.environ.get("HOME", ""), "PATH": "/usr/bin:/bin"}
        if env_token:
            env["TALKTALK_TOKEN"] = env_token
        p = subprocess.Popen([sys.executable, "-I", "-B", str(FAKE_ENTRY), "--models-dir", "/nonexistent",
                              "--roles", "tts", "--tts", "tts-fake"], stdin=subprocess.PIPE, stdout=w,
                             stderr=subprocess.DEVNULL, env=env, start_new_session=True)
        self.addCleanup(p.stdin.close)
        os.close(w)
        return p, r

    def test_fatal_without_token(self):
        p, r = self._spawn(None)
        out = b""
        while True:
            c = os.read(r, 4096)
            if not c:
                break
            out += c
        os.close(r)
        p.wait(5)
        self.assertTrue(out.startswith(b"FATAL "), out)
        self.assertNotEqual(p.returncode, 0)

    def test_fatal_when_model_missing(self):
        p, r = self._spawn("x" * 64)
        out = b""
        while True:
            c = os.read(r, 4096)
            if not c:
                break
            out += c
        os.close(r)
        p.wait(10)
        self.assertIn(b"FATAL ", out)
        self.assertIn(b"not found", out)

    def test_topology_b_separate_asr_thread(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        models = Path(tmp.name) / "models"
        for key in ("tts-fake", "asr-fake"):
            d = models / f"{key}@000000000000"
            d.mkdir(parents=True)
            (d / ".talktalk-verified").write_text(f"{'0' * 40}\nkey={key} repo=fake/{key} verified_at=now\n")
        eng = Engine(sys.executable, ENGINE, [models], roles="tts,asr", tts="tts-fake", asr="asr-fake",
                     cache_dir=Path(tmp.name) / "c", entry=FAKE_ENTRY, extra_args=["--asr-thread", "separate"])
        self.addCleanup(eng.stop)
        eng.start(timeout=30)
        eng.wait_asr(timeout=10)
        self.assertEqual(eng.health()["asr_thread"], "separate")
        pcm = np.zeros(24000 * 2, np.float32)
        _, blob = eng.build_voice(pcm + 0.1, "大家好")
        eng.load_voice(blob)
        r = eng.asr(np.zeros(16000, np.float32), hint="zh")
        self.assertTrue(r["text"])
        _, _, timing = eng.tts({"text": "Thanks, everyone.", "lang": "en"})
        self.assertGreater(timing["audio_s"], 0)
        self.assertIn("asr", eng.json("GET", "/v1/stats")["steps"])

    def test_exit_within_1s_after_stdin_eof(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        models = Path(tmp.name) / "models"
        d = models / "tts-fake@000000000000"
        d.mkdir(parents=True)
        (d / ".talktalk-verified").write_text(f"{'0' * 40}\nkey=tts-fake repo=fake/tts verified_at=now\n")
        eng = Engine(sys.executable, ENGINE, [models], roles="tts", tts="tts-fake", cache_dir=Path(tmp.name) / "c",
                     entry=FAKE_ENTRY)
        self.addCleanup(eng.stop)
        eng.start(timeout=30)
        t = time.perf_counter()
        eng.proc.stdin.close()
        eng.proc.wait(1.0)
        self.assertLess(time.perf_counter() - t, 1.0)


if __name__ == "__main__":
    unittest.main()
