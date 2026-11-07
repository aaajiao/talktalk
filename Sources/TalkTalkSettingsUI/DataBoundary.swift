// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCore

// What stays on this Mac and what goes to OpenAI, as one two-panel graphic (docs/decisions/
// 2026-11-06-settings-visual-system.md §3.6): 模型 › 文本翻译, 隐私与诊断 › 数据与隐私 and
// onboarding step 5. Text parameters are already localized.

private typealias Ladder = SubtitleTokens.SettingsIcon.Size
private typealias Icon = SubtitleTokens.SettingsIcon

/// Two 56 pt `.quaternary` panels 12 pt apart. Left: `laptopcomputer` 18 pt over "本机" with a
/// `lock.fill` 11 pt badge, and the chip 声音 · 声音档案 · 录音. Right: `network` over "OpenAI"
/// and the cloud chip 文字 · 上下文 · 术语, with an `arrow.right` between the panels. While no
/// direction sends text to OpenAI (`cloudEnabled` false) the right panel is at 40 %, shows
/// `network.slash` and "未连接", and the arrow goes. `info`: the trailing ⓘ (the cloud notice);
/// `link`: the right panel opens that page (chevron at its corner). VoiceOver reads one group
/// named after both panels, "，未连接" appended when off. At the largest text sizes the panels
/// stack, the arrow pointing down.
public struct DataBoundary: View {
    private let cloudEnabled: Bool
    private let info: [String]?
    private let link: NodeLink?
    @Environment(\.dynamicTypeSize) private var typeSize

    static let height: Double = 56

    public init(cloudEnabled: Bool, info: [String]? = nil, link: NodeLink? = nil) {
        self.cloudEnabled = cloudEnabled
        self.info = info
        self.link = link
    }

    /// The whole graphic in words.
    static func spoken(cloudEnabled: Bool) -> String {
        cloudEnabled ? String(appLocalized: "本机：声音、声音档案、录音；OpenAI：文字、上下文、术语")
            : String(appLocalized: "本机：声音、声音档案、录音；OpenAI：文字、上下文、术语，未连接")
    }

    private static var localSpoken: String { String(appLocalized: "本机：声音、声音档案、录音") }

    private static func cloudSpoken(cloudEnabled: Bool) -> String {
        cloudEnabled ? String(appLocalized: "OpenAI：文字、上下文、术语")
            : String(appLocalized: "OpenAI：文字、上下文、术语，未连接")
    }

    public var body: some View {
        let stacked = typeSize.foldsSettingsGraphics
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            panel {
                caption(Icon.thisMac, String(appLocalized: "本机"), badge: Icon.locked)
                FactChip(String(appLocalized: "声音 · 声音档案 · 录音"), symbol: Icon.privacyPromise,
                         help: String(appLocalized: "不离开这台 Mac"))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: Self.localSpoken))
            if cloudEnabled {
                Image(systemName: Icon.flowArrow)
                    .font(.system(size: Ladder.badge, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(stacked ? 90 : 0))
                    .accessibilityHidden(true)
            }
            cloudPanel
            if let info { InfoButton(topic: String(appLocalized: "数据去向"), lines: info) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: Self.spoken(cloudEnabled: cloudEnabled)))
    }

    @ViewBuilder private var cloudPanel: some View {
        let content = panel(dimmed: !cloudEnabled) {
            caption(cloudEnabled ? Icon.cloud : Icon.cloudOff,
                    cloudEnabled ? "OpenAI" : String(appLocalized: "未连接"), badge: nil)
            FactChip.cloud(String(appLocalized: "文字 · 上下文 · 术语"), help: String(appLocalized: "只有要翻译的文字"))
        }
        if let link {
            Button(action: link.action) {
                content.overlay(alignment: .bottomTrailing) { FlowChevron().accessibilityHidden(true) }
            }
            .buttonStyle(.plain)
            .help(link.destination)
            .accessibilityLabel(Text(verbatim: Self.cloudSpoken(cloudEnabled: cloudEnabled)))
            .accessibilityHint(Text(verbatim: link.destination))
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: Self.cloudSpoken(cloudEnabled: cloudEnabled)))
        }
    }

    /// One panel: its caption column, then the chip.
    private func panel<Content: View>(dimmed: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
        .background(RoundedRectangle(cornerRadius: SubtitleTokens.Radius.settingsCard).fill(.quaternary))
        .contentShape(RoundedRectangle(cornerRadius: SubtitleTokens.Radius.settingsCard))
        .opacity(dimmed ? 0.4 : 1)
    }

    /// The 18 pt glyph over an 11 pt name (with its 11 pt badge), in a 52 pt column.
    private func caption(_ symbol: String, _ title: String, badge: String?) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: Ladder.node, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                Text(verbatim: title).font(.system(size: Ladder.badge)).lineLimit(1)
                if let badge {
                    Image(systemName: badge).font(.system(size: Ladder.badge)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 52)
    }
}
