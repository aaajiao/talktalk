// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit

/// Two fixed caption tracks for one sentence. Drafts and finals share the same translation
/// slot; long text advances by complete laid-out lines, never by scrolling to its tail.
@MainActor
final class VideoSubtitleView: NSView {
    private struct Page {
        var range: NSRange
        var text: NSAttributedString
    }

    private let sourceView = VideoCaptionTextView()
    private let translationView = VideoCaptionTextView()
    private var source = NSAttributedString(string: "")
    private var translation = NSAttributedString(string: "")
    private var sourcePages: [Page] = []
    private var translationPages: [Page] = []
    private var sourcePageIndex = 0
    private var translationPageIndex = 0
    private var hasCaption = false
    private var layoutReady = false
    private var resetPage = true
    private var lastTime = 0.0
    private var pageReadyAt = 0.0
    private var lastSourceSize = NSSize.zero
    private var lastTranslationSize = NSSize.zero
    private var textNeedsLayout = true
    private var sourceCorrectionAnchor: Int?
    private var translationCorrectionAnchor: Int?

    private(set) var displayedSentence: UInt64?
    private(set) var isDisplayingFinal = false
    private(set) var displayedSource = ""
    private(set) var displayedTranslation = ""
    private(set) var currentPageIndex = 0
    private(set) var pageCount = 0
    var onDisplayedTextChange: (() -> Void)?

