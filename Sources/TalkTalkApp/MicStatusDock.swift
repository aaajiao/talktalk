// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import TalkTalkCore
import TalkTalkSession
import TalkTalkSettingsUI

/// The microphone status dock under the meeting/phone timeline (redesign §4, §5): a 0.5 pt top
/// separator, then icon 16 + state 13 pt semibold + consequence 12 pt white 60%, the flexible
/// 24 pt curve band and, for risk / unavailable audio, "[wrench] 修复…" / [info.circle]. It does
/// not repeat the titlebar's keycap; the 28 pt compact dock keeps the fix/details action as a
/// 20 × 20 icon. While I speak it expands and shows my
/// live turn; the panel animates its height, never the window. Status and meter changes only
/// touch the status row and the curve; the turn text is rebuilt only when the turn changes.
@MainActor
final class MicStatusDock: NSView {
    struct Content: Equatable {
        var presentation: MicDockPresentation
        /// My live turn; drawn only while `expanded`.
        var turn: ConversationTimeline.Turn?
        var expanded: Bool
        var showsStartHint: Bool
    }

    static let horizontalPadding: CGFloat = 12
    static let compactWaveHeight: CGFloat = 16
    static let compactWaveMaxWidth: CGFloat = 96

    /// "修复…" and "详情" open the details popover anchored here.
    var onAction: ((NSView) -> Void)?
    private(set) var content: Content?
    private var style: ConversationStyle?
    private var compact = false
    private var statusVisible = true

