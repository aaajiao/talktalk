import Foundation
import Synchronization
import Testing
@testable import TalkTalkCore
@testable import TalkTalkEngineHost

private actor StreamingClipFake: ClipASREngine {
    struct Call: Sendable { let clip: PCMClip16k; let job: JobID; let priority: Priority }
    nonisolated let id = EngineID(name: "qwen-asr-fake", revision: "1", placement: .cpu)
    var calls: [Call] = []
    var pinned: [String?] = []
    var cancelled: [JobID] = []
    var active = 0, peak = 0
    let failFrom: Int?
    let lateAfterFirst: Duration?
    let expiring: Set<Int>
    let readings: [String]
    init(failFrom: Int? = nil, lateAfterFirst: Duration? = nil, expiring: Set<Int> = [], readings: [String] = []) {
        self.failFrom = failFrom; self.lateAfterFirst = lateAfterFirst; self.expiring = expiring; self.readings = readings
    }
    enum Failure: Error { case unavailable }
    func transcribe(_ clip: PCMClip16k, hint: Lang, context: String?, pinnedText: String?, job: JobID,
                    priority: Priority, deadline: HostTime?) async throws -> ASRFinal {
        pinned.append(pinnedText)
        return try await transcribe(clip, hint: hint, context: context, job: job, priority: priority, deadline: deadline)
    }
    func transcribe(_ clip: PCMClip16k, hint: Lang, context: String?, job: JobID,
                    priority: Priority, deadline: HostTime?) async throws -> ASRFinal {
        calls.append(.init(clip: clip, job: job, priority: priority))
        let number = calls.count
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        if let failFrom, number >= failFrom { throw Failure.unavailable }
        if expiring.contains(number) { throw EngineAPIError.http(status: 409, code: "expired", message: "missed deadline") }
        if number > 1, let delay = lateAfterFirst {
            // Deliberately ignores the caller's cancellation and deadline, to exercise the
            // adapter's final fence rather than RemoteQwenASR's already-tested deadline.
            await Task.detached { try? await Task.sleep(for: delay) }.value
        }
        return .init(text: number <= readings.count ? readings[number - 1] : "words \(number)", language: hint,
                     timing: .init(received: 0, started: 0, firstOutput: 0, finished: 0))
    }
    func cancel(_ job: JobID) async { cancelled.append(job) }
}

private final class StreamingFallbackFake: ASRStream, StreamingASREngine, Sendable {
    let id = EngineID(name: "apple-speech-fake", revision: "1", placement: .cpu)
    let volatileEvents: AsyncStream<ASREvent>
    let finalEvents: AsyncStream<ASREvent>
    let vol: AsyncStream<ASREvent>.Continuation
    let fin: AsyncStream<ASREvent>.Continuation
    let fed = Mutex<[(at: HostTime, samples: Int)]>([])
    let opens = Mutex(0), closes = Mutex(0), cancels = Mutex(0)
    let openGate = AsyncStream<Void>.makeStream(), cancelGate = AsyncStream<Void>.makeStream()
    let blockOpen: Bool, blockCancel: Bool
    init(blockOpen: Bool = false, blockCancel: Bool = false) {
        self.blockOpen = blockOpen; self.blockCancel = blockCancel
        (volatileEvents, vol) = AsyncStream.makeStream()
        (finalEvents, fin) = AsyncStream.makeStream()
    }
    func open(_ lang: Lang, highPriority: Bool) async throws -> any ASRStream {
        opens.withLock { $0 += 1 }
        if blockOpen {
            let gate = openGate.stream
            await Task.detached { for await _ in gate { break } }.value
        }
        return self
    }
    func feed(_ frames: UnsafeBufferPointer<Int16>, at: HostTime) { fed.withLock { $0.append((at, frames.count)) } }
    func finalize(through: HostTime) async {}
    func close() async { closes.withLock { $0 += 1 }; vol.finish(); fin.finish() }
    func cancel() async {
        cancels.withLock { $0 += 1 }
        if blockCancel { for await _ in cancelGate.stream { break } }
        vol.finish(); fin.finish()
    }
}

