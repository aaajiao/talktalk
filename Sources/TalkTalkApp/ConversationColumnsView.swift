// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import QuartzCore
import TalkTalkCore

/// A fixed viewport containing two independent, persistent reading areas. The owner supplies
/// attributed text and the frame; it must not wrap this view in another scroll view.
@MainActor
final class ConversationColumnsView: NSView {
    enum Style: Sendable, Equatable { case columns, subtitles }

    var style: Style = .columns {
        didSet {
            guard style != oldValue else { return }
            source.setFreezingEnabled(style == .columns)
            translation.setFreezingEnabled(style == .columns)
            needsLayout = true
            layoutSubtreeIfNeeded()
            onDisplayedTextChange?()
        }
    }
    var onDisplayedTextChange: (() -> Void)?
    var hasPendingText: Bool { source.hasPendingText || translation.hasPendingText }
    var isReadingHistory: Bool {
        style == .columns && (source.isReadingHistory || translation.isReadingHistory)
    }

    private let source = Column(title: String(localized: "原文"))
    private let translation = Column(title: String(localized: "译文"))
    private let sourceIcon = NSImageView()
    private let translationIcon = NSImageView()
    private var sourceSymbol = "person"
    private let inputBackdrop = AudioActivityBackdrop()
    private let inputIcon = NSImageView()
    private let inputLabel = ConversationLabel(labelWithString: String(localized: "收音"))
    private var inputIsActive = false
    private let outputIcon = NSImageView()
    private let outputLabel = ConversationLabel(labelWithString: "")
    private var outputSymbol: String?
    private var outputText: String?
    private let divider = NSBox()

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        addSubview(inputBackdrop)
        for column in [source, translation] {
            addSubview(column.heading)
            addSubview(column.scroll)
            addSubview(column.latestButton)
            column.onPendingApplied = { [weak self] in
                guard let self else { return }
                needsLayout = true
                layoutSubtreeIfNeeded()
                onDisplayedTextChange?()
            }
        }
        divider.boxType = .separator
        addSubview(divider)
        sourceIcon.image = NSImage(systemSymbolName: sourceSymbol, accessibilityDescription: nil)
        translationIcon.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: nil)
        for icon in [sourceIcon, translationIcon] {
            icon.contentTintColor = .secondaryLabelColor
            icon.setAccessibilityElement(false)
            addSubview(icon)
        }
        inputIcon.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: String(localized: "收音"))
        inputIcon.contentTintColor = .controlAccentColor
        inputIcon.toolTip = String(localized: "收音")
        inputIcon.isHidden = true
        inputLabel.font = .systemFont(ofSize: 11)
        inputLabel.textColor = .controlAccentColor
        inputLabel.maximumNumberOfLines = 1
        inputLabel.isHidden = true
        addSubview(inputIcon)
        addSubview(inputLabel)
        outputIcon.contentTintColor = .secondaryLabelColor
        outputIcon.isHidden = true
        outputLabel.font = .systemFont(ofSize: 11)
        outputLabel.textColor = .secondaryLabelColor
        outputLabel.lineBreakMode = .byTruncatingTail
        outputLabel.maximumNumberOfLines = 1
        outputLabel.isHidden = true
        addSubview(outputIcon)
        addSubview(outputLabel)
    }

    required init?(coder: NSCoder) { return nil }

    /// Every cell identifies its speaker and language without a separate row of labels.
    func setHeadings(source: String, sourceSymbol: String, translation: String) {
        guard self.source.heading.stringValue != source || self.sourceSymbol != sourceSymbol
                || self.translation.heading.stringValue != translation else { return }
        self.source.heading.stringValue = source
        self.source.heading.toolTip = source
        self.source.scroll.setAccessibilityLabel(source + " · " + String(localized: "原文"))
        self.translation.heading.stringValue = translation
        self.translation.heading.toolTip = translation
        self.translation.scroll.setAccessibilityLabel(translation + " · " + String(localized: "译文"))
        if self.sourceSymbol != sourceSymbol {
            self.sourceSymbol = sourceSymbol
            sourceIcon.image = NSImage(systemSymbolName: sourceSymbol, accessibilityDescription: nil)
        }
        layoutHeadings()
    }

    /// The local row alone supplies a level. The video layout never renders a waveform.
    /// Meter ticks update only the backdrop, preserving text layout and every scroll offset.
    func setInputActivity(_ level: Float?) {
        inputBackdrop.setLevel(style == .columns ? level : nil)
        setInputHeaderActive(style == .columns && level?.isFinite == true
            && window?.isVisible == true && window?.isMiniaturized == false && !isHiddenOrHasHiddenAncestor)
    }

    /// Fixed settings example; no microphone or timed animation is started by a preview.
    func setInputPreviewActivity(_ level: Float?) {
        inputBackdrop.setLevel(style == .columns ? level : nil, preview: true)
        setInputHeaderActive(style == .columns && level?.isFinite == true)
    }

    private func setInputHeaderActive(_ active: Bool) {
        guard inputIsActive != active else { return }
        inputIsActive = active
        layoutHeadings()
    }

    /// Processing and actual playback can coexist with input activity. Change only the
    /// translation heading; neither reading viewport is rebuilt or laid out by this update.
    func setOutputActivity(symbol: String?, label: String?, tint: NSColor? = nil) {
        let color = tint ?? .secondaryLabelColor
        guard outputSymbol != symbol || outputText != label || outputIcon.contentTintColor != color else { return }
        outputSymbol = symbol
        outputText = label
        outputIcon.contentTintColor = color
        outputLabel.textColor = color
        outputIcon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: label) }
        outputIcon.toolTip = label
        outputLabel.stringValue = label ?? ""
        outputLabel.toolTip = label
        layoutHeadings()
    }

    private func layoutHeadings() {
        let columns = style == .columns
        let width = max(0, bounds.width), gap: CGFloat = 20
        let columnWidth = max(0, (width - gap) / 2)
        func place(_ column: Column, icon: NSImageView, x: CGFloat,
                   activityIcon: NSImageView, activityLabel: ConversationLabel, active: Bool) {
            let buttonWidth = min(86, columnWidth)
            let available = max(0, columnWidth - (column.hasPendingText ? buttonWidth + 6 : 0))
            let showsIcon = columns && available >= 14
            let inset: CGFloat = showsIcon ? 20 : 0
            let headingWidth = min(max(0, available - inset), column.heading.intrinsicContentSize.width)
            let activitySpace = max(0, available - inset - headingWidth - 8)
            let showsActivity = columns && active && activitySpace >= 14
            let desiredLabelWidth = min(150, activityLabel.intrinsicContentSize.width)
            let labelWidth = showsActivity && activitySpace >= desiredLabelWidth + 19 ? desiredLabelWidth : 0
            let activityWidth: CGFloat = showsActivity ? 14 + (labelWidth > 0 ? labelWidth + 5 : 0) : 0
            let activityX = x + available - activityWidth
            column.heading.isHidden = !columns
            column.heading.frame = NSRect(x: x + inset, y: 0,
                width: max(0, available - inset - (showsActivity ? activityWidth + 8 : 0)), height: 18)
            icon.isHidden = !showsIcon
            icon.frame = NSRect(x: x, y: 2, width: 14, height: 14)
            column.latestButton.isHidden = !columns || !column.hasPendingText
            column.latestButton.frame = NSRect(x: x + columnWidth - buttonWidth, y: 0, width: buttonWidth, height: 20)
            activityIcon.isHidden = !showsActivity
            activityIcon.frame = NSRect(x: activityX, y: 2, width: 14, height: 14)
            activityLabel.isHidden = !showsActivity || labelWidth == 0
            activityLabel.frame = NSRect(x: activityX + 19, y: 1, width: labelWidth, height: 17)
        }
        place(source, icon: sourceIcon, x: 0, activityIcon: inputIcon, activityLabel: inputLabel, active: inputIsActive)
        place(translation, icon: translationIcon, x: columnWidth + gap,
              activityIcon: outputIcon, activityLabel: outputLabel, active: outputSymbol != nil)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// `finalized`: a draft became final in place; its colour fades over 150 ms without reflow.
    func setText(source: NSAttributedString, translation: NSAttributedString, resetScroll: Bool = false,
                 finalized: Bool = false) {
        let sourceChanged = self.source.setText(source, reset: resetScroll, finalized: finalized)
        let translationChanged = self.translation.setText(translation, reset: resetScroll, finalized: finalized)
        guard sourceChanged || translationChanged else { return }
        needsLayout = true
        layoutSubtreeIfNeeded()
        onDisplayedTextChange?()
    }

    override func layout() {
        super.layout()
        // Capture before resizing the clip views; AppKit may clamp their bounds while tiling.
        let sourceOffset = source.scroll.contentView.bounds.origin.y
        let translationOffset = translation.scroll.contentView.bounds.origin.y
        let width = max(0, bounds.width), height = max(0, bounds.height)
        let columns = style == .columns
        inputBackdrop.isHidden = !columns
        layoutHeadings()
        divider.isHidden = !columns
        if columns {
            let gap: CGFloat = 20, top: CGFloat = 24
            let columnWidth = max(0, (width - gap) / 2)
            source.scroll.frame = NSRect(x: 0, y: top, width: columnWidth, height: max(0, height - top))
            inputBackdrop.frame = source.scroll.frame
            translation.scroll.frame = NSRect(x: columnWidth + gap, y: top, width: columnWidth, height: max(0, height - top))
            divider.frame = NSRect(x: width / 2, y: 0, width: 1, height: height)
        } else {
            inputBackdrop.setLevel(nil)
            let gap: CGFloat = 8
            let usableHeight = max(0, height - gap)
            let sourceHeight = usableHeight / 3
            source.scroll.frame = NSRect(x: 0, y: 0, width: width, height: sourceHeight)
            translation.scroll.frame = NSRect(x: 0, y: sourceHeight + gap, width: width, height: usableHeight - sourceHeight)
        }
        source.layout(preserving: sourceOffset)
        translation.layout(preserving: translationOffset)
    }

    @MainActor
    private final class Column: NSObject {
        enum ScrollPosition: Equatable { case top, tail }
        let heading: ConversationLabel
        let scroll = ConversationScrollView()
        let latestButton = NSButton(title: String(localized: "回到最新"), target: nil, action: nil)
        private let document = ConversationContentView()
        private let label = ConversationLabel(wrappingLabelWithString: "")
        /// 2 pt voice.translate bar beside the open draft translation (§4 三态).
        private let draftBar = NSView()
        private var hasContent = false
        private var pendingText: NSAttributedString?
        private var allowsFreeze = true
        private var isLayingOut = false
        private var scrollObserver: NSObjectProtocol?
        var onPendingApplied: (() -> Void)?
        var pendingScroll: ScrollPosition?
        var hasPendingText: Bool { pendingText != nil }
        var isReadingHistory: Bool { hasContent && (!atBottom || hasPendingText) }
        private var atBottom: Bool { document.bounds.height - scroll.documentVisibleRect.maxY <= 2 }

        init(title: String) {
            heading = ConversationLabel(labelWithString: title)
            super.init()
            heading.font = .systemFont(ofSize: 12, weight: .semibold)
            heading.textColor = .secondaryLabelColor
            heading.maximumNumberOfLines = 1
            heading.lineBreakMode = .byTruncatingTail
            heading.cell?.isScrollable = false
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.isSelectable = false
            label.cell?.isScrollable = false
            document.addSubview(label)
            draftBar.wantsLayer = true
            draftBar.isHidden = true
            draftBar.setAccessibilityElement(false)
            document.addSubview(draftBar)
            scroll.documentView = document
            scroll.drawsBackground = false
            scroll.contentView.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.automaticallyAdjustsContentInsets = false
            scroll.setAccessibilityLabel(title)
            latestButton.bezelStyle = .rounded
            latestButton.controlSize = .small
            latestButton.target = self
            latestButton.action = #selector(returnToLatest)
            latestButton.isHidden = true
            scroll.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, !self.isLayingOut, self.hasPendingText, self.atBottom else { return }
                        self.returnToLatest()
                    }
                }
        }

        isolated deinit {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        }

        func setFreezingEnabled(_ enabled: Bool) {
            allowsFreeze = enabled
            if let pendingText {
                show(pendingText)
                hasContent = pendingText.length > 0
            }
            pendingText = nil
            pendingScroll = .tail
        }

        func setText(_ text: NSAttributedString, reset: Bool, finalized: Bool = false) -> Bool {
            let oldText = label.attributedStringValue
            if !reset, allowsFreeze, hasContent, !atBottom, text.length > 0, oldText.string != text.string {
                guard pendingText?.isEqual(to: text) != true else { return false }
                // One replacement snapshot only: keep the visible reading position and never
                // append intermediate updates or extend the retained history here.
                pendingText = NSAttributedString(attributedString: text)
                return true
            }
            let hadPending = pendingText != nil
            pendingText = nil
            guard reset || hadPending || !oldText.isEqual(to: text) else { return false }
            if reset || !hasContent || text.length == 0 || (oldText.string != text.string && atBottom) {
                pendingScroll = .tail
            }
            // Font/color-only updates (including resize) preserve the reading offset.
            hasContent = text.length > 0
            if finalized, !reset { fadeNextChange() }
            show(text)
            return true
        }

        private func show(_ text: NSAttributedString) {
            label.attributedStringValue = NSAttributedString(attributedString: text)
            label.setAccessibilityValue(ConversationText.accessibilityText(text))
        }

        /// Draft → final changes colour only; a short cross-fade avoids a hard switch.
        private func fadeNextChange() {
            let duration = SubtitleStyle.duration(.draftToFinal)
            guard duration > 0 else { return }
            label.wantsLayer = true
            let transition = CATransition()
            transition.type = .fade
            transition.duration = duration
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            label.layer?.add(transition, forKey: "draftToFinal")
            draftBar.wantsLayer = true
            draftBar.layer?.add(transition, forKey: "draftToFinal")
        }

        /// Places the draft bar and badge tooltips from the label's laid-out text.
        private func decorate(textWidth: CGFloat) {
            let text = label.attributedStringValue
            document.removeAllToolTips()
            var draft: NSRange?
            var badges: [(NSRange, String)] = []
            let whole = NSRange(location: 0, length: text.length)
            text.enumerateAttribute(.talkTalkDraft, in: whole) { value, range, _ in
                guard value != nil else { return }
                draft = draft.map { NSUnionRange($0, range) } ?? range
            }
            text.enumerateAttribute(.talkTalkBadgeHelp, in: whole) { value, range, _ in
                if let help = value as? String, !help.isEmpty { badges.append((range, help)) }
            }
            guard draft != nil || !badges.isEmpty else { draftBar.isHidden = true; return }
            let storage = NSTextStorage(attributedString: text)
            let manager = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: textWidth, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 2
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
            func rect(_ range: NSRange) -> NSRect {
                let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                return manager.boundingRect(forGlyphRange: glyphs, in: container)
                    .offsetBy(dx: label.frame.minX, dy: label.frame.minY)
            }
            if let draft {
                let bounds = rect(draft)
                draftBar.layer?.backgroundColor = SubtitleStyle.color(.voiceTranslate)
                    .withAlphaComponent(ConversationTextRules.draftBarAlpha).cgColor
                draftBar.frame = NSRect(x: 0, y: bounds.minY, width: ConversationTextRules.draftBarWidth, height: bounds.height)
                draftBar.isHidden = false
            } else {
                draftBar.isHidden = true
            }
            for (range, help) in badges {
                document.addToolTip(rect(range), owner: help as NSString, userData: nil)
            }
        }

        @objc private func returnToLatest() {
            guard let pendingText else { return }
            show(pendingText)
            hasContent = pendingText.length > 0
            self.pendingText = nil
            pendingScroll = .tail
            onPendingApplied?()
        }

        func layout(preserving offset: CGFloat) {
            isLayingOut = true
            defer { isLayingOut = false }
            scroll.tile()
            let viewport = scroll.contentView.bounds.size
            guard viewport.width > 0, viewport.height > 0 else { return }
            let left: CGFloat = 4, right: CGFloat = 16, verticalInset: CGFloat = 4
            let textWidth = max(1, viewport.width - left - right)
            label.preferredMaxLayoutWidth = textWidth
            let measured = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude)).height ?? 0
            let textHeight = ceil(measured) + 2
            label.frame = NSRect(x: left, y: verticalInset, width: textWidth, height: textHeight)
            decorate(textWidth: textWidth)
            document.frame = NSRect(x: 0, y: 0, width: viewport.width,
                                    height: max(viewport.height, textHeight + verticalInset * 2))
            let limit = max(0, document.bounds.height - viewport.height)
            let next: CGFloat = switch pendingScroll {
            case .top: 0
            case .tail: limit
            case nil: min(max(0, offset), limit)
            }
            pendingScroll = nil
            scroll.contentView.scroll(to: NSPoint(x: 0, y: next))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}
