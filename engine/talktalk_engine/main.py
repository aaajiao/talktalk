"""Engine startup and state (§4.4, §6.3, §7.6).

Order: watchdogs + stubs -> HTTP listening on 127.0.0.1:0 -> on the GPU thread: import MLX and
mlx-audio, load TTS, generic warmup with the synthetic `say` reference (en + de) -> READY.
The user's voice is NOT required for READY (it arrives over HTTP, whose port READY announces).
ASR loads after READY as a background call; /v1/health reports it.
"""
import argparse
import builtins
import os
import platform
import sys
import threading
import time
import wave
from pathlib import Path

import numpy as np

from . import ENGINE_API, ENGINE_NAME, RUNTIME, handshake, stubs, watchdog
from .scheduler import P0, P1, P2, P3, GpuScheduler, Job

WATCHED_PREFIXES = ("mlx", "mlx_audio", "transformers")   # must first be imported on the GPU thread (§6.1)


class ImportAudit:
    """Records which thread first imported each heavy library (M0-T0: all on the GPU thread)."""

    def __init__(self):
        self.first = {}
        self._orig = builtins.__import__
        audit = self

        def hook(name, globals=None, locals=None, fromlist=(), level=0):
            top = name.split(".")[0] if level == 0 else None
            if top in WATCHED_PREFIXES and top not in audit.first and top not in sys.modules:
                audit.first[top] = threading.current_thread().name
            return audit._orig(name, globals, locals, fromlist, level)

        builtins.__import__ = hook


def find_models(dirs):
    """Maps model key -> (path, revision) using each dir's .talktalk-verified stamp."""
    found = {}
    for base in dirs:
        base = Path(base)
        if not base.is_dir():
            continue
        for d in sorted(base.iterdir()):
            stamp = d / ".talktalk-verified"
            if not stamp.is_file():
                continue
            lines = stamp.read_text().splitlines()
            rev = lines[0].strip() if lines else ""
            key = None
            for tok in (lines[1].split() if len(lines) > 1 else []):
                if tok.startswith("key="):
                    key = tok[4:]
            if key and key not in found:
                found[key] = (d, rev)
    return found


def read_wav_f32(path):
    with wave.open(str(path), "rb") as w:
        if w.getsampwidth() != 2 or w.getnchannels() != 1:
            raise ValueError(f"{path}: expected 16-bit mono")
        sr = w.getframerate()
        data = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768.0
    return data, sr


