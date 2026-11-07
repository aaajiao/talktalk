// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import QuartzCore
import TalkTalkCore
import TalkTalkSession
import TalkTalkSettingsUI

/// Reading style shared by the timeline rows and the dock's live turn (redesign §2, §4).
struct ConversationStyle: Equatable {
    var typography: ConversationTypography
    var opacity: Double
    var display: SubtitleStyle.Display
    var scene: SubtitleScene
    var stacked: Bool

    @MainActor var text: ConversationText {
        ConversationText(typography: typography, opacity: opacity, display: display, paragraphSpacing: 4)
    }
}

/// Meeting/phone conversation (redesign §4): the column header once per window, one scroll
/// view of pair rows that follow or freeze together, the "[arrow.down] N 条新字幕" pill and the empty
/// state. The panel gives it a frame; nothing here resizes the window. Remote previews arrive
/// at most every 500 ms and only rows whose content changed are rebuilt (normally the last).
@MainActor
final class ConversationTimelineView: NSView {
    typealias Row = ConversationTimeline.Row

    var onDisplayedRowsChange: (() -> Void)?
    var onPlaceholderClick: ((NSView) -> Void)?

    private let sourceHeader = NSTextField(labelWithString: "")
    private let translationHeader = NSTextField(labelWithString: "")
    private let scroll = ConversationScrollView()
    private let document = ConversationContentView()
    private let pill = JumpToLatestPill()
    private let placeholder = TimelinePlaceholder()
    private var rowViews: [ConversationTimeline.RowID: TimelineRowView] = [:]
    private var shownIDs: [ConversationTimeline.RowID] = []
    private var follow = TimelineFollow()
    private var style: ConversationStyle?
    private var lastRowOnly = false
    private var showsHeader = true
    private var expandedRows: Set<ConversationTimeline.RowID> = []
    private var isAdjustingScroll = false
    private var scrollObserver: NSObjectProtocol?
    private var placeholderContent: TimelinePlaceholder.Content?
    private var placeholderFading = false

