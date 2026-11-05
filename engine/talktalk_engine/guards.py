"""TTS output guards (ARCHITECTURE.md §5.5 "跑飞与过短", §3.3 short clauses). No MLX here: the guard
wraps any per-frame stream (TTSModel.stream, or a fake in tests) and is itself a per-frame
generator, so the scheduler still steps it one codec frame at a time.

Per attempt:
- runaway: generated duration above `factor * expected + extra_s`, or a codebook-0 loop (a period
  of 1..`loop_max_period` frames repeating over ≥ `loop_frames` frames); the token cap
  `12.5 * (0.5 * chars + 3)` frames is the last backstop (the inner stream's max_frames). Checked
  at chunk boundaries; the chunk that trips it gets a 25 ms fade-out and ends the clause;
- short: EOS with audio below `short_factor * expected`;
- slow: generated duration above `slow_ratio * expected` but under the cap: reported, never cut;
- start-of-utterance echo: the first `echo_frames` codebook-0 tokens against the reference
  (bigram overlap > `echo_ratio`) → abort and retry.
Retries change the seed (`next_seed`, same as Swift's TTSSeed.next) and only happen while nothing
of the clause has been released yet. Every clause is held until `hold_s` (0.64 s) of audio exists
or EOS (the M0-T1 fallback for the echo detector), and short clauses (`whole`) are held to the end;
the checks run on the held audio, up to `max_attempts` attempts in all. After release a runaway
is cut with the fade and a short ending is only reported. When the last attempt still fails
before release (runaway or echo), nothing is released: the clause is silence (§3.3), reported
with runaway / echo_aborts and audio_s 0. `slow` is reset per attempt; `gpu_ms` sums the inner
steps of every attempt. Every abandoned inner stream is closed and followed by `clear_cache()`
(abandoned generators skip mlx-audio's own cleanup).
"""
import time

import numpy as np

SAMPLE_RATE = 24000
FRAME_HZ = 12.5
MASK32 = 0xFFFFFFFF


class Policy:
    """Defaults = PolicyProfile speak.tts (ARCHITECTURE.md §5.5), calibrated in m0-results.md."""

    def __init__(self, runaway_factor=2.0, runaway_extra_s=0.6, slow_ratio=1.4, short_factor=0.3,
                 whole_below_s=1.5, max_attempts=3, hold_s=0.64, fade_ms=25.0, loop_frames=8,
                 loop_max_period=8, echo_frames=6, echo_ratio=0.5):
        self.runaway_factor = runaway_factor
        self.runaway_extra_s = runaway_extra_s
        self.slow_ratio = slow_ratio
        self.short_factor = short_factor
        self.whole_below_s = whole_below_s
        self.max_attempts = max_attempts
        self.hold_s = hold_s
        self.fade_ms = fade_ms
        self.loop_frames = loop_frames
        self.loop_max_period = loop_max_period
        self.echo_frames = echo_frames
        self.echo_ratio = echo_ratio

    @classmethod
    def raw(cls):
        """Guards off (bench calibration only): no hold, one attempt, no runaway/short/echo verdicts;
        the token cap still bounds the stream."""
        return cls(runaway_factor=1e9, runaway_extra_s=0.0, short_factor=0.0, whole_below_s=0.0,
                   max_attempts=1, hold_s=0.0, loop_frames=10 ** 9, echo_ratio=2.0)


def next_seed(seed, attempt):
    """Deterministic retry seed for attempt n ≥ 1; bit-identical to Swift `TTSSeed.next`."""
    h = (int(seed) & MASK32) ^ ((0x9E3779B9 * attempt) & MASK32)
    h ^= h >> 16
    h = (h * 0x85EBCA6B) & MASK32
    h ^= h >> 13
    return h


def token_cap_frames(text):
    """readread's last-resort cap: 12.5 x (0.5 x characters + 3) frames."""
    return int(FRAME_HZ * (0.5 * len(text) + 3))


def runaway_cap_frames(expected_s, policy):
    return int(FRAME_HZ * (policy.runaway_factor * expected_s + policy.runaway_extra_s))


def cb0_loop(tokens, min_frames=8, max_period=8):
    """True when the newest tokens repeat with some period p ≤ max_period over at least
    max(min_frames, 2p) frames (p = 1: the same token min_frames times)."""
    n = len(tokens)
    for p in range(1, max_period + 1):
        span = max(min_frames, 2 * p)
        if n < span:
            continue
        tail = tokens[n - span:]
        if all(tail[i] == tail[i + p] for i in range(span - p)):
            return True
    return False


def echo_overlap(cb0, ref_cb0, head):
    """Share of the first `head` generated codebook-0 bigrams that also occur in the reference."""
    g = list(cb0[:head])
    r = list(ref_cb0)
    if len(g) < 2 or len(r) < 2:
        return 0.0
    rb = set(zip(r, r[1:]))
    gb = list(zip(g, g[1:]))
    return sum(1 for b in gb if b in rb) / len(gb)


def fade_out(chunk, ms=25.0, sr=SAMPLE_RATE):
    """Linear fade over the last `ms` of the chunk (to exactly 0 at the end)."""
    out = np.array(chunk, dtype=np.float32, copy=True)
    n = min(len(out), int(round(sr * ms / 1000.0)))
    if n > 0:
        out[len(out) - n:] *= np.linspace(1.0, 0.0, n, dtype=np.float32)
    return out


