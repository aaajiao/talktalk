import AppKit

/// A transparent, timer-free sine curve driven by microphone RMS behind one reading cell.
/// It never scrolls, changes the window material, or animates without incoming measurements.
@MainActor
final class AudioActivityBackdrop: NSView {
    private var amplitude: CGFloat?
    private var accessibilityObserver: NSObjectProtocol?

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsDisplay = true }
            }
    }

    required init?(coder: NSCoder) { return nil }

    isolated deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func setLevel(_ level: Float?, preview: Bool = false) {
        // Preview amplitudes are static examples and may be configured before attachment.
        // Real input never survives a hidden window and must arrive fresh after restoration.
        guard preview || (window?.isVisible == true && window?.isMiniaturized == false && !isHiddenOrHasHiddenAncestor) else {
            clear()
            return
        }
        guard let level, level.isFinite else {
            clear()
            return
        }
        // Map actual RMS to a readable curve. A true zero remains flat; the shape has no
        // independently advancing phase, decorative minimum amplitude or idle animation.
        let normalized = level > 0 ? CGFloat(max(0, min(1, (20 * log10(Double(level)) + 60) / 60))) : 0
        guard amplitude != normalized else { return }
        amplitude = normalized
        needsDisplay = true
    }

    private func clear() {
        guard amplitude != nil else { return }
        amplitude = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let amplitude, let window, window.isVisible, !window.isMiniaturized,
              !isHiddenOrHasHiddenAncestor, bounds.width > 16, bounds.height > 16 else { return }
        // Glass remains owned by SubtitlePanel's NSVisualEffectView. Only this faint curve
        // is composited underneath the existing clear scroll view, without a background fill.
        NSColor.controlAccentColor.withAlphaComponent(0.22).setStroke()
        let area = bounds.insetBy(dx: 8, dy: 8)
        let height = min(44, area.height * 0.38) * amplitude
        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineCapStyle = .round
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Keep the geometry stationary and communicate the same real level by opacity.
            NSColor.controlAccentColor.withAlphaComponent(0.08 + 0.22 * amplitude).setStroke()
            path.move(to: NSPoint(x: area.minX, y: area.midY))
            path.line(to: NSPoint(x: area.maxX, y: area.midY))
            path.stroke()
            return
        }
        // One complete smooth up/down cycle, expressed as cubic Hermite segments. Its
        // amplitude comes only from measured input; the curve never moves on its own.
        let segmentCount = 8
        let dx = area.width / CGFloat(segmentCount)
        let angularScale = 2 * CGFloat.pi / area.width
        path.move(to: NSPoint(x: area.minX, y: area.midY))
        for index in 0..<segmentCount {
            let x0 = CGFloat(index) * dx, x1 = x0 + dx
            let angle0 = x0 * angularScale, angle1 = x1 * angularScale
            let y0 = area.midY + height * sin(angle0), y1 = area.midY + height * sin(angle1)
            let slope0 = height * angularScale * cos(angle0), slope1 = height * angularScale * cos(angle1)
            path.curve(to: NSPoint(x: area.minX + x1, y: y1),
                       controlPoint1: NSPoint(x: area.minX + x0 + dx / 3, y: y0 + slope0 * dx / 3),
                       controlPoint2: NSPoint(x: area.minX + x1 - dx / 3, y: y1 - slope1 * dx / 3))
        }
        path.stroke()
    }
}
