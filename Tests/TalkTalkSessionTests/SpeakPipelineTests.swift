import Foundation
import Synchronization
import Testing
import TalkTalkAudio
@testable import TalkTalkCore
@testable import TalkTalkSession

private final class SpeakTestPress: SpeakPressAudio, Sendable {
    let clips: AsyncStream<SpeakClip>
    let cc: AsyncStream<SpeakClip>.Continuation
    let preview: AsyncStream<SpeakPreviewFrame>
    let pc: AsyncStream<SpeakPreviewFrame>.Continuation
    init() {
        (clips, cc) = AsyncStream.makeStream()
        (preview, pc) = AsyncStream.makeStream()
    }
    func release(at: HostTime, reason: PushToTalkMachine.ReleaseReason) { cc.finish(); pc.finish() }
    func cancel() { cc.finish(); pc.finish() }
}

private final class SpeakTestMic: SpeakMicSource, Sendable {
    private let latest = Mutex(SpeakTestPress())
    private let floor = Mutex<HostTime?>(nil)
    var press: SpeakTestPress { latest.withLock { $0 } }
    var captureFloor: HostTime? { floor.withLock { $0 } }
    var state: SpeakMicState { .init(capture: .open, physicalMicPassesRule2: true) }
    func beginPress(id: UInt64, keyDownAt: HostTime, passthroughClosedAt: HostTime?) -> (any SpeakPressAudio)? {
        floor.withLock { $0 = passthroughClosedAt }
        let next = SpeakTestPress(); latest.withLock { $0 = next }; return next
    }
}

private final class SpeakTestHost: SpeakPlayoutHost, @unchecked Sendable {
    let ring = RingO(minCapacityFrames: 96_000, maxLeadFrames: 24_000)!
    let queue: ClauseQueue
    init() throws { queue = ClauseQueue(ring: ring, stage: try PlayoutStage()) }
    func beginSession(config: ClauseQueue.Config) async throws -> ClauseQueue { queue }
    func endSession() async {}
    func setEventSink(_ sink: (@Sendable ([ClauseQueue.Event]) -> Void)?) {}
    var isFeedAttached: Bool { true }
    func setFastPump(_ enabled: Bool) {}
}

private final class SpeakTestAnalyzers: Sendable {
    private let counts = Mutex((active: 0, peak: 0))
    func opened() { counts.withLock { $0.active += 1; $0.peak = max($0.peak, $0.active) } }
    func closed() { counts.withLock { $0.active -= 1 } }
    var active: Int { counts.withLock { $0.active } }
    var peak: Int { counts.withLock { $0.peak } }
}

private struct SpeakTestPreviewEngine: StreamingASREngine {
    let id = EngineID(name: "preview-test", revision: "1", placement: .cpu)
    let analyzers: SpeakTestAnalyzers
    func open(_ lang: Lang, highPriority: Bool) async throws -> any ASRStream {
        analyzers.opened()
        // Simulate a framework open that returns a live stream after caller cancellation.
        try? await Task.sleep(for: .milliseconds(80))
        return SpeakTestPreviewStream(analyzers: analyzers)
    }
}

private final class SpeakTestPreviewStream: ASRStream, Sendable {
    let volatileEvents: AsyncStream<ASREvent>
    let finalEvents: AsyncStream<ASREvent>
    private let vc: AsyncStream<ASREvent>.Continuation
    private let fc: AsyncStream<ASREvent>.Continuation
    private let closed = Mutex(false)
    private let analyzers: SpeakTestAnalyzers
    init(analyzers: SpeakTestAnalyzers) {
        self.analyzers = analyzers
        (volatileEvents, vc) = AsyncStream.makeStream()
        (finalEvents, fc) = AsyncStream.makeStream()
    }
    func feed(_ frames: UnsafeBufferPointer<Int16>, at: HostTime) {}
    func emit(_ event: ASREvent) {
        switch event {
        case .volatile: vc.yield(event)
        case .final: fc.yield(event)
        }
    }
    func finalize(through: HostTime) async {}
    func close() async {
        let first = closed.withLock { value in defer { value = true }; return !value }
        if first { analyzers.closed(); vc.finish(); fc.finish() }
    }
}

private struct SpeakTestLivePreview: StreamingASREngine {
    let id = EngineID(name: "live-preview-test", revision: "1", placement: .cpu)
    let stream = SpeakTestPreviewStream(analyzers: SpeakTestAnalyzers())
    func open(_ lang: Lang, highPriority: Bool) async throws -> any ASRStream { stream }
}

