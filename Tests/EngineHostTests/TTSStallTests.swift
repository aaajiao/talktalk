import Foundation
import Synchronization
import Testing
@testable import TalkTalkCore
@testable import TalkTalkEngineHost

/// SPEAK stall rule (§5.7, TTSStall + TTSStallBoard + RemoteQwenTTS.speak) and the /v1/playout
/// cadence (PlayoutReporter, §4.4), against pure inputs with injected instants and the fake engine.
@Suite(.serialized) struct TTSStallTests {
    static let fast: TTSStall.Config = {
        var c = TTSStall.Config()
        c.stallAfter = .milliseconds(300)
        c.hangAfter = .milliseconds(1000)
        c.tick = .milliseconds(20)
        return c
    }()

    static func gpu(pending: Int, ageMs: Double?, longStep: Bool = false) -> EngineHealth.GPU {
        EngineHealth.GPU(lastStepAgeMs: ageMs, inLongStep: longStep, queue: ["p0": pending, "p1": 0, "p2": 0, "p3": 0])
    }

    static func report(buffered: Int, underruns: Int = 0, paused: Bool = false, tempo: Double = 1, epoch: UInt32 = 1) -> PlayoutReport {
        PlayoutReport(job: 7, bufferedMs: buffered, underruns: underruns, paused: paused, tempo: tempo, epoch: epoch, at: 0)
    }

    static func ms(_ t0: ContinuousClock.Instant, _ n: Int) -> ContinuousClock.Instant { t0 + .milliseconds(n) }

    // MARK: pure rule

    @Test func stallNeedsSilenceEmptyBufferAndNoLongStep() {
        let c = TTSStall.Config()
        #expect(TTSStall.isStalled(sinceLastChunk: .milliseconds(1000), bufferedMs: 0, inLongStep: false, config: c))
        #expect(TTSStall.isStalled(sinceLastChunk: .milliseconds(1200), bufferedMs: nil, inLongStep: false, config: c))
        #expect(!TTSStall.isStalled(sinceLastChunk: .milliseconds(999), bufferedMs: 0, inLongStep: false, config: c))
        #expect(!TTSStall.isStalled(sinceLastChunk: .seconds(3), bufferedMs: 40, inLongStep: false, config: c))
        #expect(!TTSStall.isStalled(sinceLastChunk: .seconds(3), bufferedMs: 0, inLongStep: true, config: c))
    }

    @Test func hangNeedsAPendingJobWithoutSteps() {
        let c = TTSStall.Config()
        #expect(TTSStall.isHung(nil, config: c))                                   // no health answer
        #expect(TTSStall.isHung(Self.gpu(pending: 1, ageMs: 4200), config: c))
        #expect(TTSStall.isHung(Self.gpu(pending: 1, ageMs: nil), config: c))
        #expect(!TTSStall.isHung(Self.gpu(pending: 0, ageMs: 9000), config: c))      // idle after the cancel
        #expect(!TTSStall.isHung(Self.gpu(pending: 2, ageMs: 40), config: c))        // still stepping
        #expect(!TTSStall.isHung(Self.gpu(pending: 1, ageMs: 9000, longStep: true), config: c))
    }

    /// Review [低] in_long_step: the window restarts at the last long-step observation, so the
    /// verdict comes `stallAfter` after the step ended (on→off), not at the next check.
    @Test func longStepRestartsTheWindowUntilItEnds() {
        let c = TTSStall.Config()                  // stallAfter 1 s
        let t0 = ContinuousClock.now
        var w = TTSStall.Window(start: t0)
        #expect(!w.needsHealth(at: Self.ms(t0, 900), aheadMs: 0, config: c))
        #expect(!w.needsHealth(at: Self.ms(t0, 1100), aheadMs: 50, config: c))      // something drainable
        #expect(w.needsHealth(at: Self.ms(t0, 1100), aheadMs: 0, config: c))
        var stalled = w.observe(at: Self.ms(t0, 1100), inLongStep: true, aheadMs: 0, config: c)
        #expect(!stalled)
        #expect(w.inLongStep && w.start == Self.ms(t0, 1100))
        #expect(w.needsHealth(at: Self.ms(t0, 1200), aheadMs: 0, config: c))        // poll on while long
        stalled = w.observe(at: Self.ms(t0, 1200), inLongStep: true, aheadMs: 0, config: c)
        #expect(!stalled)
        stalled = w.observe(at: Self.ms(t0, 1300), inLongStep: false, aheadMs: 0, config: c)   // off: 0.1 s in
        #expect(!stalled)
        #expect(!w.inLongStep)
        #expect(!w.needsHealth(at: Self.ms(t0, 2100), aheadMs: 0, config: c))
        #expect(w.needsHealth(at: Self.ms(t0, 2200), aheadMs: 0, config: c))
        stalled = w.observe(at: Self.ms(t0, 2200), inLongStep: false, aheadMs: 0, config: c)   // 1 s after the step
        #expect(stalled)
        w.chunk(at: Self.ms(t0, 2300))
        #expect(!w.needsHealth(at: Self.ms(t0, 3200), aheadMs: 0, config: c))
    }

