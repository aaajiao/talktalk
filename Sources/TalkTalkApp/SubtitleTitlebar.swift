// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import TalkTalkCore

/// Shared titlebar (redesign §3). Right side, fixed order, hidden items take no space:
/// [voice capsule ⌄] [issue / notice chip] [右⌥ keycap + action] [Phone ↗] [⋯] │ [end].
/// Everything is driven by `SubtitleTitlebarContent`, so the settings preview can render the
/// same component from static data.
@MainActor
final class SubtitleTitlebarView: NSView {
    var onVoice: ((NSView) -> Void)?
    var onIssue: ((NSView) -> Void)?
    var onKey: ((NSView) -> Void)?
    var onPhone: (() -> Void)?
    var onEnd: ((NSView) -> Void)?
    /// The video hover bar's "⋯" menu (§6).
    var onMore: ((NSView) -> Void)?
    /// The video window's status dot (drawn by the panel below the titlebar) is clicked here.
    var onStatusDot: ((NSView) -> Void)?

    let capsule = VoiceCapsuleView(large: false)
    let chip = IssueChipView()
    let cloud = CloudPrivacyView()
    let keycap = KeycapActionView()
    let phone = NSButton()
    let more = MoreMenuButton()
    /// Invisible click target over the status dot, inside `trailingInset`; the titlebar sits
    /// above the content, so the dot itself could not receive clicks while the bar is shown.
    let statusDotTarget = TitlebarControl()
    var showsStatusDotTarget = false { didSet { statusDotTarget.isHidden = !showsStatusDotTarget } }
    private let divider = NSView()
    let end = EndTextButton()
    private(set) var content = SubtitleTitlebarContent(scene: .meeting)
    private(set) var compaction = TitlebarCompaction(level: 0)
    private var fadingChip = false
    private var display = SubtitleStyle.Display.current
    /// Empty room after the end button; the video window keeps its status dot there.
    var trailingInset: CGFloat = 0 { didSet { if trailingInset != oldValue { relayout() } } }

