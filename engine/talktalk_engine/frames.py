"""Binary frames (§4.4): [u32 BE length][u8 kind][payload]; length counts kind + payload."""
import json
import struct

JSON_HEAD = 1
PCM_F32_24K = 2
JSON_TAIL = 3
JSON_ERROR = 4
BLOB = 5
PCM_S16_16K = 6
# /v1/tts while the guards hold audio back (hold, whole clause, retries): proof of life for the
# app's stall rule (§5.7), no audio. Payload {held_s, attempt}.
JSON_PROGRESS = 7

KINDS = {JSON_HEAD, PCM_F32_24K, JSON_TAIL, JSON_ERROR, BLOB, PCM_S16_16K, JSON_PROGRESS}
MAX_FRAME = 4 * 1024 * 1024


class FrameError(ValueError):
    pass


def encode(kind, payload):
    if kind not in KINDS:
        raise FrameError(f"unknown frame kind {kind}")
    if isinstance(payload, (dict, list)):
        payload = json.dumps(payload, separators=(",", ":")).encode()
    return struct.pack(">IB", len(payload) + 1, kind) + payload


def decode_all(data):
    """Parses a complete body into [(kind, payload bytes)]."""
    out = []
    i = 0
    n = len(data)
    while i < n:
        if n - i < 5:
            raise FrameError("truncated frame header")
        length, kind = struct.unpack_from(">IB", data, i)
        if length < 1 or length > MAX_FRAME:
            raise FrameError(f"bad frame length {length}")
        if kind not in KINDS:
            raise FrameError(f"unknown frame kind {kind}")
        end = i + 4 + length
        if end > n:
            raise FrameError("truncated frame payload")
        out.append((kind, data[i + 5:end]))
        i = end
    return out


class StreamDecoder:
    """Incremental decoder for chunked responses (used by bench clients and tests)."""

    def __init__(self):
        self.buf = bytearray()

    def feed(self, data):
        self.buf.extend(data)
        out = []
        while len(self.buf) >= 5:
            length, kind = struct.unpack_from(">IB", self.buf, 0)
            if length < 1 or length > MAX_FRAME or kind not in KINDS:
                raise FrameError("bad frame")
            if len(self.buf) < 4 + length:
                break
            out.append((kind, bytes(self.buf[5:4 + length])))
            del self.buf[:4 + length]
        return out
