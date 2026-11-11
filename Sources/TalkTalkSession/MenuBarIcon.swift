// l10n: zh-Hans (scripts/check-strings.sh)
import TalkTalkAudio
import TalkTalkCore

/// The menu bar icon (ARCHITECTURE.md, "三种使用场景") from what is true now. Pure. A meeting
/// app that reads the physical microphone (the other party hears the original voice) comes
/// first, as in the titlebar's risk capsule; then the open microphone, conditions needing
/// attention, speech, preparation and a meeting's degraded parts. Last-run default-input
/// leftovers remain visible outside meetings.
public enum MenuBarIcon: Sendable, Equatable, CaseIterable {
    case missing, standby, warming, listening, speaking, passthroughOpen, audioNeedsCheck, degraded, needsAttention
    /// The other party hears the original voice (micGuard: physical microphone).
    case remoteHearsOriginal

    /// The status item's glyph. `missing` shares the standby bubble and is drawn dimmed;
    /// `remoteHearsOriginal` is the titlebar's risk glyph (drawn with its fallback badge where
    /// the system lacks `mic.badge.exclamationmark`).
    public var symbol: String {
        typealias I = SubtitleTokens.MenuIcon
        return switch self {
        case .missing, .standby: I.standby
        case .warming: I.warming
        case .listening: I.listening
        case .speaking: SubtitleTokens.VoiceIcon.translating
        case .passthroughOpen: SubtitleTokens.VoiceIcon.original
        case .audioNeedsCheck: I.audioUnconfirmed
        case .degraded: I.degraded
        case .needsAttention: I.needsAttention
        case .remoteHearsOriginal: SubtitleTokens.VoiceIcon.originalRisk
        }
    }

    /// The short status word (settings visual system §8.5): the status item's tooltip and
    /// VoiceOver description, and the menu's status line when no problem row explains the icon.
    public func statusText(mode: MeetingMode) -> String {
        switch self {
        case .missing: String(appLocalized: "组件未就绪")
        case .standby: String(appLocalized: "待机 · 尚未开始收听")
        case .warming: String(appLocalized: "准备中")
        case .listening: String(appLocalized: "\(mode.scene.title)运行中")
        case .speaking: String(appLocalized: "识别/播放译音")
        case .passthroughOpen: String(appLocalized: "原声中")
        case .audioNeedsCheck: String(appLocalized: "音频未就绪")
        case .degraded: String(appLocalized: "使用备用")
        case .needsAttention: String(appLocalized: "检查音频设备")
        case .remoteHearsOriginal: String(appLocalized: "对方能听到原声")
        }
    }

    public static func compute(meetingActive: Bool, systemInput: SystemInputSwitcher.Status,
                               translationDegraded: Bool, micGuard: MeetingMicGuardPlan.State = .init(),
                               mode: MeetingMode = .meeting,
                               phonePrepared: Bool = false,
                               talkTalkMicReadWhileInactive: Bool = false, componentsMissing: Bool = false,
                               listenReady: Bool = false,
                               warming: Bool = false, speaking: Bool = false, passthroughOpen: Bool = false,
                               speakerMode: Bool? = false, systemVoice: Bool = false,
                               speakTranslationDegraded: Bool = false,
                               asrFallback: Bool = false, asrFailed: Bool = false,
                               lastEndFailed: Bool = false) -> MenuBarIcon {
        // The other party hearing the raw microphone outranks everything, the open microphone
        // included: both draw a mic, so the open-mic fact stays visible.
        if meetingActive, mode.supportsSpeaking, case .physicalMic = micGuard.verdict { return .remoteHearsOriginal }
        // The open microphone is the most immediate privacy fact, including while closing down.
        if passthroughOpen { return .passthroughOpen }
        if !meetingActive && talkTalkMicReadWhileInactive { return .needsAttention }
        let waitingForPhone = waitsForPhone(mode: mode, phonePrepared: phonePrepared, micGuard: micGuard)
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
        if meetingActive, mode.supportsSpeaking, !waitingForPhone,
           micGuard.awaitingConfirmation || micGuard.verdict == nil || micGuard.micGuard == .noReaderOfTalkTalkMic {
            return .audioNeedsCheck
        }
        if speaking { return .speaking }
        // A running Apple LISTEN pipeline does not require the separately installed Qwen engine.
        // The caller confirms a ready pipeline, not merely a selected backend or active session.
        if componentsMissing && !(meetingActive && listenReady) { return .missing }
        if warming { return .warming }
        if inputDegraded { return .degraded }
        // The last session ended on an error: the menu's line in the same glyph and colour.
        guard meetingActive else { return lastEndFailed ? .degraded : .standby }
        let speakerNeedsCheck = speakerMode == true || (speakerMode == nil && !waitingForPhone)
        let voiceDegraded = mode.supportsSpeaking && (speakTranslationDegraded || systemVoice || speakerNeedsCheck)
        // 识别：Apple 备用 and 字幕识别出错 draw the same triangle as their menu lines.
        return translationDegraded || voiceDegraded || asrFallback || asrFailed ? .degraded : .listening
    }

