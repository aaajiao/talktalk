import AppKit
import Testing
import TalkTalkCore
@testable import TalkTalkAudio
@testable import TalkTalkSession

/// Review fix: the icon shows §8.6's deferred (yellow) and last-run (red) states, and a meeting
/// whose finals fell back to Apple.
@Suite struct MenuBarIconTests {
    private var green: MeetingMicGuardPlan.State { .init(verdict: .green(appID: "test.call", app: "Call")) }
    @Test func captionsIgnoreSpeechOnlyWarnings() {
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .idle,
                                    translationDegraded: false, micGuard: .init(verdict: .noReader),
                                    mode: .captions, speakerMode: true, systemVoice: true,
                                    speakTranslationDegraded: true) == .listening)
        // Real recovery work still matters, even when only captions are running.
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .noRestoreTarget,
                                    translationDegraded: false, mode: .captions) == .needsAttention)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .idle,
                                    translationDegraded: false, mode: .captions,
                                    componentsMissing: true, listenReady: true) == .listening)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .idle,
                                    translationDegraded: false, mode: .captions,
                                    componentsMissing: true, listenReady: false) == .missing)
    }

    @Test func preparedPhoneCanWaitForACallWithoutAnAudioWarning() {
        let waiting = MeetingMicGuardPlan.State(verdict: .noReader, awaitingConfirmation: true)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .holding(original: "Built-in"),
                                   translationDegraded: false, micGuard: waiting, mode: .phone,
                                   phonePrepared: true, speakerMode: nil) == .listening)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .holding(original: "Built-in"),
                                   translationDegraded: false, micGuard: waiting, mode: .phone,
                                   phonePrepared: false, speakerMode: nil) == .audioNeedsCheck)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .holding(original: "Built-in"),
                                   translationDegraded: false, micGuard: waiting, mode: .meeting,
                                   phonePrepared: true, speakerMode: nil) == .audioNeedsCheck)
    }

    @Test func preparedPhoneStillReportsPhysicalUnknownAndBrokenInputRoutes() {
        let physical = MeetingMicGuardPlan.State(verdict: .physicalMic(appID: MeetingMode.phoneAppID,
                                                                       app: "Phone", device: "Built-in"))
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .holding(original: "Built-in"),
                                   translationDegraded: false, micGuard: physical, mode: .phone,
                                   phonePrepared: true, speakerMode: nil) == .remoteHearsOriginal)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .holding(original: "Built-in"),
                                   translationDegraded: false, micGuard: .init(), mode: .phone,
                                   phonePrepared: true, speakerMode: nil) == .audioNeedsCheck)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .overridden(by: "USB Mic"),
                                   translationDegraded: false, micGuard: .init(verdict: .noReader), mode: .phone,
                                   phonePrepared: true, speakerMode: nil) == .degraded)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .noRestoreTarget,
                                   translationDegraded: false, micGuard: .init(verdict: .noReader), mode: .phone,
                                   phonePrepared: true, speakerMode: nil) == .needsAttention)
    }

    @Test func waitingPhoneDoesNotHideOtherPreparationOrTranslationProblems() {
        let waiting = MeetingMicGuardPlan.State(verdict: .noReader)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .holding(original: "Built-in"),
                                   translationDegraded: true, micGuard: waiting, mode: .phone,
                                   phonePrepared: true, speakerMode: nil) == .degraded)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .holding(original: "Built-in"),
                                   translationDegraded: false, micGuard: waiting, mode: .phone,
                                   phonePrepared: true, componentsMissing: true, speakerMode: nil) == .missing)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .holding(original: "Built-in"),
                                   translationDegraded: false, micGuard: waiting, mode: .phone,
                                   phonePrepared: true, warming: true, speakerMode: nil) == .warming)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .holding(original: "Built-in"),
                                   translationDegraded: false, micGuard: waiting, mode: .phone,
                                   phonePrepared: true, speakerMode: true) == .degraded)
    }
    @Test func liveMicrophoneAndAttentionPrecedeSpeakingAndDegradation() {
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .noRestoreTarget,
                                    translationDegraded: true, speaking: true, passthroughOpen: true) == .passthroughOpen)
        #expect(MenuBarIcon.compute(meetingActive: false, systemInput: .idle,
                                    translationDegraded: false, talkTalkMicReadWhileInactive: true) == .needsAttention)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .idle,
                                    translationDegraded: false, micGuard: .init(verdict: .noReader), speaking: true) == .audioNeedsCheck)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .idle,
                                    translationDegraded: false, micGuard: .init(verdict: green.verdict, awaitingConfirmation: true)) == .audioNeedsCheck)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .idle,
                                    translationDegraded: false) == .audioNeedsCheck) // unknown mic facts
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .idle,
                                    translationDegraded: false,
                                    micGuard: .init(verdict: .physicalMic(appID: "test.call", app: "Call", device: "Built-in"))) == .remoteHearsOriginal)
        // The risk outranks the open microphone: the other party hears the raw mic either way.
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .idle, translationDegraded: false,
                                    micGuard: .init(verdict: .physicalMic(appID: "test.call", app: "Call", device: "Built-in")),
                                    passthroughOpen: true) == .remoteHearsOriginal)
        // Video never speaks, so a physical-mic verdict there is not the remote-hears risk.
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .idle, translationDegraded: false,
                                    micGuard: .init(verdict: .physicalMic(appID: "test.call", app: "Call", device: "Built-in")),
                                    mode: .captions) == .listening)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .idle,
                                    translationDegraded: true, micGuard: green, speaking: true) == .speaking)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .idle,
                                    translationDegraded: false, micGuard: green, speakerMode: true) == .degraded)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .idle,
                                    translationDegraded: false, micGuard: green, systemVoice: true) == .degraded)
        #expect(MenuBarIcon.compute(meetingActive: false, systemInput: .idle,
                                    translationDegraded: false, componentsMissing: true) == .missing)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .idle,
                                    translationDegraded: false, micGuard: green, warming: true) == .warming)
    }

    @Test func systemInputLeftoversWinOutsideAndInsideMeetings() {
        #expect(MenuBarIcon.compute(meetingActive: false, systemInput: .pendingFromLastRun(original: "MacBook Pro 麦克风"),
                                    translationDegraded: false) == .needsAttention)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .noRestoreTarget, translationDegraded: false) == .needsAttention)
        #expect(MenuBarIcon.compute(meetingActive: false, systemInput: .deferred(original: "x"), translationDegraded: false) == .degraded)
        // sysinput, review of 9d9b3a4 #1: macOS's physical pick outside a meeting is not "standby".
        #expect(MenuBarIcon.compute(meetingActive: false, systemInput: .deferredOnPhysical(current: "x", micAbsent: true, fromLastRun: false),
                                    translationDegraded: false) == .degraded)
        #expect(MenuBarIcon.compute(meetingActive: false, systemInput: .deferredOnPhysical(current: "x", micAbsent: false, fromLastRun: true),
                                    translationDegraded: false) == .needsAttention)
        #expect(MenuBarIcon.compute(meetingActive: false, systemInput: .switchBackFailed(current: "x", retrying: false),
                                    translationDegraded: false) == .degraded)
    }

    /// Settings visual system §8.1: the degraded or red icon's facts that have no menu line of
    /// their own, whatever the icon shows.
    @Test func reasonsNameTheFactsWithoutALine() {
        #expect(MenuBarIcon.reasons(meetingActive: false, talkTalkMicReadWhileInactive: true) == [.talkTalkMicReadWhileIdle])
        #expect(MenuBarIcon.reasons(meetingActive: true, talkTalkMicReadWhileInactive: true).isEmpty)
        #expect(MenuBarIcon.reasons(meetingActive: true, micGuard: green, speakerMode: true, systemVoice: true,
                                    speakTranslationDegraded: true) == [.speakTranslation, .speaker, .systemVoice])
        #expect(MenuBarIcon.reasons(meetingActive: true, micGuard: green, speakerMode: nil) == [.playbackUnknown])
        // A prepared Phone waiting for the call expects no playback yet; video never speaks.
        #expect(MenuBarIcon.reasons(meetingActive: true, micGuard: .init(verdict: .noReader), mode: .phone,
                                    phonePrepared: true, speakerMode: nil).isEmpty)
        #expect(MenuBarIcon.reasons(meetingActive: true, mode: .captions, speakerMode: true, systemVoice: true).isEmpty)
        #expect(MenuBarIcon.reasons(meetingActive: true, micGuard: green).isEmpty)
    }

    @Test func meetingStates() {
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .holding(original: "x"), translationDegraded: false, micGuard: green) == .listening)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .holding(original: "x"), translationDegraded: true, micGuard: green) == .degraded)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .overridden(by: "AirPods"), translationDegraded: false, micGuard: green) == .degraded)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .switchBackFailed(current: "MacBook Pro 麦克风", retrying: true),
                                    translationDegraded: false, micGuard: green) == .degraded)
        #expect(MenuBarIcon.compute(meetingActive: false, systemInput: .idle, translationDegraded: true) == .standby)
    }
}