private final class SpeakTestRestartingPreview: StreamingASREngine, Sendable {
    let id = EngineID(name: "restarting-preview-test", revision: "1", placement: .cpu)
    private let streams = Mutex<[SpeakTestPreviewStream]>([])
    var stream: SpeakTestPreviewStream? { streams.withLock { $0.last } }
    var openCount: Int { streams.withLock { $0.count } }
    func open(_ lang: Lang, highPriority: Bool) async throws -> any ASRStream {
        let analyzers = SpeakTestAnalyzers(); analyzers.opened()
        let stream = SpeakTestPreviewStream(analyzers: analyzers)
        streams.withLock { $0.append(stream) }
        return stream
    }
}

private actor SpeakTestASR: ClipASREngine {
    nonisolated let id = EngineID(name: "test", revision: "1", placement: .cpu)
    let text: String
    let texts: [String]
    let fails: Bool
    let delay: Duration
    let analyzers: SpeakTestAnalyzers?
    private(set) var calls = 0
    private(set) var contexts: [String?] = []
    init(text: String = "你好世界", fails: Bool = false, delay: Duration = .zero,
         analyzers: SpeakTestAnalyzers? = nil, texts: [String] = []) {
        self.text = text; self.fails = fails; self.delay = delay; self.analyzers = analyzers
        self.texts = texts
    }
    func transcribe(_ clip: PCMClip16k, hint: Lang, context: String?, job: JobID,
                    priority: Priority, deadline: HostTime?) async throws -> ASRFinal {
        calls += 1
        contexts.append(context)
        let recognized = texts.isEmpty ? text : texts[min(calls - 1, texts.count - 1)]
        analyzers?.opened()
        defer { analyzers?.closed() }
        try await Task.sleep(for: delay)
        if fails { throw CancellationTestError.failure }
        return ASRFinal(text: recognized, language: .zh,
                        timing: .init(received: 0, started: 0, firstOutput: nil, finished: 0))
    }
    func cancel(_ job: JobID) async {}
}
private enum CancellationTestError: Error { case failure }

private actor SpeakTestMT: SpeakTranslator {
    let text: String
    let translations: [String: String]
    let delay: Duration
    let cancelDelay: Duration
    private(set) var calls = 0
    private(set) var requests: [SpeakMTRequest] = []
    private var active = 0
    private(set) var peak = 0
    private(set) var cancellations = 0
    init(text: String = "Hello world.", delay: Duration = .zero, cancelDelay: Duration = .zero,
         translations: [String: String] = [:]) {
        self.text = text; self.delay = delay; self.cancelDelay = cancelDelay
        self.translations = translations
    }
    func translate(_ request: SpeakMTRequest) async throws -> SpeakMTOutcome {
        requests.append(request)
        calls += 1; active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: delay)
        return .text(translations[request.text] ?? text, backend: .apple, numberWarning: nil, hedge: nil)
    }
    func cancel(_ job: JobID) async {
        cancellations += 1
        try? await Task.sleep(for: cancelDelay)
    }
    func pressBegan() async {}
    func prepare(targets: [Lang]) async {}
}

private final class SpeakTestTTS: TTSEngine, Sendable {
    let id = EngineID(name: "system-test", revision: "1", placement: .cpu)
    let outputRate = 24_000.0
    let requests = Mutex<[TTSRequest]>([])
    let failures: Int
    init(failures: Int = 0) { self.failures = failures }
    func buildConditioning(_ ref: VoiceReference, model: EngineID, mode: CloneMode) async throws -> Data { Data() }
    func load(_ voice: VoiceHandle, blob: Data) async throws {}
    func speak(_ request: TTSRequest) -> AsyncThrowingStream<TTSChunk, any Error> {
        let shouldFail = requests.withLock { $0.append(request); return $0.count <= failures }
        return AsyncThrowingStream { c in
            if shouldFail { c.finish(throwing: CancellationTestError.failure); return }
            let now = HostClock.now()
            let samples = (0..<12_000).map { Float(sin(Double($0) * 0.1) * 0.1) }
            c.yield(.init(job: request.job, seq: 0, samples24k: samples, isLast: true, producedAt: now,
                summary: .init(audioS: 0.5, frames: 12_000,
                               timing: .init(received: now, started: now, firstOutput: now, finished: now))))
            c.finish()
        }
    }
    func report(_ p: PlayoutReport) async {}
    func cancel(_ job: JobID) async {}
}

