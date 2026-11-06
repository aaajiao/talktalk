import AppKit
import TalkTalkCore

/// AppKit factories for `SubtitleTokens` (redesign §2). Meeting rows, my rows, the settings
/// preview and video all take colours and fonts from here instead of fixed grays. Shared with
/// the settings components (settings visual system §3.0); the app adds `toneColor`, which needs
/// session state.
@MainActor
public enum SubtitleStyle {
    /// Accessibility display options, read together whenever
    /// `accessibilityDisplayOptionsDidChange` arrives.
    public struct Display: Equatable {
        public var increaseContrast: Bool
        public var reduceTransparency: Bool
        public var reduceMotion: Bool
        /// "Differentiate without colour": status that differs only by hue gets a shape too.
        public var differentiateWithoutColor = false

        public init(increaseContrast: Bool, reduceTransparency: Bool, reduceMotion: Bool,
                    differentiateWithoutColor: Bool = false) {
            self.increaseContrast = increaseContrast
            self.reduceTransparency = reduceTransparency
            self.reduceMotion = reduceMotion
            self.differentiateWithoutColor = differentiateWithoutColor
        }

        public static var current: Display {
            let workspace = NSWorkspace.shared
            return Display(increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
                           reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
                           reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
                           differentiateWithoutColor: workspace.accessibilityDisplayShouldDifferentiateWithoutColor)
        }
    }

    public static func color(_ role: SubtitleTokens.Color, display: Display = .current, lightSurface: Bool = false) -> NSColor {
        nsColor(role.rgba(increaseContrast: display.increaseContrast, lightSurface: lightSurface))
    }

    public static func nsColor(_ value: SubtitleTokens.RGBA) -> NSColor {
        NSColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
    }

    public static func white(_ alpha: CGFloat) -> NSColor { NSColor(white: 1, alpha: alpha) }

    /// A tail-truncating `NSTextField` sized to exactly its text width still shows "…"
    /// (seen in an offscreen render of the settings preview: "原声" became "…"). Labels get
    /// this much trailing room beyond their measured width; the glyphs do not move.
    public static let labelSlack: CGFloat = 4

    public static func weight(_ value: ConversationTypography.Weight) -> NSFont.Weight {
        switch value {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
    }

    public static func font(_ role: ConversationTypography.Role) -> NSFont {
        .systemFont(ofSize: role.size, weight: weight(role.weight))
    }

    /// Paragraph style that realises the role's line-height multiple.
    public static func paragraph(_ role: ConversationTypography.Role, alignment: NSTextAlignment = .left) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = alignment
        let font = font(role)
        let natural = font.ascender - font.descender + font.leading
        let target = role.size * role.lineHeight
        paragraph.lineSpacing = max(0, target - natural)
        return paragraph
    }

    public static func controlFont(_ size: Double = ControlTypography.capsule, weight: NSFont.Weight = .semibold) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    public static var keycapFont: NSFont { .monospacedSystemFont(ofSize: ControlTypography.keycap, weight: .medium) }

    /// Reading-text shadow below 0.75 opacity; nil otherwise.
    public static func readingShadow(opacity: Double) -> NSShadow? {
        guard SubtitleTokens.needsTextShadow(opacity: opacity) else { return nil }
        let token = SubtitleTokens.readingShadow
        let shadow = NSShadow()
        shadow.shadowColor = nsColor(token.color)
        shadow.shadowBlurRadius = token.blur
        shadow.shadowOffset = NSSize(width: token.offsetX, height: token.offsetY)
        return shadow
    }

    public static func duration(_ motion: SubtitleTokens.Motion, display: Display = .current) -> TimeInterval {
        motion.duration(reduceMotion: display.reduceMotion)
    }

    /// A template image filled with `color` (monochrome, so a symbol's cut-outs stay clear),
    /// for drawing outside an NSImageView's contentTintColor.
    public static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.accessibilityDescription = image.accessibilityDescription
        return tinted
    }

    /// SF Symbol image; `mic.badge.exclamationmark` falls back to mic.fill with an
    /// exclamationmark.circle.fill badge where the system lacks it. The badge sits in a
    /// cleared 1.5 pt ring so that, tinted to one colour, it stays a separate shape and the
    /// risk glyph never reads as plain mic.fill (原声). The result stays a template image, so
    /// contentTintColor and Increase Contrast still apply.
    /// `palette` (layer colours, e.g. [white, warn] for a white mark on a yellow triangle) or
    /// `hierarchical` (one base colour) give a coloured, non-template image instead.
    public static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .semibold,
                       accessibilityDescription: String? = nil, palette: [NSColor]? = nil,
                       hierarchical: NSColor? = nil) -> NSImage? {
        var configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        if let palette { configuration = configuration.applying(.init(paletteColors: palette)) }
        else if let hierarchical { configuration = configuration.applying(.init(hierarchicalColor: hierarchical)) }
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(configuration) {
            return image
        }
        guard name == SubtitleTokens.VoiceIcon.originalRisk,
              let base = NSImage(systemSymbolName: SubtitleTokens.VoiceIcon.original,
                                 accessibilityDescription: accessibilityDescription)?.withSymbolConfiguration(configuration),
              let badge = NSImage(systemSymbolName: SubtitleTokens.VoiceIcon.originalRiskFallbackBadge,
                                  accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size * 0.72, weight: .bold)) else { return nil }
        let ring: CGFloat = 1.5
        let size = NSSize(width: base.size.width + badge.size.width * 0.45, height: max(base.size.height, badge.size.height))
        let composed = NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(x: 0, y: 0, width: base.size.width, height: base.size.height))
            let badgeRect = NSRect(x: size.width - badge.size.width, y: size.height - badge.size.height,
                                   width: badge.size.width, height: badge.size.height)
            if let context = NSGraphicsContext.current {
                context.saveGraphicsState()
                context.compositingOperation = .destinationOut
                NSColor.black.setFill()
                NSBezierPath(ovalIn: badgeRect.insetBy(dx: -ring, dy: -ring)).fill()
                context.restoreGraphicsState()
            }
            badge.draw(in: badgeRect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        composed.isTemplate = true
        composed.accessibilityDescription = accessibilityDescription
        return composed
    }
}