    /// Review [高]: only the oldest open stream is judged; the next one's window starts when it
    /// becomes the head; an unresolved stall holds everyone until resolved; a chunk resolves it.
    @Test func boardJudgesOnlyTheHeadAndRestartsTheNext() {
        let b = TTSStallBoard()
        let t0 = ContinuousClock.now
        let a = b.open(at: t0)
        let n = b.open(at: t0)
        #expect(b.isHead(a) && !b.isHead(n))
        b.chunk(a, at: Self.ms(t0, 200))
        #expect(b.chunks(a) == 1 && b.chunks(n) == 0)
        b.close(a, at: Self.ms(t0, 1500))
        #expect(b.isHead(n))
        #expect(b.window(n)?.start == Self.ms(t0, 1500))                   // not t0: it waited its turn
        let t1 = b.markStalled(since: Self.ms(t0, 1500))
        #expect(b.unresolvedSince != nil)
        b.resolve(t1, at: Self.ms(t0, 2000))
        #expect(b.unresolvedSince == nil && b.window(n)?.start == Self.ms(t0, 2000))
        _ = b.markStalled(since: Self.ms(t0, 2000))
        b.chunk(n, at: Self.ms(t0, 2100))
        #expect(b.unresolvedSince == nil)
        b.close(n, at: Self.ms(t0, 2200))
        #expect(b.openCount == 0)
    }

    /// Progress frames restart the window and resolve a stall but are not chunks.
    @Test func progressRestartsTheWindowWithoutCountingAChunk() {
        let b = TTSStallBoard()
        let t0 = ContinuousClock.now
        let a = b.open(at: t0)
        _ = b.markStalled(since: t0)
        b.progress(a, at: Self.ms(t0, 400))
        #expect(b.window(a)?.start == Self.ms(t0, 400))
        #expect(b.unresolvedSince == nil)
        #expect(b.chunks(a) == 0)
    }

    /// Review [低] PlayoutReporter:93 + [中] drainable: what the rule reads decays with time, and the
    /// drainable amount wins over bufferedMs (held preroll / whole-clause audio is not drainable).
    @Test func aheadDecaysAndPrefersDrainable() {
        let box = PlayoutBox()
        let t0 = ContinuousClock.now
        #expect(box.aheadMs(at: t0) == 0)                                   // nothing reported yet
        box.set(Self.report(buffered: 400), at: t0)
        #expect(box.aheadMs(at: t0) == 400)
        #expect(box.aheadMs(at: Self.ms(t0, 100)) == 300)
        #expect(box.aheadMs(at: Self.ms(t0, 500)) == 0)                     // a frozen report runs out
        box.setDrainable(0, at: t0)
        #expect(box.aheadMs(at: t0) == 0)                                   // 400 buffered, all held back
        box.setDrainable(250, at: Self.ms(t0, 100))
        #expect(box.aheadMs(at: Self.ms(t0, 150)) == 200)
    }

    /// 00f65f3 review [低] RemoteQwen+Core:228: each stall has its own token. A hang check that
    /// wakes for an older stall neither checks nor clears a newer one (compare-and-clear).
    @Test func staleHangCheckDoesNotClearAnotherStall() {
        let b = TTSStallBoard()
        let t0 = ContinuousClock.now
        let a = b.open(at: t0)
        let tA = b.markStalled(since: t0)
        b.chunk(a, at: Self.ms(t0, 300))                                     // A's stall resolved by a chunk
        #expect(!b.isUnresolved(tA))
        let tB = b.markStalled(since: Self.ms(t0, 300))                      // then another one stalls
        #expect(tB != tA && !b.isUnresolved(tA) && b.isUnresolved(tB))
        b.resolve(tA, at: Self.ms(t0, 1000))                                 // A's check wakes: no effect
        #expect(b.unresolvedSince == Self.ms(t0, 300))
        #expect(b.window(a)?.start == Self.ms(t0, 300))
        b.resolve(tB, at: Self.ms(t0, 1300))
        #expect(b.unresolvedSince == nil && b.window(a)?.start == Self.ms(t0, 1300))
    }

