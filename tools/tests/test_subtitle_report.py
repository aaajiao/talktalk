"""Subtitle revision identity stays distinct from visible video page excerpts."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import subtitle_report as sr  # noqa: E402


def event(at_ms, name, **fields):
    return {"t": at_ms * 1_000_000, "event": name, "configuration": 1, "sentence": 1, **fields}


class SubtitleReportTests(unittest.TestCase):
    def summarize(self, events, include_text=False):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "trace.jsonl"
            path.write_text("\n".join(json.dumps(item) for item in events), encoding="utf-8")
            return sr.report(path, include_text=include_text)

    def completed(self, source="First part. Second part.", target="第一部分。第二部分。", approx=False):
        return [
            event(0, "sentence_final", source=source),
            event(100, "mt_completed", source=source, translation=target, approx=approx),
            event(110, "subtitle_queued", kind="final", source=source, translation=target,
                  approx=approx, visible=True),
        ]

    def test_paged_final_matches_full_revision_and_preserves_actual_excerpts(self):
        source, target = "First part. Second part.", "第一部分。第二部分。"
        events = self.completed(source, target)
        events += [
            event(150, "subtitle_displayed", kind="final", source="First part.", translation="第一部分。",
                  cue_source=source, cue_translation=target, visible=True),
            event(300, "subtitle_displayed", kind="final", source="Second part.", translation="第二部分。",
                  cue_source=source, cue_translation=target, visible=True),
        ]
        report = self.summarize(events, include_text=True)
        row = report["segments"][0]
        self.assertEqual(row["status"], "displayed")
        self.assertEqual(row["mt_to_display_ms"], 50)
        self.assertEqual(row["source"], source)
        self.assertEqual(row["translation"], target)
        self.assertEqual(row["display_scope"], "visible_excerpts")
        self.assertEqual(row["visible_excerpt_count"], 2)
        self.assertEqual(row["visible_excerpts"], [
            {"source": "First part.", "translation": "第一部分。", "mt_to_display_ms": 50},
            {"source": "Second part.", "translation": "第二部分。", "mt_to_display_ms": 200},
        ])
        self.assertEqual(report["redisplay_count"], 0)
        # Text remains opt-in, including all new excerpt fields.
        metadata = self.summarize(events)["segments"][0]
        self.assertNotIn("source", metadata)
        self.assertNotIn("translation", metadata)
        self.assertNotIn("visible_excerpts", metadata)

    def test_one_approx_page_does_not_claim_the_unseen_remainder_was_visible(self):
        source, target = "Visible start. Unseen ending.", "可见开头。未显示结尾。"
        events = self.completed(source, target, approx=True)
        events += [
            event(160, "subtitle_displayed", kind="final", source="Visible start.", translation="≈ 可见开头。",
                  cue_source=source, cue_translation=target, approx=True, visible=True),
            event(180, "trace_stopped", reason="user"),
        ]
        report = self.summarize(events, include_text=True)
        row = report["segments"][0]
        self.assertEqual(row["status"], "displayed")
        self.assertEqual(row["mt_to_display_ms"], 60)
        self.assertEqual(row["visible_excerpt_count"], 1)
        self.assertEqual(row["visible_excerpts"], [
            {"source": "Visible start.", "translation": "≈ 可见开头。", "mt_to_display_ms": 60},
        ])
        self.assertTrue(any("not proof that every page was shown" in item for item in report["limitations"]))

    def test_legacy_complete_caption_identity_still_matches(self):
        events = self.completed(source="Hello.", target="你好。")
        events.append(event(125, "subtitle_displayed", kind="final", source="Hello.", translation="你好。", visible=True))
        row = self.summarize(events, include_text=True)["segments"][0]
        self.assertEqual(row["status"], "displayed")
        self.assertEqual(row["mt_to_display_ms"], 25)
        self.assertEqual(row["source"], "Hello.")
        self.assertNotIn("visible_excerpts", row)

    def test_invalid_or_half_cue_identity_is_not_used(self):
        events = self.completed()
        events += [
            event(150, "subtitle_displayed", kind="final", source="First part.", translation="第一部分。",
                  cue_source=17, cue_translation="第一部分。第二部分。", visible=True),
            event(160, "subtitle_displayed", kind="final", source="First part.", translation="第一部分。",
                  cue_source="First part. Second part.", visible=True),
        ]
        report = self.summarize(events)
        self.assertEqual(report["invalid_rows"], 2)
        self.assertEqual(report["segments"][0]["status"], "not_yet_observed")


if __name__ == "__main__":
    unittest.main()
