#!/usr/bin/env python3
"""Fake talktalk-engine for EngineHostTests (stdlib only: no MLX, no numpy, no models).

Speaks the real handshake (fd trick, PROGRESS / READY / FATAL) and the HTTP API v2 surface the
Swift host uses, with scripted misbehaviour chosen by --scenario. It ignores the real engine's
arguments it does not need. State for the tests goes to --state-dir:
  launches.txt   one line per launch: "<pid>"
  env.json       the environment it was started with (first launch only)
  argv.json      its argv
  cancels.txt    one line per /v1/cancel body
"""
import os
import sys

_HS = os.dup(1)
os.dup2(2, 1)

import argparse  # noqa: E402
import hashlib  # noqa: E402
import hmac  # noqa: E402
import itertools  # noqa: E402
import json  # noqa: E402
import signal  # noqa: E402
import struct  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer  # noqa: E402
from urllib.parse import parse_qs, urlparse  # noqa: E402


def hs(kind, obj):
    os.write(_HS, (kind + " " + json.dumps(obj, separators=(",", ":")) + "\n").encode())
    if kind in ("READY", "FATAL"):
        os.close(_HS)


p = argparse.ArgumentParser()
p.add_argument("--models-dir", action="append")
p.add_argument("--roles", default="tts,asr")
p.add_argument("--tts")
p.add_argument("--asr")
p.add_argument("--profile")
p.add_argument("--warmup-dir")
p.add_argument("--scenario", default="ok")
p.add_argument("--state-dir", required=True)
p.add_argument("--rev-tts", default="a" * 40)
p.add_argument("--rev-asr", default="c" * 40)
p.add_argument("--api", type=int, default=2)
p.add_argument("--ready-delay", type=float, default=0.0)
p.add_argument("--bad-launches", type=int, default=1, help="launches (1-based) that misbehave")
p.add_argument("--crash-after", type=float, default=0.3)
p.add_argument("--long-step", action="store_true")
p.add_argument("--tts-chunks", type=int, default=5)
p.add_argument("--tts-chunk-ms", type=float, default=50.0)
p.add_argument("--require-voice-key", action="store_true")
p.add_argument("--asr-first", action="store_true")
p.add_argument("--tts-loading", action="store_true", help="hold TTS until a tts_ready/tts_failed file appears")
p.add_argument("--asr-loading", action="store_true", help="hold ASR until an asr_ready/asr_failed file appears")
p.add_argument("--initial-voice-ready", action="store_true")
a, _ = p.parse_known_args()
roles = [r for r in a.roles.split(",") if r]

os.makedirs(a.state_dir, exist_ok=True)
with open(os.path.join(a.state_dir, "launches.txt"), "a") as f:
    f.write(f"{os.getpid()}\n")
with open(os.path.join(a.state_dir, "launches.txt")) as f:
    launch_no = sum(1 for _ in f)
bad = launch_no <= a.bad_launches
if launch_no == 1:
    with open(os.path.join(a.state_dir, "env.json"), "w") as f:
        json.dump(dict(os.environ), f)
    with open(os.path.join(a.state_dir, "argv.json"), "w") as f:
        json.dump(sys.argv, f)
with open(os.path.join(a.state_dir, f"argv-{launch_no}.json"), "w") as f:
    json.dump(sys.argv, f)

token = os.environ.get("TALKTALK_TOKEN", "")
if len(token) < 32:
    hs("FATAL", {"message": "TALKTALK_TOKEN missing or too short"})
    sys.exit(3)

scenario = a.scenario if bad else "ok"


def stdin_watch():
    while True:
        try:
            if not os.read(0, 4096):
                break
        except OSError:
            break
    sys.stderr.write("fake engine: stdin closed\n")
    os._exit(0)


if scenario == "ignore-term":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)   # only SIGKILL stops it; stdin EOF ignored too
else:
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
    threading.Thread(target=stdin_watch, daemon=True).start()

if scenario == "exit-before-ready":
    sys.exit(1)
if scenario == "fatal":
    hs("FATAL", {"message": "TTS model tts-x not found in /nowhere"})
    sys.exit(3)
if scenario == "garbage":
    os.write(_HS, b"hello from a library print\n")
    time.sleep(5)
    sys.exit(0)

