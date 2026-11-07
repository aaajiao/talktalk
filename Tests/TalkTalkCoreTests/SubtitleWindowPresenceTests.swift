import Testing
@testable import TalkTalkCore

@Suite struct SubtitleWindowPresenceTests {
    /// The window leaves in one step at the end, and a late notice never brings it back.
    @Test func endedSessionNeverReturnsForANotice() {
        var presence = SubtitleWindowPresence()
        // An idle restore notice shows no window.
        #expect(!presence.hasContent(subtitles: false, conversation: false, status: true, sessionActions: false))
        // A running session with subtitles off keeps the titlebar-only window.
        presence.begin()
        #expect(presence.hasContent(subtitles: false, conversation: false, status: true, sessionActions: false))
        let wasOpen = presence.end()
        #expect(wasOpen)
        #expect(!presence.hasContent(subtitles: true, conversation: true, status: true, sessionActions: true))
        let againOpen = presence.end()
        #expect(!againOpen)
    }

    private func video(_ presence: SubtitleWindowPresence, source: String = "", translation: String = "",
                       subtitles: Bool = true) -> Bool {
        presence.hasContent(subtitles: subtitles, conversation: false, status: true, sessionActions: true,
                            scene: .video, videoSource: source, videoTranslation: translation)
    }

    @Test func videoStartupStatusAndWhitespaceDoNotShowAnEmptyWindow() {
        var presence = SubtitleWindowPresence()
        presence.begin()
        #expect(!video(presence))
        #expect(!video(presence, source: " \n\t", translation: "　\n"))
        #expect(video(presence, source: "The video has started speaking."))
        #expect(video(presence, source: "Original.", translation: "译文。"))
        #expect(video(presence, translation: "已有译文。"))
        #expect(!video(presence, source: "Original.", translation: "译文。", subtitles: false))
    }

    @Test func videoClearOrLanguageResetWaitsForTheNextActualCaption() {
        var presence = SubtitleWindowPresence()
        presence.begin()
        #expect(video(presence, source: "Old direction.", translation: "旧方向。"))
        // A clear resets the content, not the running session or the user's subtitle setting.
        #expect(!video(presence))
        #expect(presence.sessionOpen)
        #expect(video(presence, source: "Neue Richtung."))
        // Long silence keeps the displayed cue; it must not repeatedly hide/reopen the window.
        #expect(video(presence, source: "Neue Richtung."))
    }

    @Test func videoContentCannotOverrideManualHideOrMinimize() {
        var presence = SubtitleWindowPresence()
        presence.begin()
        let content = video(presence, source: "The first real subtitle.")
        #expect(presence.allowsAutomaticDisplay(contentAvailable: content, userHidden: false, minimized: false))
        #expect(!presence.allowsAutomaticDisplay(contentAvailable: content, userHidden: true, minimized: false))
        #expect(!presence.allowsAutomaticDisplay(contentAvailable: content, userHidden: false, minimized: true))
        // A language reset followed by new text still respects the same user-owned state.
        #expect(!presence.allowsAutomaticDisplay(contentAvailable: video(presence), userHidden: false, minimized: false))
        #expect(!presence.allowsAutomaticDisplay(contentAvailable: video(presence, translation: "新字幕。"),
                                                userHidden: true, minimized: true))
    }

    @Test func endedVideoCannotReturnForLateTextAndNewSessionStillWaitsForContent() {
        var presence = SubtitleWindowPresence()
        presence.begin()
        presence.end()
        #expect(!video(presence, source: "Late source.", translation: "迟到译文。"))
        #expect(!presence.allowsAutomaticDisplay(contentAvailable: true, userHidden: false, minimized: false))
        presence.begin()
        #expect(!video(presence))
        #expect(video(presence, source: "New session."))
    }

    @Test func meetingAndPhoneRetainTheirEmptyConversationAndStatusControls() {
        var presence = SubtitleWindowPresence()
        presence.begin()
        for scene in [SubtitleScene.meeting, .phone] {
            #expect(presence.hasContent(subtitles: true, conversation: false, status: false,
                                        sessionActions: false, scene: scene))
            #expect(presence.hasContent(subtitles: false, conversation: false, status: true,
                                        sessionActions: true, scene: scene))
        }
    }
}
