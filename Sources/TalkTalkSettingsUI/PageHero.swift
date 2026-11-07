import SwiftUI
import TalkTalkCore

// The opening graphic of a single page with no flow to draw (docs/decisions/
// 2026-11-06-settings-visual-system.md §3.2; §0.2 #1: no made-up flow). Text parameters are
// already localized: callers pass `String(localized:)`.

/// A page's status tile, 56 pt high, as the Form's first section without a header (§2 Z2): the
/// page's sidebar glyph at 22 pt (hierarchical, accent) on a 40 × 40 `.quaternary` tile with
/// 9 pt corners, then the page's status (its most severe problem as a `StatusLabel`, ok
/// "已就绪" when there is none, or a count and its facts), and page-level actions at the
/// trailing end (an `IconButton` or one `.bordered` button). The tile's help says what the page
/// is for. VoiceOver reads the tile and the status as one element, "<页名>, <状态>", with that
/// purpose as its hint; each trailing action is its own element.
public struct PageHero<Status: View, Trailing: View>: View {
    private let page: String
    private let symbol: String
    private let help: String
    private let status: Status
    private let trailing: Trailing

    private typealias Ladder = SubtitleTokens.SettingsIcon.Size
    private static var height: Double { 56 }
    private static var tile: Double { 40 }
    private static var radius: Double { 9 }

    /// `page`: the sidebar name, VoiceOver's first words. `symbol`: the sidebar glyph
    /// (`SettingsIcon.Page`). `help`: the page's purpose, at most 20 characters.
    public init(_ page: String, symbol: String, help: String, @ViewBuilder status: () -> Status,
                @ViewBuilder trailing: () -> Trailing) {
        self.page = page
        self.symbol = symbol
        self.help = help
        self.status = status()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: Ladder.card, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: Self.tile, height: Self.tile)
                    .background(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).fill(.quaternary))
                    .help(help)
                    .accessibilityLabel(page)
                status
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text(verbatim: help))
            Spacer(minLength: 8)
            trailing
        }
        .frame(height: Self.height)
    }
}

extension PageHero where Trailing == EmptyView {
    /// A hero with no page-level action (通用).
    public init(_ page: String, symbol: String, help: String, @ViewBuilder status: () -> Status) {
        self.init(page, symbol: symbol, help: help, status: status) { EmptyView() }
    }
}
