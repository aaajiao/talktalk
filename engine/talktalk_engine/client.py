"""Minimal engine client for the installer smoke run and the M0 benches (stdlib + numpy only).

Spawns the engine the way the app's EngineProcess will (§7.6): own process group, stdin pipe held
by the parent, fd 1 = handshake pipe, fd 2 appended to a log file, a fully rebuilt environment
(nothing inherited, so no READREAD_* or OPENAI_API_KEY can leak in), per-launch token.
Never imports MLX (benches using this client must stay off the GPU).
"""
import http.client
import json
import os
import secrets
import select
import signal
import subprocess
import time
from pathlib import Path

import numpy as np

from . import frames

AUDIBLE_DBFS = -40.0
_AUDIBLE = 10 ** (AUDIBLE_DBFS / 20)


def clean_env(cache_dir, token):
    cache = Path(cache_dir)
    for sub in ("engine-tmp", "hf"):
        (cache / sub).mkdir(parents=True, exist_ok=True)
    return {
        "HOME": os.environ.get("HOME", ""),
        "LANG": os.environ.get("LANG", "en_US.UTF-8"),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR": str(cache / "engine-tmp"),
        "TALKTALK_TOKEN": token,
        "TALKTALK_CACHE_DIR": str(cache),
        "HF_HOME": str(cache / "hf"),
        "HF_HUB_OFFLINE": "1",
        "TRANSFORMERS_OFFLINE": "1",
        "HF_HUB_DISABLE_TELEMETRY": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
        "MLX_METAL_RESIDENCY_REFRESH_INTERVAL_MS": "1000",
    }


class EngineError(RuntimeError):
    pass


