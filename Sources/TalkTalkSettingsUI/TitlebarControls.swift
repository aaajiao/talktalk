// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import TalkTalkCore

// The subtitle window's own control primitives (redesign §3), moved here unchanged so the
// settings pages draw the same capsule and keycap (settings visual system §3.0, §3.16). The
// titlebar's other controls (chip, cloud, end, ⋯) and the dock subclass `TitlebarControl` in
// the app.

/// Views whose hover look must be dropped when the window leaves the screen.
@MainActor
public protocol HoverClearing: AnyObject {
    func clearHover()
}

/// Base for titlebar controls: clicks act on the first mouse-down in the non-key panel, never
/// drag the window, show an arrow cursor and report hover.
@MainActor
open class TitlebarControl: NSView, HoverClearing {
    public var onClick: (() -> Void)?
    public var isEnabled = true {
        didSet {
            alphaValue = isEnabled ? 1 : 0.45
            setAccessibilityEnabled(isEnabled)
            if !isEnabled { isPressed = false }
        }
    }
    public private(set) var isHovered = false
    /// Between mouse-down and mouse-up inside an enabled, clickable control (NSButton's
    /// highlighted state); subclasses draw it as hover plus a little more.
    public private(set) var isPressed = false { didSet { if isPressed != oldValue { hoverChanged() } } }
    private var tracking: NSTrackingArea?
    open override var isFlipped: Bool { true }
    open override var mouseDownCanMoveWindow: Bool { false }
    open override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    public required init?(coder: NSCoder) { nil }

    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    open override func mouseEntered(with event: NSEvent) { isHovered = true; hoverChanged() }
    open override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        hoverChanged()
    }
    public func clearHover() {
        guard isHovered || isPressed else { return }
        isHovered = false
        isPressed = false
        hoverChanged()
    }
    open override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    open override func mouseDown(with event: NSEvent) {
        if isEnabled, onClick != nil { isPressed = true }
    }
    open override func mouseUp(with event: NSEvent) {
        isPressed = false
        guard isEnabled, onClick != nil, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
    open override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let onClick else { return false }
        onClick()
        return true
    }

    open func hoverChanged() {}
}

/// Voice capsule (§3): 20 pt high (24 pt in the details popover), radius 10, padding 8/3,
/// 11 pt semibold, 10 pt leading icon, 8 pt chevron at 60%. Min 64, max 180 wide.
@MainActor
public final class VoiceCapsuleView: TitlebarControl {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private let dash = CAShapeLayer()
    private let large: Bool
    private var state: VoiceState?
    private var display = SubtitleStyle.Display.current
    public var showsChevron = true
    /// Settings in light mode: token colours use their light-surface values (§2).
    public var lightSurface = false

    public init(large: Bool) {
        self.large = large
        super.init(frame: .zero)
        icon.imageScaling = .scaleNone
        chevron.imageScaling = .scaleNone
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.alignment = .left
        for view in [icon, label, chevron] as [NSView] { view.setAccessibilityElement(false); addSubview(view) }
        dash.fillColor = nil
        dash.lineWidth = 1
        dash.lineDashPattern = [3, 2]
        layer?.addSublayer(dash)
        layer?.cornerRadius = SubtitleTokens.Radius.capsule
    }

    public required init?(coder: NSCoder) { nil }

    private static func fontSize(large: Bool) -> CGFloat { large ? 13 : ControlTypography.capsule }
    private static func iconSize(large: Bool) -> CGFloat { large ? 12 : SubtitleTokens.Size.capsuleIconSize }
    /// Video's listening state: the bare 12 pt `ear`, no fill, text or hover (a status glyph).
    private static let statusGlyphSize: CGFloat = 12
    private static let statusGlyphWidth: CGFloat = 20
    private var isStatusGlyph: Bool { !large && state?.isStatusGlyph == true }