private struct SpeakTestControl: SpeakEngineControl {
    var status: AsyncStream<SpeakEngineStatus> { AsyncStream { $0.yield(.ready); $0.finish() } }
    func pressActive(_ active: Bool) async {}
    func cancelSpeak() async {}
}
private struct SpeakTestEcho: SpeakEchoSink {
    func recordPlayed(text: String, startHost: HostTime, endHost: HostTime) async {}
    func recordPassthrough(startHost: HostTime, endHost: HostTime) async {}
    func recentRemoteText(withinS: Double) async -> [String] { [] }
    func remoteVADOverlap(from: HostTime, to: HostTime) async -> Double? { 0 }
}

struct SpeakPipelineTests {
    private func fixture(asr: SpeakTestASR = .init(), mt: SpeakTestMT = .init(),
                         primary: SpeakTestASR? = nil, ttsFailures: Int = 0,
                         preview: (any StreamingASREngine)? = nil, whileHeld: Bool = false, target: Lang = .en,
                         captureFromKeyDown: Bool = false, log: EventLog? = nil,
                         asrContext: @escaping @Sendable () -> String? = { nil },
                         onCommit: @escaping @Sendable () -> Void = {},
                         onWorkChange: @escaping @Sendable (Bool) -> Void = { _ in },
                         onUI: @escaping @Sendable (SpeakUIEvent) -> Void = { _ in },
                         onSpoken: @escaping @Sendable (String, String, HostTime) -> Void = { _, _, _ in }) throws -> (SpeakPipeline, SpeakTestMic, SpeakTestHost, SpeakTestTTS) {
        let profile = try PolicyProfile.load(from: Fixture.repoRoot.appendingPathComponent("Resources/PolicyProfile.default.json"))
        let mic = SpeakTestMic(), host = try SpeakTestHost(), tts = SpeakTestTTS(failures: ttsFailures)
        let handle = VoiceHandle(profileID: UUID(), conditioningKey: "system", mode: .system, model: tts.id)
        let pipeline = SpeakPipeline(profile: profile, mic: mic, playout: host, queue: host.queue,
            primaryASR: primary, fallbackASR: asr, translator: mt,
            voice: { .init(clone: nil, system: tts, systemHandle: handle, cloneAvailability: .noProfile,
                           playoutGainDb: 0, hudVoice: .system) },
            engine: SpeakTestControl(), echo: SpeakTestEcho(), previewASR: preview, target: target, jobs: JobIDSequence(),
            log: log ?? EventLog(inMemory: HostClock.now), speakerMode: { false }, captureFromKeyDown: captureFromKeyDown,
            ui: onUI, onCommit: onCommit, onWorkChange: onWorkChange, onSpoken: onSpoken,
            asrContext: asrContext, commitWhileHeld: whileHeld)
        return (pipeline, mic, host, tts)
    }
    private func clip(at: HostTime) -> SpeakClip {
        .init(pcm: .init(samples: Array(repeating: 0.1, count: 16_000), start: at, end: at + 1_000_000_000),
              index: 0, isFinal: true, speechMs: 1000, cutReason: .release)
    }

    @Test func releaseUsesASRFallbackAndProducesOneTargetLanguageClause() async throws {
        let primary = SpeakTestASR(fails: true), fallback = SpeakTestASR()
        let (pipeline, mic, host, tts) = try fixture(asr: fallback, primary: primary)
        let now = HostClock.now()
        await pipeline.start(); await pipeline.handle(.began(at: now))
        mic.press.cc.yield(clip(at: now))
        // Actor rendezvous: the clip may arrive before or after release; neither ordering may lose it.
        #expect(await primary.calls == 0)
        await pipeline.handle(.released(at: now + 1_000_000_000, reason: .keyUp))
        #expect(await until { tts.requests.withLock { $0.count == 1 } })
        #expect(await primary.calls == 1)
        #expect(await fallback.calls == 1)
        #expect(tts.requests.withLock { $0[0].text == "Hello world." && $0[0].language == .en })
        #expect(await until { (try? host.queue.pump(at: HostClock.now())) != nil && host.ring.availableFrames > 0 })
        await pipeline.stop()
    }