class Progress:
    """Yielded instead of None at each chunk boundary while audio is held back (0.64 s hold, whole
    clause, retries): the engine sends it as a progress frame so the app's stall rule (§5.7) sees
    the job is alive although no audio reaches it yet."""
    __slots__ = ("held_s", "attempt")

    def __init__(self, held_s, attempt):
        self.held_s = held_s
        self.attempt = attempt

    def payload(self):
        return {"held_s": round(self.held_s, 3), "attempt": self.attempt}


class Guarded:
    """Per-frame generator over guarded attempts. `make_stream(seed, max_frames, stats)` returns the
    inner per-frame generator (yields None or a float32 chunk; fills stats["frames"], stats["cb0"],
    stats["eos"]). After the generator ends, `report` holds the tail fields and `stats` the final
    attempt's inner stats."""

    def __init__(self, make_stream, text, expected_s, seed, policy=None, whole=None, ref_cb0=None,
                 clear_cache=None, max_frames=None):
        self.make_stream = make_stream
        self.text = text
        self.expected_s = float(expected_s)
        self.seed = 0 if seed is None else int(seed)
        self.p = policy or Policy()
        self.whole = (self.expected_s < self.p.whole_below_s) if whole is None else bool(whole)
        self.ref_cb0 = list(ref_cb0) if ref_cb0 is not None else None
        self.clear_cache = clear_cache or (lambda: None)
        self.max_frames = max_frames if max_frames else token_cap_frames(text)
        self.cap = runaway_cap_frames(self.expected_s, self.p)
        self.report = {"runaway": False, "short": False, "slow": False, "echo_aborts": 0, "attempts": 0,
                       "audio_s": 0.0, "frames": 0, "eos": False, "whole": self.whole, "held_s": 0.0,
                       "gpu_ms": 0.0}
        self.stats = {}
        self._inner = None
        self._gpu_s = 0.0

    def _timed(self, it):
        """The inner stream, timing each step: report["gpu_ms"] covers every attempt (bench RTF)."""
        while True:
            t0 = time.perf_counter()
            try:
                item = next(it)
            except StopIteration:
                return
            finally:
                self._gpu_s += time.perf_counter() - t0
            yield item

    # A generator object, so the scheduler's next()/close() work unchanged.
    def __iter__(self):
        return self._run()

    def _close_inner(self):
        if self._inner is not None:
            try:
                self._inner.close()
            finally:
                self._inner = None
                self.clear_cache()

    def _run(self):
        emitted = 0          # samples released to the caller
        released = False
        try:
            attempt = 0
            while True:
                attempt += 1
                seed = self.seed if attempt == 1 else next_seed(self.seed, attempt - 1)
                st = {}
                self.stats = st
                self.report["attempts"] = attempt
                self.report["slow"] = False         # per attempt: an abandoned runaway was "slow" too
                self._inner = iter(self.make_stream(seed, self.max_frames, st))
                held = []
                held_samples = 0
                verdict = None           # None | "runaway" | "short" | "echo"
                echo_checked = self.ref_cb0 is None
                last_attempt = attempt >= self.p.max_attempts
                for item in self._timed(self._inner):
                    frames = st.get("frames", 0)
                    cb0 = st.get("cb0", [])
                    if frames / FRAME_HZ > self.p.slow_ratio * self.expected_s:
                        self.report["slow"] = True
                    if not echo_checked and len(cb0) >= self.p.echo_frames:
                        echo_checked = True
                        if not released and echo_overlap(cb0, self.ref_cb0, self.p.echo_frames) > self.p.echo_ratio:
                            self.report["echo_aborts"] += 1
                            verdict = "echo"
                            break
                    if item is None:
                        yield None
                        continue
                    chunk = np.asarray(item, dtype=np.float32)
                    runaway = frames > self.cap or cb0_loop(cb0, self.p.loop_frames, self.p.loop_max_period)
                    if runaway:
                        verdict = "runaway"
                        if released:
                            # already playing: this chunk ends the clause with a 25 ms fade
                            held.append(fade_out(chunk, self.p.fade_ms))
                            held_samples += len(chunk)
                        break
                    if released:
                        emitted += len(chunk)
                        yield chunk
                        continue
                    held.append(chunk)
                    held_samples += len(chunk)
                    if not self.whole and held_samples >= self.p.hold_s * SAMPLE_RATE:
                        released = True
                        self.report["held_s"] = round(held_samples / SAMPLE_RATE, 3)
                        for c in held:
                            emitted += len(c)
                            yield c
                        held = []
                        held_samples = 0
                    else:
                        yield Progress(held_samples / SAMPLE_RATE, attempt)
                else:
                    # inner stream ended: EOS or its max_frames backstop
                    if st.get("runaway") or not st.get("eos", False):
                        verdict = "runaway"
                    elif (emitted + held_samples) / SAMPLE_RATE < self.p.short_factor * self.expected_s:
                        verdict = "short"
                self.report["frames"] = st.get("frames", 0)
                self.report["eos"] = bool(st.get("eos", False))
                self._close_inner()
                retry = verdict is not None and not released and not last_attempt
                if retry:
                    continue
                if verdict == "runaway":
                    self.report["runaway"] = True
                elif verdict == "short":
                    self.report["short"] = True
                if verdict in ("echo", "runaway") and not released:
                    # retries exhausted before anything played: release nothing (§3.3: all checks
                    # pass before the first sample, a failed clause is silence), not the reference
                    # text or the runaway audio
                    held = []
                    held_samples = 0
                if not released:
                    self.report["held_s"] = round(held_samples / SAMPLE_RATE, 3)
                for c in held:
                    emitted += len(c)
                    yield c
                return
        finally:
            self._close_inner()
            self.report["audio_s"] = round(emitted / SAMPLE_RATE, 3)
            self.report["gpu_ms"] = round(self._gpu_s * 1e3, 2)
