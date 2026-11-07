import AppKit
import Testing
@testable import TalkTalkSettingsUI

@MainActor
@Suite(.serialized) struct TitlebarInteractionPanelTests {
    @Test func nativeTitlebarBandDeliversRealMouseEventsToCustomControls() {
        let fixture = makeFixture()
        defer { fixture.panel.orderOut(nil) }
        var clicks = 0
        fixture.first.onClick = { clicks += 1 }
        let point = fixture.first.convert(NSPoint(x: 50, y: 10), to: nil)
        #expect(point.y > fixture.panel.contentLayoutRect.maxY)
        fixture.panel.sendEvent(mouse(.leftMouseDown, at: point, in: fixture.panel))
        #expect(fixture.first.isPressed)
        fixture.panel.sendEvent(mouse(.leftMouseUp, at: point, in: fixture.panel))
        #expect(clicks == 1)
        #expect(!fixture.first.isPressed)
        #expect(!fixture.panel.isKeyWindow && !fixture.panel.isMainWindow)
    }

    @Test func draggingToAnotherControlCannotTriggerEitherAction() {
        let fixture = makeFixture()
        defer { fixture.panel.orderOut(nil) }
        var firstClicks = 0, secondClicks = 0
        fixture.first.onClick = { firstClicks += 1 }
        fixture.second.onClick = { secondClicks += 1 }
        let first = fixture.first.convert(NSPoint(x: 50, y: 10), to: nil)
        let second = fixture.second.convert(NSPoint(x: 20, y: 10), to: nil)
        fixture.panel.sendEvent(mouse(.leftMouseDown, at: first, in: fixture.panel))
        fixture.panel.sendEvent(mouse(.leftMouseDragged, at: second, in: fixture.panel))
        #expect(!fixture.first.isPressed)
        fixture.panel.sendEvent(mouse(.leftMouseUp, at: second, in: fixture.panel))
        #expect(firstClicks == 0 && secondClicks == 0)
    }

    @Test func hidingOrReplacingChromeCancelsItsPendingPress() {
        let fixture = makeFixture()
        defer { fixture.panel.orderOut(nil) }
        var clicks = 0
        fixture.first.onClick = { clicks += 1 }
        let point = fixture.first.convert(NSPoint(x: 50, y: 10), to: nil)
        fixture.panel.sendEvent(mouse(.leftMouseDown, at: point, in: fixture.panel))
        fixture.chrome.isHidden = true
        fixture.panel.sendEvent(mouse(.leftMouseUp, at: point, in: fixture.panel))
        #expect(clicks == 0 && !fixture.first.isPressed)
        fixture.chrome.isHidden = false
        fixture.panel.sendEvent(mouse(.leftMouseDown, at: point, in: fixture.panel))
        fixture.panel.interactiveTitlebar = nil
        #expect(!fixture.first.isPressed)
        fixture.panel.sendEvent(mouse(.leftMouseUp, at: point, in: fixture.panel))
        #expect(clicks == 0)
    }

    @Test func transparentAncestorsAndHiddenWindowsDoNotReceiveClicks() {
        let fixture = makeFixture()
        defer { fixture.panel.orderOut(nil) }
        var clicks = 0
        fixture.first.onClick = { clicks += 1 }
        let point = fixture.first.convert(NSPoint(x: 50, y: 10), to: nil)
        fixture.chrome.alphaValue = 0
        fixture.panel.sendEvent(mouse(.leftMouseDown, at: point, in: fixture.panel))
        fixture.panel.sendEvent(mouse(.leftMouseUp, at: point, in: fixture.panel))
        #expect(clicks == 0)
        fixture.chrome.alphaValue = 1
        fixture.panel.sendEvent(mouse(.leftMouseDown, at: point, in: fixture.panel))
        fixture.panel.orderOut(nil)
        fixture.panel.sendEvent(mouse(.leftMouseUp, at: point, in: fixture.panel))
        #expect(clicks == 0 && !fixture.first.isPressed)
    }

