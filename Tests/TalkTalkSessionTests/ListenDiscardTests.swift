import Foundation
import Synchronization
import Testing
import TalkTalkCore
@testable import TalkTalkSession

/// A recognizer whose final-result path can never finish without explicit test release.
/// Cancellation deliberately leaves its event continuations alive to exercise epoch fences.
private final class DiscardStream: ASRStream, Sendable {
    let volatileEvents: AsyncStream<ASREvent>
    let finalEvents: AsyncStream<ASREvent>
    let final: AsyncStream<ASREvent>.Continuation
    let closes = Mutex(0), cancels = Mutex(0)
    let closeGate = AsyncStream<Void>.makeStream()
    let cancelGate = AsyncStream<Void>.makeStream()
    let blockCancel: Bool
    init(blockCancel: Bool = false) {
        self.blockCancel = blockCancel
        (volatileEvents, _) = AsyncStream.makeStream()
        (finalEvents, final) = AsyncStream.makeStream()
    }
    func feed(_ frames: UnsafeBufferPointer<Int16>, at: HostTime) {}
    func finalize(through: HostTime) async {}
    func close() async {
        closes.withLock { $0 += 1 }
        for await _ in closeGate.stream { break }
    }
    func cancel() async {
        cancels.withLock { $0 += 1 }
        if blockCancel { for await _ in cancelGate.stream { break } }
    }
    func lateFinal() {
        let at = HostClock.now()
        final.yield(.final("Obsolete recognition must not be displayed.", range: at...at))
    }
}

private actor DiscardASR: StreamingASREngine {
    nonisolated let id = EngineID(name: "discard-test", revision: "1", placement: .cpu)
    let streams: [DiscardStream]
    let openGate = AsyncStream<Void>.makeStream()
    private(set) var opens = 0
    let blockFirst: Bool, blockSecond: Bool
    init(_ streams: [DiscardStream], blockFirst: Bool = false, blockSecond: Bool = false) {
        self.streams = streams; self.blockFirst = blockFirst; self.blockSecond = blockSecond
    }
    func open(_ lang: Lang, highPriority: Bool) async throws -> any ASRStream {
        let index = opens; opens += 1
        if (blockFirst && index == 0) || (blockSecond && index == 1) {
            for await _ in openGate.stream { break }
        }
        return streams[index]
    }
    func releaseOpen() { openGate.continuation.yield() }
}

private actor TranslationWarmupGate {
    private(set) var entered = false
    private let gate = AsyncStream<Void>.makeStream()
    func prepare() async {
        entered = true
        for await _ in gate.stream { break }
    }
    func release() { gate.continuation.yield() }
}

@MainActor @Suite struct ListenDiscardTests {
    private func session(_ asr: DiscardASR, updates: Sink) throws -> MeetingSession {
        let profile = try PolicyProfile.load(from: Fixture.repoRoot.appendingPathComponent("Resources/PolicyProfile.default.json"))
        return MeetingSession(profile: profile, makeEngines: { _, _, _ in
            .init(asr: asr, apple: nil, primary: nil)
        }, onSubtitle: { updates.add($0) })
    }

