import Foundation
import Synchronization
import Testing
@testable import TalkTalkCore
@testable import TalkTalkEngineHost

private actor StreamingClipFake: ClipASREngine {
    struct Call: Sendable { let clip: PCMClip16k; let job: JobID; let priority: Priority }
    nonisolated let id = EngineID(name: "qwen-asr-fake", revision: "1", placement: .cpu)
    var calls: [Call] = []
    var cancelled: [JobID] = []
    var active = 0, peak = 0
    let failFrom: Int?
    let lateAfterFirst: Duration?
    init(failFrom: Int? = nil, lateAfterFirst: Duration? = nil) {
        self.failFrom = failFrom; self.lateAfterFirst = lateAfterFirst
    }
    enum Failure: Error { case unavailable }
    func transcribe(_ clip: PCMClip16k, hint: Lang, context: String?, job: JobID,
                    priority: Priority, deadline: HostTime?) async throws -> ASRFinal {
        calls.append(.init(clip: clip, job: job, priority: priority))
        let number = calls.count
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        if let failFrom, number >= failFrom { throw Failure.unavailable }
        if number > 1, let delay = lateAfterFirst {
            // Deliberately ignores the caller's cancellation and deadline, to exercise the
            // adapter's final fence rather than RemoteQwenASR's already-tested deadline.
            await Task.detached { try? await Task.sleep(for: delay) }.value
        }
        return .init(text: "words \(number)", language: hint,
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
}
