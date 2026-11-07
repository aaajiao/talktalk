import AppKit
import SwiftUI

/// A destructive settings entry with the system's small push-button bezel. On macOS,
/// bordered SwiftUI buttons do not consistently colour their label from their role or tint.
/// Keep the native control and express the destructive intent in its attributed title.
public struct SettingsDestructiveButton: NSViewRepresentable {
    private let title: String
    private let help: String?
    private let spokenLabel: String?
    private let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    /// Strings are already localized by the caller. Standard SwiftUI help and accessibility
    /// modifiers can also be applied to this view at the call site.
    public init(_ title: String, help: String? = nil, accessibilityLabel: String? = nil,
                action: @escaping () -> Void) {
        self.title = title
        self.help = help
        self.spokenLabel = accessibilityLabel
        self.action = action
    }

    @MainActor public final class Coordinator: NSObject {
        var action: (() -> Void)?

        @objc func performAction(_ sender: NSButton) {
            guard sender.isEnabled else { return }
            action?()
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: NSViewRepresentableContext<Self>) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator,
                              action: #selector(Coordinator.performAction(_:)))
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .push
        button.controlSize = .small
        button.isBordered = true
        button.hasDestructiveAction = true
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .vertical)
        return button
    }

    public func updateNSView(_ button: NSButton, context: NSViewRepresentableContext<Self>) {
        context.coordinator.action = action
        button.isEnabled = isEnabled
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small)),
            // Keep NSColor values dynamic for Light/Dark Mode; do not resolve to CGColor.
            .foregroundColor: isEnabled ? NSColor.systemRed : NSColor.disabledControlTextColor,
            .paragraphStyle: paragraph,
        ])
        button.toolTip = help
        button.setAccessibilityLabel(spokenLabel ?? title)
        button.invalidateIntrinsicContentSize()
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton,
                             context: NSViewRepresentableContext<Self>) -> CGSize? {
        nsView.intrinsicContentSize
    }
}