    /// Traffic lights plus margins before the leading accessory, and after the trailing one.
    static let windowChrome: CGFloat = 78 + 12 + 16
    /// Where the leading scene title starts: after the traffic lights.
    static let leadingTitleX: CGFloat = 78

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    var hasItems: Bool { content.hasTrailingItems || fadingChip }

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: SubtitleTokens.Size.titlebarHeight))
        capsule.onClick = { [weak self] in
            guard let self, content.voice?.opensDetails == true else { return }
            onVoice?(capsule)
        }
        chip.onClick = { [weak self] in guard let self else { return }; onIssue?(chip) }
        cloud.onClick = { [weak self] in guard let self else { return }; onIssue?(cloud) }
        keycap.onClick = { [weak self] in guard let self else { return }; onKey?(keycap) }
        end.onClick = { [weak self] in guard let self else { return }; onEnd?(end) }
        more.onClick = { [weak self] in guard let self else { return }; onMore?(more) }
        statusDotTarget.onClick = { [weak self] in guard let self else { return }; onStatusDot?(statusDotTarget) }
        statusDotTarget.isHidden = true
        addSubview(statusDotTarget)
        phone.bezelStyle = .accessoryBarAction
        phone.controlSize = .small
        phone.font = SubtitleStyle.controlFont(ControlTypography.capsule, weight: .medium)
        phone.image = SubtitleStyle.symbol(SubtitleTokens.VoiceIcon.sentToPhone, size: 11, weight: .medium)
        phone.title = "Phone"
        phone.imagePosition = .imageLeading
        phone.setAccessibilityLabel(String(localized: "打开 Phone"))
        phone.toolTip = String(localized: "在 Phone 中拨号、接听或挂断电话。")
        phone.target = self
        phone.action = #selector(phonePressed)
        divider.wantsLayer = true
        divider.layer?.backgroundColor = SubtitleStyle.white(0.2).cgColor
        divider.setAccessibilityElement(false)
        for view in [capsule, chip, cloud, keycap, phone, more, divider, end] as [NSView] {
            view.isHidden = true
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { nil }

    @objc private func phonePressed() { onPhone?() }

    /// Width the trailing group needs for `content` at `compaction`.
    func measure(_ content: SubtitleTitlebarContent, _ compaction: TitlebarCompaction) -> CGFloat {
        var widths: [CGFloat] = []
        if let voice = content.voice {
            widths.append(VoiceCapsuleView.width(for: voice, full: compaction.showsFullCapsule, large: false))
        }
        switch content.issue {
        case let .chip(value)?: widths.append(IssueChipView.width(for: value, showsText: compaction.showsChipText))
        case .cloudPrivacy?: widths.append(CloudPrivacyView.width)
        case nil: break
        }
        if let key = content.key {
            widths.append(KeycapActionView.width(for: key, showsAction: compaction.showsKeyAction))
        }
        if content.showsPhone { widths.append(compaction.showsPhoneText ? SubtitleTokens.Size.phoneButtonWidth : 28) }
        if content.showsMore { widths.append(MoreMenuButton.width) }
        let spacing = SubtitleTokens.Size.controlSpacing
        var total = widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * spacing
        if content.showsEnd {
            let endWidth = EndTextButton.width(title: content.scene.endTitle, showsText: compaction.showsEndText)
            total += (widths.isEmpty ? 0 : SubtitleTokens.Size.endDividerGap * 2 + 1) + endWidth
        }
        return ceil(total + (content.hasTrailingItems ? trailingInset : 0))
    }

    func apply(_ next: SubtitleTitlebarContent, compaction nextCompaction: TitlebarCompaction,
               display nextDisplay: SubtitleStyle.Display = .current) {
        let previousChip = content.issue?.chip
        content = next
        compaction = nextCompaction
        display = nextDisplay
        if let voice = next.voice { capsule.apply(voice, full: nextCompaction.showsFullCapsule, display: nextDisplay) }
        capsule.isHidden = next.voice == nil
        let nextChip = next.issue?.chip
        if let nextChip {
            chip.apply(nextChip, showsText: nextCompaction.showsChipText, display: nextDisplay)
            if chip.isHidden || previousChip == nil || fadingChip { fadeIn(chip) }
            fadingChip = false
            chip.isHidden = false
        } else if let previousChip, !chip.isHidden {
            // A notification fades after its 4 seconds; a cleared problem leaves at once.
            if previousChip.fades { fadeOut(chip) } else { chip.isHidden = true }
        }
        let showsCloud = next.issue == .cloudPrivacy && !fadingChip
        if showsCloud, cloud.isHidden { fadeIn(cloud) }
        cloud.isHidden = !showsCloud
        if let key = next.key { keycap.apply(key, showsAction: nextCompaction.showsKeyAction, display: nextDisplay) }
        keycap.isHidden = next.key == nil
        phone.isHidden = !next.showsPhone
        phone.isEnabled = next.phoneEnabled
        phone.imagePosition = nextCompaction.showsPhoneText ? .imageLeading : .imageOnly
        more.isHidden = !next.showsMore
        end.isHidden = !next.showsEnd
        end.isEnabled = next.endEnabled
        end.apply(title: next.scene.endTitle, showsText: nextCompaction.showsEndText)
        relayout()
    }

    private func fadeIn(_ view: NSView) {
        let duration = SubtitleStyle.duration(.chipFadeIn, display: display)
        guard duration > 0 else { view.alphaValue = 1; return }
        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            view.animator().alphaValue = 1
        }
    }

    private func fadeOut(_ view: NSView) {
        let duration = SubtitleStyle.duration(.noticeFadeOut, display: display)
        guard duration > 0 else { view.isHidden = true; return }
        fadingChip = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            view.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadingChip else { return }
                self.fadingChip = false
                view.isHidden = true
                view.alphaValue = 1
                self.apply(self.content, compaction: self.compaction, display: self.display)
                self.onLayoutChange?()
            }
        })
    }

    /// Called when a fade finished and the group's width changed by itself.
    var onLayoutChange: (() -> Void)?
    /// AppKit moved or resized the accessory (the video status dot follows its target).
    var onFrameChange: (() -> Void)?

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let changed = newOrigin != frame.origin
        super.setFrameOrigin(newOrigin)
        if changed { onFrameChange?() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { onFrameChange?() }
    }

    /// AppKit may give the accessory the native titlebar height; controls stay centred.
    private var rowHeight: CGFloat { bounds.height > 0 ? bounds.height : SubtitleTokens.Size.titlebarHeight }

    override func layout() {
        super.layout()
        relayout()
    }

    private func relayout() {
        var shown: [NSView] = []
        for view in [capsule, chip, cloud, keycap, phone, more] as [NSView] where !view.isHidden { shown.append(view) }
        let height = rowHeight
        let control = SubtitleTokens.Size.controlHeight
        let y = (height - control) / 2
        var x: CGFloat = 0
        for view in shown {
            let width: CGFloat = switch view {
            case capsule: content.voice.map { VoiceCapsuleView.width(for: $0, full: compaction.showsFullCapsule, large: false) } ?? 0
            case chip: content.issue?.chip.map { IssueChipView.width(for: $0, showsText: compaction.showsChipText) }
                ?? chip.frame.width
            case cloud: CloudPrivacyView.width
            case keycap: content.key.map { KeycapActionView.width(for: $0, showsAction: compaction.showsKeyAction) } ?? 0
            case more: MoreMenuButton.width
            default: compaction.showsPhoneText ? SubtitleTokens.Size.phoneButtonWidth : 28
            }
            view.frame = NSRect(x: x, y: y, width: width, height: control)
            x += width + SubtitleTokens.Size.controlSpacing
        }
        if !shown.isEmpty { x -= SubtitleTokens.Size.controlSpacing }
        divider.isHidden = end.isHidden || shown.isEmpty
        if !end.isHidden {
            if !shown.isEmpty {
                x += SubtitleTokens.Size.endDividerGap
                divider.frame = NSRect(x: x, y: (height - 14) / 2, width: 1, height: 14)
                x += 1 + SubtitleTokens.Size.endDividerGap
            }
            let width = EndTextButton.width(title: content.scene.endTitle, showsText: compaction.showsEndText)
            end.frame = NSRect(x: x, y: y, width: width, height: control)
            x += width
        }
        if x > 0 { x += trailingInset }
        let width = ceil(max(0, x))
        let box = VideoStatusDotView.boxSize
        let dotCenter = width - CGFloat(VideoStatusDot.edgeInset + VideoStatusDot.diameter / 2)
        statusDotTarget.frame = NSRect(x: dotCenter - box / 2, y: (height - box) / 2, width: box, height: box)
        if abs(frame.width - width) > 0.5 { setFrameSize(NSSize(width: width, height: rowHeight)) }
    }
}

