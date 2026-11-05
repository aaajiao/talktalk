"""HTTP API v2 auth, host check, errors and TTS streaming against a fake engine state."""
import http.client
import json
import threading
import unittest

from talktalk_engine import frames, server
from talktalk_engine.scheduler import GpuScheduler, Job, P0

TOKEN = "t" * 64


class FakeState:
    def __init__(self):
        self.token = TOKEN
        self.sched = GpuScheduler()
        self.voice = object()
        self.asr = None
        self.asr_state = "absent"
        self.tts_requests = 0

    def health(self):
        return {"ok": True}

    def tts_job(self, req, out):
        def gen():
            out.put(("pcm", b"\x00" * 16))
            out.put(("tail", {"timing": {"total_ms": 1.0}}))
            return
            yield  # noqa: unreachable - makes this a generator
        j = Job("tts", P0, gen)
        threading.Thread(target=lambda: [x for x in j.factory()], daemon=True).start()
        return j


class ServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.state = FakeState()
        try:
            cls.srv = server.serve(cls.state)
        except PermissionError as e:   # Claude Code sandbox without allowLocalBinding
            raise unittest.SkipTest(f"cannot bind 127.0.0.1 here ({e}); run outside the sandbox")
        cls.port = cls.srv.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()

    def req(self, method, path, body=None, host=None, token=TOKEN):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        h = {"Host": host or f"127.0.0.1:{self.port}"}
        if token:
            h["Authorization"] = "Bearer " + token
        c.request(method, path, body=json.dumps(body).encode() if body is not None else None, headers=h)
        r = c.getresponse()
        data = r.read()
        c.close()
        return r.status, data

    def test_binds_loopback_only(self):
        self.assertEqual(self.srv.server_address[0], "127.0.0.1")

    def test_auth_and_host(self):
        self.assertEqual(self.req("GET", "/v1/health")[0], 200)
        self.assertEqual(self.req("GET", "/v1/health", token=None)[0], 401)
        self.assertEqual(self.req("GET", "/v1/health", token="x" * 64)[0], 401)
        st, data = self.req("GET", "/v1/health", host="evil.example:80")
        self.assertEqual(st, 403)
        self.assertEqual(json.loads(data)["error"]["code"], "bad_host")

    def test_unknown_route(self):
        self.assertEqual(self.req("GET", "/v1/nope")[0], 404)

    def test_tts_validation(self):
        st, data = self.req("POST", "/v1/tts", {"text": "!", "lang": "en"})
        self.assertEqual((st, json.loads(data)["error"]["code"]), (400, "text_too_short"))
        st, data = self.req("POST", "/v1/tts", {"text": "Hello", "lang": "fr"})
        self.assertEqual(st, 400)

    def test_tts_streams_frames(self):
        st, data = self.req("POST", "/v1/tts", {"text": "Hello there", "lang": "en"})
        self.assertEqual(st, 200)
        kinds = [k for k, _ in frames.decode_all(data)]
        self.assertEqual(kinds, [frames.JSON_HEAD, frames.PCM_F32_24K, frames.JSON_TAIL])

    def test_asr_not_ready(self):
        st, data = self.req("POST", "/v1/asr", {})
        self.assertEqual((st, json.loads(data)["error"]["code"]), (409, "asr_not_ready"))


if __name__ == "__main__":
    unittest.main()