    /// 00f65f3 review [低] H1: the engine numbers jobs on HTTP arrival, so speak() order is not render
    /// order. The head frame's seq reorders the board; a new head's window starts then.
    @Test func engineSeqOrdersTheBoard() {
        let b = TTSStallBoard()
        let t0 = ContinuousClock.now
        let c1 = b.open(at: t0), c2 = b.open(at: t0), c3 = b.open(at: t0)
        #expect(b.order == [c1, c2, c3])
        b.sequenced(c3, engineSeq: 7, at: Self.ms(t0, 5))                   // known seqs come first
        #expect(b.order == [c3, c1, c2])
        #expect(b.window(c3)?.start == Self.ms(t0, 5))
        b.sequenced(c1, engineSeq: 9, at: Self.ms(t0, 6))
        b.sequenced(c2, engineSeq: 8, at: Self.ms(t0, 7))
        #expect(b.order == [c3, c2, c1])
        #expect(b.window(c3)?.start == Self.ms(t0, 5))                      // head unchanged: no restart
        b.close(c3, at: Self.ms(t0, 900))
        #expect(b.isHead(c2) && b.window(c2)?.start == Self.ms(t0, 900))
        let c4 = b.open(at: Self.ms(t0, 950))                                // no seq yet: last
        #expect(b.order == [c2, c1, c4])
    }

    /// 00f65f3 review [低] in_long_step: a failed health call keeps the previous answer, so a long
    /// step is not taken as ended (and judged early) because one poll timed out.
    @Test func failedHealthKeepsTheLongStep() {
        let c = TTSStall.Config()
        let t0 = ContinuousClock.now
        var w = TTSStall.Window(start: t0)
        var stalled = w.observe(at: Self.ms(t0, 1100), inLongStep: true, aheadMs: 0, config: c)
        #expect(!stalled && w.inLongStep)
        stalled = w.observe(at: Self.ms(t0, 2300), inLongStep: nil, aheadMs: 0, config: c)    // poll failed
        #expect(!stalled && w.inLongStep && w.start == Self.ms(t0, 1100))     // failures do not move it
        stalled = w.observe(at: Self.ms(t0, 2400), inLongStep: false, aheadMs: 0, config: c)
        #expect(stalled)                                                    // 1.3 s after the last long poll
        var v = TTSStall.Window(start: t0)
        _ = v.observe(at: Self.ms(t0, 100), inLongStep: true, aheadMs: 0, config: c)
        stalled = v.observe(at: Self.ms(t0, 3400), inLongStep: nil, aheadMs: 0, config: c)    // not long before
        #expect(!stalled && v.inLongStep)
    }

    /// 00f65f3 re-review [low]: a remembered in_long_step does not stick forever: it lapses after
    /// `longStepFailedPolls` failed polls in a row, or `hangAfter` after the last poll that said so.
    @Test func rememberedLongStepLapses() {
        let c = TTSStall.Config()                                            // 3 polls, hangAfter 4 s
        let t0 = ContinuousClock.now
        func poll(_ w: inout TTSStall.Window, _ ms: Int, _ long: Bool?) -> Bool {
            w.observe(at: Self.ms(t0, ms), inLongStep: long, aheadMs: 0, config: c)
        }
        var w = TTSStall.Window(start: t0)
        _ = poll(&w, 1000, true)
        let s1 = poll(&w, 1500, nil), s2 = poll(&w, 2000, nil)
        #expect(!s1 && !s2)
        #expect(w.inLongStep && w.failedPolls == 2)
        let s3 = poll(&w, 2500, nil)                                         // 3rd failure in a row
        #expect(s3 && !w.inLongStep)
        var v = TTSStall.Window(start: t0)                                   // lapse by time
        _ = poll(&v, 1000, true)
        _ = poll(&v, 2000, nil)
        _ = poll(&v, 3000, true)                                             // resets the count
        #expect(v.failedPolls == 0)
        let early = poll(&v, 6900, nil)
        #expect(!early)
        let late = poll(&v, 7000, nil)                                       // 4 s since 3000
        #expect(late)
    }

