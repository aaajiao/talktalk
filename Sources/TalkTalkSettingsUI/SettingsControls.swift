// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import SwiftUI
import TalkTalkCore

// Small shared controls of the settings visual system (docs/decisions/
// 2026-11-06-settings-visual-system.md §3.9, §3.10, §3.16): the subtitle window's capsule and
// keycap, ⓘ, and icon-only buttons. Text parameters are already localized: callers pass
// `String(appLocalized:)`.

private typealias IconSize = SubtitleTokens.SettingsIcon.Size

/// The subtitle window's voice capsule, read-only (no chevron, no details popover). In light
/// mode the token colours use their light-surface values.
public struct VoiceCapsule: NSViewRepresentable {
    let state: VoiceState
    @Environment(\.colorScheme) private var colorScheme

    public init(state: VoiceState) { self.state = state }

    public func makeNSView(context: NSViewRepresentableContext<Self>) -> VoiceCapsuleView {
        let view = VoiceCapsuleView(large: false)
        view.showsChevron = false
        return view
    }

    public func updateNSView(_ view: VoiceCapsuleView, context: NSViewRepresentableContext<Self>) {
        view.lightSurface = colorScheme == .light
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.apply(state, full: true) }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: VoiceCapsuleView,
                             context: NSViewRepresentableContext<Self>) -> CGSize? {
        CGSize(width: VoiceCapsuleView.width(for: state, full: true, large: false, chevron: false),
               height: SubtitleTokens.Size.controlHeight)
    }
}

/// The subtitle window's 右⌥ keycap with its action text, as a picture: settings never press it
/// (onboarding's 右⌥ permission row, flow nodes, the loop row). It is no accessibility element,
/// has no tooltip of its own and lets clicks through to whatever encloses it (a node's button);
/// the enclosing row, node accessory (`NodeAccessory.keycap`) or loop speaks for it and shows its
/// help. `showsAction` false draws the key alone.
public struct Keycap: View {
    let key: TitlebarKey
    let showsAction: Bool

    public init(key: TitlebarKey, showsAction: Bool = true) {
        self.key = key
        self.showsAction = showsAction
    }

    public var body: some View {
        // KeycapActionView is a titlebar control: as a subview it would take the click and,
        // without an action, drop it.
        KeycapPicture(key: key, showsAction: showsAction).allowsHitTesting(false)
    }
}

private struct KeycapPicture: NSViewRepresentable {
    let key: TitlebarKey
    let showsAction: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: NSViewRepresentableContext<Self>) -> KeycapActionView { KeycapActionView() }

    func updateNSView(_ view: KeycapActionView, context: NSViewRepresentableContext<Self>) {
        view.lightSurface = colorScheme == .light
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.apply(key, showsAction: showsAction) }
        view.setAccessibilityElement(false)
        view.toolTip = nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: KeycapActionView,
                      context: NSViewRepresentableContext<Self>) -> CGSize? {
        CGSize(width: KeycapActionView.width(for: key, showsAction: showsAction), height: SubtitleTokens.Size.controlHeight)
    }
}

extension TitlebarKey {
    /// The key and its action in words ("右⌥ 开始翻译"): the keycap's VoiceOver label and tooltip,
    /// also where a glyph replaces the drawn action.
    var spokenLabel: String { [key, action].compactMap { $0 }.joined(separator: " ") }
}

/// ⓘ (§3.9): only for the full sentence of a safety fact, a legal basis or a privacy promise,
/// in a 300 pt popover without a title. 13 pt regular `info.circle` in a 22 × 22 click area.
/// AppKit-backed: the CLT toolchain has no SwiftUIMacros plugin, so the popover state lives in
/// the coordinator, not in `@State`.
public struct InfoButton: NSViewRepresentable {
    /// What the popover explains ("会议同传"): several ⓘ on one page stay distinguishable.
    let topic: String
    let lines: [String]

    public init(topic: String, lines: [String]) {
        self.topic = topic
        self.lines = lines
    }

    @MainActor public final class Coordinator: NSObject {
        var lines: [String] = []
        let popover = NSPopover()

        override init() {
            super.init()
            popover.behavior = .transient
            popover.animates = false
        }