/// Leading titlebar part: unified scene icon (not an accessibility element), the scene name
/// in 13 pt semibold and " · source" in 13 pt regular at 60% white. The source truncates first.
@MainActor
final class SubtitleTitleView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var scene: SubtitleScene = .meeting
    private var source: String?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: SubtitleTokens.Size.titlebarHeight))
        icon.imageScaling = .scaleNone
        icon.contentTintColor = SubtitleStyle.white(0.6)
        icon.setAccessibilityElement(false)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.setAccessibilityElement(false)
        addSubview(icon)
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    private static let iconWidth: CGFloat = 22

    func apply(scene: SubtitleScene, source: String?) {
        self.scene = scene
        self.source = source
        icon.image = SubtitleStyle.symbol(scene.symbol, size: 13, weight: .regular)
        let text = NSMutableAttributedString(string: scene.title, attributes: [
            .font: NSFont.systemFont(ofSize: ControlTypography.titleScene, weight: .semibold),
            .foregroundColor: SubtitleStyle.white(0.92),
        ])
        if let source, !source.isEmpty {
            text.append(NSAttributedString(string: " · " + source, attributes: [
                .font: NSFont.systemFont(ofSize: ControlTypography.titleScene, weight: .regular),
                .foregroundColor: SubtitleStyle.white(0.6),
            ]))
        }
        label.attributedStringValue = text
        label.toolTip = text.string
    }

    /// Icon plus the scene title without its source: the part that never yields.
    var minimumWidth: CGFloat {
        let title = (scene.title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: ControlTypography.titleScene, weight: .semibold)]).width
        return Self.iconWidth + ceil(title) + 4
    }

    var naturalWidth: CGFloat { Self.iconWidth + ceil(label.attributedStringValue.size().width) + 4 }

    override func layout() {
        super.layout()
        setWidth(frame.width)
    }

    func setWidth(_ width: CGFloat) {
        let height = bounds.height > 0 ? bounds.height : SubtitleTokens.Size.titlebarHeight
        let target = max(minimumWidth, width)
        if abs(frame.width - target) > 0.5 { setFrameSize(NSSize(width: target, height: height)) }
        let size = NSSize(width: target, height: height)
        icon.frame = NSRect(x: 0, y: (height - 16) / 2, width: 18, height: 16)
        label.frame = NSRect(x: Self.iconWidth, y: (height - 17) / 2, width: max(0, size.width - Self.iconWidth), height: 17)
    }
}

