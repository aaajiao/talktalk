// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import TalkTalkCore
import TalkTalkSession

extension NSAttributedString.Key {
    /// Marks the open draft translation; its column draws the 2 pt draft bar beside it.
    static let talkTalkDraft = NSAttributedString.Key("TalkTalkDraft")
    /// Tooltip and VoiceOver text of an inline badge attachment.
    static let talkTalkBadgeHelp = NSAttributedString.Key("TalkTalkBadgeHelp")
}

/// Attributed text for the remote rows and my rows (redesign §2, §4 三态). Both rows take the
/// same `ConversationTypography`, colours, shadow and badges from here.
@MainActor
struct ConversationText {
    let typography: ConversationTypography
    let display: SubtitleStyle.Display
    /// Reading shadow below 0.75 opacity; nil otherwise.
    let shadow: NSShadow?
    var paragraphSpacing: CGFloat = 12

    init(typography: ConversationTypography, opacity: Double, display: SubtitleStyle.Display = .current,
         paragraphSpacing: CGFloat = 12) {
        self.typography = typography
        self.display = display
        self.shadow = SubtitleStyle.readingShadow(opacity: opacity)
        self.paragraphSpacing = paragraphSpacing
    }

    enum Speaker { case remote, me }

    func attributes(_ role: ConversationTypography.Role, color: SubtitleTokens.Color) -> [NSAttributedString.Key: Any] {
        attributes(role, color: SubtitleStyle.color(color, display: display))
    }

    func attributes(_ role: ConversationTypography.Role, color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = SubtitleStyle.paragraph(role)
        paragraph.paragraphSpacing = paragraphSpacing
        var result: [NSAttributedString.Key: Any] = [
            .font: SubtitleStyle.font(role), .foregroundColor: color, .paragraphStyle: paragraph,
        ]
        if let shadow { result[.shadow] = shadow }
        return result
    }

    /// Starts a new paragraph when the output already has text.
    private func separate(_ output: NSMutableAttributedString, role: ConversationTypography.Role) {
        guard output.length > 0 else { return }
        output.append(NSAttributedString(string: "\n", attributes: attributes(role, color: .textSource)))
    }

    /// Final source (text.source) or live recognized source (text.sourceLive plus a static caret).
    func appendSource(_ text: String, live: Bool, speaker: Speaker, to output: NSMutableAttributedString) {
        guard !text.isEmpty else { return }
        separate(output, role: typography.source)
        let attributes = attributes(typography.source, color: live ? .textSourceLive : .textSource)
        output.append(NSAttributedString(string: text, attributes: attributes))
        if live { output.append(caret(speaker: speaker, attributes: attributes)) }
    }

    /// Final translation (text.primary) or draft (text.draft, "…", draft bar). Draft and final
    /// share size and weight, so finalization only changes colour.
    func appendTranslation(_ text: String, role: ConversationTypography.Role, isFinal: Bool, fallback: Bool,
                           to output: NSMutableAttributedString) {
        let value = isFinal ? text : ConversationTextRules.draftDisplay(text)
        guard !value.isEmpty else { return }
        separate(output, role: role)
        var attributes = attributes(role, color: isFinal ? .textPrimary : .textDraft)
        if !isFinal { attributes[.talkTalkDraft] = true }
        output.append(NSAttributedString(string: value, attributes: attributes))
        if isFinal, fallback { output.append(fallbackBadge(role: role, attributes: attributes)) }
    }

    /// "未发送" badge at the source size, followed by the preview-only tail (§4 送达标签).
    func appendUnsent(_ text: String, to output: NSMutableAttributedString) {
        guard !text.isEmpty else { return }
        separate(output, role: typography.source)
        let attributes = attributes(typography.source, color: .warn)
        output.append(Self.badge(String(localized: "未发送"), symbol: ConversationTextRules.unsentSymbol,
                                 font: SubtitleStyle.font(typography.source),
                                 text: SubtitleStyle.color(.warn, display: display),
                                 fill: SubtitleStyle.color(.warn, display: display)
                                    .withAlphaComponent(ConversationTextRules.unsentBadgeFillAlpha),
                                 help: String(localized: "未发送"), attributes: attributes))
        output.append(NSAttributedString(string: " " + text, attributes: attributes))
    }

    /// Delivery label after my translation (§4 送达标签): 18 pt high, 11 pt medium. "未发送" sits on
    /// a warn 15% fill at the source size; the others are coloured text with an optional icon.
    func appendDelivery(_ delivery: ConversationTimeline.Delivery, role: ConversationTypography.Role,
                        to output: NSMutableAttributedString) {
        let base = attributes(role, color: .textPrimary)
        let warn = SubtitleStyle.color(.warn, display: display)
        let font: NSFont, text: NSColor, fill: NSColor
        switch delivery {
        case .notSent:
            font = .systemFont(ofSize: typography.source.size, weight: .medium)
            text = warn
            fill = warn.withAlphaComponent(ConversationTextRules.unsentBadgeFillAlpha)
        case .sent, .phoneSent:
            font = .systemFont(ofSize: ControlTypography.chip, weight: .medium)
            text = SubtitleStyle.color(.voiceOriginal, display: display)
            fill = .clear
        case .phoneLocalOnly, .aborted:
            font = .systemFont(ofSize: ControlTypography.chip, weight: .medium)
            text = warn
            fill = .clear
        }
        output.append(Self.badge(delivery.title, symbol: delivery.symbol, font: font, text: text, fill: fill,
                                 help: delivery.title, baseFont: SubtitleStyle.font(role), attributes: base,
                                 leadingSpace: true, minHeight: Self.deliveryHeight))
    }

