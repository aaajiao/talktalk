"""ASR-first readiness and background warmup contracts, without MLX or audio devices."""
import http.client
import json
import queue
import sys
import tempfile
import threading
import time
import types
import unittest
import wave
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np

from talktalk_engine import frames, main, server
from talktalk_engine.scheduler import GpuScheduler, Job, P0, P2, P3, _now_ms


class InlineScheduler:
    thread = None

    def __init__(self):
        self.jobs = []

    def call(self, fn, **kwargs):
        return fn()

    def submit(self, job):
        self.jobs.append(job)
        return job


class ModelDiscoveryTests(unittest.TestCase):
    def test_exact_directory_keeps_selected_revision_when_another_sorts_first(self):
        with tempfile.TemporaryDirectory() as root:
            base = Path(root)
            old, selected = base / "ASR-Y@aaaa", base / "ASR-Y@cccc"
            for directory, revision in ((old, "aaaa"), (selected, "cccc")):
                directory.mkdir()
                (directory / ".talktalk-verified").write_text(f"{revision}\nkey=asr-y repo=org/ASR-Y\n")
            # Legacy root scanning remains available to command-line callers.
            self.assertEqual(main.find_models([base]), {"asr-y": (old, "aaaa")})
            # App configuration gives the exact manifest directory, bypassing the sibling.
            self.assertEqual(main.find_models([selected]), {"asr-y": (selected, "cccc")})
            self.assertEqual(main.find_models([selected, base]), {"asr-y": (selected, "cccc")})

    def test_exact_asr_and_tts_directories_do_not_discover_unselected_models(self):
        with tempfile.TemporaryDirectory() as root:
            base = Path(root)
            for key in ("asr-y", "tts-x", "unused"):
                directory = base / key
                directory.mkdir()
                (directory / ".talktalk-verified").write_text(f"revision-{key}\nkey={key}\n")
            found = main.find_models([base / "asr-y", base / "tts-x"])
            self.assertEqual(set(found), {"asr-y", "tts-x"})
            self.assertEqual(found["asr-y"], (base / "asr-y", "revision-asr-y"))


class StartupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        with wave.open(str(self.root / 'ref-zh.wav'), 'wb') as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(24000)
            wav.writeframes(np.arange(2400, dtype='<i2').tobytes())
        (self.root / 'ref-zh.txt').write_text('Synthetic startup reference.')
        self.trace = []
        trace = self.trace
        self.asr_error = self.tts_error = None
        owner = self

        class TTS:
            def __init__(self, key, path, rev):
                self.key, self.rev = key, rev

            def load(self):
                trace.append(('tts.load', self.key))
                return self

            def build_voice(self, pcm, text, key):
                trace.append(('tts.reference', len(pcm), text, key))
                return object(), {}

            def stream(self, text, voice, lang, **kwargs):
                trace.append(('tts.stream', text, lang, kwargs))
                if owner.tts_error:
                    raise owner.tts_error
                yield None
                yield np.zeros(3840, np.float32)

        class ASR:
            def __init__(self, key, path, rev):
                trace.append(('asr.construct', key))

            def load(self):
                trace.append(('asr.load',))
                if owner.asr_error:
                    raise owner.asr_error

            def stream(self, pcm, **kwargs):
                trace.append(('asr.warm', pcm.copy(), kwargs))
                yield None

        mx = types.ModuleType('mlx.core')
        mx.__version__ = 'fake'
        mx.set_cache_limit = mx.set_wired_limit = lambda n: None
        mlx = types.ModuleType('mlx')
        mlx.core = mx
        audio = types.ModuleType('mlx_audio')
        version = types.ModuleType('mlx_audio.version')
        version.__version__ = 'fake'
        transformers = types.ModuleType('transformers')
        transformers.__version__ = 'fake'
        self.addCleanup(patch.stopall)
        patch.dict(sys.modules, {'mlx': mlx, 'mlx.core': mx, 'mlx_audio': audio,
                                 'mlx_audio.version': version, 'transformers': transformers}).start()
        patch('talktalk_engine.tts.TTSModel', TTS).start()
        patch('talktalk_engine.asr.ASRModel', ASR).start()
        patch('talktalk_engine.ming.MingTTSModel', TTS).start()
        patch.object(main, 'find_models', return_value={
            'tts-qwen3-1.7b-base-8bit': (self.root, 'qwen-rev'),
            'tts-ming3-0.5b-bf16': (self.root, 'ming-rev'),
            'asr-qwen3-0.6b-8bit': (self.root, 'asr-rev'),
        }).start()
        self.progress = patch.object(main.handshake, 'progress').start()

    def state(self, *flags):
        args = main.parse(['--models-dir', str(self.root), '--warmup-dir', str(self.root), *flags])
        state = main.EngineState(args)
        state.sched = state.asr_sched = InlineScheduler()
        return state

    def finish_warmup(self, state):
        job = state.sched.jobs[0]
        job.gen = job.factory()
        try:
            for _ in job.gen:
                pass
        except BaseException as err:
            job.on_done(err)
            return err
        job.on_done(None)

    def assert_asr_warmup_unchanged(self):
        warmups = [entry for entry in self.trace if entry[0] == 'asr.warm']
        self.assertEqual(len(warmups), 2)
        rng = np.random.default_rng(0)
        for entry, seconds in zip(warmups, (1, 3)):
            expected = (rng.standard_normal(16000 * seconds) * 0.003).astype(np.float32)
            np.testing.assert_array_equal(entry[1], expected)
            self.assertEqual(entry[2], {'hint': 'zh', 'max_tokens': 4})

    def assert_tts_warmup_unchanged(self):
        warmups = [entry for entry in self.trace if entry[0] == 'tts.stream']
        self.assertEqual(warmups, [
            ('tts.stream', 'Thanks, everyone.', 'en', {'interval': 0.16, 'max_frames': 40, 'seed': 0}),
            ('tts.stream', 'Danke Ihnen allen.', 'de', {'interval': 0.16, 'max_frames': 40, 'seed': 0}),
        ])
        references = [entry for entry in self.trace if entry[0] == 'tts.reference']
        self.assertEqual(references, [('tts.reference', 2400, 'Synthetic startup reference.', 'warmup')])

    def test_default_still_finishes_tts_before_background_asr(self):
        state = self.state()
        self.assertFalse(state.args.asr_first)
        state.gpu_init()
        self.assertEqual(state.models['tts']['state'], 'ready')
        self.assertEqual(state.asr_state, 'loading')
        self.assertEqual(state.sched.jobs, [])
        self.assert_tts_warmup_unchanged()
        self.assertNotIn(('asr.load',), self.trace)
        self.progress.assert_any_call('warmup', 2, 2)
        state._load_asr_ready()
        self.assertEqual(state.asr_state, 'ready')
        self.assert_asr_warmup_unchanged()

    def test_asr_first_has_ready_asr_and_defers_identical_tts_for_both_models(self):
        for tts in ('tts-qwen3-1.7b-base-8bit', 'tts-ming3-0.5b-bf16'):
            with self.subTest(tts=tts):
                self.trace.clear()
                self.progress.reset_mock()
                state = self.state('--asr-first', '--tts', tts)
                state.gpu_init()
                self.assertEqual(state.asr_state, 'ready')
                self.assertEqual(state.models['asr']['state'], 'ready')
                self.assertEqual(state.models['tts']['state'], 'loading')
                self.assertFalse(any(entry[0].startswith('tts.') and entry[0] != 'tts.load'
                                     for entry in self.trace))
                self.assert_asr_warmup_unchanged()
                job, = state.sched.jobs
                self.assertEqual((job.kind, job.priority, job.deadline_ms), ('generic_warmup', P3, float('inf')))
                self.progress.reset_mock()
                self.assertIsNone(self.finish_warmup(state))
                self.assertEqual(state.models['tts']['state'], 'ready')
                self.assert_tts_warmup_unchanged()
                self.assertEqual(self.trace.count(('asr.load',)), 1)
                self.progress.assert_not_called()  # READY closes this fd.

    def test_flag_without_asr_keeps_synchronous_tts_startup(self):
        state = self.state('--asr-first', '--roles', 'tts')
        state.gpu_init()
        self.assertEqual(state.models['tts']['state'], 'ready')
        self.assertEqual(state.asr_state, 'absent')
        self.assertEqual(state.sched.jobs, [])
        self.assert_tts_warmup_unchanged()

    def test_asr_only_flag_never_creates_tts_work(self):
        state = self.state('--asr-first', '--roles', 'asr')
        state.gpu_init()
        self.assertEqual(state.models['asr']['state'], 'ready')
        self.assertNotIn('tts', state.models)
        self.assertEqual(state.sched.jobs, [])
        self.assert_asr_warmup_unchanged()

    def test_asr_failure_keeps_tts_available_for_apple_asr_fallback(self):
        self.asr_error = RuntimeError('synthetic ASR failure')
        state = self.state('--asr-first')
        state.gpu_init()
        self.assertEqual(state.models['asr']['state'], 'failed')
        self.assertEqual(state.asr_state, 'failed')
        self.assertEqual(state.models['tts']['state'], 'loading')
        self.assertEqual(len(state.sched.jobs), 1)
        self.assertIsNone(self.finish_warmup(state))
        self.assertEqual(state.models['tts']['state'], 'ready')
        self.assertEqual(self.trace.count(('asr.load',)), 1)

    def test_warmup_failure_keeps_asr_ready_and_blocks_all_tts_operations(self):
        state = self.state('--asr-first')
        state.gpu_init()
        self.tts_error = RuntimeError('synthetic warmup failure')
        self.assertIs(self.finish_warmup(state), self.tts_error)
        self.assertEqual(state.models['tts']['state'], 'failed')
        self.assertEqual(state.asr_state, 'ready')
        self.assert_not_ready_operations(state)

    def assert_not_ready_operations(self, state):
        state.voice = SimpleNamespace(key='voice')
        state.voice_state = 'ready'
        old_generation = state.voice_gen
        for call in (lambda: state.build_voice(np.zeros(24000), 'Reference.'),
                     lambda: state.load_voice(b'not parsed'),
                     lambda: state.tts_job({'text': 'Hello.', 'lang': 'en'}, queue.Queue()),
                     lambda: state.similarity(np.zeros(24000), np.zeros(24000))):
            with self.assertRaises(server.ApiError) as error:
                call()
            self.assertEqual((error.exception.status, error.exception.code), (409, 'tts_not_ready'))
        self.assertEqual(state.voice_gen, old_generation)

    def test_raw_http_cannot_bypass_loading_tts_readiness(self):
        state = self.state('--asr-first')
        state.gpu_init()
        self.assert_not_ready_operations(state)
        state.token = 'test-token'
        srv = server.serve(state)
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        pcm = np.zeros(12000, dtype='<f4').tobytes()
        requests = [
            ('/v1/voice/build', frames.encode(frames.JSON_HEAD, {'ref_text': 'Reference.'}) +
             frames.encode(frames.PCM_F32_24K, pcm)),
            ('/v1/voice/load', frames.encode(frames.BLOB, b'not parsed')),
            ('/v1/voice/similarity', frames.encode(frames.PCM_F32_24K, pcm) * 2),
            ('/v1/tts', json.dumps({'text': 'Hello.', 'lang': 'en'}).encode()),
        ]
        for path, body in requests:
            with self.subTest(path=path):
                connection = http.client.HTTPConnection('127.0.0.1', srv.server_port, timeout=2)
                connection.request('POST', path, body, {'Authorization': 'Bearer test-token'})
                response = connection.getresponse()
                payload = json.loads(response.read())
                connection.close()
                self.assertEqual((response.status, payload['error']['code']), (409, 'tts_not_ready'))