class Engine:
    def __init__(self, python, engine_src, models_dirs, roles="tts,asr", tts=None, asr=None, warmup_dir=None,
                 cache_dir=None, log_path=None, extra_args=(), env_extra=None, entry=None):
        self.python = str(python)
        # `entry` exists for the fake-model engine tests (tests/fakes/run_fake_engine.py) only.
        self.entry = str(entry or Path(engine_src) / "talktalk_engine.py")
        self.models_dirs = [str(d) for d in models_dirs]
        self.roles = roles
        self.tts_key = tts
        self.asr_key = asr
        self.warmup_dir = warmup_dir
        self.cache_dir = cache_dir or str(Path.home() / "Library/Caches/TalkTalk")
        self.log_path = log_path
        self.extra_args = list(extra_args)
        self.env_extra = env_extra or {}
        self.proc = None
        self.ready = None
        self.progress = []
        self.token = secrets.token_hex(32)
        self.port = None
        self.ready_s = None
        self.handshake_closed = False

    # ------------------------------------------------------------ lifecycle

    def start(self, timeout=180.0):
        args = [self.python, "-I", "-B", self.entry, "--roles", self.roles]
        for d in self.models_dirs:
            args += ["--models-dir", d]
        if self.tts_key:
            args += ["--tts", self.tts_key]
        if self.asr_key:
            args += ["--asr", self.asr_key]
        if self.warmup_dir:
            args += ["--warmup-dir", str(self.warmup_dir)]
        args += self.extra_args
        env = clean_env(self.cache_dir, self.token)
        env.update(self.env_extra)
        r, w = os.pipe()
        log = open(self.log_path, "ab") if self.log_path else subprocess.DEVNULL
        t0 = time.perf_counter()
        self.proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=w, stderr=log, env=env,
                                     start_new_session=True, close_fds=True)
        os.close(w)
        if log is not subprocess.DEVNULL:
            log.close()
        buf = b""
        deadline = time.monotonic() + timeout
        try:
            while True:
                left = deadline - time.monotonic()
                if left <= 0:
                    raise EngineError("engine did not become READY in time")
                ready, _, _ = select.select([r], [], [], min(left, 1.0))
                if not ready:
                    if self.proc.poll() is not None:
                        raise EngineError(f"engine exited with {self.proc.returncode} before READY")
                    continue
                chunk = os.read(r, 65536)
                if not chunk:
                    raise EngineError(f"handshake closed without READY (exit {self.proc.poll()})")
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    kind, _, payload = line.decode().partition(" ")
                    obj = json.loads(payload) if payload else {}
                    if kind == "PROGRESS":
                        self.progress.append(obj)
                    elif kind == "READY":
                        self.ready = obj
                        self.port = obj["port"]
                        self.ready_s = time.perf_counter() - t0
                        self._handshake_fd = r
                        return self
                    elif kind == "FATAL":
                        raise EngineError("FATAL " + obj.get("message", ""))
                    else:
                        raise EngineError(f"unexpected handshake line {kind!r}")
        except BaseException:
            self.stop()
            raise

    def handshake_extra_lines(self, wait=0.05):
        """Anything written to the handshake fd after READY (must be nothing; M0-T0).

        The engine closes its end right after READY, so EOF here is the expected state
        (`self.handshake_closed` becomes True) and nothing can be written afterwards."""
        fd = getattr(self, "_handshake_fd", None)
        if fd is None:
            return b""
        out = b""
        while True:
            ready, _, _ = select.select([fd], [], [], wait)
            if not ready:
                return out
            chunk = os.read(fd, 65536)
            if not chunk:
                os.close(fd)
                self._handshake_fd = None
                self.handshake_closed = True
                return out
            out += chunk

    def stop(self, grace=1.0):
        p = self.proc
        if p is None or p.poll() is not None:
            return p.returncode if p else None
        try:
            p.stdin.close()
        except OSError:
            pass
        try:
            return p.wait(grace)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(p.pid, signal.SIGTERM)
            return p.wait(2.0)
        except (subprocess.TimeoutExpired, ProcessLookupError):
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            return p.wait()

    @property
    def pid(self):
        return self.proc.pid if self.proc else None

    # ------------------------------------------------------------ HTTP

    def _conn(self, timeout=600):
        return http.client.HTTPConnection("127.0.0.1", self.port, timeout=timeout)

    def _headers(self, ctype=None):
        h = {"Host": f"127.0.0.1:{self.port}", "Authorization": "Bearer " + self.token}
        if ctype:
            h["Content-Type"] = ctype
        return h

    def request(self, method, path, body=None, ctype=None, timeout=600):
        c = self._conn(timeout)
        try:
            if isinstance(body, (dict, list)):
                body = json.dumps(body).encode()
                ctype = ctype or "application/json"
            c.request(method, path, body=body, headers=self._headers(ctype))
            resp = c.getresponse()
            data = resp.read()
            return resp.status, data
        finally:
            c.close()

    def json(self, method, path, body=None, expect=(200,), **kw):
        status, data = self.request(method, path, body, **kw)
        if status not in expect:
            raise EngineError(f"{method} {path}: HTTP {status} {data[:200]!r}")
        return json.loads(data) if data else None

    def health(self):
        return self.json("GET", "/v1/health")

    def build_voice(self, pcm24k, ref_text):
        body = frames.encode(frames.JSON_HEAD, {"mode": "icl", "ref_text": ref_text, "lang": "zh"}) + \
            frames.encode(frames.PCM_F32_24K, np.ascontiguousarray(pcm24k, dtype="<f4").tobytes())
        status, data = self.request("POST", "/v1/voice/build", body, ctype="application/x-talktalk-frames")
        if status != 200:
            raise EngineError(f"voice/build: HTTP {status} {data[:200]!r}")
        parts = frames.decode_all(data)
        head = json.loads(next(p for k, p in parts if k == frames.JSON_HEAD))
        blob = next(p for k, p in parts if k == frames.BLOB)
        return head, blob

    def load_voice(self, blob, wait_ready=True, timeout=60):
        body = frames.encode(frames.JSON_HEAD, {}) + frames.encode(frames.BLOB, blob)
        status, data = self.request("POST", "/v1/voice/load", body, ctype="application/x-talktalk-frames")
        if status != 202:
            raise EngineError(f"voice/load: HTTP {status} {data[:200]!r}")
        if wait_ready:
            end = time.monotonic() + timeout
            while time.monotonic() < end:
                if self.health()["voice"]["state"] == "ready":
                    return True
                time.sleep(0.05)
            raise EngineError("voice did not become ready")
        return True

    def similarity(self, ref24k, sample24k):
        """/v1/voice/similarity: x-vector cosine of two 24 kHz float clips."""
        body = frames.encode(frames.JSON_HEAD, {}) + \
            frames.encode(frames.PCM_F32_24K, np.ascontiguousarray(ref24k, dtype="<f4").tobytes()) + \
            frames.encode(frames.PCM_F32_24K, np.ascontiguousarray(sample24k, dtype="<f4").tobytes())
        return float(self.json("POST", "/v1/voice/similarity", body, ctype="application/x-talktalk-frames")["cosine"])

    def wait_asr(self, timeout=180):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            st = self.health()["models"].get("asr", {}).get("state")
            if st == "ready":
                return True
            if st == "failed":
                raise EngineError("ASR failed to load")
            time.sleep(0.1)
        raise EngineError("ASR not ready in time")

    def asr(self, pcm16k_float, hint="zh", priority=1, context=None):
        pcm = np.clip(np.asarray(pcm16k_float) * 32768.0, -32768, 32767).astype("<i2").tobytes()
        body = frames.encode(frames.JSON_HEAD, {"context": context} if context else {}) + \
            frames.encode(frames.PCM_S16_16K, pcm)
        t0 = time.perf_counter()
        status, data = self.request("POST", f"/v1/asr?hint={hint}&priority={priority}", body,
                                    ctype="application/x-talktalk-frames")
        ms = (time.perf_counter() - t0) * 1e3
        if status != 200:
            raise EngineError(f"asr: HTTP {status} {data[:200]!r}")
        r = json.loads(data)
        r["client_ms"] = ms
        return r

    def tts(self, req, on_chunk=None, timeout=600):
        """Streams /v1/tts. Returns (pcm float32, tail, client timing dict)."""
        c = self._conn(timeout)
        body = json.dumps(req).encode()
        t0 = time.perf_counter()
        c.request("POST", "/v1/tts", body=body, headers=self._headers("application/json"))
        resp = c.getresponse()
        if resp.status != 200:
            data = resp.read()
            c.close()
            raise EngineError(f"tts: HTTP {resp.status} {data[:200]!r}")
        dec = frames.StreamDecoder()
        chunks, arrivals = [], []
        head = tail = err = None
        t_first_byte = t_audible = None
        samples = 0
        while True:
            data = resp.read1(65536) if hasattr(resp, "read1") else resp.read(4096)
            if not data:
                break
            now = time.perf_counter()
            if t_first_byte is None:
                t_first_byte = now
            for kind, payload in dec.feed(data):
                if kind == frames.JSON_HEAD:
                    head = json.loads(payload)
                elif kind == frames.PCM_F32_24K:
                    a = np.frombuffer(payload, dtype="<f4")
                    if t_audible is None:
                        idx = np.nonzero(np.abs(a) > _AUDIBLE)[0]
                        if idx.size:
                            # first audible sample: arrival time of its chunk (it is playable from then on)
                            t_audible = now
                            first_audible_sample = samples + int(idx[0])
                    samples += len(a)
                    chunks.append(a)
                    arrivals.append((now - t0) * 1e3)
                    if on_chunk:
                        on_chunk(a, now)
                elif kind == frames.JSON_TAIL:
                    tail = json.loads(payload)
                elif kind == frames.JSON_ERROR:
                    err = json.loads(payload)
        c.close()
        if err:
            raise EngineError(f"tts error frame: {err}")
        pcm = np.concatenate(chunks) if chunks else np.zeros(0, dtype=np.float32)
        timing = {"first_byte_ms": (t_first_byte - t0) * 1e3 if t_first_byte else None,
                  "ttfa_ms": (t_audible - t0) * 1e3 if t_audible else None,
                  "first_audible_sample": locals().get("first_audible_sample"),
                  "chunk_arrival_ms": arrivals, "total_ms": (time.perf_counter() - t0) * 1e3,
                  "audio_s": len(pcm) / 24000.0}
        return pcm, tail, timing
