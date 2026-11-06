/// Settings › 字幕 (redesign §7 字幕页): the layout preview's geometry and the rules that
/// enable or explain its controls. Pure values; the App target draws the preview.

/// What the preview window floats over. The glass blurs this backdrop, so a light web page
/// and a dark video frame show how the chosen opacity reads on either.
public enum SubtitlePreviewBackdrop: String, Sendable, CaseIterable {
    case lightPage
    case darkVideoFrame

    /// Meeting and phone windows usually sit over documents; video captions over video.
    public static func initial(for scene: SubtitleScene) -> SubtitlePreviewBackdrop {
        scene == .video ? .darkVideoFrame : .lightPage
    }

    public var isDark: Bool { self == .darkVideoFrame }
}

/// The preview renders the live window's components at their real logical size and scales
/// the whole window into the settings column, so breakpoints, compaction and font formulas
/// behave exactly as in a 760×480 meeting/phone window or a 960×150 video window.
public struct SubtitlePreviewLayout: Sendable, Equatable {
    /// Backdrop visible around the window on every side.
    public static let margin: Double = 16
    /// Used when SwiftUI proposes no width.
    public static let fallbackWidth: Double = 560

    public let scene: SubtitleScene
    public let canvasWidth: Double
    public let canvasHeight: Double
    /// The window inside the canvas, in canvas points.
    public let windowX: Double
    public let windowY: Double
    public let windowWidth: Double
    public let windowHeight: Double
    /// Canvas points per logical window point (≤ 1 in the settings window).
    public let scale: Double

    /// Locked aspect: 760:480 (meeting, phone) and 960:150 (video), titlebar included. Video
    /// uses a full-size content view, so its hover bar lies over the caption area.
    public static func logicalSize(for scene: SubtitleScene) -> (width: Double, height: Double) {
        scene == .video
            ? (VideoCaptionLayout.defaultContentWidth, VideoCaptionLayout.defaultContentHeight)
            : (760, 480)
    }

    /// 32 pt titlebar; the video hover bar is 28 pt and drawn in its shown state.
    public static func titlebarHeight(for scene: SubtitleScene) -> Double {
        scene == .video ? SubtitleTokens.Size.videoHoverBarHeight : SubtitleTokens.Size.titlebarHeight
    }

    /// Logical reading area: below the titlebar for meeting/phone, the whole window for video.
    public static func contentHeight(for scene: SubtitleScene) -> Double {
        let size = logicalSize(for: scene)
        return scene == .video ? size.height : size.height - titlebarHeight(for: scene)
    }

    public static func canvasHeight(for scene: SubtitleScene, width: Double) -> Double {
        SubtitlePreviewLayout(scene: scene, canvasWidth: width).canvasHeight
    }

    public init(scene: SubtitleScene, canvasWidth: Double) {
        let width = canvasWidth.isFinite && canvasWidth > 0 ? canvasWidth : Self.fallbackWidth
        let logical = Self.logicalSize(for: scene)
        let windowWidth = max(1, width - 2 * Self.margin)
        let scale = windowWidth / logical.width
        let windowHeight = logical.height * scale
        self.scene = scene
        self.canvasWidth = width
        self.canvasHeight = (windowHeight + 2 * Self.margin).rounded(.up)
        self.windowX = Self.margin
        self.windowY = Self.margin
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
        self.scale = scale
    }
}

/// The opacity slider (§6 字幕样式, §2 可读性兜底). Reduce Transparency fixes every
/// background (opaque meeting/phone window, video plates at 0.85); the stroke style draws
/// no background at all.
public struct SubtitleOpacityControl: Sendable, Equatable {
    public enum Note: Sendable, Equatable {
        case reduceTransparency
        /// "描边样式不使用背景".
        case strokeHasNoBackground
    }

    public let enabled: Bool
    public let note: Note?

    public static func make(scene: SubtitleScene, videoStyle: VideoCaptionStyle,
                            reduceTransparency: Bool) -> SubtitleOpacityControl {
        if reduceTransparency { return .init(enabled: false, note: .reduceTransparency) }
        if scene == .video, !videoStyle.usesBackgroundOpacity {
            return .init(enabled: false, note: .strokeHasNoBackground)
        }
        return .init(enabled: true, note: nil)
    }

    /// "恢复默认字号": 26 for video, 22 for meeting and phone.
    public static func defaultFontSize(for scene: SubtitleScene) -> Double {
        scene == .video ? VideoCaptionTypography.defaultBase : ConversationTypography.defaultBase
    }
}
