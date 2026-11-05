"""expected_seconds reads engine/talktalk_engine/expected_duration.json (the single data file shared
with Swift's ExpectedDuration)."""
import json
import unittest
from pathlib import Path

from talktalk_engine import tts

DATA = Path(tts.__file__).with_name("expected_duration.json")


class ExpectedDurationTests(unittest.TestCase):
    def test_file_shape(self):
        d = json.loads(DATA.read_text(encoding="utf-8"))
        self.assertEqual(d["version"], 1)
        self.assertEqual(set(d["languages"]), {"en", "de"})
        self.assertIn(d["default"], d["languages"])

    def test_values(self):
        self.assertAlmostEqual(tts.expected_seconds("one two three four five six seven eight nine ten", "en"),
                               0.391 + 0.340 * 10)
        self.assertAlmostEqual(tts.expected_seconds("eins zwei drei", "de"), 0.134 + 0.430 * 3)
        # at least one word; extra whitespace does not count
        self.assertAlmostEqual(tts.expected_seconds("", "en"), 0.391 + 0.340)
        self.assertAlmostEqual(tts.expected_seconds("  Guten   Morgen ", "de"), 0.134 + 0.430 * 2)

    def test_other_languages_use_the_default(self):
        self.assertAlmostEqual(tts.expected_seconds("a b", "fr"), tts.expected_seconds("a b", "de"))


if __name__ == "__main__":
    unittest.main()
