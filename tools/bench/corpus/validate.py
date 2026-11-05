#!/usr/bin/env python3
"""Check the corpus against the M0 requirements (counts, word limits, ids). Exit 1 on failure."""
import json, os, re, sys

D = os.path.dirname(os.path.abspath(__file__))
def load(n): return json.load(open(os.path.join(D, n + ".json"), encoding="utf-8"))
bad = []
def check(c, msg):
    if not c: bad.append(msg)

for lang in ("en", "de"):
    t1 = load(f"t1_{lang}")["items"]
    check(len(t1) == 50, f"t1_{lang}: need 50, got {len(t1)}")
    w = [len(i["text"].split()) for i in t1]
    check(all(1 <= x <= 25 for x in w), f"t1_{lang}: word count outside 1-25: {max(w)}")
    check(sum(1 for x in w if x <= 3) == 30, f"t1_{lang}: need exactly 30 sentences <=3 words, got {sum(1 for x in w if x <= 3)}")
    t7 = load(f"t7_{lang}")["items"]
    check(len(t7) == 30, f"t7_{lang}: need 30, got {len(t7)}")

t5 = load("t5")["items"]
check(len(t5) == 100, f"t5: need 100, got {len(t5)}")
check(sum(1 for i in t5 if i["mixed"]) == 30, "t5: need 30 mixed zh/en")
check(all(1.4 <= i["est_s"] <= 6.0 for i in t5), "t5: est_s outside 1.4-6.0")
for k in ("percent", "money", "date", "duration"):
    check(sum(1 for i in t5 if f"number:{k}" in i["tags"]) >= 6, f"t5: too few number:{k}")

ref = load("voice_ref")
check("items" in ref and "text" not in json.dumps(ref["items"], ensure_ascii=False).replace('"note"', ""), "voice_ref: must not duplicate the script text (see ARCHITECTURE section 9.1)")
check(ref["script_ref"]["section"] == "9.1", "voice_ref: must point at section 9.1")

for n in ("voice_ref", "t5", "t17", "t1_en", "t1_de", "t7_en", "t7_de"):
    ids = [i["id"] for i in load(n)["items"]]
    check(len(ids) == len(set(ids)), f"{n}: duplicate ids")
    check(all(re.fullmatch(r"[a-z0-9\-]+", x) for x in ids), f"{n}: bad id charset")

print("\n".join(bad) if bad else "corpus OK")
sys.exit(1 if bad else 0)