    private static let trackGap: CGFloat = 8
    private static let verticalInset: CGFloat = 2
    private static let horizontalInset: CGFloat = 4

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        addSubview(sourceView)
        addSubview(translationView)
        sourceView.setAccessibilityLabel(String(localized: "原文"))
        translationView.setAccessibilityLabel(String(localized: "译文"))
    }

    required init?(coder: NSCoder) { return nil }

    /// One complete source line and two complete translated lines, plus the fixed padding.
    /// The panel uses the same metrics for its minimum size, independent of incoming text.
    static func minimumReadingHeight(sourceFont: NSFont, translationFont: NSFont) -> CGFloat {
        lineHeight(sourceFont) + 2 * lineHeight(translationFont) + trackGap + 4 * verticalInset
    }

    func setCaption(source: NSAttributedString, translation: NSAttributedString,
                    sentence: UInt64?, isFinal: Bool, at now: Double) {
        lastTime = now
        let newSentence = !hasCaption || displayedSentence != sentence
        let changed = !self.source.isEqual(to: source) || !self.translation.isEqual(to: translation)
        let metadataChanged = displayedSentence != sentence || isDisplayingFinal != isFinal
        if newSentence {
            sourceCorrectionAnchor = nil; translationCorrectionAnchor = nil
        } else {
            // A draft can revise an already-read page before an identical final arrives.
            // Remember that unseen correction, but wait for finalization before rewinding.
            let sourceAnchor = page(in: sourcePages, at: sourcePageIndex)?.range.location ?? 0
            let targetAnchor = page(in: translationPages, at: translationPageIndex)?.range.location ?? 0
            if let change = Self.revisedOffset(source.string, replacing: self.source.string), change < sourceAnchor {
                sourceCorrectionAnchor = min(sourceCorrectionAnchor ?? sourceAnchor, change)
            }
            if let change = Self.revisedOffset(translation.string, replacing: self.translation.string), change < targetAnchor {
                translationCorrectionAnchor = min(translationCorrectionAnchor ?? targetAnchor, change)
            }
        }
        hasCaption = source.length > 0 || translation.length > 0
        displayedSentence = sentence
        isDisplayingFinal = isFinal
        guard changed || newSentence || metadataChanged else { return }
        self.source = NSAttributedString(attributedString: source)
        self.translation = NSAttributedString(attributedString: translation)
        resetPage = resetPage || newSentence
        textNeedsLayout = true
        needsLayout = true
        layoutSubtreeIfNeeded()
        if metadataChanged, !changed { onDisplayedTextChange?() }
    }

    /// Called by the panel's existing clock; this view creates no timer or animation.
    @discardableResult
    func advance(at now: Double) -> Bool {
        lastTime = now
        let hasSourcePage = sourcePageIndex + 1 < sourcePages.count
        let hasTranslationPage = translationPageIndex + 1 < translationPages.count
        guard layoutReady, hasSourcePage || hasTranslationPage, now >= pageReadyAt else { return false }
        if hasSourcePage { sourcePageIndex += 1 }
        if hasTranslationPage { translationPageIndex += 1 }
        currentPageIndex = max(sourcePageIndex, translationPageIndex)
        showPage(at: now, newPage: true)
        return true
    }

    func canAdvance(at now: Double) -> Bool {
        !hasCaption || (layoutReady && sourcePageIndex + 1 >= sourcePages.count
                       && translationPageIndex + 1 >= translationPages.count && now >= pageReadyAt)
    }

    /// Hidden time is not reading time. An explicit restore gives the currently visible page
    /// a fresh budget without changing its text, page positions or sentence identity.
    func resetReadingTime(at now: Double) {
        lastTime = now
        pageReadyAt = now + (hasCaption && layoutReady
            ? Self.readingTime(source: displayedSource.count, translation: displayedTranslation.count) : 0)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let sourceFont = Self.font(in: source, fallback: 17)
        let translationFont = Self.font(in: translation, fallback: 22)
        let sourceLine = Self.lineHeight(sourceFont)
        let targetLine = Self.lineHeight(translationFont)
        let usableHeight = max(0, bounds.height - Self.trackGap)
        let sourceMinimum = sourceLine + 2 * Self.verticalInset
        let targetMinimum = 2 * targetLine + 2 * Self.verticalInset
        let sourceWanted = max(sourceMinimum, min(usableHeight / 3, usableHeight - targetMinimum))
        let sourceLines = max(1, floor((sourceWanted - 2 * Self.verticalInset) / sourceLine))
        let sourceHeight = min(usableHeight, sourceLines * sourceLine + 2 * Self.verticalInset)
        let targetHeight = max(0, usableHeight - sourceHeight)
        let sourceTextHeight = max(0, floor((sourceHeight - 2 * Self.verticalInset) / sourceLine) * sourceLine)
        let targetTextHeight = max(0, floor((targetHeight - 2 * Self.verticalInset) / targetLine) * targetLine)
        let width = max(0, bounds.width - 2 * Self.horizontalInset)
        sourceView.frame = NSRect(x: Self.horizontalInset, y: Self.verticalInset,
                                  width: width, height: sourceTextHeight)
        translationView.frame = NSRect(x: Self.horizontalInset,
                                       y: sourceHeight + Self.trackGap + Self.verticalInset,
                                       width: width, height: targetTextHeight)
        let sourceSize = sourceView.bounds.size, targetSize = translationView.bounds.size
        guard textNeedsLayout || sourceSize != lastSourceSize || targetSize != lastTranslationSize else { return }
        let previousSourceAnchor = page(in: sourcePages, at: sourcePageIndex)?.range.location ?? 0
        let previousTargetAnchor = page(in: translationPages, at: translationPageIndex)?.range.location ?? 0
        let sourceAnchor = isDisplayingFinal ? min(previousSourceAnchor, sourceCorrectionAnchor ?? previousSourceAnchor) : previousSourceAnchor
        let targetAnchor = isDisplayingFinal ? min(previousTargetAnchor, translationCorrectionAnchor ?? previousTargetAnchor) : previousTargetAnchor
        sourcePages = Self.pages(for: source, in: sourceSize)
        translationPages = Self.pages(for: translation, in: targetSize)
        pageCount = max(sourcePages.count, translationPages.count)
        layoutReady = (!hasCaption || pageCount > 0)
            && (source.length == 0 || !sourcePages.isEmpty)
            && (translation.length == 0 || !translationPages.isEmpty)
        if resetPage {
            sourcePageIndex = 0; translationPageIndex = 0
        } else {
            // Each language owns its reading position. If a short translation grows while
            // its source is already on page five, new translation pages must start after its
            // own old page, not jump directly to the source's later page number.
            sourcePageIndex = Self.pageIndex(containing: sourceAnchor, in: sourcePages)
            translationPageIndex = Self.pageIndex(containing: targetAnchor, in: translationPages)
        }
        currentPageIndex = max(sourcePageIndex, translationPageIndex)
        lastSourceSize = sourceSize; lastTranslationSize = targetSize
        textNeedsLayout = false
        let startsNewPage = resetPage
        resetPage = false
        showPage(at: lastTime, newPage: startsNewPage, newSentence: startsNewPage)
    }

    private func page(in pages: [Page], at index: Int) -> Page? {
        guard !pages.isEmpty else { return nil }
        // Keep the last page of the shorter language visible while the longer one finishes.
        return pages[min(index, pages.count - 1)]
    }

    private func showPage(at now: Double, newPage: Bool, newSentence: Bool = false) {
        let sourcePage = layoutReady ? page(in: sourcePages, at: sourcePageIndex)?.text : nil
        let targetPage = layoutReady ? page(in: translationPages, at: translationPageIndex)?.text : nil
        let newSource = sourcePage?.string ?? "", newTarget = targetPage?.string ?? ""
        let changedSource = Self.changedCharacters(newSource, replacing: displayedSource)
        let changedTarget = Self.changedCharacters(newTarget, replacing: displayedTranslation)
        let pageSourceCharacters = newSentence || newSource != displayedSource ? newSource.count : 0
        let pageTargetCharacters = newSentence || newTarget != displayedTranslation ? newTarget.count : 0
        let textChanged = newSource != displayedSource || newTarget != displayedTranslation
        displayedSource = newSource; displayedTranslation = newTarget
        sourceView.setCaption(sourcePage ?? NSAttributedString(string: ""))
        translationView.setCaption(targetPage ?? NSAttributedString(string: ""))
        if layoutReady {
            if correctionIsVisible(sourceCorrectionAnchor, in: page(in: sourcePages, at: sourcePageIndex), length: source.length) {
                sourceCorrectionAnchor = nil
            }
            if correctionIsVisible(translationCorrectionAnchor, in: page(in: translationPages, at: translationPageIndex), length: translation.length) {
                translationCorrectionAnchor = nil
            }
        }
        if newPage {
            // A shorter language may hold its last page while the other advances. That text
            // has already been read and must not consume another page's reading budget.
            pageReadyAt = now + Self.readingTime(source: pageSourceCharacters, translation: pageTargetCharacters)
        } else if changedSource > 0 || changedTarget > 0 {
            // A same-sentence final or partial does not charge the already visible prefix
            // again, and a color/font-only update never restarts its reading clock.
            pageReadyAt = max(pageReadyAt, now + Self.readingTime(source: changedSource, translation: changedTarget))
        }
        if textChanged || newPage { onDisplayedTextChange?() }
    }

    private func correctionIsVisible(_ offset: Int?, in page: Page?, length: Int) -> Bool {
        guard let offset else { return false }
        if length == 0 { return true }
        guard let page, page.range.location <= offset else { return false }
        return offset < NSMaxRange(page.range) || (offset == length && NSMaxRange(page.range) == length)
    }

    private static func readingTime(source: Int, translation: Int) -> Double {
        min(6, max(1, max(Double(source) / 18, Double(translation) / 9)))
    }

    private static func changedCharacters(_ text: String, replacing old: String) -> Int {
        max(0, text.count - zip(text, old).prefix(while: { $0 == $1 }).count)
    }

    /// UTF-16 offsets match TextKit's ranges. Identical and append-only text do not invalidate
    /// earlier reading; a finalized correction to an earlier word/number must be shown again.
    private static func revisedOffset(_ text: String, replacing old: String) -> Int? {
        let prefix = zip(text.utf16, old.utf16).prefix(while: { $0 == $1 }).count
        guard prefix < old.utf16.count else { return nil }
        let nsText = text as NSString
        guard prefix < nsText.length else { return prefix }
        return nsText.rangeOfComposedCharacterSequence(at: prefix).location
    }

    private static func font(in text: NSAttributedString, fallback size: CGFloat) -> NSFont {
        guard text.length > 0 else { return .systemFont(ofSize: size) }
        return text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: size)
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: font))
    }

    private static func pageIndex(containing anchor: Int, in pages: [Page]) -> Int {
        pages.firstIndex { anchor < NSMaxRange($0.range) } ?? max(0, pages.count - 1)
    }

    private static func pages(for text: NSAttributedString, in size: NSSize) -> [Page] {
        guard text.length > 0, size.width > 0, size.height > 0 else { return [] }
        var result: [Page] = []
        var offset = 0
        while offset < text.length {
            let remaining = text.attributedSubstring(from: NSRange(location: offset, length: text.length - offset))
            let storage = NSTextStorage(attributedString: remaining)
            let manager = NSLayoutManager()
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            container.lineBreakMode = .byWordWrapping
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
            let glyphs = manager.glyphRange(for: container)
            var completeEnd = 0
            manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, range, stop in
                guard rect.maxY <= size.height + 0.5 else { stop.pointee = true; return }
                completeEnd = NSMaxRange(range)
            }
            // An undersized viewport must not silently drop the remaining text or claim its
            // final page is ready. The panel raises its minimum size from the same metrics.
            guard completeEnd > 0 else { return [] }
            let chars = manager.characterRange(forGlyphRange: NSRange(location: 0, length: completeEnd), actualGlyphRange: nil)
            let length = min(remaining.length, NSMaxRange(chars))
            guard length > 0 else { return [] }
            let range = NSRange(location: offset, length: length)
            result.append(Page(range: range, text: text.attributedSubstring(from: range)))
            offset += length
        }
        return result
    }
}

@MainActor
private final class VideoCaptionTextView: NSTextView {
    private let captionStorage: NSTextStorage
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    init() {
        // Supply the same TextKit 1 stack used for pagination. A nil container can opt into
        // TextKit 2 on newer systems, whose metrics and layout-manager access differ.
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: .zero)
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        captionStorage = storage
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = false
        drawsBackground = false
        isRichText = true
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        textContainer?.heightTracksTextView = true
    }

    required init?(coder: NSCoder) { return nil }

    func setCaption(_ value: NSAttributedString) {
        guard textStorage?.isEqual(to: value) != true else { return }
        textStorage?.setAttributedString(value)
    }
}
