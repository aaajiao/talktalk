import Foundation
import Synchronization
import Testing
@testable import TalkTalkCore
@testable import TalkTalkSession

// MARK: - fakes

final class FakeStream: ASRStream, @unchecked Sendable {
    let volatileEvents: AsyncStream<ASREvent>
    let finalEvents: AsyncStream<ASREvent>
    let vc: AsyncStream<ASREvent>.Continuation
    let fc: AsyncStream<ASREvent>.Continuation
    private let lock = NSLock()
    private var _finalizes: [HostTime] = []
    private var _fed = 0
    var finalizes: [HostTime] { lock.withLock { _finalizes } }
    var fed: Int { lock.withLock { _fed } }

    init() {
        (volatileEvents, vc) = AsyncStream.makeStream(of: ASREvent.self, bufferingPolicy: .bufferingNewest(1))
        (finalEvents, fc) = AsyncStream.makeStream(of: ASREvent.self, bufferingPolicy: .bufferingOldest(64))
    }
    func feed(_ frames: UnsafeBufferPointer<Int16>, at: HostTime) { lock.withLock { _fed += frames.count } }
    func finalize(through: HostTime) async { lock.withLock { _finalizes.append(through) } }
    func close() async { vc.finish(); fc.finish() }
    func volatile(_ t: String) { vc.yield(.volatile(t, through: HostClock.now())) }
    func final(_ t: String) { let n = HostClock.now(); fc.yield(.final(t, range: n...n)) }
}

struct FakeASR: StreamingASREngine {
    let stream: FakeStream
    var partialUpdateIntervalMs: Int = 0
    var id: EngineID { EngineID(name: "fake-asr", revision: "1", placement: .cpu) }
    func open(_ lang: Lang, highPriority: Bool) async throws -> any ASRStream { stream }
}

actor FakeMT: MTEngine {
    nonisolated let id: EngineID
    let prefix: String
    let delayMs: Int
    let fixed: String?
    private(set) var requests: [MTRequest] = []
    private(set) var cancels: [JobID] = []

    init(_ name: String, placement: Placement, prefix: String, delayMs: Int, fixed: String? = nil) {
        id = EngineID(name: name, revision: "1", placement: placement)
        self.prefix = prefix; self.delayMs = delayMs; self.fixed = fixed
    }

    func translate(_ r: MTRequest) async throws -> MTResult {
        requests.append(r)
        try await Task.sleep(for: .milliseconds(delayMs))
        let now = HostClock.now()
        return MTResult(text: fixed ?? "\(prefix):\(r.text)", tokens: 1, reasoningTokens: 0, engine: id,
                        hedge: HedgeOutcome(fired: false, winner: .A, reason: nil, ms: delayMs),
                        timing: StageTiming(received: now, started: now, firstOutput: now, finished: now))
    }
    func setContext(_ s: MTSession, glossary: [GlossaryEntry]) async throws {}
    func cancel(_ job: JobID) async { cancels.append(job) }
}

final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [SubtitleUpdate] = []
    func add(_ u: SubtitleUpdate) { lock.withLock { _items.append(u) } }
    var items: [SubtitleUpdate] { lock.withLock { _items } }
    var finals: [(UInt64, String, Bool, Bool)] {
        items.compactMap { if case let .final(s, t, _, a, n) = $0 { (s, t, a, n) } else { nil } }
    }
    var drafts: [String] { items.compactMap { if case let .draft(_, t) = $0 { t } else { nil } } }
}