/// Base for titlebar controls: clicks act on the first mouse-down in the non-key panel, never
/// drag the window, show an arrow cursor and report hover.
@MainActor
class TitlebarControl: NSView, HoverClearing {
    var onClick: (() -> Void)?
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.45 } }
    private(set) var isHovered = false
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; hoverChanged() }
    override func mouseExited(with event: NSEvent) { isHovered = false; hoverChanged() }
    func clearHover() {
        guard isHovered else { return }
        isHovered = false
        hoverChanged()
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard isEnabled, onClick != nil, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let onClick else { return false }
        onClick()
        return true
    }

    func hoverChanged() {}
}

/// Voice capsule (§3): 20 pt high (24 pt in the details popover), radius 10, padding 8/3,
/// 11 pt semibold, 10 pt leading icon, 8 pt chevron at 60%. Min 64, max 180 wide.
@MainActor
final class VoiceCapsuleView: TitlebarControl {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private let dash = CAShapeLayer()
    private let large: Bool
    private var state: VoiceState?
    private var display = SubtitleStyle.Display.current
    var showsChevron = true
    /// Settings in light mode: token colours use their light-surface values (§2).
    var lightSurface = false

    init(large: Bool) {
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

    required init?(coder: NSCoder) { nil }

    private static func fontSize(large: Bool) -> CGFloat { large ? 13 : ControlTypography.capsule }
    private static func iconSize(large: Bool) -> CGFloat { large ? 12 : SubtitleTokens.Size.capsuleIconSize }

    static func width(for state: VoiceState, full: Bool, large: Bool, chevron: Bool = true) -> CGFloat {
        let title = full ? state.title : state.compactTitle
        let text = (title as NSString).size(withAttributes: [.font: SubtitleStyle.controlFont(fontSize(large: large))]).width
        let pad = SubtitleTokens.Size.capsuleHorizontalPadding
        let chevronWidth = chevron && state.opensDetails ? SubtitleTokens.Size.capsuleChevronSize + 4 : 0
        let raw = pad + iconSize(large: large) + 4 + ceil(text) + chevronWidth + pad
        let minimum = full ? SubtitleTokens.Size.capsuleMinWidth : 0
        return min(SubtitleTokens.Size.capsuleMaxWidth, max(minimum, raw))
    }

    func apply(_ next: VoiceState, full: Bool, display nextDisplay: SubtitleStyle.Display = .current) {
        state = next
        display = nextDisplay
        let colors = Self.colors(next.appearance, display: nextDisplay, lightSurface: lightSurface)
        icon.image = SubtitleStyle.symbol(next.symbol, size: Self.iconSize(large: large), weight: .semibold,
                                          accessibilityDescription: nil)
        icon.contentTintColor = colors.text
        label.font = SubtitleStyle.controlFont(Self.fontSize(large: large))
        label.stringValue = full ? next.title : next.compactTitle
        label.textColor = colors.text
        chevron.image = SubtitleStyle.symbol(SubtitleTokens.VoiceIcon.chevron, size: SubtitleTokens.Size.capsuleChevronSize,
                                             weight: .bold)
        chevron.contentTintColor = colors.text.withAlphaComponent(0.6)
        chevron.isHidden = !showsChevron || !next.opensDetails
        setAccessibilityLabel(next.accessibilityLabel)
        setAccessibilityHelp(next.detail)
        setAccessibilityRole(next.opensDetails && showsChevron ? .button : .staticText)
        toolTip = next.detail
        updateLayer(colors)
        needsLayout = true
    }

    struct Colors { var fill: NSColor?; var stroke: NSColor?; var dashed: Bool; var text: NSColor }

    static func colors(_ appearance: VoiceState.Appearance, display: SubtitleStyle.Display,
                       lightSurface: Bool = false) -> Colors {
        func token(_ role: SubtitleTokens.Color) -> NSColor {
            SubtitleStyle.color(role, display: display, lightSurface: lightSurface)
        }
        let dark = NSColor(white: 0, alpha: 0.85)
        return switch appearance {
        case .originalFill: Colors(fill: token(.voiceOriginal), stroke: nil, dashed: false, text: dark)
        case .translateFill: Colors(fill: token(.voiceTranslate), stroke: nil, dashed: false, text: .white)
        case .translateStroke: Colors(fill: nil, stroke: token(.voiceTranslate), dashed: false, text: token(.voiceTranslate))
        case .dimStroke: Colors(fill: nil, stroke: SubtitleStyle.white(0.35), dashed: false, text: SubtitleStyle.white(0.8))
        case .dashed: Colors(fill: nil, stroke: SubtitleStyle.white(0.5), dashed: true, text: SubtitleStyle.white(0.8))
        case .warnStroke: Colors(fill: nil, stroke: token(.warn), dashed: false, text: token(.warn))
        case .riskFill: Colors(fill: token(.riskFill), stroke: nil, dashed: false, text: .white)
        case .warnFill: Colors(fill: token(.warn), stroke: nil, dashed: false, text: dark)
        case .neutral: Colors(fill: SubtitleStyle.white(0.12), stroke: nil, dashed: false, text: SubtitleStyle.white(0.8))
        }
    }

    private func updateLayer(_ colors: Colors? = nil) {
        guard let state else { return }
        let colors = colors ?? Self.colors(state.appearance, display: display, lightSurface: lightSurface)
        var fill = colors.fill ?? .clear
        if isHovered, state.opensDetails, showsChevron {
            fill = colors.fill.map { $0.blended(withFraction: 0.08, of: .white) ?? $0 } ?? SubtitleStyle.white(0.08)
        }
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth = colors.stroke != nil && !colors.dashed ? 1 : 0
        layer?.borderColor = colors.stroke?.cgColor
        dash.isHidden = !colors.dashed
        dash.strokeColor = colors.stroke?.cgColor
    }

    override func hoverChanged() { updateLayer() }

    override func layout() {
        super.layout()
        let height = bounds.height
        layer?.cornerRadius = min(SubtitleTokens.Radius.capsule * (large ? 1.2 : 1), height / 2)
        dash.frame = bounds
        dash.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                           cornerWidth: layer?.cornerRadius ?? 10, cornerHeight: layer?.cornerRadius ?? 10, transform: nil)
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

/// Problem / notification chip (§3): 20 pt, radius 9, 11 pt medium, icon + ≤10 characters,
/// max 180 wide. Problems use warn/risk outlines; notifications white 28%; information gray.
@MainActor
final class IssueChipView: TitlebarControl {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var showsText = true

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleNone
        label.font = SubtitleStyle.controlFont(ControlTypography.chip, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        for view in [icon, label] as [NSView] { view.setAccessibilityElement(false); addSubview(view) }
        layer?.cornerRadius = SubtitleTokens.Radius.chip
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { nil }

    static func width(for chip: HUDChip, showsText: Bool) -> CGFloat {
        guard showsText else { return 28 }
        let text = (chip.label as NSString).size(withAttributes: [
            .font: SubtitleStyle.controlFont(ControlTypography.chip, weight: .medium)]).width
        return min(SubtitleTokens.Size.chipMaxWidth, 8 + 12 + 4 + ceil(text) + 8)
    }

    static func color(_ tone: HUDChip.Tone, display: SubtitleStyle.Display) -> (stroke: NSColor, text: NSColor) {
        switch tone {
        case .risk: (SubtitleStyle.color(.riskStroke, display: display), SubtitleStyle.color(.riskStroke, display: display))
        case .warn: (SubtitleStyle.color(.warn, display: display), SubtitleStyle.color(.warn, display: display))
        case .notice: (SubtitleStyle.color(.noticeStroke, display: display), SubtitleStyle.white(0.85))
        case .info: (SubtitleStyle.white(0.2), SubtitleStyle.white(0.6))
        }
    }

    func apply(_ chip: HUDChip, showsText nextShowsText: Bool, display: SubtitleStyle.Display = .current) {
        showsText = nextShowsText
        let colors = Self.color(chip.tone, display: display)
        icon.image = SubtitleStyle.symbol(chip.symbol, size: 10, weight: .semibold)
        icon.contentTintColor = colors.text
        label.stringValue = chip.label
        label.textColor = colors.text
        label.isHidden = !nextShowsText
        layer?.borderColor = colors.stroke.cgColor
        setAccessibilityLabel(chip.label)
        setAccessibilityHelp(chip.detail)
        toolTip = chip.detail
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        if showsText {
            icon.frame = NSRect(x: 8, y: (height - 12) / 2, width: 12, height: 12)
            let labelHeight = ceil(label.intrinsicContentSize.height)
            label.frame = NSRect(x: 24, y: (height - labelHeight) / 2, width: max(0, bounds.width - 32) + SubtitleStyle.labelSlack,
                                 height: labelHeight)
        } else {
            icon.frame = NSRect(x: (bounds.width - 12) / 2, y: (height - 12) / 2, width: 12, height: 12)
        }
    }

    override func hoverChanged() {
        layer?.backgroundColor = isHovered ? SubtitleStyle.white(0.08).cgColor : nil
    }
}

/// Cloud translation is on: 16 pt network icon plus a 6 pt blue dot, until the user picks
/// "本场不再提示" or "只用 Apple" in the popover.
@MainActor
final class CloudPrivacyView: TitlebarControl {
    static let width: CGFloat = 24
    private let icon = NSImageView()
    private let dot = CALayer()

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleNone
        icon.image = SubtitleStyle.symbol(SubtitleTokens.VoiceIcon.cloud, size: 13, weight: .regular)
        icon.contentTintColor = SubtitleStyle.white(0.75)
        icon.setAccessibilityElement(false)
        addSubview(icon)
        dot.backgroundColor = SubtitleStyle.color(.voiceTranslate).cgColor
        dot.cornerRadius = SubtitleTokens.Size.cloudDotSize / 2
        layer?.addSublayer(dot)
        setAccessibilityLabel(String(localized: "云端翻译已开启"))
        setAccessibilityHelp(String(localized: "会议文字会发送给 OpenAI。"))
        toolTip = String(localized: "云端翻译已开启：会议文字会发送给 OpenAI。")
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let size = SubtitleTokens.Size.cloudIconSize
        icon.frame = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        let dotSize = SubtitleTokens.Size.cloudDotSize
        dot.frame = CGRect(x: icon.frame.maxX - dotSize + 1, y: icon.frame.minY - 1, width: dotSize, height: dotSize)
    }

    override func hoverChanged() {
        layer?.backgroundColor = isHovered ? SubtitleStyle.white(0.08).cgColor : nil
        layer?.cornerRadius = SubtitleTokens.Radius.chip
    }
}

/// 右⌥ keycap and its action text (§3): keycap 20 pt high, min 30 wide, radius 5, 11 pt SF Mono,
/// 1 pt white 30% border; translating fills voice.translate; switching shows a pressed key.
@MainActor
final class KeycapActionView: TitlebarControl {
    private let keyBox = NSView()
    private let keyLabel = NSTextField(labelWithString: "")
    private let action = NSTextField(labelWithString: "")
    private var key: TitlebarKey?
    private var showsAction = true
    /// Settings in light mode: system label colours instead of the panel's whites.
    var lightSurface = false

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        keyBox.wantsLayer = true
        keyBox.layer?.cornerRadius = SubtitleTokens.Radius.keycap
        keyLabel.font = SubtitleStyle.keycapFont
        keyLabel.alignment = .center
        action.font = SubtitleStyle.controlFont(ControlTypography.keyAction, weight: .medium)
        action.textColor = SubtitleStyle.white(0.7)
        action.lineBreakMode = .byTruncatingTail
        keyBox.addSubview(keyLabel)
        for view in [keyBox, keyLabel, action] as [NSView] { view.setAccessibilityElement(false) }
        addSubview(keyBox)
        addSubview(action)
    }

    required init?(coder: NSCoder) { nil }

    static func keyWidth(_ key: TitlebarKey) -> CGFloat {
        let text = (key.key as NSString).size(withAttributes: [.font: SubtitleStyle.keycapFont]).width
        return max(SubtitleTokens.Size.keycapMinWidth, ceil(text) + 12)
    }

    static func width(for key: TitlebarKey, showsAction: Bool) -> CGFloat {
        guard showsAction, let action = key.action else { return keyWidth(key) }
        let text = (action as NSString).size(withAttributes: [
            .font: SubtitleStyle.controlFont(ControlTypography.keyAction, weight: .medium)]).width
        return keyWidth(key) + 5 + ceil(text)
    }

    func apply(_ next: TitlebarKey, showsAction nextShowsAction: Bool, display: SubtitleStyle.Display = .current) {
        key = next
        showsAction = nextShowsAction
        keyLabel.stringValue = next.key
        action.stringValue = next.action ?? ""
        action.isHidden = !nextShowsAction || next.action == nil
        action.textColor = lightSurface ? .secondaryLabelColor : SubtitleStyle.white(0.7)
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
            keyBox.layer?.borderColor = SubtitleStyle.white(0.3).cgColor
            keyLabel.textColor = SubtitleStyle.white(0.85)
        }
        let spoken = [next.key, next.action].compactMap { $0 }.joined(separator: " ")
        setAccessibilityLabel(spoken)
        setAccessibilityHelp(String(localized: "点按右侧 Option 键开始或结束翻译；点此查看按键说明。"))
        toolTip = spoken
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let key else { return }
        let width = Self.keyWidth(key)
        let pressed = key.style == .pressed ? 1.0 : 0
        keyBox.frame = NSRect(x: 0, y: pressed, width: width, height: bounds.height - pressed)
        let labelHeight = ceil(keyLabel.intrinsicContentSize.height)
        keyLabel.frame = NSRect(x: 0, y: (keyBox.bounds.height - labelHeight) / 2, width: width, height: labelHeight)
        let actionHeight = ceil(action.intrinsicContentSize.height)
        action.frame = NSRect(x: width + 5, y: (bounds.height - actionHeight) / 2,
                              width: max(0, bounds.width - width - 5) + SubtitleStyle.labelSlack, height: actionHeight)
    }
}