    /// The status item's word when a failure, not a fallback, draws `.degraded`: that menu
    /// line's own words instead of 使用备用. nil otherwise.
    public static func failureText(_ icon: MenuBarIcon, meetingActive: Bool, mode: MeetingMode,
                                   asrFailed: Bool, lastEndFailed: Bool) -> String? {
        guard icon == .degraded else { return nil }
        if meetingActive { return asrFailed ? String(appLocalized: "字幕识别出错") : nil }
        return lastEndFailed ? String(appLocalized: "\(mode.scene.title)因错误已结束") : nil
    }

    /// A fact that turns the icon orange or red and has no menu line of its own: the meeting
    /// check, the default input and 字幕翻译 have theirs. The menu gives each its line, with the
    /// sentence in the tooltip and its fix (settings visual system §8.1).
    public enum Reason: Sendable, Equatable, CaseIterable {
        /// An app reads TalkTalk Mic while no session runs.
        case talkTalkMicReadWhileIdle
        /// 我说话's translation fell back to Apple.
        case speakTranslation
        /// The meeting plays through a speaker: 耳机译音 and the original-voice path are off.
        case speaker
        /// The meeting app's playback devices are not known yet.
        case playbackUnknown
        /// A voice profile exists, but the translated voice is the system voice (no engine).
        case systemVoice
    }

    /// The `Reason`s true now, from the same inputs as `compute`, whatever the icon shows.
    public static func reasons(meetingActive: Bool, micGuard: MeetingMicGuardPlan.State = .init(),
                               mode: MeetingMode = .meeting, phonePrepared: Bool = false,
                               talkTalkMicReadWhileInactive: Bool = false, speakerMode: Bool? = false,
                               systemVoice: Bool = false, speakTranslationDegraded: Bool = false) -> [Reason] {
        var reasons: [Reason] = []
        if !meetingActive && talkTalkMicReadWhileInactive { reasons.append(.talkTalkMicReadWhileIdle) }
        guard meetingActive, mode.supportsSpeaking else { return reasons }
        if speakTranslationDegraded { reasons.append(.speakTranslation) }
        if speakerMode == true {
            reasons.append(.speaker)
        } else if speakerMode == nil, !waitsForPhone(mode: mode, phonePrepared: phonePrepared, micGuard: micGuard) {
            reasons.append(.playbackUnknown)
        }
        if systemVoice { reasons.append(.systemVoice) }
        return reasons
    }

    /// A prepared Phone session deliberately waits without a microphone reader until dialing or
    /// answering. Only that exact fact is expected; unknown/physical input is not.
    private static func waitsForPhone(mode: MeetingMode, phonePrepared: Bool, micGuard: MeetingMicGuardPlan.State) -> Bool {
        mode == .phone && phonePrepared && micGuard.verdict == .noReader
    }
}
