import Testing
@testable import TalkTalkCore

@Suite struct PassthroughNoticeHUDTests {
    @Test func controlNoticesAreSeparateFromPresentation() {
        #expect(PassthroughNotice.playOpenCue.hudEvent == nil)
        #expect(PassthroughNotice.startMic.hudEvent == nil)
        #expect(PassthroughNotice.opened(at: 10, waitMs: 20, generation: 1).hudEvent == .opened)
        #expect(PassthroughNotice.closed(at: 20, reason: .keyReleased, heldMs: 10).hudEvent == .closed(reason: nil))
        #expect(PassthroughNotice.refused(.unavailable(.meetingModeOff)).hudEvent == .refused(reason: nil))
        #expect(PassthroughNotice.cancelled(reason: .otherKey).hudEvent == .cancelled)
    }
}