    /// 00f65f3 review [中] TTSStall:179: paused, or bufferedMs at the render horizon, is a legal
    /// hold; a stale report (the reporter sends every 100 ms) is not trusted.
    @Test func pausedOrAtHorizonHoldsTheEngine() {
        var c = TTSStall.Config()                                            // stallAfter 1 s
        c.horizonMs = 1500
        let box = PlayoutBox()
        let t0 = ContinuousClock.now
        #expect(!box.holdsEngine(at: t0, config: c))                         // nothing reported
        box.set(Self.report(buffered: 300, paused: true), at: t0)
        #expect(box.holdsEngine(at: Self.ms(t0, 900), config: c))
        #expect(!box.holdsEngine(at: Self.ms(t0, 1000), config: c))          // stale
        box.set(Self.report(buffered: 1600), at: t0)
        #expect(box.holdsEngine(at: Self.ms(t0, 100), config: c))            // 1500 left: at the horizon
        #expect(!box.holdsEngine(at: Self.ms(t0, 101), config: c))           // drained below it
        box.setDrainable(0, at: t0)                                          // full but nothing drains
        #expect(!box.holdsEngine(at: Self.ms(t0, 50), config: c))
        box.setDrainable(300, at: t0)
        #expect(box.holdsEngine(at: Self.ms(t0, 50), config: c))
        box.set(Self.report(buffered: 800), at: t0)
        #expect(!box.holdsEngine(at: t0, config: c))
    }

    // MARK: PlayoutReporter

    @Test func cadenceRule() {
        let base = Self.report(buffered: 300)
        let i = Duration.milliseconds(100)
        #expect(PlayoutReporter.shouldSend(previous: nil, current: base, sinceLastSend: nil, interval: i))
        #expect(!PlayoutReporter.shouldSend(previous: base, current: Self.report(buffered: 260), sinceLastSend: .milliseconds(40), interval: i))
        #expect(PlayoutReporter.shouldSend(previous: base, current: Self.report(buffered: 260), sinceLastSend: .milliseconds(100), interval: i))
        #expect(PlayoutReporter.shouldSend(previous: base, current: Self.report(buffered: 300, paused: true), sinceLastSend: .milliseconds(5), interval: i))
        #expect(PlayoutReporter.shouldSend(previous: base, current: Self.report(buffered: 0, underruns: 1), sinceLastSend: .milliseconds(5), interval: i))
        #expect(PlayoutReporter.shouldSend(previous: base, current: Self.report(buffered: 300, tempo: 1.25), sinceLastSend: .milliseconds(5), interval: i))
        #expect(PlayoutReporter.shouldSend(previous: base, current: Self.report(buffered: 0, epoch: 2), sinceLastSend: .milliseconds(5), interval: i))
        #expect(PlayoutReporter.shouldSend(previous: base, current: base, sinceLastSend: .milliseconds(5), interval: i, kicked: true))
    }

    /// Review [低·测试] :71: the reporter is driven poll by poll with injected instants (no wall-clock
    /// windows). Also: the drainable amount is handed on at every poll, sent or not.
    @Test func reporterSendsOnIntervalAndAtOnceOnPause() async {
        let current = Mutex(Self.report(buffered: 300))
        let sent = Mutex<[PlayoutReport]>([])
        let drains = Mutex<[Int]>([])
        var cfg = PlayoutReporter.Config()
        cfg.interval = .milliseconds(200)
        let r = PlayoutReporter(config: cfg, source: { current.withLock { $0 } }, drainable: { 120 },
                                onDrainable: { v in drains.withLock { $0.append(v) } },
                                sink: { p in sent.withLock { $0.append(p) } })
        let t0 = ContinuousClock.now
        await r.step(at: t0)
        #expect(sent.withLock { $0.count } == 1)                           // the first report goes at once
        await r.step(at: Self.ms(t0, 50))
        await r.step(at: Self.ms(t0, 100))
        #expect(sent.withLock { $0.count } == 1)                           // inside the 200 ms interval
        current.withLock { $0 = Self.report(buffered: 280, paused: true) }
        await r.step(at: Self.ms(t0, 110))
        #expect(sent.withLock { $0.count } == 2 && sent.withLock { $0.last?.paused } == true)   // pause: at once
        await r.step(at: Self.ms(t0, 300))
        #expect(sent.withLock { $0.count } == 2)                           // 190 ms since the last send
        await r.step(at: Self.ms(t0, 310))
        #expect(sent.withLock { $0.count } == 3)                           // periodic again
        r.kick()
        await r.step(at: Self.ms(t0, 320))
        #expect(sent.withLock { $0.count } == 4)
        #expect(drains.withLock { $0 } == Array(repeating: 120, count: 7))
        #expect(r.sentCount == 4)
    }

