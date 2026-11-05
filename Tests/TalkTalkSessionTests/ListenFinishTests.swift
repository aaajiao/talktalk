import Foundation
import Testing
import TalkTalkCore
@testable import TalkTalkSession

private actor ReopeningASR: StreamingASREngine {
    nonisolated let id = EngineID(name: "reopen", revision: "1", placement: .cpu)
    private(set) var streams: [FakeStream] = []
    func open(_ lang: Lang, highPriority: Bool) async throws -> any ASRStream {
        let stream = FakeStream(); streams.append(stream); return stream
    }
}

@Suite struct ListenFinishTests {
    @Test func gapReopensAnalyzerAndReplaysOnlyNewAudio() async throws {
        let engine = ReopeningASR(), sink = Sink(), ingest = AudioIngest()
        let p = ListenPipeline(lang: .en, profile: try Fixture.listen(), engines: .init(asr: engine, apple: nil, primary: nil),
                               log: EventLog(inMemory: HostClock.now), ingest: ingest, tickMs: 100_000, onUpdate: sink.add)
        try await p.start()
        let old = await engine.streams[0]
        await p.onVolatile("Words before the gap")
        ingest.push(Array(repeating: 0, count: 320), host: 1_000_000_000)
        #expect(ingest.prepareAnalyzerRestart(ifGapBefore: 4_000_000_000) == 2980)
        ingest.push(Array(repeating: 0, count: 320), host: 4_000_000_000)
        try await p.restartAnalyzer(afterGapMs: 2980)
        let opened = await engine.streams
        #expect(opened.count == 2)
        #expect(old.fed == 320)
        #expect(opened[1].fed == 320)
        #expect(await until { sink.finals.count == 1 })
        #expect(sink.finals.first?.1 == "Words before the gap")
        old.final("Late old analyzer text.")
        await p.onFinal("New analyzer text.", range: 4_000_000_000...4_020_000_000)
        #expect(await until { sink.finals.count == 2 })
        #expect(sink.finals.last?.0 == 2)
        await p.stop()
    }

    @Test func germanContinuationReplacesPreviousOnlyOnce() async throws {
        let sink = Sink(), stream = FakeStream()
        var profile = try Fixture.listen(); profile.deLookback.enabled = true
        let p = ListenPipeline(lang: .de, profile: profile, engines: .init(asr: FakeASR(stream: stream), apple: nil, primary: nil),
                               log: EventLog(inMemory: HostClock.now), tickMs: 100_000, onUpdate: sink.add)
        try await p.start()
        await p.onFinal("Wir fangen morgen.", range: 1...2)
        #expect(await until { sink.finals.count == 1 })
        await p.onFinal("an.", range: 3...4)
        #expect(await until { sink.finals.count == 2 })
        #expect(sink.finals[1].0 == 1)
        #expect(sink.finals[1].1 == "Wir fangen morgen an.")
        await p.onFinal("auf.", range: 5...6)
        #expect(await until { sink.finals.count == 3 })
        #expect(sink.finals[2].0 == 3)
        await p.stop()
    }

    @Test func choosingAppleCancelsOnlyThisListenRequestAndUsesReadyFallback() async throws {
        let sink = Sink(), stream = FakeStream()
        let cloud = FakeMT("cloud", placement: .network, prefix: "cloud", delayMs: 1000)
        let apple = FakeMT("apple", placement: .systemService, prefix: "apple", delayMs: 1)
        let p = ListenPipeline(lang: .en, profile: try Fixture.listen(deadlineMs: 2000),
            engines: .init(asr: FakeASR(stream: stream), apple: apple, primary: cloud),
            log: EventLog(inMemory: HostClock.now), tickMs: 100_000, onUpdate: sink.add)
        try await p.start()
        await p.onFinal("Switch this meeting to Apple.", range: 1...2)
        #expect(await until { await cloud.requests.count == 1 })
        await p.useAppleForThisMeeting()
        #expect(await until(300) { sink.finals.count == 1 })
        #expect(sink.finals[0].1.hasPrefix("apple:"))
        #expect(!(await cloud.cancels).isEmpty)
        await p.onFinal("The next sentence stays on Apple.", range: 3...4)
        #expect(await until { sink.finals.count == 2 })
        #expect(await cloud.requests.count == 1)
        await p.stop()
    }

    @Test func subtitlePacingBoundsBacklogAndClearsDrafts() {
        var board = SubtitleBoard(maxCharactersPerSecond: 9)
        board.apply(.final(sentence: 1, text: "一二三四五六七八九", approx: false, numberWarning: false), at: 0)
        board.apply(.final(sentence: 2, text: "下一句", approx: false, numberWarning: false), at: 100_000_000)
        board.apply(.final(sentence: 3, text: "第三句", approx: false, numberWarning: false), at: 200_000_000)
        board.apply(.final(sentence: 4, text: "第四句", approx: false, numberWarning: false), at: 300_000_000)
        board.apply(.final(sentence: 5, text: "第五句", approx: false, numberWarning: false), at: 400_000_000)
        #expect(board.finals.map(\.sentence) == [1, 2])
        #expect(board.pendingFinalSentenceIDs == [4, 5])
        let early = board.advance(at: 999_000_000); #expect(!early)
        let next = board.advance(at: 1_000_000_000); #expect(next)
        #expect(board.finals.map(\.sentence) == [2, 4])
        let last = board.advance(at: 1_001_000_000); #expect(last)
        #expect(board.finals.map(\.sentence) == [4, 5])
        board.clear()
        #expect(board.isEmpty)
        let cleared = board.advance(at: 10_000_000_000); #expect(!cleared)
    }

    @Test func observedSilenceAndEchoEvidenceExpire() async throws {
        let ingest = AudioIngest(), p = ListenPipeline(lang: .en, profile: try Fixture.listen(),
            engines: .init(asr: FakeASR(stream: FakeStream()), apple: nil, primary: nil),
            log: EventLog(inMemory: HostClock.now), ingest: ingest, tickMs: 100_000, onUpdate: { _ in })
        ingest.push(Array(repeating: 0, count: 320), host: 1_000_000_000)
        #expect(ingest.activity(at: 1_020_000_000).vadSpeech == false)
        #expect(ingest.activity(at: 1_300_000_000).vadSpeech == nil)
        await p.setEchoScore(0, at: 1_020_000_000)
        #expect(await p.echoScore(at: 1_100_000_000) == 0)
        #expect(await p.echoScore(at: 1_600_000_000) == nil)
    }
}
