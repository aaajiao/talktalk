import Foundation
import Synchronization
import Testing
import TalkTalkCore
@testable import TalkTalkSession

/// Results are released by the test, so cloud/draft ordering never depends on a short sleep.
private actor DeferredDraftMT: MTEngine {
    nonisolated let id: EngineID
    private(set) var requests: [MTRequest] = []
    private(set) var cancellations: Set<JobID> = []
    private var pending: [JobID: CheckedContinuation<MTResult, Error>] = [:]

    init(_ placement: Placement = .systemService) {
        id = EngineID(name: placement == .network ? "draft-test-cloud" : "draft-test-apple",
                      revision: "1", placement: placement)
    }

    func translate(_ request: MTRequest) async throws -> MTResult {
        try Task.checkCancellation()
        requests.append(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled || cancellations.contains(request.job) {
                    continuation.resume(throwing: CancellationError())
                } else {
                    pending[request.job] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(request.job) }
        }
    }

    func succeed(_ job: JobID, text: String) {
        let now = HostClock.now()
        pending.removeValue(forKey: job)?.resume(returning: MTResult(
            text: text, tokens: 1, reasoningTokens: 0, engine: id,
            hedge: .init(fired: false, winner: id.placement == .network ? .A : .apple, reason: nil, ms: 0),
            timing: .init(received: now, started: now, firstOutput: now, finished: now)))
    }

    func fail(_ job: JobID) {
        pending.removeValue(forKey: job)?.resume(throwing: MTError.cloudUnavailable("testFailure"))
    }

    func isPending(_ job: JobID) -> Bool { pending[job] != nil }
    func cancel(_ job: JobID) {
        cancellations.insert(job)
        pending.removeValue(forKey: job)?.resume(throwing: CancellationError())
    }
    func setContext(_ session: MTSession, glossary: [GlossaryEntry]) async throws {}
}

private final class DraftReuseClock: Sendable {
    private let time = Mutex<HostTime>(10_000_000_000)
    func now() -> HostTime { time.withLock { $0 } }
    func advance(_ milliseconds: Int) { time.withLock { $0 += UInt64(milliseconds) * 1_000_000 } }
}

private actor DraftSecondPass: ClipASREngine {
    nonisolated let id = EngineID(name: "draft-second-pass", revision: "1", placement: .cpu)
    private(set) var calls = 0
    let corrected: String
    init(_ corrected: String) { self.corrected = corrected }
    func transcribe(_ clip: PCMClip16k, hint: Lang, context: String?, job: JobID,
                    priority: Priority, deadline: HostTime?) async throws -> ASRFinal {
        calls += 1
        return ASRFinal(text: corrected, language: hint,
                        timing: .init(received: 0, started: 0, firstOutput: nil, finished: 0))
    }
    func cancel(_ job: JobID) async {}
}

private actor DraftSwitchASR: StreamingASREngine {
    nonisolated let id = EngineID(name: "draft-switch-asr", revision: "1", placement: .cpu)
    private(set) var streams: [FakeStream] = []
    func open(_ lang: Lang, highPriority: Bool) async throws -> any ASRStream {
        let stream = FakeStream()
        streams.append(stream)
        return stream
    }
}

@Suite struct ListenDraftReuseTests {
    private struct Rig: Sendable {
        let pipeline: ListenPipeline
        let sink: Sink
        let clock: DraftReuseClock

        /// Two equal volatile hypotheses commit the whole source through the real segmenter.
        func draft(_ source: String) async {
            await pipeline.onVolatile(source)
            await pipeline.onVolatile(source)
        }

        func final(_ source: String) async {
            clock.advance(1)
            let at = clock.now()
            await pipeline.onFinal(source, range: at...at)
        }
    }

