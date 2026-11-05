"""HTTP API v2 on 127.0.0.1:0 with a per-launch Bearer token and Host check (§4.4).

Logs carry request ids, lengths and timings only, never text.
"""
import hmac
import json
import queue
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import numpy as np

from . import frames
from .scheduler import P0, P1, P2, P3, Job

MAX_JSON = 1 << 20
MAX_BINARY = 4 << 20
_ALNUM = re.compile(r"[0-9A-Za-zÀ-ÖØ-öø-ÿ一-鿿]")


class ApiError(Exception):
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "talktalk-engine"
    sys_version = ""

    def log_message(self, fmt, *args):  # quiet default logging; we log our own lines
        pass

    def send_response(self, code, message=None):
        self._sent_status = code
        super().send_response(code, message)

    # ------------------------------------------------------------------ plumbing

    @property
    def state(self):
        return self.server.state

    def _check(self):
        host = self.headers.get("Host", "")
        port = self.server.server_address[1]
        if host not in (f"127.0.0.1:{port}", f"localhost:{port}"):
            raise ApiError(403, "bad_host", "Host header must be the loopback address")
        auth = self.headers.get("Authorization", "")
        if not hmac.compare_digest(auth.encode(), ("Bearer " + self.state.token).encode()):
            raise ApiError(401, "unauthorized", "missing or wrong token")

    def _body(self, limit):
        n = int(self.headers.get("Content-Length") or 0)
        if n > limit:
            raise ApiError(413, "too_large", f"body larger than {limit} bytes")
        return self.rfile.read(n) if n else b""

    def _json_body(self):
        raw = self._body(MAX_JSON)
        try:
            return json.loads(raw or b"{}")
        except ValueError:
            raise ApiError(400, "bad_json", "body is not JSON")

    def _send_json(self, status, obj):
        data = json.dumps(obj, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_empty(self, status):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _send_frames(self, status, parts):
        data = b"".join(frames.encode(k, p) for k, p in parts)
        self.send_response(status)
        self.send_header("Content-Type", "application/x-talktalk-frames")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _dispatch(self, method):
        t0 = time.perf_counter()
        url = urlparse(self.path)
        status = 200
        try:
            self._check()
            route = ROUTES.get((method, url.path))
            if route is None:
                raise ApiError(404, "not_found", f"no route {method} {url.path}")
            self._sent_status = None
            route(self, parse_qs(url.query))
            status = self._sent_status or 200
        except ApiError as e:
            status = e.status
            self._send_json(e.status, {"error": {"code": e.code, "message": e.message}})
        except (BrokenPipeError, ConnectionResetError):
            status = 499
        except Exception as e:  # noqa: BLE001
            status = 500
            print(f"engine: {method} {url.path} failed: {type(e).__name__}", file=sys.stderr)
            try:
                self._send_json(500, {"error": {"code": "internal", "message": type(e).__name__}})
            except OSError:
                pass
        ms = (time.perf_counter() - t0) * 1e3
        if url.path not in ("/v1/health", "/v1/playout"):
            print(f"engine: {method} {url.path} {status} {ms:.1f}ms", file=sys.stderr)

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    # ------------------------------------------------------------------ routes

    def r_health(self, q):
        self._send_json(200, self.state.health())

    def r_stats(self, q):
        steps = self.state.sched.stats()
        asr_sched = getattr(self.state, "asr_sched", self.state.sched)
        if asr_sched is not self.state.sched:
            steps.update(asr_sched.stats())
        self._send_json(200, {"steps": steps, "tts_requests": self.state.tts_requests})

    def r_session(self, q):
        b = self._json_body()
        for sch in _scheds(self.state):
            sch.set_session(bool(b.get("speak_active")))
        self._send_empty(204)

    def r_playout(self, q):
        b = self._json_body()
        self.state.sched.report_playout(float(b.get("bufferedMs", 0.0)))
        self._send_empty(204)

    def r_cancel(self, q):
        b = self._json_body()
        for sch in _scheds(self.state):
            sch.cancel(job_id=b.get("job"), scope=b.get("scope"))
        self._send_empty(204)

    def r_voice_build(self, q):
        parts = frames.decode_all(self._body(MAX_BINARY))
        head = next((json.loads(p) for k, p in parts if k == frames.JSON_HEAD), None)
        if not head or not head.get("ref_text"):
            raise ApiError(400, "bad_request", "voice/build needs a JSON head with ref_text")
        pcm = _pcm_24k(parts)
        voice, ms, blob = self.state.build_voice(pcm, head["ref_text"], head.get("model"))
        self._send_frames(200, [(frames.JSON_HEAD, {"ms": ms, "key_material": voice.key, "frames": voice.ref_frames}),
                                (frames.BLOB, blob)])

    def r_voice_load(self, q):
        parts = frames.decode_all(self._body(MAX_BINARY))
        blob = next((p for k, p in parts if k == frames.BLOB), None)
        if blob is None:
            raise ApiError(400, "bad_request", "voice/load needs a blob frame")
        self.state.load_voice(blob)
        self._send_empty(202)

    def r_voice_unload(self, q):
        self.state.unload_voice()
        self._send_empty(204)

    def r_voice_similarity(self, q):
        """Frames: JSON head {} + two kind-2 PCM frames (24 kHz f32): the reference, then the sample."""
        if self.state.tts is None:
            raise ApiError(409, "tts_not_loaded", "TTS model is not loaded")
        parts = frames.decode_all(self._body(MAX_BINARY))
        pcm = [np.frombuffer(p, dtype="<f4").astype(np.float32) for k, p in parts if k == frames.PCM_F32_24K]
        if len(pcm) != 2:
            raise ApiError(400, "bad_request", "similarity needs two kind 2 PCM frames: reference, sample")
        if min(len(pcm[0]), len(pcm[1])) < SIMILARITY_MIN_SAMPLES:
            raise ApiError(400, "audio_too_short", "each clip needs >= 0.5 s for a stable x-vector")
        self._send_json(200, {"cosine": round(self.state.similarity(pcm[0], pcm[1]), 6)})

    def r_asr(self, q):
        if self.state.asr is None or self.state.asr_state != "ready":
            raise ApiError(409, "asr_not_ready", "ASR model is not loaded")
        parts = frames.decode_all(self._body(MAX_BINARY))
        head = next((json.loads(p) for k, p in parts if k == frames.JSON_HEAD), {}) or {}
        pcm = b"".join(p for k, p in parts if k == frames.PCM_S16_16K)
        if not pcm:
            raise ApiError(400, "bad_request", "asr needs kind 6 PCM")
        audio = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0
        prio = int((q.get("priority") or ["1"])[0])
        hint = (q.get("hint") or [None])[0]
        result = self.state.run_asr(audio, hint, head.get("context"), prio, (q.get("job") or [None])[0])
        self._send_json(200, result)

    def r_tts(self, q):
        b = self._json_body()
        text = str(b.get("text") or "")
        if len(_ALNUM.findall(text)) < 2:
            raise ApiError(400, "text_too_short", "fewer than 2 letters or digits")
        if b.get("lang") not in ("en", "de"):
            raise ApiError(400, "bad_request", "lang must be en or de")
        if self.state.voice is None:
            raise ApiError(409, "voice_absent", "no voice loaded")
        out = queue.Queue()
        job = self.state.tts_job(b, out)
        self.send_response(200)
        self.send_header("Content-Type", "application/x-talktalk-frames")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def chunk(data):
            self.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
            self.wfile.flush()

        try:
            # seq: the scheduler's job number, given on arrival; TTS renders in this order, which the
            # app's stall board follows (concurrent requests race over separate connections)
            chunk(frames.encode(frames.JSON_HEAD, {"sample_rate": 24000, "job": job.job_id, "seq": job.seq}))
            while True:
                kind, payload = out.get()
                if kind == "pcm":
                    chunk(frames.encode(frames.PCM_F32_24K, payload))
                elif kind == "progress":
                    chunk(frames.encode(frames.JSON_PROGRESS, payload))
                elif kind == "tail":
                    chunk(frames.encode(frames.JSON_TAIL, payload))
                    break
                else:
                    chunk(frames.encode(frames.JSON_ERROR, payload))
                    break
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            job.cancel()          # client went away: same as /v1/cancel
            raise


ROUTES = {
    ("GET", "/v1/health"): Handler.r_health,
    ("GET", "/v1/stats"): Handler.r_stats,
    ("POST", "/v1/session"): Handler.r_session,
    ("POST", "/v1/playout"): Handler.r_playout,
    ("POST", "/v1/cancel"): Handler.r_cancel,
    ("POST", "/v1/voice/build"): Handler.r_voice_build,
    ("POST", "/v1/voice/load"): Handler.r_voice_load,
    ("POST", "/v1/voice/unload"): Handler.r_voice_unload,
    ("POST", "/v1/voice/similarity"): Handler.r_voice_similarity,
    ("POST", "/v1/asr"): Handler.r_asr,
    ("POST", "/v1/tts"): Handler.r_tts,
}


def _scheds(state):
    """The GPU scheduler(s): one in topology A, a second ASR one in M0-T2 topology B."""
    extra = getattr(state, "asr_sched", state.sched)
    return (state.sched,) if extra is state.sched else (state.sched, extra)


SIMILARITY_MIN_SAMPLES = 12000      # 0.5 s at 24 kHz: shorter clips give unstable x-vectors

def _pcm_24k(parts):
    f32 = b"".join(p for k, p in parts if k == frames.PCM_F32_24K)
    if f32:
        return np.frombuffer(f32, dtype="<f4").astype(np.float32)
    s16 = b"".join(p for k, p in parts if k == frames.PCM_S16_16K)
    if not s16:
        raise ApiError(400, "bad_request", "reference PCM missing (kind 2 or 6)")
    from scipy.signal import resample_poly
    audio = np.frombuffer(s16, dtype="<i2").astype(np.float32) / 32768.0
    return resample_poly(audio, 3, 2).astype(np.float32)


class EngineHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, state):
        super().__init__(("127.0.0.1", 0), Handler)
        self.state = state


def serve(state):
    srv = EngineHTTPServer(state)
    t = threading.Thread(target=srv.serve_forever, name="http", daemon=True)
    t.start()
    return srv
