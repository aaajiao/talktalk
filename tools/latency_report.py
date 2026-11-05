#!/usr/bin/env python3
"""Latency report over talktalk session event logs (ARCHITECTURE.md §12.2, §14 M1/M2).

    python3 -I -B tools/latency_report.py [FILES or DIRS ...] [--profile P] [--json] [--check]

Input: the per-session jsonl logs written by `TalkTalkCore/EventLog.swift`
(`~/Library/Logs/TalkTalk/sessions/*.jsonl` by default): one object per line, `t` = host time in
ns (CLOCK_UPTIME_RAW), `ev` = event name, other fields numbers / booleans / tags. No text is ever
read or printed; lengths only.

M1 (LISTEN), per sentence of every `listen.start` … `listen.stop` run:
  s0  first word     = trigger − listen.sentence.first_word_to_trigger_ms
  trg finalize trig. = listen.sentence.t − listen.sentence.trigger_to_final_ms
  s1  source end     = trg − listen.sentence.last_word_to_trigger_ms when logged, else trg
  T   final shown    = listen.commit_shown.t when logged, else mt.final.t
  Y   final length   = chars on listen.commit_shown / mt.final when logged
  - first draft:  first listen.draft_shown{sentence} (else first mt.draft{sentence} that finished
                  while the sentence was still open, i.e. at or before listen.sentence) − s0.
                  "first text" = min(first draft, T) − s0 also covers sentences with no draft.
                  Target p50 ≤ 1.2 s.
  - LongYAAL:     per sentence (Polák, Papi et al. 2025, arXiv 2509.17349: every token of a
                  segment counts, ideal delay (i−1)·|X_s|/|Y_s|, averaged over segments). A final
                  appears at once, so every token has delay T − s0 and
                      YAAL_s = (T − s0) − (s1 − s0)·(Y − 1)/(2Y)       (Y unknown: Y → ∞)
                  Reported: mean over sentences, p50, p90. Targets: en ≤ 3.0 s, de ≤ 3.5 s,
                  p90 ≤ 4.0 s. Our own sentences are the segments (no reference resegmentation),
                  and s0/s1 are ASR arrival times, so this is a lower bound on the true lag.
  - NE:           Σ erased chars (listen.revise{erased}) / Σ final chars. Target ≤ 0.2.
  - chars/s:      max over finals k of Σ chars of finals shown in [T_k − W, T_k] / W
                  (W = --cps-window-s, default 10). Target ≤ listen.display.maxCps (profile).
  - deadline:     share of sentences in runs with a cloud primary (listen.start primary=true)
                  whose final came from OpenAI (mt.final engine=openai) within
                  listen.finalMT.deadlineMs (profile) of the trigger. Target ≥ 0.95.
  Sentences dropped as echo (listen.echo_drop) and sentences that span sys.sleep /
  meeting.suspend are left out.

M2 (SPEAK), per press (key.down … key.up; key.chordCancel discards the press):
  excluded time = the disclosure (告知语: out.first_audible{disclosure=true, dur_ms}) and
                  passthrough yield + open ([pt.open.t − pt.open.waitMs, pt.close.t]), §3.8, §5.5.
  - release → first sound: first non-disclosure out.first_audible after key.up and before the next
                  key.down, minus excluded time in between. Target (presses ≤ 8 s):
                  p50 ≤ 2.0 s, p90 ≤ 3.2 s.
  - EVS:          per clause, out.first_audible{clause}.t − source start of the clause, minus
                  excluded time. Source start: seg.commit{clause, src_t0} (host ns); without it
                  the press's mic.onset (else key.down) for its first clause and the previous
                  clause's seg.commit for later ones (counted as approximate).
  - underruns:    out.underrun outside excluded time; per press with output. Target 0.
M3 metrics come later.

Exit status: 0; with --check, 1 when a target with data is missed. 2 = usage / input error.
"""
import argparse
import json
import math
import os
import sys

