import AppKit
import Testing
@testable import TalkTalkSettingsUI

@MainActor
@Suite struct TitlebarControlInteractionTests {
    /// The custom controls contain decorative AppKit views. Their icon and text must share
    /// the owning control's first-click and non-draggable mouse handling.
    @Test func iconAndTextHitTheOwningControl() {
        let fixture = makeFixture()
        for decoration in [fixture.icon, fixture.label] as [NSView] {
            let center = NSPoint(x: decoration.bounds.midX, y: decoration.bounds.midY)
            let point = decoration.convert(center, to: fixture.root)
            #expect(fixture.root.hitTest(point) === fixture.control)
        }
        #expect(fixture.control.acceptsFirstMouse(for: nil))
        #expect(!fixture.control.mouseDownCanMoveWindow)
    }

    @Test func nestedCoordinatesRespectTheControlBoundary() {
        let fixture = makeFixture()
        let control = fixture.control
        // Both the enclosing row and the flipped control have nonzero frame origins.
        let center = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: fixture.root)
        #expect(fixture.root.hitTest(center) === control)
        let outside = [
            NSPoint(x: -1, y: control.bounds.midY),
            NSPoint(x: control.bounds.maxX + 1, y: control.bounds.midY),
            NSPoint(x: control.bounds.midX, y: -1),
            NSPoint(x: control.bounds.midX, y: control.bounds.maxY + 1),
        ]
        for local in outside {
            let parentPoint = control.convert(local, to: fixture.row)
            #expect(control.hitTest(parentPoint) == nil)
            #expect(fixture.root.hitTest(control.convert(local, to: fixture.root)) !== control)
        }
    }

    @Test func hiddenControlOrAncestorCannotReceiveTheClick() {
        let fixture = makeFixture()
        let point = fixture.icon.convert(NSPoint(x: fixture.icon.bounds.midX, y: fixture.icon.bounds.midY),
                                         to: fixture.root)
        fixture.control.isHidden = true
        #expect(fixture.root.hitTest(point) !== fixture.control)
        fixture.control.isHidden = false
        fixture.row.isHidden = true
        #expect(fixture.root.hitTest(point) !== fixture.control)
        fixture.row.isHidden = false
        #expect(fixture.root.hitTest(point) === fixture.control)
    }

    @Test func completelyTransparentControlDoesNotInterceptTheClick() {
        let fixture = makeFixture()
        let point = fixture.icon.convert(NSPoint(x: fixture.icon.bounds.midX, y: fixture.icon.bounds.midY),
                                         to: fixture.root)
        fixture.control.alphaValue = 0
        #expect(fixture.root.hitTest(point) !== fixture.control)
        fixture.control.alphaValue = 1
        #expect(fixture.root.hitTest(point) === fixture.control)
    }

    private func makeFixture() -> (root: NSView, row: NSView, control: TitlebarControl,
                                   icon: NSImageView, label: NSTextField) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        let row = NSView(frame: NSRect(x: 63, y: 79, width: 300, height: 100))
        let control = TitlebarControl(frame: NSRect(x: 41, y: 27, width: 160, height: 32))
        root.addSubview(row)
        row.addSubview(control)
        let icon = NSImageView(frame: NSRect(x: 8, y: 9, width: 14, height: 14))
        icon.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil)
        let label = NSTextField(labelWithString: "完成发言")
        label.frame = NSRect(x: 30, y: 7, width: 90, height: 18)
        control.addSubview(icon)
        control.addSubview(label)
        return (root, row, control, icon, label)
    }
}
