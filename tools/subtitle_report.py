#!/usr/bin/env python3
"""Summarize one explicitly enabled subtitle trace; no audio, cloud calls, or quality score."""
import argparse
import collections
import json
import math
from pathlib import Path
import re


def uint(value):
    return isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= 2**64 - 1


def stats(values):
    values = sorted(values)
    return {"n": len(values), **{name: round(values[max(0, math.ceil(len(values) * q) - 1)], 3)
            if values else None for name, q in (("p50_ms", .5), ("p90_ms", .9), ("max_ms", 1))}}


def base(event):
    return event.get("configuration"), event.get("sentence")


def revision(event):
    return (*base(event), event.get("source", ""), event.get("translation", ""))


def report(path, include_text=False):
    if path.stat().st_size > 16 * 1024 * 1024:
        raise ValueError("trace exceeds the 16 MiB reader limit")
    events, invalid = [], 0
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            event = json.loads(line)
            if not isinstance(event, dict) or not uint(event.get("t")) or not isinstance(event.get("event"), str):
                raise ValueError()
            if any(k in event and not uint(event[k]) for k in ("configuration", "sentence")):
                raise ValueError()
            if any(k in event and not isinstance(event[k], str) for k in ("source", "translation")):
                raise ValueError()
            events.append(event)
        except (ValueError, TypeError):
            invalid += 1
    events.sort(key=lambda e: e["t"])  # actor delivery can arrive out of timestamp order
    finals, translations, observations = collections.defaultdict(list), [], collections.defaultdict(list)
    asr_lag, invalid_intervals, short = [], 0, set()
    for event in events:
        kind = event["event"]
        if kind == "asr_update" and "audio_through" in event:
            through = event["audio_through"]
            if uint(through) and through <= event["t"]:
                asr_lag.append((event["t"] - through) / 1e6)
            else:
                invalid_intervals += 1
        if not all(uint(v) for v in base(event)):
            continue
        if kind == "sentence_final":
            finals[(*base(event), event.get("source", ""))].append(event["t"])
            words = re.findall(r"\b\w+(?:['’\-]\w+)*\b", event.get("source", ""))
            if 0 < len(words) <= 3:
                short.add(base(event))
        elif kind == "mt_completed":
            translations.append(event)
        elif kind in ("subtitle_queued", "subtitle_displayed") and event.get("kind") == "final":
            observations[revision(event)].append(event)
    mt_lag, display_lag, rows, redisplayed = [], [], [], 0
    revisions = collections.Counter()
    counts = collections.Counter(e["event"] for e in events)
    stop = next((e for e in reversed(events) if e["event"] == "trace_stopped"), None)
    for index, mt in enumerate(translations):
        key, start = revision(mt), mt["t"]
        revisions[base(mt)] += 1
        next_same = next((e["t"] for e in translations[index + 1:] if revision(e) == key), math.inf)
        final_at = [t for t in finals[(*base(mt), mt.get("source", ""))] if t <= start]
        seen = [e for e in observations[key] if start <= e["t"] < next_same]
        shown = [e for e in seen if e["event"] == "subtitle_displayed" and e.get("visible") is True]
        queued = [e for e in seen if e["event"] == "subtitle_queued"]
        mt_ms = (start - max(final_at)) / 1e6 if final_at else None
        shown_ms = (shown[0]["t"] - start) / 1e6 if shown else None
        if mt_ms is not None: mt_lag.append(mt_ms)
        if shown_ms is not None: display_lag.append(shown_ms)
        redisplayed += max(0, len(shown) - 1)
        next_base = next((e["t"] for e in translations[index + 1:] if base(e) == base(mt)), math.inf)
        later = [e for e in events if e["t"] >= start]
        discarded = any(base(e) == base(mt) and start <= e["t"] < next_base
                        and e["event"] in ("subtitle_discarded", "subtitle_dropped") for e in later)
        superseded = any(base(e) == base(mt) for e in translations[index + 1:])
        hidden = any(e.get("visible") is False for e in queued)
        hidden_end = next((e["visible"] is False for e in reversed(later) if isinstance(e.get("visible"), bool)), False)
        reset = any(e["event"] == "configuration_reset" and e.get("configuration") != key[0] for e in later)
        status = ("displayed" if shown else "explicitly_discarded" if discarded else
                  "superseded_revision" if superseded else "configuration_reset_before_display" if reset else
                  "stopped_before_display" if stop and stop["t"] >= start and stop.get("reason") == "session_ended" else
                  "hidden_before_display" if hidden or hidden_end else "unobserved_at_capture_stop" if stop else "not_yet_observed")
        row = {"configuration": key[0], "sentence": key[1], "revision": revisions[base(mt)], "status": status,
               "queued_while_hidden": hidden, "hidden_at_capture_end": hidden_end,
               "sentence_to_mt_ms": mt_ms, "mt_to_display_ms": shown_ms,
               "number_warning": mt.get("number_warning") is True}
        if include_text: row.update(source=key[2], translation=key[3])
        rows.append(row)
    pairs = collections.defaultdict(set)
    for mt in translations:
        pair = tuple(" ".join(mt.get(k, "").split()).casefold() for k in ("source", "translation"))
        if all(pair): pairs[pair].add(base(mt))
    repeated = [sorted(ids) for ids in pairs.values() if len(ids) > 1]
    pending = [e["pending_final_count"] for e in events if uint(e.get("pending_final_count")) and e["pending_final_count"] <= 10_000]
    return {"schema": 1, "quality": "not_evaluated_without_reference", "quantiles": "nearest_rank",
            "records": len(events), "invalid_rows": invalid, "invalid_asr_intervals": invalid_intervals,
            "asr_result_return_lag": stats(asr_lag), "sentence_final_to_mt": stats(mt_lag),
            "mt_to_visible_display": stats(display_lag), "peak_pending_finals": max(pending, default=0),
            "sentence_final_count": sum(map(len, finals.values())), "short_sentence_count": len(short), "short_sentence_ids": sorted(short),
            "repeated_pair_groups": repeated, "number_warning_count": sum(r["number_warning"] for r in rows),
            "discard_count": counts["subtitle_discarded"], "pipeline_drop_count": counts["subtitle_dropped"],
            "remove_count": counts["subtitle_removed"], "redisplay_count": redisplayed,
            "statuses": dict(collections.Counter(r["status"] for r in rows)),
            "unmatched_sentence_final_count": sum(r["sentence_to_mt_ms"] is None for r in rows),
            "stop_reason": stop.get("reason") if stop else None, "segments": rows,
            "limitations": ["ASR lag is result arrival minus audioThrough, not voice onset latency.",
                            "Display time is visible AppKit label submission, not compositor or optical time.",
                            "Exact source/target revisions only; combined or second-pass source may have no final start match.",
                            "Repeated pairs and <=3-word fragments are review hints, not errors or accuracy scores.",
                            "No stop marker may mean active, size-limited, interrupted, or partially read capture.",
                            "Unshown at capture stop is not proof of audio or translation loss; removal is normal panel rollover."]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    parser.add_argument("--include-text", action="store_true", help="include recognized source and translated text")
    args = parser.parse_args()
    try:
        print(json.dumps(report(args.trace, args.include_text), ensure_ascii=False, indent=2, allow_nan=False))
    except (OSError, ValueError) as error:
        parser.exit(1, f"subtitle report: {error}\n")
