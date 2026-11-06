// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import TalkTalkCore
import TalkTalkSession

/// The microphone status dock under the meeting/phone timeline (redesign §4, §5): a 0.5 pt top
/// separator, then icon 16 + state 13 pt semibold + consequence 12 pt white 60%, the flexible
/// 24 pt curve band and the keycap (or "修复…" / "详情"). While I speak it expands and shows my
/// live turn; the panel animates its height, never the window. Status and meter changes only
/// touch the status row and the curve; the turn text is rebuilt only when the turn changes.
@MainActor
final class MicStatusDock: NSView {
    struct Content: Equatable {
        var presentation: MicDockPresentation
        var key: TitlebarKey?
        /// My live turn; drawn only while `expanded`.
        var turn: ConversationTimeline.Turn?
        var expanded: Bool
        var showsStartHint: Bool
    }

    static let horizontalPadding: CGFloat = 12
    static let compactWaveHeight: CGFloat = 16
    static let compactWaveMaxWidth: CGFloat = 96

    /// Keycap, "修复…" and "详情" all open the details popover anchored here.
    var onAction: ((NSView) -> Void)?
    private(set) var content: Content?
    private var style: ConversationStyle?
    private var compact = false

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
    private let keycap = KeycapActionView()
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
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        dot.font = .systemFont(ofSize: 12)
        dot.textColor = SubtitleStyle.white(0.45)
        consequence.font = .systemFont(ofSize: 12)
        consequence.textColor = SubtitleStyle.white(0.6)
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = SubtitleStyle.white(0.45)
        hint.stringValue = MicDockPresentation.startHint
        for field in [label, dot, consequence, hint] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.setAccessibilityElement(false)
        }
        icon.setAccessibilityElement(false)
        for view in [icon, label, dot, consequence, hint] as [NSView] { status.addSubview(view) }
        keycap.onClick = { [weak self] in
            guard let self else { return }
            onAction?(keycap)
        }
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
        for view in [fill, bar, separator, status, wave, keycap, actionButton, turnArea] as [NSView] { addSubview(view) }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ next: Content?, style nextStyle: ConversationStyle, compact nextCompact: Bool) {
        let modeChanged = compact != nextCompact || style != nextStyle
        guard next != content || modeChanged else { return }
        content = next
        style = nextStyle
        compact = nextCompact
        // The panel owns visibility: no content means no session.
        guard let next else {
            wave.stop()
            return
        }
        if next.presentation != renderedPresentation || modeChanged { applyStatus(next.presentation, display: nextStyle.display) }
        let turn = next.expanded ? next.turn : nil
        if turn != renderedTurn || renderedTurnStyle != nextStyle { applyTurn(turn, style: nextStyle) }
        if let key = next.key { keycap.apply(key, showsAction: false, display: nextStyle.display) }
        if let action = next.presentation.action {
            actionButton.setTitle(action.title, tone: next.presentation.emphasis)
        }
        applyBackground(next, display: nextStyle.display)
        needsLayout = true
    }

    /// One meter tick: only the curve redraws.
    func setLevel(_ level: Float?) {
        guard content != nil, !isHidden else { wave.stop(); return }
        wave.setLevel(level)
    }

    func stopLevel() { wave.stop() }

    /// Settings preview: a fixed example level that never expires.
    func setPreviewLevel(_ level: Float) {
        wave.isPreview = true
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
        wave.setStyle(presentation.wave, color: color)
        if presentation.wave == .none { wave.stop() }
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
        text.appendTranslation(turn.translation, role: style.typography.myTranslation, isFinal: turn.isFinal,
                               fallback: false, to: translation)
        sourceLabel.attributedStringValue = source
        translationLabel.attributedStringValue = translation
        let spokenSource = ConversationText.accessibilityText(source)
        let spokenTranslation = ConversationText.accessibilityText(translation)
        turnArea.setAccessibilityLabel(spokenTranslation.isEmpty
            ? String(localized: "我正在说：\(spokenSource)")
            : String(localized: "我：\(spokenSource)；译文：\(spokenTranslation)"))
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
        fill.layer?.backgroundColor = fillColor?.cgColor
        fill.isHidden = fillColor == nil
        bar.layer?.backgroundColor = barColor?.cgColor
        bar.isHidden = barColor == nil
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
        fill.frame = bounds
        bar.frame = NSRect(x: 0, y: 0, width: 3, height: height)
        separator.frame = NSRect(x: 0, y: 0, width: width,
                                 height: CGFloat(SubtitleTokens.separatorWidth(increaseContrast: display.increaseContrast)))
        // The status row keeps its idle height (48, or 28 in a low window) while expanded, so it
        // does not jump; my turn takes the space below it.
        let idleRow = compact ? CGFloat(ConversationLayout.compactDockHeight) : CGFloat(SubtitleTokens.Size.statusBandIdleHeight)
        let bottomPadding = CGFloat(SubtitleTokens.Size.panelBottomPadding)
        let expanded = content.expanded && height > idleRow + bottomPadding
        let rowHeight = min(height, idleRow)

        // Trailing control: the keycap, or the button that replaces it for risk / unavailable.
        var trailing: NSView?
        var trailingWidth: CGFloat = 0
        if !compact {
            if content.presentation.action != nil {
                trailing = actionButton
                trailingWidth = actionButton.preferredWidth
            } else if let key = content.key {
                trailing = keycap
                trailingWidth = KeycapActionView.width(for: key, showsAction: false)
            }
        }
        keycap.isHidden = trailing !== keycap
        actionButton.isHidden = trailing !== actionButton
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

        // The curve takes the flexible middle; it never overlaps text or the keycap.
        let waveHeight = compact ? Self.compactWaveHeight : CGFloat(SubtitleTokens.Size.waveformBandHeight)
        var waveWidth = max(0, limit - x - padding)
        if compact { waveWidth = min(waveWidth, Self.compactWaveMaxWidth) }
        wave.isHidden = waveWidth < 24 || content.presentation.wave == .none
        wave.frame = NSRect(x: x + padding, y: ((rowHeight - waveHeight) / 2).rounded(), width: waveWidth, height: waveHeight)

        // My live turn below the status row, in the timeline's columns, newest lines kept.
        turnArea.isHidden = !expanded || content.turn == nil
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

/// "修复…" / "详情": 20 pt, radius 10, 11 pt semibold; it opens the details popover.
@MainActor
final class DockActionButton: TitlebarControl {
    private let label = NSTextField(labelWithString: "")
    private var emphasis: MicDockPresentation.Emphasis = .none

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        layer?.cornerRadius = CGFloat(SubtitleTokens.Size.controlHeight) / 2
        label.font = SubtitleStyle.controlFont(ControlTypography.capsule, weight: .semibold)
        label.alignment = .center
        label.setAccessibilityElement(false)
        addSubview(label)
        hoverChanged()
    }

    required init?(coder: NSCoder) { nil }

    func setTitle(_ title: String, tone: MicDockPresentation.Emphasis) {
        emphasis = tone
        label.stringValue = title
        label.textColor = .white
        setAccessibilityLabel(title)
        setAccessibilityHelp(String(localized: "打开详情查看原因和修复方法"))
        hoverChanged()
        needsLayout = true
    }

    var preferredWidth: CGFloat { ceil(label.intrinsicContentSize.width) + 20 }

    override func layout() {
        super.layout()
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
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
