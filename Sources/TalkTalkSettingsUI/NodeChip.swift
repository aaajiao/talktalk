// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import SwiftUI
import TalkTalkCore

// A choice folded into a flow node (docs/decisions/2026-11-06-settings-visual-system.md §3.4):
// the source app, 对方语言, 我的译音 and similar, in place of separate Picker rows. Text
// parameters are already localized.

private typealias Ladder = SubtitleTokens.SettingsIcon.Size

/// One entry of a NodeChip's menu: a 13 pt glyph (or the app's own icon) and a title, a
/// check mark on the current choice; or a separator.
public struct NodeChipItem {
    public enum Glyph: Sendable, Equatable {
        case none
        case symbol(String)
        case app(bundleID: String)
        /// A chosen source that is not open now: the orange triangle.
        case warn
    }

    let title: String
    let glyph: Glyph
    let isOn: Bool
    let isEnabled: Bool
    let action: (() -> Void)?

    public init(_ title: String, glyph: Glyph = .none, isOn: Bool = false, isEnabled: Bool = true,
                action: @escaping () -> Void) {
        self.title = title
        self.glyph = glyph
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.action = action
    }

    private init() {
        title = ""
        glyph = .none
        isOn = false
        isEnabled = false
        action = nil
    }

    /// A line between groups of items.
    public static var separator: NodeChipItem { NodeChipItem() }
}

/// A 20 pt capsule on the quinary fill (§3.4): an optional orange 9 pt triangle (the source is
/// not open), a 12 pt app icon or an 11 pt symbol, 11 pt medium text truncated in the middle,
/// and the 8 pt `chevron.down`; locked during a session, `lock.fill` 9 pt replaces the chevron
/// and the menu does not open ("会话中不可更换" is then the caller's `help`); disabled by its
/// environment, it draws at half opacity, as a disabled control does. `width` fixes it
/// (the 34 pt language chip "EN"); otherwise it is as wide as its text and the text truncates
/// when the node is narrower. `help` carries the full name.
/// The menu is AppKit's (an `NSMenu` popped from an overlay view), so every item keeps its
/// image: a SwiftUI `Menu` on macOS flattens its label and its click area (step 1's measurement).
public struct NodeChip: View {
    public enum Leading: Sendable, Equatable {
        case none
        case symbol(String)
        case app(bundleID: String)
    }

    private let title: String
    private let leading: Leading
    private let width: Double?
    private let warn: Bool
    private let locked: Bool
    private let label: String
    private let help: String
    private let items: [NodeChipItem]
    @Environment(\.isEnabled) private var isEnabled

    /// `accessibilityLabel`: what the chip chooses ("声音来源", "对方语言", "我的译音"); its
    /// value is `title`.
    public init(_ title: String, leading: Leading = .none, width: Double? = nil, warn: Bool = false,
                locked: Bool = false, accessibilityLabel: String, help: String, items: [NodeChipItem]) {
        self.title = title
        self.leading = leading
        self.width = width
        self.warn = warn
        self.locked = locked
        self.label = accessibilityLabel
        self.help = help
        self.items = items
    }