    // MARK: RemoteQwenTTS against the fake engine

    static func loaded(_ extra: [String] = [], stall: TTSStall.Config = fast) async throws -> (EngineHostTests.Sandbox, EngineProcess, RemoteQwenTTS) {
        let box = try EngineHostTests.Sandbox()
        let e = EngineProcess(config: try box.config(extra: extra))
        let tts = RemoteQwenTTS(engine: e, stall: stall)
        let blob = try await tts.buildConditioning(
            VoiceReference(pcm24k: Data(repeating: 0, count: 4 * 2400), text: "参考", lang: .zh),
            model: RemoteQwenCoreTests.handle().model, mode: .icl)
        try await tts.load(RemoteQwenCoreTests.handle(), blob: blob)
        return (box, e, tts)
    }

    static func request(_ text: String, job: JobID) -> TTSRequest {
        TTSRequest(job: job, clause: job, text: text, language: .en, voice: RemoteQwenCoreTests.handle(), seed: 1, wholeClause: false)
    }

    /// Drains a stream; returns (chunks before the end, the error it ended with, when it ended).
    static func drain(_ s: AsyncThrowingStream<TTSChunk, any Error>,
                      firstChunk: (@Sendable () -> Void)? = nil) async -> (Int, (any Error)?, ContinuousClock.Instant) {
        var n = 0
        do {
            for try await c in s where !c.isLast {
                n += 1
                if n == 1 { firstChunk?() }
            }
            return (n, nil, .now)
        } catch {
            return (n, error, .now)
        }
    }

    /// Review [低·测试] :114: the not-hung case must not restart the engine (one launch), and the
    /// fake's idle step age keeps growing after the cancel (what makes `pending > 0` necessary).
    @Test func stallCancelsTheJobAndEndsTheStream() async throws {
        let (box, e, tts) = try await Self.loaded()
        let start = ContinuousClock.now
        let (chunks, err, end) = await Self.drain(tts.speak(Self.request("stall please", job: 21)))
        #expect(err as? RemoteEngineError == .stalled(chunksYielded: 1))
        #expect(chunks == 1)
        #expect(end - start >= .milliseconds(300) && end - start < .seconds(3))
        #expect(box.file("cancels.txt").contains("tts-21"))
        try await Task.sleep(for: .milliseconds(1200))                     // past hangAfter (1 s)
        #expect(EngineHostTests.isReady(await e.status))
        #expect(box.launches.count == 1)
        let client = try #require(await e.client)
        let a1 = try #require(try await client.health().gpu.lastStepAgeMs)
        try await Task.sleep(for: .milliseconds(200))
        let a2 = try #require(try await client.health().gpu.lastStepAgeMs)
        #expect(a2 > a1 + 100)
        await e.stop()
    }

    /// Review [低] TTSStall.swift:8: a stall before any chunk says so (stream failure, resend).
    @Test func zeroChunkStallReportsNoChunks() async throws {
        let (box, e, tts) = try await Self.loaded()
        let (chunks, err, _) = await Self.drain(tts.speak(Self.request("stall zero", job: 25)))
        #expect(chunks == 0)
        #expect(err as? RemoteEngineError == .stalled(chunksYielded: 0))
        #expect(box.file("cancels.txt").contains("tts-25"))
        await e.stop()
    }

    /// Review [高]: a clause queued behind a slower-than-real-time one (nothing buffered, global
    /// bufferedMs 0) is not judged until it is the oldest open stream, then gets a fresh window.
    @Test func queuedStreamIsNotJudgedBeforeItsTurn() async throws {
        let (box, e, tts) = try await Self.loaded()
        await tts.report(Self.report(buffered: 0))
        let firstOfA = AsyncStream<Void>.makeStream()
        let a = Task { await Self.drain(tts.speak(Self.request("serial slow", job: 31)), firstChunk: { firstOfA.continuation.yield() }) }
        for await _ in firstOfA.stream { break }                           // A holds the engine now
        let queuedAt = ContinuousClock.now
        let (bChunks, bErr, bEnd) = await Self.drain(tts.speak(Self.request("serial next", job: 32)))
        let (aChunks, aErr, aEnd) = await a.value
        #expect(aErr == nil && aChunks == 10)
        #expect(bErr == nil && bChunks == 5)
        #expect(bEnd - queuedAt > .milliseconds(1000))                     // it really waited behind A
        #expect(bEnd >= aEnd)
        #expect(!box.file("cancels.txt").contains("tts-32"))
        #expect(!box.file("cancels.txt").contains("tts-31"))
        #expect(tts.board.openCount == 0)
        await e.stop()
    }