/// Every status-item glyph exists on this system; the risk glyph's fallback parts exist where
/// `mic.badge.exclamationmark` does not (a missing SF Symbol draws nothing).
@Suite struct MenuBarIconSymbolTests {
    @Test func everyStateHasADrawableGlyph() {
        for icon in MenuBarIcon.allCases {
            if icon.symbol == SubtitleTokens.VoiceIcon.originalRisk {
                for part in [SubtitleTokens.VoiceIcon.original, SubtitleTokens.VoiceIcon.originalRiskFallbackBadge] {
                    #expect(NSImage(systemSymbolName: part, accessibilityDescription: nil) != nil, "\(icon): \(part)")
                }
            } else {
                #expect(NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil) != nil, "\(icon): \(icon.symbol)")
            }
        }
        // Problems differ by shape, not only by colour.
        #expect(Set([MenuBarIcon.audioNeedsCheck, .degraded, .needsAttention, .remoteHearsOriginal].map(\.symbol)).count == 4)
        #expect(MenuQuickStart.symbol == SubtitleTokens.OnboardingIcon.quickStart)
    }
}

@Suite struct ListenTranslationTextTests {
    @Test func menuTextNamesTheReason() {
        #expect(ListenTranslation.openAI.menuText(offline: false) == "字幕翻译：OpenAI")
        #expect(ListenTranslation.openAI.menuText(offline: true).contains("离线"))
        #expect(ListenTranslation.appleFallback(reason: "paused:401").menuText(offline: false).contains("暂停"))
        #expect(ListenTranslation.appleFallback(reason: "deadline").menuText(offline: false).contains("超时"))
        #expect(ListenTranslation.appleFallback(reason: "breakerOpen").menuText(offline: false).contains("暂时不可用"))
        // Apple-only also covers the per-meeting choice, even when a key is configured.
        #expect(ListenTranslation.appleOnly.menuText(offline: false).contains("本场未使用 OpenAI"))
    }
}
