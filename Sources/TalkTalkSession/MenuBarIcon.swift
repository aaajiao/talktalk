import TalkTalkAudio
import TalkTalkCore

/// The menu bar icon (ARCHITECTURE.md §11 菜单栏图标状态) from what is true now. Pure. The system
/// open microphone comes first, then conditions needing attention, speech, preparation and a
/// meeting's degraded parts. Last-run default-input leftovers remain visible outside meetings.
public enum MenuBarIcon: Sendable, Equatable {
    case missing, standby, warming, listening, speaking, passthroughOpen, audioNeedsCheck, degraded, needsAttention

    public static func compute(meetingActive: Bool, systemInput: SystemInputSwitcher.Status,
                               translationDegraded: Bool, micGuard: MeetingMicGuardPlan.State = .init(),
                               mode: MeetingMode = .meeting,
                               talkTalkMicReadWhileInactive: Bool = false, componentsMissing: Bool = false,
                               listenReady: Bool = false,
                               warming: Bool = false, speaking: Bool = false, passthroughOpen: Bool = false,
                               speakerMode: Bool? = false, systemVoice: Bool = false,
                               speakTranslationDegraded: Bool = false) -> MenuBarIcon {
        // The open microphone is the most immediate privacy fact, including while closing down.
        if passthroughOpen { return .passthroughOpen }
        if !meetingActive && talkTalkMicReadWhileInactive { return .needsAttention }
        if meetingActive, mode == .meeting, case .physicalMic = micGuard.verdict { return .needsAttention }
        var inputDegraded = false
        switch systemInput {
        case .pendingFromLastRun, .noRestoreTarget: return .needsAttention
        case .deferredOnPhysical(_, _, true): return .needsAttention
        // The default input is a physical mic macOS picked (Mic gone, switch back failed): degraded
        // whether or not a meeting runs (deferred has none; review of 9d9b3a4 #1).
        case .deferred, .deferredOnPhysical, .waitingForMic, .switchBackFailed: inputDegraded = true
        case .overridden: inputDegraded = meetingActive
        case .idle, .otherInstanceManages, .holding, .suspended: break
        }
        if meetingActive, mode == .meeting,
           micGuard.awaitingConfirmation || micGuard.verdict == nil || micGuard.micGuard == .noReaderOfTalkTalkMic {
            return .audioNeedsCheck
        }
        if speaking { return .speaking }
        // A running Apple LISTEN pipeline does not require the separately installed Qwen engine.
        // The caller confirms a ready pipeline, not merely a selected backend or active session.
        if componentsMissing && !(meetingActive && listenReady) { return .missing }
        if warming { return .warming }
        if inputDegraded { return .degraded }
        guard meetingActive else { return .standby }
        let voiceDegraded = mode == .meeting && (speakTranslationDegraded || systemVoice || speakerMode != false)
        return translationDegraded || voiceDegraded ? .degraded : .listening
    }
}