    private let fill = NSView()
    private let bar = NSView()
    private let separator = NSView()
    private let status = DockStatusGroup()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let dot = NSTextField(labelWithString: "·")
    private let consequence = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let wave = MicWaveView()
    private let actionButton = DockActionButton()
    private let turnArea = DockTurnView()
    private let sourceLabel = ConversationLabel(wrappingLabelWithString: "")
    private let translationLabel = ConversationLabel(wrappingLabelWithString: "")
    private let draftBar = NSView()
    private var renderedTurn: ConversationTimeline.Turn?
    private var renderedTurnStyle: ConversationStyle?
    private var renderedPresentation: MicDockPresentation?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        for view in [fill, bar, separator, draftBar] {
            view.wantsLayer = true
            view.setAccessibilityElement(false)
        }
        icon.imageScaling = .scaleNone
        label.font = .systemFont(ofSize: ControlTypography.dockLabel, weight: .semibold)
        dot.font = .systemFont(ofSize: ControlTypography.dockConsequence)
        dot.textColor = SubtitleStyle.white(0.45)
        consequence.font = .systemFont(ofSize: ControlTypography.dockConsequence)
        consequence.textColor = SubtitleStyle.white(0.6)
        hint.font = .systemFont(ofSize: ControlTypography.dockConsequence)
        hint.textColor = SubtitleStyle.white(0.45)
        hint.stringValue = MicDockPresentation.startHint
        for field in [label, dot, consequence, hint] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.setAccessibilityElement(false)
        }
        icon.setAccessibilityElement(false)
        for view in [icon, label, dot, consequence, hint] as [NSView] { status.addSubview(view) }
        actionButton.onClick = { [weak self] in
            guard let self else { return }
            onAction?(actionButton)
        }
        for label in [sourceLabel, translationLabel] {
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.isSelectable = false
            label.cell?.isScrollable = false
            label.setAccessibilityElement(false)
            turnArea.addSubview(label)
        }
        turnArea.addSubview(draftBar)
        turnArea.wantsLayer = true
        turnArea.layer?.masksToBounds = true
        turnArea.isHidden = true
        for view in [fill, bar, separator, status, wave, actionButton, turnArea] as [NSView] { addSubview(view) }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    /// Hover controls are independent from my live subtitles. Keep the row's space so neither
    /// the turn nor the timeline moves. Hide immediately, including hit testing and VoiceOver;
    /// this also respects Reduce Motion and cannot leave invisible controls during a fade.
    func setStatusVisible(_ visible: Bool, animated _: Bool = false) {
        guard statusVisible != visible else { return }
        statusVisible = visible
        updateStatusVisibility()
        if let content, let style { applyBackground(content, display: style.display) }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func updateStatusVisibility() {
        let shown = statusVisible && content != nil
        status.isHidden = !shown
        status.setAccessibilityElement(shown)
        status.toolTip = shown ? content?.presentation.toolTip : nil
        separator.isHidden = !shown
        let showsAction = shown && content?.presentation.action != nil
        actionButton.isHidden = !showsAction
        actionButton.setAccessibilityElement(showsAction)
        actionButton.toolTip = showsAction ? content?.presentation.action?.title : nil
        if !showsAction { actionButton.clearHover() }
        if !shown {
            wave.isHidden = true
            wave.stop()
        }
    }

    func apply(_ next: Content?, style nextStyle: ConversationStyle, compact nextCompact: Bool) {
        let modeChanged = compact != nextCompact || style != nextStyle
        guard next != content || modeChanged else { return }
        content = next
        style = nextStyle
        compact = nextCompact
        // The panel owns visibility: no content means no session.
        guard let next else {
            wave.stop()
            updateStatusVisibility()
            return
        }
        if next.presentation != renderedPresentation || modeChanged { applyStatus(next.presentation, display: nextStyle.display) }
        let turn = next.expanded ? next.turn : nil
        if turn != renderedTurn || renderedTurnStyle != nextStyle { applyTurn(turn, style: nextStyle) }
        if let action = next.presentation.action {
            actionButton.setAction(action, tone: next.presentation.emphasis, iconOnly: !action.showsTitle(compact: nextCompact))
        }
        applyBackground(next, display: nextStyle.display)
        updateStatusVisibility()
        needsLayout = true
    }

    func refreshAppLanguage() {
        hint.stringValue = MicDockPresentation.startHint
        // The panel/HUD supplies a freshly localized presentation. Rebuild only its text;
        // the waveform, capture, current turn and expanded state remain in place.
        renderedPresentation = nil
        renderedTurnStyle = nil
        if let content, let style {
            let current = content
            self.content = nil
            apply(current, style: style, compact: compact)
        }
        needsLayout = true
    }

    /// One meter tick: only the curve redraws.
    func setLevel(_ level: Float?) {
        guard content != nil, statusVisible, !isHidden else { wave.stop(); return }
        wave.setLevel(level)
    }

    func stopLevel() { wave.stop() }

    /// Settings preview: a fixed example level that never expires.
    func setPreviewLevel(_ level: Float) {
        wave.isPreview = true
        guard statusVisible else { wave.stop(); return }
        wave.setLevel(level)
    }

    private func toneColor(_ tone: MicDockPresentation.Tone, display: SubtitleStyle.Display) -> NSColor {
        switch tone {
        case .original: SubtitleStyle.color(.voiceOriginal, display: display)
        case .translate: SubtitleStyle.color(.voiceTranslate, display: display)
        case .neutral: SubtitleStyle.white(display.increaseContrast ? 0.92 : 0.8)
        case .warn: SubtitleStyle.color(.warn, display: display)
        case .risk: SubtitleStyle.color(.riskStroke, display: display)
        }
    }

    private func applyStatus(_ presentation: MicDockPresentation, display: SubtitleStyle.Display) {
        renderedPresentation = presentation
        let color = toneColor(presentation.tone, display: display)
        icon.image = SubtitleStyle.symbol(presentation.symbol, size: compact ? 12 : 14, weight: .semibold)
        icon.contentTintColor = color
        label.stringValue = presentation.label
        label.textColor = color
        consequence.stringValue = presentation.consequence ?? ""
        status.setAccessibilityLabel(presentation.accessibilityLabel)
        // The compact or narrow dock drops the consequence; hovering still shows it.
        status.toolTip = statusVisible ? presentation.toolTip : nil
        wave.setStyle(presentation.wave, color: color)
        if presentation.wave == .none || !statusVisible { wave.stop() }
    }

    private func applyTurn(_ turn: ConversationTimeline.Turn?, style: ConversationStyle) {
        renderedTurn = turn
        renderedTurnStyle = style
        guard let turn else {
            sourceLabel.attributedStringValue = NSAttributedString()
            translationLabel.attributedStringValue = NSAttributedString()
            turnArea.setAccessibilityLabel(nil)
            return
        }
        let text = style.text
        let source = NSMutableAttributedString()
        text.appendSource(turn.source, live: !turn.isFinal, speaker: .me, to: source)
        text.appendUnsent(turn.unsentSource, to: source)
        let translation = NSMutableAttributedString()
        text.appendTranslation(turn.translation, role: style.typography.myTranslation, isFinal: turn.isFinal, to: translation)
        sourceLabel.attributedStringValue = source
        translationLabel.attributedStringValue = translation
        let spokenSource = ConversationText.accessibilityText(source)
        let spokenTranslation = ConversationText.accessibilityText(translation)
        turnArea.setAccessibilityLabel(spokenTranslation.isEmpty
            ? String(appLocalized: "我正在说：\(spokenSource)")
            : String(appLocalized: "我：\(spokenSource)；译文：\(spokenTranslation)"))
    }

    private func applyBackground(_ content: Content, display: SubtitleStyle.Display) {
        let translate = SubtitleStyle.color(.voiceTranslate, display: display)
        var fillColor: NSColor?
        var barColor: NSColor?
        switch content.presentation.emphasis {
        case .risk:
            fillColor = SubtitleStyle.color(.riskFill, display: display).withAlphaComponent(0.18)
            barColor = SubtitleStyle.color(.riskStroke, display: display)
        case .unavailable:
            fillColor = SubtitleStyle.color(.warn, display: display).withAlphaComponent(0.15)
        case .none:
            if content.expanded {
                // rgba(64,156,255,0.10) with a 3 pt voice.translate bar.
                fillColor = translate.withAlphaComponent(0.10)
                barColor = translate
            }
        }
        let hasVisibleBackground = statusVisible || (content.expanded && content.turn != nil)
        fill.layer?.backgroundColor = fillColor?.cgColor
        fill.isHidden = fillColor == nil || !hasVisibleBackground
        bar.layer?.backgroundColor = barColor?.cgColor
        bar.isHidden = barColor == nil || !hasVisibleBackground
        separator.layer?.backgroundColor = SubtitleStyle.color(.separator, display: display).cgColor
        draftBar.layer?.backgroundColor = translate.withAlphaComponent(ConversationTextRules.draftBarAlpha).cgColor
    }

    private static func width(_ field: NSTextField) -> CGFloat {
        field.stringValue.isEmpty ? 0 : ceil(field.intrinsicContentSize.width)
    }

    // swiftlint:disable:next function_body_length
    override func layout() {
        super.layout()
        guard let content, let style else { return }
        let width = bounds.width, height = bounds.height
        let padding = Self.horizontalPadding
        let display = style.display
        separator.frame = NSRect(x: 0, y: 0, width: width,
                                 height: CGFloat(SubtitleTokens.separatorWidth(increaseContrast: display.increaseContrast)))
        // The status row keeps its idle height (48, or 28 in a low window) while expanded, so it
        // does not jump; my turn takes the space below it.
        let idleRow = compact ? CGFloat(ConversationLayout.compactDockHeight) : CGFloat(SubtitleTokens.Size.statusBandIdleHeight)
        let bottomPadding = CGFloat(SubtitleTokens.Size.panelBottomPadding)
        let expanded = content.expanded && height > idleRow + bottomPadding
        let rowHeight = min(height, idleRow)
        // Hiding the controls also hides their tint, while the live-turn tint stays exactly
        // behind the unchanged text area. No dock, row or turn geometry depends on hovering.
        let backgroundTop: CGFloat = statusVisible ? 0 : rowHeight
        let backgroundHeight = max(0, height - backgroundTop)
        fill.frame = NSRect(x: 0, y: backgroundTop, width: width, height: backgroundHeight)
        bar.frame = NSRect(x: 0, y: backgroundTop, width: 3, height: backgroundHeight)

        // Trailing control: only the fix/details button for risk / unavailable audio (an icon in
        // the compact dock). The keycap lives in the titlebar alone; the curve takes its width.
        var trailing: NSView?
        var trailingWidth: CGFloat = 0
        if content.presentation.action != nil {
            trailing = actionButton
            trailingWidth = actionButton.preferredWidth
        }
        actionButton.isHidden = !statusVisible || trailing !== actionButton
        let controlHeight = CGFloat(SubtitleTokens.Size.controlHeight)
        if let trailing {
            trailing.frame = NSRect(x: width - padding - trailingWidth, y: ((rowHeight - controlHeight) / 2).rounded(),
                                    width: trailingWidth, height: controlHeight)
        }
        let limit = trailing == nil ? width - padding : width - padding - trailingWidth - padding

        // Status texts give way in order: the start hint, then the consequence, then the label.
        let iconSize: CGFloat = 16
        let textStart = padding + iconSize + 6
        let labelWidth = Self.width(label)
        let dotWidth = Self.width(dot)
        let consequenceWidth = Self.width(consequence)
        let hintWidth = Self.width(hint)
        var showsConsequence = !compact && consequenceWidth > 0
        var showsHint = !compact && content.showsStartHint
        let minimumWave: CGFloat = 36
        func needed() -> CGFloat {
            labelWidth + (showsConsequence ? 4 + dotWidth + 4 + consequenceWidth : 0) + (showsHint ? 12 + hintWidth : 0)
        }
        let room = max(0, limit - textStart - minimumWave)
        if needed() > room { showsHint = false }
        if needed() > room { showsConsequence = false }
        status.frame = NSRect(x: 0, y: 0, width: max(0, limit), height: rowHeight)
        icon.frame = NSRect(x: padding, y: ((rowHeight - iconSize) / 2).rounded(), width: iconSize, height: iconSize)
        func place(_ field: NSTextField, x: CGFloat, width: CGFloat) {
            let fieldHeight = ceil(field.intrinsicContentSize.height)
            field.frame = NSRect(x: x, y: ((rowHeight - fieldHeight) / 2).rounded(),
                                 width: width > 0 ? width + SubtitleStyle.labelSlack : 0, height: fieldHeight)
        }
        var x = textStart
        let shownLabel = min(labelWidth, max(0, limit - textStart))
        place(label, x: x, width: shownLabel)
        x += shownLabel
        dot.isHidden = !showsConsequence
        consequence.isHidden = !showsConsequence
        if showsConsequence {
            place(dot, x: x + 4, width: dotWidth)
            place(consequence, x: x + 4 + dotWidth + 4, width: consequenceWidth)
            x += 4 + dotWidth + 4 + consequenceWidth
        }
        hint.isHidden = !showsHint
        if showsHint {
            place(hint, x: x + 12, width: hintWidth)
            x += 12 + hintWidth
        }

        // The curve takes the flexible middle; it never overlaps text or the action button.
        let waveHeight = compact ? Self.compactWaveHeight : CGFloat(SubtitleTokens.Size.waveformBandHeight)
        var waveWidth = max(0, limit - x - padding)
        if compact { waveWidth = min(waveWidth, Self.compactWaveMaxWidth) }
        wave.isHidden = !statusVisible || waveWidth < 24 || content.presentation.wave == .none
        wave.frame = NSRect(x: x + padding, y: ((rowHeight - waveHeight) / 2).rounded(), width: waveWidth, height: waveHeight)

        // My live turn below the status row, in the timeline's columns, newest lines kept.
        turnArea.isHidden = !expanded || content.turn == nil
        turnArea.removeAllToolTips()
        turnArea.badgeToolTipOwners = []
        guard expanded, content.turn != nil else { return }
        let area = NSRect(x: padding, y: rowHeight, width: max(0, width - 2 * padding),
                          height: max(0, height - rowHeight - bottomPadding))
        turnArea.frame = area
        let columns = ConversationLayout.columns(rowWidth: Double(area.width), stacked: style.stacked)
        func measure(_ field: NSTextField, width: CGFloat) -> CGFloat {
            guard field.attributedStringValue.length > 0, width > 0 else { return 0 }
            let size = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
            return ceil(size?.height ?? 0)
        }
        let sourceWidth = CGFloat(columns.sourceWidth), translationWidth = CGFloat(columns.translationWidth)
        let sourceHeight = measure(sourceLabel, width: sourceWidth)
        let translationHeight = measure(translationLabel, width: translationWidth)
        func anchored(_ textHeight: CGFloat, top: CGFloat, bottom: CGFloat) -> CGFloat {
            // Top aligned while it fits; otherwise the end of the text stays in view.
            textHeight <= bottom - top ? top : bottom - textHeight
        }
        if style.stacked {
            let gap: CGFloat = sourceHeight > 0 && translationHeight > 0 ? CGFloat(ConversationLayout.stackedGap) : 0
            let total = translationHeight + gap + sourceHeight
            let top = anchored(total, top: 0, bottom: area.height)
            translationLabel.frame = NSRect(x: columns.translationX, y: top, width: translationWidth, height: translationHeight)
            sourceLabel.frame = NSRect(x: columns.sourceX, y: top + translationHeight + gap, width: sourceWidth, height: sourceHeight)
        } else {
            sourceLabel.frame = NSRect(x: columns.sourceX, y: anchored(sourceHeight, top: 0, bottom: area.height),
                                       width: sourceWidth, height: sourceHeight)
            translationLabel.frame = NSRect(x: columns.translationX, y: anchored(translationHeight, top: 0, bottom: area.height),
                                            width: translationWidth, height: translationHeight)
        }
        // Badge tooltips ("未发送" and the like), in the turn area's coordinates.
        turnArea.badgeToolTipOwners = ConversationText.addBadgeToolTips(for: sourceLabel, frame: sourceLabel.frame, to: turnArea)
            + ConversationText.addBadgeToolTips(for: translationLabel, frame: translationLabel.frame, to: turnArea)
        let draft = content.turn.map { !$0.isFinal && !$0.translation.isEmpty } ?? false
        draftBar.isHidden = !draft
        if draft {
            let frame = translationLabel.frame
            let visibleTop = max(0, frame.minY), visibleBottom = min(area.height, frame.maxY)
            draftBar.frame = NSRect(x: frame.minX - (style.stacked ? 3 : 8), y: visibleTop + 2,
                                    width: CGFloat(ConversationTextRules.draftBarWidth), height: max(0, visibleBottom - visibleTop - 4))
        }
    }
}