    var displayedRows: [Row] { follow.displayed }
    var isFrozen: Bool { follow.isFrozen }
    var isEmpty: Bool { follow.displayed.isEmpty }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        for header in [sourceHeader, translationHeader] {
            header.font = .systemFont(ofSize: ControlTypography.columnHeader, weight: .semibold)
            header.textColor = SubtitleStyle.color(.textColumnHeader)
            header.lineBreakMode = .byTruncatingTail
            header.maximumNumberOfLines = 1
            addSubview(header)
        }
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.setAccessibilityLabel(String(appLocalized: "对话字幕"))
        addSubview(scroll)
        placeholder.isHidden = true
        placeholder.onClick = { [weak self] in
            guard let self, placeholderContent?.clickable == true else { return }
            onPlaceholderClick?(placeholder)
        }
        addSubview(placeholder)
        pill.isHidden = true
        pill.onClick = { [weak self] in self?.followLatest() }
        addSubview(pill)
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.userScrolled() }
            }
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    /// Generic columns also fit local speech and rows from earlier language selections.
    func setHeader(source: String, translation: String) {
        sourceHeader.stringValue = source
        translationHeader.stringValue = translation
    }

    func setPlaceholder(_ content: TimelinePlaceholder.Content?) {
        guard placeholderContent != content else { return }
        placeholderContent = content
        if let content { placeholder.apply(content) }
        updatePlaceholder(animated: false)
        needsLayout = true
    }

    /// Re-render annotations in place, retaining frozen rows, expansion and scroll position.
    func refreshAppLanguage() {
        setHeader(source: String(appLocalized: "原文"), translation: String(appLocalized: "译文"))
        scroll.setAccessibilityLabel(String(appLocalized: "对话字幕"))
        rowViews.values.forEach { $0.refreshAppLanguage() }
        updatePill()
        needsLayout = true
    }

    /// New rows from the timeline. While frozen they only replace the one latest snapshot.
    func apply(rows: [Row], style nextStyle: ConversationStyle, lastRowOnly nextLastRowOnly: Bool, showsHeader nextHeader: Bool) {
        let styleChanged = style != nextStyle
        let modeChanged = lastRowOnly != nextLastRowOnly || showsHeader != nextHeader
        style = nextStyle
        lastRowOnly = nextLastRowOnly
        showsHeader = nextHeader
        sourceHeader.isHidden = !nextHeader
        translationHeader.isHidden = !nextHeader
        follow.update(rows)
        // The last-row-only window cannot scroll back; it always follows.
        if nextLastRowOnly, follow.isFrozen { follow.follow() }
        if follow.isFrozen && !styleChanged && !modeChanged {
            updatePill()
            return
        }
        reconcile()
    }

    /// Clicking the pill, scrolling back to the end, a new own turn or a reset.
    func followLatest() {
        let wasFrozen = follow.isFrozen
        follow.follow()
        if wasFrozen { reconcile() }
        scrollToEnd()
        updatePill()
    }

    private func reconcile() {
        guard let style else { return }
        let rows = follow.displayed
        let visible = lastRowOnly ? Array(rows.suffix(1)) : rows
        var next: [ConversationTimeline.RowID: TimelineRowView] = [:]
        for row in visible {
            let view = rowViews[row.id] ?? TimelineRowView()
            view.onExpand = { [weak self, id = row.id] in self?.expand(id) }
            view.update(row: row, style: style, expanded: expandedRows.contains(row.id))
            if view.superview !== document { document.addSubview(view) }
            next[row.id] = view
        }
        for (id, view) in rowViews where next[id] == nil { view.removeFromSuperview() }
        rowViews = next
        shownIDs = visible.map(\.id)
        expandedRows = expandedRows.filter { next[$0] != nil }
        updatePlaceholder(animated: true)
        updatePill()
        needsLayout = true
        layoutSubtreeIfNeeded()
        onDisplayedRowsChange?()
    }

    private func expand(_ id: ConversationTimeline.RowID) {
        guard let style, let view = rowViews[id] else { return }
        expandedRows.insert(id)
        view.update(row: view.row, style: style, expanded: true)
        needsLayout = true
    }

    private var isAtEnd: Bool {
        document.bounds.height - scroll.documentVisibleRect.maxY <= 2
    }

    private func userScrolled() {
        guard !isAdjustingScroll, !shownIDs.isEmpty, !lastRowOnly else { return }
        if isAtEnd {
            if follow.isFrozen { followLatest() }
        } else if !follow.isFrozen {
            follow.freeze()
            updatePill()
        }
    }

    private func scrollToEnd() {
        isAdjustingScroll = true
        defer { isAdjustingScroll = false }
        let limit = max(0, document.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: limit))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        isAdjustingScroll = true
        defer { isAdjustingScroll = false }
        // Capture before resizing the clip view; AppKit may clamp its bounds while tiling.
        let offset = scroll.contentView.bounds.origin.y
        let width = max(0, bounds.width), height = max(0, bounds.height)
        let headerHeight = showsHeader ? CGFloat(SubtitleTokens.Size.columnHeaderHeight) : 0
        if showsHeader {
            let columns = ConversationLayout.columns(rowWidth: Double(width), stacked: false)
            let labelHeight: CGFloat = 15
            let y = (headerHeight - labelHeight) / 2
            sourceHeader.frame = NSRect(x: columns.sourceX, y: y, width: columns.sourceWidth, height: labelHeight)
            translationHeader.frame = NSRect(x: columns.translationX, y: y, width: columns.translationWidth, height: labelHeight)
        }
        scroll.frame = NSRect(x: 0, y: headerHeight, width: width, height: max(0, height - headerHeight))
        scroll.tile()
        let rowWidth = scroll.contentView.bounds.width
        var y: CGFloat = 0
        for (index, id) in shownIDs.enumerated() {
            guard let view = rowViews[id] else { continue }
            let speaker = view.row.speaker
            view.segmentStart = index == 0 || rowViews[shownIDs[index - 1]]?.row.speaker != speaker
            view.segmentEnd = index == shownIDs.count - 1 || rowViews[shownIDs[index + 1]]?.row.speaker != speaker
            view.showsSeparator = index > 0
            let rowHeight = view.height(for: rowWidth)
            view.frame = NSRect(x: 0, y: y, width: rowWidth, height: rowHeight)
            y += rowHeight
        }
        let viewport = scroll.contentView.bounds.height
        document.frame = NSRect(x: 0, y: 0, width: rowWidth, height: max(y, viewport))
        // Following keeps the newest row in view; a frozen reader keeps its own position, also
        // when the dock grows or shrinks.
        let limit = max(0, document.frame.height - viewport)
        let target = follow.isFrozen ? min(max(0, offset), limit) : limit
        scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)

        let pillWidth = pill.preferredWidth
        let pillHeight = CGFloat(SubtitleTokens.Size.jumpToLatestHeight)
        pill.frame = NSRect(x: ((width - pillWidth) / 2).rounded(), y: height - CGFloat(ConversationLayout.jumpPillGap) - pillHeight,
                            width: pillWidth, height: pillHeight)
        let size = placeholder.fittingSize(maxWidth: max(0, width - 32))
        let area = scroll.frame
        placeholder.frame = NSRect(x: ((width - size.width) / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                                   width: size.width, height: size.height)
    }

    private func updatePill() {
        let count = follow.newFinalCount
        let shows = follow.isFrozen && count > 0
        if shows { pill.setCount(count) }
        if pill.isHidden == shows { pill.isHidden = !shows; needsLayout = true }
    }

    /// The empty state fades out over 120 ms when the first row arrives.
    private func updatePlaceholder(animated: Bool) {
        let wanted = placeholderContent != nil && follow.displayed.isEmpty
        if wanted {
            placeholderFading = false
            placeholder.alphaValue = 1
            placeholder.isHidden = false
            return
        }
        guard !placeholder.isHidden, !placeholderFading else { return }
        let duration = animated ? SubtitleStyle.duration(.placeholderFadeOut, display: style?.display ?? .current) : 0
        guard duration > 0 else { placeholder.isHidden = true; return }
        placeholderFading = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            placeholder.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.placeholderFading else { return }
                self.placeholderFading = false
                self.placeholder.isHidden = true
                self.placeholder.alphaValue = 1
            }
        })
    }
}

