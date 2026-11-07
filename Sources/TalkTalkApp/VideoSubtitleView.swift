// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import QuartzCore
import TalkTalkCore
import TalkTalkSession
import TalkTalkSettingsUI

/// Two fixed caption blocks for one sentence (redesign §6). Drafts and finals share the same
/// translation slot; long text advances by complete pages of at most two lines, never by
/// scrolling to its tail. Block widths come from the font size, not the window; the pair is
/// anchored to the bottom so a single line sinks instead of floating.
@MainActor
final class VideoSubtitleView: NSView {
    /// Caption presentation chosen by the panel. `style` is already resolved for Reduce
    /// Transparency; `opacity` is the scene opacity after Increase Contrast.
    struct Appearance: Equatable {
        var style: VideoCaptionStyle = .default
        var arrangement: VideoCaptionArrangement = .default
        var opacity: CGFloat = 0.85
        var reduceTransparency = false
        var reduceMotion = false
        /// Strengthens the meta alphas: page dots, "›", "已跳过 N 句", the placeholder (§2).
        var increaseContrast = false
    }

    private struct Page {
        /// UTF-16 range in the whole text, matching TextKit's ranges.
        var range: NSRange
        /// The page's characters as laid out, for reading time and analysis.
        var text: NSAttributedString
        /// Line ranges (UTF-16) that the view joins with explicit line breaks.
        var lines: [NSRange]
    }

    private let captionLayer = CaptionContainerView()
    private let glass = NSVisualEffectView()
    private let sourceView = VideoCaptionTextView()
    private let translationView = VideoCaptionTextView()
    private let dots = PageDotsView()
    private let noticeView = VideoCaptionTextView()
    private var source = NSAttributedString(string: "")
    private var translation = NSAttributedString(string: "")
    private var fallback = false
    private(set) var sourceLanguage: Lang = .en
    private(set) var targetLanguage: Lang = .zh
    /// Glass, or the text blocks plus the glass padding: the only area that drags the window.
    private(set) var textBlockRect = NSRect.null
    /// Reserved even while controls are hidden, so a two-line page never collides with them.
    var reservedChromeHeight: CGFloat = 0 {
        didSet { if reservedChromeHeight != oldValue { needsLayout = true } }
    }
    var onReadingBoundsChange: (() -> Void)?

    func controlBarFrame(height: CGFloat) -> NSRect {
        let width = CGFloat(VideoCaptionLayout.readingWidth(windowWidth: Double(bounds.width),
            translationSize: Double(translationFont.pointSize), sourceSize: Double(sourceFont.pointSize),
            sourceLanguage: sourceLanguage, targetLanguage: targetLanguage))
        let top = textBlockRect.isNull ? 0
            : CGFloat(VideoCaptionLayout.controlBarTop(readingTop: Double(textBlockRect.minY), height: Double(height)))
        return NSRect(x: (bounds.width - width) / 2, y: top, width: width, height: height)
    }
    /// Long-silence dimming (§1): text 35%, glass or plates at most 40%.
    private(set) var quietDimmed = false
    private var sourcePages: [Page] = []
    private var translationPages: [Page] = []
    private var sourcePageIndex = 0
    private var translationPageIndex = 0
    private(set) var hasCaption = false
    private var layoutReady = false
    private var resetPage = true
    private var lastTime = 0.0
    private var pageShownAt = 0.0
    private var pageReadyAt = 0.0
    private var lastLayoutKey: LayoutKey?
    private var textNeedsLayout = true
    private var sourceCorrectionAnchor: Int?
    private var translationCorrectionAnchor: Int?
    private var skippedNotice: (text: String, until: Double)?
    private var visualGeneration = 0
    /// Fading out the old page; the new one is placed when it completes.
    private var fadeInFlight = false
    /// Blank frame and fade-in of the new page.
    private var fadingIn = false
    private var finalizing = false
    private var advanceCache: [String: CGFloat] = [:]
    private var baselineCache: [String: CGFloat] = [:]

    private(set) var displayedSentence: UInt64?
    private(set) var isDisplayingFinal = false
    private(set) var displayedSource = ""
    private(set) var displayedTranslation = ""
    private(set) var currentPageIndex = 0
    private(set) var pageCount = 0
    var onDisplayedTextChange: (() -> Void)?

    var appearanceSettings = Appearance() {
        didSet {
            guard appearanceSettings != oldValue else { return }
            textNeedsLayout = true
            needsLayout = true
        }
    }
    /// Pending cues exist: each page waits 0.7 of its reading time (at least 1 s).
    var catchingUp = false
    /// Empty state shown at the source position, e.g. "正在听 Google Chrome…".
    var placeholder: String? {
        didSet { if placeholder != oldValue, !hasCaption { applyVisual() } }
    }