struct QwenStreamingASRTests {
    private var config: QwenStreamConfiguration {
        .init(cadenceFrames: 1600, segmentFrames: 6400, bufferFrames: 12800,
              requestNs: 300_000_000, finalizeNs: 400_000_000)
    }
    private func feed(_ stream: any ASRStream, at: HostTime, count: Int = 1600) {
        [Int16](repeating: 1000, count: count).withUnsafeBufferPointer { stream.feed($0, at: at) }
    }
    private func until(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await predicate()
    }

    @Test func fasterCadenceKeepsTheOneSecondSentencePauseAllowance() {
        let fast = QwenStreamingASR(primary: StreamingClipFake(failFrom: 1), fallback: StreamingFallbackFake(),
                                    configuration: .init(cadenceFrames: 8_000))
        #expect(fast.partialUpdateIntervalMs == 1000)
        let standard = QwenStreamingASR(engine: nil, fallback: StreamingFallbackFake())
        #expect(standard.partialUpdateIntervalMs == 1000)
    }

    @Test func discardForwardsCancellationAndConcurrentCallersWaitForRelease() async throws {
        let primary = StreamingClipFake(failFrom: 1), fallback = StreamingFallbackFake(blockCancel: true)
        let stream = try await QwenStreamingASR(primary: primary, fallback: fallback, configuration: config)
            .open(.en, highPriority: false)
        feed(stream, at: 1_000_000_000)
        #expect(await until { fallback.fed.withLock { !$0.isEmpty } })
        let finished = Mutex(0)
        let first = Task { await stream.cancel(); finished.withLock { $0 += 1 } }
        #expect(await until { fallback.cancels.withLock { $0 } == 1 })
        let second = Task { await stream.cancel(); finished.withLock { $0 += 1 } }
        try await Task.sleep(for: .milliseconds(30))
        #expect(finished.withLock { $0 } == 0)
        fallback.cancelGate.continuation.finish()
        await first.value; await second.value
        #expect(finished.withLock { $0 } == 2)
        #expect(fallback.cancels.withLock { $0 } == 1)
        #expect(fallback.closes.withLock { $0 } == 0)
    }