class EngineState:
    def __init__(self, args):
        self.args = args
        self.token = os.environ.get("TALKTALK_TOKEN", "")
        self.sched = GpuScheduler(horizon_ms=args.horizon_ms)
        # M0-T2 topology B: ASR on its own MLX thread in the same process (default: shared, topology A)
        self.asr_sched = GpuScheduler(horizon_ms=args.horizon_ms) if args.asr_thread == "separate" else self.sched
        self.tts = None
        self.asr = None
        self.asr_state = "absent"
        self.voice = None
        self.voice_state = "absent"
        # Voice load/unload order (voice-m2, review round 2 item 4): every load and unload takes a
        # new generation when its request arrives; a load commits only if its generation is still
        # the newest once the GPU thread has decoded the blob. A load the app gave up on (stuck
        # behind the ASR background load in sched.call) cannot bring back a deleted voice.
        self.voice_gen = 0
        self.voice_lock = threading.Lock()
        self.warmup_voice = None
        self.tts_requests = 0
        self.versions = {}
        self.models = {}
        self.port = None
        self.audit = None

    # -------------------------------------------------------------- GPU-thread init

    def gpu_init(self):
        import mlx.core as mx
        import mlx_audio  # noqa: F401
        import transformers

        from .asr import ASRModel
        from .tts import TTSModel

        mx.set_cache_limit(1 << 30)
        self.mx = mx
        try:
            from mlx_audio.version import __version__ as mav
        except Exception:  # noqa: BLE001
            mav = "unknown"
        self.versions = {"mlx": mx.__version__, "mlx_audio": mav, "transformers": transformers.__version__,
                         "python": platform.python_version()}
        found = find_models(self.args.models_dir)
        roles = self.args.roles
        steps = ["tts", "warmup"] if "tts" in roles else []
        n = len(steps)
        if "tts" in roles:
            if self.args.tts not in found:
                raise RuntimeError(f"TTS model {self.args.tts} not found in {self.args.models_dir}")
            path, rev = found[self.args.tts]
            handshake.progress("tts", 0, n)
            self.tts = TTSModel(self.args.tts, path, rev).load()
            self.models["tts"] = {"id": self.args.tts, "rev": rev, "state": "ready"}
            handshake.progress("tts", 1, n)
            self._generic_warmup()
            handshake.progress("warmup", 2, n)
        if "asr" in roles:
            if self.args.asr not in found:
                raise RuntimeError(f"ASR model {self.args.asr} not found in {self.args.models_dir}")
            path, rev = found[self.args.asr]
            self.asr = ASRModel(self.args.asr, path, rev)
            self.models["asr"] = {"id": self.args.asr, "rev": rev, "state": "loading"}
            self.asr_state = "loading"
        try:
            dirs = [Path(found[k][0]) for k in (self.args.tts, self.args.asr) if k in found and
                    ((k == self.args.tts and "tts" in roles) or (k == self.args.asr and "asr" in roles))]
            wired = sum(f.stat().st_size for d in dirs for f in d.rglob("*.safetensors"))
            mx.set_wired_limit(int(wired + (1 << 30)))
        except Exception as e:  # noqa: BLE001
            print(f"engine: set_wired_limit skipped ({type(e).__name__}: {e})", file=sys.stderr)

    def _generic_warmup(self):
        """Compiles kernels with the synthetic reference; the result is discarded (§4.4, §6.3)."""
        wdir = Path(self.args.warmup_dir) if self.args.warmup_dir else None
        if not wdir or not (wdir / "ref-zh.wav").is_file():
            print("engine: no warmup reference; skipping generic warmup", file=sys.stderr)
            return
        pcm, sr = read_wav_f32(wdir / "ref-zh.wav")
        if sr != 24000:
            from scipy.signal import resample_poly
            pcm = resample_poly(pcm, 24000, sr).astype(np.float32)
        text = (wdir / "ref-zh.txt").read_text().strip()
        voice, _ = self.tts.build_voice(pcm, text, key="warmup")
        self.warmup_voice = voice
        for lang, sentence in (("en", "Thanks, everyone."), ("de", "Danke Ihnen allen.")):
            for _ in self.tts.stream(sentence, voice, lang, interval=0.16, max_frames=40, seed=0):
                pass

    def load_asr_background(self):
        def load():
            self.asr.load()
            # warm the encoder with 1 s / 3 s of silence-plus-noise shapes (§6.3 step 3)
            rng = np.random.default_rng(0)
            for secs in (1, 3):
                pcm = (rng.standard_normal(16000 * secs) * 0.003).astype(np.float32)
                for _ in self.asr.stream(pcm, hint="zh", max_tokens=4):
                    pass
            return True

        def run():
            try:
                if self.asr_sched is not self.sched and self.asr_sched.thread is None:
                    self.asr_sched.start(name="gpu-asr")
                self.asr_sched.call(load, long_step=True)
                self.asr_state = "ready"
                self.models["asr"]["state"] = "ready"
            except Exception as e:  # noqa: BLE001
                self.asr_state = "failed"
                self.models["asr"]["state"] = "failed"
                print(f"engine: ASR load failed: {type(e).__name__}: {e}", file=sys.stderr)

        threading.Thread(target=run, name="asr-load", daemon=True).start()

    # -------------------------------------------------------------- voice

    def build_voice(self, pcm24k, ref_text, model=None):
        from . import voice as V

        key = f"{RUNTIME}-mlxaudio{self.versions.get('mlx_audio', '?')}-{self.tts.key}@{self.tts.rev[:12]}-icl-{V.audio_fingerprint(pcm24k)[:16]}"

        def build():
            v, ms = self.tts.build_voice(pcm24k, ref_text, key=key)
            return v, ms, V.to_blob(v)

        return self.sched.call(build, long_step=True)

    def load_voice(self, blob, expected_key=None, model=None):
        """Returns False when an unload (or a newer load) came in while this one waited for the GPU
        thread: then nothing changes."""
        from . import voice as V
        from .server import ApiError

        if model is not None and (self.tts is None or self.tts.key != model):
            raise ApiError(409, "voice_model_mismatch", "voice model does not match the loaded TTS model")

        def load():
            voice = V.from_blob(blob)
            if expected_key is not None and voice.key != expected_key:
                raise ApiError(409, "voice_key_mismatch", "voice blob does not match the requested voice")
            return voice

        with self.voice_lock:
            self.voice_gen += 1
            gen = self.voice_gen
        v = self.sched.call(load)
        with self.voice_lock:
            if gen != self.voice_gen:
                print(f"engine: voice/load superseded (generation {gen} < {self.voice_gen}), not applied", file=sys.stderr)
                return False
            self.voice = v
            self.voice_state = "loading"

        def warm():
            # #1096 decoder warmup for this voice (P3): one short en and de sentence, discarded.
            for lang, s in (("en", "Thank you."), ("de", "Vielen Dank.")):
                yield from self.tts.stream(s, v, lang, interval=0.16, max_frames=30, seed=0)

        def done(err):
            with self.voice_lock:
                if self.voice is v:       # not unloaded or replaced meanwhile
                    self.voice_state = "failed" if err else "ready"

        self.sched.submit(Job("voice_warmup", P3, warm, deadline_ms=float("inf"), on_done=done))
        return True

    def _clear_cache(self):
        mx = getattr(self, "mx", None)
        if mx is not None:
            mx.clear_cache()

    def _ref_cb0(self, voice):
        """Codebook-0 of the voice's reference codes, for the start-of-utterance echo check
        (cached per voice key; GPU thread only)."""
        if voice is None or getattr(voice, "ref_codes", None) is None:
            return None
        cache = getattr(self, "_ref_cb0_cache", None)
        if cache is not None and cache[0] == voice.key:
            return cache[1]
        ref = np.array(voice.ref_codes[0, 0]).tolist()
        self._ref_cb0_cache = (voice.key, ref)
        return ref

    def unload_voice(self):
        with self.voice_lock:
            self.voice_gen += 1
            self.voice = None
            self.voice_state = "absent"

    # -------------------------------------------------------------- jobs

    def tts_job(self, req, out):
        from .guards import Guarded, Policy, Progress
        from .tts import echo_features, expected_seconds
        from .server import ApiError

        self.tts_requests += 1
        text = str(req["text"])
        lang = req["lang"]
        with self.voice_lock:
            if self.voice is None:
                raise ApiError(409, "voice_absent", "no voice loaded")
            if self.voice_state != "ready":
                raise ApiError(409, "voice_not_ready", "voice is not ready")
            voice, voice_gen = self.voice, self.voice_gen
            if req.get("voice_key") is not None and req["voice_key"] != voice.key:
                raise ApiError(409, "voice_key_mismatch", "loaded voice does not match the requested voice")
        t_req = time.perf_counter()
        first = {}
        exp = expected_seconds(text, lang)
        # Request overrides are for the bench (raw vs guarded runs); the app sends whole_clause only.
        policy = Policy.raw() if req.get("guards") is False else Policy()
        if req.get("hold_s") is not None:
            policy.hold_s = float(req["hold_s"])
        if req.get("max_attempts") is not None:
            policy.max_attempts = max(1, int(req["max_attempts"]))
        guard = Guarded(
            lambda seed, max_frames, stats: self.tts.stream(
                text, voice, lang, interval=float(req.get("interval", 0.16)),
                compiled=bool(req.get("compiled", False)), seed=seed, temperature=req.get("temperature"),
                max_frames=max_frames, prime=bool(req.get("prime", True)), stats=stats),
            text, exp, req.get("seed"), policy=policy, whole=req.get("whole_clause"),
            clear_cache=self._clear_cache, max_frames=req.get("max_frames"))

        def factory():
            # on the GPU thread: the reference codes are an MLX array
            with self.voice_lock:
                if self.voice is not voice or self.voice_gen != voice_gen or self.voice_state != "ready":
                    raise ApiError(409, "voice_changed", "voice changed before synthesis started")
            first["queue_ms"] = (time.perf_counter() - t_req) * 1e3
            guard.ref_cb0 = self._ref_cb0(voice)
            return iter(guard)

        def on_item(chunk):
            if isinstance(chunk, Progress):
                out.put(("progress", chunk.payload()))      # held audio: proof of life, no samples
                return
            ms = len(chunk) / 24.0
            self.sched.note_audio(job, ms)
            out.put(("pcm", chunk.astype("<f4").tobytes()))

        def on_done(err):
            if err is not None and err != "cancelled":
                out.put(("error", {"code": getattr(err, "code", "tts_failed"), "message": type(err).__name__}))
                return
            st = guard.stats
            g = guard.report
            frames_n = g["frames"]
            audio_s = g["audio_s"]
            fm = sorted(st.get("frame_ms", []))
            pick = lambda q: round(fm[min(len(fm) - 1, int(q * (len(fm) - 1)))], 3) if fm else None  # noqa: E731
            gaps = np.diff([0.0] + st.get("chunk_at_ms", [])).tolist()
            tail = {"audio_s": audio_s, "frames": frames_n, "eos": g["eos"],
                    "runaway": g["runaway"], "short": g["short"], "slow": g["slow"],
                    "echo_aborts": g["echo_aborts"], "attempts": g["attempts"], "lead_trim_ms": 0,
                    "whole": g["whole"], "held_s": g["held_s"], "cancelled": err == "cancelled",
                    "expected_s": round(exp, 3),
                    "timing": {"queue_ms": round(first.get("queue_ms", 0.0), 3),
                               "prepare_ms": round(st.get("prepare_ms", 0.0), 3),
                               "prime_ms": round(st.get("prime_ms", 0.0), 3),
                               "prefill_ms": round(st.get("prefill_ms", 0.0), 3),
                               "first_chunk_ms": round(st["chunk_at_ms"][0], 3) if st.get("chunk_at_ms") else None,
                               "frame_ms_p50": pick(0.5), "frame_ms_p95": pick(0.95), "frame_ms_p99": pick(0.99),
                               "frame_ms_max": pick(1.0), "chunk_gap_ms_p99": round(sorted(gaps[1:])[int(0.99 * (len(gaps) - 2))], 3) if len(gaps) > 2 else None,
                               "total_ms": round(st.get("total_ms", 0.0), 3),
                               "gpu_ms_all_attempts": g["gpu_ms"], "prompt_len": st.get("prompt_len"),
                               "chunk_frames": st.get("chunk_frames"), "compiled": st.get("compiled")}}
            if req.get("debug"):
                tail["cb0"] = st.get("cb0", [])
                tail["echo"] = echo_features(st.get("cb0", []), np.array(voice.ref_codes[0, 0]).tolist())
                tail["frame_ms"] = [round(x, 3) for x in st.get("frame_ms", [])]
            if audio_s > 0:
                self.sched.tts_rtf_recent.append(g["gpu_ms"] / 1e3 / audio_s)      # every attempt counts
            out.put(("tail", tail))

        job = Job("tts", P0, factory, job_id=req.get("job"), on_item=on_item, on_done=on_done)
        return self.sched.submit(job)

    def similarity(self, ref24k, sample24k):
        """/v1/voice/similarity: x-vector cosine of two 24 kHz clips, one P3 step (§6.1 rule 3)."""
        done = threading.Event()
        box = {}

        def factory():
            yield self.tts.speaker_cosine(ref24k, sample24k)

        def on_item(item):
            box["cosine"] = item

        def on_done(err):
            box["err"] = err
            done.set()

        self.sched.submit(Job("similarity", P3, factory, deadline_ms=float("inf"), on_item=on_item, on_done=on_done))
        done.wait()
        if box.get("err") is not None or "cosine" not in box:
            from .server import ApiError
            raise ApiError(500, "similarity_failed", str(box.get("err")))
        return box["cosine"]

    def run_asr(self, pcm16k, hint, context, priority, job_id):
        done = threading.Event()
        box = {}
        st = {}

        def factory():
            return self.asr.stream(pcm16k, hint=hint, context=context, stats=st)

        def on_item(item):
            box["result"] = item

        def on_done(err):
            box["err"] = err
            done.set()

        prio = {0: P1, 1: P1, 2: P2, 3: P3}.get(priority, P1)
        deadline = time.monotonic() * 1e3 + (300.0 if prio == P2 else 0.0)
        job = Job("asr", prio, factory, job_id=job_id, deadline_ms=deadline, on_item=on_item, on_done=on_done)
        self.asr_sched.submit(job)
        done.wait()
        if box.get("err") is not None:
            from .server import ApiError
            if box["err"] == "expired":       # §6.1 rule 7: P2 past its deadline; the app uses Apple final
                raise ApiError(409, "expired", "second-pass ASR missed its deadline")
            raise ApiError(409 if box["err"] == "cancelled" else 500, "asr_failed", str(box["err"]))
        r = box.get("result") or {"text": "", "language": hint, "timing": {}}
        r["timing"]["step_ms_p99"] = round(sorted(st["step_ms"])[int(0.99 * (len(st["step_ms"]) - 1))], 3) if st.get("step_ms") else None
        return r

    # -------------------------------------------------------------- health

    def health(self):
        mem = {}
        try:
            mx = self.mx
            mem = {"active": mx.get_active_memory(), "cache": mx.get_cache_memory(), "peak": mx.get_peak_memory()}
        except Exception:  # noqa: BLE001
            pass
        with self.voice_lock:
            voice = {"state": self.voice_state, "key8": self.voice.key8 if self.voice else None}
        return {"status": "ok", "api": ENGINE_API, "pid": os.getpid(), "runtime": RUNTIME, "versions": self.versions,
                "models": self.models,
                "voice": voice,
                "gpu": self.sched.health(), "mem": mem, "asr_thread": self.args.asr_thread,
                "hygiene": {"imports_first_thread": dict(self.audit.first) if self.audit else {},
                            "sounddevice_stub": stubs.is_installed(),
                            "speaker_embed": dict(self.tts.stats) if self.tts else {}}}


