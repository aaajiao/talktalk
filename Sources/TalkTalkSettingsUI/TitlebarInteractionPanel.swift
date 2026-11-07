import AppKit

/// AppKit reserves a titled panel's native titlebar band even with a full-size content view
/// and hidden native chrome. Deliver only our visible controls in that band (or a moved
/// video bar) directly; background dragging, resizing and every other event stay native.
@MainActor
open class TitlebarInteractionPanel: NSPanel {
    public weak var interactiveTitlebar: NSView? {
        didSet {
            if interactiveTitlebar !== oldValue { cancelTitlebarInteraction() }
        }
    }
    private weak var trackingControl: TitlebarControl?
    /// A cancelled/disabled custom press still owns its remaining drag/up. AppKit never
    /// received its mouse-down, so those events must not fall into native titlebar handling.
    private var customPressInFlight = false

    /// A scene change or presentation hide cancels a press before its eventual mouse-up.
    public func cancelTitlebarInteraction() {
        trackingControl?.clearHover()
        trackingControl = nil
    }

    open override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            cancelTitlebarInteraction()
            customPressInFlight = false
            if let target = titlebarTarget(for: event) {
                guard isLive(target) else { customPressInFlight = true; return }
                if let control = target as? TitlebarControl {
                    customPressInFlight = true
                    guard control.isEnabled, control.onClick != nil else { return }
                    trackingControl = control
                    control.mouseDown(with: event)
                } else if let button = target as? NSButton {
                    // NSButton owns its tracking loop, including drag/up and cancellation.
                    // Do not capture it or synthesize a second mouse-up/action.
                    button.mouseDown(with: event)
                }
                return
            }
        case .leftMouseDragged:
            if customPressInFlight {
                guard let control = trackingControl else { return }
                guard isLiveTitlebarControl(control) else { cancelTitlebarInteraction(); return }
                control.mouseDragged(with: event)
                return
            }
        case .leftMouseUp:
            if customPressInFlight {
                customPressInFlight = false
                guard let control = trackingControl else { return }
                trackingControl = nil
                guard isLiveTitlebarControl(control) else { control.clearHover(); return }
                // Keep the mouse-down target: dragging from one control to another must
                // never trigger the second control. Its own bounds decide whether to act.
                control.mouseUp(with: event)
                return
            }
        default: break
        }
        super.sendEvent(event)
    }

    private func titlebarTarget(for event: NSEvent) -> NSView? {
        guard let bar = interactiveTitlebar, bar.window === self,
              bar.bounds.contains(bar.convert(event.locationInWindow, from: nil)) else { return nil }
        let point = bar.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        var hit = bar.hitTest(point)
        while let view = hit, view !== bar {
            if view is TitlebarControl || view is NSButton { return view }
            hit = view.superview
        }
        return nil
    }

    private func isLiveTitlebarControl(_ control: TitlebarControl) -> Bool {
        guard let bar = interactiveTitlebar, control.isDescendant(of: bar) else { return false }
        return isLive(control)
    }

    private func isLive(_ view: NSView) -> Bool {
        guard isVisible, !ignoresMouseEvents, view.window === self else { return false }
        var ancestor: NSView? = view
        while let current = ancestor {
            guard !current.isHidden, current.alphaValue > 0 else { return false }
            ancestor = current.superview
        }
        return true
    }
}
