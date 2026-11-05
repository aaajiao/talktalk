"""TTS output guards (talktalk_engine/guards.py) with fake per-frame streams: no MLX, no GPU.

Each fake stream is scripted per seed, so a test can make attempt 1 fail and attempt 2 pass.
"""
import unittest

import numpy as np

from talktalk_engine import guards
from talktalk_engine.guards import Guarded, Policy, cb0_loop, echo_overlap, fade_out, next_seed

FRAME = 1920          # samples per codec frame at 24 kHz / 12.5 Hz
CHUNK_FRAMES = 2      # 0.16 s chunks


def tokens(n, start=0):
    """Non-periodic codebook-0 tokens."""
    return [((start + i) * 7919 + 13) % 2003 for i in range(n)]


class Script:
    """make_stream for Guarded: per attempt seed, `frames` frames with these cb0 tokens, then EOS
    (or no EOS when `eos=False`, like a stream stopped by its max_frames)."""

    def __init__(self, plans):
        self.plans = plans            # {seed or "default": (cb0 list, eos)}
        self.seeds = []
        self.closed = 0
        self.max_frames = []

    def __call__(self, seed, max_frames, st):
        self.seeds.append(seed)
        self.max_frames.append(max_frames)
        cb0, eos = self.plans.get(seed, self.plans.get("default"))
        return self._gen(cb0[:max_frames], eos and len(cb0) <= max_frames, st)

    def _gen(self, cb0, eos, st):
        st.update(frames=0, cb0=[], eos=False)
        pending = 0
        try:
            for i, t in enumerate(cb0):
                st["frames"] += 1
                st["cb0"].append(t)
                pending += 1
                if pending == CHUNK_FRAMES:
                    pending = 0
                    yield np.full(CHUNK_FRAMES * FRAME, 0.5, np.float32)
                else:
                    yield None
            if pending:
                yield np.full(pending * FRAME, 0.5, np.float32)
            st["eos"] = eos
            st["runaway"] = not eos
        finally:
            self.closed += 1


def audio(x):
    return isinstance(x, np.ndarray)


def run(g):
    """Drain the guard like the scheduler does; returns (audio chunks, steps). Progress markers
    (held audio) are not audio."""
    out, steps = [], 0
    for item in iter(g):
        steps += 1
        if audio(item):
            out.append(item)
    return out, steps


class PureParts(unittest.TestCase):
    def test_next_seed_matches_swift(self):
        # Swift TTSSeed.next(seed, attempt) for these inputs (computed with the Swift formula)
        def swift(seed, attempt):
            h = (seed ^ ((0x9E3779B9 * attempt) & 0xFFFFFFFF)) & 0xFFFFFFFF
            h ^= h >> 16
            h = (h * 0x85EBCA6B) & 0xFFFFFFFF
            h ^= h >> 13
            return h
        for s, a in [(0, 1), (1, 1), (0xDEADBEEF, 2), (12345, 3)]:
            self.assertEqual(next_seed(s, a), swift(s, a))
        self.assertNotEqual(next_seed(7, 1), next_seed(7, 2))
        self.assertTrue(all(0 <= next_seed(s, 1) <= 0xFFFFFFFF for s in range(50)))

    def test_cb0_loop(self):
        self.assertFalse(cb0_loop(tokens(60)))
        self.assertTrue(cb0_loop(tokens(20) + [5] * 8))                 # period 1 over 8 frames
        self.assertFalse(cb0_loop(tokens(20) + [5] * 7))
        self.assertTrue(cb0_loop(tokens(20) + [1, 2, 3] * 3))           # period 3 over 9 frames
        self.assertFalse(cb0_loop(tokens(20) + [1, 2, 3, 1, 2, 3, 1]))  # 7 frames only
        self.assertTrue(cb0_loop(tokens(10) + list(range(8)) * 2))      # period 8 needs 16 frames
        self.assertFalse(cb0_loop(tokens(10) + list(range(8)) + list(range(7))))
        self.assertFalse(cb0_loop(tokens(10) + list(range(9)) * 2))     # period 9 > max_period

    def test_echo_overlap(self):
        ref = list(range(100, 140))
        self.assertEqual(echo_overlap([120, 121, 122, 123, 124, 125], ref, 6), 1.0)
        self.assertEqual(echo_overlap(tokens(6), ref, 6), 0.0)
        self.assertEqual(echo_overlap([1], ref, 6), 0.0)

    def test_fade_out_is_25_ms_to_zero(self):
        c = np.ones(3840, np.float32)
        f = fade_out(c, 25)
        n = 600                                    # 25 ms at 24 kHz
        self.assertTrue(np.all(f[:-n] == 1.0))
        self.assertEqual(f[-1], 0.0)
        self.assertTrue(np.all(np.diff(f[-n:]) <= 0))
        self.assertTrue(np.all(c == 1.0))           # input untouched
        self.assertEqual(len(fade_out(np.ones(100, np.float32), 25)), 100)

    def test_caps(self):
        p = Policy()
        self.assertEqual(guards.runaway_cap_frames(2.0, p), int(12.5 * (2.0 * 2.0 + 0.6)))
        self.assertEqual(guards.token_cap_frames("x" * 20), int(12.5 * (0.5 * 20 + 3)))


