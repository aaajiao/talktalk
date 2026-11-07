"""Single GPU thread with cooperative EDF scheduling (§6.1).

Jobs are Python generators created and advanced only on the GPU thread. One `next()` is one
non-preemptible step (a TTS frame, an ASR token, a background chunk). Rules (§6.1):
  0  render horizon: a TTS job is runnable only while bufferedAhead < horizonMs
  1  any TTS job with bufferedAhead < 250 ms runs first
  2  admission: a step of estimated cost c starts only if every active TTS job has
     bufferedAhead >= c + 150 ms; otherwise TTS runs first. c is the rolling p95 of that step
     class: `<kind>.first` for a job's first step (TTS ICL prefill, ASR encode + prefill), `<kind>`
     for the rest; a class with fewer than 5 samples uses a conservative default (DEFAULT_COST_MS)
  3  otherwise earliest deadline first; ties P0 > P1 > P2 > P3
  -  tts and voice_warmup share one stateful decoder: a started generator owns it until close,
     even while parked at the render horizon; ASR may still run between its steps
  6  while SPEAK is active (/v1/session speak_active, or any TTS job queued), P2 is paused
  7  P2 past its deadline is dropped, whether paused, not started or running (a running one is
     cancelled before its next step): counted in expired_dropped, finished with err "expired".
     P0, P1 and P3 are never dropped for lateness (the app cancels them)
bufferedAhead comes from the app's /v1/playout reports. Without any report (bench, smoke) it is
unknown and TTS is never held back by the horizon.
"""
import collections
import ctypes
import itertools
import queue
import sys
import threading
import time
import traceback

P0, P1, P2, P3 = 0, 1, 2, 3
_seq = itertools.count()

# Rule-2 cost guess for a step class with fewer than 5 samples. First steps are the expensive ones
# (ICL prefill, ASR encode), so they start at the 150 ms non-preemptible bound (rule 4).
DEFAULT_COST_MS = 20.0
DEFAULT_FIRST_COST_MS = 150.0
_TTS_DECODER_JOBS = ("tts", "voice_warmup")


def step_class(job):
    """The class of the job's next step: `<kind>.first` before its first step, else `<kind>`."""
    return job.kind + (".first" if job.steps == 0 else "")


def _now_ms():
    return time.monotonic() * 1e3


def set_thread_qos_user_interactive():
    """pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) (§6.3)."""
    try:
        libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        return libc.pthread_set_qos_class_self_np(0x21, 0) == 0
    except OSError:
        return False


class RollingP95:
    def __init__(self, n=200, default=20.0):
        self.v = collections.deque(maxlen=n)
        self.default = default

    def add(self, x):
        self.v.append(x)

    def p95(self):
        if len(self.v) < 5:
            return self.default
        s = sorted(self.v)
        return s[min(len(s) - 1, int(0.95 * (len(s) - 1)))]


class Job:
    """A scheduled unit of GPU work. `factory()` is called on the GPU thread and returns a generator."""

    def __init__(self, kind, priority, factory, job_id=None, deadline_ms=None, on_item=None, on_done=None):
        self.kind = kind
        self.priority = priority
        self.factory = factory
        self.job_id = job_id or f"{kind}-{next(_seq)}"
        self.created_ms = _now_ms()
        self.deadline_ms = deadline_ms if deadline_ms is not None else self.created_ms
        self.on_item = on_item or (lambda item: None)
        self.on_done = on_done or (lambda err: None)
        self.gen = None
        self.cancelled = threading.Event()
        self.expired = False          # rule 7 drop (P2 only)
        self.finished = False
        self.seq = next(_seq)
        self.produced_audio_ms = 0.0
        self.steps = 0
        # Watchdog time excludes idle time and deliberate scheduler parking. Updated under cv.
        self.runnable_since_ms = None

    def cancel(self):
        self.cancelled.set()


