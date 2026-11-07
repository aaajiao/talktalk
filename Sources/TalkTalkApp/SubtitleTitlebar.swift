// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import TalkTalkCore
import TalkTalkSettingsUI

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
        // "Open the Phone app", never the 已送入 Phone delivery glyph.
        phone.image = SubtitleStyle.symbol(SubtitleTokens.VoiceIcon.openPhone, size: 11, weight: .medium)
        phone.title = "Phone"
        phone.imagePosition = .imageLeading
        phone.setAccessibilityLabel(String(localized: "打开 Phone"))
        phone.toolTip = String(localized: "在 Phone 中拨号、接听或挂断电话。")
        phone.target = self
        phone.action = #selector(phonePressed)
        divider.wantsLayer = true
        divider.layer?.backgroundColor = SubtitleStyle.color(.divider).cgColor
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
        // Icon-only, the glyph alone does not say "Phone": the tooltip names it.
        phone.toolTip = nextCompaction.showsPhoneText
            ? String(localized: "在 Phone 中拨号、接听或挂断电话。")
            : String(localized: "打开 Phone：在 Phone 中拨号、接听或挂断电话。")
        more.isHidden = !next.showsMore
        more.apply(display: nextDisplay)
        end.isHidden = !next.showsEnd
        end.isEnabled = next.endEnabled
        end.apply(scene: next.scene, showsText: nextCompaction.showsEndText, inputSwitched: next.endInputSwitched,
                  display: nextDisplay)
        divider.layer?.backgroundColor = SubtitleStyle.color(.divider, display: nextDisplay).cgColor
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
    private var display = SubtitleStyle.Display.current
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: SubtitleTokens.Size.titlebarHeight))
        icon.imageScaling = .scaleNone
        icon.contentTintColor = SubtitleStyle.color(.controlTertiary, display: display)
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

    /// Video names only its source after the `play.rectangle` icon, which already says
    /// "视频字幕"; the full title stays in the tooltip, VoiceOver and the window title.
    private var showsSourceOnly: Bool { scene == .video && !(source ?? "").isEmpty }

    func apply(scene: SubtitleScene, source: String?) {
        self.scene = scene
        self.source = source
        icon.image = SubtitleStyle.symbol(scene.symbol, size: 13, weight: .regular)
        icon.contentTintColor = SubtitleStyle.color(.controlTertiary, display: display)
        if showsSourceOnly, let source {
            label.attributedStringValue = NSAttributedString(string: source, attributes: [
                .font: NSFont.systemFont(ofSize: ControlTypography.titleVideoSource, weight: .semibold),
                .foregroundColor: SubtitleStyle.color(.textPrimary, display: display),
            ])
            let full = String(localized: "视频字幕 · \(source)")
            label.toolTip = full
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(full)
            return
        }
        setAccessibilityElement(false)
        setAccessibilityLabel(nil)
        let text = NSMutableAttributedString(string: scene.title, attributes: [
            .font: NSFont.systemFont(ofSize: ControlTypography.titleScene, weight: .semibold),
            .foregroundColor: SubtitleStyle.color(.textPrimary, display: display),
        ])
        if let source, !source.isEmpty {
            text.append(NSAttributedString(string: " · " + source, attributes: [
                .font: NSFont.systemFont(ofSize: ControlTypography.titleScene, weight: .regular),
                .foregroundColor: SubtitleStyle.color(.controlTertiary, display: display),
            ]))
        }
        label.attributedStringValue = text
        label.toolTip = text.string
    }

    /// Increase Contrast changed: redraw the same title with the new token values.
    func apply(display next: SubtitleStyle.Display) {
        guard next != display else { return }
        display = next
        apply(scene: scene, source: source)
    }

    /// Icon plus the scene title without its source: the part that never yields. Video's
    /// source name truncates down to the icon.
    var minimumWidth: CGFloat {
        if showsSourceOnly { return Self.iconWidth + 4 }
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
        case .info: (SubtitleStyle.color(.divider, display: display), SubtitleStyle.color(.controlTertiary, display: display))
        }
    }

    func apply(_ chip: HUDChip, showsText nextShowsText: Bool, display: SubtitleStyle.Display = .current) {
        showsText = nextShowsText
        let colors = Self.color(chip.tone, display: display)
        // Beside its 11 pt medium label the icon is 10 pt medium; icon-only it takes the
        // shared icon-only size.
        icon.image = SubtitleStyle.symbol(chip.symbol, size: nextShowsText ? 10 : SubtitleTokens.Size.iconOnlySymbol,
                                          weight: .medium)
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
            icon.frame = NSRect(x: (bounds.width - 16) / 2, y: (height - 16) / 2, width: 16, height: 16)
        }
    }

    override func hoverChanged() {
        layer?.backgroundColor = isPressed ? SubtitleStyle.white(0.14).cgColor
            : isHovered ? SubtitleStyle.white(0.08).cgColor : nil
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
        icon.image = SubtitleStyle.symbol(SubtitleTokens.VoiceIcon.cloud, size: SubtitleTokens.Size.iconOnlySymbol,
                                          weight: .medium)
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
        layer?.backgroundColor = isPressed ? SubtitleStyle.white(0.14).cgColor
            : isHovered ? SubtitleStyle.white(0.08).cgColor : nil
        layer?.cornerRadius = SubtitleTokens.Radius.chip
    }
}

