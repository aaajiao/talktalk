// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCore

/// Shared by model and component tabs, the scenario cards and onboarding's scenario choice, so
/// selection, focus and hit areas stay consistent. `running` (§7) is independent of `selected`:
/// an 8 pt voice.original dot at the top left and a green caption2 subtitle.
struct SettingsTabButton: View {
    let title: String
    let symbol: String
    let summary: String
    let selected: Bool
    var running = false
    /// "运行中 · 12:03"; replaces the summary while running.
    var runningSubtitle: String?
    let action: () -> Void

    private static let runningGreen = Color(nsColor: SubtitleStyle.color(.voiceOriginal))

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 22)).frame(height: 26)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                Text(title).font(.callout.weight(.semibold))
                if running, let runningSubtitle {
                    Text(runningSubtitle).font(.caption2.monospacedDigit()).foregroundStyle(Self.runningGreen)
                } else {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 88)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            if running {
                Circle().fill(Self.runningGreen).frame(width: 8, height: 8).padding(9)
                    .accessibilityHidden(true).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor).padding(8)
                    .accessibilityHidden(true).allowsHitTesting(false)
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(summary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var accessibilityValue: String {
        switch (selected, running) {
        case (true, true): String(localized: "已选择，\(runningSubtitle ?? String(localized: "运行中"))")
        case (true, false): String(localized: "已选择")
        case (false, true): runningSubtitle ?? String(localized: "运行中")
        case (false, false): ""
        }
    }
}
