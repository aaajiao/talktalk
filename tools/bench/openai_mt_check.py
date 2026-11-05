#!/usr/bin/env python3
"""talktalk M0 quick check: OpenAI MT latency and request parameters.

Key source (ARCHITECTURE.md §7.7 "key 的安排", user decision 2026-11-04): only the user's
existing Keychain item, service com.aaajiao.talktalk.openai, account = the macOS user name.
Never the OPENAI_API_KEY environment variable and never the app's or dev app's item (account
api-key). The key is never printed, logged or stored.
Sends only the fixed test sentences below. Stops at the first auth failure.
Usage: python3 -I tools/bench/openai_mt_check.py tools/bench/results/<name>.jsonl
"""
import http.client, json, os, pwd, re, ssl, statistics, subprocess, sys, time, urllib.parse

HOST = "api.openai.com"
MODEL = os.environ.get("TT_BENCH_MODEL", "gpt-6-luna")
OUT = sys.argv[1] if len(sys.argv) > 1 else "results.jsonl"


BENCH_SERVICE = "com.aaajiao.talktalk.openai"
BENCH_ACCOUNT = pwd.getpwuid(os.getuid()).pw_name  # the account the user wrote; never "api-key"


def get_key():
    print(f"key source: Keychain {BENCH_SERVICE} (account {BENCH_ACCOUNT})")
    r = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", BENCH_SERVICE,
                        "-a", BENCH_ACCOUNT, "-w"], capture_output=True, text=True)
    k = r.stdout.strip()
    if r.returncode != 0 or not k:
        sys.exit(f"bench key missing: no {BENCH_SERVICE} item for account {BENCH_ACCOUNT} (ARCHITECTURE.md §7.7)")
    print(f"key length: {len(k)}")
    return k


KEY = get_key()


class Conn:
    def __init__(self):
        self.c = None
        self.opened = 0

    def _open(self):
        proxy = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
        ctx = ssl.create_default_context()
        if proxy:
            u = urllib.parse.urlparse(proxy if "://" in proxy else "http://" + proxy)
            c = http.client.HTTPSConnection(u.hostname, u.port or 8080, timeout=20, context=ctx)
            th = {}
            if u.username is not None:
                import base64
                cred = f"{urllib.parse.unquote(u.username)}:{urllib.parse.unquote(u.password or '')}"
                th["Proxy-Authorization"] = "Basic " + base64.b64encode(cred.encode()).decode()
            c.set_tunnel(HOST, 443, headers=th)
        else:
            c = http.client.HTTPSConnection(HOST, 443, timeout=20, context=ctx)
        t = time.perf_counter()
        c.connect()
        self.connect_ms = (time.perf_counter() - t) * 1e3
        self.c = c
        self.opened += 1

    def request(self, method, path, body=None, stream=False):
        reused = self.c is not None
        if not reused:
            self._open()
        hdr = {"Authorization": "Bearer " + KEY, "Content-Type": "application/json"}
        if stream:
            hdr["Accept"] = "text/event-stream"
        data = json.dumps(body).encode() if body is not None else None
        t0 = time.perf_counter()
        try:
            self.c.request(method, path, body=data, headers=hdr)
            resp = self.c.getresponse()
        except (http.client.HTTPException, OSError):
            # server closed the idle connection: reconnect once
            self.c = None
            self._open()
            reused = False
            t0 = time.perf_counter()
            self.c.request(method, path, body=data, headers=hdr)
            resp = self.c.getresponse()
        t_hdr = time.perf_counter()
        return resp, t0, t_hdr, reused


def first(xs, n):
    return xs[n] if len(xs) > n else None


def pct(xs, p):
    xs = sorted(xs)
    if not xs:
        return None
    k = (len(xs) - 1) * p
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


SPEAK_ZH = [
    "大家好，我先简单介绍一下项目进展。",
    "上周我们完成了第一版的原型。",
    "测试结果比预期好一些。",
    "延迟大概降低了百分之三十。",
    "不过还有两个问题需要解决。",
    "第一个是德语的发音不够自然。",
    "第二个是会议软件偶尔会吞掉第一个字。",
    "我们计划下周三之前修好。",
    "预算方面暂时没有变化。",
    "总共还是三十万欧元。",
    "如果大家没有问题，我们就继续。",
    "关于时间表，我想听听你们的意见。",
    "我们能不能把发布推迟两周？",
    "这样测试会更充分一些。",
    "好的，谢谢大家。",
]
LISTEN_EN = [
    "Thanks for the update, that sounds promising.",
    "Can you say a bit more about the latency numbers?",
    "We measured roughly three hundred milliseconds on our side.",
    "The budget review is scheduled for the twelfth of December.",
    "I'm not sure a two-week delay works for the sales team.",
    "Let's take that offline and come back to it on Friday.",
    "Who owns the German pronunciation issue?",
    "Great, then let's move on to the next item.",
]
LISTEN_DE = [
    "Vielen Dank für den Überblick, das klingt gut.",
    "Können Sie noch etwas zu den Kosten sagen?",
    "Wir haben dafür insgesamt dreihunderttausend Euro eingeplant.",
    "Die Abnahme ist für den zwölften Dezember geplant.",
    "Eine Verschiebung um zwei Wochen wäre für uns schwierig.",
    "Lassen Sie uns das am Freitag noch einmal besprechen.",
    "Wer kümmert sich um die Aussprache im Deutschen?",
    "Gut, dann kommen wir zum nächsten Punkt.",
]

