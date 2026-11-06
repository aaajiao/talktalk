import Testing
@testable import TalkTalkCore

@Suite struct VideoWindowChromeTests {
    @Test func hoverBarShowsWhileInsideAndHidesOneAndAHalfSecondsAfterLeaving() {
        var bar = VideoHoverBar()
        #expect(!bar.isShown(at: 0))
        bar.pointer(inside: true, at: 1)
        #expect(bar.isShown(at: 1) && bar.hideDeadline(at: 1) == nil)
        bar.pointer(inside: false, at: 2)
        #expect(bar.isShown(at: 3.4))
        #expect(bar.hideDeadline(at: 3) == 3.5)
        #expect(!bar.isShown(at: 3.5) && bar.hideDeadline(at: 3.5) == nil)
        // Coming back before the deadline cancels it.
        bar.pointer(inside: true, at: 4); bar.pointer(inside: false, at: 4.2); bar.pointer(inside: true, at: 5)
        #expect(bar.isShown(at: 9))
        #expect(VideoHoverBar.fadeDuration(reduceMotion: false) == 0.2)
        #expect(VideoHoverBar.fadeDuration(reduceMotion: true) == 0)
    }

    @Test func hidingTheWindowDropsThePointerAndCaptionsOffPinsTheBar() {
        var bar = VideoHoverBar()
        bar.pointer(inside: true, at: 1)
        bar.setHeld(true, at: 1)
        // Ordered out with the pointer inside: no mouseExited arrives, the bar goes at once.
        bar.windowHidden()
        #expect(!bar.isShown(at: 1) && !bar.pointerInside && !bar.held && bar.hideDeadline(at: 1) == nil)
        // Re-sampled on show: an entry is no longer swallowed by a stale inside state.
        bar.pointer(inside: true, at: 2)
        #expect(bar.isShown(at: 2))
        bar.pointer(inside: false, at: 3)
        bar.setPinned(true)
        #expect(bar.isShown(at: 100) && bar.hideDeadline(at: 3.1) == nil)
        bar.setLocked(true)
        #expect(!bar.isShown(at: 100))
    }

    @Test func menusHoldAShownBarButNeverRevealAHiddenOneAndLockingHidesIt() {
        var bar = VideoHoverBar()
        bar.setHeld(true, at: 0)
        #expect(!bar.isShown(at: 0))
        bar.pointer(inside: true, at: 1)
        bar.setHeld(true, at: 1)
        bar.pointer(inside: false, at: 1.1)
        #expect(bar.isShown(at: 10) && bar.hideDeadline(at: 10) == nil)
        // Releasing the hold starts the 1.5 s delay from then.
        bar.setHeld(false, at: 10)
        #expect(bar.isShown(at: 11.4) && !bar.isShown(at: 11.5))
        bar.pointer(inside: true, at: 12)
        bar.setLocked(true)
        #expect(!bar.isShown(at: 12))
        bar.pointer(inside: true, at: 13)
        #expect(!bar.isShown(at: 13))
        bar.setLocked(false)
        bar.pointer(inside: true, at: 14)
        #expect(bar.isShown(at: 14))
    }

    @Test func statusDotFollowsProblemTonesAndLag() {
        #expect(VideoStatusDot.make(issue: nil) == nil)
        #expect(VideoStatusDot.make(issue: .cloudPrivacy) == nil)
        #expect(VideoStatusDot.make(issue: .chip(HUDChip("提示", symbol: "info", tone: .notice))) == nil)
        #expect(VideoStatusDot.make(issue: .chip(HUDChip("未听到对方", symbol: "ear", tone: .info))) == nil)
        #expect(VideoStatusDot.make(issue: .chip(HUDChip("风险", symbol: "mic", tone: .risk))) == .risk)
        #expect(VideoStatusDot.risk.color == .riskStroke && VideoStatusDot.warn.color == .warn)
        // Severity differs by shape too: caution triangle vs stop octagon.
        #expect(VideoStatusDot.warn.symbol == "exclamationmark.triangle.fill")
        #expect(VideoStatusDot.risk.symbol == "exclamationmark.octagon.fill")
        // Captions behind: a constant warning chip that turns the dot yellow.
        let chip = VideoStatusDot.lagChip
        #expect(chip.label == "字幕落后" && chip.tone == .warn && chip.detail == "字幕落后于声音，正在加快翻页追赶")
        #expect(chip.symbol == SubtitleTokens.VoiceIcon.captionLag && chip.symbol == "clock.badge.exclamationmark")
        var model = HUDModel()
        model.meetingStarted()
        model.scene = .video
        model.setExternalIssue(.videoLag, chip)
        #expect(VideoStatusDot.make(issue: model.issueSlot(now: 0)) == .warn)
        model.setExternalIssue(.videoLag, nil)
        #expect(VideoStatusDot.make(issue: model.issueSlot(now: 0)) == nil)
    }

