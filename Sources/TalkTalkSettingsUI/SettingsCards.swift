// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import SwiftUI
import TalkTalkCore

// The one sub-page and scene navigation of the settings window (docs/decisions/
// 2026-11-06-settings-visual-system.md §3.1, §6): icon cards in a row pinned above the scroll
// view, never collapsed and never a segmented control. Text parameters are already localized.

private typealias Ladder = SubtitleTokens.SettingsIcon.Size

/// What a card's top-right corner says (§3.1). No badge means ready.
public struct CardBadge: Sendable, Equatable {
    public enum Glyph: Sendable, Equatable {
        /// A status glyph at 11 pt on its disc; `ok` is never drawn.
        case status(SettingsStatus)
        /// 文本翻译 while OpenAI translates: `network`, accent.
        case cloud
        /// 字幕分析 while it saves subtitle text: `record.circle`, orange.
        case analysing
    }

    public let glyph: Glyph
    /// The short cause ("可更新", "对方能听到原声"): the card's tooltip and VoiceOver value.
    public let reason: String

    public static func status(_ status: SettingsStatus, _ reason: String) -> CardBadge {
        CardBadge(glyph: .status(status), reason: reason)
    }

    public static func cloud(_ reason: String) -> CardBadge { CardBadge(glyph: .cloud, reason: reason) }

    public static func analysing(_ reason: String) -> CardBadge { CardBadge(glyph: .analysing, reason: reason) }

    /// The one corner shows the most severe candidate: failed > risk > recording > warn >
    /// pending > waiting > the information badges. Ties keep the earlier candidate; `ok` is
    /// dropped (no badge = ready).
    public static func mostSevere(_ candidates: [CardBadge?]) -> CardBadge? {
        var best: (badge: CardBadge, rank: Int)?
        for case let badge? in candidates {
            guard let rank = badge.rank else { continue }
            if best == nil || rank < best!.rank { best = (badge, rank) }
        }
        return best?.badge
    }

    var rank: Int? {
        switch glyph {
        case .status(.failed): 0
        case .status(.risk): 1
        case .status(.recording): 2
        case .status(.warn): 3
        case .status(.pending): 4
        case .status(.waiting), .status(.busy): 5
        case .analysing: 6
        case .cloud: 7
        case .status(.ok): nil
        }
    }

    /// "需要处理：<短因>" for a state that asks for something, the bare cause otherwise.
    var spoken: String {
        switch glyph {
        case .status(.failed), .status(.risk), .status(.warn), .status(.pending):
            String(appLocalized: "需要处理：\(reason)")
        default:
            reason
        }
    }
}

/// One card of a `CardRow`.
public struct CardItem<ID: Hashable>: Identifiable {
    public let id: ID
    public let title: String
    public let symbol: String
    /// What the page is for ("声音 → 原文"): the card's help and VoiceOver hint only.
    public let summary: String
    public let badge: CardBadge?
    /// Scene cards of a running session: the voice-coloured dot and the elapsed time.
    public let runningSince: Date?

    public init(id: ID, title: String, symbol: String, summary: String, badge: CardBadge? = nil,
                runningSince: Date? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.summary = summary
        self.badge = badge
        self.runningSince = runningSince
    }
}

/// A card (§3.1): 64 pt high, radius 10, bordered; a 22 pt hierarchical icon in a 28 × 24 box
/// over a one-line 13 pt semibold title, no summary line and no checkmark. Selected: 2 pt
/// accent stroke, 10 % accent fill and an accent icon (shape, fill and colour). Running: the
/// voice-coloured 8 pt dot and the elapsed time at the top left; the badge sits at the top
/// right. Only the clock text is in a TimelineView.
public struct SettingsCard: View {
    static let height: Double = 64
    private static let inset: Double = 6
    private static let radius = SubtitleTokens.Radius.settingsCard
    private static let runningColor = Color(nsColor: SubtitleStyle.color(.voiceOriginal))

    private let title: String
    private let symbol: String
    private let summary: String
    private let selected: Bool
    private let badge: CardBadge?
    private let runningSince: Date?
    private let multiSelect: Bool
    private let action: () -> Void

