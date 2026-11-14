"""Installer smoke must actually recognize speech without requiring TTS resources."""
import contextlib
import io
import json
import sys
import tempfile
import unittest
import wave
from pathlib import Path
from unittest.mock import Mock, patch

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import smoke_engine


class RecognitionSmokeTests(unittest.TestCase):
    def run_smoke(self, *, transcript="我们下周二开会", failure=None, revision="selected-revision"):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            warm = home / "warmup"
            warm.mkdir()
            with wave.open(str(warm / "sample-zh.wav"), "wb") as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(16000)
                wav.writeframes(np.zeros(16000, dtype="<i2").tobytes())
            (warm / "sample-zh.txt").write_text("我们下周二开会")
            selected = home / "models" / "selected-asr"
            selected.mkdir(parents=True)
            engine = Mock()
            engine.ready_s = 0.1
            engine.ready = {"models": {"asr": {"id": "asr-test", "rev": revision}}}
            engine.asr.return_value = {"text": transcript}
            engine.asr.side_effect = failure
            output = io.StringIO()
            argv = ["smoke_engine.py", "--engine-home", str(home), "--engine-src", str(home),
                    "--asr", "asr-test", "--asr-model-dir", str(selected),
                    "--asr-revision", "selected-revision"]
            with patch.object(sys, "argv", argv), patch.object(smoke_engine, "Engine", return_value=engine) as factory, \
                    patch.object(smoke_engine, "lsof_ok", return_value=(True, {})), \
                    patch.object(Path, "home", return_value=home), contextlib.redirect_stdout(output):
                code = smoke_engine.main()
            kwargs = factory.call_args.kwargs
            self.assertEqual(kwargs["roles"], "asr")
            self.assertIsNone(kwargs["tts"])
            engine.build_voice.assert_not_called()
            engine.load_voice.assert_not_called()
            engine.tts.assert_not_called()
            engine.stop.assert_called_once()
            self.assertFalse((warm / "ref-zh.wav").exists())
            self.assertFalse(factory.call_args.args[2][0].exists(), "temporary model view must be removed")
            return code, json.loads(output.getvalue()), engine

    def test_recognition_only_runs_actual_asr_without_voice_or_tts(self):
        code, result, engine = self.run_smoke()
        self.assertEqual(code, 0)
        self.assertTrue(result["ok"])
        self.assertEqual(result["roles"], "asr")
        self.assertEqual(result["asr_cer"], 0)
        self.assertNotIn("tts", result)
        engine.wait_asr.assert_called_once()
        engine.asr.assert_called_once()

    def test_asr_failure_or_bad_transcript_cannot_pass_installation(self):
        for arguments in ({"failure": RuntimeError("ASR load failed")}, {"transcript": "unrelated output"}):
            with self.subTest(arguments=arguments):
                code, result, _ = self.run_smoke(**arguments)
                self.assertEqual(code, 1)
                self.assertFalse(result["ok"])

    def test_wrong_model_revision_cannot_pass_installation(self):
        code, result, engine = self.run_smoke(revision="another-revision")
        self.assertEqual(code, 1)
        self.assertIn("different model or revision", result["error"])
        engine.asr.assert_not_called()


if __name__ == "__main__":
    unittest.main()
