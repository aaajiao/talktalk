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
                                    micGuard: .init(verdict: .physicalMic(appID: "test.call", app: "Call", device: "Built-in"))) == .needsAttention)
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

    @Test func meetingStates() {
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .holding(original: "x"), translationDegraded: false, micGuard: green) == .listening)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .holding(original: "x"), translationDegraded: true, micGuard: green) == .degraded)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .overridden(by: "AirPods"), translationDegraded: false, micGuard: green) == .degraded)
        #expect(MenuBarIcon.compute(meetingActive: true, systemInput: .switchBackFailed(current: "MacBook Pro 麦克风", retrying: true),
                                    translationDegraded: false, micGuard: green) == .degraded)
        #expect(MenuBarIcon.compute(meetingActive: false, systemInput: .idle, translationDegraded: true) == .standby)
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