GLOSSARY = "Glossary (always use): 原型 = prototype (de: Prototyp); 延迟 = latency (de: Latenz); 发布 = release (de: Release)."
INSTR = {
    ("zh", "en"): "You are a live interpreter in a business video meeting. Translate the user's LATEST Chinese clause into natural spoken English, as the speaker would say it. Earlier turns are context only (what was already said). Keep every number exact. Output only the English translation of the latest clause: no quotes, no notes, no Chinese characters. " + GLOSSARY,
    ("zh", "de"): "You are a live interpreter in a business video meeting. Translate the user's LATEST Chinese clause into natural spoken German (formal 'Sie'), as the speaker would say it. Earlier turns are context only (what was already said). Keep every number exact. Output only the German translation of the latest clause: no quotes, no notes, no Chinese characters. " + GLOSSARY,
    ("en", "zh"): "Translate the LATEST English sentence from a meeting participant into concise Simplified Chinese subtitles. Earlier turns are context only. Use Arabic numerals for numbers; keep personal and product names in the original. Output only the Chinese subtitle.",
    ("de", "zh"): "Translate the LATEST German sentence from a meeting participant into concise Simplified Chinese subtitles. Earlier turns are context only. Use Arabic numerals for numbers; keep personal and product names in the original. Output only the Chinese subtitle.",
}


def translate(conn, src, tgt, text, history, max_ctx_pairs):
    inp = []
    for s, t in history[-max_ctx_pairs:]:
        inp.append({"role": "user", "content": s})
        inp.append({"role": "assistant", "content": t})
    inp.append({"role": "user", "content": text})
    body = {"model": MODEL, "instructions": INSTR[(src, tgt)], "input": inp,
            "reasoning": {"effort": "none"}, "temperature": 0,
            "max_output_tokens": 160 if src == "zh" else 256, "store": False, "stream": True}
    resp, t0, t_hdr, reused = conn.request("POST", "/v1/responses", body, stream=True)
    rec = {"dir": f"{src}->{tgt}", "status": resp.status, "reused": reused,
           "hdr_ms": round((t_hdr - t0) * 1e3, 1),
           "proc_ms": resp.getheader("openai-processing-ms"),
           "request_id": resp.getheader("x-request-id")}
    if resp.status != 200:
        rec["error"] = resp.read().decode(errors="replace")[:600]
        return rec, None
    t_first, text_out, usage, resp_id, ev_types = None, [], None, None, set()
    while True:
        line = resp.readline()
        if not line:
            break
        line = line.decode("utf-8", errors="replace").strip()
        if not line.startswith("data:"):
            continue
        payload = line[5:].strip()
        if payload == "[DONE]":
            continue
        try:
            ev = json.loads(payload)
        except json.JSONDecodeError:
            continue
        typ = ev.get("type", "")
        ev_types.add(typ)
        if typ.endswith("output_text.delta"):
            if t_first is None:
                t_first = time.perf_counter()
            text_out.append(ev.get("delta", ""))
        elif typ in ("response.completed", "response.incomplete", "response.failed"):
            r = ev.get("response", {})
            usage = r.get("usage")
            resp_id = r.get("id")
            rec["final_status"] = r.get("status")
            if r.get("error"):
                rec["error"] = r.get("error")
        elif typ == "error":
            rec["error"] = ev
    t_end = time.perf_counter()
    out = "".join(text_out).strip()
    rec.update({"first_delta_ms": round((t_first - t0) * 1e3, 1) if t_first else None,
                "total_ms": round((t_end - t0) * 1e3, 1), "text": out, "response_id": resp_id,
                "in_tok": (usage or {}).get("input_tokens"),
                "out_tok": (usage or {}).get("output_tokens"),
                "reasoning_tok": ((usage or {}).get("output_tokens_details") or {}).get("reasoning_tokens"),
                "cached_tok": ((usage or {}).get("input_tokens_details") or {}).get("cached_tokens"),
                "han_in_output": bool(re.search(r"[一-鿿]", out)) if tgt != "zh" else None,
                "events": sorted(ev_types)})
    return rec, out