    public var body: some View {
        // A fixed-width chip ("EN ▾" in 34 pt) packs its insets tighter so the code fits whole.
        HStack(spacing: width == nil ? 3 : 1) {
            if warn {
                Image(systemName: SubtitleTokens.SettingsIcon.statusWarn)
                    .font(.system(size: Ladder.micro, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            leadingGlyph
            Text(verbatim: title)
                .font(.system(size: Ladder.badge, weight: .medium))
                .foregroundStyle(locked ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: locked ? SubtitleTokens.SettingsIcon.locked : SubtitleTokens.VoiceIcon.chevron)
                .font(.system(size: locked ? Ladder.micro : SubtitleTokens.Size.capsuleChevronSize, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, width == nil ? 6 : 3)
        .frame(width: width.map { CGFloat($0) }, height: Ladder.chipHeight)
        .background(Capsule().fill(.quinary))
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityHidden(true)
        .overlay(NodeChipMenuTarget(value: title, label: label, help: help, enabled: !locked, items: items))
    }

    @ViewBuilder private var leadingGlyph: some View {
        switch leading {
        case .none:
            EmptyView()
        case let .symbol(name):
            Image(systemName: name).font(.system(size: Ladder.badge, weight: .regular)).foregroundStyle(.secondary)
        case let .app(bundleID):
            if let icon = AppIcon.image(bundleID) {
                Image(nsImage: icon).resizable().interpolation(.high)
                    .frame(width: Ladder.chipAppIcon, height: Ladder.chipAppIcon)
            } else {
                Image(systemName: SubtitleTokens.SettingsIcon.unknownApp)
                    .font(.system(size: Ladder.badge, weight: .regular)).foregroundStyle(.secondary)
            }
        }
    }
}

/// The chip's click, keyboard and VoiceOver target: a transparent view over the capsule that
/// pops the menu under itself on mouse-down, space, return or ↓, and reads as a pop-up button.
private struct NodeChipMenuTarget: NSViewRepresentable {
    let value: String
    let label: String
    let help: String
    let enabled: Bool
    let items: [NodeChipItem]

    func makeNSView(context: Context) -> NodeChipMenuView { NodeChipMenuView() }

    func updateNSView(_ view: NodeChipMenuView, context: Context) {
        view.items = items
        view.isEnabled = enabled && context.environment.isEnabled
        view.toolTip = help
        view.setAccessibilityLabel(label)
        view.setAccessibilityValue(value)
        view.setAccessibilityHelp(help)
    }
}

final class NodeChipMenuView: NSView {
    var items: [NodeChipItem] = []
    var isEnabled = true {
        didSet { setAccessibilityEnabled(isEnabled) }
    }
    private var menuOpen = false
    private var actions: [Int: () -> Void] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    /// While the menu is open the capsule reads as pressed.
    override func draw(_ dirtyRect: NSRect) {
        guard menuOpen else { return }
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        showMenu()
    }

    override func keyDown(with event: NSEvent) {
        // Space, return, keypad enter and ↓ open the menu, as a pop-up button.
        guard isEnabled, [49, 36, 76, 125].contains(event.keyCode) else {
            super.keyDown(with: event)
            return
        }
        showMenu()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        showMenu()
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool { accessibilityPerformPress() }

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var actions: [Int: () -> Void] = [:]
        for (index, item) in items.enumerated() {
            guard let action = item.action else {
                menu.addItem(.separator())
                continue
            }
            let entry = NSMenuItem(title: item.title, action: #selector(chooseItem(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            entry.image = Self.image(item.glyph)
            entry.state = item.isOn ? .on : .off
            entry.isEnabled = item.isEnabled
            actions[index] = action
            menu.addItem(entry)
        }
        self.actions = actions
        menuOpen = true
        needsDisplay = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
        menuOpen = false
        needsDisplay = true
    }

    @objc private func chooseItem(_ sender: NSMenuItem) { actions[sender.tag]?() }

    /// Menu glyphs at 13 pt (§3.4); app icons at the menu's 16 pt icon size, whose artwork
    /// reads as tall as a 13 pt symbol.
    private static func image(_ glyph: NodeChipItem.Glyph) -> NSImage? {
        switch glyph {
        case .none:
            return nil
        case let .symbol(name):
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Ladder.inline, weight: .regular))
        case let .app(bundleID):
            guard let icon = AppIcon.image(bundleID)?.copy() as? NSImage else { return nil }
            icon.size = NSSize(width: 16, height: 16)
            return icon
        case .warn:
            return SubtitleStyle.symbol(SubtitleTokens.SettingsIcon.statusWarn, size: Ladder.inline, weight: .regular,
                                        palette: [.systemOrange])
        }
    }
}