        @objc func toggle(_ sender: NSButton) {
            if popover.isShown { popover.performClose(sender); return }
            let content = VStack(alignment: .leading, spacing: 8) {
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(width: 300, alignment: .leading)
            let controller = NSHostingController(rootView: content)
            // Hosting starts with a zero-sized view. Give AppKit the final dimensions before
            // it positions the popover; resizing the hosted content after show can leave the
            // arrow far below its button inside a SwiftUI Form/ScrollView.
            controller.view.layoutSubtreeIfNeeded()
            let size = controller.view.fittingSize
            controller.view.setFrameSize(size)
            controller.preferredContentSize = size
            popover.contentViewController = controller
            popover.contentSize = size
            sender.window?.contentView?.layoutSubtreeIfNeeded()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: NSViewRepresentableContext<Self>) -> NSButton {
        let image = NSImage(systemSymbolName: SubtitleTokens.SettingsIcon.info, accessibilityDescription: nil) ?? NSImage()
        let button = NSButton(image: image, target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: IconSize.inline, weight: .regular)
        return button
    }

    public func updateNSView(_ button: NSButton, context: NSViewRepresentableContext<Self>) {
        context.coordinator.lines = lines
        let name = String(appLocalized: "\(topic)说明")
        button.toolTip = name
        button.setAccessibilityLabel(name)
        button.setAccessibilityHelp(lines.joined(separator: "\n"))
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton,
                             context: NSViewRepresentableContext<Self>) -> CGSize? {
        CGSize(width: IconSize.hitArea, height: IconSize.hitArea)
    }
}

/// An icon-only action (§3.10): borderless, 13 pt regular, 22 × 22 click area, secondary. Use
/// the fixed glyph for the action (`SettingsIcon.refresh`, `.reset`, `.remove`, `.add`,
/// `.close`, `.copy`, `.finder`, `.verify`, `.delete`, `.cancel`, `.openApp`). `help` is the
/// tooltip and, unless `accessibilityLabel` names more, the VoiceOver label. Deletion
/// uses the explicit destructive role and system red; other actions retain their neutral style.
public struct IconButton: View {
    private let symbol: String
    private let help: String
    private let label: String
    private let isDestructive: Bool
    private let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    /// `accessibilityLabel`: when the help alone does not name the object ("关闭" → "关闭返回提示").
    public init(_ symbol: String, help: String, accessibilityLabel: String? = nil,
                isDestructive: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.label = accessibilityLabel ?? help
        self.isDestructive = isDestructive
        self.action = action
    }

    public var body: some View {
        Button(role: isDestructive ? .destructive : nil, action: action) {
            Image(systemName: symbol)
                .font(.system(size: IconSize.inline, weight: .regular))
                .frame(width: IconSize.hitArea, height: IconSize.hitArea)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isDestructive && isEnabled ? Color(nsColor: .systemRed) : Color.secondary)
        .help(help)
        .accessibilityLabel(label)
    }
}

/// One entry of an `IconMenuButton` menu: a short title with its 13 pt glyph (§3.10: every item
/// carries an icon), or a separator. `title` is already localized.
public struct IconMenuItem {
    fileprivate let title: String
    fileprivate let symbol: String
    fileprivate let isEnabled: Bool
    fileprivate let isDestructive: Bool
    fileprivate let action: (() -> Void)?

    public init(_ title: String, symbol: String, isEnabled: Bool = true,
                isDestructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
        self.action = action
    }

    private init() {
        title = ""
        symbol = ""
        isEnabled = false
        isDestructive = false
        action = nil
    }

    /// A line between groups of items.
    public static var separator: IconMenuItem { IconMenuItem() }
}

/// A row's maintenance menu (§3.10): `ellipsis.circle` 13 pt, secondary, no indicator, in a
/// 22 × 22 click area. `help` ("维护引擎", "维护") is the tooltip and the VoiceOver label.
/// AppKit-backed: macOS draws a SwiftUI `Menu` as a popup button of its own intrinsic size
/// (about 21 × 15) whatever frame its label or the menu gets, so the click area would be
/// smaller than the 22 × 22 of every other icon-only control.
public struct IconMenuButton: NSViewRepresentable {
    let help: String
    let items: [IconMenuItem]

    public init(help: String, items: [IconMenuItem]) {
        self.help = help
        self.items = items
    }

    @MainActor public final class Coordinator: NSObject {
        var actions: [Int: () -> Void] = [:]

        @objc func chooseItem(_ sender: NSMenuItem) { actions[sender.tag]?() }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: NSViewRepresentableContext<Self>) -> NSPopUpButton {
        let button = IconPullDownButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    public func updateNSView(_ button: NSPopUpButton, context: NSViewRepresentableContext<Self>) {
        let coordinator = context.coordinator
        // A pull-down button shows its first item and lists the rest. A new menu, not edited in
        // place, so a menu that is open while the view updates keeps its items.
        let menu = NSMenu()
        menu.autoenablesItems = false
        let face = NSMenuItem()
        face.image = Self.image(SubtitleTokens.SettingsIcon.more)
        menu.addItem(face)
        var actions: [Int: () -> Void] = [:]
        for (index, item) in items.enumerated() {
            guard let action = item.action else {
                menu.addItem(.separator())
                continue
            }
            let entry = NSMenuItem(title: item.title, action: #selector(Coordinator.chooseItem(_:)), keyEquivalent: "")
            entry.target = coordinator
            entry.tag = index
            entry.image = Self.image(item.symbol)
            entry.isEnabled = item.isEnabled && context.environment.isEnabled
            if item.isDestructive {
                entry.attributedTitle = NSAttributedString(string: item.title, attributes: [
                    .foregroundColor: entry.isEnabled ? NSColor.systemRed : NSColor.disabledControlTextColor
                ])
            }
            actions[index] = action
            menu.addItem(entry)
        }
        coordinator.actions = actions
        button.menu = menu
        button.isEnabled = context.environment.isEnabled
        button.toolTip = help
        button.setAccessibilityLabel(help)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton,
                             context: NSViewRepresentableContext<Self>) -> CGSize? {
        CGSize(width: IconSize.hitArea, height: IconSize.hitArea)
    }

    private static func image(_ symbol: String) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: IconSize.inline, weight: .regular))
    }
}

/// A pull-down button laid out at exactly its frame: without the popup button's alignment insets
/// the 22 × 22 box is the whole click area and the glyph sits in its centre.
final class IconPullDownButton: NSPopUpButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
}
