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
    def __init__(self, output=" b"):
        self._tokenizer = FakeTokenizer()
        self.prompts = []
        self.system_prompts = []
        self.output = output

    def _build_prompt(self, num_audio_tokens, language, system_prompt):
        return np.array([[1, 2]], dtype=np.int32)

    def stream_generate(self, audio, max_tokens, language, system_prompt):
        self.system_prompts.append(system_prompt)
        self.prompts.append(self._build_prompt(0, language, system_prompt)[0].tolist())
        for c in self.output:
            yield ord(c), None


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

    def test_french_hint_keeps_explicit_language_and_pinned_text(self):
        result = run(self.asr, hint="fr", pinned_text="L’état.")
        self.assertEqual(result["language"], "French")
        self.assertEqual(result["text"], "L’état. b")
        self.assertEqual(self.asr.model.prompts, [[1, 2] + [ord(c) for c in "L’état."]])

    def test_without_a_language_the_text_is_ignored(self):
        self.assertEqual(run(self.asr, pinned_text="A.")["text"], "b")
        self.assertEqual(self.asr.model.prompts, [[1, 2]])

    def test_unhinted_reading_reports_the_model_language_tag(self):
        self.asr.model.output = "language German<asr_text>Guten Tag."
        result = run(self.asr)
        self.assertEqual((result["language"], result["text"]), ("German", "Guten Tag."))

    def test_unhinted_reading_without_a_tag_or_speech_has_no_language(self):
        # The same result whichever mlx-audio runtime is installed (0.6.4 said "English"/"None").
        self.asr.model.output = "plain words"
        self.assertEqual((run(self.asr)["language"], run(self.asr)["text"]), (None, "plain words"))
        self.asr.model.output = "language None<asr_text>"
        result = run(self.asr)
        self.assertEqual((result["language"], result["text"]), (None, ""))

    def test_a_hint_overrides_any_tag(self):
        self.asr.model.output = "language English<asr_text>b"
        self.assertEqual(run(self.asr, hint="fr")["language"], "French")

    def test_context_keeps_the_newline_the_older_runtime_added(self):
        # mlx-audio 0.6.4 built "{context}\n"; 0.6.8 builds "{context}" as given.
        run(self.asr, hint="zh", context="上一句。")
        run(self.asr, hint="zh")
        run(self.asr, hint="zh", context="")
        self.assertEqual(self.asr.model.system_prompts, ["上一句。\n", None, None])


if __name__ == "__main__":
    unittest.main()