func until(_ timeoutMs: Int = 3000, _ cond: () async -> Bool) async -> Bool {
    let end = ContinuousClock.now + .milliseconds(timeoutMs)
    while ContinuousClock.now < end {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await cond()
}

enum Fixture {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func listen(deadlineMs: Int = 300) throws -> PolicyProfile.Listen {
        var p = try PolicyProfile.load(from: repoRoot.appendingPathComponent("Resources/PolicyProfile.default.json")).listen
        p.finalMT.deadlineMs = deadlineMs
        return p
    }
}

// MARK: - tests

@Suite struct ListenPipelineTests {
    @Test func batchedASRCadenceDoesNotForceOrStallButRealSilenceStillFinalizes() async throws {
        let original = try Fixture.listen()
        let pipeline = ListenPipeline(lang: .de, profile: original,
            engines: .init(asr: FakeASR(stream: FakeStream(), partialUpdateIntervalMs: 1000), apple: nil, primary: nil),
            log: EventLog(inMemory: HostClock.now), onUpdate: { _ in })
        let adjusted = await pipeline.profile
        var segmenter = ListenSegmenter(lang: .de, profile: adjusted)
        var words = "one two three four five six seven eight nine ten."
        for second in 0...9 {
            let updates = segmenter.volatile(words, nowMs: second * 1000)
            #expect(!updates.contains { if case .finalize = $0 { true } else { false } })
            let waiting = segmenter.tick(nowMs: second * 1000 + 999, silenceMs: 0)
            #expect(!waiting.contains { if case .finalize = $0 { true } else { false } })
            words += " more"
        }
        let silence = segmenter.tick(nowMs: 10_000, silenceMs: 1000)
        #expect(silence.contains(.finalize(sentence: 1, trigger: .silence, throughMs: 10_000)))
        #expect(adjusted.finalize.silenceMs == original.finalize.silenceMs)
        #expect(adjusted.finalize.hardCapS == original.finalize.hardCapS)
    }

    @Test func volatileDeliveredAfterItsFinalCannotRepopulateTheNextSentence() async throws {
        let (pipeline, _, sink, _) = try make(primary: nil, apple: nil)
        try await pipeline.start()
        let cut = HostClock.now()
        await pipeline.onFinal("The first sentence is finished.", range: cut...cut)
        #expect(await until { sink.finals.count == 1 })

        // Model the two independent ASR consumers delivering a buffered old hypothesis after
        // the final consumer has advanced the sentence. Equal and older boundaries are stale.
        await pipeline.onVolatile("stale equal boundary", through: cut)
        await pipeline.onVolatile("stale earlier boundary", through: cut - 1)
        #expect(await pipeline.volatileText.isEmpty)
        #expect(!sink.items.contains(.source("stale equal boundary")))
        #expect(!sink.items.contains(.source("stale earlier boundary")))

        await pipeline.onVolatile("new sentence", through: cut + 1)
        #expect(await pipeline.volatileText == "new sentence")
        #expect(await pipeline.openSentence == 2)
        await pipeline.stop()
    }

    @Test func stoppingCancelsInFlightFinalWithoutLateSubtitles() async throws {
        let primary = FakeMT("openai", placement: .network, prefix: "cloud", delayMs: 500)
        let apple = FakeMT("apple", placement: .systemService, prefix: "apple", delayMs: 500)
        let (p, stream, sink, _) = try make(primary: primary, apple: apple, deadlineMs: 1000)
        try await p.start()
        stream.final("This reply must not reach the next meeting.")
        #expect(await until { !(await primary.requests).isEmpty })
        await p.stop()
        #expect(await until { await p.pendingFinals == 0 })
        #expect(sink.finals.isEmpty)
        // Stop and the cancelled final task may both notify the idempotent backend.
        let cancelled = await primary.cancels, requested = await primary.requests.map(\.job)
        #expect(!cancelled.isEmpty && Set(cancelled) == Set(requested))
    }

    func make(primary: FakeMT?, apple: FakeMT?, deadlineMs: Int = 300) throws -> (ListenPipeline, FakeStream, Sink, EventLog) {
        let stream = FakeStream(), sink = Sink(), log = EventLog(inMemory: HostClock.now)
        let p = ListenPipeline(lang: .en, profile: try Fixture.listen(deadlineMs: deadlineMs),
                               engines: .init(asr: FakeASR(stream: stream), apple: apple, primary: primary),
                               log: log, tickMs: 100_000, onUpdate: { sink.add($0) })
        return (p, stream, sink, log)
    }

    func events(_ log: EventLog, _ name: String) -> [[String: Any]] { log.recorded.filter { ($0["ev"] as? String) == name } }

    @Test func primaryInTimeIsTheFinal() async throws {
        let primary = FakeMT("openai", placement: .network, prefix: "云", delayMs: 30)
        let apple = FakeMT("apple", placement: .systemService, prefix: "苹", delayMs: 10)
        let (p, s, sink, log) = try make(primary: primary, apple: apple)
        try await p.start()
        s.volatile("hello there")
        s.final("Hello there.")
        #expect(await until { sink.finals.count == 1 })
        let f = sink.finals[0]
        #expect(f.0 == 1 && f.1 == "云:Hello there." && f.2 == false)
        let reqs = await primary.requests
        #expect(reqs.first?.session == .listenEnZh && reqs.first?.priority == .p2Listen)
        #expect(reqs.first?.deadline != nil)
        #expect(events(log, "mt.final").first?["engine"] as? String == "openai")
        await p.stop()
    }

    @Test func nonePlaceholderFallsBackInsteadOfBecomingASubtitle() async throws {
        let primary = FakeMT("openai", placement: .network, prefix: "", delayMs: 5, fixed: " \n<none>\n ")
        let apple = FakeMT("apple", placement: .systemService, prefix: "", delayMs: 10, fixed: "这是有效的译文。")
        let (pipeline, stream, sink, log) = try make(primary: primary, apple: apple)
        try await pipeline.start()
        stream.final("A valid sentence.")
        #expect(await until { sink.finals.count == 1 })
        #expect(sink.finals.first?.1 == "这是有效的译文。")
        #expect(sink.finals.first?.2 == true)
        #expect(events(log, "mt.fail").first?["reason"] as? String == "empty")
        #expect(events(log, "mt.final").first?["engine"] as? String == "apple")
        await pipeline.stop()
    }

    @Test func latePrimaryFallsBackToAppleWithApproxAndIsCancelled() async throws {
        let primary = FakeMT("openai", placement: .network, prefix: "云", delayMs: 2000)
        let apple = FakeMT("apple", placement: .systemService, prefix: "苹", delayMs: 10)
        let (p, s, sink, log) = try make(primary: primary, apple: apple, deadlineMs: 250)
        try await p.start()
        let t0 = ContinuousClock.now
        s.final("Let us begin.")
        #expect(await until { sink.finals.count == 1 })
        let waited = ContinuousClock.now - t0
        #expect(waited >= .milliseconds(240) && waited < .milliseconds(1500))
        #expect(sink.finals[0].1 == "苹:Let us begin." && sink.finals[0].2 == true)
        #expect(await primary.cancels.count == 1)
        #expect(events(log, "mt.late").count == 1)
        await p.stop()
    }

    @Test func noPrimaryMeansAppleFinalsWithApprox() async throws {
        let apple = FakeMT("apple", placement: .systemService, prefix: "苹", delayMs: 5)
        let (p, s, sink, _) = try make(primary: nil, apple: apple)
        try await p.start()
        s.final("Good morning.")
        #expect(await until { sink.finals.count == 1 })
        #expect(sink.finals[0].1 == "苹:Good morning." && sink.finals[0].2 == true)
        await p.stop()
    }

    @Test func noAppleEitherShowsTheSource() async throws {
        let (p, s, sink, _) = try make(primary: nil, apple: nil)
        try await p.start()
        s.final("Good morning.")
        #expect(await until { sink.finals.count == 1 })
        #expect(sink.finals[0].1 == "Good morning." && sink.finals[0].2 == true)
        await p.stop()
    }

    @Test func draftsAppearForTheOpenSentenceAndSourceLineFollows() async throws {
        let apple = FakeMT("apple", placement: .systemService, prefix: "苹", delayMs: 5)
        let (p, s, sink, _) = try make(primary: nil, apple: apple)
        try await p.start()
        s.volatile("we need to")
        #expect(await until { sink.items.contains(.source("we need to")) })
        s.volatile("we need to decide")
        #expect(await until { !sink.drafts.isEmpty })
        #expect(sink.drafts.last == "苹:we need to")
        await p.stop()
    }

    @Test func silenceTriggersFinalizeThroughTheStream() async throws {
        let apple = FakeMT("apple", placement: .systemService, prefix: "苹", delayMs: 5)
        let (p, s, sink, _) = try make(primary: nil, apple: apple)
        try await p.start()
        s.volatile("this is it")
        #expect(await until { await p.openSentence == 1 && sink.items.contains(.source("this is it")) })
        // No audio was pushed: the ingest reports long silence, so the next tick fires `silence`.
        await p.tick()
        #expect(await until { s.finalizes.count == 1 })
        s.final("This is it.")
        #expect(await until { sink.finals.count == 1 })
        await p.stop()
    }

    @Test func echoOfOurOwnSpeechIsDropped() async throws {
        let apple = FakeMT("apple", placement: .systemService, prefix: "苹", delayMs: 5)
        let (p, s, sink, log) = try make(primary: nil, apple: apple)
        try await p.start()
        let now = HostClock.now()
        await p.recordPlayed(text: "We will ship the release on Monday", startHost: now - 3_000_000_000, endHost: now)
        s.final("We will ship the release on Monday.")
        #expect(await until { sink.items.contains { if case .dropped = $0 { true } else { false } } })
        #expect(sink.finals.isEmpty)
        #expect(events(log, "listen.echo_drop").count == 1)
        await p.stop()
    }

    @Test func liveOriginalEchoRejectsDelayedDraftsAndFinalsWithoutMutingRemoteSpeech() async throws {
        let origin = HostClock.now()
        let time = Mutex(origin)
        func at(_ milliseconds: UInt64) -> HostTime {
            let next = origin + milliseconds * 1_000_000
            time.withLock { $0 = next }
            return next
        }
        let apple = FakeMT("apple", placement: .systemService, prefix: "译", delayMs: 40)
        let stream = FakeStream(), sink = Sink(), log = EventLog(inMemory: { time.withLock { $0 } })
        let p = ListenPipeline(lang: .en, profile: try Fixture.listen(),
            engines: .init(asr: FakeASR(stream: stream), apple: apple, primary: nil),
            log: log, tickMs: 100_000, clock: { time.withLock { $0 } }, onUpdate: { sink.add($0) })
        try await p.start()
        let own = "this is my original microphone speech"
        let ownEnd = at(1000)
        await p.recordPassthrough(startHost: origin, endHost: ownEnd) // still open
        await p.setEchoScore(0.95, at: ownEnd)
        _ = at(1800) // Qwen returns after its audio boundary; current-score freshness is insufficient.
        await p.onVolatile(own, through: ownEnd)
        await p.onVolatile(own, through: ownEnd)
        #expect(await apple.requests.isEmpty)
        #expect(!sink.items.contains(.source(own)))
        #expect(sink.drafts.isEmpty)

        let close = origin + 1100_000_000
        await p.recordPassthrough(startHost: origin, endHost: close)
        await p.setEchoScore(0, at: at(3500))
        await p.onFinal(own + ".", range: origin...close)
        await p.onFinal(own + ".", range: origin...close) // duplicate old final cannot enter sentence 2
        #expect(await p.openSentence == 2)
        #expect(sink.finals.isEmpty)
        #expect(events(log, "listen.echo_drop").count == 1)

        let remote = "the remote participant can still speak"
        let nextOpen = at(4000)
        await p.recordPassthrough(startHost: nextOpen, endHost: nextOpen)
        await p.setEchoScore(0.1, at: nextOpen)
        await p.onVolatile(remote, through: nextOpen)
        await p.onVolatile(remote, through: nextOpen)
        let remoteDraft = await until { !sink.drafts.isEmpty }
        #expect(remoteDraft && sink.items.contains(.source(remote)))
        let remoteEnd = at(4100)
        await p.onFinal(remote + ".", range: nextOpen...remoteEnd)
        let remoteFinal = await until { sink.finals.count == 1 }
        #expect(remoteFinal)

        // Evidence arriving after a provisional result cancels the already queued Apple job.
        let pending = "more original microphone words still returning"
        let pendingStart = at(5000)
        await p.recordPassthrough(startHost: nextOpen, endHost: pendingStart)
        await p.setEchoScore(nil, at: pendingStart)
        await p.onVolatile(pending, through: pendingStart)
        await p.onVolatile(pending, through: pendingStart)
        let draftStarted = await until { await apple.requests.contains { $0.text == pending && !$0.isFinalChunk } }
        #expect(draftStarted)
        let draft = try #require(await apple.requests.last { $0.text == pending && !$0.isFinalChunk })
        let pendingEnd = at(5100)
        await p.onVolatile(pending, through: pendingEnd)
        await p.setEchoScore(0.95, at: pendingEnd)
        let draftCancelled = await until { await apple.cancels.contains(draft.job) }
        #expect(draftCancelled && sink.items.contains(.dropped(sentence: 3)))
        await p.recordPassthrough(startHost: nextOpen, endHost: pendingEnd)
        await p.setEchoScore(nil, at: at(8200))
        await p.onFinal(pending + ".", range: pendingStart...pendingEnd)
        #expect(events(log, "listen.echo_drop").count == 2)
        #expect(await p.openSentence == 4)

        // An unrelated remote sentence after raw-close is not dropped by later high correlation.
        let afterClose = at(9000)
        await p.setEchoScore(0.95, at: afterClose)
        await p.onFinal("A fresh remote sentence after the original path closed.", range: afterClose...afterClose)
        let afterCloseFinal = await until { sink.finals.count == 2 }
        #expect(afterCloseFinal)
        #expect(await apple.requests.filter { $0.isFinalChunk && ($0.text == own + "." || $0.text == pending + ".") }.isEmpty)
        await p.stop()
    }

    @Test func numberMismatchIsFlagged() async throws {
        let apple = FakeMT("apple", placement: .systemService, prefix: "", delayMs: 5, fixed: "预算是3万欧元。")
        let (p, s, sink, _) = try make(primary: nil, apple: apple)
        try await p.start()
        s.final("The budget is 300,000 euros.")
        #expect(await until { sink.finals.count == 1 })
        #expect(sink.finals[0].3 == true)
        await p.stop()
    }

    @Test func eventLogHoldsNoText() async throws {
        let primary = FakeMT("openai", placement: .network, prefix: "云", delayMs: 10)
        let apple = FakeMT("apple", placement: .systemService, prefix: "苹", delayMs: 5)
        let (p, s, sink, log) = try make(primary: primary, apple: apple)
        try await p.start()
        s.volatile("secret plan alpha")
        s.volatile("secret plan alpha bravo")
        s.final("Secret plan alpha bravo.")
        #expect(await until { sink.finals.count == 1 })
        await p.stop()
        let dump = String(describing: log.recorded)
        #expect(!dump.contains("secret") && !dump.contains("Secret") && !dump.contains("云"))
    }
}

@Suite struct AudioIngestTests {
    @Test func silenceCountsFromTheLastVoicedChunkAndFeedsTheStream() {
        let ing = AudioIngest()
        let s = FakeStream()
        ing.attach(s)
        let t0: HostTime = 10_000_000_000
        #expect(ing.silenceMs(now: t0) > 1_000_000)
        // A voiced harmonic envelope, rather than DC (which real libfvad need not call speech).
        let voiced: [Float] = (0..<1600).map { i in
            let t = Double(i) / 16_000
            var sample = 0.0
            for h in 1...25 {
                let frequency = 140 * Double(h)
                let formant = exp(-pow((frequency - 700) / 250, 2))
                    + 0.6 * exp(-pow((frequency - 1200) / 300, 2))
                    + 0.3 * exp(-pow((frequency - 2500) / 400, 2))
                sample += formant * sin(2 * .pi * frequency * t)
            }
            return Float(0.15 * sample * (0.6 + 0.4 * sin(2 * .pi * 4 * t)))
        }
        ing.push(voiced, host: t0)
        let initialSilence = ing.silenceMs(now: t0 + 100_000_000)
        #expect(initialSilence >= 0 && initialSilence < 100)
        ing.push([Float](repeating: 0, count: 1600), host: t0 + 100_000_000)
        // Classification is per 20 ms frame; subsequent silence must advance the same clock.
        #expect(ing.silenceMs(now: t0 + 600_000_000) == initialSilence + 500)
        #expect(s.fed == 3200)
    }

    @Test func clipCutsTheRingByHostTime() throws {
        let ing = AudioIngest(ringSeconds: 1)
        let t0: HostTime = 1_000_000_000
        for i in 0..<20 {   // 2 s of 100 ms chunks, value = chunk index
            ing.push([Float](repeating: Float(i), count: 1600), host: t0 + HostTime(i) * 100_000_000)
        }
        #expect(ing.clip(from: t0, to: t0 + 200_000_000) == nil)          // fell out of the 1 s ring
        let c = try #require(ing.clip(from: t0 + 1_550_000_000, to: t0 + 1_750_000_000))
        #expect(c.samples.count == 3200)
        #expect(c.samples.first == 15 && c.samples.last == 17)
        #expect(c.start == t0 + 1_550_000_000)
    }
}

@Suite struct MeetingAutoEndTests {
    @Test func asksAfterTenQuietMinutesThenEndsSixtySecondsLater() {
        var a = MeetingAutoEnd()
        #expect(a.observe(nowMs: 0, anyAudio: true) == .ok)
        #expect(a.observe(nowMs: 1000, anyAudio: false) == .ok)
        #expect(a.observe(nowMs: 600_999, anyAudio: false) == .ok)
        #expect(a.observe(nowMs: 601_000, anyAudio: false) == .ask)
        #expect(a.observe(nowMs: 660_999, anyAudio: false) == .ok)
        #expect(a.observe(nowMs: 661_000, anyAudio: false) == .end)
    }

    @Test func audioOrTheUserCancelsTheQuestion() {
        var a = MeetingAutoEnd()
        _ = a.observe(nowMs: 0, anyAudio: false)
        #expect(a.observe(nowMs: 600_000, anyAudio: false) == .ask)
        #expect(a.observe(nowMs: 610_000, anyAudio: true) == .ok)
        #expect(!a.asking)
        _ = a.observe(nowMs: 620_000, anyAudio: false)
        #expect(a.observe(nowMs: 1_220_000, anyAudio: false) == .ask)
        a.stillInMeeting(nowMs: 1_230_000)
        #expect(a.observe(nowMs: 1_300_000, anyAudio: false) == .ok)
        #expect(a.observe(nowMs: 1_830_000, anyAudio: false) == .ask)
    }
}

@Suite struct SubtitleBoardTests {
    @Test func meetingRetentionKeepsCompletePairsAndPendingRemainsBounded() {
        let policy = SubtitleRetentionPolicy(windowNs: 60_000_000_000, maxSegments: 3, maxCharacters: 40)
        var board = SubtitleBoard(maxCharactersPerSecond: 9, retention: policy)
        for id in 1...4 {
            board.apply(.final(sentence: UInt64(id), text: "译\(id)", source: "源\(id)",
                               approx: false, numberWarning: false), at: UInt64(id - 1) * 2_000_000_000)
        }
        #expect(board.finals.map(\.sentence) == [2, 3, 4])
        _ = board.advance(at: 63_000_000_000)
        #expect(board.finals.map(\.source) == ["源2", "源3", "源4"]) // silence alone never expires text
        board.apply(.final(sentence: 4, text: "修订译文", source: "修订原文", approx: true,
                           numberWarning: true), at: 64_000_000_000)
        board.apply(.final(sentence: 5, text: "新译文", source: "新原文", approx: false,
                           numberWarning: false), at: 70_000_000_000)
        #expect(board.finals.map(\.sentence) == [5]) // a revision did not renew sentence 4's receipt time
        let longSource = String(repeating: "源", count: 45)
        board.apply(.final(sentence: 6, text: "完整译文", source: longSource, approx: false,
                           numberWarning: false), at: 72_000_000_000)
        #expect(board.finals.count == 1 && board.finals[0].source == longSource)
        #expect(board.finals[0].text == "完整译文") // even an oversized newest pair is not cut in half

        var paced = SubtitleBoard(maxCharactersPerSecond: 9, retention: .meeting)
        for id in 1...5 {
            paced.apply(.final(sentence: UInt64(id), text: String(repeating: "长", count: 90),
                               source: "source \(id)", approx: false, numberWarning: false),
                        at: UInt64(id - 1) * 100_000_000)
        }
        #expect(paced.finals.map(\.sentence) == [1, 2])
        #expect(paced.pendingFinalSentenceIDs == [4, 5]) // 24 history slots are not pending slots
    }

    @Test func thirdFinalWaitsOnlyForTheOldestVisibleLine() {
        var board = SubtitleBoard(maxCharactersPerSecond: 9)
        board.apply(.final(sentence: 1, text: "一二三四五六七八九", approx: false, numberWarning: false), at: 0)
        let longSecond = String(repeating: "长", count: 90)
        board.apply(.final(sentence: 2, text: longSecond, approx: false, numberWarning: false), at: 100_000_000)
        #expect(board.finals.map(\.sentence) == [1, 2]) // the second slot is free
        #expect(board.pendingFinalSentenceIDs.isEmpty)

        board.apply(.final(sentence: 2, text: longSecond + "。", approx: false, numberWarning: false), at: 150_000_000)
        #expect(board.finals.last?.text == longSecond + "。") // same-line correction is immediate
        board.apply(.final(sentence: 3, text: "第三句", approx: false, numberWarning: false), at: 200_000_000)
        #expect(board.pendingFinalSentenceIDs == [3])
        let early = board.advance(at: 999_000_000)
        #expect(!early)
        let ready = board.advance(at: 1_000_000_000)
        #expect(ready)
        #expect(board.finals.map(\.sentence) == [2, 3]) // keep the still-reading second line
    }

    @Test func finalReplacesDraftImmediatelyAndCreditsItsVisiblePrefix() {
        var board = SubtitleBoard(maxCharactersPerSecond: 9)
        board.apply(.draft(sentence: 1, text: "一二三四五六七八九"), at: 0)
        #expect(board.draft?.sentence == 1)

        // A final arriving during the draft's one-second reading interval is ready to show.
        board.apply(.final(sentence: 1, text: "一二三四五六七八九十", source: "First sentence.",
                           approx: false, numberWarning: false), at: 100_000_000)
        #expect(board.finals.first?.text == "一二三四五六七八九十")
        #expect(board.draft == nil && board.pendingFinalSentenceIDs.isEmpty)

        // A second final uses the free slot. Only a third one evicts the first line, whose
        // already visible prefix is not charged again; its new tenth character keeps its budget.
        board.apply(.final(sentence: 2, text: "下一句", approx: false, numberWarning: false), at: 150_000_000)
        #expect(board.finals.map(\.sentence) == [1, 2])
        board.apply(.final(sentence: 3, text: "第三句", approx: false, numberWarning: false), at: 200_000_000)
        let beforeReadingTime = board.advance(at: 211_000_000)
        #expect(!beforeReadingTime)
        let afterReadingTime = board.advance(at: 212_000_000)
        #expect(afterReadingTime)
        #expect(board.finals.map(\.sentence) == [2, 3])
    }

    @Test func finalsStayInSentenceOrderAndKeepTheLastTwo() {
        var b = SubtitleBoard()
        b.apply(.final(sentence: 2, text: "二", approx: false, numberWarning: false))
        b.apply(.final(sentence: 1, text: "一", approx: true, numberWarning: false))   // a slow cloud reply
        b.apply(.final(sentence: 3, text: "三", approx: false, numberWarning: true))
        #expect(b.finals.map(\.sentence) == [2, 3])
        #expect(b.finals.map(\.display) == ["二", "三  ⚠︎数字待核"])
        b.apply(.final(sentence: 4, text: "四", approx: true, numberWarning: false))
        #expect(b.finals.last?.display == "≈ 四")
    }

    @Test func bilingualFinalsStayPairedAcrossDraftsPacingAndCorrections() {
        var board = SubtitleBoard(maxCharactersPerSecond: 9)
        board.apply(.final(sentence: 1, text: "明天见", source: "See you tomorrow.", approx: false, numberWarning: false), at: 0)
        board.apply(.source("Wir besprechen den Plan."), at: 100_000_000)
        board.apply(.draft(sentence: 2, text: "我们讨论计划"), at: 150_000_000)
        board.apply(.final(sentence: 2, text: "我们讨论计划。", source: "Wir besprechen den Plan.", approx: false, numberWarning: false), at: 200_000_000)
        #expect(board.finals.first?.source == "See you tomorrow.")
        _ = board.advance(at: 2_000_000_000)
        #expect(board.finals.map(\.source) == ["See you tomorrow.", "Wir besprechen den Plan."])
        board.apply(.final(sentence: 2, text: "我们讨论新计划。", source: "Wir besprechen den neuen Plan.", approx: true, numberWarning: false), at: 4_000_000_000)
        board.apply(.source("Next topic."), at: 4_100_000_000)
        #expect(board.finals.last?.source == "Wir besprechen den neuen Plan.")
        #expect(board.finals.last?.text == "我们讨论新计划。")
        board.apply(.final(sentence: 3, text: "下个话题。", source: "Next topic.", approx: false, numberWarning: false), at: 6_000_000_000)
        #expect(board.finals.map(\.sentence) == [2, 3])
        #expect(board.finals.map(\.source) == ["Wir besprechen den neuen Plan.", "Next topic."])
    }

    @Test func draftBelongsToTheOpenSentenceOnly() {
        var b = SubtitleBoard()
        b.apply(.draft(sentence: 1, text: "草稿一"))
        #expect(b.draft?.text == "草稿一")
        b.apply(.final(sentence: 1, text: "定稿一", approx: false, numberWarning: false))
        #expect(b.draft == nil)
        // A late draft for a frozen sentence never comes back.
        #expect(b.apply(.draft(sentence: 1, text: "迟到的草稿")) == false)
        b.apply(.draft(sentence: 2, text: "草稿二"))
        b.apply(.dropped(sentence: 2))
        #expect(b.draft == nil)
    }

    @Test func sourceLineSurvivesTheEmptyResetBetweenSentences() {
        var b = SubtitleBoard()
        b.apply(.source("we need to decide"))
        #expect(b.apply(.source("")) == false)
        #expect(b.source == "we need to decide")
        b.apply(.source("next"))
        #expect(b.source == "next")
    }
}

/// A primary MT that can be taken offline: offline it fails at once, like OpenAIMT with no route
/// (URLError → MTError.cloudUnavailable).
actor SwitchableMT: MTEngine {
    nonisolated let id = EngineID(name: "openai", revision: "test", placement: .network)
    private(set) var online = true
    private(set) var calls = 0
    func setOnline(_ on: Bool) { online = on }
    func translate(_ r: MTRequest) async throws -> MTResult {
        calls += 1
        guard online else { throw MTError.cloudUnavailable("offline") }
        try await Task.sleep(for: .milliseconds(20))
        let now = HostClock.now()
        return MTResult(text: "云:\(r.text)", tokens: 1, reasoningTokens: 0, engine: id,
                        hedge: HedgeOutcome(fired: false, winner: .A, reason: nil, ms: 20),
                        timing: StageTiming(received: now, started: now, firstOutput: now, finished: now))
    }
    func setContext(_ s: MTSession, glossary: [GlossaryEntry]) async throws {}
    func cancel(_ job: JobID) async {}
}

@Suite struct OfflineFallbackTests {
    @Test func offlineFallsBackAtOnceAndRecovers() async throws {
        let primary = SwitchableMT()
        let apple = FakeMT("apple", placement: .systemService, prefix: "苹", delayMs: 30)
        let stream = FakeStream(), sink = Sink(), log = EventLog(inMemory: HostClock.now)
        let statuses = Statuses()
        // The real 1.5 s deadline: an offline primary must not make the subtitle wait for it.
        let p = ListenPipeline(lang: .de, profile: try Fixture.listen(deadlineMs: 1500),
                               engines: .init(asr: FakeASR(stream: stream), apple: apple, primary: primary),
                               log: log, tickMs: 100_000, onUpdate: { sink.add($0) },
                               onTranslation: { statuses.add($0) })
        try await p.start()

        do {   // online
            stream.final("Guten Morgen.")
            #expect(await until { sink.finals.count == 1 })
            #expect(sink.finals[0].1 == "云:Guten Morgen." && sink.finals[0].2 == false)
        }
        await primary.setOnline(false)
        let t0 = ContinuousClock.now
        stream.final("Das Netz ist weg.")
        #expect(await until(1000) { sink.finals.count == 2 })
        #expect(ContinuousClock.now - t0 < .seconds(1))                 // §14: ≤ 1 s to the Apple final
        #expect(sink.finals[1].1 == "苹:Das Netz ist weg." && sink.finals[1].2 == true)
        let fail = log.recorded.first { ($0["ev"] as? String) == "mt.fail" }
        #expect(fail?["reason"] as? String == "cloud:offline")

        await primary.setOnline(true)
        stream.final("Jetzt wieder da.")
        #expect(await until { sink.finals.count == 3 })
        #expect(sink.finals[2].1 == "云:Jetzt wieder da." && sink.finals[2].2 == false)
        let reqs = await primary.calls
        #expect(reqs == 3)
        // Review fix: the menu follows the actual source of the finals, changes only.
        #expect(statuses.items == [.openAI, .appleFallback(reason: "offline"), .openAI])
        await p.stop()
    }

    @Test func noPrimaryReportsAppleOnly() async throws {
        let stream = FakeStream(), statuses = Statuses()
        let p = ListenPipeline(lang: .en, profile: try Fixture.listen(),
                               engines: .init(asr: FakeASR(stream: stream), apple: nil, primary: nil),
                               log: EventLog(inMemory: HostClock.now), tickMs: 100_000, onUpdate: { _ in },
                               onTranslation: { statuses.add($0) })
        try await p.start()
        #expect(statuses.items == [.appleOnly])
        await p.stop()
    }
}

final class Statuses: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [ListenTranslation] = []
    func add(_ t: ListenTranslation) { lock.withLock { _items.append(t) } }
    var items: [ListenTranslation] { lock.withLock { _items } }
}

