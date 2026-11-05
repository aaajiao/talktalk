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
            source.pendingScroll = .top
            translation.pendingScroll = .top
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
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
        divider.isHidden = !columns
        if columns {
            let gap: CGFloat = 20, headingHeight: CGFloat = 18, top: CGFloat = 24
            let columnWidth = max(0, (width - gap) / 2)
            source.heading.frame = NSRect(x: 0, y: 0, width: columnWidth, height: headingHeight)
            translation.heading.frame = NSRect(x: columnWidth + gap, y: 0, width: columnWidth, height: headingHeight)
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
    private final class Column {
        enum ScrollPosition: Equatable { case top, tail }
        let heading: ConversationLabel
        let scroll = ConversationScrollView()
        private let document = ConversationContentView()
        private let label = ConversationLabel(wrappingLabelWithString: "")
        private var hasContent = false
        var pendingScroll: ScrollPosition?

        init(title: String) {
            heading = ConversationLabel(labelWithString: title)
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
        }

        func setText(_ text: NSAttributedString, reset: Bool) -> Bool {
            let oldText = label.attributedStringValue
            guard reset || !oldText.isEqual(to: text) else { return false }
            let firstContent = !hasContent && text.length > 0
            let atBottom = document.bounds.height - scroll.documentVisibleRect.maxY <= 2
            if reset || firstContent || text.length == 0 || pendingScroll == .top {
                pendingScroll = .top
            } else if oldText.string != text.string, atBottom {
                pendingScroll = .tail
            }
            // Font/color-only updates (including resize) preserve the reading offset.
            hasContent = text.length > 0
            label.attributedStringValue = NSAttributedString(attributedString: text)
            return true
        }

        func layout(preserving offset: CGFloat) {
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