    private func make(apple: DeferredDraftMT, cloud: DeferredDraftMT? = nil, lang: Lang = .en,
                      secondPass: DraftSecondPass? = nil, lookback: Bool = false) throws -> Rig {
        let clock = DraftReuseClock(), sink = Sink(), ingest = AudioIngest()
        var profile = try Fixture.listen(deadlineMs: 30_000)
        profile.draft.minNewWords = 1
        profile.deLookback.enabled = lookback
        profile.secondPassASR = secondPass != nil
        let pipeline = ListenPipeline(lang: lang, profile: profile,
            engines: .init(asr: FakeASR(stream: FakeStream()), apple: apple, primary: cloud, secondPass: secondPass),
            log: EventLog(inMemory: clock.now), ingest: ingest, tickMs: 100_000,
            clock: clock.now, onUpdate: sink.add)
        if secondPass != nil {
            // Covers the clip requested after the clock advances to the final below.
            ingest.push(Array(repeating: 0, count: 32_000), host: clock.now() - 1_000_000_000)
        }
        return Rig(pipeline: pipeline, sink: sink, clock: clock)
    }

    private func request(_ backend: DeferredDraftMT, at index: Int) async throws -> MTRequest {
        try #require(await until { await backend.requests.count > index })
        return await backend.requests[index]
    }

    @Test func exactSourcePendingDraftBecomesAppleFinalWithoutAnotherRequest() async throws {
        let apple = DeferredDraftMT(), rig = try make(apple: apple)
        defer { Task { await rig.pipeline.stop() } }
        try await rig.pipeline.start()
        let source = "The draft already contains this exact sentence."
        await rig.draft(source)
        let draft = try await request(apple, at: 0)
        #expect(!draft.isFinalChunk && draft.text == source)
        await rig.final(source)
        #expect(await rig.pipeline.pendingFinals == 1)
        await apple.succeed(draft.job, text: "复用了同一句草稿。")
        try #require(await until { rig.sink.finals.count == 1 })
        #expect(rig.sink.finals[0].1 == "复用了同一句草稿。" && rig.sink.finals[0].2)
        #expect(await apple.requests.count == 1)
        #expect(rig.sink.drafts.isEmpty)
    }

    @Test(arguments: [false, true])
    func cloudStartsAlongsideReusedDraftAndRemainsPreferred(appleFinishesFirst: Bool) async throws {
        let apple = DeferredDraftMT(), cloud = DeferredDraftMT(.network)
        let rig = try make(apple: apple, cloud: cloud)
        defer { Task { await rig.pipeline.stop() } }
        try await rig.pipeline.start()
        let source = "The cloud still chooses the final translation."
        await rig.draft(source)
        let draft = try await request(apple, at: 0)
        await rig.final(source)
        // Cloud must start before this test releases the still-pending Apple translation.
        let final = try await request(cloud, at: 0)
        #expect(final.isFinalChunk && final.text == source)
        if appleFinishesFirst {
            await apple.succeed(draft.job, text: "Apple 的候选译文。")
            #expect(rig.sink.finals.isEmpty)
        }
        await cloud.succeed(final.job, text: "云端最终译文。")
        try #require(await until { rig.sink.finals.count == 1 })
        #expect(rig.sink.finals[0].1 == "云端最终译文。" && !rig.sink.finals[0].2)
        #expect(await apple.requests.count == 1)
        if !appleFinishesFirst {
            #expect(await until { await apple.cancellations.contains(draft.job) })
            #expect(await !apple.isPending(draft.job))
        }
    }

    @Test func changedFinalSourceCancelsDraftAndTranslatesCorrectedText() async throws {
        let apple = DeferredDraftMT(), rig = try make(apple: apple)
        defer { Task { await rig.pipeline.stop() } }
        try await rig.pipeline.start()
        await rig.draft("The draft has the earlier wording.")
        let draft = try await request(apple, at: 0)
        let corrected = "The final has the corrected wording."
        await rig.final(corrected)
        let final = try await request(apple, at: 1)
        #expect(final.isFinalChunk && final.text == corrected && final.job != draft.job)
        #expect(await until { await apple.cancellations.contains(draft.job) })
        await apple.succeed(final.job, text: "修正后的译文。")
        try #require(await until { rig.sink.finals.count == 1 })
        #expect(rig.sink.finals[0].1 == "修正后的译文。")
    }