state = {"voice": "absent", "voice_key": None, "hang": scenario == "hang-health", "step_age": scenario == "step-age",
         "last_step": time.monotonic()}
if a.initial_voice_ready:
    state.update(voice="ready", voice_key="k")
# The real engine renders TTS jobs one at a time; texts starting with "serial" share this lock.
serial_lock = threading.Lock()
# Job numbers as the real engine gives them on HTTP arrival (head frame `seq`).
job_seq = itertools.count(1)
# "order N" (N = 1..3): the requests arrived at the engine in reverse speak() order, so "order 3"
# gets the lowest seq and renders first, then 2, then 1 (00f65f3 review [低] H1).
order_turn = {"n": 3}
order_cv = threading.Condition()


def long_step_now():
    """--long-step, until the test drops a `long_step_off` file into the state dir."""
    return a.long_step and not os.path.exists(os.path.join(a.state_dir, "long_step_off"))
FRAMES = {"head": 1, "pcm": 2, "tail": 3, "error": 4, "blob": 5, "progress": 7}


def frame(kind, payload):
    if isinstance(payload, (dict, list)):
        payload = json.dumps(payload).encode()
    return struct.pack(">IB", len(payload) + 1, FRAMES[kind]) + payload


request_log_lock = threading.Lock()


def current_models():
    result = {role: dict(model) for role, model in models.items()}
    for role, loading in (("tts", a.tts_loading), ("asr", a.asr_loading)):
        if loading and role in result:
            if os.path.exists(os.path.join(a.state_dir, role + "_failed")):
                result[role]["state"] = "failed"
            elif os.path.exists(os.path.join(a.state_dir, role + "_ready")):
                result[role]["state"] = "ready"
            else:
                result[role]["state"] = "loading"
    return result