    @Test func recognitionContextStaysWithinTheRecordingTurn() async throws {
        let primary = SpeakTestASR(texts: ["上一轮的第一句。", "上一轮的第二句。", "这是新一轮。"])
        let mt = SpeakTestMT()
        let (pipeline, mic, _, _) = try fixture(mt: mt, primary: primary, whileHeld: true,
                                               asrContext: { "TalkTalk" })
        let now = HostClock.now()
        await pipeline.handle(.began(at: now))
        mic.press.cc.yield(clip(at: now))
        #expect(await until { await mt.calls == 1 })
        mic.press.cc.yield(clip(at: now + 1_000_000_000))
        #expect(await until { await mt.calls == 2 })
        await pipeline.handle(.released(at: now + 2_000_000_000, reason: .keyUp))
        await pipeline.handle(.began(at: now + 3_000_000_000))
        mic.press.cc.yield(clip(at: now + 3_000_000_000))
        #expect(await until { await mt.calls == 3 })
        let contexts = await primary.contexts
        #expect(contexts == ["TalkTalk", "上一轮的第一句。\nTalkTalk", "TalkTalk"])
        await pipeline.stop()
    }

    @Test func lengthDiagnosticsLinkSourceClipToTTSWithoutText() async throws {
        let log = EventLog(inMemory: HostClock.now)
        let (pipeline, mic, _, _) = try fixture(log: log)
        let now = HostClock.now()
        await pipeline.handle(.began(at: now))
        mic.press.cc.yield(clip(at: now))
        await pipeline.handle(.released(at: now + 1_000_000_000, reason: .keyUp))
        #expect(await until { log.recorded.contains { $0["ev"] as? String == "speak.tts_complete" } })
        let events = log.recorded
        let source = try #require(events.first { $0["ev"] as? String == "speak.clip_committed" })
        let request = try #require(events.first { $0["ev"] as? String == "speak.tts_requested" })
        let complete = try #require(events.first { $0["ev"] as? String == "speak.tts_complete" })
        #expect(source["clip_ms"] as? Int == 1000 && source["speech_ms"] as? Int == 1000)
        #expect(source["cut_reason"] as? String == "release")
        #expect(request["clause"] as? Int == source["clause"] as? Int)
        #expect(request["members"] as? Int == 1)
        #expect(request["target_words"] as? Int == 2 && request["target_characters"] as? Int == 12)
        #expect(request["expected_audio_ms"] as? Int == 1071)
        #expect(complete["job"] as? Int == request["job"] as? Int)
        #expect(complete["audio_ms"] as? Int == 500)
        for event in [source, request, complete] {
            let line = String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
            #expect(DiagnosticsWhitelist.scrubEventLine(Substring(line)) != nil)
            #expect(!line.contains("Hello world") && !line.contains("你好世界"))
            #expect(event["voice_key"] == nil && event["conditioningKey"] == nil)
        }
        await pipeline.stop()
    }

    @Test func releaseWaitsForOpeningPreviewAndSerializesASRButNotMT() async throws {
        let analyzers = SpeakTestAnalyzers()
        let asr = SpeakTestASR(delay: .milliseconds(40), analyzers: analyzers)
        let mt = SpeakTestMT(delay: .milliseconds(200))
        let (pipeline, mic, _, tts) = try fixture(asr: asr, mt: mt,
            preview: SpeakTestPreviewEngine(analyzers: analyzers))
        let now = HostClock.now()
        await pipeline.handle(.began(at: now))
        #expect(await until { analyzers.active == 1 })
        for index in 0..<3 { mic.press.cc.yield(clip(at: now + UInt64(index) * 1_000_000_000)) }
        await pipeline.handle(.released(at: now + 3_000_000_000, reason: .keyUp))
        #expect(await until { await mt.calls == 3 })
        #expect(await until { tts.requests.withLock { !$0.isEmpty } })
        #expect(await asr.calls == 3)
        #expect(analyzers.peak == 1)
        #expect(await mt.peak > 1)
        await pipeline.stop()
        #expect(analyzers.active == 0)
    }

    @Test func stoppingDuringTranslationCannotEnqueueLateAudio() async throws {
        let mt = SpeakTestMT(delay: .seconds(1))
        let (pipeline, mic, host, tts) = try fixture(mt: mt)
        let now = HostClock.now()
        await pipeline.start(); await pipeline.handle(.began(at: now))
        mic.press.cc.yield(clip(at: now))
        await pipeline.handle(.released(at: now + 1_000_000_000, reason: .keyUp))
        #expect(await until { await mt.calls == 1 })
        await pipeline.stop()
        #expect(tts.requests.withLock { $0.isEmpty })
        #expect(host.queue.clauseCount == 0)
    }

