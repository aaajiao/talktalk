"""Pinned text goes on the end of the prompt, once, and the result restates it."""
import unittest

import numpy as np

from talktalk_engine.asr import ASRModel


class FakeTokenizer:
    def encode(self, text, add_special_tokens=True):
        return [ord(c) for c in text]

    def decode(self, ids, skip_special_tokens=True):
        return "".join(chr(i) for i in ids)


class FakeModel:
    def __init__(self):
        self._tokenizer = FakeTokenizer()
        self.prompts = []

    def _build_prompt(self, num_audio_tokens, language, system_prompt):
        return np.array([[1, 2]], dtype=np.int32)

    def stream_generate(self, audio, max_tokens, language, system_prompt):
        self.prompts.append(self._build_prompt(0, language, system_prompt)[0].tolist())
        yield ord(" "), None
        yield ord("b"), None


def run(asr, **kwargs):
    return [item for item in asr.stream(np.zeros(16000), **kwargs) if item is not None][-1]


class PinnedTextTests(unittest.TestCase):
    def setUp(self):
        self.asr = ASRModel("asr", "path", "rev")
        self.asr.model = FakeModel()
        self.asr.mx = np
        self.asr._extend_prompts()

    def test_prompt_carries_the_text_and_the_result_restates_it(self):
        result = run(self.asr, hint="en", pinned_text="A.")
        self.assertEqual(self.asr.model.prompts, [[1, 2, ord("A"), ord(".")]])
        self.assertEqual(result["text"], "A. b")
        self.assertEqual(result["timing"]["pinned_tokens"], 2)
        self.assertEqual(result["timing"]["tokens"], 2)

    def test_the_next_read_is_not_pinned(self):
        run(self.asr, hint="en", pinned_text="A.")
        self.assertEqual(run(self.asr, hint="en")["text"], "b")
        self.assertEqual(self.asr.model.prompts[1], [1, 2])

    def test_without_a_language_the_text_is_ignored(self):
        self.assertEqual(run(self.asr, pinned_text="A.")["text"], "b")
        self.assertEqual(self.asr.model.prompts, [[1, 2]])


if __name__ == "__main__":
    unittest.main()
