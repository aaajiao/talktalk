import Foundation

/// Shared visual tokens for the subtitle window, its titlebar and the settings preview
/// (docs/decisions/2026-11-06-subtitle-ui-redesign.md §2). Pure values only: AppKit colour,
/// font and shadow factories live in the app target and read everything from here.
public enum SubtitleTokens {
    /// sRGB components, 0…1.
    public struct RGBA: Sendable, Equatable {
        public var red: Double, green: Double, blue: Double, alpha: Double
        public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
            self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
        }
        public init(hex: UInt32, alpha: Double = 1) {
            self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255,
                      Double(hex & 0xFF) / 255, alpha)
        }
        public static func white(_ alpha: Double) -> RGBA { RGBA(1, 1, 1, alpha) }
        public static func black(_ alpha: Double) -> RGBA { RGBA(0, 0, 0, alpha) }
        public func withAlpha(_ value: Double) -> RGBA { RGBA(red, green, blue, value) }
    }

    /// Colour roles. The subtitle panel is always darkAqua; `lightSurface` selects the
    /// light-settings variants where the table lists one. Translation blue never follows
    /// the user's accent colour.
    public enum Color: Sendable, CaseIterable {
        case voiceOriginal, voiceTranslate, speakerRemote
        case riskFill, riskStroke, warn
        case textPrimary, textSource, textSourceLive, textDraft, textMeta, textColumnHeader
        case videoSource, separator, pairHover, meRow
        /// Titlebar notification chip outline.
        case noticeStroke

        public func rgba(increaseContrast: Bool = false, lightSurface: Bool = false) -> RGBA {
            let ic = increaseContrast
            switch self {
            case .voiceOriginal: return RGBA(hex: 0x30D158)
            case .voiceTranslate: return RGBA(hex: lightSurface ? 0x0A64D6 : 0x409CFF)
            case .speakerRemote: return RGBA(hex: 0x40C8E0)
            case .riskFill: return RGBA(hex: 0xD70015)
            case .riskStroke: return RGBA(hex: 0xFF453A)
            case .warn: return RGBA(hex: lightSurface ? 0xC93400 : 0xFF9F0A)
            case .textPrimary: return .white(ic ? 1.0 : 0.92)
            case .textSource: return .white(ic ? 0.85 : 0.72)
            case .textSourceLive: return .white(ic ? 0.92 : 0.80)
            case .textDraft: return .white(ic ? 0.78 : 0.60)
            case .textMeta: return .white(0.60)
            case .textColumnHeader: return .white(0.45)
            case .videoSource: return ic ? .white(0.92) : RGBA(hex: 0xD1D1D6)
            case .separator: return .white(ic ? 0.35 : 0.08)
            case .pairHover: return .white(0.06)
            case .meRow: return RGBA(64 / 255, 156 / 255, 1, 0.08)
            case .noticeStroke: return .white(0.28)
            }
        }
    }

    /// Separator thickness: 0.5 pt normally, 1 pt with Increase Contrast.
    public static func separatorWidth(increaseContrast: Bool) -> Double { increaseContrast ? 1 : 0.5 }
    /// Speaker track bar width.
    public static func trackWidth(increaseContrast: Bool) -> Double { increaseContrast ? 4 : 3 }

    // MARK: sizes (points)

    public enum Size {
        public static let titlebarHeight: Double = 32
        public static let videoHoverBarHeight: Double = 28
        public static let controlHeight: Double = 20
        public static let controlSpacing: Double = 6
        /// Gap on each side of the 1 pt divider before the end button.
        public static let endDividerGap: Double = 8
        public static let panelHorizontalPadding: Double = 12
        public static let panelBottomPadding: Double = 8
        public static let columnHeaderHeight: Double = 20
        public static let speakerTrackWidth: Double = 24
        public static let sourceColumnFraction: Double = 0.4
        public static let translationColumnFraction: Double = 0.6
        public static let columnGap: Double = 16
        public static let pairTopPadding: Double = 6
        public static let pairBottomPadding: Double = 8
        public static let statusBandIdleHeight: Double = 48
        public static let waveformBandHeight: Double = 24
        public static let jumpToLatestHeight: Double = 24

        // Titlebar components (§3).
        public static let capsuleMinWidth: Double = 64
        public static let capsuleMaxWidth: Double = 180
        public static let capsuleHorizontalPadding: Double = 8
        public static let capsuleVerticalPadding: Double = 3
        public static let capsuleIconSize: Double = 10
        public static let capsuleChevronSize: Double = 8
        public static let chipMaxWidth: Double = 180
        public static let keycapMinWidth: Double = 30
        public static let phoneButtonWidth: Double = 64
        public static let detailsPopoverWidth: Double = 320
        public static let detailsCapsuleHeight: Double = 24
        public static let endConfirmationWidth: Double = 260
        public static let cloudIconSize: Double = 16
        public static let cloudDotSize: Double = 6
        /// Below this window width only the keycap remains (no action text).
        public static let keyActionMinWindowWidth: Double = 560
    }

    public enum Radius {
        public static let window: Double = 12
        public static let settingsCard: Double = 10
        public static let capsule: Double = 10
        public static let chip: Double = 9
        public static let videoGlass: Double = 10
        public static let solidRowBlock: Double = 6
        public static let keycap: Double = 5
    }

    // MARK: motion (seconds)

    public enum Motion: Sendable, CaseIterable {
        case statusBandResize, draftToFinal, videoPageCrossfade, videoTitlebarFadeIn, videoTitlebarHideDelay
        case chipFadeIn, noticeFadeOut, longSilenceDim, placeholderFadeOut

        public var seconds: Double {
            switch self {
            case .statusBandResize: 0.18
            case .draftToFinal: 0.15
            case .videoPageCrossfade: 0.12
            case .videoTitlebarFadeIn: 0.2
            case .videoTitlebarHideDelay: 1.5
            case .chipFadeIn: 0.15
            case .noticeFadeOut: 0.3
            case .longSilenceDim: 0.3
            case .placeholderFadeOut: 0.12
            }
        }

        /// Reduce Motion switches every transition instantly. The hide delay is not an
        /// animation: it still decides when the hover bar leaves.
        public func duration(reduceMotion: Bool) -> Double {
            reduceMotion && self != .videoTitlebarHideDelay ? 0 : seconds
        }
    }

    /// How long a notification chip stays before it fades.
    public static let noticeChipSeconds: Double = 4

    // MARK: legibility fallback

    public struct TextShadow: Sendable, Equatable {
        public var color: RGBA, blur: Double, offsetX: Double, offsetY: Double
    }

    public static let readingShadow = TextShadow(color: .black(0.55), blur: 3, offsetX: 0, offsetY: -0.5)

    /// Below 0.75 opacity body text gets `readingShadow`.
    public static func needsTextShadow(opacity: Double) -> Bool { opacity < 0.75 }

    /// Increase Contrast raises the scene opacity to at least 0.95. Reduce Transparency is
    /// handled by the window (opaque background), not by this value.
    public static func effectiveOpacity(_ opacity: Double, increaseContrast: Bool) -> Double {
        let value = opacity.isFinite ? min(1, max(0, opacity)) : 0.85
        return increaseContrast ? max(0.95, value) : value
    }

    // MARK: icons (one vocabulary for the titlebar, the scene page and the subtitle page)

    public enum SceneIcon {
        public static let meeting = "person.2.wave.2"
        public static let phone = "phone"
        public static let video = "play.rectangle"
    }

    public enum VoiceIcon {
        public static let original = "mic.fill"
        /// Not in every SF Symbols release; the app overlays exclamationmark.circle.fill on mic.fill.
        public static let originalRisk = "mic.badge.exclamationmark"
        public static let originalRiskFallbackBadge = "exclamationmark.circle.fill"
        /// Only for "原声已关" (restoring) and "音频不可用".
        public static let originalOff = "mic.slash"
        public static let translating = "waveform"
        public static let playingTranslation = "speaker.wave.2.fill"
        public static let sentToPhone = "phone.arrow.up.right"
        public static let localOnly = "speaker.slash"
        public static let listening = "ear"
        public static let locked = "lock.fill"
        public static let chevron = "chevron.down"
        public static let end = "stop.circle"
        public static let cloud = "network"
    }
}