class GpuScheduler:
    def __init__(self, horizon_ms=1000.0):   # M2 T2 pick (2026-11-05)
        self.horizon_ms = horizon_ms
        self.jobs = []
        self.cv = threading.Condition()
        self.calls = queue.Queue()
        self.thread = None
        self.last_step_at = None
        self.in_long_step = False
        self.expired_dropped = 0
        self.speak_active = False
        self.playout = None             # (buffered_ms, at_ms, produced_since_ms)
        self.step_cost = {}                # step class -> RollingP95 (rule 2)
        self.step_hist = collections.defaultdict(lambda: collections.deque(maxlen=20000))
        self.tts_rtf_recent = collections.deque(maxlen=50)
        self.qos_ok = None
        self.thread_ident = None

    # ------------------------------------------------------------ public (any thread)

    def start(self, init=None, name="gpu"):
        ready = threading.Event()
        err = []

        def run():
            self.thread_ident = threading.get_ident()
            self.qos_ok = set_thread_qos_user_interactive()
            try:
                if init:
                    self.in_long_step = True
                    init()
            except BaseException as e:  # noqa: BLE001
                err.append(e)
                ready.set()
                return
            finally:
                self.in_long_step = False
            ready.set()
            self._loop()

        self.thread = threading.Thread(target=run, name=name, daemon=True)
        self.thread.start()
        ready.wait()
        if err:
            raise err[0]

    def call(self, fn, long_step=False, timeout=None):
        """Runs fn() on the GPU thread between steps and returns its result (or raises)."""
        if threading.get_ident() == self.thread_ident:
            return fn()
        done = threading.Event()
        box = {}

        def wrapped():
            self.in_long_step = long_step
            try:
                box["v"] = fn()
            except BaseException as e:  # noqa: BLE001
                box["e"] = e
            finally:
                self.in_long_step = False
                done.set()

        self.calls.put(wrapped)
        with self.cv:
            self.cv.notify()
        if not done.wait(timeout):
            raise TimeoutError("GPU call timed out")
        if "e" in box:
            raise box["e"]
        return box.get("v")

    def submit(self, job):
        with self.cv:
            self.jobs.append(job)
            self._watchdog_jobs_locked(_now_ms())
            self.cv.notify()
        return job

    def cancel(self, job_id=None, scope=None):
        n = 0
        with self.cv:
            for j in self.jobs:
                if (job_id and j.job_id == job_id) or scope == "all" or \
                   (scope == "speak" and j.priority in (P0, P1)) or (scope == "listen" and j.priority == P2):
                    j.cancel()
                    n += 1
            self._watchdog_jobs_locked(_now_ms())
            self.cv.notify()
        return n

    def report_playout(self, buffered_ms):
        with self.cv:
            self.playout = [float(buffered_ms), _now_ms(), 0.0]
            self._watchdog_jobs_locked(_now_ms())
            self.cv.notify()

    def set_session(self, speak_active):
        with self.cv:
            self.speak_active = bool(speak_active)
            self._watchdog_jobs_locked(_now_ms())
            self.cv.notify()

    def buffered_ahead_ms(self, now=None):
        p = self.playout
        if p is None:
            return None
        now = now if now is not None else _now_ms()
        return max(0.0, p[0] + p[2] - (now - p[1]))

    def _watchdog_jobs_locked(self, now):
        # These waits are intentional, not stalled GPU work: the render horizon, P2 paused
        # during SPEAK, and another generator owning the shared TTS decoder.
        live = [j for j in self.jobs if not j.finished and not j.cancelled.is_set()]
        owner = self._decoder_owner(live)
        parked = {j for j in live if owner is not None and j is not owner and j.kind in _TTS_DECODER_JOBS}
        tts_live = [j for j in live if j.priority == P0]
        buffered = self.buffered_ahead_ms(now)
        if buffered is not None and buffered >= self.horizon_ms:
            parked.update(tts_live)
        if self.speak_active or tts_live:
            parked.update(j for j in live if j.priority == P2)
        runnable = set(live) - parked
        for j in self.jobs:
            if j not in runnable:
                j.runnable_since_ms = None
            elif j.runnable_since_ms is None:
                j.runnable_since_ms = now
        return live, parked

    def health(self):
        with self.cv:
            now = _now_ms()
            live, parked_jobs = self._watchdog_jobs_locked(now)
            q = {f"p{i}": sum(1 for j in live if j.priority == i) for i in range(4)}
            parked = len(parked_jobs)
            starts = [j.runnable_since_ms for j in live if j not in parked_jobs]
            # Keep the wire field, but never charge a new/unparked job for earlier idle time.
            # New arrivals cannot reset an older runnable job's genuine stall.
            since = max(min(starts), self.last_step_at or 0.0) if starts else None
            age = None if since is None else round(max(0.0, now - since), 1)
        rtf = sorted(self.tts_rtf_recent)
        return {"last_step_age_ms": age, "in_long_step": self.in_long_step, "queue": q, "parked": parked,
                "expired_dropped": self.expired_dropped,
                "step_p99": {k: v["p99"] for k, v in self.stats().items()},
                "tts_rtf_recent": round(rtf[len(rtf) // 2], 4) if rtf else None, "qos_user_interactive": self.qos_ok}

    def stats(self):
        out = {}
        for kind, hist in list(self.step_hist.items()):
            s = sorted(hist.copy())    # deque.copy is one C call: safe against the GPU thread's appends
            if not s:
                continue
            pick = lambda q: round(s[min(len(s) - 1, int(q * (len(s) - 1)))], 2)  # noqa: E731
            out[kind] = {"n": len(s), "p50": pick(0.5), "p95": pick(0.95), "p99": pick(0.99), "max": round(s[-1], 2)}
        return out

    def cost_ms(self, cls):
        """Rule 2: the rolling p95 of one step class."""
        r = self.step_cost.get(cls)
        if r is None:
            r = self.step_cost[cls] = RollingP95(
                default=DEFAULT_FIRST_COST_MS if cls.endswith(".first") else DEFAULT_COST_MS)
        return r.p95()

    # ------------------------------------------------------------ GPU thread

    def note_audio(self, job, audio_ms):
        job.produced_audio_ms += audio_ms
        if self.playout is not None:
            self.playout[2] += audio_ms

    @staticmethod
    def _decoder_owner(live):
        return next((j for j in live if j.kind in _TTS_DECODER_JOBS and j.gen is not None), None)

    def _pick(self, now):
        self._watchdog_jobs_locked(now)
        live = [j for j in self.jobs if not j.finished]
        if not live:
            return None
        for j in live:
            if j.cancelled.is_set():
                return j          # retire cancelled jobs first (closes their generator on this thread)
        # A warmup uses the same decoder and MLX RNG as a foreground TTS generator. Never
        # start another one between its yields: reset/prime/close would corrupt its state.
        # No wait or GPU-thread lock: keep unrelated work eligible while the owner is parked.
        owner = self._decoder_owner(live)
        eligible = [j for j in live if owner is None or j is owner or j.kind not in _TTS_DECODER_JOBS]
        buffered = self.buffered_ahead_ms(now)
        tts = [j for j in live if j.priority == P0]
        tts_runnable = [j for j in eligible if j.priority == P0 and (buffered is None or buffered < self.horizon_ms)]
        # rule 1
        if tts_runnable and buffered is not None and buffered < 250:
            return min(tts_runnable, key=lambda j: j.seq)
        candidates = []
        for j in eligible:
            if j.priority == P0:
                if j in tts_runnable:
                    d = now if buffered is None else now + buffered - 250
                    candidates.append((d, j.priority, j.seq, j))
                continue
            if j.priority == P2:
                # rule 7 before rule 6: a paused P2 still expires, so the app falls back at once
                if now > j.deadline_ms:
                    j.expired = True
                    j.cancel()
                    self.expired_dropped += 1
                    return j
                if self.speak_active or tts:
                    continue
            # rule 2: admission against every active TTS job
            if tts and buffered is not None:
                if buffered < self.cost_ms(step_class(j)) + 150:
                    if tts_runnable:
                        continue
            candidates.append((j.deadline_ms, j.priority, j.seq, j))
        if not candidates:
            return None
        candidates.sort(key=lambda t: (t[0], t[1], t[2]))
        return candidates[0][3]

    def _retire(self, job, err=None):
        job.finished = True
        if job.gen is not None:
            try:
                job.gen.close()
            except Exception:  # noqa: BLE001
                traceback.print_exc(file=sys.stderr)
        with self.cv:
            if job in self.jobs:
                self.jobs.remove(job)
            self._watchdog_jobs_locked(_now_ms())
        try:
            job.on_done(err)
        except Exception:  # noqa: BLE001
            traceback.print_exc(file=sys.stderr)

    def _loop(self):
        while True:
            while True:
                try:
                    fn = self.calls.get_nowait()
                except queue.Empty:
                    break
                fn()
                self.last_step_at = _now_ms()
            with self.cv:
                job = self._pick(_now_ms())
                if job is None:
                    # wake on new work, playout reports, or periodically to re-check horizons
                    self.cv.wait(timeout=0.01 if self.jobs else 0.5)
                    continue
            if job.cancelled.is_set():
                self._retire(job, err="expired" if job.expired else "cancelled")
                continue
            t0 = time.perf_counter()
            try:
                if job.gen is None:
                    job.gen = job.factory()
                item = next(job.gen)
            except StopIteration:
                self._retire(job)
                continue
            except BaseException as e:  # noqa: BLE001
                traceback.print_exc(file=sys.stderr)
                self._retire(job, err=e)
                continue
            dt = (time.perf_counter() - t0) * 1e3
            cls = step_class(job)
            job.steps += 1
            self.cost_ms(cls)                          # creates the class with its default
            self.step_cost[cls].add(dt)
            self.step_hist[cls].append(dt)
            self.last_step_at = _now_ms()
            if item is not None:
                try:
                    job.on_item(item)
                except Exception:  # noqa: BLE001
                    traceback.print_exc(file=sys.stderr)
                    job.cancel()
