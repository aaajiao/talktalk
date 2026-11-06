// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import Observation
import SwiftUI
import TalkTalkCore

private typealias Ladder = SubtitleTokens.SettingsIcon.Size

/// Back to the page a flow link came from (settings visual system §3.13, §6.4): a 24 pt
/// quaternary capsule with `chevron.left` 11 pt semibold, the source's 13 pt icon and its name
/// ("会议同传", "语音识别"; not "返回"), then the close icon button. The window's detail container
/// draws it once, in its Z0 slot, above the page's cards.
public struct ReturnPill: View {
    private let title: String
    private let symbol: String
    private let back: () -> Void
    private let dismiss: () -> Void

    public init(_ title: String, symbol: String, back: @escaping () -> Void, dismiss: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.back = back
        self.dismiss = dismiss
    }

    public var body: some View {
        let name = String(localized: "返回\(title)")
        HStack(spacing: 0) {
            Button(action: back) {
                HStack(spacing: 6) {
                    Image(systemName: SubtitleTokens.SettingsIcon.back)
                        .font(.system(size: Ladder.badge, weight: .semibold))
                    Image(systemName: symbol)
                        .font(.system(size: Ladder.inline, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                    Text(verbatim: title).font(.body).lineLimit(1)
                }
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(name)
            .accessibilityLabel(Text(verbatim: name))
            IconButton(SubtitleTokens.SettingsIcon.close, help: String(localized: "关闭"),
                       accessibilityLabel: String(localized: "关闭返回提示"), action: dismiss)
                .padding(.trailing, 1)
        }
        .frame(height: 24)
        .background(Capsule().fill(.quaternary))
        .fixedSize()
        .accessibilityElement(children: .contain)
    }
}

/// Flow diagram interaction state (§3.3, §6.3), held by the settings navigation: the section a
/// node scrolled to flashes a 2 pt accent outline once for 0.8 s; never with Reduce Motion.
@MainActor
@Observable
public final class FlowInteraction {
    /// The anchor id flashing now.
    public private(set) var flashed: String?
    @ObservationIgnored private var clearing: Task<Void, Never>?

    public init() {}

    public func flash(_ id: String) {
        clearing?.cancel()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            flashed = nil
            return
        }
        flashed = id
        clearing = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.flashed = nil
        }
    }
}