    @Test func meetingCaptureStartsAtKeyDownAndBusyWaitsForCancellation() async throws {
        let busy = Mutex<[Bool]>([])
        let mt = SpeakTestMT(delay: .seconds(10), cancelDelay: .milliseconds(100))
        let (pipeline, mic, _, tts) = try fixture(mt: mt, captureFromKeyDown: true,
            onWorkChange: { value in busy.withLock { $0.append(value) } })
        let now = HostClock.now()
        await pipeline.handle(.began(at: now))
        #expect(mic.captureFloor == now)
        mic.press.cc.yield(clip(at: now))
        await pipeline.handle(.released(at: now + 1_000_000_000, reason: .keyUp))
        #expect(await until { await mt.calls == 1 })
        let cancel = Task { await pipeline.handle(.doubleTapped(at: now + 2_000_000_000)) }
        #expect(await until { await mt.cancellations > 0 })
        #expect(!(await pipeline.isIdle))
        #expect(busy.withLock { $0 == [true] })
        await cancel.value
        #expect(await pipeline.isIdle)
        #expect(busy.withLock { $0 == [true, false] })
        #expect(tts.requests.withLock { $0.isEmpty })
        await pipeline.stop()
    }

    @Test func transientTTSFailureRetriesWithoutWaitingForAnEngineRestart() async throws {
        let (pipeline, mic, host, tts) = try fixture(ttsFailures: 1)
        let now = HostClock.now()
        // No engine status subscription: a single stream failure must recover without ready.
        await pipeline.handle(.began(at: now))
        mic.press.cc.yield(clip(at: now))
        await pipeline.handle(.released(at: now + 1_000_000_000, reason: .keyUp))
        #expect(await until { tts.requests.withLock { $0.count == 2 } })
        #expect(await until { (try? host.queue.pump(at: HostClock.now())) != nil && host.ring.availableFrames > 0 })
        await pipeline.stop()
    }

    @Test func evenAnInvalidTranslatorCannotSendHanToTTS() async throws {
        let (pipeline, mic, _, tts) = try fixture(mt: .init(text: "错误的中文译文"))
        let now = HostClock.now()
        await pipeline.start(); await pipeline.handle(.began(at: now))
        mic.press.cc.yield(clip(at: now))
        await pipeline.handle(.released(at: now + 1_000_000_000, reason: .keyUp))
        #expect(await until { await pipeline.isIdle })
        #expect(tts.requests.withLock { $0.isEmpty })
        await pipeline.stop()
    }

    @Test func heldCommitStartsTTSAndDoubleTapClearsCurrentEpoch() async throws {
        let commits = Mutex(0)
        let (pipeline, mic, host, tts) = try fixture(whileHeld: true, onCommit: { commits.withLock { $0 += 1 } })
        let now = HostClock.now()
        await pipeline.start(); await pipeline.handle(.began(at: now))
        mic.press.cc.yield(clip(at: now))
        #expect(await until { tts.requests.withLock { $0.count == 1 } })
        #expect(commits.withLock { $0 } == 1)
        let oldEpoch = host.queue.currentEpoch
        await pipeline.handle(.doubleTapped(at: now + 2_000_000_000))
        #expect(host.queue.currentEpoch != oldEpoch && host.queue.clauseCount == 0)
        #expect(await pipeline.isIdle)
        await pipeline.stop()
    }

    @Test func previewNewPressWaitsForBorrowedFinalASRSlot() async {
        let analyzers = SpeakTestAnalyzers()
        let preview = SpeakPreview(engine: SpeakTestPreviewEngine(analyzers: analyzers))
        await preview.pauseForFinalASR()
        analyzers.opened() // the final recognizer owns the slot across a press boundary
        await preview.stop()
        await preview.start(frames: AsyncStream { $0.finish() }, update: { _ in })
        #expect(analyzers.active == 1 && analyzers.peak == 1)
        analyzers.closed()
        await preview.resumeAfterFinalASR()
        #expect(analyzers.active == 1 && analyzers.peak == 1)
        await preview.stop()
        #expect(analyzers.active == 0)
    }

