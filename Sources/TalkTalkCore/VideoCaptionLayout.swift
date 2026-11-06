import Foundation

/// Video caption background style (redesign §6 字幕样式). Saved for the video scene only.
public enum VideoCaptionStyle: String, Sendable, CaseIterable {
    /// Transparent window; glass only behind the text blocks' bounding box (default).
    case fittedGlass
    /// No background; shadow and a black outline.
    case stroke
    /// A dark rounded block behind every line.
    case plate

    public static let `default`: VideoCaptionStyle = .fittedGlass

    /// Reduce Transparency always uses plates.
    public func effective(reduceTransparency: Bool) -> VideoCaptionStyle {
        reduceTransparency ? .plate : self
    }

    /// Stroke draws no background, so the scene opacity does not apply to it.
    public var usesBackgroundOpacity: Bool { self != .stroke }

    /// Line-block alpha for plates: 0.62, or 0.85 under Reduce Transparency.
    public static func plateAlpha(reduceTransparency: Bool) -> Double { reduceTransparency ? 0.85 : 0.62 }

    /// Text shadow used by the stroke style, and by fitted glass below 0.75 opacity.
    public static let strokeShadow = SubtitleTokens.TextShadow(color: .black(0.85), blur: 3.5, offsetX: 0, offsetY: -1)
    /// `NSAttributedString.Key.strokeWidth`; negative keeps the fill.
    public static let strokeWidth: Double = -3

    /// Which text shadow a style draws at the given (effective) opacity.
    public func textShadow(opacity: Double) -> SubtitleTokens.TextShadow? {
        switch self {
        case .stroke: Self.strokeShadow
        case .fittedGlass: SubtitleTokens.needsTextShadow(opacity: opacity) ? Self.strokeShadow : nil
        case .plate: nil
        }
    }
}

/// Vertical order of the two caption blocks. The source sits above Chinese by default.
public enum VideoCaptionArrangement: String, Sendable, CaseIterable {
    case sourceFirst
    /// "中文在上".
    case translationFirst

    public static let `default`: VideoCaptionArrangement = .sourceFirst
}

/// Video caption geometry (redesign §6 排版). Pure values; the app view measures text.
public enum VideoCaptionLayout {
    public static let defaultContentWidth: Double = 960
    public static let defaultContentHeight: Double = 150
    /// Chinese block width in Chinese characters (one em each).
    public static let translationCharactersPerLine: Double = 20
    /// Source block width in characters of about 0.52 em.
    public static let sourceCharactersPerLine: Double = 46
    public static let sourceCharacterEm: Double = 0.52
    public static let maxLinesPerPage = 2
    /// Below this width text blocks span the window minus `narrowMargin` on each side.
    public static let narrowWidth: Double = 640
    public static let narrowMargin: Double = 24
    public static let blockGap: Double = 6
    /// Distance from the bottom block's last baseline to the content bottom.
    public static let bottomBaselineInset: Double = 12
    public static let glassHorizontalPadding: Double = 16
    public static let glassVerticalPadding: Double = 10
    /// Plate padding on each side, in em of that line's font.
    public static let plateHorizontalPaddingEm: Double = 0.4

    // Page feedback.
    // Meta alphas take stronger values with Increase Contrast (§2).
    public static let pageDotDiameter: Double = 3
    public static let pageDotSpacing: Double = 4
    public static let pageDotGap: Double = 4
    public static func pageDotCurrentAlpha(increaseContrast: Bool) -> Double { increaseContrast ? 1.0 : 0.90 }
    public static func pageDotOtherAlpha(increaseContrast: Bool) -> Double { increaseContrast ? 0.5 : 0.30 }
    /// Draft text that changed since the previous version.
    public static let draftTailAlpha: Double = 0.65
    public static let skippedNoticeSeconds: Double = 1.5
    public static let skippedNoticeSize: Double = 12
    public static func skippedNoticeAlpha(increaseContrast: Bool) -> Double { increaseContrast ? 0.75 : 0.5 }
    /// "正在听 <来源>…", led by the listening glyph (`ear`) at 13 pt.
    public static let placeholderSize: Double = 14
    public static let placeholderSymbolSize: Double = 13
    public static func placeholderAlpha(increaseContrast: Bool) -> Double { increaseContrast ? 0.8 : 0.6 }

    /// 20 × Chinese size, never wider than the window minus 48; narrow windows use window − 48.
    public static func translationBlockWidth(windowWidth: Double, translationSize: Double) -> Double {
        blockWidth(windowWidth: windowWidth, natural: translationCharactersPerLine * translationSize)
    }

    /// About 46 characters of the source font.
    public static func sourceBlockWidth(windowWidth: Double, sourceSize: Double) -> Double {
        blockWidth(windowWidth: windowWidth, natural: sourceCharactersPerLine * sourceCharacterEm * sourceSize)
    }

    private static func blockWidth(windowWidth: Double, natural: Double) -> Double {
        let width = windowWidth.isFinite ? windowWidth : defaultContentWidth
        let available = max(0, width - 2 * narrowMargin)
        return width < narrowWidth ? available : min(available, natural)
    }

    /// Two Chinese lines, one source line and 24 pt (§6 窗口).
    public static func minimumContentHeight(translationLineHeight: Double, sourceLineHeight: Double) -> Double {
        2 * translationLineHeight + sourceLineHeight + 24
    }
}
