#!/usr/bin/env python3
"""M0-T0 engine hygiene (ARCHITECTURE.md §14 table, T0).

  <engine>/venv/bin/python3 -I -B tools/bench/t0_engine_hygiene.py [--engine-home <dir>] [--n 50]
      [--app build/TalkTalk-Dev.app] --out tools/bench/results/t0_<date>.json

Checks (all must pass):
  venv_matches_lock      installed distributions == engine/requirements-engine.lock (+ build lock)
  ready_without_voice    READY arrives with voice.state == absent; /v1/tts answers 409 voice_absent
  voice_load_works       /v1/voice/load -> voice.state ready -> TTS works
  imports_on_gpu_thread  mlx, mlx_audio, transformers first imported on the "gpu" thread
  handshake_only_ready   nothing written to the handshake fd after READY across N ICL generations
  sounddevice_stub       the stub is what `sounddevice` resolves to inside the engine
  no_core_audio_object   the engine PID is absent from kAudioHardwarePropertyProcessObjectList
  single_listen_port     lsof: exactly one LISTEN socket, 127.0.0.1:<port>, nothing else non-loopback
Uses only the synthetic `say` references in <engine>/warmup. Runs outside the sandbox (Metal).
"""
import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "engine"))

from smoke_engine import lsof_ok, read_wav  # noqa: E402
from talktalk_engine.client import Engine, EngineError  # noqa: E402

SENTENCES = [("en", "Thanks, everyone."), ("de", "Danke Ihnen allen."),
             ("en", "Let me quickly walk you through where the project stands today."),
             ("de", "Wir sollten das Budget für das dritte Quartal noch einmal prüfen."),
             ("en", "Yes."), ("de", "Genau.")]


def lock_versions(path):
    out = {}
    for line in Path(path).read_text().splitlines():
        m = re.match(r"^([A-Za-z0-9_.\-]+)==([^\s;\\]+)", line.strip())
        if m:
            out[m.group(1).lower().replace("_", "-")] = m.group(2)
    return out


def venv_check(home):
    py = home / "venv/bin/python3"
    r = subprocess.run([str(py), "-I", "-m", "pip", "list", "--format", "json", "--disable-pip-version-check"],
                       capture_output=True, text=True, check=True)
    have = {d["name"].lower().replace("_", "-"): d["version"] for d in json.loads(r.stdout)}
    want = lock_versions(ROOT / "engine/requirements-engine.lock")
    want.update(lock_versions(ROOT / "engine/requirements-build.lock"))
    missing = {k: v for k, v in want.items() if have.get(k) != v}
    extra = sorted(set(have) - set(want) - {"pip", "mlx-audio"})
    return {"ok": not missing and not extra and "mlx-audio" in have, "mismatch": missing, "extra": extra,
            "sounddevice_installed": "sounddevice" in have}


def audio_objects(app):
    exe = Path(app) / "Contents/MacOS/TalkTalk"
    out = Path(subprocess.run(["/usr/bin/mktemp", "-t", "tt-audioproc"], capture_output=True, text=True).stdout.strip())
    subprocess.run([str(exe), "--list-audio-processes", "--out", str(out)], check=True, capture_output=True)
    data = json.loads(out.read_text())
    out.unlink()
    return data["processes"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine-home", default=str(Path.home() / "Library/Application Support/TalkTalk/engine"))
    ap.add_argument("--app", default=str(ROOT / "build/TalkTalk-Dev.app"))
    ap.add_argument("--tts", default="tts-qwen3-1.7b-base-8bit")
    ap.add_argument("--asr", default="asr-qwen3-0.6b-8bit")
    ap.add_argument("--n", type=int, default=50)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    home = Path(a.engine_home)
    res = {"test": "T0", "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "checks": {}}
    C = res["checks"]
    C["venv_matches_lock"] = venv_check(home)
    log = Path.home() / "Library/Logs/TalkTalk/engine-bench-t0.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    eng = Engine(home / "venv/bin/python3", ROOT / "engine", [home / "models"], roles="tts,asr", tts=a.tts,
                 asr=a.asr, warmup_dir=home / "warmup", log_path=log)
    try:
        eng.start()
        res["ready_s"] = round(eng.ready_s, 2)
        res["ready"] = eng.ready
        h = eng.health()
        st, body = eng.request("POST", "/v1/tts", {"text": "Hello there", "lang": "en"})
        C["ready_without_voice"] = {"ok": h["voice"]["state"] == "absent" and eng.ready["voice"]["state"] == "absent"
                                    and st == 409 and b"voice_absent" in body,
                                    "voice_state": h["voice"]["state"], "tts_status": st}
        warm = home / "warmup"
        ref, _ = read_wav(warm / "ref-zh.wav")
        _, blob = eng.build_voice(ref, (warm / "ref-zh.txt").read_text().strip())
        t0 = time.perf_counter()
        eng.load_voice(blob)
        load_ms = (time.perf_counter() - t0) * 1e3
        pcm, tail, timing = eng.tts({"text": "Thanks, everyone.", "lang": "en", "seed": 0})
        C["voice_load_works"] = {"ok": timing["audio_s"] > 0.3, "load_to_ready_ms": round(load_ms, 1),
                                 "audio_s": round(timing["audio_s"], 2)}
        eng.wait_asr()
        extra = b""
        rtfs, gens = [], 0
        for i in range(a.n):
            lang, text = SENTENCES[i % len(SENTENCES)]
            pcm, tail, timing = eng.tts({"text": text, "lang": lang, "seed": i})
            gens += 1
            if timing["audio_s"] > 0:
                rtfs.append(tail["timing"]["total_ms"] / 1e3 / timing["audio_s"])
            extra += eng.handshake_extra_lines(wait=0.0)
        extra += eng.handshake_extra_lines(wait=0.2)
        C["handshake_only_ready"] = {"ok": extra == b"", "generations": gens, "extra_bytes": len(extra),
                                     "extra_head": extra[:200].decode("utf-8", "replace")}
        h = eng.health()
        first = h["hygiene"]["imports_first_thread"]
        C["imports_on_gpu_thread"] = {"ok": bool(first) and all(v == "gpu" for v in first.values()), "first": first}
        C["sounddevice_stub"] = {"ok": bool(h["hygiene"]["sounddevice_stub"])}
        procs = audio_objects(a.app)
        C["no_core_audio_object"] = {"ok": all(p["pid"] != eng.pid for p in procs), "engine_pid": eng.pid,
                                     "process_objects": len(procs)}
        ok, detail = lsof_ok(eng.pid, eng.port)
        C["single_listen_port"] = {"ok": ok, **detail}
        res["rtf_median"] = round(sorted(rtfs)[len(rtfs) // 2], 4) if rtfs else None
        res["health"] = {k: h[k] for k in ("versions", "models", "gpu", "mem")}
        res["stats"] = eng.json("GET", "/v1/stats")
    except EngineError as e:
        res["error"] = str(e)
    finally:
        eng.stop()
    res["pass"] = "error" not in res and all(c.get("ok") for c in C.values()) and len(C) == 8
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(res, ensure_ascii=False, indent=1) + "\n")
    print(json.dumps({"pass": res["pass"], **{k: v["ok"] for k, v in C.items()}, "error": res.get("error")}))
    return 0 if res["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