    @Test(arguments: [false, true])
    func failedDraftGetsOneFreshFinalAttempt(failsBeforeFinal: Bool) async throws {
        let apple = DeferredDraftMT(), rig = try make(apple: apple)
        defer { Task { await rig.pipeline.stop() } }
        try await rig.pipeline.start()
        let source = "A draft failure must still allow the final translation."
        await rig.draft(source)
        let draft = try await request(apple, at: 0)
        if failsBeforeFinal { await apple.fail(draft.job) }
        await rig.final(source)
        if !failsBeforeFinal { await apple.fail(draft.job) }
        let retry = try await request(apple, at: 1)
        #expect(retry.isFinalChunk && retry.text == source && retry.job != draft.job)
        await apple.succeed(retry.job, text: "最终翻译恢复成功。")
        try #require(await until { rig.sink.finals.count == 1 })
        #expect(rig.sink.finals[0].1 == "最终翻译恢复成功。")
        #expect(await apple.requests.count == 2)
    }

    @Test func nextSentenceDraftCannotCancelThePreviousFinalsAdoptedJob() async throws {
        let apple = DeferredDraftMT(), rig = try make(apple: apple)
        defer { Task { await rig.pipeline.stop() } }
        try await rig.pipeline.start()
        let firstSource = "The first sentence remains pending."
        await rig.draft(firstSource)
        let first = try await request(apple, at: 0)
        await rig.final(firstSource)
        await rig.pipeline.setDraftsPaused(true)
        #expect(await apple.isPending(first.job))
        await rig.pipeline.setDraftsPaused(false)
        let nextSource = "The next sentence now has its own draft."
        await rig.draft(nextSource)
        let next = try await request(apple, at: 1)
        #expect(!next.isFinalChunk && next.text == nextSource)
        #expect(await apple.isPending(first.job))
        #expect(await !apple.cancellations.contains(first.job))
        await apple.succeed(first.job, text: "第一句译文。")
        try #require(await until { rig.sink.finals.count == 1 })
        #expect(rig.sink.finals[0].0 == 1 && rig.sink.finals[0].1 == "第一句译文。")
        await rig.final(nextSource)
        await apple.succeed(next.job, text: "第二句译文。")
        try #require(await until { rig.sink.finals.count == 2 })
        #expect(rig.sink.finals[1].0 == 2 && rig.sink.finals[1].1 == "第二句译文。")
        #expect(await apple.requests.count == 2)
    }

    @Test func stoppingCancelsTheOriginalAdoptedJobAndPublishesNothing() async throws {
        let apple = DeferredDraftMT(), rig = try make(apple: apple)
        defer { Task { await rig.pipeline.stop() } }
        try await rig.pipeline.start()
        let source = "This pending final belongs only to the stopped session."
        await rig.draft(source)
        let draft = try await request(apple, at: 0)
        await rig.final(source)
        await rig.pipeline.stop()
        #expect(await until { await rig.pipeline.pendingFinals == 0 })
        #expect(await apple.cancellations.contains(draft.job))
        #expect(await !apple.isPending(draft.job))
        await apple.succeed(draft.job, text: "迟到的旧译文。")
        #expect(rig.sink.finals.isEmpty)
        #expect(await apple.requests.count == 1)
    }