    @Test func discardWaitsForAnObsoleteFallbackOpenToReleaseItsRecognizer() async throws {
        let primary = StreamingClipFake(failFrom: 1), fallback = StreamingFallbackFake(blockOpen: true)
        let selected = Mutex<[EngineID]>([])
        let stream = try await QwenStreamingASR(primary: primary, fallback: fallback, configuration: config,
            onEngine: { engine in selected.withLock { $0.append(engine) } }).open(.en, highPriority: false)
        feed(stream, at: 1_000_000_000)
        #expect(await until { fallback.opens.withLock { $0 } == 1 })
        let finished = Mutex(false)
        let cancel = Task { await stream.cancel(); finished.withLock { $0 = true } }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!finished.withLock { $0 })
        fallback.openGate.continuation.yield()
        await cancel.value
        #expect(fallback.cancels.withLock { $0 } == 1)
        #expect(fallback.closes.withLock { $0 } == 0)
        #expect(selected.withLock { $0 } == [primary.id])
    }

    @Test func cumulativeWindowsFinalizeAtHostBoundaryAndNeverOverlapJobs() async throws {
        let primary = StreamingClipFake(), fallback = StreamingFallbackFake()
        let stream = try await QwenStreamingASR(primary: primary, fallback: fallback, configuration: config).open(.en, highPriority: false)
        let finals = Mutex<[ASREvent]>([])
        let reader = Task { for await event in stream.finalEvents { finals.withLock { $0.append(event) } } }
        let start: HostTime = 1_000_000_000
        feed(stream, at: start)
        #expect(await until { await primary.calls.count == 1 })
        try await Task.sleep(for: .milliseconds(20))
        #expect(await primary.calls.count == 1) // no new audio, no re-decoding
        feed(stream, at: start + 100_000_017)
        #expect(await until { await primary.calls.count == 2 })
        let cut = start + 150_000_017
        await stream.finalize(through: cut)
        #expect(await until { finals.withLock { !$0.isEmpty } })
        if case .final(_, let range) = finals.withLock({ $0[0] }) {
            #expect(range == start...cut)
        } else { Issue.record("expected final") }
        feed(stream, at: start + 200_000_017)
        #expect(await until { await primary.calls.last?.clip.start == cut })
        feed(stream, at: start + 300_000_017, count: 12_000)
        #expect(await until { await primary.calls.count >= 5 })
        await stream.close(); await reader.value
        let calls = await primary.calls
        #expect(calls.allSatisfy { $0.clip.samples.count <= 6400 && $0.priority == .p2Listen })
        #expect(Set(calls.map(\.job)).count == calls.count)
        #expect(await primary.peak == 1)
        #expect(fallback.opens.withLock { $0 } == 0)
    }

    @Test func finalizeTimeoutKeepsKnownHypothesisAndSuppressesLateFinal() async throws {
        let primary = StreamingClipFake(lateAfterFirst: .milliseconds(160)), fallback = StreamingFallbackFake()
        var short = config; short.finalizeNs = 40_000_000
        let stream = try await QwenStreamingASR(primary: primary, fallback: fallback, configuration: short).open(.de, highPriority: false)
        let finals = Mutex<[ASREvent]>([]), volatile = Mutex<[ASREvent]>([])
        let readers = [Task { for await event in stream.finalEvents { finals.withLock { $0.append(event) } } },
                       Task { for await event in stream.volatileEvents { volatile.withLock { $0.append(event) } } }]
        feed(stream, at: 2_000_000_000)
        #expect(await until { volatile.withLock { !$0.isEmpty } })
        await stream.finalize(through: 2_100_000_000)
        #expect(await until { finals.withLock { !$0.isEmpty } })
        #expect(finals.withLock { $0 } == [.final("words 1", range: 2_000_000_000...2_100_000_000)])
        try await Task.sleep(for: .milliseconds(190))
        #expect(finals.withLock { $0.count } == 1)
        #expect(await primary.peak == 1)
        #expect(await primary.cancelled.contains(2))
        await stream.close(); for reader in readers { await reader.value }
    }

    @Test func requestFailureSwitchesToAppleAndReplaysOnlyUnfinalizedAudio() async throws {
        let primary = StreamingClipFake(failFrom: 3), fallback = StreamingFallbackFake()
        let selected = Mutex<[EngineID]>([])
        let stream = try await QwenStreamingASR(primary: primary, fallback: fallback, configuration: config,
            onEngine: { engine in selected.withLock { $0.append(engine) } }).open(.en, highPriority: false)
        let finals = Mutex<[ASREvent]>([]), volatile = Mutex<[ASREvent]>([])
        let readers = [Task { for await event in stream.finalEvents { finals.withLock { $0.append(event) } } },
                       Task { for await event in stream.volatileEvents { volatile.withLock { $0.append(event) } } }]
        feed(stream, at: 3_000_000_000)
        #expect(await until { volatile.withLock { !$0.isEmpty } })
        await stream.finalize(through: 3_100_000_000)
        #expect(await until { finals.withLock { $0.count == 1 } })
        feed(stream, at: 3_100_000_000)
        #expect(await until { fallback.fed.withLock { !$0.isEmpty } })
        #expect(fallback.fed.withLock { $0.map(\.at) } == [3_100_000_000])
        #expect(selected.withLock { $0.map(\.name) } == [primary.id.name, fallback.id.name])
        fallback.fin.yield(.final("backup words", range: 3_100_000_000...3_200_000_000))
        #expect(await until { finals.withLock { $0.count == 2 } })
        await stream.close(); for reader in readers { await reader.value }
        #expect(fallback.closes.withLock { $0 } == 1)
    }

    private func finalLog(_ events: borrowing Mutex<[ASREvent]>) -> [(text: String, through: HostTime)] {
        events.withLock { $0.compactMap { if case .final(let text, let range) = $0 { (text, range.upperBound) } else { nil } } }
    }

    @Test func expiredDecodeKeepsQwenAndResumesAfterWhatItAlreadyRead() async throws {
        let primary = StreamingClipFake(expiring: [2, 3, 5]), fallback = StreamingFallbackFake()
        let stream = try await QwenStreamingASR(primary: primary, fallback: fallback, configuration: config).open(.en, highPriority: false)
        let finals = Mutex<[ASREvent]>([]), volatile = Mutex<[ASREvent]>([])
        let readers = [Task { for await event in stream.finalEvents { finals.withLock { $0.append(event) } } },
                       Task { for await event in stream.volatileEvents { volatile.withLock { $0.append(event) } } }]
        feed(stream, at: 3_000_000_000)
        #expect(await until { volatile.withLock { $0.count == 1 } })
        feed(stream, at: 3_100_000_000)   // 2 expires and commits 1; 3 retries the tail and expires too
        #expect(await until { await primary.calls.count == 3 })
        #expect(await until { finalLog(finals).count == 1 })
        feed(stream, at: 3_200_000_000)   // 4 succeeds, which clears the run of expiries
        #expect(await until { volatile.withLock { $0.count == 2 } })
        feed(stream, at: 3_300_000_000)   // 5 expires; two more in a row would still be tolerated
        #expect(await until { finalLog(finals).count == 2 })
        let starts = await primary.calls.map(\.clip.start)
        #expect(Array(starts[2...4]) == [3_100_000_000, 3_100_000_000, 3_100_000_000])
        #expect(finalLog(finals).map(\.text) == ["words 1", "words 4"])
        #expect(finalLog(finals).map(\.through) == [3_100_000_000, 3_300_000_000])
        #expect(fallback.opens.withLock { $0 } == 0)
        await stream.close(); for reader in readers { await reader.value }
    }

    @Test func expiredFinalKeepsTheAudioTheLastDecodeDidNotReach() async throws {
        let primary = StreamingClipFake(expiring: [2]), fallback = StreamingFallbackFake()
        let stream = try await QwenStreamingASR(primary: primary, fallback: fallback, configuration: config).open(.en, highPriority: false)
        let finals = Mutex<[ASREvent]>([]), volatile = Mutex<[ASREvent]>([])
        let readers = [Task { for await event in stream.finalEvents { finals.withLock { $0.append(event) } } },
                       Task { for await event in stream.volatileEvents { volatile.withLock { $0.append(event) } } }]
        feed(stream, at: 3_000_000_000)
        #expect(await until { volatile.withLock { $0.count == 1 } })
        feed(stream, at: 3_100_000_000, count: 800)
        await stream.finalize(through: 3_150_000_000)
        #expect(await until { finalLog(finals).count == 1 })
        #expect(finalLog(finals)[0].text == "words 1" && finalLog(finals)[0].through == 3_100_000_000)
        feed(stream, at: 3_150_000_000, count: 800)
        #expect(await until { await primary.calls.count == 3 })
        #expect(await primary.calls[2].clip.start == 3_100_000_000)
        #expect(fallback.opens.withLock { $0 } == 0)
        await stream.close(); for reader in readers { await reader.value }
    }

    private var earlyConfig: QwenStreamConfiguration {
        var early = config; early.earlySentences = true; return early
    }

    private let spoken = [
        "Nobody was at fault. The system allowed.",
        "Nobody was at fault. The system allowed it.",
        "Nobody was at fault. The system allowed it to.",
    ]

    @Test func earlySentenceLeavesTheAudioWindowWhereItWas() async throws {
        let primary = StreamingClipFake(readings: spoken), fallback = StreamingFallbackFake()
        let stream = try await QwenStreamingASR(primary: primary, fallback: fallback, configuration: earlyConfig).open(.en, highPriority: false)
        let finals = Mutex<[ASREvent]>([]), volatile = Mutex<[ASREvent]>([])
        let readers = [Task { for await event in stream.finalEvents { finals.withLock { $0.append(event) } } },
                       Task { for await event in stream.volatileEvents { volatile.withLock { $0.append(event) } } }]
        let start: HostTime = 4_000_000_000
        for index in 0..<3 {
            feed(stream, at: start + UInt64(index) * 100_000_000)
            #expect(await until { await primary.calls.count == index + 1 })
            #expect(await until { await primary.active == 0 })
        }
        #expect(await until { finalLog(finals).count == 1 })
        #expect(finalLog(finals)[0].text == "Nobody was at fault.")
        #expect(finalLog(finals)[0].through == start + 200_000_000 - 1)
        #expect(await until { volatile.withLock { $0.last == .volatile("The system allowed it to.", through: start + 300_000_000) } })
        #expect(await primary.calls.allSatisfy { $0.clip.start == start })
        await stream.close(); for reader in readers { await reader.value }
    }

    @Test func readingsContinueFromReleasedTextUntilTheWindowMoves() async throws {
        let readings = spoken + ["Nobody was at fault. The system allowed it to happen. It took a."]
        let primary = StreamingClipFake(readings: readings), fallback = StreamingFallbackFake()
        let stream = try await QwenStreamingASR(primary: primary, fallback: fallback, configuration: earlyConfig).open(.en, highPriority: false)
        let start: HostTime = 5_500_000_000
        for index in 0..<5 {
            feed(stream, at: start + UInt64(index) * 100_000_000)
            #expect(await until { await primary.calls.count == index + 1 })
            #expect(await until { await primary.active == 0 })
        }
        let released = "Nobody was at fault."
        #expect(await primary.pinned == [nil, nil, released, released, nil])
        await stream.close()
    }

    @Test func expiryAfterAWordlessReadingStillRestartsTheWindow() async throws {
        let primary = StreamingClipFake(expiring: [2], readings: [""]), fallback = StreamingFallbackFake()
        let stream = try await QwenStreamingASR(primary: primary, fallback: fallback, configuration: earlyConfig).open(.en, highPriority: false)
        let start: HostTime = 5_800_000_000
        feed(stream, at: start)
        #expect(await until { await primary.calls.count == 1 })
        #expect(await until { await primary.active == 0 })
        feed(stream, at: start + 100_000_000)
        #expect(await until { await primary.calls.count == 3 })
        #expect(await primary.calls[2].clip.start == start + 100_000_000)
        #expect(fallback.opens.withLock { $0 } == 0)
        await stream.close()
    }

    @Test func aLongRunWithNoSentenceEndCutsTheWindowEarly() async throws {
        var long = earlyConfig
        long.longRunWords = 4
        let primary = StreamingClipFake(readings: ["one two three four.", "one two three four five."])
        let stream = try await QwenStreamingASR(primary: primary, fallback: StreamingFallbackFake(), configuration: long)
            .open(.en, highPriority: false)
        let finals = Mutex<[ASREvent]>([])
        let reader = Task { for await event in stream.finalEvents { finals.withLock { $0.append(event) } } }
        feed(stream, at: 6_000_000_000)
        #expect(await until { finalLog(finals).count == 1 })
        #expect(finalLog(finals).map(\.text) == ["one two three four five"])
        #expect(await primary.calls.count == 2)
        await stream.close(); await reader.value
    }

    @Test func forcedCutDropsTheTailPeriodAndKeepsTheFinalAfterTheEarlySentence() async throws {
        let readings = spoken + ["Nobody was at fault. The system allowed it to happen. It took a."]
        let primary = StreamingClipFake(readings: readings), fallback = StreamingFallbackFake()
        let stream = try await QwenStreamingASR(primary: primary, fallback: fallback, configuration: earlyConfig).open(.en, highPriority: false)
        let finals = Mutex<[ASREvent]>([])
        let reader = Task { for await event in stream.finalEvents { finals.withLock { $0.append(event) } } }
        let start: HostTime = 5_000_000_000
        for index in 0..<4 {
            feed(stream, at: start + UInt64(index) * 100_000_000)
            #expect(await until { await primary.calls.count == min(index + 1, 4) })
            #expect(await until { await primary.active == 0 })
        }
        #expect(await until { finalLog(finals).count == 2 })
        #expect(finalLog(finals).map(\.text) == ["Nobody was at fault.", "The system allowed it to happen. It took a"])
        #expect(finalLog(finals)[1].through == start + 400_000_000)
        await stream.close(); await reader.value
    }

    @Test func aRequestedFinalThroughTheLastReadingStillPassesTheEarlySentence() async throws {
        let readings = spoken + ["Nobody was at fault. The system allowed it to happen."]
        let primary = StreamingClipFake(readings: readings), fallback = StreamingFallbackFake()
        let stream = try await QwenStreamingASR(primary: primary, fallback: fallback, configuration: earlyConfig).open(.en, highPriority: false)
        let finals = Mutex<[ASREvent]>([])
        let reader = Task { for await event in stream.finalEvents { finals.withLock { $0.append(event) } } }
        let start: HostTime = 6_000_000_000
        for index in 0..<3 {
            feed(stream, at: start + UInt64(index) * 100_000_000)
            #expect(await until { await primary.calls.count == index + 1 })
            #expect(await until { await primary.active == 0 })
        }
        #expect(await until { finalLog(finals).count == 1 })
        let reading = start + 300_000_000
        await stream.finalize(through: reading)
        #expect(await until { finalLog(finals).count == 2 })
        #expect(finalLog(finals)[1].text == "The system allowed it to happen.")
        #expect(finalLog(finals)[0].through < finalLog(finals)[1].through)
        await stream.close(); await reader.value
    }

    private func releaseFirstSentence(_ stream: any ASRStream, _ primary: StreamingClipFake,
                                      _ finals: borrowing Mutex<[ASREvent]>, start: HostTime) async {
        for index in 0..<2 {
            feed(stream, at: start + UInt64(index) * 100_000_000)
            #expect(await until { await primary.calls.count == index + 1 })
            #expect(await until { await primary.active == 0 })
        }
        #expect(await until { finalLog(finals).count == 1 })
    }

    @Test func aFinalAtTheReleasingReadingPassesTheEarlySentencesStamp() async throws {
        let primary = StreamingClipFake(readings: spoken), fallback = StreamingFallbackFake()
        let stream = try await QwenStreamingASR(primary: primary, fallback: fallback, configuration: earlyConfig).open(.en, highPriority: false)
        let finals = Mutex<[ASREvent]>([])
        let reader = Task { for await event in stream.finalEvents { finals.withLock { $0.append(event) } } }
        let start: HostTime = 9_000_000_000
        await releaseFirstSentence(stream, primary, finals, start: start)
        await stream.finalize(through: start + 200_000_000)
        #expect(await until { finalLog(finals).count == 2 })
        #expect(finalLog(finals)[0].through < finalLog(finals)[1].through)
        await stream.close(); await reader.value
    }

    @Test func aFinalBeforeTheStampStillPassesAndKeepsTheRealCut() async throws {
        let primary = StreamingClipFake(readings: spoken), fallback = StreamingFallbackFake()
        let stream = try await QwenStreamingASR(primary: primary, fallback: fallback, configuration: earlyConfig).open(.en, highPriority: false)
        let finals = Mutex<[ASREvent]>([])
        let reader = Task { for await event in stream.finalEvents { finals.withLock { $0.append(event) } } }
        let start: HostTime = 10_000_000_000
        await releaseFirstSentence(stream, primary, finals, start: start)
        let cut = start + 150_000_000
        await stream.finalize(through: cut)
        #expect(await until { finalLog(finals).count == 2 })
        #expect(finalLog(finals)[1].through == start + 200_000_000 - 1 + 1)
        feed(stream, at: start + 200_000_000)
        #expect(await until { await primary.calls.last?.clip.start == cut })
        await stream.close(); await reader.value
    }

    @Test func aFinalLISTENAsksForDuringAForcedCutKeepsItsPeriod() async throws {
        let primary = StreamingClipFake(lateAfterFirst: .milliseconds(100), readings: ["One two.", "It took a long time."])
        let fallback = StreamingFallbackFake()
        let stream = try await QwenStreamingASR(primary: primary, fallback: fallback, configuration: earlyConfig).open(.en, highPriority: false)
        let finals = Mutex<[ASREvent]>([])
        let reader = Task { for await event in stream.finalEvents { finals.withLock { $0.append(event) } } }
        let start: HostTime = 11_000_000_000
        feed(stream, at: start)
        #expect(await until { await primary.calls.count == 1 })
        #expect(await until { await primary.active == 0 })
        feed(stream, at: start + 100_000_000, count: 4800)
        #expect(await until { await primary.calls.count == 2 })
        await stream.finalize(through: start + 400_000_000)
        #expect(await until { finalLog(finals).count == 1 })
        #expect(finalLog(finals)[0].text == "It took a long time.")
        await stream.close(); await reader.value
    }

    @Test func switchingToAppleDoesNotRepeatReleasedSentences() async throws {
        let primary = StreamingClipFake(failFrom: 4, readings: spoken), fallback = StreamingFallbackFake()
        var roomy = earlyConfig; roomy.segmentFrames = 12_800; roomy.bufferFrames = 16_000
        let stream = try await QwenStreamingASR(primary: primary, fallback: fallback, configuration: roomy).open(.en, highPriority: false)
        let finals = Mutex<[ASREvent]>([])
        let reader = Task { for await event in stream.finalEvents { finals.withLock { $0.append(event) } } }
        let start: HostTime = 7_000_000_000
        for index in 0..<4 {
            feed(stream, at: start + UInt64(index) * 100_000_000)
            #expect(await until { await primary.calls.count == index + 1 })
            #expect(await until { await primary.active == 0 })
        }
        #expect(await until { fallback.fed.withLock { !$0.isEmpty } })
        #expect(fallback.fed.withLock { $0.map(\.at) } == [start + 300_000_000])
        #expect(await until { finalLog(finals).map(\.text) == ["Nobody was at fault.", "The system allowed it to"] })
        await stream.close(); await reader.value
    }

    @Test func withoutEarlySentencesEveryReadingAndPeriodPassThroughUnchanged() async throws {
        let readings = spoken + ["Nobody was at fault. The system allowed it to happen. It took a."]
        let primary = StreamingClipFake(readings: readings), fallback = StreamingFallbackFake()
        let stream = try await QwenStreamingASR(primary: primary, fallback: fallback, configuration: config).open(.en, highPriority: false)
        let finals = Mutex<[ASREvent]>([]), volatile = Mutex<[ASREvent]>([])
        let readers = [Task { for await event in stream.finalEvents { finals.withLock { $0.append(event) } } },
                       Task { for await event in stream.volatileEvents { volatile.withLock { $0.append(event) } } }]
        let start: HostTime = 8_000_000_000
        for index in 0..<4 {
            feed(stream, at: start + UInt64(index) * 100_000_000)
            #expect(await until { await primary.calls.count == min(index + 1, 4) })
            #expect(await until { await primary.active == 0 })
            if index < 3 {
                let expected = ASREvent.volatile(readings[index], through: start + UInt64(index + 1) * 100_000_000)
                #expect(await until { volatile.withLock { $0.last == expected } })
            }
        }
        #expect(await until { finalLog(finals).count == 1 })
        #expect(finalLog(finals)[0].text == readings[3] && finalLog(finals)[0].through == start + 400_000_000)
        await stream.close(); for reader in readers { await reader.value }
        #expect(finalLog(finals).count == 1)
    }

    @Test func repeatedExpiriesStillSwitchToApple() async throws {
        let primary = StreamingClipFake(expiring: [1, 2, 3]), fallback = StreamingFallbackFake()
        let stream = try await QwenStreamingASR(primary: primary, fallback: fallback, configuration: config).open(.en, highPriority: false)
        for index in 0..<3 {
            feed(stream, at: 3_000_000_000 + UInt64(index) * 100_000_000)
            #expect(await until { await primary.calls.count == index + 1 })
        }
        #expect(await until { fallback.opens.withLock { $0 } == 1 })
        await stream.close()
    }
}
