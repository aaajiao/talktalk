#!/usr/bin/env python3
"""Bootstrap simulation of hedged SPEAK MT requests (ARCHITECTURE.md appendix B, O15).

Input: the JSONL written by openai_mt_check.py (rows that contain "dir").
Usage: python3 tools/bench/hedge_sim.py tools/bench/results/m0_gpt-6-luna_2026-11-04.jsonl

Model (all estimates):
- Request A is drawn from the measured SPEAK requests (zh->en, zh->de).
- If A has no first text delta by h ms, a hedge B is sent. B is drawn from the
  same SPEAK requests only (the faster LISTEN requests are not mixed in).
  rho is the share of hedges that are exactly as slow as A (shared cause,
  e.g. server overload): rho 0 = independent, rho 0.5 = pessimistic.
- Total deadline D: past it the clause uses Apple Translation, assumed ready
  about 150 ms after the deadline.
- The deadline extension by playout queue (section 4.1) is not modelled; it
  only lowers the Apple rate.
Part 2 convolves the MT distribution with a non-MT model (fixed 370 ms plus a
lognormal with p50 347 ms and p95 975 ms, which reproduces the section 6.5
table: idle p50 sum 0.72 s, co-run p95 sum 1.35 s) to get clause-end -> first
audible sample, and the tail after key release (fixed part 270 ms plus whole-
clause rendering 0.1-0.3 s). A local-MT run (lognormal p50 300 ms, p95 540 ms)
calibrates the method against the old local targets (1.0 / 1.5 s).
No network access, no API key.
"""
import json
import math
import random
import sys


def pct(a, p):
    a = sorted(a)
    k = (len(a) - 1) * p
    f = int(k)
    c = min(f + 1, len(a) - 1)
    return a[f] + (a[c] - a[f]) * (k - f)


def load(path):
    rows = [json.loads(l) for l in open(path, encoding="utf-8") if '"dir"' in l]
    speak = [(r["first_delta_ms"], r["total_ms"]) for r in rows if r["dir"].startswith("zh")]
    listen = [(r["first_delta_ms"], r["total_ms"]) for r in rows if not r["dir"].startswith("zh")]
    return speak, listen


def mt_draws(speak, h, D, rho, n=40000, seed=7):
    rnd = random.Random(seed)
    out, hedged, apple = [], 0, 0
    for _ in range(n):
        fA, tA = rnd.choice(speak)
        t = tA
        if h is not None and fA > h:
            hedged += 1
            if rnd.random() < rho:
                tB = tA - h            # B exactly as slow as A
            else:
                _, tB = rnd.choice(speak)
            t = min(tA, h + tB)
        if D is not None and t > D:
            apple += 1
            t = D + 150
        out.append(t)
    return out, hedged / n, apple / n


def summary(out, hedged, apple):
    return "p50 %4.0f  p90 %4.0f  p95 %4.0f  max %4.0f  hedged %.3f  apple %.3f" % (
        pct(out, .5), pct(out, .9), pct(out, .95), max(out), hedged, apple)


def main():
    speak, listen = load(sys.argv[1])
    print("measured SPEAK n=%d, LISTEN n=%d (B drawn from SPEAK only)" % (len(speak), len(listen)))
    tot = [t for _, t in speak]
    print("SPEAK unhedged total: p50 %.0f p90 %.0f p95 %.0f max %.0f" % (
        pct(tot, .5), pct(tot, .9), pct(tot, .95), max(tot)))
    lt = [t for _, t in listen]
    print("LISTEN unhedged total: p50 %.0f p90 %.0f min %.0f max %.0f" % (
        pct(lt, .5), pct(lt, .9), min(lt), max(lt)))
    print()
    print("== Part 1: SPEAK MT, request sent -> response.completed (ms) ==")
    for D in (None, 2000, 2500):
        for rho in (0.0, 0.5):
            for h in (700, 800, 900, 1000, 1200):
                print("D=%-4s rho=%.1f h=%4d  %s" % (D, rho, h, summary(*mt_draws(speak, h, D, rho))))
        print()
    # round-2 design without hedge: Apple if no first delta by 1.2 s or not done by 2.0 s
    out, ap = [], 0
    for fA, tA in speak:
        if fA > 1200 or tA > 2000:
            ap += 1
            out.append((1200 if fA > 1200 else 2000) + 150)
        else:
            out.append(tA)
    print("no hedge, Apple at 1.2 s first delta / 2.0 s total: p50 %.0f p90 %.0f max %.0f apple %.3f" % (
        pct(out, .5), pct(out, .9), max(out), ap / len(speak)))
    print()
    print("== Part 2: convolution with non-MT segments (ms) ==")
    mu = math.log(347)
    sig = math.log(975 / 347) / 1.645
    rnd = random.Random(3)
    chk = [370 + rnd.lognormvariate(mu, sig) for _ in range(40000)]
    print("non-MT check: p50 %.0f p95 %.0f (target 717 / 1345)" % (pct(chk, .5), pct(chk, .95)))
    lmu = math.log(300)
    lsig = math.log(540 / 300) / 1.645
    for rho in (0.0, 0.5):
        o, _, _ = mt_draws(speak, 1000, 2500, rho, seed=11)
        s = [x + 370 + rnd.lognormvariate(mu, sig) for x in o]
        print("clause end -> audible, hedge 1.0 s / D 2.5 s, rho %.1f: p50 %.0f p90 %.0f p95 %.0f" % (
            rho, pct(s, .5), pct(s, .9), pct(s, .95)))
    for rho in (0.0, 0.5):
        o, _, _ = mt_draws(speak, 1000, 2500, rho, seed=13)
        s = [x + 270 + rnd.lognormvariate(mu, sig) + rnd.uniform(100, 300) for x in o]
        print("key release -> tail audible, rho %.1f: p50 %.0f p90 %.0f" % (rho, pct(s, .5), pct(s, .9)))
    s = [rnd.lognormvariate(lmu, lsig) + 370 + rnd.lognormvariate(mu, sig) for _ in range(40000)]
    print("calibration, local MT (p50 300, p95 540): clause p50 %.0f p90 %.0f" % (pct(s, .5), pct(s, .9)))
    s = [rnd.lognormvariate(lmu, lsig) + 270 + rnd.lognormvariate(mu, sig) + rnd.uniform(100, 300)
         for _ in range(40000)]
    print("calibration, local MT: tail p50 %.0f p90 %.0f" % (pct(s, .5), pct(s, .9)))


if __name__ == "__main__":
    main()