/// One pair row: speaker track 24 + source 40% + gap 16 + translation 60%, top aligned, with
/// the pair padding; my rows add the meRow fill and a delivery label. Stacked below 520 pt.
@MainActor
final class TimelineRowView: NSView, HoverClearing {
    private(set) var row = ConversationTimeline.Row(id: .remoteLive(0), speaker: .remote, source: "", sourceIsLive: false,
                                                    translation: "", translationIsFinal: true, fallback: false,
                                                    unsentSource: "", delivery: nil, arrivedAt: 0, settledAt: nil, order: 0)
    private var style: ConversationStyle?
    private(set) var expanded = false
    var onExpand: (() -> Void)?
    var segmentStart = true { didSet { if oldValue != segmentStart { needsLayout = true } } }
    var segmentEnd = true { didSet { if oldValue != segmentEnd { needsLayout = true } } }
    var showsSeparator = false { didSet { if oldValue != showsSeparator { needsLayout = true } } }

    private let background = NSView()
    private let hover = NSView()
    private let separator = NSView()
    private let track = TrackBarView()
    private let mark = NSImageView()
    private let sourceLabel = ConversationLabel(wrappingLabelWithString: "")
    private let translationLabel = ConversationLabel(wrappingLabelWithString: "")
    private let draftBar = NSView()
    /// The badge tooltips' owners: `addToolTip` does not retain them.
    private var badgeToolTipOwners: [NSString] = []
    private let expandControl = InlineLinkControl()
    private var sourceText = NSAttributedString()
    private var translationText = NSAttributedString()
    private var measuredWidth: CGFloat = -1
    private var rowHeight: CGFloat = 0
    private var sourceFrame = NSRect.zero
    private var translationFrame = NSRect.zero
    private var tokenFrame: NSRect?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        for view in [background, hover, separator, draftBar] {
            view.wantsLayer = true
            view.setAccessibilityElement(false)
        }
        hover.isHidden = true
        draftBar.isHidden = true
        mark.imageScaling = .scaleNone
        mark.setAccessibilityElement(false)
        for label in [sourceLabel, translationLabel] {
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.isSelectable = false
            label.cell?.isScrollable = false
            label.setAccessibilityElement(false)
        }
        expandControl.isHidden = true
        expandControl.setAccessibilityLabel(String(appLocalized: "展开原文"))
        expandControl.toolTip = String(appLocalized: "展开原文")
        expandControl.onClick = { [weak self] in self?.onExpand?() }
        for view in [background, hover, separator, track, mark, sourceLabel, translationLabel, draftBar, expandControl] as [NSView] {
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { nil }

    func update(row next: ConversationTimeline.Row, style nextStyle: ConversationStyle, expanded nextExpanded: Bool) {
        let finalized = row.id == next.id && !row.translationIsFinal && next.translationIsFinal && !next.translation.isEmpty
        let textChanged = row.source != next.source || row.sourceIsLive != next.sourceIsLive
            || row.translation != next.translation || row.translationIsFinal != next.translationIsFinal
            || row.fallback != next.fallback || row.unsentSource != next.unsentSource || row.delivery != next.delivery
            || row.speaker != next.speaker || style != nextStyle || measuredWidth < 0
        let expansionChanged = expanded != nextExpanded
        row = next
        style = nextStyle
        expanded = nextExpanded
        guard textChanged || expansionChanged else { return }
        if textChanged { rebuildText() }
        if finalized { fadeNextChange(nextStyle.display) }
        measuredWidth = -1
        applyColors()
        needsLayout = true
    }

    func refreshAppLanguage() {
        expandControl.setAccessibilityLabel(String(appLocalized: "展开原文"))
        expandControl.toolTip = String(appLocalized: "展开原文")
        rebuildText()
        measuredWidth = -1
        needsLayout = true
    }

    private func rebuildText() {
        guard let style else { return }
        let text = style.text
        let source = NSMutableAttributedString()
        text.appendSource(row.source, live: row.sourceIsLive, speaker: row.speaker == .remote ? .remote : .me, to: source)
        text.appendUnsent(row.unsentSource, to: source)
        let translation = NSMutableAttributedString()
        let role = row.speaker == .remote ? style.typography.remoteTranslation : style.typography.myTranslation
        text.appendTranslation(row.translation, role: role, isFinal: row.translationIsFinal, fallback: row.fallback,
                               to: translation)
        if let delivery = row.delivery { text.appendDelivery(delivery, role: role, to: translation) }
        sourceText = source
        translationText = translation
        let speakerTitle = Self.speakerTitle(row.speaker, scene: style.scene)
        let spokenSource = ConversationText.accessibilityText(source)
        let spokenTranslation = ConversationText.accessibilityText(translation)
        let label: String = switch row.speaker {
        case .remote where translation.length == 0: String(appLocalized: "\(speakerTitle)正在说：\(spokenSource)")
        case .remote: String(appLocalized: "\(speakerTitle)：\(spokenTranslation)；原文：\(spokenSource)")
        case .me: String(appLocalized: "\(speakerTitle)：\(spokenSource)；译文：\(spokenTranslation)")
        }
        setAccessibilityLabel(label)
    }

    static func speakerTitle(_ speaker: ConversationTimeline.Speaker, scene: SubtitleScene) -> String {
        switch speaker {
        case .me: String(appLocalized: "我")
        case .remote: scene == .phone ? String(appLocalized: "通话对方") : String(appLocalized: "对方")
        }
    }

    private func applyColors() {
        guard let style else { return }
        let display = style.display
        let speakerColor = SubtitleStyle.color(row.speaker == .remote ? .speakerRemote : .voiceTranslate, display: display)
        background.layer?.backgroundColor = row.speaker == .me ? SubtitleStyle.color(.meRow, display: display).cgColor : nil
        hover.layer?.backgroundColor = SubtitleStyle.color(.pairHover, display: display).cgColor
        separator.layer?.backgroundColor = SubtitleStyle.color(.separator, display: display).cgColor
        track.color = speakerColor
        // Not mic.fill for my rows: on this surface mic.fill means 原声 (the dock below).
        let icons = SubtitleTokens.ConversationIcon.self
        let symbol = row.speaker == .me ? icons.me : (style.scene == .phone ? icons.phoneRemote : icons.remote)
        mark.image = SubtitleStyle.symbol(symbol, size: 12, weight: .semibold)
        mark.contentTintColor = speakerColor
        // The row's AX label already names the speaker; the mark stays out of VoiceOver.
        mark.toolTip = Self.speakerTitle(row.speaker, scene: style.scene)
        draftBar.layer?.backgroundColor = SubtitleStyle.color(.voiceTranslate, display: display)
            .withAlphaComponent(ConversationTextRules.draftBarAlpha).cgColor
    }

    /// Draft → final changes colour only; a short fade avoids a hard switch.
    private func fadeNextChange(_ display: SubtitleStyle.Display) {
        let duration = SubtitleStyle.duration(.draftToFinal, display: display)
        guard duration > 0 else { return }
        for view in [translationLabel, draftBar] {
            view.wantsLayer = true
            let transition = CATransition()
            transition.type = .fade
            transition.duration = duration
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            view.layer?.add(transition, forKey: "draftToFinal")
        }
    }

    private func measure(_ text: NSAttributedString, width: CGFloat, with label: NSTextField) -> CGFloat {
        guard text.length > 0, width > 0 else { return 0 }
        label.attributedStringValue = text
        let size = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
        return ceil(size?.height ?? 0)
    }

    /// Height for `width`; also fixes the column frames and the long-source truncation.
    func height(for width: CGFloat) -> CGFloat {
        if abs(width - measuredWidth) < 0.5 { return rowHeight }
        guard let style else { return 0 }
        let columns = ConversationLayout.columns(rowWidth: Double(width), stacked: style.stacked)
        let sourceWidth = CGFloat(columns.sourceWidth), translationWidth = CGFloat(columns.translationWidth)
        let translationHeight = measure(translationText, width: translationWidth, with: translationLabel)
        var shown = sourceText
        var sourceHeight = measure(sourceText, width: sourceWidth, with: sourceLabel)
        tokenFrame = nil
        let line = style.typography.source.size * style.typography.source.lineHeight
        if !expanded, let limit = ConversationLayout.truncatedSourceHeight(
            source: Double(sourceHeight), translation: Double(translationHeight), sourceLine: line) {
            let token = expandToken(style)
            shown = truncated(sourceText, width: sourceWidth, maxHeight: CGFloat(limit), token: token)
            sourceHeight = measure(shown, width: sourceWidth, with: sourceLabel)
            tokenFrame = Self.rect(ofTail: token.length, in: shown, width: sourceWidth)
        }
        sourceLabel.attributedStringValue = shown
        translationLabel.attributedStringValue = translationText
        let top = CGFloat(SubtitleTokens.Size.pairTopPadding)
        if style.stacked {
            translationFrame = NSRect(x: columns.translationX, y: top, width: translationWidth, height: translationHeight)
            let gap: CGFloat = translationHeight > 0 && sourceHeight > 0 ? CGFloat(ConversationLayout.stackedGap) : 0
            sourceFrame = NSRect(x: columns.sourceX, y: top + translationHeight + gap, width: sourceWidth, height: sourceHeight)
        } else {
            sourceFrame = NSRect(x: columns.sourceX, y: top, width: sourceWidth, height: sourceHeight)
            translationFrame = NSRect(x: columns.translationX, y: top, width: translationWidth, height: translationHeight)
        }
        rowHeight = ceil(CGFloat(ConversationLayout.rowHeight(source: Double(sourceHeight),
                                                              translation: Double(translationHeight), stacked: style.stacked)))
        measuredWidth = width
        needsLayout = true
        return rowHeight
    }

    /// "…" plus an inline chevron.down.circle (0.8 × the source size) in voice.translate; the
    /// word 展开原文 is the tooltip and the VoiceOver label of the control over it.
    private func expandToken(_ style: ConversationStyle) -> NSAttributedString {
        var attributes = style.text.attributes(style.typography.source, color: .voiceTranslate)
        attributes[.shadow] = nil
        let token = NSMutableAttributedString(string: ConversationTextRules.draftEllipsis, attributes: attributes)
        let font = SubtitleStyle.font(style.typography.source)
        let color = SubtitleStyle.color(.voiceTranslate, display: style.display)
        guard let symbol = SubtitleStyle.symbol(SubtitleTokens.ConversationIcon.expand,
                                                size: font.pointSize * 0.8, weight: .medium) else { return token }
        let image = SubtitleStyle.tinted(symbol, color)
        let help = String(appLocalized: "展开原文")
        image.accessibilityDescription = help
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: (font.capHeight - image.size.height) / 2,
                                   width: image.size.width, height: image.size.height)
        var chevron = attributes
        chevron[.attachment] = attachment
        chevron[.talkTalkBadgeHelp] = help
        token.append(NSAttributedString(string: "\u{2009}", attributes: attributes))
        token.append(NSAttributedString(string: "\u{FFFC}", attributes: chevron))
        return token
    }

