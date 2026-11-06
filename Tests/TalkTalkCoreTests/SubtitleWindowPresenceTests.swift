import Testing
@testable import TalkTalkCore

@Suite struct SubtitleWindowPresenceTests {
    /// The window leaves in one step at the end, and a late notice never brings it back.
    @Test func endedSessionNeverReturnsForANotice() {
        var presence = SubtitleWindowPresence()
        // An idle restore notice shows no window.
        #expect(!presence.hasContent(subtitles: false, conversation: false, status: true,
                                     sessionActions: false, phoneActions: false))
        // A running session with subtitles off keeps the titlebar-only window.
        presence.begin()
        #expect(presence.hasContent(subtitles: false, conversation: false, status: true,
                                    sessionActions: false, phoneActions: false))
        let wasOpen = presence.end()
        #expect(wasOpen)
        #expect(!presence.hasContent(subtitles: true, conversation: true, status: true,
                                     sessionActions: true, phoneActions: true))
        let againOpen = presence.end()
        #expect(!againOpen)
    }
}