    public static func width(for state: VoiceState, full: Bool, large: Bool, chevron: Bool = true) -> CGFloat {
        if !large, state.isStatusGlyph { return statusGlyphWidth }
        let title = full ? state.title : state.compactTitle
        let text = (title as NSString).size(withAttributes: [.font: SubtitleStyle.controlFont(fontSize(large: large))]).width
        let pad = SubtitleTokens.Size.capsuleHorizontalPadding
        let chevronWidth = chevron && state.opensDetails ? SubtitleTokens.Size.capsuleChevronSize + 4 : 0
        let raw = pad + iconSize(large: large) + 4 + ceil(text) + chevronWidth + pad
        let minimum = full ? SubtitleTokens.Size.capsuleMinWidth : 0
        return min(SubtitleTokens.Size.capsuleMaxWidth, max(minimum, raw))
    }

    public func apply(_ next: VoiceState, full: Bool, display nextDisplay: SubtitleStyle.Display = .current) {
        state = next
        display = nextDisplay
        let colors = Self.colors(next.appearance, display: nextDisplay, lightSurface: lightSurface)
        if isStatusGlyph {
            let tint = SubtitleStyle.white(0.8)
            icon.image = SubtitleStyle.symbol(next.symbol, size: Self.statusGlyphSize, weight: .semibold, hierarchical: tint)
            icon.contentTintColor = nil
        } else {
            icon.image = SubtitleStyle.symbol(next.symbol, size: Self.iconSize(large: large), weight: .semibold,
                                              accessibilityDescription: nil)
            icon.contentTintColor = colors.text
        }
        label.isHidden = isStatusGlyph
        label.font = SubtitleStyle.controlFont(Self.fontSize(large: large))
        label.stringValue = full ? next.title : next.compactTitle
        label.textColor = colors.text
        chevron.image = SubtitleStyle.symbol(SubtitleTokens.VoiceIcon.chevron, size: SubtitleTokens.Size.capsuleChevronSize,
                                             weight: .semibold)
        // The tertiary token's alpha (60%, Increase Contrast 90%) over the capsule's text colour.
        let chevronAlpha = SubtitleTokens.Color.controlTertiary.rgba(increaseContrast: nextDisplay.increaseContrast).alpha
        chevron.contentTintColor = colors.text.withAlphaComponent(chevronAlpha)
        chevron.isHidden = !showsChevron || !next.opensDetails || isStatusGlyph
        setAccessibilityLabel(next.accessibilityLabel)
        setAccessibilityHelp(next.detail)
        setAccessibilityRole(next.opensDetails && showsChevron ? .button : .staticText)
        toolTip = next.detail
        updateLayer(colors)
        needsLayout = true
    }

    public struct Colors { public var fill: NSColor?; public var stroke: NSColor?; public var dashed: Bool; public var text: NSColor }

    public static func colors(_ appearance: VoiceState.Appearance, display: SubtitleStyle.Display,
                       lightSurface: Bool = false) -> Colors {
        func token(_ role: SubtitleTokens.Color) -> NSColor {
            SubtitleStyle.color(role, display: display, lightSurface: lightSurface)
        }
        let dark = NSColor(white: 0, alpha: 0.85)
        return switch appearance {
        case .originalFill: Colors(fill: token(.voiceOriginal), stroke: nil, dashed: false, text: dark)
        case .translateFill: Colors(fill: token(.voiceTranslate), stroke: nil, dashed: false, text: .white)
        case .translateStroke: Colors(fill: nil, stroke: token(.voiceTranslate), dashed: false, text: token(.voiceTranslate))
        case .dimStroke: Colors(fill: nil, stroke: token(.controlStroke), dashed: false, text: SubtitleStyle.white(0.8))
        case .dashed: Colors(fill: nil, stroke: token(.controlDashed), dashed: true, text: SubtitleStyle.white(0.8))
        case .warnStroke: Colors(fill: nil, stroke: token(.warn), dashed: false, text: token(.warn))
        case .riskFill: Colors(fill: token(.riskFill), stroke: nil, dashed: false, text: .white)
        case .warnFill: Colors(fill: token(.warn), stroke: nil, dashed: false, text: dark)
        case .neutral: Colors(fill: token(.controlFill), stroke: nil, dashed: false, text: SubtitleStyle.white(0.8))
        }
    }

