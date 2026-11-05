import Testing
import TalkTalkAudio
import TalkTalkCore
@testable import TalkTalkSession

@Suite struct SpeakFactsTests {
    func facts(guardState: MeetingMicGuardPlan.State = .init(verdict: .green(appID: "zoom", app: "Zoom")),
               speaker: Bool? = false, enabled: Bool = true, mic: Bool? = true,
               tap: Bool? = true, secure: Bool? = false, active: Bool = true) -> SpeakFacts {
        SpeakFacts(meetingState: active ? .running(app: "Zoom") : .suspended(app: "Zoom"),
                   micGuard: guardState, route: .init(speakerMode: speaker), passthroughEnabled: enabled,
                   physicalMicPassesRule2: mic, tapHealthy: tap, secureInput: secure,
                   pushToTalkActive: false, selfTestRunning: false)
    }

    @Test func confirmedPhysicalAndKeyFactsControlAvailability() {
        #expect(facts().pushToTalkAvailable)
        #expect(PassthroughPolicy.evaluate(facts().passthrough) == .available)
        for f in [facts(guardState: .init(verdict: .physicalMic(appID: "zoom", app: "Zoom", device: "mic"))),
                  facts(guardState: .init(verdict: .green(appID: "zoom", app: "Zoom"), awaitingConfirmation: true)),
                  facts(mic: false), facts(tap: false), facts(secure: true), facts(active: false)] {
            #expect(!f.pushToTalkAvailable)
            #expect(!PassthroughPolicy.evaluate(f.passthrough).isAvailable)
        }
        // Speaker mode blocks raw audio, but translated push-to-talk remains usable.
        #expect(facts(speaker: true).pushToTalkAvailable)
        #expect(PassthroughPolicy.evaluate(facts(speaker: true).passthrough) == .unavailable(.speakerMode))
        #expect(!PassthroughPolicy.evaluate(facts(speaker: nil).passthrough).isAvailable)
        #expect(PassthroughPolicy.evaluate(facts(enabled: false).passthrough) == .unavailable(.settingOff))
    }
}