    /// `multiSelect`: one of several independent choices (onboarding); VoiceOver hears a toggle.
    public init(title: String, symbol: String, summary: String, selected: Bool, badge: CardBadge? = nil,
                runningSince: Date? = nil, multiSelect: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.summary = summary
        self.selected = selected
        self.badge = badge?.rank == nil ? nil : badge
        self.runningSince = runningSince
        self.multiSelect = multiSelect
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: Ladder.card, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 28, height: 24)
                    .accessibilityHidden(true)
                Text(verbatim: title).font(.body.weight(.semibold)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: Self.radius))
        // On the button itself: the running clock below is its own element, so VoiceOver hears
        // the live time right after the card instead of a value frozen at the last render.
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: accessibilityValue))
        .accessibilityHint(Text(verbatim: summary))
        .accessibilityAddTraits(multiSelect ? .isToggle : (selected ? .isSelected : []))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: Self.radius)
                    .fill(Color.accentColor.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: Self.radius).strokeBorder(Color.accentColor, lineWidth: 2))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            if let runningSince {
                HStack(spacing: 4) {
                    Circle().fill(Self.runningColor).frame(width: Ladder.runningDot, height: Ladder.runningDot)
                        .accessibilityHidden(true)
                    TimelineView(.periodic(from: runningSince, by: 1)) { context in
                        let elapsed = SessionClock.elapsed(context.date.timeIntervalSince(runningSince))
                        Text(verbatim: elapsed)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("运行时间"))
                            .accessibilityValue(Text(verbatim: elapsed))
                    }
                }
                .padding(Self.inset)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let badge {
                CardBadgeGlyph(glyph: badge.glyph)
                    .padding(Self.inset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .help(badge.map { "\(summary) · \($0.reason)" } ?? summary)
    }

    /// "已选择，运行中，需要处理：可更新"; the time is the clock element's ("运行时间 12:03").
    private var accessibilityValue: String {
        var parts: [String] = []
        if selected {
            parts.append(String(appLocalized: "已选择"))
        } else if multiSelect {
            parts.append(String(appLocalized: "未选择"))
        }
        if runningSince != nil {
            parts.append(String(appLocalized: "运行中"))
        }
        if let badge { parts.append(badge.spoken) }
        return parts.joined(separator: String(appLocalized: "，"))
    }
}

/// The corner glyph: 11 pt on the 15 pt window-coloured disc.
private struct CardBadgeGlyph: View {
    let glyph: CardBadge.Glyph

    var body: some View {
        switch glyph {
        case .status(let status):
            StatusGlyph(status, size: .badge)
        case .cloud:
            disc(SubtitleTokens.SettingsIcon.cloud, AnyShapeStyle(.tint))
        case .analysing:
            disc(SubtitleTokens.SettingsIcon.recording, AnyShapeStyle(Color.orange))
        }
    }

    private func disc(_ symbol: String, _ style: AnyShapeStyle) -> some View {
        Image(systemName: symbol)
            .font(.system(size: Ladder.badge, weight: .regular))
            .foregroundStyle(style)
            .frame(width: Ladder.badgeDisc, height: Ladder.badgeDisc)
            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
    }
}

/// The cards of one page in a row (§3.1, §6): equal widths, 12 pt apart, or 24 pt with an
/// `arrow.right` between them for the model page's steps. VoiceOver gets a container named
/// after the page. Place it outside the Form, at the top of the page's fixed band.
public struct CardRow<ID: Hashable>: View {
    private let label: String
    private let items: [CardItem<ID>]
    private let arrows: Bool
    private let multiSelect: Bool
    private let isSelected: (ID) -> Bool
    private let choose: (ID) -> Void

    /// One selection (a page's sub-page or the shared scene). `label`: the page's name.
    public init(_ label: String, items: [CardItem<ID>], selection: Binding<ID>, arrows: Bool = false) {
        self.label = label
        self.items = items
        self.arrows = arrows
        multiSelect = false
        isSelected = { $0 == selection.wrappedValue }
        choose = { selection.wrappedValue = $0 }
    }

    /// Several independent choices (onboarding's scenarios): every card toggles itself.
    public init(_ label: String, items: [CardItem<ID>], selected: Set<ID>, toggle: @escaping (ID) -> Void) {
        self.label = label
        self.items = items
        arrows = false
        multiSelect = true
        isSelected = { selected.contains($0) }
        choose = toggle
    }

    public var body: some View {
        HStack(spacing: arrows ? 0 : 12) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                if arrows, index > 0 {
                    Image(systemName: SubtitleTokens.SettingsIcon.flowArrow)
                        .font(.system(size: Ladder.badge, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                }
                SettingsCard(title: item.title, symbol: item.symbol, summary: item.summary,
                             selected: isSelected(item.id), badge: item.badge, runningSince: item.runningSince,
                             multiSelect: multiSelect) { choose(item.id) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: label))
    }
}

/// Page-wide switches above a page's cards (§2 Z1a; only 字幕): one 28 pt line, left aligned,
/// each a switch with its 15 pt icon in the row column. Its place above the scene cards says
/// "every scene", so no label says it.
public struct GlobalRow<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        HStack(spacing: 24) { content }
            .labelStyle(.settingsRow)
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
    }
}
