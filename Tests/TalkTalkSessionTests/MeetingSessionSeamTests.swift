import Foundation
import Testing
import TalkTalkCore
@testable import TalkTalkSession

@MainActor
@Suite struct MeetingSessionSeamTests {
    @Test func echoAndRecentTextBelongToTheActiveSession() async throws {
        let profile = try PolicyProfile.load(from: Fixture.repoRoot.appendingPathComponent("Resources/PolicyProfile.default.json"))
        let stream = FakeStream(), sink = Sink()
        let p = ListenPipeline(lang: .en, profile: profile.listen,
                               engines: .init(asr: FakeASR(stream: stream), apple: nil, primary: nil),
                               log: EventLog(inMemory: HostClock.now), tickMs: 100_000, onUpdate: { sink.add($0) })
        let session = MeetingSession(profile: profile, makeEngines: { _, _, _ in fatalError("not started") }, onSubtitle: { _ in })
        try await p.start()
        session.runForTesting(app: "Zoom", pipeline: p)
        let now = HostClock.now()
        await session.recordPlayed(text: "We will ship the release on Monday", startHost: now - 1_000_000_000, endHost: now)
        stream.final("We will ship the release on Monday.")
        #expect(await until { @Sendable in sink.items.contains(.dropped(sentence: 1)) })
        await session.recordPassthrough(startHost: now, endHost: now)
        stream.final("The next question is about the budget.")
        #expect(await until { @Sendable in sink.finals.count == 1 })
        #expect(await session.recentRemoteText(withinS: 5) == ["The next question is about the budget."])
        await session.stop()
        #expect(await session.recentRemoteText(withinS: 5).isEmpty)
        #expect(session.remoteVADOverlap(from: now, to: now + 1_000_000) == nil)
    }

    @Test func aFinalReleasedDuringPlaybackIsRecognizedAsItsEcho() async throws {
        let profile = try PolicyProfile.load(from: Fixture.repoRoot.appendingPathComponent("Resources/PolicyProfile.default.json"))
        let stream = FakeStream(), sink = Sink()
        let p = ListenPipeline(lang: .en, profile: profile.listen,
                               engines: .init(asr: FakeASR(stream: stream), apple: nil, primary: nil),
                               log: EventLog(inMemory: HostClock.now), tickMs: 100_000, onUpdate: { sink.add($0) })
        let session = MeetingSession(profile: profile, makeEngines: { _, _, _ in fatalError("not started") }, onSubtitle: { _ in })
        try await p.start()
        session.runForTesting(app: "Zoom", pipeline: p)
        await session.recordPlaying(clause: 3, text: "We will ship the release on Monday", startHost: HostClock.now() - 1_000_000_000)
        stream.final("We will ship the release on Monday.")
        #expect(await until { @Sendable in sink.items.contains(.dropped(sentence: 1)) })
        await session.stopPlaying(clause: 3)
        stream.final("We will ship the release on Monday.")
        #expect(await until { @Sendable in sink.finals.count == 1 })
        await session.stop()
    }

    @Test func remoteVADRequiresCoverageAndMeasuresIntersection() {
        let ingest = AudioIngest()
        let start: HostTime = 1_000_000_000
        #expect(ingest.remoteVADOverlap(from: start, to: start + 40_000_000) == nil)
        ingest.push(Array(repeating: 0.2, count: 320), host: start)
        ingest.push(Array(repeating: 0, count: 320), host: start + 20_000_000)
        #expect(ingest.remoteVADOverlap(from: start, to: start + 40_000_000) == 0.5)
        #expect(ingest.remoteVADOverlap(from: start + 20_000_000, to: start + 40_000_000) == 0)
        ingest.push(Array(repeating: 0.2, count: 320), host: start + 60_000_000)
        #expect(ingest.remoteVADOverlap(from: start, to: start + 80_000_000) == nil)
    }
}