    private func updateLayer(_ colors: Colors? = nil) {
        guard let state else { return }
        if isStatusGlyph {
            layer?.backgroundColor = nil
            layer?.borderWidth = 0
            dash.isHidden = true
            return
        }
        let colors = colors ?? Self.colors(state.appearance, display: display, lightSurface: lightSurface)
        var fill = colors.fill ?? .clear
        if isHovered || isPressed, state.opensDetails, showsChevron {
            // Hover lightens 8%; pressed a little more, as NSButton's highlight.
            let fraction: CGFloat = isPressed ? 0.16 : 0.08
            fill = colors.fill.map { $0.blended(withFraction: fraction, of: .white) ?? $0 }
                ?? SubtitleStyle.white(isPressed ? 0.14 : 0.08)
        }
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth = colors.stroke != nil && !colors.dashed ? 1 : 0
        layer?.borderColor = colors.stroke?.cgColor
        dash.isHidden = !colors.dashed
        dash.strokeColor = colors.stroke?.cgColor
    }

    public override func hoverChanged() { updateLayer() }

    public override func layout() {
        super.layout()
        let height = bounds.height
        layer?.cornerRadius = min(SubtitleTokens.Radius.capsule * (large ? 1.2 : 1), height / 2)
        dash.frame = bounds
        dash.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                           cornerWidth: layer?.cornerRadius ?? 10, cornerHeight: layer?.cornerRadius ?? 10, transform: nil)
        if isStatusGlyph {
            let box = Self.statusGlyphSize + 4
            icon.frame = NSRect(x: (bounds.width - box) / 2, y: (height - box) / 2, width: box, height: box)
            return
        }
        let pad = SubtitleTokens.Size.capsuleHorizontalPadding
        let iconSize = Self.iconSize(large: large)
        icon.frame = NSRect(x: pad, y: (height - iconSize - 2) / 2, width: iconSize + 2, height: iconSize + 2)
        let chevronWidth: CGFloat = chevron.isHidden ? 0 : SubtitleTokens.Size.capsuleChevronSize + 4
        let labelX = pad + iconSize + 4
        let labelHeight = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: labelX, y: (height - labelHeight) / 2,
                             width: max(0, bounds.width - labelX - pad - chevronWidth) + SubtitleStyle.labelSlack,
                             height: labelHeight)
        chevron.frame = NSRect(x: bounds.width - pad - SubtitleTokens.Size.capsuleChevronSize - 1, y: (height - 10) / 2,
                               width: SubtitleTokens.Size.capsuleChevronSize + 2, height: 10)
    }
}

/// 右⌥ keycap and its action (§3): keycap 20 pt high, min 30 wide, radius 5, 11 pt SF Mono,
/// 1 pt white 30% border; translating fills voice.translate; switching shows a pressed key.
/// Start and end show as a glyph after the key at every width (`TitlebarKey.symbol`);
/// "松开确认" and "本机试说" stay text and yield below 560 pt.
@MainActor
public final class KeycapActionView: TitlebarControl {
    private let keyBox = NSView()
    private let keyLabel = NSTextField(labelWithString: "")
    private let action = NSTextField(labelWithString: "")
    private let actionIcon = NSImageView()
    private var key: TitlebarKey?
    private var showsAction = true
    private var showsSymbol = true
    /// Settings in light mode: system label colours instead of the panel's whites.
    public var lightSurface = false

    /// Gap between the keycap and its action, and the action glyph's box.
    private static let actionGap: CGFloat = 5
    private static let symbolBox: CGFloat = 14