@Suite struct MeetingLifecycleTests {
    @Test func sleepThenWakeWithAudioResumes() {
        var l = MeetingLifecycle()
        #expect(l.suspend(.sleep) == .suspend)
        #expect(l.isSuspended)
        #expect(l.clear(.sleep, meetingHasAudio: true) == .resume(afterSleep: true))
        #expect(!l.isSuspended)
    }

    @Test func wakeWithoutMeetingAudioEnds() {
        var l = MeetingLifecycle()
        _ = l.suspend(.lock)
        #expect(l.clear(.lock, meetingHasAudio: false) == .end)
    }

    /// The lid closes on a locked screen: wake alone is not enough, unlock resumes.
    @Test func wakeToALockedScreenWaitsForUnlock() {
        var l = MeetingLifecycle()
        #expect(l.suspend(.lock) == .suspend)
        #expect(l.suspend(.sleep) == .none)
        #expect(l.clear(.sleep, meetingHasAudio: true) == .none)
        #expect(l.isSuspended)
        #expect(l.clear(.lock, meetingHasAudio: true) == .resume(afterSleep: true))
    }

    /// Review fix: lock → sleep → wake → unlock still reports the sleep (didWake for OpenAIMT);
    /// a lock alone does not, and the flag does not leak into the next suspension.
    @Test func lockSleepWakeUnlockResumesAfterSleep() {
        var l = MeetingLifecycle()
        _ = l.suspend(.lock)
        _ = l.suspend(.sleep)                 // no event: already suspended
        #expect(l.clear(.sleep, meetingHasAudio: true) == .none)
        #expect(l.clear(.lock, meetingHasAudio: true) == .resume(afterSleep: true))
        _ = l.suspend(.lock)
        #expect(l.clear(.lock, meetingHasAudio: true) == .resume(afterSleep: false))
    }

    @Test func clearingAReasonThatWasNeverSetDoesNothing() {
        var l = MeetingLifecycle()
        #expect(l.clear(.session, meetingHasAudio: false) == .none)
        _ = l.suspend(.session)
        #expect(l.clear(.sleep, meetingHasAudio: false) == .none)
        #expect(l.isSuspended)
    }
}