def record_request(method, path, body=None):
    item = {"method": method, "path": path, "pid": os.getpid(),
            "tts_state": current_models().get("tts", {}).get("state")}
    if path == "/v1/tts":
        item["request"] = json.loads(body or b"{}")
    with request_log_lock:
        with open(os.path.join(a.state_dir, "requests.jsonl"), "a") as f:
            f.write(json.dumps(item) + "\n")


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, code, obj=None, ctype="application/json", raw=None):
        data = raw if raw is not None else (json.dumps(obj).encode() if obj is not None else b"")
        self.send_response(code)
        if data:
            self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _ok(self):
        port = self.server.server_address[1]
        if self.headers.get("Host") not in (f"127.0.0.1:{port}", f"localhost:{port}"):
            self._send(403, {"error": {"code": "bad_host", "message": "host"}})
            return False
        if not hmac.compare_digest(self.headers.get("Authorization", "").encode(), ("Bearer " + token).encode()):
            self._send(401, {"error": {"code": "unauthorized", "message": "token"}})
            return False
        return True

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def do_GET(self):
        if not self._ok():
            return
        path = urlparse(self.path).path
        record_request("GET", path)
        if path == "/v1/health":
            if state["hang"] or os.path.exists(os.path.join(a.state_dir, "health_hang")):
                time.sleep(3600)
            idle_ms = round((time.monotonic() - state["last_step"]) * 1000, 1)   # grows while idle
            gpu = {"last_step_age_ms": 5000.0 if state["step_age"] else idle_ms, "in_long_step": long_step_now(),
                   "queue": {"p0": 1 if state["step_age"] else 0, "p1": 0, "p2": 0, "p3": 0},
                   "expired_dropped": 0, "tts_rtf_recent": 0.27,
                   "step_p99": {"tts.first": 88.5, "tts": 41.0}}
            self._send(200, {"status": "ok", "api": a.api, "pid": os.getpid(), "runtime": "python-mlx",
                             "models": current_models(), "voice": {"state": state["voice"], "key8":
                                 hashlib.sha256(state["voice_key"].encode()).hexdigest()[:8] if state["voice_key"] else None},
                             "gpu": gpu, "mem": {"active": 1, "cache": 0, "peak": 2}})
        elif path == "/v1/stats":
            self._send(200, {"steps": {}, "tts_requests": 0})
        else:
            self._send(404, {"error": {"code": "not_found", "message": path}})

    def do_POST(self):
        if not self._ok():
            return
        url = urlparse(self.path)
        body = self._body()
        record_request("POST", url.path, body)
        if (a.tts_loading and url.path in ("/v1/tts", "/v1/voice/build", "/v1/voice/load", "/v1/voice/similarity")
                and current_models().get("tts", {}).get("state") != "ready"):
            self._send(409, {"error": {"code": "tts_not_ready", "message": "fake TTS is still warming"}})
            return
        if url.path == "/v1/cancel":
            with open(os.path.join(a.state_dir, "cancels.txt"), "a") as f:
                f.write(body.decode() + "\n")
            self._send(204)
        elif url.path == "/v1/playout":
            with open(os.path.join(a.state_dir, "playouts.txt"), "a") as f:
                f.write(body.decode() + "\n")
            self._send(204)
        elif url.path == "/v1/session":
            self._send(204)
        elif url.path == "/v1/voice/build":
            self._send(200, ctype="application/x-talktalk-frames",
                       raw=frame("head", {"ms": {"encode_ms": 1.0}, "key_material": "k" * 16, "frames": 120})
                       + frame("blob", b"BLOB" * 8))
        elif url.path == "/v1/voice/similarity":
            pcm, i = [], 0
            while i + 5 <= len(body):
                n, kind = struct.unpack(">IB", body[i:i + 5])
                if kind == FRAMES["pcm"]:
                    pcm.append(body[i + 5:i + 4 + n])
                i += 4 + n
            if len(pcm) != 2:
                self._send(400, {"error": {"code": "bad_request", "message": "two kind 2 frames"}})
            elif min(len(p) for p in pcm) < 12000 * 4:
                self._send(400, {"error": {"code": "audio_too_short", "message": "0.5 s"}})
            else:
                self._send(200, {"cosine": 1.0 if pcm[0] == pcm[1] else 0.5})
        elif url.path == "/v1/voice/load":
            n, kind = struct.unpack(">IB", body[:5])
            head = json.loads(body[5:4 + n]) if kind == FRAMES["head"] else {}
            state["voice_key"] = "other-voice" if scenario == "voice-key-mismatch" else head.get("key", "fake-voice")
            state["voice"] = "ready"
            self._send(202)
        elif url.path == "/v1/voice/unload":
            state["voice"] = "absent"
            state["voice_key"] = None
            self._send(204)
        elif url.path == "/v1/asr":
            hint = (parse_qs(url.query).get("hint") or [None])[0]
            self._send(200, {"text": "今天十点开会", "language": hint or "zh", "timing": {"total_ms": 12.5, "x": None}})
        elif url.path == "/v1/tts":
            req = json.loads(body or b"{}")
            if state["voice"] != "ready":
                self._send(409, {"error": {"code": "voice_absent", "message": "no voice loaded"}})
                return
            if (a.require_voice_key or "voice_key" in req) and req.get("voice_key") != state["voice_key"]:
                self._send(409, {"error": {"code": "voice_key_mismatch", "message": "loaded voice does not match the requested voice"}})
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/x-talktalk-frames")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()

            def chunk(d):
                self.wfile.write(b"%x\r\n" % len(d) + d + b"\r\n")
                self.wfile.flush()

            try:
                text = req.get("text") or ""
                seq = next(job_seq)
                if text.startswith("order "):
                    seq = 100 - int(text.split()[1])
                chunk(frame("head", {"sample_rate": 24000, "job": req.get("job"), "seq": seq}))
                if text.startswith("order "):
                    me = int(text.split()[1])
                    with order_cv:
                        order_cv.wait_for(lambda: order_turn["n"] == me, timeout=20)
                    for i in range(6):
                        time.sleep(0.15)
                        chunk(frame("pcm", struct.pack("<1920f", *([0.25] * 1920))))
                        state["last_step"] = time.monotonic()
                    chunk(frame("tail", {"audio_s": 0.48, "frames": 12, "runaway": False, "short": False,
                                         "slow": True, "cancelled": False, "expected_s": 0.4, "timing": {}}))
                    self.wfile.write(b"0\r\n\r\n")
                    self.wfile.flush()
                    with order_cv:
                        order_turn["n"] = me - 1
                        order_cv.notify_all()
                    return
                if text == "parked":
                    # one chunk, then the engine is parked (paused playback / at the horizon) for
                    # 3 s, then the rest of the clause (00f65f3 review [中])
                    chunk(frame("pcm", struct.pack("<1920f", *([0.25] * 1920))))
                    time.sleep(3)
                    for i in range(4):
                        time.sleep(0.05)
                        chunk(frame("pcm", struct.pack("<1920f", *([0.25] * 1920))))
                    chunk(frame("tail", {"audio_s": 0.4, "frames": 10, "runaway": False, "short": False,
                                         "slow": False, "cancelled": False, "expected_s": 0.4, "timing": {}}))
                    self.wfile.write(b"0\r\n\r\n")
                    self.wfile.flush()
                    return
                if text == "stall zero":
                    # zero-chunk stall (or a job queued behind a hung one): head, then nothing
                    time.sleep(20)
                    return
                if text == "whole retry":
                    # whole clause held to the end, first attempt runs away, retry passes: 1.2 s of
                    # progress frames and no audio, then the clause (review [3])
                    for i in range(8):
                        time.sleep(0.15)
                        chunk(frame("progress", {"held_s": round(0.16 * (i % 4 + 1), 3), "attempt": 1 + i // 4}))
                if text == "serial slow":
                    # slower than real time but steady: 10 chunks 150 ms apart, holding the GPU
                    with serial_lock:
                        for i in range(10):
                            time.sleep(0.15)
                            chunk(frame("pcm", struct.pack("<1920f", *([0.25] * 1920))))
                            state["last_step"] = time.monotonic()
                        chunk(frame("tail", {"audio_s": 0.8, "frames": 20, "runaway": False, "short": False,
                                             "slow": True, "cancelled": False, "expected_s": 0.4, "timing": {}}))
                    self.wfile.write(b"0\r\n\r\n")
                    self.wfile.flush()
                    return
                if text.startswith("serial"):
                    serial_lock.acquire()
                    serial_lock.release()
                if req.get("text") in ("stall please", "stall hang"):
                    # SPEAK stall rule tests: one chunk, then nothing. "stall hang" also makes
                    # health report a pending job with no GPU step (a hung engine).
                    chunk(frame("pcm", struct.pack("<1920f", *([0.25] * 1920))))
                    if req.get("text") == "stall hang":
                        state["step_age"] = True
                    time.sleep(20)
                    return
                n = 0
                for i in range(a.tts_chunks):
                    time.sleep(a.tts_chunk_ms / 1000)
                    pcm = struct.pack("<1920f", *([0.25] * 1920))
                    chunk(frame("pcm", pcm))
                    state["last_step"] = time.monotonic()
                    n += 1920
                if req.get("text") == "fail please":
                    chunk(frame("error", {"code": "tts_failed", "message": "RuntimeError"}))
                else:
                    chunk(frame("tail", {"audio_s": n / 24000, "frames": a.tts_chunks * 2, "runaway": False,
                                         "short": False, "slow": False, "cancelled": False, "expected_s": 0.4,
                                         "timing": {"total_ms": 100.0, "first_chunk_ms": 50.0, "prompt_len": 7,
                                                    "compiled": False, "frame_ms_p99": None}}))
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            self._send(404, {"error": {"code": "not_found", "message": url.path}})


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
srv.daemon_threads = True
threading.Thread(target=srv.serve_forever, daemon=True).start()

models = {}
if "tts" in roles:
    models["tts"] = {"id": a.tts, "rev": a.rev_tts, "state": "loading" if a.tts_loading else "ready"}
if "asr" in roles:
    models["asr"] = {"id": a.asr, "rev": a.rev_asr, "state": "loading" if a.asr_loading else "ready"}

hs("PROGRESS", {"step": "tts", "done": 0, "count": 2})
if scenario == "slow-ready":
    time.sleep(3600)
time.sleep(a.ready_delay)
hs("PROGRESS", {"step": "warmup", "done": 1, "count": 2})
hs("READY", {"port": srv.server_address[1], "pid": os.getpid(), "api": a.api if scenario != "api1" else 1,
             "engine": "talktalk-engine", "runtime": "python-mlx",
             "versions": {"mlx": "fake", "mlx_audio": "fake", "transformers": "fake", "python": "3"},
             "models": models, "voice": {"state": "absent"}})

if scenario == "crash-after-ready":
    time.sleep(a.crash_after)
    os._exit(9)
if scenario == "controlled-crash":
    while not os.path.exists(os.path.join(a.state_dir, "crash_now")):
        time.sleep(0.01)
    os._exit(9)
threading.Event().wait()