    @Test func secondPassChangedSourceDoesNotReuseTheOriginalDraft() async throws {
        let corrected = "Second pass corrected the source sentence."
        let secondPass = DraftSecondPass(corrected), apple = DeferredDraftMT()
        let rig = try make(apple: apple, secondPass: secondPass)
        defer { Task { await rig.pipeline.stop() } }
        try await rig.pipeline.start()
        let original = "The first recognizer used different words."
        await rig.draft(original)
        let draft = try await request(apple, at: 0)
        rig.clock.advance(500)
        await rig.final(original)
        let final = try await request(apple, at: 1)
        #expect(await secondPass.calls == 1)
        #expect(final.isFinalChunk && final.text == corrected)
        #expect(await until { await apple.cancellations.contains(draft.job) })
        await apple.succeed(final.job, text: "二次识别后的译文。")
        try #require(await until { rig.sink.finals.count == 1 })
        #expect(rig.sink.items.contains(.final(sentence: 1, text: "二次识别后的译文。", source: corrected,
                                             approx: true, numberWarning: false)))
    }

    @Test func germanLookbackTranslatesCombinedSourceInsteadOfFragmentDraft() async throws {
        let apple = DeferredDraftMT(), rig = try make(apple: apple, lang: .de, lookback: true)
        defer { Task { await rig.pipeline.stop() } }
        try await rig.pipeline.start()
        await rig.final("Wir fangen morgen.")
        let first = try await request(apple, at: 0)
        await apple.succeed(first.job, text: "我们明天开始。")
        try #require(await until { rig.sink.finals.count == 1 })
        rig.clock.advance(100)
        await rig.draft("an.")
        let fragment = try await request(apple, at: 1)
        #expect(!fragment.isFinalChunk && fragment.text == "an.")
        await rig.final("an.")
        let correction = try await request(apple, at: 2)
        #expect(correction.isFinalChunk && correction.text == "Wir fangen morgen an.")
        #expect(await until { await apple.cancellations.contains(fragment.job) })
        await apple.succeed(correction.job, text: "拼接后的完整译文。")
        try #require(await until { rig.sink.finals.count == 2 })
        #expect(rig.sink.finals[1].0 == 1 && rig.sink.finals[1].1 == "拼接后的完整译文。")
        #expect(rig.sink.items.contains(.dropped(sentence: 2)))
    }

    @Test @MainActor func languageSwitchCancelsAdoptedDraftAndKeepsTheNewDirectionIndependent() async throws {
        let apple = DeferredDraftMT(), asr = DraftSwitchASR(), sink = Sink()
        var profile = try PolicyProfile.load(from: Fixture.repoRoot.appendingPathComponent("Resources/PolicyProfile.default.json"))
        profile.listen.finalize.silenceMs = ["en": 60_000, "de": 60_000, "zh": 60_000]
        let session = MeetingSession(profile: profile, makeEngines: { _, _, _ in
            .init(asr: asr, apple: apple, primary: nil)
        }, onSubtitle: sink.add)
        defer { Task { await session.stop() } }
        try await session.startListenForTesting(lang: .en, target: .zh)
        let old = await asr.streams[0]
        let source = "The same source must not share a translation across directions."
        old.volatile(source)
        // The fake ASR keeps only its newest volatile event; allow the first to be consumed.
        try #require(await until { @Sendable in sink.items.contains(.source(source)) })
        old.volatile(source)
        let oldDraft = try await request(apple, at: 0)
        #expect(oldDraft.session == .listenEnZh && !oldDraft.isFinalChunk)
        old.final(source)
        try #require(await until { @Sendable in await MainActor.run {
            session.eventLog?.recorded.contains { $0["ev"] as? String == "listen.sentence" } == true
        } })
        try await session.switchListenDirection(source: .de, target: .en)
        #expect(await apple.cancellations.contains(oldDraft.job))
        let fresh = await asr.streams[1]
        fresh.final(source)
        let newFinal = try await request(apple, at: 1)
        #expect(newFinal.isFinalChunk && newFinal.session == .listenDeEn && newFinal.job != oldDraft.job)
        await apple.succeed(oldDraft.job, text: "旧方向译文。")
        await apple.succeed(newFinal.job, text: "Only the new direction may finish.")
        try #require(await until { @Sendable in sink.finals.count == 1 })
        #expect(sink.finals[0].1 == "Only the new direction may finish.")
        #expect(await apple.requests.count == 2)
    }
}
