import Testing
@testable import TalkTalkCore

@Suite struct VideoCaptionLayoutTests {
    @Test func controlsStayAtReadingWidthAndNeverRunAboveTheWindow() {
        let normal = VideoCaptionLayout.readingWidth(windowWidth: 960, translationSize: 26, sourceSize: 17)
        #expect(normal == 552)
        #expect(VideoCaptionLayout.readingWidth(windowWidth: 1600, translationSize: 26, sourceSize: 17) == normal)
        #expect(VideoCaptionLayout.readingWidth(windowWidth: 500, translationSize: 26, sourceSize: 17) == 484)
        #expect(VideoCaptionLayout.controlBarTop(readingTop: 80, height: 28) == 46)
        #expect(VideoCaptionLayout.controlBarTop(readingTop: 20, height: 28) == 0)
    }
    @Test func blockWidthsAreFixedByFontSizeAndOnlyNarrowWindowsFollowTheWindow() {
        // 20 × Chinese size and about 46 characters of 0.52 em; a wider window adds margins only.
        #expect(VideoCaptionLayout.translationBlockWidth(windowWidth: 960, translationSize: 26) == 520)
        #expect(VideoCaptionLayout.translationBlockWidth(windowWidth: 1600, translationSize: 26) == 520)
        #expect(abs(VideoCaptionLayout.sourceBlockWidth(windowWidth: 960, sourceSize: 17) - 46 * 0.52 * 17) < 1e-9)
        // Large sizes stay inside the window minus 48.
        #expect(VideoCaptionLayout.translationBlockWidth(windowWidth: 700, translationSize: 36) == 652)
        // Below 640 both blocks span the window minus 48.
        #expect(VideoCaptionLayout.translationBlockWidth(windowWidth: 500, translationSize: 18) == 452)
        #expect(VideoCaptionLayout.sourceBlockWidth(windowWidth: 500, sourceSize: 14) == 452)
        #expect(VideoCaptionLayout.minimumContentHeight(translationLineHeight: 34, sourceLineHeight: 22) == 114)
    }

    @Test func metaAlphasStrengthenWithIncreaseContrast() {
        let pairs: [(Bool) -> Double] = [
            VideoCaptionLayout.pageDotOtherAlpha, VideoCaptionLayout.pageDotCurrentAlpha,
            VideoCaptionLayout.skippedNoticeAlpha, VideoCaptionLayout.placeholderAlpha,
        ]
        #expect(pairs.map { $0(false) } == [0.30, 0.90, 0.5, 0.6])
        #expect(pairs.map { $0(true) } == [0.5, 1.0, 0.75, 0.8])
    }

    @Test func captionStylesResolveReduceTransparencyAndShadows() {
        #expect(VideoCaptionStyle.default == .fittedGlass)
        #expect(VideoCaptionStyle.stroke.effective(reduceTransparency: true) == .plate)
        #expect(VideoCaptionStyle.fittedGlass.effective(reduceTransparency: false) == .fittedGlass)
        #expect(!VideoCaptionStyle.stroke.usesBackgroundOpacity)
        #expect(VideoCaptionStyle.plate.usesBackgroundOpacity)
        #expect(VideoCaptionStyle.plateAlpha(reduceTransparency: false) == 0.62)
        #expect(VideoCaptionStyle.plateAlpha(reduceTransparency: true) == 0.85)
        #expect(VideoCaptionStyle.stroke.textShadow(opacity: 1) == VideoCaptionStyle.strokeShadow)
        #expect(VideoCaptionStyle.fittedGlass.textShadow(opacity: 0.8) == nil)
        #expect(VideoCaptionStyle.fittedGlass.textShadow(opacity: 0.6) == VideoCaptionStyle.strokeShadow)
        #expect(VideoCaptionStyle.plate.textShadow(opacity: 0.4) == nil)
        #expect(VideoCaptionStyle.strokeShadow.blur == 3.5 && VideoCaptionStyle.strokeShadow.offsetY == -1)
        #expect(VideoCaptionArrangement.default == .sourceFirst)
    }

    @Test func draftAndCaretRules() {
        #expect(ConversationTextRules.draftDisplay("我们需要") == "我们需要…")
        #expect(ConversationTextRules.draftDisplay("我们需要… ") == "我们需要…")
        #expect(ConversationTextRules.draftDisplay("We need...") == "We need...")
        #expect(ConversationTextRules.draftDisplay("  ") == "")
        #expect(abs(ConversationTextRules.caretHeight(translationSize: 22) - 15.4) < 1e-9)
        #expect(ConversationTextRules.caretWidth == 2)
    }
}
