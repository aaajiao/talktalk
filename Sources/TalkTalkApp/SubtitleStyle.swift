import AppKit
import TalkTalkCore

/// AppKit factories for `SubtitleTokens` (redesign §2). Meeting rows, my rows, the settings
/// preview and video all take colours and fonts from here instead of fixed grays.
@MainActor
enum SubtitleStyle {
    /// Accessibility display options, read together whenever
    /// `accessibilityDisplayOptionsDidChange` arrives.
    struct Display: Equatable {
        var increaseContrast: Bool
        var reduceTransparency: Bool
        var reduceMotion: Bool

        static var current: Display {
            let workspace = NSWorkspace.shared
            return Display(increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
                           reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
                           reduceMotion: workspace.accessibilityDisplayShouldReduceMotion)
        }
    }

    static func color(_ role: SubtitleTokens.Color, display: Display = .current, lightSurface: Bool = false) -> NSColor {
        nsColor(role.rgba(increaseContrast: display.increaseContrast, lightSurface: lightSurface))
    }

    static func nsColor(_ value: SubtitleTokens.RGBA) -> NSColor {
        NSColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
    }

    static func white(_ alpha: CGFloat) -> NSColor { NSColor(white: 1, alpha: alpha) }

    /// A tail-truncating `NSTextField` sized to exactly its text width still shows "…"
    /// (seen in an offscreen render of the settings preview: "原声" became "…"). Labels get
    /// this much trailing room beyond their measured width; the glyphs do not move.
    static let labelSlack: CGFloat = 4

    static func weight(_ value: ConversationTypography.Weight) -> NSFont.Weight {
        switch value {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
    }

    static func font(_ role: ConversationTypography.Role) -> NSFont {
        .systemFont(ofSize: role.size, weight: weight(role.weight))
    }

    /// Paragraph style that realises the role's line-height multiple.
    static func paragraph(_ role: ConversationTypography.Role, alignment: NSTextAlignment = .left) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = alignment
        let font = font(role)
        let natural = font.ascender - font.descender + font.leading
        let target = role.size * role.lineHeight
        paragraph.lineSpacing = max(0, target - natural)
        return paragraph
    }

    static func controlFont(_ size: Double = ControlTypography.capsule, weight: NSFont.Weight = .semibold) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static var keycapFont: NSFont { .monospacedSystemFont(ofSize: ControlTypography.keycap, weight: .medium) }

    /// Reading-text shadow below 0.75 opacity; nil otherwise.
    static func readingShadow(opacity: Double) -> NSShadow? {
        guard SubtitleTokens.needsTextShadow(opacity: opacity) else { return nil }
        let token = SubtitleTokens.readingShadow
        let shadow = NSShadow()
        shadow.shadowColor = nsColor(token.color)
        shadow.shadowBlurRadius = token.blur
        shadow.shadowOffset = NSSize(width: token.offsetX, height: token.offsetY)
        return shadow
    }

    static func duration(_ motion: SubtitleTokens.Motion, display: Display = .current) -> TimeInterval {
        motion.duration(reduceMotion: display.reduceMotion)
    }

    /// SF Symbol image; `mic.badge.exclamationmark` falls back to mic.fill with an
    /// exclamationmark.circle.fill badge where the system lacks it.
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .semibold,
                       accessibilityDescription: String? = nil) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(configuration) {
            return image
        }
        guard name == SubtitleTokens.VoiceIcon.originalRisk,
              let base = NSImage(systemSymbolName: SubtitleTokens.VoiceIcon.original,
                                 accessibilityDescription: accessibilityDescription)?.withSymbolConfiguration(configuration),
              let badge = NSImage(systemSymbolName: SubtitleTokens.VoiceIcon.originalRiskFallbackBadge,
                                  accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size * 0.6, weight: .bold)) else { return nil }
        let size = NSSize(width: base.size.width + badge.size.width * 0.45, height: max(base.size.height, badge.size.height))
        let composed = NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(x: 0, y: 0, width: base.size.width, height: base.size.height))
            badge.draw(in: NSRect(x: size.width - badge.size.width, y: size.height - badge.size.height,
                                  width: badge.size.width, height: badge.size.height))
            return true
        }
        composed.isTemplate = true
        composed.accessibilityDescription = accessibilityDescription
        return composed
    }
}