class Streaming(unittest.TestCase):
    """expected 3.0 s (> 1.5 s): streaming mode with the 0.64 s hold."""

    def test_clean_clause_passes_through_after_the_hold(self):
        s = Script({"default": (tokens(30), True)})
        g = Guarded(s, "a b c d e f g h", 3.0, seed=11)
        chunks, steps = run(g)
        self.assertEqual(sum(len(c) for c in chunks), 30 * FRAME)
        # one guard step per frame, plus 3: the release hands out the 4 held chunks one per step
        self.assertEqual(steps, 33)
        r = g.report
        self.assertEqual((r["attempts"], r["runaway"], r["short"], r["slow"], r["echo_aborts"]), (1, False, False, False, 0))
        self.assertFalse(r["whole"])
        self.assertAlmostEqual(r["held_s"], 0.64)            # 4 chunks of 0.16 s held, then released
        self.assertAlmostEqual(r["audio_s"], 30 * FRAME / 24000)
        self.assertEqual(s.seeds, [11])
        self.assertEqual(s.closed, 1)

    def test_nothing_is_released_before_0_64_s(self):
        s = Script({"default": (tokens(30), True)})
        it = iter(Guarded(s, "x", 3.0, seed=1))
        first = [next(it) for _ in range(7)]
        self.assertFalse(any(audio(x) for x in first))       # 7 frames = 0.56 s: still held
        released = [next(it) for _ in range(1)]
        self.assertTrue(audio(released[0]))                  # frame 8 completes 0.64 s

    def test_runaway_by_duration_is_retried_before_release_with_a_new_seed(self):
        # cap for 3.0 s expected = 12.5 * 6.6 = 82 frames; attempt 1 never stops
        s = Script({1: (tokens(400), False), next_seed(1, 1): (tokens(30, 900), True)})
        g = Guarded(s, "x" * 400, 3.0, seed=1, policy=Policy(hold_s=100.0))   # hold everything
        chunks, _ = run(g)
        self.assertEqual(s.seeds, [1, next_seed(1, 1)])
        self.assertEqual(g.report["attempts"], 2)
        self.assertFalse(g.report["runaway"])
        self.assertEqual(sum(len(c) for c in chunks), 30 * FRAME)
        self.assertEqual(s.closed, 2)

    def test_runaway_after_release_is_cut_with_a_fade_not_retried(self):
        s = Script({"default": (tokens(400), False)})
        g = Guarded(s, "x" * 400, 3.0, seed=1)
        chunks, _ = run(g)
        self.assertEqual(s.seeds, [1])                       # released after 0.64 s: no retry
        r = g.report
        self.assertTrue(r["runaway"])
        cap = guards.runaway_cap_frames(3.0, Policy())
        self.assertLessEqual(r["frames"], cap + CHUNK_FRAMES)
        self.assertEqual(chunks[-1][-1], 0.0)                # 25 ms fade on the cut chunk
        self.assertEqual(chunks[-1][0], 0.5)
        self.assertEqual(s.closed, 1)

    def test_cb0_loop_is_a_runaway(self):
        s = Script({"default": (tokens(20) + [42] * 40, True)})
        g = Guarded(s, "a b c d e f g h", 3.0, seed=1)
        chunks, _ = run(g)
        self.assertTrue(g.report["runaway"])
        self.assertLess(g.report["frames"], 32)              # stopped near frame 28, not at 60
        self.assertEqual(chunks[-1][-1], 0.0)

    def test_slow_is_reported_not_cut(self):
        # 1.4 * 3.0 s = 4.2 s = 52.5 frames; 60 frames is slow but under the 82-frame cap
        s = Script({"default": (tokens(60), True)})
        g = Guarded(s, "a b c d e f g h", 3.0, seed=1)
        chunks, _ = run(g)
        self.assertTrue(g.report["slow"])
        self.assertFalse(g.report["runaway"])
        self.assertEqual(sum(len(c) for c in chunks), 60 * FRAME)
        self.assertEqual(chunks[-1][-1], 0.5)                # no fade

    def test_short_before_release_is_retried(self):
        # 0.3 * 3.0 s = 0.9 s; 5 frames = 0.4 s ends inside the 0.64 s hold
        s = Script({1: (tokens(5), True), next_seed(1, 1): (tokens(30), True)})
        g = Guarded(s, "x", 3.0, seed=1)
        run(g)
        self.assertEqual(g.report["attempts"], 2)
        self.assertFalse(g.report["short"])

    def test_short_after_release_is_only_reported(self):
        # 10 frames = 0.8 s < 0.9 s, but 0.64 s was already released
        s = Script({"default": (tokens(10), True)})
        g = Guarded(s, "x", 3.0, seed=1)
        chunks, _ = run(g)
        self.assertEqual(g.report["attempts"], 1)
        self.assertTrue(g.report["short"])
        self.assertEqual(sum(len(c) for c in chunks), 10 * FRAME)

    def test_echo_aborts_and_retries(self):
        ref = list(range(100, 160))
        s = Script({1: (list(range(140, 170)), True), next_seed(1, 1): (tokens(30), True)})
        g = Guarded(s, "x", 3.0, seed=1, ref_cb0=ref)
        chunks, _ = run(g)
        self.assertEqual(g.report["echo_aborts"], 1)
        self.assertEqual(g.report["attempts"], 2)
        self.assertEqual(sum(len(c) for c in chunks), 30 * FRAME)

    def test_at_most_three_attempts(self):
        s = Script({"default": (tokens(5), True)})           # always short inside the hold
        g = Guarded(s, "x", 3.0, seed=1)
        chunks, _ = run(g)
        self.assertEqual(len(s.seeds), 3)
        self.assertEqual(g.report["attempts"], 3)
        self.assertTrue(g.report["short"])
        self.assertEqual(sum(len(c) for c in chunks), 5 * FRAME)   # the last attempt is released

    def test_loop_inside_the_hold_on_the_last_attempt_releases_nothing(self):
        # review [1], streaming: every attempt loops on cb0 before 0.64 s is released
        s = Script({"default": ([42] * 40, True)})
        g = Guarded(s, "a b c d e f g h", 3.0, seed=1)
        chunks, _ = run(g)
        self.assertEqual(chunks, [])
        self.assertEqual(len(s.seeds), 3)
        self.assertTrue(g.report["runaway"])
        self.assertEqual(g.report["audio_s"], 0.0)

    def test_close_and_clear_cache_on_every_attempt_and_on_cancel(self):
        cleared = []
        s = Script({1: (tokens(5), True), "default": (tokens(400), False)})
        g = Guarded(s, "x" * 400, 3.0, seed=1, clear_cache=lambda: cleared.append(1))
        it = iter(g)
        for _ in range(30):                                  # attempt 1 (short, retried), then streaming
            next(it)
        it.close()                                           # scheduler cancel
        self.assertEqual(s.closed, 2)
        self.assertEqual(len(cleared), 2)