/// Meeting and phone reading sizes (§2 字体). `base` is the scene's base size B (default 22),
/// `width` the content width W in points.
public struct ConversationTypography: Sendable, Equatable {
    public enum Weight: Sendable, Equatable { case regular, medium, semibold }
    public struct Role: Sendable, Equatable {
        public var size: Double
        public var weight: Weight
        /// Line height as a multiple of the font size.
        public var lineHeight: Double
    }

    public static let defaultBase: Double = 22
    public static let referenceWidth: Double = 760

    public let remoteTranslation: Role
    public let source: Role
    public let myTranslation: Role

    public init(base: Double, width: Double) {
        let b = base.isFinite && base > 0 ? base : Self.defaultBase
        let f = Self.translationSize(base: b, width: width)
        remoteTranslation = Role(size: f, weight: .medium, lineHeight: 1.34)
        source = Role(size: max(12, 0.78 * f), weight: .regular, lineHeight: 1.30)
        myTranslation = Role(size: 0.86 * f, weight: .medium, lineHeight: 1.34)
    }

    /// F = B × clamp(√(W/760), 0.85, 1.30), then clamped to [14, B×1.3].
    public static func translationSize(base: Double, width: Double) -> Double {
        let w = width.isFinite && width > 0 ? width : referenceWidth
        let factor = min(1.30, max(0.85, (w / referenceWidth).squareRoot()))
        return min(base * 1.3, max(14, base * factor))
    }
}

/// Video caption sizes (§2): only the base size decides; width trims ±15% between 640 and
/// 1200 points. The narrow-window floors (§6) never raise the text above the chosen base.
public struct VideoCaptionTypography: Sendable, Equatable {
    public static let defaultBase: Double = 26
    public static let narrowWidth: Double = 640
    public static let wideWidth: Double = 1200

    public let translation: ConversationTypography.Role
    public let source: ConversationTypography.Role

    public init(base: Double, width: Double) {
        let b = base.isFinite && base > 0 ? base : Self.defaultBase
        translation = .init(size: Self.translationSize(base: b, width: width), weight: .semibold, lineHeight: 1.30)
        source = .init(size: max(14, 0.66 * b), weight: .regular, lineHeight: 1.30)
    }

    /// Linear from 0.85 B at 640 pt to 1.15 B at 1200 pt; flat outside; at least min(18, B).
    public static func translationSize(base: Double, width: Double) -> Double {
        let w = width.isFinite ? width : narrowWidth
        let t = min(1, max(0, (w - narrowWidth) / (wideWidth - narrowWidth)))
        return max(min(18, base), base * (0.85 + 0.30 * t))
    }
}

/// Fixed control text sizes (§2 字体), shared by the titlebar, popovers and the preview.
public enum ControlTypography {
    public static let capsule: Double = 11
    public static let chip: Double = 11
    public static let keyAction: Double = 11
    /// SF Mono, medium.
    public static let keycap: Double = 11
    public static let columnHeader: Double = 11
    public static let placeholder: Double = 13
    public static let fallbackBadge: Double = 10
    public static let titleScene: Double = 13
    public static let endButton: Double = 11
}