    /// The longest prefix that, followed by the expand token, fits in `maxHeight`.
    private func truncated(_ full: NSAttributedString, width: CGFloat, maxHeight: CGFloat,
                           token: NSAttributedString) -> NSAttributedString {
        let string = full.string as NSString
        let storage = NSTextStorage(attributedString: full)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 2
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var end = 0
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { rect, _, _, glyphs, stop in
            guard rect.maxY <= maxHeight + 0.5 else { stop.pointee = true; return }
            end = NSMaxRange(manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
        }
        var cut = min(end, string.length)
        for _ in 0..<80 where cut > 0 {
            let head = NSMutableAttributedString(attributedString: full.attributedSubstring(from: NSRange(location: 0, length: cut)))
            while let last = head.string.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
                head.deleteCharacters(in: NSRange(location: head.length - 1, length: 1))
            }
            head.append(token)
            if measure(head, width: width, with: sourceLabel) <= maxHeight + 0.5 { return head }
            cut = string.rangeOfComposedCharacterSequence(at: cut - 1).location
        }
        return token
    }

    /// Bounding rect of the last `length` characters, in the label's coordinates.
    private static func rect(ofTail length: Int, in text: NSAttributedString, width: CGFloat) -> NSRect? {
        guard length > 0, text.length >= length else { return nil }
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 2
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: text.length - length, length: length),
                                        actualCharacterRange: nil)
        return manager.boundingRect(forGlyphRange: glyphs, in: container)
    }

    /// Tooltips of the inline badges in both columns ("备用翻译" → "云端不可用，本句由 Apple 翻译",
    /// "未发送" and the delivery labels → their explanation).
    private func addBadgeToolTips() {
        removeAllToolTips()
        badgeToolTipOwners = ConversationText.addBadgeToolTips(for: sourceLabel, frame: sourceFrame, to: self)
            + ConversationText.addBadgeToolTips(for: translationLabel, frame: translationFrame, to: self)
    }

    override func layout() {
        super.layout()
        guard let style else { return }
        let height = bounds.height, width = bounds.width
        let display = style.display
        background.frame = bounds
        hover.frame = bounds
        let separatorWidth = CGFloat(SubtitleTokens.separatorWidth(increaseContrast: display.increaseContrast))
        let track = CGFloat(SubtitleTokens.Size.speakerTrackWidth)
        separator.isHidden = !showsSeparator
        separator.frame = NSRect(x: track, y: 0, width: max(0, width - track), height: separatorWidth)
        // Bars of one speaker's consecutive rows join; only a segment's ends are rounded.
        let top = CGFloat(SubtitleTokens.Size.pairTopPadding), bottom = CGFloat(SubtitleTokens.Size.pairBottomPadding)
        let barTop = segmentStart ? top : 0
        let barBottom = segmentEnd ? height - bottom : height
        self.track.roundTop = segmentStart
        self.track.roundBottom = segmentEnd
        self.track.frame = NSRect(x: 0, y: barTop, width: CGFloat(SubtitleTokens.trackWidth(increaseContrast: display.increaseContrast)),
                                  height: max(0, barBottom - barTop))
        mark.isHidden = !segmentStart
        mark.frame = NSRect(x: 5, y: top + 2, width: 16, height: 16)
        sourceLabel.frame = sourceFrame
        translationLabel.frame = translationFrame
        let draft = !row.translationIsFinal && !row.translation.isEmpty
        draftBar.isHidden = !draft
        if draft {
            let x = translationFrame.minX - (style.stacked ? 3 : 8)
            draftBar.frame = NSRect(x: x, y: translationFrame.minY + 2, width: CGFloat(ConversationTextRules.draftBarWidth),
                                    height: max(0, translationFrame.height - 4))
        }
        if let tokenFrame {
            expandControl.isHidden = false
            expandControl.frame = tokenFrame.offsetBy(dx: sourceFrame.minX, dy: sourceFrame.minY).insetBy(dx: -4, dy: -2)
        } else {
            expandControl.isHidden = true
        }
        addBadgeToolTips()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hover.isHidden = false }
    override func mouseExited(with event: NSEvent) { hover.isHidden = true }
    func clearHover() { hover.isHidden = true }
}