    public override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        keyBox.wantsLayer = true
        keyBox.layer?.cornerRadius = SubtitleTokens.Radius.keycap
        keyLabel.font = SubtitleStyle.keycapFont
        keyLabel.alignment = .center
        action.font = SubtitleStyle.controlFont(ControlTypography.keyAction, weight: .medium)
        action.textColor = SubtitleStyle.color(.controlSecondary)
        action.lineBreakMode = .byTruncatingTail
        actionIcon.imageScaling = .scaleNone
        keyBox.addSubview(keyLabel)
        for view in [keyBox, keyLabel, action, actionIcon] as [NSView] { view.setAccessibilityElement(false) }
        addSubview(keyBox)
        addSubview(action)
        addSubview(actionIcon)
    }

    public required init?(coder: NSCoder) { nil }

    public static func keyWidth(_ key: TitlebarKey) -> CGFloat {
        let text = (key.key as NSString).size(withAttributes: [.font: SubtitleStyle.keycapFont]).width
        return max(SubtitleTokens.Size.keycapMinWidth, ceil(text) + 12)
    }

    /// `showsSymbol` false (the status band) draws the key alone.
    public static func width(for key: TitlebarKey, showsAction: Bool, showsSymbol: Bool = true) -> CGFloat {
        if showsSymbol, key.symbol != nil { return keyWidth(key) + actionGap + symbolBox }
        guard showsAction, key.drawsAction, let action = key.action else { return keyWidth(key) }
        let text = (action as NSString).size(withAttributes: [
            .font: SubtitleStyle.controlFont(ControlTypography.keyAction, weight: .medium)]).width
        return keyWidth(key) + actionGap + ceil(text)
    }

    public func apply(_ next: TitlebarKey, showsAction nextShowsAction: Bool, showsSymbol nextShowsSymbol: Bool = true,
               display: SubtitleStyle.Display = .current) {
        key = next
        showsAction = nextShowsAction
        showsSymbol = nextShowsSymbol
        let symbol = nextShowsSymbol ? next.symbol : nil
        keyLabel.stringValue = next.key
        action.stringValue = next.action ?? ""
        // The capsule already says the same words (松开确认): only the keycap is drawn.
        action.isHidden = symbol != nil || !nextShowsAction || next.action == nil || !next.drawsAction
        let secondary = lightSurface ? NSColor.secondaryLabelColor : SubtitleStyle.color(.controlSecondary, display: display)
        action.textColor = secondary
        actionIcon.isHidden = symbol == nil
        if let symbol {
            actionIcon.image = SubtitleStyle.symbol(symbol, size: 11, weight: .medium)
            actionIcon.contentTintColor = next.style == .translating
                ? SubtitleStyle.color(.voiceTranslate, display: display, lightSurface: lightSurface) : secondary
        }
        switch next.style {
        case .idle where lightSurface:
            keyBox.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
            keyBox.layer?.borderWidth = 1
            keyBox.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.25).cgColor
            keyLabel.textColor = .labelColor
        case .translating:
            keyBox.layer?.backgroundColor = SubtitleStyle.color(.voiceTranslate, display: display,
                                                                lightSurface: lightSurface).cgColor
            keyBox.layer?.borderWidth = 0
            keyLabel.textColor = .white
        case .pressed:
            keyBox.layer?.backgroundColor = SubtitleStyle.white(0.22).cgColor
            keyBox.layer?.borderWidth = 1
            keyBox.layer?.borderColor = SubtitleStyle.color(.voiceTranslate, display: display).cgColor
            keyLabel.textColor = .white
        case .idle:
            keyBox.layer?.backgroundColor = SubtitleStyle.white(0.06).cgColor
            keyBox.layer?.borderWidth = 1
            keyBox.layer?.borderColor = SubtitleStyle.color(.keycapStroke, display: display).cgColor
            keyLabel.textColor = SubtitleStyle.white(0.85)
        }
        // The glyph replaces only the drawn text: VoiceOver and the tooltip keep the words.
        let spoken = next.spokenLabel
        setAccessibilityLabel(spoken)
        setAccessibilityHelp(String(localized: "点按右侧 Option 键开始或结束翻译；点此查看按键说明。"))
        toolTip = spoken
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        guard let key else { return }
        let width = Self.keyWidth(key)
        let pressed = key.style == .pressed ? 1.0 : 0
        keyBox.frame = NSRect(x: 0, y: pressed, width: width, height: bounds.height - pressed)
        let labelHeight = ceil(keyLabel.intrinsicContentSize.height)
        keyLabel.frame = NSRect(x: 0, y: (keyBox.bounds.height - labelHeight) / 2, width: width, height: labelHeight)
        let actionHeight = ceil(action.intrinsicContentSize.height)
        action.frame = NSRect(x: width + Self.actionGap, y: (bounds.height - actionHeight) / 2,
                              width: max(0, bounds.width - width - Self.actionGap) + SubtitleStyle.labelSlack,
                              height: actionHeight)
        actionIcon.frame = NSRect(x: width + Self.actionGap, y: (bounds.height - Self.symbolBox) / 2,
                                  width: Self.symbolBox, height: Self.symbolBox)
    }
}