    /// 0c91692 review [3]: a whole clause whose first attempt runs away is retried inside the
    /// engine for > 1 s with no audio and nothing buffered; its progress frames keep it alive.
    @Test func wholeClauseRetryIsNotCut() async throws {
        let (box, e, tts) = try await Self.loaded()
        await tts.report(Self.report(buffered: 0))
        let start = ContinuousClock.now
        let (chunks, err, end) = await Self.drain(tts.speak(Self.request("whole retry", job: 29)))
        #expect(err == nil)
        #expect(chunks == 5)
        #expect(end - start >= .milliseconds(1200))                        // 4 x stallAfter without audio
        #expect(!box.file("cancels.txt").contains("tts-29"))
        await e.stop()
    }

    /// 00f65f3 review [中]: a floor pause (or a buffer at the render horizon) for 3 s with nothing
    /// drainable parks the engine on purpose: the clause is neither cut nor the engine killed.
    @Test(arguments: [true, false]) func legalHoldIsNotAStall(paused: Bool) async throws {
        let (box, e, tts) = try await Self.loaded()
        // one horizon for both sides: the engine's --horizon-ms and the stall rule
        let cfg = await e.config
        #expect(tts.stall.horizonMs == cfg.horizonMs)
        let args = cfg.arguments
        #expect(args.firstIndex(of: "--horizon-ms").map { args[$0 + 1] } == String(cfg.horizonMs))
        let done = Mutex(false)
        let refresh = Task {
            while !Task.isCancelled, !done.withLock({ $0 }) {
                await tts.report(paused ? Self.report(buffered: 300, paused: true) : Self.report(buffered: 1600))
                tts.noteDrainable(paused ? 0 : 200)                         // at the horizon: playing
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        let start = ContinuousClock.now
        let (chunks, err, end) = await Self.drain(tts.speak(Self.request("parked", job: 33)))
        done.withLock { $0 = true }
        refresh.cancel()
        #expect(err == nil)
        #expect(chunks == 5)
        #expect(end - start >= .seconds(3))                                 // 10 x stallAfter, 3 x hangAfter
        #expect(!box.file("cancels.txt").contains("tts-33"))
        #expect(EngineHostTests.isReady(await e.status))
        #expect(box.launches.count == 1)
        await e.stop()
    }

    /// 00f65f3 re-review [medium]: a later clause C reached the ClauseQueue first and fills the buffer
    /// to the horizon, but cannot play before the head A (queue order ≠ engine order): nothing
    /// drains. That is not a legal hold; A, which gets no chunks, is still judged a stall.
    @Test func fullButNotDrainingBufferIsNotAHold() async throws {
        let (_, e, tts) = try await Self.loaded()
        let horizon = tts.stall.horizonMs
        let refresh = Task {
            while !Task.isCancelled {
                await tts.report(Self.report(buffered: horizon + 600))     // C, held behind A
                tts.noteDrainable(0)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        let start = ContinuousClock.now
        let (_, err, end) = await Self.drain(tts.speak(Self.request("stall please", job: 37)))
        refresh.cancel()
        #expect(err as? RemoteEngineError == .stalled(chunksYielded: 1))
        #expect(end - start < .seconds(2))
        await e.stop()
    }

    /// 00f65f3 review [低] H1: three clauses sent at once reach the engine in reverse order (the fake
    /// numbers "order 3" first and renders 3, 2, 1, each slower than real time). With the board in
    /// engine order none of them is judged a stall while it waits.
    @Test func engineOrderDecidesWhoIsJudged() async throws {
        let (box, e, tts) = try await Self.loaded()
        await tts.report(Self.report(buffered: 0))
        let streams = (1...3).map { n in tts.speak(Self.request("order \(n)", job: JobID(40 + n))) }
        let results = await withTaskGroup(of: (Int, Int, (any Error)?).self) { g in
            for (i, s) in streams.enumerated() { g.addTask { let r = await Self.drain(s); return (i + 1, r.0, r.1) } }
            var out: [(Int, Int, (any Error)?)] = []
            for await r in g { out.append(r) }
            return out
        }
        for (n, chunks, err) in results {
            #expect(err == nil, "order \(n): \(String(describing: err))")
            #expect(chunks == 6)
        }
        let cancels = box.file("cancels.txt")
        #expect(!cancels.contains("tts-41") && !cancels.contains("tts-42") && !cancels.contains("tts-43"))
        #expect(tts.board.openCount == 0)
        await e.stop()
    }

    /// 00f65f3 review [低] T2: a consumer that stops at the isLast chunk sends no /v1/cancel (gotTail
    /// is set before the yield).
    @Test func stoppingAtTheTailSendsNoCancel() async throws {
        let (box, e, tts) = try await Self.loaded()
        var last = false
        for try await c in tts.speak(Self.request("Thanks, everyone.", job: 34)) where c.isLast {
            last = true
            break
        }
        #expect(last)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!box.file("cancels.txt").contains("tts-34"))
        await e.stop()
    }

    /// Review [中] :194: audio the ClauseQueue holds back (preroll / whole clause) counts in
    /// bufferedMs but is not drainable; with drainable 0 the stall fires although 600 ms are buffered.
    @Test func heldAudioDoesNotHideAStall() async throws {
        let (_, e, tts) = try await Self.loaded()
        let refresh = Task {
            while !Task.isCancelled {
                await tts.report(Self.report(buffered: 600))
                tts.noteDrainable(0)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        let start = ContinuousClock.now
        let (_, err, end) = await Self.drain(tts.speak(Self.request("stall please", job: 26)))
        refresh.cancel()
        #expect(err as? RemoteEngineError == .stalled(chunksYielded: 1))
        #expect(end - start < .seconds(2))
        await e.stop()
    }

    /// Fresh reports of real buffered audio hold the stall; once they stop, it decays and fires.
    @Test func bufferedAudioHoldsTheStallWhileReported() async throws {
        let (_, e, tts) = try await Self.loaded()
        let reporting = Mutex(true)
        let refresh = Task {
            while !Task.isCancelled, reporting.withLock({ $0 }) {
                await tts.report(Self.report(buffered: 600))
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        let ended = Mutex<ContinuousClock.Instant?>(nil)
        let consumer = Task {
            let r = await Self.drain(tts.speak(Self.request("stall please", job: 22)))
            ended.withLock { $0 = r.2 }
            return r
        }
        try await Task.sleep(for: .milliseconds(800))
        #expect(ended.withLock { $0 } == nil)                               // 600 ms buffered, refreshed
        reporting.withLock { $0 = false }
        let stoppedAt = ContinuousClock.now
        let (_, err, end) = await consumer.value
        refresh.cancel()
        #expect(err as? RemoteEngineError == .stalled(chunksYielded: 1))
        #expect(end - stoppedAt >= .milliseconds(450) && end - stoppedAt < .seconds(3))   // ~600 ms decay
        await e.stop()
    }

    /// Review [低] PlayoutReporter:93: one report that is never refreshed (the POST is stuck) does
    /// not hold the stall forever.
    @Test func staleReportDecays() async throws {
        let (_, e, tts) = try await Self.loaded()
        await tts.report(Self.report(buffered: 500))
        let start = ContinuousClock.now
        let (_, err, end) = await Self.drain(tts.speak(Self.request("stall please", job: 27)))
        #expect(err as? RemoteEngineError == .stalled(chunksYielded: 1))
        #expect(end - start >= .milliseconds(450) && end - start < .seconds(2))
        await e.stop()
    }

    /// Review [低] :193: in_long_step on → off: no verdict while it lasts (3 × stallAfter here),
    /// then a stall once it is off. Real time, so only the order is asserted: the window restarts at
    /// the last `true` answer, whose phase against the file write depends on the poll timing, and
    /// the exact `stallAfter`-after-the-step-ended is the pure `longStepRestartsTheWindowUntilItEnds`
    /// / `failedHealthKeepsTheLongStep`. Under load a health call can time out; the generous timeout
    /// and lapse bounds keep that from ending the remembered long step early (main: flaky at :533
    /// in parallel check.sh runs).
    @Test func longStepOffStartsAFreshWindow() async throws {
        var c = Self.fast
        c.healthTimeout = 3
        c.longStepFailedPolls = 1000
        c.hangAfter = .seconds(10)
        let (box, e, tts) = try await Self.loaded(["--long-step"], stall: c)
        let consumer = Task { await Self.drain(tts.speak(Self.request("stall please", job: 23))) }
        try await Task.sleep(for: .milliseconds(900))
        #expect(tts.board.openCount == 1)                                   // still open: exempt
        let offAt = ContinuousClock.now
        try Data().write(to: box.state.appendingPathComponent("long_step_off"))
        let (_, err, end) = await consumer.value
        #expect(err as? RemoteEngineError == .stalled(chunksYielded: 1))
        #expect(end > offAt && end - offAt < .seconds(10))
        await e.stop()
    }

    /// Review [中] :197 + [低·测试] :155: a hung engine stalls the head once; the clause queued behind
    /// it is not cut but fails with the restart (the caller resends it); the restart comes no earlier
    /// than hangAfter after the last chunk, and the status passes through `.restarting`.
    @Test func stallThatLastsIsAHangAndKeepsTheQueue() async throws {
        let (box, e, tts) = try await Self.loaded(["--bad-launches", "1"])
        let firstOfA = AsyncStream<ContinuousClock.Instant>.makeStream()
        let a = Task { await Self.drain(tts.speak(Self.request("stall hang", job: 24)), firstChunk: { firstOfA.continuation.yield(.now) }) }
        var lastChunk = ContinuousClock.now
        for await t in firstOfA.stream { lastChunk = t; break }
        let b = Task { await Self.drain(tts.speak(Self.request("stall zero", job: 28))) }
        let (_, aErr, _) = await a.value
        #expect(aErr as? RemoteEngineError == .stalled(chunksYielded: 1))
        let s = try await EngineHostTests.waitFor(e, timeout: .seconds(6)) { if case .restarting = $0 { true } else { false } }
        #expect(ContinuousClock.now - lastChunk >= .milliseconds(1000))
        guard case .restarting(_, _, let reason) = s else { Issue.record("no restart: \(s)"); return }
        #expect(reason.contains("SPEAK stall"))
        let (bChunks, bErr, _) = await b.value
        #expect(bChunks == 0)
        #expect(bErr != nil)
        if case .stalled? = bErr as? RemoteEngineError { Issue.record("queued clause was cut as a stall") }
        #expect(!box.file("cancels.txt").contains("tts-28"))
        await e.stop()
    }

    /// 00f65f3 review [低] RemoteQwen+Core:228: A stalls without a hang; B's chunk resolves it; then B
    /// hangs. A's hang check wakes first but must not act on B's stall: the restart comes at
    /// B's last chunk + hangAfter, not at A's window + hangAfter.
    @Test func hangCheckBelongsToItsOwnStall() async throws {
        let (_, e, tts) = try await Self.loaded(["--bad-launches", "1"])
        let (_, aErr, _) = await Self.drain(tts.speak(Self.request("stall please", job: 35)))
        #expect(aErr as? RemoteEngineError == .stalled(chunksYielded: 1))
        let firstOfB = AsyncStream<ContinuousClock.Instant>.makeStream()
        let b = Task { await Self.drain(tts.speak(Self.request("stall hang", job: 36)), firstChunk: { firstOfB.continuation.yield(.now) }) }
        var bLast = ContinuousClock.now
        for await t in firstOfB.stream { bLast = t; break }
        let s = try await EngineHostTests.waitFor(e, timeout: .seconds(6)) { if case .restarting = $0 { true } else { false } }
        let restartSeen = ContinuousClock.now
        guard case .restarting(_, _, let reason) = s else { Issue.record("no restart: \(s)"); return }
        #expect(reason.contains("SPEAK stall") && reason.contains("tts-36"))
        #expect(restartSeen - bLast >= .milliseconds(950))                  // B's own clock (hangAfter 1 s)
        let (_, bErr, _) = await b.value
        #expect(bErr as? RemoteEngineError == .stalled(chunksYielded: 1))
        await e.stop()
    }

    @Test func reportCarriesTheWholePlayoutReport() async throws {
        let (box, e, tts) = try await Self.loaded()
        await tts.report(PlayoutReport(job: 9, bufferedMs: 420, underruns: 2, paused: true, tempo: 1.25, epoch: 3, at: 0))
        #expect(tts.playout.report?.bufferedMs == 420)
        await e.stop()
        let line = try #require(box.file("playouts.txt").split(separator: "\n").last)
        let body = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(body["bufferedMs"] as? Int == 420)
        #expect(body["underruns"] as? Int == 2)
        #expect(body["paused"] as? Bool == true)
        #expect(body["tempo"] as? Double == 1.25)
        #expect(body["epoch"] as? Int == 3)
        #expect(body["job"] as? String == "tts-9")
    }
}