/// Speaker track bar: 3 pt (4 pt with Increase Contrast), radius 1.5 at a segment's ends.
final class TrackBarView: NSView {
    var color: NSColor = .white { didSet { needsDisplay = true } }
    var roundTop = true { didSet { if oldValue != roundTop { needsDisplay = true } } }
    var roundBottom = true { didSet { if oldValue != roundBottom { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.height > 0 else { return }
        color.setFill()
        let radius: CGFloat = 1.5
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        if !roundTop { NSRect(x: 0, y: 0, width: bounds.width, height: min(radius, bounds.height)).fill() }
        if !roundBottom {
            NSRect(x: 0, y: max(0, bounds.height - radius), width: bounds.width, height: min(radius, bounds.height)).fill()
        }
    }
}

/// The transparent hit area over "…展开".
@MainActor
final class InlineLinkControl: TitlebarControl {}

/// "[arrow.down] N 条新字幕" (§4): 24 pt, radius 12, hudWindow, 1 pt white 18% outline, 12 pt
/// medium; an 11 pt semibold arrow.down 4 pt before the count, centred as one group.
@MainActor
final class JumpToLatestPill: TitlebarControl {
    private let material = NSVisualEffectView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private static let iconGap: CGFloat = 4

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        material.material = .hudWindow
        material.blendingMode = .withinWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = CGFloat(SubtitleTokens.Size.jumpToLatestHeight) / 2
        material.layer?.masksToBounds = true
        material.setAccessibilityElement(false)
        addSubview(material)
        icon.image = SubtitleStyle.symbol(SubtitleTokens.ConversationIcon.jumpToLatest, size: 11, weight: .semibold)
        icon.imageScaling = .scaleNone
        icon.contentTintColor = SubtitleStyle.white(0.92)
        icon.setAccessibilityElement(false)
        addSubview(icon)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = SubtitleStyle.white(0.92)
        label.alignment = .center
        label.setAccessibilityElement(false)
        addSubview(label)
        layer?.cornerRadius = CGFloat(SubtitleTokens.Size.jumpToLatestHeight) / 2
        layer?.borderWidth = 1
        layer?.borderColor = SubtitleStyle.white(0.18).cgColor
        setAccessibilityRole(.button)
        toolTip = String(appLocalized: "回到最新字幕")
    }

    required init?(coder: NSCoder) { nil }

    func setCount(_ count: Int) {
        toolTip = String(appLocalized: "回到最新字幕")
        let title = String(appLocalized: "\(count) 条新字幕")
        guard label.stringValue != title else { return }
        label.stringValue = title
        setAccessibilityLabel(String(appLocalized: "\(count) 条新字幕，回到最新"))
        superview?.needsLayout = true
    }

    private var iconWidth: CGFloat { ceil(icon.image?.size.width ?? 0) }
    private var labelWidth: CGFloat { ceil(label.intrinsicContentSize.width) }

    var preferredWidth: CGFloat { iconWidth + Self.iconGap + labelWidth + 24 }

    override func layout() {
        super.layout()
        material.frame = bounds
        let height = ceil(label.intrinsicContentSize.height)
        let iconHeight = ceil(icon.image?.size.height ?? 0)
        let x = ((bounds.width - (iconWidth + Self.iconGap + labelWidth)) / 2).rounded()
        icon.frame = NSRect(x: x, y: ((bounds.height - iconHeight) / 2).rounded(), width: iconWidth, height: iconHeight)
        label.frame = NSRect(x: x + iconWidth + Self.iconGap, y: (bounds.height - height) / 2,
                             width: labelWidth + SubtitleStyle.labelSlack, height: height)
    }

    override func hoverChanged() {
        layer?.backgroundColor = isHovered ? SubtitleStyle.white(0.08).cgColor : nil
    }
}

/// Empty state (§4, §5): 13 pt white 45%, centred, after an inline 13 pt symbol (ear while
/// listening, info.circle when the meeting is silent, phone on Phone). The silent one opens
/// details.
@MainActor
final class TimelinePlaceholder: TitlebarControl {
    struct Content: Equatable {
        var primary: String
        var secondary: String?
        var clickable: Bool
        /// Leading SF Symbol of the primary line, in the text colour, 4 pt before it.
        var symbol: String?
        var help: String?
        /// VoiceOver label; defaults to the text.
        var accessibilityLabel: String?
    }

