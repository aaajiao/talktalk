// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation

/// Settings › 字幕 (redesign §7 字幕页): the layout preview's geometry and the rules that
/// enable or explain its controls. Pure values; the App target draws the preview over a
/// backdrop that follows the system appearance.

/// The preview renders the live window's components at their real logical size and scales
/// the whole window into the settings column, so breakpoints, compaction and font formulas
/// behave exactly as in a 760×480 meeting/phone window or the default 960×184 video window.
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

    /// Locked aspect: 760:480 (meeting, phone) and 960:184 (video), titlebar included. Video
    /// reserves its control strip and gap inside the full-size view without moving captions
    /// when the pointer reveals or hides the strip.
    public static func logicalSize(for scene: SubtitleScene) -> (width: Double, height: Double) {
        scene == .video
            ? (VideoCaptionLayout.defaultContentWidth, VideoCaptionLayout.defaultContentHeight)
            : (760, 480)
    }

    /// 32 pt titlebar; the video hover bar is 28 pt. All previews reveal these on hover.
    public static func titlebarHeight(for scene: SubtitleScene) -> Double {
        scene == .video ? SubtitleTokens.Size.videoHoverBarHeight : SubtitleTokens.Size.titlebarHeight
    }

    /// Logical content view: below the titlebar for meeting/phone, the whole window for video.
    /// The video caption view itself reserves the control strip and its gap.
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
        /// The stroke style draws no background ("描边样式没有背景").
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

    /// Every scene's background starts at 85 % (the stored default, the slider's tick and
    /// "恢复默认 85%").
    public static let defaultOpacity: Double = 0.85
}

/// The settings example follows the scene's speaking direction without starting audio.
public struct SubtitleSpeakingSample: Equatable, Sendable {
    public let source: String
    public let translation: String

    public init(phone: Bool, languages: SpeakLanguageSelection) {
        let zh = phone ? "周二上午可以，谢谢。请再告诉我一下具体地址。" // l10n-ignore
            : "周二上午可以。我们可以先看演示，再讨论接下来的安排。" // l10n-ignore
        let en = phone ? "Tuesday morning works, thank you. Could you give me the address again?"
            : "Tuesday morning works. Let's start with the demo, then talk about next steps."
        let de = phone ? "Dienstagvormittag passt, danke. Können Sie mir die Adresse noch einmal nennen?"
            : "Dienstagvormittag passt. Wir können zuerst die Demo ansehen und dann die nächsten Schritte besprechen."
        source = languages.source == .zh ? zh : en
        switch languages.target {
        case .zh: translation = zh
        case .en: translation = en
        case .de: translation = de
        }
    }
}

/// Paired, non-private examples for the selected caption direction. Both sides come from
/// the same sentence; a Chinese source never gets an English-only placeholder.
public struct SubtitleListeningSample: Equatable, Sendable {
    public struct Pair: Equatable, Sendable {
        public let source: String
        public let translation: String
    }
    public let pairs: [Pair]

    public init(scene: SubtitleScene, languages: ListenLanguageSelection) {
        let sentences: [(zh: String, en: String, de: String)]
        switch scene {
        case .meeting:
            sentences = [
                ("我们确认一下下周的安排。周二上午你方便吗？", // l10n-ignore
                 "Let's confirm the plan for next week. Would Tuesday morning work for you?",
                 "Lassen Sie uns den Plan für nächste Woche bestätigen. Passt Ihnen Dienstagvormittag?"),
                ("好的。我今天下午把议程和会议链接发给你。", // l10n-ignore
                 "Great. I'll send the agenda and the meeting link this afternoon.",
                 "Gut. Ich schicke Ihnen heute Nachmittag die Tagesordnung und den Link zur Besprechung.")
            ]
        case .phone:
            sentences = [
                ("您好，我打电话来确认您的预约。周二上午您方便吗？", // l10n-ignore
                 "Hi, I'm calling to confirm your appointment. Would Tuesday morning work for you?",
                 "Guten Tag, ich rufe an, um Ihren Termin zu bestätigen. Passt Ihnen Dienstagvormittag?"),
                ("当然。我们在市场街，二楼。", // l10n-ignore
                 "Of course. We're on Market Street, on the second floor.",
                 "Natürlich. Wir sind in der Marktstraße, im zweiten Stock.")
            ]
        case .video:
            sentences = [
                ("最简单的想法，往往始于换一种方式去看待我们身边的世界。", // l10n-ignore
                 "The simplest ideas often begin with a different way of looking at the world around us.",
                 "Die einfachsten Ideen beginnen oft damit, die Welt um uns herum auf eine andere Weise zu betrachten.")
            ]
        }
        func text(_ sentence: (zh: String, en: String, de: String), for language: Lang) -> String {
            switch language { case .zh: sentence.zh; case .en: sentence.en; case .de: sentence.de }
        }
        pairs = sentences.map { Pair(source: text($0, for: languages.source), translation: text($0, for: languages.target)) }
    }
}