    static let deliveryHeight: CGFloat = 18

    /// A 2 × 0.7F static bar after live source; it never blinks.
    private func caret(speaker: Speaker, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let height = CGFloat(ConversationTextRules.caretHeight(translationSize: typography.remoteTranslation.size))
        let width = CGFloat(ConversationTextRules.caretWidth)
        let color = SubtitleStyle.color(speaker == .remote ? .speakerRemote : .voiceTranslate, display: display)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        let font = SubtitleStyle.font(typography.source)
        attachment.bounds = NSRect(x: 0, y: font.descender * 0.5, width: width, height: height)
        let result = NSMutableAttributedString(string: "\u{2009}", attributes: attributes)
        var caretAttributes = attributes
        caretAttributes[.attachment] = attachment
        caretAttributes[.talkTalkBadgeHelp] = ""
        caretAttributes[.shadow] = nil
        result.append(NSAttributedString(string: "\u{FFFC}", attributes: caretAttributes))
        return result
    }

    /// The 10 pt "备用翻译" badge after an Apple-fallback final.
    private func fallbackBadge(role: ConversationTypography.Role, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        Self.fallbackBadge(baseFont: SubtitleStyle.font(role), attributes: attributes)
    }

    static func fallbackBadge(baseFont: NSFont, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        badge(String(localized: "备用翻译"), symbol: nil,
              font: .systemFont(ofSize: ControlTypography.fallbackBadge, weight: .medium),
              text: SubtitleStyle.white(ConversationTextRules.fallbackBadgeTextAlpha),
              fill: SubtitleStyle.white(ConversationTextRules.fallbackBadgeFillAlpha),
              help: fallbackHelp, baseFont: baseFont, attributes: attributes, leadingSpace: true)
    }

    static var fallbackHelp: String { String(localized: "云端不可用，本句由 Apple 翻译") }

    /// An inline capsule drawn as an image attachment, vertically centred on the text.
    static func badge(_ title: String, symbol: String?, font: NSFont, text: NSColor, fill: NSColor, help: String,
                      baseFont: NSFont? = nil, attributes: [NSAttributedString.Key: Any],
                      leadingSpace: Bool = false, minHeight: CGFloat = 0) -> NSAttributedString {
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: text]
        let titleSize = (title as NSString).size(withAttributes: titleAttributes)
        let icon = symbol.flatMap { SubtitleStyle.symbol($0, size: font.pointSize * 0.85, weight: .medium) }
        let iconWidth = icon.map { $0.size.width + 3 } ?? 0
        let horizontal: CGFloat = font.pointSize < 12 ? 5 : 6
        let height = max(minHeight, ceil(titleSize.height + 2))
        let width = ceil(titleSize.width + iconWidth + 2 * horizontal)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            var x = horizontal
            if let icon {
                let tinted = NSImage(size: icon.size, flipped: false) { iconRect in
                    icon.draw(in: iconRect)
                    text.set()
                    iconRect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: x, y: (rect.height - icon.size.height) / 2,
                                       width: icon.size.width, height: icon.size.height))
                x += iconWidth
            }
            (title as NSString).draw(at: NSPoint(x: x, y: (rect.height - titleSize.height) / 2), withAttributes: titleAttributes)
            return true
        }
        image.accessibilityDescription = help
        let attachment = NSTextAttachment()
        attachment.image = image
        let reference = baseFont ?? font
        attachment.bounds = NSRect(x: 0, y: (reference.capHeight - height) / 2, width: width, height: height)
        let result = NSMutableAttributedString()
        if leadingSpace { result.append(NSAttributedString(string: " ", attributes: attributes)) }
        var badgeAttributes = attributes
        badgeAttributes[.attachment] = attachment
        badgeAttributes[.talkTalkBadgeHelp] = help
        badgeAttributes[.shadow] = nil
        badgeAttributes[.talkTalkDraft] = nil
        result.append(NSAttributedString(string: "\u{FFFC}", attributes: badgeAttributes))
        return result
    }

    /// VoiceOver text: badges read as their help text, carets are silent.
    static func accessibilityText(_ text: NSAttributedString) -> String {
        var result = ""
        let string = text.string as NSString
        text.enumerateAttribute(.talkTalkBadgeHelp, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let help = value as? String {
                if !help.isEmpty { result += " " + help + " " }
            } else {
                result += string.substring(with: range)
            }
        }
        return result.replacingOccurrences(of: "\u{2009}", with: "")
    }
}