/// The status row as one VoiceOver element: "麦克风：原声，对方能听到你".
@MainActor
private final class DockStatusGroup: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { nil }
}

/// My live turn as one VoiceOver element; its text is clipped to the dock.
@MainActor
private final class DockTurnView: NSView {
    /// The badge tooltips' owners: `addToolTip` does not retain them.
    var badgeToolTipOwners: [NSString] = []
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { nil }
}

/// "修复…" / "详情": 20 pt, radius 10; it opens the details popover. "修复…" is a 10 pt semibold
/// wrench, 4 pt and the 11 pt semibold word in white on riskFill; icon-only (详情, or either in
/// the compact dock) is a 20 × 20 circle with an 11 pt semibold glyph. The title is always the
/// tooltip and the VoiceOver label.
@MainActor
final class DockActionButton: TitlebarControl {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var emphasis: MicDockPresentation.Emphasis = .none
    private var iconOnly = false
    private var action: MicDockPresentation.Action?
    private static let iconGap: CGFloat = 4

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        layer?.cornerRadius = CGFloat(SubtitleTokens.Size.controlHeight) / 2
        icon.imageScaling = .scaleNone
        icon.setAccessibilityElement(false)
        addSubview(icon)
        label.font = SubtitleStyle.controlFont(ControlTypography.capsule, weight: .semibold)
        label.alignment = .center
        label.textColor = .white
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityHelp(String(appLocalized: "打开详情查看原因和修复方法"))
        hoverChanged()
    }

    required init?(coder: NSCoder) { nil }

    func setAction(_ next: MicDockPresentation.Action, tone: MicDockPresentation.Emphasis, iconOnly nextIconOnly: Bool) {
        let title = next.title
        guard next != action || tone != emphasis || nextIconOnly != iconOnly || label.stringValue != title else { return }
        setAccessibilityHelp(String(appLocalized: "打开详情查看原因和修复方法"))
        action = next
        emphasis = tone
        setIconOnly(nextIconOnly)
        label.stringValue = next.title
        toolTip = next.title
        setAccessibilityLabel(next.title)
        hoverChanged()
        needsLayout = true
    }

    /// Icon only: 20 × 20 with an 11 pt glyph; otherwise a 10 pt glyph before the title.
    func setIconOnly(_ on: Bool) {
        iconOnly = on
        label.isHidden = on
        updateIcon()
        needsLayout = true
    }

    private func updateIcon() {
        guard let action else { icon.image = nil; return }
        icon.image = SubtitleStyle.symbol(action.symbol, size: iconOnly ? 11 : 10, weight: .semibold)
        // White on the red risk fill; white 90% on the neutral white 16% fill.
        icon.contentTintColor = emphasis == .risk ? .white : SubtitleStyle.white(0.9)
    }

    private var iconSize: NSSize {
        let size = icon.image?.size ?? .zero
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    var preferredWidth: CGFloat {
        let height = CGFloat(SubtitleTokens.Size.controlHeight)
        guard !iconOnly else { return height }
        return iconSize.width + Self.iconGap + ceil(label.intrinsicContentSize.width) + 20
    }

    override func layout() {
        super.layout()
        let glyph = iconSize
        if iconOnly {
            icon.frame = NSRect(x: ((bounds.width - glyph.width) / 2).rounded(), y: ((bounds.height - glyph.height) / 2).rounded(),
                                width: glyph.width, height: glyph.height)
            return
        }
        let textWidth = ceil(label.intrinsicContentSize.width)
        let height = ceil(label.intrinsicContentSize.height)
        let x = ((bounds.width - (glyph.width + Self.iconGap + textWidth)) / 2).rounded()
        icon.frame = NSRect(x: x, y: ((bounds.height - glyph.height) / 2).rounded(), width: glyph.width, height: glyph.height)
        label.frame = NSRect(x: x + glyph.width + Self.iconGap, y: (bounds.height - height) / 2,
                             width: textWidth + SubtitleStyle.labelSlack, height: height)
    }

    override func hoverChanged() {
        let display = SubtitleStyle.Display.current
        let base: NSColor = switch emphasis {
        case .risk: SubtitleStyle.color(.riskFill, display: display)
        case .unavailable, .none: SubtitleStyle.white(0.16)
        }
        layer?.backgroundColor = (isHovered ? base.blended(withFraction: 0.15, of: .white) ?? base : base).cgColor
    }
}