class WholeClause(unittest.TestCase):
    """expected < 1.5 s: render whole, check, then release."""

    def test_short_clause_is_held_to_the_end(self):
        s = Script({"default": (tokens(12), True)})
        g = Guarded(s, "Danke.", 1.0, seed=1)
        it = iter(g)
        held = [next(it) for _ in range(12)]
        self.assertFalse(any(audio(x) for x in held))        # nothing during rendering
        rest = list(it)
        self.assertEqual(sum(len(c) for c in rest if audio(c)), 12 * FRAME)
        self.assertTrue(g.report["whole"])
        self.assertAlmostEqual(g.report["held_s"], 12 * FRAME / 24000)

    def test_whole_runaway_retries(self):
        # cap for 1.0 s = 12.5 * 2.6 = 32 frames
        s = Script({1: (tokens(200), False), next_seed(1, 1): (tokens(12), True)})
        g = Guarded(s, "x" * 200, 1.0, seed=1)
        chunks, _ = run(g)
        self.assertEqual(g.report["attempts"], 2)
        self.assertFalse(g.report["runaway"])
        self.assertEqual(sum(len(c) for c in chunks), 12 * FRAME)

    def test_whole_runaway_on_every_attempt_releases_nothing(self):
        # review [1]: "Thank you." with no EOS three times used to release 2.88 s of runaway audio
        s = Script({"default": (tokens(200), False)})
        g = Guarded(s, "Thank you.", 1.0, seed=1)
        chunks, _ = run(g)
        self.assertEqual(chunks, [])
        self.assertEqual(len(s.seeds), 3)
        r = g.report
        self.assertTrue(r["runaway"])
        self.assertEqual(r["audio_s"], 0.0)
        self.assertEqual(s.closed, 3)

    def test_slow_is_per_attempt(self):
        # review [2]: attempt 1 has no EOS (so it also crossed 1.4 x e); attempt 2 is a clean
        # 1.04 x e. The clause must not be reported slow (ClauseQueue would play it at 1.25x).
        s = Script({1: (tokens(200), False), next_seed(1, 1): (tokens(13), True)})
        g = Guarded(s, "Thank you.", 1.0, seed=1)
        chunks, _ = run(g)
        self.assertEqual(g.report["attempts"], 2)
        self.assertFalse(g.report["slow"])
        self.assertFalse(g.report["runaway"])
        self.assertEqual(sum(len(c) for c in chunks), 13 * FRAME)

    def test_gpu_ms_covers_every_attempt(self):
        import time as _t

        def slow_stream(seed, max_frames, st):
            st.update(frames=0, cb0=[], eos=False)
            n = 200 if seed == 1 else 12
            for i, t in enumerate(tokens(min(n, max_frames))):
                _t.sleep(0.001)
                st["frames"] += 1
                st["cb0"].append(t)
                yield np.full(FRAME, 0.5, np.float32) if i % 2 else None
            st["eos"] = n == 12
        g = Guarded(slow_stream, "Thank you.", 1.0, seed=1)
        run(g)
        self.assertEqual(g.report["attempts"], 2)
        frames_run = guards.runaway_cap_frames(1.0, Policy()) + 12        # attempt 1 stops at the cap
        self.assertGreaterEqual(g.report["gpu_ms"], frames_run * 1.0)

    def test_progress_while_holding_and_retrying(self):
        # review [3]: while audio is held (whole clause, retries) the guard yields Progress at every
        # chunk boundary, so the engine can tell the app's stall rule the job is alive
        s = Script({1: (tokens(200), False), next_seed(1, 1): (tokens(12), True)})
        items = list(iter(Guarded(s, "Thank you.", 1.0, seed=1)))
        prog = [x for x in items if isinstance(x, guards.Progress)]
        self.assertTrue(prog)
        self.assertEqual({p.attempt for p in prog}, {1, 2})
        gaps, last = [], None
        for i, x in enumerate(items):                         # never more than one chunk without a sign
            if audio(x) or isinstance(x, guards.Progress):
                if last is not None:
                    gaps.append(i - last)
                last = i
        self.assertLessEqual(max(gaps), CHUNK_FRAMES + 1)
        a2 = [p.held_s for p in prog if p.attempt == 2]
        self.assertEqual(a2, sorted(a2))
        self.assertEqual(prog[0].payload(), {"held_s": 0.16, "attempt": 1})

    def test_request_can_force_whole_or_streaming(self):
        self.assertTrue(Guarded(Script({}), "x", 3.0, seed=1, whole=True).whole)
        self.assertFalse(Guarded(Script({}), "x", 1.0, seed=1, whole=False).whole)

    def test_raw_policy_passes_everything_through(self):
        # bench calibration mode: no hold, no verdicts, one attempt, chunks as they come
        s = Script({"default": (tokens(20) + [42] * 40, True)})
        g = Guarded(s, "x" * 400, 1.0, seed=1, policy=Policy.raw(), ref_cb0=list(range(0, 3000)))
        it = iter(g)
        self.assertIsNone(next(it))
        self.assertIsNotNone(next(it))                       # frame 2 = first chunk, no hold
        rest = [c for c in it if audio(c)]
        self.assertEqual(sum(len(c) for c in rest) + 2 * FRAME, 60 * FRAME)
        r = g.report
        self.assertEqual((r["runaway"], r["short"], r["echo_aborts"], r["attempts"], r["whole"]), (False, False, 0, 1, False))

    def test_token_cap_is_the_inner_max_frames(self):
        s = Script({"default": (tokens(12), True)})
        run(Guarded(s, "Danke schön.", 1.0, seed=1))
        self.assertEqual(s.max_frames, [guards.token_cap_frames("Danke schön.")])


if __name__ == "__main__":
    unittest.main()
