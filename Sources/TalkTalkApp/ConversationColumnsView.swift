// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit

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
    private let divider = NSBox()

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
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
    }

    required init?(coder: NSCoder) { return nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    func setText(source: NSAttributedString, translation: NSAttributedString, resetScroll: Bool = false) {
        let sourceChanged = self.source.setText(source, reset: resetScroll)
        let translationChanged = self.translation.setText(translation, reset: resetScroll)
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
        source.heading.isHidden = !columns
        translation.heading.isHidden = !columns
        source.latestButton.isHidden = !columns || !source.hasPendingText
        translation.latestButton.isHidden = !columns || !translation.hasPendingText
        divider.isHidden = !columns
        if columns {
            let gap: CGFloat = 20, headingHeight: CGFloat = 18, top: CGFloat = 24
            let columnWidth = max(0, (width - gap) / 2)
            let buttonWidth: CGFloat = 86
            source.heading.frame = NSRect(x: 0, y: 0, width: max(0, columnWidth - (source.hasPendingText ? buttonWidth + 4 : 0)), height: headingHeight)
            translation.heading.frame = NSRect(x: columnWidth + gap, y: 0, width: max(0, columnWidth - (translation.hasPendingText ? buttonWidth + 4 : 0)), height: headingHeight)
            source.latestButton.frame = NSRect(x: max(0, columnWidth - buttonWidth), y: 0, width: buttonWidth, height: 20)
            translation.latestButton.frame = NSRect(x: width - buttonWidth, y: 0, width: buttonWidth, height: 20)
            source.scroll.frame = NSRect(x: 0, y: top, width: columnWidth, height: max(0, height - top))
            translation.scroll.frame = NSRect(x: columnWidth + gap, y: top, width: columnWidth, height: max(0, height - top))
            divider.frame = NSRect(x: width / 2, y: 0, width: 1, height: height)
        } else {
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
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.isSelectable = false
            label.cell?.isScrollable = false
            document.addSubview(label)
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
                label.attributedStringValue = pendingText
                hasContent = pendingText.length > 0
            }
            pendingText = nil
            pendingScroll = .tail
        }

        func setText(_ text: NSAttributedString, reset: Bool) -> Bool {
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
            label.attributedStringValue = NSAttributedString(attributedString: text)
            return true
        }

        @objc private func returnToLatest() {
            guard let pendingText else { return }
            label.attributedStringValue = pendingText
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