def parse(argv):
    p = argparse.ArgumentParser(prog="talktalk_engine")
    p.add_argument("--models-dir", action="append", required=True)
    p.add_argument("--roles", default="tts,asr")
    p.add_argument("--tts", default="tts-qwen3-1.7b-base-8bit")
    p.add_argument("--asr", default="asr-qwen3-0.6b-8bit")
    p.add_argument("--profile", default="max")
    p.add_argument("--warmup-dir")
    p.add_argument("--horizon-ms", type=float, default=1000.0)   # M2 T2 2026-11-05; the app passes PolicyProfile speak.tts.renderHorizonMs
    p.add_argument("--asr-thread", choices=("shared", "separate"), default="shared")   # M0-T2 topology B only
    a = p.parse_args(argv)
    a.roles = [r.strip() for r in a.roles.split(",") if r.strip()]
    return a


def run(handshake_fd, argv):
    audit = ImportAudit()
    handshake.init(handshake_fd)
    try:
        args = parse(argv)
    except SystemExit:
        handshake.fatal("bad arguments")
        return 3
    if len(os.environ.get("TALKTALK_TOKEN", "")) < 32:
        handshake.fatal("TALKTALK_TOKEN missing or too short")
        return 3
    watchdog.install()
    stubs.install()
    state = EngineState(args)
    state.audit = audit
    from . import server

    srv = server.serve(state)
    state.port = srv.server_address[1]
    try:
        state.sched.start(init=state.gpu_init)
    except BaseException as e:  # noqa: BLE001
        print(f"engine: FATAL {type(e).__name__}: {e}", file=sys.stderr)
        handshake.fatal(f"{type(e).__name__}: {e}")
        return 3
    handshake.ready({"port": state.port, "pid": os.getpid(), "api": ENGINE_API, "engine": ENGINE_NAME,
                     "runtime": RUNTIME, "versions": state.versions, "models": state.models,
                     "voice": {"state": state.voice_state}})
    if state.asr is not None:
        state.load_asr_background()
    threading.Event().wait()
    return 0