    private struct LayoutKey: Equatable {
        var translationWidth: CGFloat, sourceWidth: CGFloat, sourceLines: Int
        var appearance: Appearance
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    // Only the text blocks drag the window (§6 鼠标穿透). Transparent areas are set explicitly:
    // they take the click but neither drag nor act.
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        let local = convert(point, from: superview)
        guard !textBlockRect.isNull, textBlockRect.contains(local) else { return nil }
        return captionLayer
    }

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(captionLayer)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = SubtitleTokens.Radius.videoGlass
        glass.layer?.masksToBounds = true
        glass.isHidden = true
        captionLayer.addSubview(glass)
        for view in [sourceView, translationView, noticeView] {
            // Plates draw in a sibling below the text, so dimming can fade them separately.
            captionLayer.addSubview(view.backdrop)
            captionLayer.addSubview(view)
        }
        captionLayer.addSubview(dots)
        noticeView.isHidden = true
        dots.isHidden = true
        sourceView.setAccessibilityLabel(String(localized: "原文"))
        translationView.setAccessibilityLabel(String(localized: "译文"))
    }

    required init?(coder: NSCoder) { return nil }

    /// The live window blurs what lies behind it; the settings preview blurs its in-window
    /// backdrop instead.
    var glassBlendingMode: NSVisualEffectView.BlendingMode {
        get { glass.blendingMode }
        set { glass.blendingMode = newValue }
    }

    // MARK: caption text (shared by the live window and the settings preview)

    /// Source text in the video.source token. Stroke, shadow, paragraph and line breaks
    /// belong to this view's style.
    static func sourceText(_ text: String, font: NSFont, display: SubtitleStyle.Display) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: SubtitleStyle.color(.videoSource, display: display),
        ])
    }

    /// Finals are white 100%. A draft keeps the first `stablePrefix` characters (shared with
    /// its previous version) at full white; only the changed tail is 65% and ends with "…"
    /// (§6 视觉反馈). `text` is the final's display text, or the draft's raw text.
    static func translationText(_ text: String, isFinal: Bool, stablePrefix: Int, font: NSFont) -> NSAttributedString {
        guard !text.isEmpty else { return NSAttributedString(string: "") }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        guard !isFinal else { return NSAttributedString(string: text, attributes: attributes) }
        let shown = ConversationTextRules.draftDisplay(text)
        let split = shown.index(shown.startIndex, offsetBy: min(max(0, stablePrefix), shown.count))
        var tail = attributes
        tail[.foregroundColor] = SubtitleStyle.white(CGFloat(VideoCaptionLayout.draftTailAlpha))
        let result = NSMutableAttributedString(string: String(shown[..<split]), attributes: attributes)
        result.append(NSAttributedString(string: String(shown[split...]), attributes: tail))
        return result
    }

    /// VoiceOver names the two blocks with their languages, e.g. "原文 · 英语" (§6 无障碍).
    func setAccessibilityTitles(source: String, translation: String) {
        sourceView.setAccessibilityLabel(source)
        translationView.setAccessibilityLabel(translation)
    }

    // MARK: metrics

    static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.pointSize * 1.30) }

    /// Two translation lines, one source line and 24 pt (§6 窗口).
    static func minimumReadingHeight(sourceFont: NSFont, translationFont: NSFont) -> CGFloat {
        CGFloat(VideoCaptionLayout.minimumContentHeight(translationLineHeight: Double(lineHeight(translationFont)),
                                                        sourceLineHeight: Double(lineHeight(sourceFont))))
    }

    // MARK: input

    /// A direction change gives both sides their own script metrics and starts a fresh page.
    /// The panel clears the old caption board before installing the new session direction.
    func setLanguages(source: Lang, target: Lang) {
        guard source != sourceLanguage || target != targetLanguage else { return }
        sourceLanguage = source; targetLanguage = target
        sourceCorrectionAnchor = nil; translationCorrectionAnchor = nil
        resetPage = true; textNeedsLayout = true; needsLayout = true
    }

    func setCaption(source: NSAttributedString, translation: NSAttributedString,
                    sentence: UInt64?, isFinal: Bool, fallback: Bool = false, at now: Double) {
        lastTime = now
        let newSentence = !hasCaption || displayedSentence != sentence
        let changed = !self.source.isEqual(to: source) || !self.translation.isEqual(to: translation)
            || self.fallback != fallback
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
        finalizing = !newSentence && !isDisplayingFinal && isFinal
        hasCaption = source.length > 0 || translation.length > 0
        displayedSentence = sentence
        isDisplayingFinal = isFinal
        guard changed || newSentence || metadataChanged else { finalizing = false; return }
        self.source = NSAttributedString(attributedString: source)
        self.translation = NSAttributedString(attributedString: translation)
        self.fallback = fallback
        resetPage = resetPage || newSentence
        textNeedsLayout = true
        needsLayout = true
        layoutSubtreeIfNeeded()
        finalizing = false
        if metadataChanged, !changed { onDisplayedTextChange?() }
    }

    static func skippedText(count: Int) -> String { String(localized: "已跳过 \(count) 句") }

    /// "已跳过 N 句" at the source position for 1.5 s (§6 视觉反馈).
    func showSkipped(count: Int, at now: Double) {
        guard count > 0 else { return }
        skippedNotice = (Self.skippedText(count: count), now + VideoCaptionLayout.skippedNoticeSeconds)
        applyVisual()
    }

    /// Called by the panel's existing clock; this view creates no timer.
    @discardableResult
    func advance(at now: Double) -> Bool {
        lastTime = now
        if let notice = skippedNotice, now >= notice.until {
            skippedNotice = nil
            applyVisual()
        }
        let hasSourcePage = sourcePageIndex + 1 < sourcePages.count
        let hasTranslationPage = translationPageIndex + 1 < translationPages.count
        guard layoutReady, hasSourcePage || hasTranslationPage, now >= readyTime else { return false }
        if hasSourcePage { sourcePageIndex += 1 }
        if hasTranslationPage { translationPageIndex += 1 }
        currentPageIndex = max(sourcePageIndex, translationPageIndex)
        showPage(at: now, newPage: true)
        return true
    }

    /// The caption's last page has used up its reading time (long-silence dimming).
    func hasReadLastPage(at now: Double) -> Bool { hasCaption && canAdvance(at: now) }

    /// Dims over 300 ms (instant with Reduce Motion); restoring is always instant.
    func setQuietDimmed(_ on: Bool) {
        guard on != quietDimmed else { return }
        quietDimmed = on
        applyDim(duration: VideoQuietDim.transition(dimming: on, reduceMotion: appearanceSettings.reduceMotion))
    }

    private var plateBaseAlpha: CGFloat {
        CGFloat(VideoCaptionStyle.plateAlpha(reduceTransparency: appearanceSettings.reduceTransparency))
    }

    private var glassAlpha: CGFloat {
        CGFloat(VideoQuietDim.backgroundAlpha(normal: Double(appearanceSettings.opacity), dimmed: quietDimmed))
    }

    /// The plate views draw at the plate alpha; this factor brings them to at most 40%.
    private var plateDimFactor: CGFloat {
        let base = plateBaseAlpha
        guard base > 0 else { return 1 }
        return CGFloat(VideoQuietDim.backgroundAlpha(normal: Double(base), dimmed: quietDimmed)) / base
    }

    private func applyDim(duration: TimeInterval) {
        let text = CGFloat(VideoQuietDim.textAlpha(dimmed: quietDimmed))
        let plate = plateDimFactor, glassValue = glassAlpha
        let textViews: [NSView] = [sourceView, translationView, noticeView, dots]
        let plates: [NSView] = [sourceView.backdrop, translationView.backdrop, noticeView.backdrop]
        guard duration > 0, window != nil else {
            textViews.forEach { $0.alphaValue = text }
            plates.forEach { $0.alphaValue = plate }
            glass.alphaValue = glassValue
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            textViews.forEach { $0.animator().alphaValue = text }
            plates.forEach { $0.animator().alphaValue = plate }
            glass.animator().alphaValue = glassValue
        }
    }

    func canAdvance(at now: Double) -> Bool {
        !hasCaption || (layoutReady && sourcePageIndex + 1 >= sourcePages.count
                       && translationPageIndex + 1 >= translationPages.count && now >= readyTime)
    }

    /// The page budget, shortened while pending cues wait.
    private var readyTime: Double {
        pageShownAt + VideoCaptionPacing.effectiveDuration(max(0, pageReadyAt - pageShownAt), catchingUp: catchingUp)
    }

    /// Hidden time is not reading time. An explicit restore gives the currently visible page
    /// a fresh budget without changing its text, page positions or sentence identity.
    func resetReadingTime(at now: Double) {
        lastTime = now
        pageShownAt = now
        pageReadyAt = now + (hasCaption && layoutReady
            ? VideoCaptionPacing.readingTime(sourceCharacters: displayedSource.count,
                                             translationCharacters: displayedTranslation.count,
                                             sourceLanguage: sourceLanguage, targetLanguage: targetLanguage) : 0)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    // MARK: layout

    private var sourceFont: NSFont { Self.font(in: source, fallback: 17) }
    private var translationFont: NSFont { Self.font(in: translation, fallback: 26) }

    override func layout() {
        super.layout()
        captionLayer.frame = bounds
        let width = Double(bounds.width)
        let translationWidth = CGFloat(VideoCaptionLayout.translationBlockWidth(
            windowWidth: width, translationSize: Double(translationFont.pointSize), language: targetLanguage))
        let sourceWidth = CGFloat(VideoCaptionLayout.sourceBlockWidth(windowWidth: width,
                                                                      sourceSize: Double(sourceFont.pointSize), language: sourceLanguage))
        let key = LayoutKey(translationWidth: translationWidth, sourceWidth: sourceWidth,
                            sourceLines: sourceLineBudget, appearance: appearanceSettings)
        guard textNeedsLayout || key != lastLayoutKey else { applyVisual(); return }
        let previousSourceAnchor = page(in: sourcePages, at: sourcePageIndex)?.range.location ?? 0
        let previousTargetAnchor = page(in: translationPages, at: translationPageIndex)?.range.location ?? 0
        let sourceAnchor = isDisplayingFinal ? min(previousSourceAnchor, sourceCorrectionAnchor ?? previousSourceAnchor) : previousSourceAnchor
        let targetAnchor = isDisplayingFinal ? min(previousTargetAnchor, translationCorrectionAnchor ?? previousTargetAnchor) : previousTargetAnchor
        sourcePages = paginate(source, lineWidth: sourceWidth, maxLines: key.sourceLines)
        translationPages = paginate(translation, lineWidth: max(1, translationWidth),
                                    maxLines: VideoCaptionLayout.maxLinesPerPage)
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
        lastLayoutKey = key
        let resized = !textNeedsLayout
        textNeedsLayout = false
        let startsNewPage = resetPage
        resetPage = false
        showPage(at: lastTime, newPage: startsNewPage, newSentence: startsNewPage, animated: startsNewPage && !resized)
    }

    /// Two source lines when the height allows them with two translation lines; otherwise one.
    private var sourceLineBudget: Int {
        let translationLine = Self.lineHeight(translationFont), sourceLine = Self.lineHeight(sourceFont)
        let needed = CGFloat(VideoCaptionLayout.glassVerticalPadding) + 2 * sourceLine
            + CGFloat(VideoCaptionLayout.blockGap) + 2 * translationLine + CGFloat(VideoCaptionLayout.bottomBaselineInset)
        return bounds.height - reservedChromeHeight >= needed ? VideoCaptionLayout.maxLinesPerPage : 1
    }

    private func paginate(_ text: NSAttributedString, lineWidth: CGFloat, maxLines: Int) -> [Page] {
        guard text.length > 0, lineWidth > 0 else { return [] }
        let characters = Array(text.string)
        var offsets = [0]
        offsets.reserveCapacity(characters.count + 1)
        var advances: [Double] = []
        advances.reserveCapacity(characters.count)
        for character in characters {
            let location = offsets.last!
            let length = character.utf16.count
            offsets.append(location + length)
            let font = text.attribute(.font, at: min(location, text.length - 1), effectiveRange: nil) as? NSFont ?? translationFont
            advances.append(Double(advance(of: character, font: font)))
        }
        let laidOut = VideoCaptionPager.paginate(characters, advances: advances, lineWidth: Double(lineWidth), maxLines: maxLines)
            .map { page in
                page.lines.map { NSRange(location: offsets[$0.lowerBound], length: offsets[$0.upperBound] - offsets[$0.lowerBound]) }
            }
            .filter { !$0.isEmpty }
        // Pages tile the whole text: each owns the spaces after it, so correction anchors and
        // the final page's end match the text length.
        return laidOut.enumerated().map { index, lines in
            let start = index == 0 ? 0 : lines[0].location
            let end = index + 1 < laidOut.count ? laidOut[index + 1][0].location : text.length
            let range = NSRange(location: start, length: max(0, end - start))
            return Page(range: range, text: text.attributedSubstring(from: range), lines: lines)
        }
    }

    private func advance(of character: Character, font: NSFont) -> CGFloat {
        let key = "\(font.fontName)|\(font.pointSize)|\(character)"
        if let cached = advanceCache[key] { return cached }
        let width = (String(character) as NSString).size(withAttributes: [.font: font]).width
        if advanceCache.count > 4096 { advanceCache.removeAll(keepingCapacity: true) }
        advanceCache[key] = width
        return width
    }

    private func page(in pages: [Page], at index: Int) -> Page? {
        guard !pages.isEmpty else { return nil }
        // Keep the last page of the shorter language visible while the longer one finishes.
        return pages[min(index, pages.count - 1)]
    }

    private func showPage(at now: Double, newPage: Bool, newSentence: Bool = false, animated: Bool? = nil) {
        let sourcePage = layoutReady ? page(in: sourcePages, at: sourcePageIndex)?.text : nil
        let targetPage = layoutReady ? page(in: translationPages, at: translationPageIndex)?.text : nil
        let newSource = sourcePage?.string ?? "", newTarget = targetPage?.string ?? ""
        let changedSource = Self.changedCharacters(newSource, replacing: displayedSource)
        let changedTarget = Self.changedCharacters(newTarget, replacing: displayedTranslation)
        let pageSourceCharacters = newSentence || newSource != displayedSource ? newSource.count : 0
        let pageTargetCharacters = newSentence || newTarget != displayedTranslation ? newTarget.count : 0
        let textChanged = newSource != displayedSource || newTarget != displayedTranslation
        displayedSource = newSource; displayedTranslation = newTarget
        // Page flips cross-fade; in-place draft growth and resizes do not.
        presentVisual(animated: animated ?? newPage)
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
            pageShownAt = now
            pageReadyAt = now + VideoCaptionPacing.readingTime(sourceCharacters: pageSourceCharacters,
                                                               translationCharacters: pageTargetCharacters,
                                                               sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
        } else if changedSource > 0 || changedTarget > 0 {
            // A same-sentence final or partial does not charge the already visible prefix
            // again, and a color/font-only update never restarts its reading clock.
            pageReadyAt = max(pageReadyAt, now + VideoCaptionPacing.readingTime(sourceCharacters: changedSource,
                                                                               translationCharacters: changedTarget,
                                                                               sourceLanguage: sourceLanguage, targetLanguage: targetLanguage))
        }
        if textChanged || newPage { onDisplayedTextChange?() }
    }

    // MARK: visual

    /// Page flips fade out, leave one blank frame and fade in, 120 ms in total (§6).
    private func presentVisual(animated: Bool) {
        let duration = appearanceSettings.reduceMotion ? 0 : SubtitleTokens.Motion.videoPageCrossfade.seconds
        guard animated, duration > 0, window != nil, !captionLayer.isHidden else {
            // Outside a page flip the captions are fully visible.
            if !fadeInFlight, !fadingIn { captionLayer.alphaValue = 1 }
            applyVisual()
            return
        }
        visualGeneration += 1
        let generation = visualGeneration
        // Updates during the fade-out are picked up when the new page is placed.
        fadeInFlight = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration / 2
            captionLayer.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.visualGeneration else { return }
                self.fadeInFlight = false
                self.fadingIn = true
                self.applyVisual()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, generation == self.visualGeneration else { return }
                        NSAnimationContext.runAnimationGroup({ context in
                            context.duration = duration / 2
                            self.captionLayer.animator().alphaValue = 1
                        }, completionHandler: { [weak self] in
                            MainActor.assumeIsolated {
                                guard let self, generation == self.visualGeneration else { return }
                                self.fadingIn = false
                            }
                        })
                    }
                }
            }
        })
    }

    /// Places blocks, glass, plates, dots and notices for the current pages.
    private func applyVisual() {
        guard !fadeInFlight else { return }
        let style = appearanceSettings.style
        let sourcePageValue = layoutReady ? page(in: sourcePages, at: sourcePageIndex) : nil
        let targetPageValue = layoutReady ? page(in: translationPages, at: translationPageIndex) : nil
        let hasNextPage = layoutReady && currentPageIndex + 1 < pageCount
        let isLastTranslationPage = translationPageIndex + 1 >= translationPages.count

        // Source slot: the skipped notice, the page, or the empty-state placeholder.
        var sourceVisual = sourcePageValue.map { visual(for: $0, in: source) } ?? NSAttributedString(string: "")
        let contrast = appearanceSettings.increaseContrast
        var notice: NSAttributedString?
        var noticeText: String?
        if let skipped = skippedNotice {
            notice = plain(skipped.text, size: VideoCaptionLayout.skippedNoticeSize,
                           alpha: VideoCaptionLayout.skippedNoticeAlpha(increaseContrast: contrast))
            noticeText = skipped.text
        } else if !hasCaption, let placeholder, !placeholder.isEmpty {
            notice = placeholderVisual(placeholder)
            noticeText = placeholder
        }
        if notice != nil { sourceVisual = NSAttributedString(string: "") }
        let translationVisual = NSMutableAttributedString(attributedString:
            targetPageValue.map { visual(for: $0, in: translation) } ?? NSAttributedString(string: ""))
        // More pages are shown by the page dots alone (no "›" on the line as well).
        if translationVisual.length > 0, fallback, isDisplayingFinal, isLastTranslationPage {
            let attributes = translationVisual.attributes(at: translationVisual.length - 1, effectiveRange: nil)
            translationVisual.append(ConversationText.fallbackBadge(baseFont: translationFont, attributes: attributes))
        }

        let plateAlpha = plateBaseAlpha
        for view in [sourceView, translationView, noticeView] {
            view.plateAlpha = style == .plate ? plateAlpha : 0
            view.backdrop.alphaValue = plateDimFactor
        }
        if finalizing, !appearanceSettings.reduceMotion {
            translationView.fade(duration: SubtitleTokens.Motion.draftToFinal.seconds)
        }
        sourceView.setCaption(sourceVisual)
        translationView.setCaption(translationVisual)
        noticeView.setCaption(notice ?? NSAttributedString(string: ""))
        sourceView.setAccessibilityValue(displayedSource)
        // VoiceOver hears that more pages follow, which the dots only show.
        translationView.setAccessibilityValue(layoutReady && pageCount > 1 && !displayedTranslation.isEmpty
            ? String(localized: "\(displayedTranslation)，第 \(currentPageIndex + 1) 页，共 \(pageCount) 页")
            : displayedTranslation)
        // The source block is hidden while a notice holds its slot; the notice is read instead.
        noticeView.setAccessibilityValue(noticeText)
        if fallback, isDisplayingFinal {
            translationView.setAccessibilityHelp(ConversationText.fallbackHelp)
        } else {
            translationView.setAccessibilityHelp(nil)
        }

        // Bottom anchoring: the bottom block's last baseline sits 12 pt above the content edge.
        let height = bounds.height
        let translationFirst = appearanceSettings.arrangement == .translationFirst
        let topSlot = translationFirst ? translationView : (notice != nil ? noticeView : sourceView)
        let bottomSlot = translationFirst ? (notice != nil ? noticeView : sourceView) : translationView
        sourceView.isHidden = notice != nil
        noticeView.isHidden = notice == nil
        let showsDots = hasNextPage && pageCount > 1
        let dotsSpace = CGFloat(VideoCaptionLayout.pageDotGap + VideoCaptionLayout.pageDotDiameter + 2)
        let bottomBaseline = height - CGFloat(VideoCaptionLayout.bottomBaselineInset)
        let bottomLines = bottomSlot.lineCount
        let bottomFont = bottomSlot.firstFont ?? translationFont
        let bottomLine = Self.lineHeight(bottomFont)
        let bottomTop = bottomLines > 0
            ? bottomBaseline - (CGFloat(bottomLines - 1) * bottomLine + baselineOffset(for: bottomFont))
            : bottomBaseline
        place(bottomSlot, top: bottomTop, lines: bottomLines, font: bottomFont)
        let gap = CGFloat(VideoCaptionLayout.blockGap) + (translationFirst && showsDots ? dotsSpace : 0)
        let topLines = topSlot.lineCount
        let topFont = topSlot.firstFont ?? sourceFont
        let topBottom = bottomLines > 0 ? bottomTop - gap : bottomBaseline
        place(topSlot, top: topBottom - CGFloat(topLines) * Self.lineHeight(topFont), lines: topLines, font: topFont)

        // Page dots 4 pt under the Chinese block, hidden on the last page.
        dots.isHidden = !showsDots
        if showsDots {
            dots.count = pageCount
            dots.current = currentPageIndex
            dots.increaseContrast = contrast
            let baseline = translationView.frame.minY + CGFloat(max(0, translationView.lineCount - 1)) * Self.lineHeight(translationFont)
                + baselineOffset(for: translationFont)
            let size = dots.intrinsicContentSize
            let y = min(baseline - translationFont.descender + CGFloat(VideoCaptionLayout.pageDotGap),
                        height - size.height - 1)
            dots.frame = NSRect(x: (bounds.width - size.width) / 2, y: y, width: size.width, height: size.height)
        }

        // Fitted glass: one rounded block around both text blocks' used bounds.
        var union = NSRect.null
        for view in [topSlot, bottomSlot] where !view.isHidden && view.lineCount > 0 {
            union = union.union(view.usedTextRect.offsetBy(dx: view.frame.minX, dy: view.frame.minY))
        }
        if showsDots { union = union.union(dots.frame) }
        let showsGlass = style == .fittedGlass && !union.isNull
        glass.isHidden = !showsGlass
        var padded = union.isNull ? NSRect.null
            : union.insetBy(dx: -CGFloat(VideoCaptionLayout.glassHorizontalPadding),
                            dy: -CGFloat(VideoCaptionLayout.glassVerticalPadding)).integral
        if !padded.isNull {
            let readingWidth = CGFloat(VideoCaptionLayout.readingWidth(windowWidth: Double(bounds.width),
                translationSize: Double(translationFont.pointSize), sourceSize: Double(sourceFont.pointSize),
                sourceLanguage: sourceLanguage, targetLanguage: targetLanguage))
            padded.origin.x = (bounds.width - readingWidth) / 2
            padded.size.width = readingWidth
        }
        if showsGlass {
            glass.frame = padded
            glass.alphaValue = glassAlpha
        }
        if textBlockRect != padded {
            textBlockRect = padded
            onReadingBoundsChange?()
        }
    }

    private func place(_ view: VideoCaptionTextView, top: CGFloat, lines: Int, font: NSFont) {
        // A little slack keeps TextKit from re-wrapping lines the pager already broke.
        let blockWidth = view === sourceView
            ? CGFloat(VideoCaptionLayout.sourceBlockWidth(windowWidth: Double(bounds.width), sourceSize: Double(font.pointSize), language: sourceLanguage))
            : CGFloat(VideoCaptionLayout.translationBlockWidth(windowWidth: Double(bounds.width), translationSize: Double(font.pointSize), language: targetLanguage))
        let width = min(bounds.width, max(blockWidth, view.naturalWidth) + 4 * font.pointSize)
        view.frame = NSRect(x: (bounds.width - width) / 2, y: top, width: width,
                            height: CGFloat(lines) * Self.lineHeight(font))
    }

    /// Baseline offset from a fixed-height line's top, measured once per font.
    private func baselineOffset(for font: NSFont) -> CGFloat {
        let key = "\(font.fontName)|\(font.pointSize)"
        if let cached = baselineCache[key] { return cached }
        let storage = NSTextStorage(string: "国A", attributes: [.font: font, .paragraphStyle: Self.paragraph(for: font)]) // l10n-ignore
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 1000, height: 1000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let value = manager.location(forGlyphAt: 0).y
        baselineCache[key] = value
        return value
    }

    static func paragraph(for font: NSFont) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.minimumLineHeight = lineHeight(font)
        paragraph.maximumLineHeight = lineHeight(font)
        return paragraph
    }

    /// The page's lines joined by explicit breaks, with the style's stroke and shadow.
    private func visual(for page: Page, in text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, line) in page.lines.enumerated() {
            if index > 0 {
                let attributes = text.attributes(at: max(0, line.location - 1), effectiveRange: nil)
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
            result.append(text.attributedSubstring(from: line))
        }
        styled(result)
        return result
    }

    /// "正在听 <来源>…" led by the listening glyph, so the empty state matches the bar's `ear`.
    private func placeholderVisual(_ value: String) -> NSAttributedString {
        let alpha = VideoCaptionLayout.placeholderAlpha(increaseContrast: appearanceSettings.increaseContrast)
        let font = NSFont.systemFont(ofSize: VideoCaptionLayout.placeholderSize)
        let color = SubtitleStyle.white(CGFloat(alpha))
        let result = NSMutableAttributedString()
        if let symbol = SubtitleStyle.symbol(SubtitleTokens.VoiceIcon.listening,
                                             size: CGFloat(VideoCaptionLayout.placeholderSymbolSize), weight: .regular) {
            let image = SubtitleStyle.tinted(symbol, color)
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: (font.capHeight - image.size.height) / 2,
                                       width: image.size.width, height: image.size.height)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: " "))
            result.addAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: result.length))
        }
        result.append(NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: color]))
        styled(result)
        return result
    }

    private func plain(_ value: String, size: Double, alpha: Double) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: size)
        let result = NSMutableAttributedString(string: value, attributes: [
            .font: font, .foregroundColor: SubtitleStyle.white(CGFloat(alpha)),
        ])
        styled(result)
        return result
    }

    private func styled(_ text: NSMutableAttributedString) {
        let whole = NSRange(location: 0, length: text.length)
        guard whole.length > 0 else { return }
        text.enumerateAttribute(.font, in: whole) { value, range, _ in
            let font = value as? NSFont ?? translationFont
            text.addAttribute(.paragraphStyle, value: Self.paragraph(for: font), range: range)
        }
        let style = appearanceSettings.style
        if let token = style.textShadow(opacity: Double(appearanceSettings.opacity)) {
            let shadow = NSShadow()
            shadow.shadowColor = SubtitleStyle.nsColor(token.color)
            shadow.shadowBlurRadius = token.blur
            shadow.shadowOffset = NSSize(width: token.offsetX, height: token.offsetY)
            text.addAttribute(.shadow, value: shadow, range: whole)
        } else {
            text.removeAttribute(.shadow, range: whole)
        }
        if style == .stroke {
            // Negative stroke width keeps the foreground fill.
            text.addAttributes([.strokeWidth: VideoCaptionStyle.strokeWidth, .strokeColor: NSColor.black], range: whole)
        }
    }

    // MARK: helpers

    private func correctionIsVisible(_ offset: Int?, in page: Page?, length: Int) -> Bool {
        guard let offset else { return false }
        if length == 0 { return true }
        guard let page, page.range.location <= offset else { return false }
        return offset < NSMaxRange(page.range) || (offset == length && NSMaxRange(page.range) == length)
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

    private static func pageIndex(containing anchor: Int, in pages: [Page]) -> Int {
        pages.firstIndex { anchor < NSMaxRange($0.range) } ?? max(0, pages.count - 1)
    }
}