    @Test func onlyTheVideoSceneLocksAndOffersTheMenuItem() {
        #expect(SubtitleClickThrough.ignoresMouse(locked: true, scene: .video))
        #expect(!SubtitleClickThrough.ignoresMouse(locked: true, scene: .meeting))
        #expect(!SubtitleClickThrough.ignoresMouse(locked: true, scene: .phone))
        #expect(!SubtitleClickThrough.ignoresMouse(locked: false, scene: .video))
        #expect(SubtitleClickThrough.offersLock(scene: .video, sessionActive: true))
        #expect(!SubtitleClickThrough.offersLock(scene: .video, sessionActive: false))
        #expect(!SubtitleClickThrough.offersLock(scene: .meeting, sessionActive: true))
        #expect(SubtitleClickThrough.indicatorAlpha(increaseContrast: false) == 0.4)
        #expect(SubtitleClickThrough.indicatorAlpha(increaseContrast: true) == 0.8)
    }

    @Test func quietDimStartsEightSecondsAfterTheLastPageWasReadAndRestoresAtOnce() {
        var dim = VideoQuietDim()
        #expect(dim.enabled)
        dim.update(lastPageRead: false, pending: false, at: 0)
        #expect(!dim.isDimmed(at: 100))
        dim.update(lastPageRead: true, pending: false, at: 10)
        dim.update(lastPageRead: true, pending: false, at: 15)
        #expect(!dim.isDimmed(at: 17.9) && dim.isDimmed(at: 18))
        dim.contentArrived()
        #expect(!dim.isDimmed(at: 18))
        // The quiet period restarts from the next tick after new content.
        dim.update(lastPageRead: true, pending: false, at: 19)
        #expect(!dim.isDimmed(at: 26.9) && dim.isDimmed(at: 27))
        // Pending cues are never quiet.
        dim.update(lastPageRead: true, pending: true, at: 28)
        #expect(!dim.isDimmed(at: 40))
        dim.update(lastPageRead: true, pending: false, at: 40)
        dim.enabled = false
        #expect(!dim.isDimmed(at: 60))
        #expect(VideoQuietDim.textAlpha(dimmed: true) == 0.35 && VideoQuietDim.textAlpha(dimmed: false) == 1)
        #expect(VideoQuietDim.backgroundAlpha(normal: 0.85, dimmed: true) == 0.40)
        #expect(VideoQuietDim.backgroundAlpha(normal: 0.35, dimmed: true) == 0.35)
        #expect(VideoQuietDim.backgroundAlpha(normal: 0.85, dimmed: false) == 0.85)
        #expect(VideoQuietDim.transition(dimming: true, reduceMotion: false) == 0.3)
        #expect(VideoQuietDim.transition(dimming: true, reduceMotion: true) == 0)
        #expect(VideoQuietDim.transition(dimming: false, reduceMotion: false) == 0)
    }

    @Test func fullScreenSpaceNeedsAnotherAppsWindowCoveringTheWholeDisplayOnce() {
        let display = (x: 0.0, y: 0.0, width: 1512.0, height: 982.0)
        let zoomed = FullScreenSpaceHint.Window(layer: 0, ownerPID: 9, x: 0, y: 33, width: 1512, height: 949)
        let fullScreen = FullScreenSpaceHint.Window(layer: 0, ownerPID: 9, x: 0, y: 0, width: 1512, height: 982)
        let menuBar = FullScreenSpaceHint.Window(layer: 24, ownerPID: 3, x: 0, y: 0, width: 1512, height: 982)
        let mine = FullScreenSpaceHint.Window(layer: 0, ownerPID: 42, x: 0, y: 0, width: 1512, height: 982)
        #expect(!FullScreenSpaceHint.isFullScreenSpace(windows: [zoomed, menuBar, mine], display: display, ownPID: 42))
        #expect(FullScreenSpaceHint.isFullScreenSpace(windows: [fullScreen], display: display, ownPID: 42))
        // A second display's full-screen window says nothing about this one.
        let other = FullScreenSpaceHint.Window(layer: 0, ownerPID: 9, x: 1512, y: 0, width: 1920, height: 1080)
        #expect(!FullScreenSpaceHint.isFullScreenSpace(windows: [other], display: display, ownPID: 42))
        #expect(FullScreenSpaceHint.shouldShow(alreadyShown: false, scene: .video, windowVisible: true, locked: false,
                                               onFullScreenSpace: true))
        #expect(!FullScreenSpaceHint.shouldShow(alreadyShown: true, scene: .video, windowVisible: true, locked: false,
                                                onFullScreenSpace: true))
        #expect(!FullScreenSpaceHint.shouldShow(alreadyShown: false, scene: .meeting, windowVisible: true, locked: false,
                                                onFullScreenSpace: true))
        #expect(!FullScreenSpaceHint.shouldShow(alreadyShown: false, scene: .video, windowVisible: true, locked: true,
                                                onFullScreenSpace: true))
        #expect(!FullScreenSpaceHint.shouldShow(alreadyShown: false, scene: .video, windowVisible: true, locked: false,
                                                onFullScreenSpace: false))
    }
}