    @Test func recognizerAndTranslationPrepareConcurrentlyButBothGateReadiness() async throws {
        let stream = DiscardStream(), asr = DiscardASR([stream], blockFirst: true)
        let warmup = TranslationWarmupGate(), finished = Mutex(false)
        let log = EventLog(inMemory: HostClock.now)
        let pipeline = ListenPipeline(lang: .en, profile: try Fixture.listen(),
            engines: .init(asr: asr, apple: nil, primary: nil,
                           prepareTranslation: { await warmup.prepare() }),
            log: log, onUpdate: { _ in })
        let start = Task { try await pipeline.start(); finished.withLock { $0 = true } }
        #expect(await until(500) { @Sendable in
            let open = await asr.opens, translating = await warmup.entered
            return open == 1 && translating
        })
        #expect(!finished.withLock { $0 })
        #expect(!log.recorded.contains { $0["ev"] as? String == "listen.prepare" })
        await asr.releaseOpen()
        #expect(await until { @Sendable in
            log.recorded.contains { $0["ev"] as? String == "listen.prepare" && $0["stage"] as? String == "asr" }
        })
        #expect(!finished.withLock { $0 })
        #expect(!log.recorded.contains { $0["stage"] as? String == "translation" })
        await warmup.release()
        try await start.value
        #expect(finished.withLock { $0 })
        let stages = log.recorded.filter { $0["ev"] as? String == "listen.prepare" }
        #expect(stages.compactMap { $0["stage"] as? String } == ["asr", "translation"])
        #expect(stages.allSatisfy { ($0["ms"] as? Int ?? -1) >= 0 })
        #expect(stages.allSatisfy { Set($0.keys) == ["ev", "t", "stage", "ms"] })
        await pipeline.stop()
    }

    @Test func stopDuringTranslationPreparationReleasesAlreadyOpenedRecognizer() async throws {
        let stream = DiscardStream(), asr = DiscardASR([stream]), warmup = TranslationWarmupGate()
        let pipeline = ListenPipeline(lang: .en, profile: try Fixture.listen(),
            engines: .init(asr: asr, apple: nil, primary: nil,
                           prepareTranslation: { await warmup.prepare() }),
            log: EventLog(inMemory: HostClock.now), onUpdate: { _ in })
        let start = Task { try await pipeline.start() }
        #expect(await until { @Sendable in
            let open = await asr.opens, translating = await warmup.entered
            return open == 1 && translating
        })
        await pipeline.stop()
        #expect(await until(500) { @Sendable in stream.cancels.withLock { $0 } == 1 })
        await warmup.release()
        do { try await start.value; Issue.record("obsolete start unexpectedly succeeded") }
        catch is CancellationError { }
        #expect(stream.closes.withLock { $0 } == 0)
    }

    @Test func sessionEndDiscardsTailAndRejectsLateRecognition() async throws {
        let stream = DiscardStream(), updates = Sink()
        let session = try session(DiscardASR([stream]), updates: updates)
        try await session.startListenForTesting(lang: .en)
        let finished = Mutex(false)
        let stop = Task { await session.stop(); finished.withLock { $0 = true } }
        #expect(await until(500) { @Sendable in finished.withLock { $0 } })
        // Release even on regression, so a mistaken close() cannot strand the test runner.
        stream.closeGate.continuation.yield()
        await stop.value
        #expect(stream.cancels.withLock { $0 } == 1)
        #expect(stream.closes.withLock { $0 } == 0)
        let before = updates.items
        stream.lateFinal()
        try await Task.sleep(for: .milliseconds(30))
        #expect(updates.items == before)
        #expect(session.state == .idle)
    }

    @Test func concurrentPipelineStopsWaitForTheSameRecognizerRelease() async throws {
        let stream = DiscardStream(blockCancel: true)
        let pipeline = ListenPipeline(lang: .en, profile: try Fixture.listen(),
            engines: .init(asr: DiscardASR([stream]), apple: nil, primary: nil),
            log: EventLog(inMemory: HostClock.now), onUpdate: { _ in })
        try await pipeline.start()
        let finished = Mutex(0)
        let first = Task { await pipeline.stop(); finished.withLock { $0 += 1 } }
        #expect(await until { @Sendable in stream.cancels.withLock { $0 } == 1 })
        let second = Task { await pipeline.stop(); finished.withLock { $0 += 1 } }
        try await Task.sleep(for: .milliseconds(30))
        #expect(finished.withLock { $0 } == 0)
        stream.cancelGate.continuation.yield()
        stream.closeGate.continuation.yield()
        await first.value; await second.value
        #expect(finished.withLock { $0 } == 2)
        #expect(stream.cancels.withLock { $0 } == 1)
    }

    @Test func languageReplacementAndObsoleteOpenBothDiscardWithoutFinalizing() async throws {
        let old = DiscardStream(), obsolete = DiscardStream(), updates = Sink()
        let asr = DiscardASR([old, obsolete], blockSecond: true)
        let session = try session(asr, updates: updates)
        try await session.startListenForTesting(lang: .en)
        let change = Task { try await session.switchListenLanguage(to: .de) }
        #expect(await until(500) { @Sendable in await asr.opens == 2 })
        old.closeGate.continuation.yield()
        #expect(old.cancels.withLock { $0 } == 1)
        old.lateFinal()
        let stop = Task { await session.stop() }
        await Task.yield()
        await asr.releaseOpen()
        _ = await change.result
        obsolete.closeGate.continuation.yield()
        await stop.value
        #expect(obsolete.cancels.withLock { $0 } == 1)
        #expect(old.closes.withLock { $0 } == 0 && obsolete.closes.withLock { $0 } == 0)
        #expect(updates.items.isEmpty)
        #expect(session.state == .idle && session.listenLanguage == nil)
    }
}