/// "结束同传" / "结束": 11 pt text, white 70%, #FF453A on hover; `stop.circle` when narrow.
/// The label and tooltip name the scene's session, and help says what does not end.
@MainActor
final class EndTextButton: TitlebarControl {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var showsText = true
    private var display = SubtitleStyle.Display.current

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        label.font = SubtitleStyle.controlFont(ControlTypography.endButton, weight: .medium)
        icon.imageScaling = .scaleNone
        icon.image = SubtitleStyle.symbol(SubtitleTokens.VoiceIcon.end, size: SubtitleTokens.Size.iconOnlySymbol,
                                          weight: .medium)
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

    func apply(scene: SubtitleScene, showsText nextShowsText: Bool, inputSwitched: Bool,
               display nextDisplay: SubtitleStyle.Display = .current) {
        showsText = nextShowsText
        display = nextDisplay
        label.stringValue = scene.endTitle
        label.isHidden = !nextShowsText
        icon.isHidden = nextShowsText
        setAccessibilityLabel(scene.endAccessibilityLabel)
        // 结束 ends at once: its help and tooltip carry the consequence (redesign §3).
        let help = scene.endHelp(systemInputSwitched: inputSwitched)
        setAccessibilityHelp(help)
        toolTip = help
        hoverChanged()
        needsLayout = true
    }

    override func hoverChanged() {
        let color = (isHovered || isPressed) && isEnabled
            ? SubtitleStyle.color(.riskStroke, display: display) : SubtitleStyle.color(.controlSecondary, display: display)
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

/// The video hover bar's window options menu (`ellipsis.circle`).
/// White 70%, 92% on hover.
@MainActor
final class MoreMenuButton: TitlebarControl {
    static let width: CGFloat = 22
    private let icon = NSImageView()
    private var display = SubtitleStyle.Display.current

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleNone
        icon.image = SubtitleStyle.symbol(SubtitleTokens.VoiceIcon.more, size: SubtitleTokens.Size.iconOnlySymbol,
                                          weight: .medium)
        icon.setAccessibilityElement(false)
        addSubview(icon)
        layer?.cornerRadius = SubtitleTokens.Radius.chip
        // VoiceOver announces that it opens a menu.
        setAccessibilityRole(.menuButton)
        setAccessibilityLabel(String(localized: "字幕窗口选项"))
        toolTip = String(localized: "字幕窗口选项：锁定字幕位置")
        hoverChanged()
    }

    required init?(coder: NSCoder) { nil }

    func apply(display next: SubtitleStyle.Display) {
        guard next != display else { return }
        display = next
        hoverChanged()
    }

    override func hoverChanged() {
        let active = (isHovered || isPressed) && isEnabled
        icon.contentTintColor = SubtitleStyle.color(active ? .textPrimary : .controlSecondary, display: display)
        layer?.backgroundColor = isPressed ? SubtitleStyle.white(0.14).cgColor : nil
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: (bounds.width - 18) / 2, y: (bounds.height - 16) / 2, width: 18, height: 16)
    }
}
