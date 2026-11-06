import AppKit
import TalkTalkCore

/// The dock's curve band (redesign §4): one smooth up/down cycle whose amplitude (at most 10 pt)
/// comes only from measured microphone RMS, coloured by the speaking mode at 55%. It shows
/// local capture only, never delivery. Timer-free apart from the 250 ms stale check: it never
/// moves by itself, and Reduce Motion draws a stationary line whose opacity carries the level.
@MainActor
final class MicWaveView: NSView {
    private(set) var signal = MicWaveSignal()
    private(set) var style: MicDockPresentation.Wave = .none
    private var color: NSColor = .white
    private var expiry: Timer?
    private var accessibilityObserver: NSObjectProtocol?
    /// Settings preview: a static example drawn without a visible-window check.
    var isPreview = false

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsDisplay = true }
            }
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        expiry?.invalidate()
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    private var isOnScreen: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && !isHiddenOrHasHiddenAncestor
    }

    func setStyle(_ next: MicDockPresentation.Wave, color nextColor: NSColor) {
        guard style != next || color != nextColor else { return }
        style = next
        color = nextColor
        needsDisplay = true
    }

    /// One meter tick. Only this view redraws; no text or layout is touched.
    func setLevel(_ level: Float?, now: Double = ProcessInfo.processInfo.systemUptime) {
        // Real input never survives a hidden window and must arrive fresh after restoration.
        guard isPreview || isOnScreen else { stop(); return }
        if signal.feed(level, now: now) { needsDisplay = true }
        // A preview example is static; only live input goes stale.
        if !isPreview { scheduleExpiry(now: now) }
    }

    /// Capture closed or the band left the screen: the curve goes at once.
    func stop() {
        expiry?.invalidate(); expiry = nil
        if signal.stop() { needsDisplay = true }
    }

    private func scheduleExpiry(now: Double) {
        expiry?.invalidate(); expiry = nil
        guard let at = signal.expiresAt else { return }
        // Only fires when meter ticks stop arriving; the next tick normally replaces it.
        let timer = Timer(timeInterval: max(0.01, at - now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.signal.expire(now: ProcessInfo.processInfo.systemUptime) { self.needsDisplay = true }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiry = timer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard style != .none, signal.state != .removed, isPreview || isOnScreen,
              bounds.width > 8, bounds.height > 4 else { return }
        let alpha = CGFloat(MicWaveSignal.colorAlpha)
        let midY = bounds.midY
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineWidth = style == .solid || style == .flat ? CGFloat(MicWaveSignal.lineWidth) : CGFloat(MicWaveSignal.dashedLineWidth)
        if style == .dashed {
            var pattern: [CGFloat] = [3, 2.5]
            path.setLineDash(&pattern, count: 2, phase: 0)
        }
        var level: CGFloat = 0
        if case let .level(value) = signal.state { level = CGFloat(value) }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Stationary geometry; the same real level shows as opacity.
            color.withAlphaComponent(CGFloat(MicWaveSignal.reducedMotionAlpha(level: Double(level), wave: style))).setStroke()
            path.move(to: NSPoint(x: bounds.minX, y: midY))
            path.line(to: NSPoint(x: bounds.maxX, y: midY))
            path.stroke()
            return
        }
        color.withAlphaComponent(style == .outlined ? alpha * 0.6 : alpha).setStroke()
        // "收平": a flat line while nothing is sent. Otherwise the measured amplitude, scaled
        // down only when the compact dock's band is lower than the 24 pt band.
        let peak = min(CGFloat(MicWaveSignal.maxAmplitude), bounds.height / 2 - 1)
        let height = style == .flat ? 0 : peak * level
        let segmentCount = 8
        let dx = bounds.width / CGFloat(segmentCount)
        let angularScale = 2 * CGFloat.pi / bounds.width
        path.move(to: NSPoint(x: bounds.minX, y: midY))
        for index in 0..<segmentCount {
            let x0 = CGFloat(index) * dx, x1 = x0 + dx
            let angle0 = x0 * angularScale, angle1 = x1 * angularScale
            let y0 = midY - height * sin(angle0), y1 = midY - height * sin(angle1)
            let slope0 = -height * angularScale * cos(angle0), slope1 = -height * angularScale * cos(angle1)
            path.curve(to: NSPoint(x: bounds.minX + x1, y: y1),
                       controlPoint1: NSPoint(x: bounds.minX + x0 + dx / 3, y: y0 + slope0 * dx / 3),
                       controlPoint2: NSPoint(x: bounds.minX + x1 - dx / 3, y: y1 - slope1 * dx / 3))
        }
        path.stroke()
    }
}