class StartupSchedulerTests(unittest.TestCase):
    def test_generic_warmup_owns_decoder_and_allows_listen_asr_between_steps(self):
        scheduler = GpuScheduler()
        entered, release, finished = threading.Event(), threading.Event(), threading.Event()
        trace = []

        def generic():
            trace.append(('reference', scheduler.in_long_step))
            entered.set()
            if not release.wait(2):
                raise TimeoutError('test did not release reference preparation')
            yield None
            trace.append(('generic.decode', scheduler.in_long_step))
            yield None

        def asr():
            trace.append(('asr', scheduler.in_long_step))
            yield None

        def voice():
            trace.append(('voice', scheduler.in_long_step))
            yield None

        warm = Job('generic_warmup', P3, generic, deadline_ms=float('inf'))
        scheduler.submit(warm)
        scheduler.start()
        self.addCleanup(release.set)
        self.assertTrue(entered.wait(2))
        self.assertTrue(scheduler.health()['in_long_step'])
        scheduler.submit(Job('voice_warmup', P3, voice, deadline_ms=float('inf'),
                             on_done=lambda err: finished.set()))
        scheduler.submit(Job('asr', P2, asr, deadline_ms=_now_ms() + 1000))
        release.set()
        self.assertTrue(finished.wait(2))
        self.assertEqual(trace, [('reference', True), ('asr', False),
                                 ('generic.decode', False), ('voice', False)])
        self.assertFalse(scheduler.health()['in_long_step'])
        self.assertEqual(scheduler.expired_dropped, 0)

    def test_generic_owner_blocks_foreground_decoder_until_retired(self):
        scheduler = GpuScheduler()
        warm = Job('generic_warmup', P3, lambda: (None for _ in range(1)), deadline_ms=float('inf'))
        warm.gen = warm.factory()
        next(warm.gen)
        tts = Job('tts', P0, lambda: (None for _ in range(1)))
        scheduler.submit(warm)
        scheduler.submit(tts)
        self.assertIs(scheduler._pick(_now_ms()), warm)
        scheduler._retire(warm)
        self.assertIs(scheduler._pick(_now_ms()), tts)


if __name__ == '__main__':
    unittest.main()
