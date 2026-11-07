import AppKit
import SwiftUI
import TalkTalkCore

// Fact chips, section headers and the row label style of the settings visual system
// (docs/decisions/2026-11-06-settings-visual-system.md §3.8, §3.11). Text parameters are
// already localized: callers pass `String(localized:)`.

private typealias Ladder = SubtitleTokens.SettingsIcon.Size

/// A visible fact in icon + shortest words (§3.11), in place of a gray paragraph: a 20 pt
/// capsule, 11 pt icon and 11 pt text (≤ 8 characters; the safety facts of §5.4 ≤ 16). Every
/// chip has its glyph: a neutral chip names it, `.cloud`, `.warn` and `.risk` draw their tone's.
/// `help` (≤ 20 characters) is required. VoiceOver reads `spoken`, the full sentence, when given,
/// else the chip text, and always `help` after it, so it hears at least what the pointer shows.
public struct FactChip: View {
    public enum Tone: Sendable {
        /// Secondary text.
        case neutral
        /// Text that leaves this Mac: the `network` glyph and accent text.
        case cloud
        case warn
        /// The other party can hear the original voice: the red risk glyph and red text.
        case risk
    }

    private let symbol: String
    private let text: String
    private let tone: Tone
    private let help: String
    private let spoken: String?

    /// A chip with its own glyph (a cloud or warn chip may name a more specific one). A risk chip
    /// always draws the risk glyph.
    public init(_ text: String, symbol: String, tone: Tone = .neutral, help: String, spoken: String? = nil) {
        self.text = text
        self.symbol = symbol
        self.tone = tone
        self.help = help
        self.spoken = spoken
    }

    /// Leaves this Mac (`network`, accent text).
    public static func cloud(_ text: String, help: String, spoken: String? = nil) -> FactChip {
        FactChip(text, symbol: SubtitleTokens.SettingsIcon.cloud, tone: .cloud, help: help, spoken: spoken)
    }

    /// Needs attention (the warning triangle, orange text).
    public static func warn(_ text: String, help: String, spoken: String? = nil) -> FactChip {
        FactChip(text, symbol: SubtitleTokens.SettingsIcon.statusWarn, tone: .warn, help: help, spoken: spoken)
    }

    /// The other party can hear the original voice (the risk glyph, red text).
    public static func risk(_ text: String, help: String, spoken: String? = nil) -> FactChip {
        FactChip(text, symbol: SettingsStatus.risk.symbol, tone: .risk, help: help, spoken: spoken)
    }

    public var body: some View {
        HStack(spacing: 4) {
            glyph.accessibilityHidden(true)
            Text(verbatim: text).font(.system(size: Ladder.badge)).lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .frame(height: Ladder.chipHeight)
        .background(Capsule().fill(.quaternary))
        .overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken ?? text)
        .accessibilityHint(Text(verbatim: help))
        .help(help)
    }

    @ViewBuilder private var glyph: some View {
        if tone == .risk, let image = RiskGlyph.image(Ladder.badge) {
            Image(nsImage: image)
        } else {
            Image(systemName: symbol).font(.system(size: Ladder.badge))
        }
    }

    private var foreground: AnyShapeStyle {
        switch tone {
        case .neutral: AnyShapeStyle(.secondary)
        case .cloud: AnyShapeStyle(.tint)
        case .warn: AnyShapeStyle(SettingsStatus.warn.textColor)
        case .risk: AnyShapeStyle(.red)
        }
    }

    private var stroke: AnyShapeStyle {
        tone == .risk ? AnyShapeStyle(Color.red.opacity(0.4)) : AnyShapeStyle(Color(nsColor: .separatorColor))
    }
}

/// Up to four fact chips in a row under the main graphic or a section's last row (§3.11).
/// When the row does not fit, the chips stack (`ViewThatFits`, no custom layout and no geometry
/// read back). `indented` starts the row at the row text inset (+30). `info`: the row's one ⓘ
/// (§3.9: at the row's end), kept beside the last chip when the chips stack.
public struct FactRow: View {
    private let chips: [FactChip]
    private let indented: Bool
    private let info: InfoButton?

    public init(_ chips: [FactChip], indented: Bool = false, info: InfoButton? = nil) {
        self.chips = Array(chips.prefix(4))
        self.indented = indented
        self.info = info
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                ForEach(chips.indices, id: \.self) { chips[$0] }
                info
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(chips.indices.dropLast()), id: \.self) { chips[$0] }
                HStack(spacing: 6) {
                    chips.last
                    info
                }
            }
        }
        .padding(.leading, indented ? Ladder.rowTextInset : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A Form section's header (§3.8): the anchoring node's glyph at 15 pt medium in the 22 pt
/// column, a title of at most four characters in 13 pt semibold, and an optional ⓘ. Give the
/// Section `.id(anchorID)` so a node can scroll to it.
public struct SectionHeader: View {
    private let title: String
    private let symbol: String
    private let info: [String]?

    /// `info`: the ⓘ popover's lines (a safety fact, at most one per section).
    public init(_ title: String, symbol: String, info: [String]? = nil) {
        self.title = title
        self.symbol = symbol
        self.info = info
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: Ladder.row, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: Ladder.rowColumn)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            if let info { InfoButton(topic: title, lines: info) }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Every Form row's label (§3.8): the icon at 15 pt regular, hierarchical secondary, centred in
/// the fixed 22 pt column, and the title from +30. App icons are drawn 15 × 15 by the caller.
/// Apply `.labelStyle(.settingsRow)` once at each Form's root; a destructive row takes
/// `.settingsRowDestructive` (icon and title red).
public struct SettingsRowLabelStyle: LabelStyle {
    private let destructive: Bool

    public init(destructive: Bool = false) { self.destructive = destructive }

    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .font(.system(size: Ladder.row, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(width: Ladder.rowColumn)
                .accessibilityHidden(true)
            if destructive {
                configuration.title.foregroundStyle(.red)
            } else {
                configuration.title
            }
        }
    }
}

extension LabelStyle where Self == SettingsRowLabelStyle {
    public static var settingsRow: SettingsRowLabelStyle { SettingsRowLabelStyle() }
    public static var settingsRowDestructive: SettingsRowLabelStyle { SettingsRowLabelStyle(destructive: true) }
}
