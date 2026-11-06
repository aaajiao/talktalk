import Testing
import TalkTalkAudio
import TalkTalkCore
@testable import TalkTalkSession

@Suite struct SpeakFactsTests {
    func facts(guardState: MeetingMicGuardPlan.State = .init(verdict: .green(appID: "zoom", app: "Zoom")),
               speaker: Bool? = false, enabled: Bool = true, mic: Bool? = true,
               tap: Bool? = true, secure: Bool? = false, active: Bool = true,
               mode: MeetingMode = .meeting, phoneReady: Bool = false, selfTest: Bool? = false) -> SpeakFacts {
        SpeakFacts(meetingState: active ? .running(app: "Zoom") : .suspended(app: "Zoom"),
                   micGuard: guardState, route: .init(speakerMode: speaker), passthroughEnabled: enabled,
                   mode: mode, phoneLocalReady: phoneReady,
                   physicalMicPassesRule2: mic, tapHealthy: tap, secureInput: secure,
                   pushToTalkActive: false, selfTestRunning: selfTest)
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

    @Test func preparedPhoneAllowsLocalCaptureWithoutClaimingARemoteReader() {
        let waiting = MeetingMicGuardPlan.State(verdict: .noReader, awaitingConfirmation: true)
        let local = facts(guardState: waiting, speaker: nil, mode: .phone, phoneReady: true)
        #expect(local.allowsPhoneLocalSpeech && local.pushToTalkAvailable)
        #expect(local.passthrough.micGuard == .noReaderOfTalkTalkMic)
        #expect(local.passthrough.awaitingAudioConfirmation == true)
        #expect(local.passthrough.speakerMode == nil)
        #expect(!PassthroughPolicy.evaluate(local.passthrough).isAvailable)
        #expect(!facts(guardState: waiting, mode: .phone, phoneReady: false).pushToTalkAvailable)
        #expect(!facts(guardState: waiting, mode: .meeting, phoneReady: true).pushToTalkAvailable)
    }

    @Test func phoneLocalCaptureStillRequiresRealMicAndKeyReadiness() {
        let waiting = MeetingMicGuardPlan.State(verdict: .noReader, awaitingConfirmation: true)
        for unsafe in [facts(guardState: waiting, mic: false, mode: .phone, phoneReady: true),
                       facts(guardState: waiting, tap: false, mode: .phone, phoneReady: true),
                       facts(guardState: waiting, secure: true, mode: .phone, phoneReady: true),
                       facts(guardState: waiting, active: false, mode: .phone, phoneReady: true),
                       facts(guardState: waiting, mode: .phone, phoneReady: true, selfTest: true),
                       facts(guardState: .init(), mode: .phone, phoneReady: true),
                       facts(guardState: .init(verdict: .physicalMic(appID: MeetingMode.phoneAppID,
                                                                  app: "Phone", device: "Built-in")),
                             mode: .phone, phoneReady: true)] {
            #expect(!unsafe.pushToTalkAvailable)
        }
        #expect(facts(mode: .phone).pushToTalkAvailable) // Normal verified reader keeps its existing path.
    }
}
