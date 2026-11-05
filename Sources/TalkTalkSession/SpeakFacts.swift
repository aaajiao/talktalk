import TalkTalkAudio
import TalkTalkCore

/// One interpretation of the live facts for the key runtime and passthrough gate. No IO.
public struct SpeakFacts: Sendable {
    public let pushToTalkAvailable: Bool
    public let passthrough: PassthroughPolicy.Facts
    public let passthroughKey: ModifierKey

    public init(meetingState: MeetingSession.State, micGuard: MeetingMicGuardPlan.State,
                route: OutputRouteProbe.State, passthroughEnabled: Bool,
                passthroughKey: ModifierKey = .rightCommand, physicalMicPassesRule2: Bool?,
                tapHealthy: Bool?, secureInput: Bool?, pushToTalkActive: Bool?, selfTestRunning: Bool?) {
        let running: Bool
        if case .running = meetingState { running = true } else { running = false }
        self.passthroughKey = passthroughKey
        pushToTalkAvailable = running && micGuard.allowsPushToTalk
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
