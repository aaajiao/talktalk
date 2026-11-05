// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI

/// Shared by model and component tabs so selection, focus and hit areas stay consistent.
struct SettingsTabButton: View {
    let title: String
    let symbol: String
    let summary: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 22)).frame(height: 26)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                Text(title).font(.callout.weight(.semibold))
                Text(summary).font(.caption).foregroundStyle(.secondary)
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
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor).padding(8)
                    .accessibilityHidden(true).allowsHitTesting(false)
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(selected ? String(localized: "已选择") : "")
        .accessibilityHint(summary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