    private let primary = NSTextField(wrappingLabelWithString: "")
    private let secondary = NSTextField(wrappingLabelWithString: "")
    private var content = Content(primary: "", secondary: nil, clickable: false)
    private var clickable = false
    private static let font = NSFont.systemFont(ofSize: ControlTypography.placeholder)

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        for label in [primary, secondary] {
            label.font = Self.font
            label.textColor = SubtitleStyle.white(0.45)
            label.alignment = .center
            label.isSelectable = false
            label.setAccessibilityElement(false)
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ next: Content) {
        content = next
        secondary.stringValue = next.secondary ?? ""
        secondary.isHidden = next.secondary == nil
        clickable = next.clickable
        toolTip = next.help
        setAccessibilityRole(next.clickable ? .button : .staticText)
        let text = next.secondary.map { String(appLocalized: "\(next.primary)；\($0)") } ?? next.primary
        setAccessibilityLabel(next.accessibilityLabel ?? text)
        hoverChanged()
        needsLayout = true
    }

    /// The primary line with its leading symbol, both in white `alpha`.
    private func primaryText(alpha: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let color = SubtitleStyle.white(alpha)
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color, .paragraphStyle: paragraph]
        let result = NSMutableAttributedString()
        if !content.primary.isEmpty, let name = content.symbol,
           let symbol = SubtitleStyle.symbol(name, size: Self.font.pointSize, weight: .regular) {
            let gap: CGFloat = 4
            let tinted = SubtitleStyle.tinted(symbol, color)
            let image = NSImage(size: NSSize(width: tinted.size.width + gap, height: tinted.size.height), flipped: false) { _ in
                tinted.draw(in: NSRect(origin: .zero, size: tinted.size))
                return true
            }
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: (Self.font.capHeight - image.size.height) / 2,
                                       width: image.size.width, height: image.size.height)
            var symbolAttributes = attributes
            symbolAttributes[.attachment] = attachment
            result.append(NSAttributedString(string: "\u{FFFC}", attributes: symbolAttributes))
        }
        result.append(NSAttributedString(string: content.primary, attributes: attributes))
        return result
    }

    private func secondaryText() -> NSAttributedString {
        NSAttributedString(string: secondary.stringValue, attributes: [.font: Self.font])
    }

    private static func size(_ text: NSAttributedString, maxWidth: CGFloat) -> NSSize {
        guard text.length > 0 else { return .zero }
        let bounds = text.boundingRect(with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading])
        return NSSize(width: ceil(bounds.width) + 8, height: ceil(bounds.height) + 4)
    }

    func fittingSize(maxWidth: CGFloat) -> NSSize {
        let first = content.primary.isEmpty ? .zero : Self.size(primaryText(alpha: 0.45), maxWidth: maxWidth)
        let second = secondary.isHidden ? .zero : Self.size(secondaryText(), maxWidth: maxWidth)
        return NSSize(width: min(maxWidth, max(first.width, second.width)),
                      height: first.height + (second.height > 0 ? second.height + 4 : 0))
    }

    override func layout() {
        super.layout()
        let width = max(1, bounds.width - 8)
        let first = content.primary.isEmpty ? 0 : Self.size(primaryText(alpha: 0.45), maxWidth: width).height
        primary.frame = NSRect(x: 0, y: 0, width: bounds.width, height: first)
        secondary.frame = NSRect(x: 0, y: first + 4, width: bounds.width, height: max(0, bounds.height - first - 4))
    }

    /// A plain empty state is window background: it drags the window like the rest.
    override func hitTest(_ point: NSPoint) -> NSView? { clickable ? super.hitTest(point) : nil }

    override func cursorUpdate(with event: NSEvent) {
        (clickable ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func hoverChanged() {
        let alpha: CGFloat = clickable && isHovered ? 0.7 : 0.45
        primary.attributedStringValue = primaryText(alpha: alpha)
    }
}
