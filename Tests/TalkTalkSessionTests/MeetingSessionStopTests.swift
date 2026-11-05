import Foundation
import Testing
@testable import TalkTalkCore
@testable import TalkTalkSession

/// Review fix: two stops racing (the user and auto end, or a stop after sleep) end meeting mode
/// once: one `.ended`, one end question, no stale events into the shared hub.
@MainActor
@Suite struct MeetingSessionStopTests {
    @Test func concurrentStopsEndOnce() async throws {
        let profile = try PolicyProfile.load(from: Fixture.repoRoot.appendingPathComponent("Resources/PolicyProfile.default.json"))
        let events = MeetingEvents()
        var ended: [MeetingSession.EndReason] = []
        var states: [MeetingSession.State] = []
        let sub = events.subscribe { e in
            switch e {
            case let .ended(r): ended.append(r)
            case let .state(s): states.append(s)
            default: break
            }
        }
        let s = MeetingSession(profile: profile, makeEngines: { _, _, _ in fatalError("not started") }, events: events,
                               onSubtitle: { _ in })
        let pipeline = ListenPipeline(lang: .en, profile: profile.listen,
                                      engines: .init(asr: FakeASR(stream: FakeStream()), apple: nil, primary: nil),
                                      log: EventLog(inMemory: HostClock.now), tickMs: 100_000, onUpdate: { _ in })
        try await pipeline.start()
        s.runForTesting(app: "Zoom", pipeline: pipeline)

        async let a: Void = s.stop(.user)
        async let b: Void = s.stop(.autoEnd)
        _ = await (a, b)
        await s.stop(.failed)                         // after the end: nothing

        #expect(ended.count == 1)
        #expect(states.filter { if case .ended = $0 { true } else { false } }.count == 1)
        #expect(s.state == .idle)
        _ = sub
    }
}
