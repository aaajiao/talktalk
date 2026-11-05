Fakes for the engine process tests (`tests/test_engine_fake.py`). Only `run_fake_engine.py` puts
this directory on `sys.path`; the real engine entry (`talktalk_engine.py`) never does.

- `mlx/`, `mlx_audio/`, `transformers/`: tiny numpy-backed stand-ins for the parts `main.py` and
  `voice.py` touch (version strings, memory calls, `mx.array`). They print to stdout on purpose,
  like mlx-audio does, to prove the handshake fd trick keeps library output off the handshake pipe.
- `fake_models.py`: replaces `talktalk_engine.tts` / `.asr` with models that produce sine audio
  frame by frame and canned ASR text, with the same generator contract as the real ones.