    @Test func previewShowsFullRevisionsAndUncommittedTailStaysLabelled() async throws {
        let engine = SpeakTestLivePreview()
        let snapshots = Mutex<[SpeakPreview.Snapshot]>([])
        let live = SpeakPreview(engine: engine)
        let frames = AsyncStream<SpeakPreviewFrame>.makeStream()
        let now = HostClock.now()
        await live.start(frames: frames.stream) { value in snapshots.withLock { $0.append(value) } }
        frames.continuation.yield(.init(samples: Array(repeating: 1, count: 160), at: now, level: 0.1))
        #expect(await until { snapshots.withLock { $0.last?.from == now } })
        engine.stream.emit(.volatile("今天我们继续开发", through: now + 100_000_000))
        #expect(await until { snapshots.withLock { $0.last?.text == "今天我们继续开发" } })
        #expect(snapshots.withLock { $0.last?.stableText.isEmpty == true })
        engine.stream.emit(.volatile("今天我们继续检查字幕", through: now + 200_000_000))
        #expect(await until { snapshots.withLock { $0.last?.text == "今天我们继续检查字幕" } })
        #expect(snapshots.withLock { $0.last?.stableText == "今天我们继续" })
        engine.stream.emit(.final("今天我们继续检查字幕。", range: now...(now + 200_000_000)))
        #expect(await until { snapshots.withLock { $0.last?.isFinal == true } })
        engine.stream.emit(.volatile("旧的假设", through: now + 200_000_000))
        await live.stop()
        #expect(snapshots.withLock { $0.last?.text == "今天我们继续检查字幕。" })

        // The capture stream can finish without committing a short tail. Its recognizer preview
        // remains visible as a draft, never a successful final source or translated sentence.
        let tailEngine = SpeakTestLivePreview(), transcript = Mutex<SpeakTranscript?>(nil)
        let (pipeline, mic, _, tts) = try fixture(preview: tailEngine, onUI: { event in
            if case .transcript(let value) = event { transcript.withLock { $0 = value } }
        })
        await pipeline.handle(.began(at: now))
        mic.press.pc.yield(.init(samples: Array(repeating: 1, count: 160), at: now, level: 0.1))
        tailEngine.stream.emit(.volatile("还有最后一个词", through: now + 100_000_000))
        #expect(await until { transcript.withLock { $0?.source == "还有最后一个词" } })
        await pipeline.handle(.released(at: now + 200_000_000, reason: .keyUp))
        #expect(await until { transcript.withLock { $0?.isFinal == true } })
        #expect(transcript.withLock { $0?.source.isEmpty == true && $0?.target.isEmpty == true
            && $0?.unsubmittedSource == "还有最后一个词" })
        #expect(tts.requests.withLock { $0.isEmpty })
        await pipeline.stop()
    }

    @Test func transcriptKeepsAllSegmentsAndWaitsForReleasedTail() async throws {
        let transcript = Mutex<SpeakTranscript?>(nil)
        let asr = SpeakTestASR(delay: .milliseconds(40), texts: ["第一段。", "最后一段。"])
        let mt = SpeakTestMT(translations: ["第一段。": "First segment.", "最后一段。": "Final segment."])
        let (pipeline, mic, _, tts) = try fixture(asr: asr, mt: mt, whileHeld: true, onUI: { event in
            if case .transcript(let value) = event { transcript.withLock { $0 = value } }
        })
        let now = HostClock.now()
        await pipeline.handle(.began(at: now))
        mic.press.cc.yield(clip(at: now))
        #expect(await until { tts.requests.withLock { $0.count == 1 } })
        #expect(transcript.withLock { $0?.source == "第一段。" && $0?.isFinal == false })
        mic.press.cc.yield(clip(at: now + 1_000_000_000))
        await pipeline.handle(.released(at: now + 2_000_000_000, reason: .keyUp))
        #expect(transcript.withLock { $0?.isFinal == false })
        #expect(await until { transcript.withLock { $0?.isFinal == true } })
        #expect(transcript.withLock { $0?.source == "第一段。\n最后一段。"
            && $0?.target == "First segment. Final segment." && $0?.unsubmittedSource.isEmpty == true })
        await pipeline.stop()
    }

    @Test func discardedSegmentDoesNotBlockLaterSourceOrLivePreview() async throws {
        let transcript = Mutex<SpeakTranscript?>(nil)
        let preview = SpeakTestRestartingPreview(), primary = SpeakTestASR(texts: ["", "后续原文。"])
        let mt = SpeakTestMT()
        let (pipeline, mic, _, _) = try fixture(mt: mt, primary: primary, preview: preview,
            whileHeld: true, onUI: { event in
                if case .transcript(let value) = event { transcript.withLock { $0 = value } }
            })
        let now = HostClock.now()
        await pipeline.handle(.began(at: now))
        #expect(await until { preview.openCount == 1 })
        mic.press.pc.yield(.init(samples: Array(repeating: 1, count: 160), at: now, level: 0.1))
        preview.stream?.emit(.volatile("这一小段未提交", through: now + 100_000_000))
        #expect(await until { transcript.withLock { $0?.source == "这一小段未提交" } })
        mic.press.cc.yield(clip(at: now))
        #expect(await until { transcript.withLock { $0?.unsubmittedSource == "这一小段未提交" } })
        #expect(await until { preview.openCount == 2 })

        mic.press.cc.yield(clip(at: now + 1_000_000_000))
        #expect(await until { transcript.withLock { $0?.source == "后续原文。" } })
        #expect(await until { preview.openCount == 3 })
        mic.press.pc.yield(.init(samples: Array(repeating: 1, count: 160), at: now + 2_000_000_000, level: 0.1))
        preview.stream?.emit(.volatile("继续输入的新预览", through: now + 2_100_000_000))
        #expect(await until { transcript.withLock {
            $0?.source == "后续原文。\n继续输入的新预览" && $0?.isFinal == false
                && $0?.unsubmittedSource == "这一小段未提交"
        } })
        #expect(await until { await mt.calls == 1 })
        let requests = await mt.requests
        #expect(requests.map(\.text) == ["后续原文。"])
        await pipeline.stop()
    }

    @Test func transcriptRetentionEvictsOldPairsWithoutDiscardingWork() async throws {
        let transcript = Mutex<SpeakTranscript?>(nil)
        let sources = ["开头一段。", "接着一段。", "一分钟后的内容。"]
        let translations = ["开头一段。": "Opening segment.", "接着一段。": "Following segment.",
                            "一分钟后的内容。": "Content after one minute."]
        let mt = SpeakTestMT(translations: translations)
        let (pipeline, mic, _, _) = try fixture(asr: SpeakTestASR(texts: sources), mt: mt,
            whileHeld: true, onUI: { event in
                if case .transcript(let value) = event { transcript.withLock { $0 = value } }
            })
        let now = HostClock.now()
        await pipeline.handle(.began(at: now))
        pipeline.setFloorPaused(true) // Keep playback/backlog policy out of this display-only check.
        mic.press.cc.yield(clip(at: now))
        mic.press.cc.yield(clip(at: now + 1_000_000_000))
        #expect(await until { transcript.withLock {
            $0?.source == "开头一段。\n接着一段。" && $0?.target == "Opening segment. Following segment."
        } })
        // Only a new clip advances the reading window; no wall-clock wait or recording restart.
        mic.press.cc.yield(clip(at: now + 62_000_000_000))
        #expect(await until { transcript.withLock {
            $0?.source == "一分钟后的内容。" && $0?.target == "Content after one minute."
                && $0?.isFinal == false && $0?.unsubmittedSource.isEmpty == true
        } })
        let requests = await mt.requests
        #expect(requests.map(\.text).sorted() == sources.sorted())
        await pipeline.stop()
    }

    @Test func backlogSummarizesWaitingClausesInsteadOfStartingAllTTS() async throws {
        let transcript = Mutex<SpeakTranscript?>(nil)
        let sources = ["第一段内容。", "第二段内容。", "第三段内容。", "第四段内容。", "一分钟后的新段。"]
        let mt = SpeakTestMT(text: "We will discuss the complete project plan at the meeting.")
        let (pipeline, mic, host, tts) = try fixture(asr: SpeakTestASR(texts: sources), mt: mt,
            whileHeld: true, onUI: { event in
                if case .transcript(let value) = event { transcript.withLock { $0 = value } }
            })
        let now = HostClock.now()
        await pipeline.start(); await pipeline.handle(.began(at: now))
        for index in 0..<4 { mic.press.cc.yield(clip(at: now + UInt64(index) * 1_000_000_000)) }
        #expect(await until { await mt.requests.contains { $0.mode == .summarize } })
        #expect(tts.requests.withLock { $0.count < 4 })
        #expect(host.queue.clauseCount > 0)
        pipeline.setFloorPaused(true)
        mic.press.cc.yield(clip(at: now + 70_000_000_000))
        #expect(await until { transcript.withLock {
            $0?.source == "一分钟后的新段。" && $0?.target == "We will discuss the complete project plan at the meeting."
        } })
        await pipeline.stop()
    }

    @Test func announcementStaysOutsideBacklogAndSpokenCallbackWaitsForFeed() async throws {
        let spoken = Mutex(0)
        let (pipeline, mic, host, tts) = try fixture(whileHeld: true,
            onSpoken: { _, _, _ in spoken.withLock { $0 += 1 } })
        await pipeline.configureAnnouncement(text: "I use live translation.", enabled: true)
        #expect(await until { tts.requests.withLock { $0.count == 1 } })
        let now = HostClock.now()
        await pipeline.handle(.began(at: now)); await pipeline.handle(.tapped(at: now + 50_000_000))
        #expect(host.queue.clauseCount == 0)
        await pipeline.handle(.began(at: now + 100_000_000))
        mic.press.cc.yield(clip(at: now + 100_000_000))
        #expect(await until { tts.requests.withLock { $0.count == 2 } })
        let user = try #require(tts.requests.withLock { $0.last })
        #expect(host.queue.drainEstimate().renderedMs > host.queue.drainEstimate(excludingAnnouncements: true).renderedMs)
        let events = try host.queue.pump(at: now + 200_000_000)
        await pipeline.receive(events)
        #expect(spoken.withLock { $0 } == 0)
        // Only an actual Feed first-sample event may create the optional transcript record.
        let played = ClauseQueue.Event.firstSamplePlayed(clause: user.clause, job: user.job, at: now + 300_000_000)
        await pipeline.receive([played, played])
        #expect(spoken.withLock { $0 } == 1)
        await pipeline.handle(.doubleTapped(at: now + 400_000_000))
        await pipeline.configureAnnouncement(text: "I use live translation.", enabled: false)
        await pipeline.configureAnnouncement(text: "I use live translation.", enabled: true)
        await pipeline.handle(.began(at: now + 500_000_000))
        mic.press.cc.yield(clip(at: now + 500_000_000))
        #expect(await until { tts.requests.withLock { $0.count == 3 } })
        #expect(host.queue.clauseCount == 1) // toggling cannot replay the automatic notice
        await pipeline.stop()

        let (manual, _, manualHost, manualTTS) = try fixture()
        await manual.configureAnnouncement(text: "I use live translation.", enabled: false)
        #expect(manualTTS.requests.withLock { $0.isEmpty })
        await manual.playAnnouncement()
        #expect(await until { manualHost.queue.clauseCount == 1 })
        #expect(manualTTS.requests.withLock { $0.count == 1 })
        await manual.stop()
    }

    @Test func languageGateAcceptsMixedAndLatinSegmentsAndKeepsEchoChecks() throws {
        let p = try PolicyProfile.load(from: Fixture.repoRoot.appendingPathComponent("Resources/PolicyProfile.default.json"))
        let gate = SpeakLanguageGate(p.speak)
        #expect(gate.isFiller("嗯，那个，就是。"))
        #expect(!gate.isFiller("那个作品"))
        #expect(gate.check("这是 API 接口", speakerMode: false, remoteOverlap: nil, recentRemoteText: []) == nil)
        #expect(gate.check("使用 TypeScript", speakerMode: false, remoteOverlap: nil, recentRemoteText: []) == nil)
        #expect(gate.check("Let's check the deployment pipeline.", speakerMode: false, remoteOverlap: nil, recentRemoteText: []) == nil)
        #expect(gate.check("Привет", speakerMode: false, remoteOverlap: nil, recentRemoteText: []) == .unsupportedText)
        #expect(gate.check("这是 API 接口", speakerMode: true, remoteOverlap: 0.5, recentRemoteText: []) == .remoteOverlap)
        #expect(gate.check("check the deployment pipeline", speakerMode: true, remoteOverlap: 0,
                           recentRemoteText: ["Please check the deployment pipeline."]) == .remoteText)
    }

    @Test func firstEnglishSegmentAndMixedSpeechReachTranslationWithGermanTarget() async throws {
        let sources = ["Let's check the deployment pipeline.", "使用 TypeScript", "We can ship this tomorrow."]
        let asr = SpeakTestASR(texts: sources)
        let mt = SpeakTestMT(text: "Wir prüfen das morgen.")
        let (pipeline, mic, _, _) = try fixture(asr: asr, mt: mt, whileHeld: true, target: .de)
        let now = HostClock.now()
        await pipeline.handle(.began(at: now))
        for index in sources.indices { mic.press.cc.yield(clip(at: now + UInt64(index) * 1_000_000_000)) }
        await pipeline.handle(.released(at: now + 3_000_000_000, reason: .keyUp))
        #expect(await until { await mt.calls == sources.count })
        let requests = await mt.requests
        #expect(requests.map(\.text).sorted() == sources.sorted())
        #expect(requests.allSatisfy { $0.target == .de })
        await pipeline.stop()
    }
}