MS = 1_000_000  # ns per ms
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PROFILE = os.path.join(HERE, "..", "Resources", "PolicyProfile.default.json")
DEFAULT_LOGS = os.path.expanduser("~/Library/Logs/TalkTalk/sessions")
SLEEP_EVENTS = ("sys.sleep", "meeting.suspend")

M1_TARGETS = {"first_draft_p50_s": 1.2, "longyaal_mean_s": {"en": 3.0, "de": 3.5},
              "longyaal_p90_s": 4.0, "ne_max": 0.2, "deadline_min": 0.95}
M2_TARGETS = {"release_p50_s": 2.0, "release_p90_s": 3.2, "max_hold_s": 8.0, "underruns_max": 0}


# ---- input ------------------------------------------------------------------------------------

def load_events(paths):
    """{file: [event dicts in file order]}; directories contribute their *.jsonl."""
    files = []
    for p in paths:
        if os.path.isdir(p):
            files += sorted(os.path.join(p, f) for f in os.listdir(p) if f.endswith(".jsonl"))
        elif os.path.isfile(p):
            files.append(p)
        else:
            raise FileNotFoundError("no such file or directory: %s" % p)
    out = {}
    for f in files:
        evs = []
        with open(f, encoding="utf-8") as fh:
            for n, line in enumerate(fh, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except ValueError:
                    raise ValueError("%s:%d: not JSON" % (f, n))
                if isinstance(e, dict) and isinstance(e.get("t"), (int, float)) and isinstance(e.get("ev"), str):
                    evs.append(e)
        out[f] = evs
    return out


def load_profile(path):
    with open(path, encoding="utf-8") as fh:
        p = json.load(fh)
    listen = p["listen"]
    return {"deadline_ms": int(listen["finalMT"]["deadlineMs"]),
            "max_cps": float(listen["display"]["maxCps"])}


# ---- statistics -------------------------------------------------------------------------------

def percentile(xs, q):
    """Linear interpolation between closest ranks (numpy's default); None for no data."""
    if not xs:
        return None
    s = sorted(xs)
    k = (len(s) - 1) * q / 100.0
    lo, hi = int(math.floor(k)), int(math.ceil(k))
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def mean(xs):
    return sum(xs) / len(xs) if xs else None


def stats(xs):
    return {"n": len(xs), "mean": mean(xs), "p50": percentile(xs, 50), "p90": percentile(xs, 90)}


def overlap_ns(intervals, a, b):
    """Total length of [a, b] covered by the (possibly overlapping) intervals."""
    segs = sorted((max(a, s), min(b, e)) for s, e in intervals if e > a and s < b)
    total, cur_s, cur_e = 0, None, None
    for s, e in segs:
        if cur_e is None or s > cur_e:
            if cur_e is not None:
                total += cur_e - cur_s
            cur_s, cur_e = s, e
        else:
            cur_e = max(cur_e, e)
    if cur_e is not None:
        total += cur_e - cur_s
    return total


# ---- M1 ---------------------------------------------------------------------------------------

def listen_runs(events):
    """Split a file's events into LISTEN runs: [(start event, [events])]. Sentence ids restart
    with every ListenPipeline, so they are only unique within a run."""
    runs, cur = [], None
    for e in events:
        if e["ev"] == "listen.start":
            cur = (e, [])
            runs.append(cur)
        elif cur is not None:
            cur[1].append(e)
            if e["ev"] == "listen.stop":
                cur = None
    return runs


def m1_sentences(events):
    """Per-sentence timing records for one file."""
    sleeps = [e["t"] for e in events if e["ev"] in SLEEP_EVENTS]
    out = []
    for start, evs in listen_runs(events):
        lang = start.get("lang", "?")
        primary = bool(start.get("primary", False))
        by = {}
        def s(sid):
            return by.setdefault(sid, {"drafts": [], "shown_drafts": [], "erased": 0})
        for e in evs:
            sid = e.get("sentence")
            if not isinstance(sid, int):
                continue
            ev = e["ev"]
            if ev == "listen.sentence":
                s(sid)["sentence"] = e
            elif ev == "mt.draft":
                s(sid)["drafts"].append(e["t"])
            elif ev == "listen.draft_shown":
                s(sid)["shown_drafts"].append(e["t"])
            elif ev == "mt.final":
                s(sid)["final"] = e
            elif ev == "listen.commit_shown":
                s(sid)["commit"] = e
            elif ev == "listen.echo_drop":
                s(sid)["echo"] = True
            elif ev == "listen.revise":
                s(sid)["erased"] += int(e.get("erased", 0))
        for sid in sorted(by):
            r = by[sid]
            se, fin = r.get("sentence"), r.get("final")
            if se is None or r.get("echo") or fin is None:
                continue
            trg = se["t"] - int(se.get("trigger_to_final_ms", 0)) * MS
            fw = se.get("first_word_to_trigger_ms", -1)
            s0 = trg - int(fw) * MS if isinstance(fw, (int, float)) and fw >= 0 else None
            lw = se.get("last_word_to_trigger_ms")
            s1 = trg - int(lw) * MS if isinstance(lw, (int, float)) and lw >= 0 else trg
            shown = r.get("commit", fin)
            T = shown["t"]
            chars = shown.get("chars", fin.get("chars"))
            chars = int(chars) if isinstance(chars, (int, float)) and chars > 0 else None
            if s0 is not None and any(s0 < z <= T for z in sleeps):
                continue
            if r["shown_drafts"]:
                draft = min(r["shown_drafts"])
            else:
                open_drafts = [t for t in r["drafts"] if t <= se["t"]]
                draft = min(open_drafts) if open_drafts else None
            ttt = fin.get("trigger_to_text_ms")
            out.append({"lang": lang, "primary": primary, "s0": s0, "s1": s1, "trigger": trg, "T": T,
                        "chars": chars, "draft": draft, "erased": r["erased"],
                        "engine": fin.get("engine"),
                        "trigger_to_text_ms": int(ttt) if isinstance(ttt, (int, float)) else (T - trg) / MS})
    return out


def yaal(r):
    """LongYAAL contribution of one sentence (s), or None without a first-word time."""
    if r["s0"] is None:
        return None
    span = max(0, r["s1"] - r["s0"])
    y = r["chars"]
    factor = (y - 1) / (2.0 * y) if y else 0.5
    return ((r["T"] - r["s0"]) - span * factor) / 1e9


def m1_report(sentences, profile, deadline_ms=None, cps_window_s=10.0):
    deadline_ms = profile["deadline_ms"] if deadline_ms is None else deadline_ms
    rep = {"sentences": len(sentences), "deadline_ms": deadline_ms, "max_cps": profile["max_cps"],
           "cps_window_s": cps_window_s, "notes": []}
    draft = [(r["draft"] - r["s0"]) / 1e9 for r in sentences if r["s0"] is not None and r["draft"] is not None]
    first_text = [(min(x for x in (r["draft"], r["T"]) if x is not None) - r["s0"]) / 1e9
                  for r in sentences if r["s0"] is not None]
    rep["first_draft_s"] = stats(draft)
    rep["first_text_s"] = stats(first_text)
    rep["longyaal_s"] = {}
    for lang in sorted({r["lang"] for r in sentences}):
        ys = [v for v in (yaal(r) for r in sentences if r["lang"] == lang) if v is not None]
        rep["longyaal_s"][lang] = stats(ys)
    if any(r["chars"] is None for r in sentences):
        rep["notes"].append("some finals have no chars: LongYAAL uses Y → ∞, chars/s and NE skip them")
    # NE
    with_chars = [r for r in sentences if r["chars"] is not None]
    erased = sum(r["erased"] for r in sentences)
    total = sum(r["chars"] for r in with_chars)
    if total > 0:
        rep["ne"] = erased / float(total)
    else:
        rep["ne"] = 0.0 if sentences and erased == 0 else None
    # chars/s over a sliding window ending at each final
    shown = sorted((r["T"], r["chars"]) for r in with_chars)
    w = cps_window_s * 1e9
    peak = None
    for i, (t, _) in enumerate(shown):
        c = sum(ch for (u, ch) in shown[: i + 1] if u >= t - w)
        v = c / cps_window_s
        peak = v if peak is None or v > peak else peak
    rep["cps_max"] = peak
    # final MT before deadline
    cloud = [r for r in sentences if r["primary"]]
    met = [r for r in cloud if r["engine"] == "openai" and r["trigger_to_text_ms"] <= deadline_ms]
    rep["deadline"] = {"n": len(cloud), "met": len(met),
                       "share": len(met) / float(len(cloud)) if cloud else None,
                       "engines": {e: sum(1 for r in cloud if r["engine"] == e)
                                   for e in sorted({str(r["engine"]) for r in cloud})}}
    return rep


def m1_verdicts(rep):
    t, v = M1_TARGETS, []
    v.append(("first draft p50 ≤ %.1f s" % t["first_draft_p50_s"], rep["first_draft_s"]["p50"],
              lambda x: x <= t["first_draft_p50_s"]))
    for lang, st in sorted(rep["longyaal_s"].items()):
        lim = t["longyaal_mean_s"].get(lang)
        if lim is not None:
            v.append(("LongYAAL %s ≤ %.1f s" % (lang, lim), st["mean"], lambda x, lim=lim: x <= lim))
        v.append(("LongYAAL %s p90 ≤ %.1f s" % (lang, t["longyaal_p90_s"]), st["p90"],
                  lambda x: x <= t["longyaal_p90_s"]))
    v.append(("NE ≤ %.1f" % t["ne_max"], rep["ne"], lambda x: x <= t["ne_max"]))
    v.append(("chars/s ≤ %g" % rep["max_cps"], rep["cps_max"], lambda x: x <= rep["max_cps"]))
    v.append(("OpenAI final within %d ms ≥ %d%%" % (rep["deadline_ms"], t["deadline_min"] * 100),
              rep["deadline"]["share"], lambda x: x >= t["deadline_min"]))
    return [(name, val, None if val is None else bool(ok(val))) for name, val, ok in v]


# ---- M2 ---------------------------------------------------------------------------------------

def m2_presses(events):
    """Presses, clause EVS and underruns for one file."""
    excluded = []
    open_pt = None
    for e in events:
        ev = e["ev"]
        if ev == "out.first_audible" and e.get("disclosure"):
            excluded.append((e["t"], e["t"] + int(e.get("dur_ms", 0)) * MS))
        elif ev == "pt.open":
            open_pt = e["t"] - int(e.get("waitMs", 0)) * MS
        elif ev == "pt.close" and open_pt is not None:
            excluded.append((open_pt, e["t"]))
            open_pt = None
    if open_pt is not None:
        excluded.append((open_pt, events[-1]["t"]))

    presses, cur = [], None
    commits, audible, underruns = {}, {}, []
    sleeps = [e["t"] for e in events if e["ev"] in SLEEP_EVENTS]
    for e in events:
        ev, t = e["ev"], e["t"]
        if ev == "key.down":
            cur = {"down": t, "up": None, "first": None, "cancel": False, "onset": None, "clauses": [],
                   "underruns": 0}
            presses.append(cur)
        elif cur is None:
            continue
        elif ev == "key.up" and cur["up"] is None:
            cur["up"] = t
        elif ev == "key.chordCancel":
            cur["cancel"] = True
        elif ev == "mic.onset" and cur["onset"] is None:
            cur["onset"] = t
        elif ev == "seg.commit" and isinstance(e.get("clause"), int):
            commits[e["clause"]] = (e, cur)
            cur["clauses"].append(e["clause"])
        elif ev == "out.first_audible" and not e.get("disclosure"):
            if cur["up"] is not None and cur["first"] is None:
                cur["first"] = t
            if isinstance(e.get("clause"), int) and e["clause"] not in audible:
                audible[e["clause"]] = t
        elif ev == "out.underrun":
            if overlap_ns(excluded, t, t + 1) == 0:
                cur["underruns"] += 1
                underruns.append(t)
    rel, rel_short, evs, approx = [], [], [], 0
    with_output = 0
    for p in presses:
        if p["cancel"] or p["up"] is None or p["first"] is None:
            continue
        if any(p["down"] < z <= p["first"] for z in sleeps):
            continue
        with_output += 1
        d = (p["first"] - p["up"] - overlap_ns(excluded, p["up"], p["first"])) / 1e9
        rel.append(d)
        if (p["up"] - p["down"]) / 1e9 <= M2_TARGETS["max_hold_s"]:
            rel_short.append(d)
        prev = None
        for c in p["clauses"]:
            ce, _ = commits[c]
            if isinstance(ce.get("src_t0"), (int, float)):
                src = ce["src_t0"]
            else:
                approx += 1
                src = prev if prev is not None else (p["onset"] if p["onset"] is not None else p["down"])
            prev = ce["t"]
            if c in audible and audible[c] >= src:
                evs.append((audible[c] - src - overlap_ns(excluded, src, audible[c])) / 1e9)
    counted = [p for p in presses if not p["cancel"] and p["first"] is not None]
    return {"release": rel, "release_short": rel_short, "evs": evs, "evs_approx": approx,
            "presses": len(presses), "with_output": with_output,
            "underruns": len(underruns), "presses_with_underrun": sum(1 for p in counted if p["underruns"]),
            "excluded_s": sum(e - s for s, e in excluded) / 1e9}


def m2_report(parts):
    rel = [x for p in parts for x in p["release"]]
    short = [x for p in parts for x in p["release_short"]]
    evs = [x for p in parts for x in p["evs"]]
    with_output = sum(p["with_output"] for p in parts)
    return {"presses": sum(p["presses"] for p in parts), "with_output": with_output,
            "release_s": stats(rel), "release_short_s": stats(short), "evs_s": stats(evs),
            "evs_approx": sum(p["evs_approx"] for p in parts),
            "underruns": sum(p["underruns"] for p in parts),
            "underrun_rate": (sum(p["presses_with_underrun"] for p in parts) / float(with_output)) if with_output else None,
            "excluded_s": sum(p["excluded_s"] for p in parts)}


def m2_verdicts(rep):
    t = M2_TARGETS
    v = [("release → first sound p50 ≤ %.1f s (≤ %g s presses)" % (t["release_p50_s"], t["max_hold_s"]),
          rep["release_short_s"]["p50"], lambda x: x <= t["release_p50_s"]),
         ("release → first sound p90 ≤ %.1f s (≤ %g s presses)" % (t["release_p90_s"], t["max_hold_s"]),
          rep["release_short_s"]["p90"], lambda x: x <= t["release_p90_s"]),
         ("underruns = 0", rep["underruns"] if rep["with_output"] else None, lambda x: x <= t["underruns_max"])]
    return [(name, val, None if val is None else bool(ok(val))) for name, val, ok in v]


# ---- output -----------------------------------------------------------------------------------

def fmt(x, unit=""):
    if x is None:
        return "n/a"
    if isinstance(x, float):
        return "%.3f%s" % (x, unit)
    return "%s%s" % (x, unit)


def fmt_stats(st, unit="s"):
    return "n=%d mean=%s p50=%s p90=%s" % (st["n"], fmt(st["mean"], unit), fmt(st["p50"], unit), fmt(st["p90"], unit))


def build(paths, profile_path, deadline_ms=None, cps_window_s=10.0):
    profile = load_profile(profile_path)
    files = load_events(paths)
    sentences, parts = [], []
    for f in sorted(files):
        sentences += m1_sentences(files[f])
        parts.append(m2_presses(files[f]))
    m1 = m1_report(sentences, profile, deadline_ms, cps_window_s)
    m2 = m2_report(parts)
    return {"files": len(files), "m1": m1, "m1_targets": m1_verdicts(m1),
            "m2": m2, "m2_targets": m2_verdicts(m2)}


def render(rep):
    m1, m2 = rep["m1"], rep["m2"]
    lines = ["files: %d" % rep["files"], "", "M1 LISTEN (%d sentences, deadline %d ms from PolicyProfile)"
             % (m1["sentences"], m1["deadline_ms"])]
    lines.append("  first draft       %s" % fmt_stats(m1["first_draft_s"]))
    lines.append("  first text        %s" % fmt_stats(m1["first_text_s"]))
    for lang, st in sorted(m1["longyaal_s"].items()):
        lines.append("  LongYAAL %-8s %s" % (lang, fmt_stats(st)))
    lines.append("  NE                %s" % fmt(m1["ne"]))
    lines.append("  chars/s max       %s (window %g s)" % (fmt(m1["cps_max"]), m1["cps_window_s"]))
    d = m1["deadline"]
    lines.append("  final ≤ deadline  %s (%d of %d; engines %s)" % (fmt(d["share"]), d["met"], d["n"],
                 ", ".join("%s=%d" % kv for kv in sorted(d["engines"].items())) or "-"))
    for n in m1["notes"]:
        lines.append("  note: " + n)
    lines += ["", "M2 SPEAK (%d presses, %d with output, %.3f s excluded)" % (m2["presses"], m2["with_output"], m2["excluded_s"])]
    lines.append("  release → sound   %s" % fmt_stats(m2["release_s"]))
    lines.append("  … presses ≤ 8 s   %s" % fmt_stats(m2["release_short_s"]))
    lines.append("  EVS               %s (approx. source start: %d)" % (fmt_stats(m2["evs_s"]), m2["evs_approx"]))
    lines.append("  underruns         %d (presses with one: %s)" % (m2["underruns"], fmt(m2["underrun_rate"])))
    lines += ["", "targets"]
    for name, val, ok in rep["m1_targets"] + rep["m2_targets"]:
        lines.append("  %-4s %s: %s" % ("-" if ok is None else ("ok" if ok else "MISS"), name, fmt(val)))
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description="talktalk latency report (§12.2, §14 M1/M2)")
    ap.add_argument("paths", nargs="*", help="jsonl files or directories (default %s)" % DEFAULT_LOGS)
    ap.add_argument("--profile", default=DEFAULT_PROFILE, help="PolicyProfile json (deadline, maxCps)")
    ap.add_argument("--deadline-ms", type=int, help="override listen.finalMT.deadlineMs")
    ap.add_argument("--cps-window-s", type=float, default=10.0)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--check", action="store_true", help="exit 1 when a target with data is missed")
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    try:
        rep = build(a.paths or [DEFAULT_LOGS], a.profile, a.deadline_ms, a.cps_window_s)
    except (OSError, ValueError, KeyError) as e:
        print("latency_report: %s" % e, file=sys.stderr)
        return 2
    if a.json:
        out = dict(rep)
        out["m1_targets"] = [{"target": n, "value": v, "ok": ok} for n, v, ok in rep["m1_targets"]]
        out["m2_targets"] = [{"target": n, "value": v, "ok": ok} for n, v, ok in rep["m2_targets"]]
        print(json.dumps(out, indent=1, sort_keys=True, ensure_ascii=False))
    else:
        print(render(rep))
    if a.check and any(ok is False for _, _, ok in rep["m1_targets"] + rep["m2_targets"]):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