    @Test func inactiveOrCancelledPressCannotBecomeAnActionOnRelease() {
        let fixture = makeFixture()
        defer { fixture.panel.orderOut(nil) }
        var clicks = 0
        let point = fixture.first.convert(NSPoint(x: 50, y: 10), to: nil)
        fixture.first.onClick = { clicks += 1 }
        fixture.first.isEnabled = false
        fixture.panel.sendEvent(mouse(.leftMouseDown, at: point, in: fixture.panel))
        fixture.first.isEnabled = true
        fixture.panel.sendEvent(mouse(.leftMouseUp, at: point, in: fixture.panel))
        #expect(clicks == 0)
        fixture.first.onClick = nil
        fixture.panel.sendEvent(mouse(.leftMouseDown, at: point, in: fixture.panel))
        fixture.first.onClick = { clicks += 1 }
        fixture.panel.sendEvent(mouse(.leftMouseUp, at: point, in: fixture.panel))
        #expect(clicks == 0)
        fixture.panel.sendEvent(mouse(.leftMouseDown, at: point, in: fixture.panel))
        fixture.panel.cancelTitlebarInteraction()
        fixture.panel.sendEvent(mouse(.leftMouseUp, at: point, in: fixture.panel))
        #expect(clicks == 0 && !fixture.first.isPressed)
    }

    @Test func nativeButtonReceivesOriginalMouseDownWithoutSyntheticClick() {
        let fixture = makeFixture()
        defer { fixture.panel.orderOut(nil) }
        let button = ButtonTrackingProbe(frame: NSRect(x: 16, y: 9, width: 14, height: 14))
        fixture.chrome.addSubview(button)
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let press = mouse(.leftMouseDown, at: point, in: fixture.panel)
        fixture.panel.sendEvent(press)
        #expect(button.receivedMouseDown === press)
        #expect(button.mouseDownCount == 1 && button.syntheticClicks == 0)
    }

    private func makeFixture() -> (panel: OffscreenPanel, chrome: NSView,
                                   first: TitlebarControl, second: TitlebarControl) {
        _ = NSApplication.shared
        let panel = OffscreenPanel(contentRect: NSRect(x: -10_000, y: -10_000, width: 760, height: 512),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                               .nonactivatingPanel, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.superview?.superview?.isHidden = true
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: 760, height: 512))
        panel.contentView = content
        let chrome = FlippedView(frame: NSRect(x: 0, y: 0, width: 760, height: 32))
        content.addSubview(chrome)
        let first = TitlebarControl(frame: NSRect(x: 400, y: 6, width: 100, height: 20))
        let second = TitlebarControl(frame: NSRect(x: 540, y: 6, width: 40, height: 20))
        chrome.addSubview(first)
        chrome.addSubview(second)
        let label = NSTextField(labelWithString: "完成发言")
        label.frame = NSRect(x: 8, y: 1, width: 84, height: 18)
        first.addSubview(label)
        panel.interactiveTitlebar = chrome
        // Ordered for NSWindow event delivery, but physically off every display. The
        // constrain override prevents AppKit from pulling a sliver onto the user's screen.
        panel.orderFrontRegardless()
        return (panel, chrome, first, second)
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in panel: NSPanel) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                          timestamp: ProcessInfo.processInfo.systemUptime,
                          windowNumber: panel.windowNumber, context: nil, eventNumber: 1,
                          clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private final class OffscreenPanel: TitlebarInteractionPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// Exercise the panel-to-NSButton boundary without entering AppKit's nested tracking
    /// loop inside Swift Testing. Native factory-button tracking is checked separately in
    /// a standalone AppKit fixture; that loop can terminate the test runner's application.
    private final class ButtonTrackingProbe: NSButton {
        var receivedMouseDown: NSEvent?
        var mouseDownCount = 0
        var syntheticClicks = 0
        override func mouseDown(with event: NSEvent) {
            receivedMouseDown = event
            mouseDownCount += 1
        }
        override func performClick(_ sender: Any?) { syntheticClicks += 1 }
    }
}