/// Holds every caption element so a page flip can fade them together.
private final class CaptionContainerView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

/// 3 pt dots, 4 pt apart: the current page white 90%, the others 30%.
private final class PageDotsView: NSView {
    var count = 0 { didSet { if count != oldValue { needsDisplay = true; invalidateIntrinsicContentSize() } } }
    var current = 0 { didSet { if current != oldValue { needsDisplay = true } } }
    var increaseContrast = false { didSet { if increaseContrast != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override var intrinsicContentSize: NSSize {
        let diameter = CGFloat(VideoCaptionLayout.pageDotDiameter), spacing = CGFloat(VideoCaptionLayout.pageDotSpacing)
        return NSSize(width: max(0, CGFloat(count) * diameter + CGFloat(max(0, count - 1)) * spacing), height: diameter)
    }

    override func draw(_ dirtyRect: NSRect) {
        let diameter = CGFloat(VideoCaptionLayout.pageDotDiameter), spacing = CGFloat(VideoCaptionLayout.pageDotSpacing)
        for index in 0..<count {
            let alpha = index == current ? VideoCaptionLayout.pageDotCurrentAlpha(increaseContrast: increaseContrast)
                : VideoCaptionLayout.pageDotOtherAlpha(increaseContrast: increaseContrast)
            SubtitleStyle.white(CGFloat(alpha)).setFill()
            NSBezierPath(ovalIn: NSRect(x: CGFloat(index) * (diameter + spacing), y: 0, width: diameter, height: diameter)).fill()
        }
    }
}

@MainActor
private final class VideoCaptionTextView: NSTextView {
    private let captionStorage: NSTextStorage
    /// Plate style: a rounded dark block behind each line; 0 draws none. The blocks are drawn
    /// by `backdrop`, a sibling right below this view that follows its frame and visibility.
    var plateAlpha: CGFloat = 0 { didSet { if plateAlpha != oldValue { backdrop.needsDisplay = true } } }
    let backdrop = CaptionPlateView()
    override var isHidden: Bool { didSet { backdrop.isHidden = isHidden } }
    override var frame: NSRect { didSet { syncBackdrop() } }
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); syncBackdrop() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); syncBackdrop() }
    private func syncBackdrop() {
        if backdrop.frame != frame { backdrop.frame = frame }
        backdrop.needsDisplay = true
    }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    init() {
        // Supply a TextKit 1 stack. A nil container can opt into TextKit 2 on newer systems,
        // whose metrics and layout-manager access differ.
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
        wantsLayer = true
        backdrop.text = self
    }

    required init?(coder: NSCoder) { return nil }

    func setCaption(_ value: NSAttributedString) {
        guard textStorage?.isEqual(to: value) != true else { return }
        textStorage?.setAttributedString(value)
        needsDisplay = true
        backdrop.needsDisplay = true
    }

    /// The colour change of a final replacing its draft in place.
    func fade(duration: TimeInterval) {
        guard duration > 0 else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = duration
        layer?.add(transition, forKey: "draftToFinal")
    }

    var lineCount: Int {
        guard let text = textStorage, text.length > 0 else { return 0 }
        return text.string.components(separatedBy: "\n").count
    }

    var firstFont: NSFont? {
        guard let text = textStorage, text.length > 0 else { return nil }
        return text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    }

    /// Widest line, so the frame never forces a wrap of a pager line.
    var naturalWidth: CGFloat {
        guard let text = textStorage, text.length > 0 else { return 0 }
        return ceil(text.size().width)
    }

    /// Union of the laid-out lines' used rects in view coordinates.
    var usedTextRect: NSRect {
        guard let manager = layoutManager, let container = textContainer, (textStorage?.length ?? 0) > 0 else { return .null }
        manager.ensureLayout(for: container)
        var union = NSRect.null
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, used, _, _, _ in
            union = union.union(used)
        }
        return union
    }

    /// Plate blocks in this view's coordinates (§6 实底).
    func drawPlates() {
        guard plateAlpha > 0, let manager = layoutManager, let container = textContainer, (textStorage?.length ?? 0) > 0 else { return }
        manager.ensureLayout(for: container)
        NSColor(white: 0, alpha: plateAlpha).setFill()
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { [weak self] rect, used, _, glyphs, _ in
            guard let self, used.width > 0 else { return }
            let characterIndex = manager.characterIndexForGlyph(at: glyphs.location)
            let font = self.textStorage?.attribute(.font, at: characterIndex, effectiveRange: nil) as? NSFont
            let padding = CGFloat(VideoCaptionLayout.plateHorizontalPaddingEm) * (font?.pointSize ?? 20)
            let block = NSRect(x: used.minX - padding, y: rect.minY, width: used.width + 2 * padding, height: rect.height)
            let radius = CGFloat(SubtitleTokens.Radius.solidRowBlock)
            NSBezierPath(roundedRect: block, xRadius: radius, yRadius: radius).fill()
        }
    }
}

/// Draws a caption text view's plates right below it.
@MainActor
private final class CaptionPlateView: NSView {
    weak var text: VideoCaptionTextView?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) { text?.drawPlates() }
}
