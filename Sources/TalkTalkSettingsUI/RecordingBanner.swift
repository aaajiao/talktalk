// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCore

// The pinned recording banner of 隐私与诊断 (docs/decisions/2026-11-06-settings-visual-system.md
// §2 Z1b, §3.14): a privacy fact that must not rest on an 11 pt card badge alone. Text parameters
// are already localized.

private typealias Ladder = SubtitleTokens.SettingsIcon.Size
private typealias Icon = SubtitleTokens.SettingsIcon

/// A 32 pt band across the detail column under the card row, outside the scroll view: red
/// (`record.circle.fill`) while a diagnostic recording runs, orange (`record.circle`) while the
/// subtitle analysis saves text or a recording is planned, a spinner while the analysis starts.
/// `link` leads to the sub-page that controls it (a trailing chevron, the whole band is the
/// button); pass nil on that sub-page itself.
public struct RecordingBanner: View {
    public enum Kind: Sendable {
        /// A diagnostic recording runs (录音中：…).
        case recording
        /// The subtitle analysis saves text (正在保存字幕文字).
        case analysing
        /// The subtitle analysis is creating its file.
        case preparing
        /// A diagnostic recording is set for this or the next meeting (本场将录音).
        case planned
    }

    private let text: String
    private let kind: Kind
    private let link: NodeLink?

    public static let height: Double = 32

    public init(_ text: String, kind: Kind, link: NodeLink? = nil) {
        self.text = text
        self.kind = kind
        self.link = link
    }

    public var body: some View {
        if let link {
            Button(action: link.action) { content(chevron: true) }
                .buttonStyle(.plain)
                .help(link.destination)
                .accessibilityLabel(Text(verbatim: text))
                .accessibilityHint(Text(verbatim: link.destination))
        } else {
            content(chevron: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: text))
        }
    }

    private func content(chevron: Bool) -> some View {
        HStack(spacing: 6) {
            glyph.accessibilityHidden(true)
            Text(verbatim: text).lineLimit(1)
            Spacer(minLength: 8)
            if chevron {
                Image(systemName: Icon.link)
                    .font(.system(size: Ladder.micro, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Ladder.hitArea, height: Ladder.hitArea)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
        .background(tint.opacity(0.10))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var glyph: some View {
        switch kind {
        case .recording:
            StatusGlyph(.recording)
        case .preparing:
            StatusGlyph(.busy)
        case .analysing, .planned:
            Image(systemName: Icon.recording)
                .font(.system(size: Ladder.inline, weight: .regular))
                .foregroundStyle(.orange)
        }
    }

    private var tint: Color { kind == .recording ? .red : .orange }
}
