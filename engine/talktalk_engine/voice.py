"""Voice conditioning (§4.4 /v1/voice/build|load, §9.3).

A voice is the reference-derived state Base ICL needs on every generation:
  ref_codes [1, 16, T] int32, ref_text_ids [1, L] int32, speaker_embed [1, D].
The engine never sees a path: /v1/voice/build receives PCM bytes plus ref_text and returns a
safetensors blob; /v1/voice/load receives that blob. Nothing is written to disk here.
"""
import hashlib
import json
from dataclasses import dataclass, field

import numpy as np


@dataclass
class Voice:
    key: str
    ref_text: str
    ref_codes: object          # mx.array [1, 16, T]
    ref_text_ids: object       # mx.array [1, L]
    speaker_embed: object      # mx.array [1, D] (x-vector; ICL also uses it)
    meta: dict = field(default_factory=dict)

    @property
    def key8(self):
        return hashlib.sha256(self.key.encode()).hexdigest()[:8]

    @property
    def ref_frames(self):
        return int(self.ref_codes.shape[2])


def audio_fingerprint(pcm):
    """Stable content hash of reference PCM (float32 or int16)."""
    a = np.ascontiguousarray(pcm)
    return hashlib.sha256(a.dtype.str.encode() + a.tobytes()).hexdigest()


def to_blob(voice):
    """Serialises a Voice to safetensors bytes (kind 5 frame payload)."""
    import mlx.core as mx

    arrays = {
        "ref_codes": voice.ref_codes.astype(mx.int32),
        "ref_text_ids": voice.ref_text_ids.astype(mx.int32),
        "speaker_embed": voice.speaker_embed.astype(mx.float32),
    }
    meta = {"key": voice.key, "ref_text": voice.ref_text, "meta": json.dumps(voice.meta)}
    # Encoded in memory (mx.save_safetensors only writes to paths; the engine never writes files).
    return _encode_safetensors({k: np.array(v) for k, v in arrays.items()}, meta)


def from_blob(blob):
    import mlx.core as mx

    tensors, meta = _decode_safetensors(blob)
    return Voice(
        key=meta["key"],
        ref_text=meta["ref_text"],
        ref_codes=mx.array(tensors["ref_codes"]),
        ref_text_ids=mx.array(tensors["ref_text_ids"]),
        speaker_embed=mx.array(tensors["speaker_embed"]),
        meta=json.loads(meta.get("meta", "{}")),
    )


_DTYPES = {np.dtype("int32"): "I32", np.dtype("float32"): "F32"}
_NP = {"I32": np.int32, "F32": np.float32}


def _encode_safetensors(tensors, metadata):
    header = {"__metadata__": {k: str(v) for k, v in metadata.items()}}
    offset = 0
    payload = []
    for name in sorted(tensors):
        a = np.ascontiguousarray(tensors[name])
        b = a.tobytes()
        header[name] = {"dtype": _DTYPES[a.dtype], "shape": list(a.shape), "data_offsets": [offset, offset + len(b)]}
        offset += len(b)
        payload.append(b)
    h = json.dumps(header, separators=(",", ":")).encode()
    h += b" " * ((8 - len(h) % 8) % 8)
    return len(h).to_bytes(8, "little") + h + b"".join(payload)


def _decode_safetensors(blob):
    n = int.from_bytes(blob[:8], "little")
    if n <= 0 or n > len(blob) - 8:
        raise ValueError("bad safetensors header")
    header = json.loads(blob[8:8 + n])
    meta = header.pop("__metadata__", {})
    base = 8 + n
    out = {}
    for name, info in header.items():
        s, e = info["data_offsets"]
        out[name] = np.frombuffer(blob[base + s:base + e], dtype=_NP[info["dtype"]]).reshape(info["shape"])
    return out, meta
