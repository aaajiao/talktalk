import Testing
@testable import TalkTalkCore

@Suite struct SubtitleSettingsPreviewTests {
    @Test func previewKeepsTheLiveWindowAspectInsideAFixedMargin() {
        let meeting = SubtitlePreviewLayout(scene: .meeting, canvasWidth: 640)
        #expect(meeting.windowX == 16 && meeting.windowY == 16)
        #expect(meeting.windowWidth == 608)
        #expect(abs(meeting.windowWidth / meeting.windowHeight - 760.0 / 480.0) < 1e-9)
        #expect(meeting.canvasHeight == (608 * 480 / 760 + 32).rounded(.up))
        #expect(meeting.scale == 608.0 / 760.0)
        let video = SubtitlePreviewLayout(scene: .video, canvasWidth: 640)
        #expect(abs(video.windowWidth / video.windowHeight - 960.0 / 184.0) < 1e-9)
        #expect(SubtitlePreviewLayout(scene: .phone, canvasWidth: 640) == SubtitlePreviewLayout(scene: .phone, canvasWidth: 640))
        // No proposal or a nonsense width falls back to a usable size.
        #expect(SubtitlePreviewLayout(scene: .meeting, canvasWidth: .nan).canvasWidth == SubtitlePreviewLayout.fallbackWidth)
        #expect(SubtitlePreviewLayout.canvasHeight(for: .video, width: 640) == video.canvasHeight)
    }

    @Test func logicalWindowAndTitlebarMatchTheLiveScenes() {
        #expect(SubtitlePreviewLayout.logicalSize(for: .meeting) == (760, 480))
        #expect(SubtitlePreviewLayout.logicalSize(for: .video) == (960, 184))
        #expect(SubtitlePreviewLayout.titlebarHeight(for: .phone) == 32)
        #expect(SubtitlePreviewLayout.titlebarHeight(for: .video) == 28)
        // Video reserves its hover bar inside the full-size content; meeting/phone sit below it.
        #expect(SubtitlePreviewLayout.contentHeight(for: .meeting) == 448)
        #expect(SubtitlePreviewLayout.contentHeight(for: .video) == 184)
    }

    @Test func opacitySliderIsGreyedForStrokeAndUnderReduceTransparency() {
        #expect(SubtitleOpacityControl.make(scene: .video, videoStyle: .fittedGlass, reduceTransparency: false)
            == .init(enabled: true, note: nil))
        #expect(SubtitleOpacityControl.make(scene: .video, videoStyle: .plate, reduceTransparency: false).enabled)
        #expect(SubtitleOpacityControl.make(scene: .video, videoStyle: .stroke, reduceTransparency: false)
            == .init(enabled: false, note: .strokeHasNoBackground))
        // The video caption style never affects the meeting/phone background.
        #expect(SubtitleOpacityControl.make(scene: .meeting, videoStyle: .stroke, reduceTransparency: false).enabled)
        for scene in SubtitleScene.allCases {
            #expect(SubtitleOpacityControl.make(scene: scene, videoStyle: .stroke, reduceTransparency: true)
                == .init(enabled: false, note: .reduceTransparency))
        }
        #expect(SubtitleOpacityControl.defaultFontSize(for: .video) == 26)
        #expect(SubtitleOpacityControl.defaultFontSize(for: .meeting) == 22)
        #expect(SubtitleOpacityControl.defaultFontSize(for: .phone) == 22)
        // The reset button's help says "恢复默认 85%".
        #expect(SubtitleOpacityControl.defaultOpacity == 0.85)
    }
}
