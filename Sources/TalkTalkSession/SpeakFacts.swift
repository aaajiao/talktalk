import TalkTalkAudio
import TalkTalkCore

/// One interpretation of the live facts for the key runtime and passthrough gate. No IO.
public struct SpeakFacts: Sendable {
    public let pushToTalkAvailable: Bool
    /// Local phone practice/preparation can capture speech before Phone starts reading input.
    /// This never changes the actual facts used by the original-audio gate.
    public let allowsPhoneLocalSpeech: Bool
    public let passthrough: PassthroughPolicy.Facts
    public let passthroughKey: ModifierKey

    public init(meetingState: MeetingSession.State, micGuard: MeetingMicGuardPlan.State,
                route: OutputRouteProbe.State, passthroughEnabled: Bool,
                mode: MeetingMode = .meeting, phoneLocalReady: Bool = false,
                passthroughKey: ModifierKey = .rightCommand, physicalMicPassesRule2: Bool?,
                tapHealthy: Bool?, secureInput: Bool?, pushToTalkActive: Bool?, selfTestRunning: Bool?) {
        let running: Bool
        if case .running = meetingState { running = true } else { running = false }
        self.passthroughKey = passthroughKey
        allowsPhoneLocalSpeech = mode == .phone && phoneLocalReady && micGuard.verdict == .noReader
        let readerAllowsSpeech = mode == .phone ? micGuard.verified : micGuard.allowsPushToTalk
        pushToTalkAvailable = running && (allowsPhoneLocalSpeech || readerAllowsSpeech)
            && physicalMicPassesRule2 == true && tapHealthy == true
            && secureInput == false && selfTestRunning == false
        passthrough = .init(meetingModeActive: running,
                            settingEnabled: passthroughEnabled && (passthroughKey == .rightCommand || passthroughKey == .rightControl),
                            micGuard: micGuard.micGuard, speakerMode: route.speakerMode,
                            tapHealthy: tapHealthy, awaitingAudioConfirmation: micGuard.awaitingConfirmation,
                            secureInput: secureInput, pushToTalkActive: pushToTalkActive,
                            selfTestRunning: selfTestRunning, physicalMicPassesRule2: physicalMicPassesRule2)
    }
}