/// "结束同传" / "结束": 11 pt text, white 70%, #FF453A on hover; `stop.circle` when narrow.
@MainActor
final class EndTextButton: TitlebarControl {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var showsText = true

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        label.font = SubtitleStyle.controlFont(ControlTypography.endButton, weight: .medium)
        icon.imageScaling = .scaleNone
        icon.image = SubtitleStyle.symbol(SubtitleTokens.VoiceIcon.end, size: 13, weight: .regular)
        for view in [label, icon] as [NSView] { view.setAccessibilityElement(false); addSubview(view) }
        hoverChanged()
    }

    required init?(coder: NSCoder) { nil }

    static func width(title: String, showsText: Bool) -> CGFloat {
        guard showsText else { return 22 }
        let text = (title as NSString).size(withAttributes: [
            .font: SubtitleStyle.controlFont(ControlTypography.endButton, weight: .medium)]).width
        return ceil(text) + 4
    }

    func apply(title: String, showsText nextShowsText: Bool) {
        showsText = nextShowsText
        label.stringValue = title
        label.isHidden = !nextShowsText
        icon.isHidden = nextShowsText
        setAccessibilityLabel(title)
        toolTip = title
        needsLayout = true
    }

    override func hoverChanged() {
        let color = isHovered && isEnabled ? SubtitleStyle.color(.riskStroke) : SubtitleStyle.white(0.7)
        label.textColor = color
        icon.contentTintColor = color
    }

    override func layout() {
        super.layout()
        let labelHeight = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 2, y: (bounds.height - labelHeight) / 2, width: max(0, bounds.width - 4), height: labelHeight)
        icon.frame = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }
}

/// "⋯" in the video hover bar: opens the window's options menu. White 70%, 92% on hover.
@MainActor
final class MoreMenuButton: TitlebarControl {
    static let width: CGFloat = 22
    private let icon = NSImageView()

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleNone
        icon.image = SubtitleStyle.symbol("ellipsis", size: 13, weight: .semibold)
        icon.setAccessibilityElement(false)
        addSubview(icon)
        setAccessibilityLabel(String(localized: "更多"))
        toolTip = String(localized: "更多")
        hoverChanged()
    }

    required init?(coder: NSCoder) { nil }

    override func hoverChanged() {
        icon.contentTintColor = SubtitleStyle.white(isHovered && isEnabled ? 0.92 : 0.7)
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: (bounds.width - 18) / 2, y: (bounds.height - 16) / 2, width: 18, height: 16)
    }
}