def main():
    conn = Conn()
    log = open(OUT, "w")
    # 1) model list
    resp, t0, t_hdr, _ = conn.request("GET", "/v1/models")
    raw = resp.read()
    t1 = time.perf_counter()
    first_connect_ms = round(conn.connect_ms, 1)
    ids = sorted(m["id"] for m in json.loads(raw)["data"]) if resp.status == 200 else []
    print(f"models: HTTP {resp.status}, {len(ids)} ids, cold connect {first_connect_ms} ms, request {round((t1-t0)*1e3,1)} ms")
    if resp.status in (401, 403):
        sys.exit(f"auth failed (HTTP {resp.status}); stopping before any translation request")
    pat = re.compile(r"^gpt-(?P<major>[0-9]+)(?:\.(?P<minor>[0-9]+))?-(?P<tier>[a-z]+)(?:-(?P<date>[0-9]{4}-[0-9]{2}-[0-9]{2}))?$")
    deny = {"realtime", "audio", "transcribe", "tts", "speech", "image", "search", "codex", "chat", "latest", "pro",
            "preview", "cyber", "daybreak", "rosalind", "live", "translate", "whisper", "embedding", "moderation",
            "oss", "research", "discovery", "law", "computer"}
    gpt6_all = [i for i in ids if re.match(r"^gpt-([6-9]|[1-9][0-9])", i)]
    picked = [i for i in ids if (m := pat.match(i)) and int(m["major"]) >= 6 and m["tier"] not in deny]
    print("all gpt-6+ ids:", gpt6_all)
    print("picker after filter:", picked)
    log.write(json.dumps({"kind": "models", "gpt6_all": gpt6_all, "picked": picked}) + "\n")
    # 2) warm RTT on the same connection (cheap GETs)
    warm = []
    for _ in range(5):
        resp, t0, t_hdr, reused = conn.request("GET", "/v1/models")
        resp.read()
        warm.append((time.perf_counter() - t0) * 1e3)
        time.sleep(0.3)
    print("warm GET /v1/models ms:", [round(x) for x in warm])
    # 3) translations
    results = []
    for (src, tgt, sents, ctx) in [("zh", "en", SPEAK_ZH, 3), ("zh", "de", SPEAK_ZH, 3),
                                    ("en", "zh", LISTEN_EN, 2), ("de", "zh", LISTEN_DE, 2)]:
        hist = []
        for i, s in enumerate(sents):
            rec, out = translate(conn, src, tgt, s, hist, ctx)
            rec["i"] = i
            results.append(rec)
            log.write(json.dumps(rec, ensure_ascii=False) + "\n")
            log.flush()
            print(f"{rec['dir']} #{i:02d} st={rec['status']} reused={rec['reused']} hdr={rec['hdr_ms']} "
                  f"first={rec.get('first_delta_ms')} total={rec.get('total_ms')} proc={rec.get('proc_ms')} "
                  f"tok in/out/reason/cached={rec.get('in_tok')}/{rec.get('out_tok')}/{rec.get('reasoning_tok')}/{rec.get('cached_tok')} "
                  f"| {rec.get('text') or rec.get('error')}")
            if out:
                hist.append((s, out))
            time.sleep(1.0)
    # 4) idle 25 s then one more request: is the connection still reused?
    time.sleep(25)
    rec, _ = translate(conn, "zh", "en", "我们再确认一下下周的安排。", [], 0)
    rec["i"] = "after_idle_25s"
    results.append(rec)
    log.write(json.dumps(rec, ensure_ascii=False) + "\n")
    print(f"after 25 s idle: reused={rec['reused']} first={rec.get('first_delta_ms')} total={rec.get('total_ms')}")
    # 5) store=false check: fetching a response id should fail
    rid = next((r.get("response_id") for r in results if r.get("response_id")), None)
    if rid:
        resp, *_ = conn.request("GET", f"/v1/responses/{rid}")
        body = resp.read().decode(errors="replace")[:200]
        print(f"GET stored response {rid[:12]}…: HTTP {resp.status} {body}")
        log.write(json.dumps({"kind": "store_check", "status": resp.status, "body": body}) + "\n")
    # 6) summary
    print("\n=== summary (ms), model", MODEL, "connections opened:", conn.opened)
    ok = [r for r in results if r.get("status") == 200 and r.get("first_delta_ms")]
    for d in ["zh->en", "zh->de", "en->zh", "de->zh"]:
        rs = [r for r in ok if r["dir"] == d and r["i"] != "after_idle_25s"]
        f = [r["first_delta_ms"] for r in rs]
        t = [r["total_ms"] for r in rs]
        p = [float(r["proc_ms"]) for r in rs if r.get("proc_ms")]
        if f:
            print(f"{d}: n={len(rs)} first p50={pct(f,.5):.0f} p90={pct(f,.9):.0f} max={max(f):.0f} | "
                  f"total p50={pct(t,.5):.0f} p90={pct(t,.9):.0f} max={max(t):.0f} | proc p50={pct(p,.5) if p else 'n/a'}")
    rt = [r.get("reasoning_tok") for r in ok]
    print("reasoning tokens:", sorted(set(rt)), "| Han chars in en/de output:", sum(1 for r in ok if r.get("han_in_output")))
    tin = sum(r.get("in_tok") or 0 for r in ok)
    tout = sum(r.get("out_tok") or 0 for r in ok)
    print(f"tokens used: in={tin} out={tout}; cost at $0.10/$0.50 per 1M ≈ ${tin/1e6*0.10 + tout/1e6*0.50:.4f}")
    errs = [r for r in results if r.get("status") != 200 or r.get("error")]
    print("errors:", len(errs))
    for e in errs[:5]:
        print("  ", e.get("dir"), e.get("status"), str(e.get("error"))[:300])


if __name__ == "__main__":
    main()
