// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import TalkTalkCore
import TalkTalkSettingsUI

/// Solid hover chrome shared by the three subtitle scenes. The panel owns its frame,
/// visibility and content measurements; caption opacity never changes this background.
@MainActor
final class SubtitleChromeView: NSView {
    var onHover: ((Bool) -> Void)?
    private var title: SubtitleTitleView?
    private var actions: SubtitleTitlebarView?
    private var hoverArea: NSTrackingArea?
    private var scene: SubtitleScene = .meeting
    private var display = SubtitleStyle.Display.current
    private let closeButton: NSButton?
    private let minimizeButton: NSButton?
    private let zoomButton: NSButton?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect = .zero) {
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel]
        closeButton = NSWindow.standardWindowButton(.closeButton, for: style)
        minimizeButton = NSWindow.standardWindowButton(.miniaturizeButton, for: style)
        zoomButton = NSWindow.standardWindowButton(.zoomButton, for: style)
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
        for button in [closeButton, minimizeButton, zoomButton].compactMap({ $0 }) {
            button.target = self
            button.refusesFirstResponder = true
            addSubview(button)
        }
        closeButton?.action = #selector(closeWindow(_:))
        minimizeButton?.action = #selector(minimizeWindow(_:))
        zoomButton?.action = #selector(zoomWindow(_:))
        apply(scene: .meeting)
    }

    required init?(coder: NSCoder) { nil }

    /// Reparent the existing scene title and controls without recreating their state.
    func install(title: SubtitleTitleView, actions: SubtitleTitlebarView) {
        if self.title !== title {
            self.title?.removeFromSuperview()
            self.title = title
            addSubview(title)
        }
        if self.actions !== actions {
            self.actions?.removeFromSuperview()
            self.actions = actions
            addSubview(actions)
        }
        title.apply(display: display)
        needsLayout = true
    }

    func apply(scene: SubtitleScene, display: SubtitleStyle.Display = .current) {
        self.scene = scene
        self.display = display
        // Resolve the system's solid dark window colour in this view's appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(1).cgColor
        }
        layer?.cornerRadius = scene == .video ? SubtitleTokens.Radius.videoGlass : SubtitleTokens.Radius.window
        layer?.borderWidth = display.increaseContrast ? 1 : 0
        layer?.borderColor = SubtitleStyle.color(.controlStroke, display: display).cgColor
        title?.apply(display: display)
        zoomButton?.isHidden = scene == .video
        closeButton?.toolTip = scene == .video
            ? String(localized: "隐藏字幕，收听和翻译继续") : String(localized: "隐藏字幕，同传继续")
        minimizeButton?.toolTip = scene == .video
            ? String(localized: "最小化字幕，收听和翻译继续") : String(localized: "最小化字幕，同传继续")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for (index, button) in [closeButton, minimizeButton, zoomButton].enumerated() {
            guard let button else { continue }
            let size = button.frame.size
            button.setFrameOrigin(NSPoint(x: 16 + CGFloat(index) * 20,
                                          y: ((bounds.height - size.height) / 2).rounded()))
        }
        if let title {
            title.frame = NSRect(x: SubtitleTitlebarView.leadingTitleX, y: 0,
                                 width: title.frame.width, height: bounds.height)
        }
        if let actions {
            actions.frame = NSRect(x: bounds.width - 16 - actions.frame.width, y: 0,
                                   width: actions.frame.width, height: bounds.height)
        }
    }

    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea === hoverArea { onHover?(true) }
        else { super.mouseEntered(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === hoverArea { onHover?(false) }
        else { super.mouseExited(with: event) }
    }

    @objc private func closeWindow(_ sender: Any?) { window?.performClose(sender) }
    @objc private func minimizeWindow(_ sender: Any?) { window?.miniaturize(sender) }
    @objc private func zoomWindow(_ sender: Any?) { window?.zoom(sender) }
}
