"""Frame codec (§4.4). Run: python3 -I -m unittest discover -s engine/tests -t engine"""
import struct
import unittest

from talktalk_engine import frames


class FramesTests(unittest.TestCase):
    def test_roundtrip_all_kinds(self):
        parts = [(frames.JSON_HEAD, {"a": 1}), (frames.PCM_F32_24K, b"\x00" * 8), (frames.BLOB, b"xyz"),
                 (frames.PCM_S16_16K, b"\x01\x02"), (frames.JSON_TAIL, {"t": 2}), (frames.JSON_ERROR, {"e": 3})]
        data = b"".join(frames.encode(k, p) for k, p in parts)
        out = frames.decode_all(data)
        self.assertEqual([k for k, _ in out], [k for k, _ in parts])
        self.assertEqual(out[1][1], b"\x00" * 8)
        self.assertEqual(out[0][1], b'{"a":1}')

    def test_length_counts_kind_byte(self):
        b = frames.encode(frames.BLOB, b"abc")
        self.assertEqual(struct.unpack(">IB", b[:5]), (4, frames.BLOB))

    def test_rejects_bad_input(self):
        with self.assertRaises(frames.FrameError):
            frames.encode(9, b"")
        with self.assertRaises(frames.FrameError):
            frames.decode_all(b"\x00\x00")
        with self.assertRaises(frames.FrameError):
            frames.decode_all(struct.pack(">IB", 2, 9) + b"x")
        with self.assertRaises(frames.FrameError):
            frames.decode_all(struct.pack(">IB", frames.MAX_FRAME + 1, 1))

    def test_stream_decoder_handles_split_boundaries(self):
        data = frames.encode(frames.JSON_HEAD, {"x": 1}) + frames.encode(frames.PCM_F32_24K, b"\x01" * 4000)
        dec = frames.StreamDecoder()
        got = []
        for i in range(0, len(data), 7):
            got += dec.feed(data[i:i + 7])
        self.assertEqual([k for k, _ in got], [frames.JSON_HEAD, frames.PCM_F32_24K])
        self.assertEqual(len(got[1][1]), 4000)


if __name__ == "__main__":
    unittest.main()
