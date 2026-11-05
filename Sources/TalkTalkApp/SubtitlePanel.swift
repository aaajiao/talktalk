// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import TalkTalkCore
import TalkTalkSession

/// One non-activating window for remote subtitles and the local speech HUD. Both sections keep
/// their own scroll space, while the title bar, text and background move the same saved window.
@MainActor
final class SubtitlePanel {
    private let panel: NSPanel
    private let content = ConversationContentView()
    private let backgroundEffect = NSVisualEffectView()
    private let body = ConversationContentView()
    private let scroll = ConversationScrollView()
    private let speechScroll = ConversationScrollView()
    private let remoteHeading = ConversationLabel(wrappingLabelWithString: String(localized: "对方 / 视频"))
    private let speechHeading = ConversationLabel(wrappingLabelWithString: String(localized: "我"))
    private let divider = NSBox()
    private let sourceLabel = ConversationLabel(wrappingLabelWithString: "")
    private let finalLabels = [ConversationLabel(wrappingLabelWithString: ""), ConversationLabel(wrappingLabelWithString: "")]
    private let finalSourceLabels = [ConversationLabel(wrappingLabelWithString: ""), ConversationLabel(wrappingLabelWithString: "")]
    private let draftLabel = ConversationLabel(wrappingLabelWithString: "")
    private(set) var board = SubtitleBoard(maxCharactersPerSecond: 9)
    private(set) var baseFontSize: CGFloat = 22
    var textScale: CGFloat { contentWidth / 760 }
    var fontSize: CGFloat { max(14, baseFontSize * textScale) }
    private var backgroundOpacity: CGFloat = 0.85
    private var manualContentSize: NSSize?
    private var isLayingOut = false
    private var subtitlesRequested = false
    private var speechHeight: CGFloat = 0
    var onAppearanceChange: (() -> Void)?
    var onHintChange: ((String?) -> Void)?
    private var liveSource = ""
    private var timer: Timer?
    private var moveObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    var analysisRecorder: SubtitleAnalysisRecorder?
    private var analysisConfiguration: UInt64 = 0
    private var presentedFinals: [SubtitleBoard.Line] = []
    private var presentedDraft: SubtitleBoard.Line?
    private var labelsInOrder: [NSTextField] {
        [finalSourceLabels[0], finalLabels[0], finalSourceLabels[1], finalLabels[1], sourceLabel, draftLabel]
    }
    var frame: NSRect { panel.frame }
    var screen: NSScreen? { panel.screen }
    var contentWidth: CGFloat {
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame.width ?? 1440
        return min(max(480, manualContentSize?.width ?? 760), max(280, visible - 40))
    }

    init() {
        panel = SubtitleWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 150),
                               styleMask: [.titled, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.title = String(localized: "TalkTalk · 字幕与发言")
        panel.identifier = NSUserInterfaceItemIdentifier("TalkTalkConversation")
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.titleVisibility = .visible
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        backgroundEffect.material = .hudWindow
        backgroundEffect.blendingMode = .behindWindow
        backgroundEffect.state = .active
        backgroundEffect.autoresizingMask = [.width, .height]
        content.addSubview(backgroundEffect)

        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = body
        content.addSubview(scroll)
        speechScroll.drawsBackground = false
        speechScroll.borderType = .noBorder
        speechScroll.hasHorizontalScroller = false
        speechScroll.autohidesScrollers = true
        speechScroll.scrollerStyle = .overlay
        content.addSubview(speechScroll)
        for heading in [remoteHeading, speechHeading] {
            heading.font = .systemFont(ofSize: 12, weight: .semibold)
            heading.textColor = .secondaryLabelColor
            content.addSubview(heading)
        }
        divider.boxType = .separator
        content.addSubview(divider)
        for label in labelsInOrder {
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.isSelectable = false
            label.cell?.isScrollable = false
            body.addSubview(label)
        }
        for label in finalSourceLabels + [sourceLabel] { label.textColor = NSColor(white: 0.65, alpha: 1) }
        for label in finalLabels { label.textColor = .white }
        draftLabel.textColor = NSColor(white: 0.68, alpha: 1)
        panel.contentView = content
        if let screen = NSScreen.main ?? NSScreen.screens.first,
           let saved = UserDefaults.standard.string(forKey: sizeKey(for: screen)) {
            let size = NSSizeFromString(saved)
            if size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 {
                manualContentSize = size
            }
        }
        setFontSize(22)
        updateBackground()
        placeInitially()
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePosition() }
        }
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.userResized() }
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateBackground() }
            }
    }

    isolated deinit {
        timer?.invalidate()
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    func setFontSize(_ size: Double) {
        baseFontSize = CGFloat(size.isFinite ? min(36, max(16, size)) : 22)
        updateFonts()
        render()
        onAppearanceChange?()
    }

    private func updateFonts() {
        for label in finalSourceLabels + [sourceLabel] { label.font = .systemFont(ofSize: max(11, max(12, baseFontSize * 0.65) * textScale)) }
        for label in finalLabels { label.font = .systemFont(ofSize: fontSize, weight: .medium) }
        draftLabel.font = .systemFont(ofSize: max(12, max(14, baseFontSize * 0.88) * textScale))
    }

    func setBackgroundOpacity(_ value: Double) {
        backgroundOpacity = CGFloat(value.isFinite ? min(1, max(0.35, value)) : 0.85)
        updateBackground()
    }

    private func updateBackground() {
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || backgroundOpacity >= 1
        panel.isOpaque = opaque
        panel.backgroundColor = opaque ? .windowBackgroundColor : .clear
        backgroundEffect.isHidden = opaque
        // This view is a background sibling: labels, buttons and scrolling content keep alpha 1.
        backgroundEffect.alphaValue = backgroundOpacity
        panel.invalidateShadow()
    }

    /// PTTHUD supplies only content; it never creates or orders another window.
    func setSpeechContent(_ view: NSView, height: CGFloat, hasLocalSpeech: Bool = false) {
        if speechScroll.documentView !== view { speechScroll.documentView = view }
        speechHeading.stringValue = hasLocalSpeech ? String(localized: "我的发言") : String(localized: "状态")
        speechHeight = max(0, height)
        layout()
        updateWindowVisibility()
    }

    func apply(_ update: SubtitleUpdate) {
        let now = HostClock.now()
        let previousPending = board.pendingFinalSentenceIDs
        let previousSource = liveSource
        if case .source(let text) = update { liveSource = text }
        let changed = board.apply(update, at: now)
        switch update {
        case let .final(sentence, text, source, approx, numberWarning):
            observe("subtitle_queued", at: now,
                    line: .init(sentence: sentence, text: text, source: source, approx: approx, numberWarning: numberWarning), kind: "final")
        case let .draft(sentence, text):
            observe("subtitle_queued", at: now,
                    line: .init(sentence: sentence, text: text, approx: false, numberWarning: false), kind: "draft")
        case let .dropped(sentence):
            observe("subtitle_dropped", at: now,
                    line: .init(sentence: sentence, text: "", approx: false, numberWarning: false))
        case .source: break
        }
        for sentence in previousPending where !board.pendingFinalSentenceIDs.contains(sentence)
            && !board.finals.contains(where: { $0.sentence == sentence }) {
            observe("subtitle_discarded", at: now,
                    line: .init(sentence: sentence, text: "", approx: false, numberWarning: false), kind: "pacing_overflow")
        }
        if changed || previousSource != liveSource { render() }
    }
    func setHint(_ hint: String?) {
        board.setHint(hint)
        onHintChange?(hint)
    }
    func clear() {
        liveSource = ""; board.clear(); onHintChange?(nil); render()
        observe("subtitle_cleared", at: HostClock.now())
    }

    func setAnalysisConfiguration(_ id: UInt64) {
        guard analysisConfiguration != id else { return }
        analysisConfiguration = id
        presentedFinals = []; presentedDraft = nil
        observe("configuration_reset", at: HostClock.now())
    }

    private func render() {
        let lines = Array(board.finals.suffix(finalLabels.count))
        for index in finalLabels.indices {
            let line = index < lines.count ? lines[index] : nil
            finalSourceLabels[index].stringValue = line?.source ?? ""
            finalLabels[index].stringValue = line?.display ?? ""
        }
        let currentSource = liveSource.isEmpty ? "" : String(localized: "识别中：\(liveSource)")
        sourceLabel.stringValue = board.isEmpty ? String(localized: "等待应用声音…") : currentSource
        draftLabel.stringValue = board.draft.map { String(localized: "草稿：\($0.text)") } ?? ""
        layout()
        body.alphaValue = 1
        recordPresentation()
    }

    private func recordPresentation() {
        guard subtitlesRequested, panel.isVisible else { return }
        let now = HostClock.now()
        // Log actual label changes after board pacing, including revisions, not timer ticks or
        // font/layout refreshes. This is AppKit submission time, not a display hardware timestamp.
        for line in board.finals where !presentedFinals.contains(line) {
            observe("subtitle_displayed", at: now, line: line, kind: "final")
        }
        for line in presentedFinals where !board.finals.contains(where: { $0.sentence == line.sentence }) {
            observe("subtitle_removed", at: now, line: line, kind: "final")
        }
        if let draft = board.draft, draft != presentedDraft {
            observe("subtitle_displayed", at: now, line: draft, kind: "draft")
        } else if board.draft == nil, let draft = presentedDraft {
            observe("subtitle_removed", at: now, line: draft, kind: "draft")
        }
        presentedFinals = board.finals; presentedDraft = board.draft
    }

    private func observe(_ event: String, at time: HostTime, line: SubtitleBoard.Line? = nil, kind: String? = nil) {
        analysisRecorder?.recordPanel(event, configuration: analysisConfiguration, at: time,
                                      line: line, kind: kind, visible: subtitlesRequested && panel.isVisible,
                                      pendingFinals: board.pendingFinalSentenceIDs,
                                      pendingDraft: board.pendingDraftSentenceID)
    }

    private func layout() {
        guard !isLayingOut else { return }
        isLayingOut = true
        defer { isLayingOut = false }
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = contentWidth
        let titleHeight = panel.frame.height - panel.contentRect(forFrameRect: panel.frame).height
        let maxHeight = max(140, visible.height - titleHeight - 40)
        panel.contentMinSize = NSSize(width: min(480, width), height: 140)
        panel.contentMaxSize = NSSize(width: max(280, visible.width - 40), height: maxHeight)
        let textWidth = width - 44
        var y: CGFloat = 0
        for label in labelsInOrder {
            label.isHidden = label.stringValue.isEmpty
            guard !label.isHidden, let font = label.font else { continue }
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
            let bounds = (label.stringValue as NSString).boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .paragraphStyle: paragraph])
            let height = ceil(max(font.ascender - font.descender + font.leading, bounds.height)) + 4
            label.preferredMaxLayoutWidth = textWidth
            label.frame = NSRect(x: 0, y: y, width: textWidth, height: height)
            y += height + (finalLabels.contains(where: { $0 === label }) ? 14 : 5)
        }
        let bodyHeight = max(24, y)
        let hasSpeech = speechHeight > 0
        let manualHeight = manualContentSize.map { min(maxHeight, max(140, $0.height)) }
        let sectionChrome: CGFloat = 24 + (subtitlesRequested ? 24 : 0) + (hasSpeech ? 24 : 0) + (subtitlesRequested && hasSpeech ? 22 : 0)
        let budget = manualHeight.map { max(40, $0 - sectionChrome) } ?? max(160, visible.height * 0.7 - 80)
        var viewportHeight = subtitlesRequested ? min(bodyHeight, hasSpeech ? budget * 0.55 : budget) : 0
        let speechViewportHeight = hasSpeech ? min(speechHeight, budget - viewportHeight) : 0
        if subtitlesRequested { viewportHeight = min(bodyHeight, budget - speechViewportHeight) }
        var top: CGFloat = 12
        remoteHeading.isHidden = !subtitlesRequested
        scroll.isHidden = !subtitlesRequested
        speechHeading.isHidden = !hasSpeech
        speechScroll.isHidden = !hasSpeech
        divider.isHidden = !subtitlesRequested || !hasSpeech
        if subtitlesRequested {
            remoteHeading.frame = NSRect(x: 16, y: top, width: width - 32, height: 18)
            top += 24
            scroll.frame = NSRect(x: 16, y: top, width: width - 32, height: viewportHeight)
            top += viewportHeight
        }
        if hasSpeech {
            if subtitlesRequested {
                divider.frame = NSRect(x: 16, y: top + 10, width: width - 32, height: 1)
                top += 22
            }
            speechHeading.frame = NSRect(x: 16, y: top, width: width - 32, height: 18)
            top += 24
            speechScroll.frame = NSRect(x: 4, y: top, width: width - 8, height: speechViewportHeight)
            speechScroll.hasVerticalScroller = speechHeight > speechViewportHeight
            top += speechViewportHeight
        }
        let size = NSSize(width: width, height: manualHeight ?? min(maxHeight, max(140, top + 12)))
        let old = panel.frame
        let oldSize = panel.contentRect(forFrameRect: old).size
        let sizeChanged = abs(oldSize.width - size.width) > 0.5 || abs(oldSize.height - size.height) > 0.5
        if sizeChanged { panel.setContentSize(size) }
        content.frame = NSRect(origin: .zero, size: size)
        backgroundEffect.frame = content.bounds
        body.frame = NSRect(x: 0, y: 0, width: width - 32, height: bodyHeight)
        scroll.hasVerticalScroller = bodyHeight > viewportHeight
        // A content refresh must not fight an in-progress drag or overwrite a manual size.
        if sizeChanged {
            let x = min(max(visible.minX + 12, old.midX - width / 2), visible.maxX - width - 12)
            let bottom = min(max(visible.minY + 12, old.minY), visible.maxY - panel.frame.height - 12)
            panel.setFrameOrigin(NSPoint(x: x, y: bottom))
        }
    }

    func setVisible(_ on: Bool) {
        guard subtitlesRequested != on else { return }
        subtitlesRequested = on
        layout()
        updateWindowVisibility()
        if on {
            body.alphaValue = 1
            observe("panel_shown", at: HostClock.now())
            recordPresentation()
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        } else {
            timer?.invalidate(); timer = nil
            observe("panel_hidden", at: HostClock.now())
            presentedFinals = []; presentedDraft = nil
        }
    }
    private func updateWindowVisibility() {
        if subtitlesRequested || speechHeight > 0 { panel.orderFrontRegardless() }
        else { panel.orderOut(nil) }
    }
    var isVisible: Bool { subtitlesRequested && panel.isVisible }
    var isWindowVisible: Bool { panel.isVisible }
    var speechIsVisible: Bool { speechHeight > 0 && panel.isVisible }

    private func poll() {
        if board.advance() { render() }
    }

    private func userResized() {
        guard !isLayingOut else { return }
        manualContentSize = panel.contentRect(forFrameRect: panel.frame).size
        updateFonts()
        render()
        onAppearanceChange?()
        if let screen = panel.screen {
            UserDefaults.standard.set(NSStringFromSize(panel.contentRect(forFrameRect: panel.frame).size), forKey: sizeKey(for: screen))
        }
        savePosition()
    }

    private func key(for screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return "ui.subtitleOrigin.\(number?.stringValue ?? "main")"
    }
    private func sizeKey(for screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return "ui.subtitleSize.\(number?.stringValue ?? "main")"
    }
    private func placeInitially() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        if let saved = UserDefaults.standard.string(forKey: key(for: screen)) {
            let point = NSPointFromString(saved)
            if screen.visibleFrame.insetBy(dx: -40, dy: -40).contains(point) {
                let visible = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: min(max(point.x, visible.minX + 12), visible.maxX - panel.frame.width - 12),
                                             y: min(max(point.y, visible.minY + 12), visible.maxY - panel.frame.height - 12)))
                return
            }
        }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 80))
    }
    private func savePosition() {
        guard !isLayingOut, let screen = panel.screen else { return }
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: key(for: screen))
    }

    var sharingTypeIsNone: Bool { panel.sharingType == .none }
    var collectionBehavior: NSWindow.CollectionBehavior { panel.collectionBehavior }
    var clickThrough: Bool { panel.ignoresMouseEvents }
    var canBecomeKey: Bool { panel.canBecomeKey }
    var isMovable: Bool { panel.isMovable && panel.isMovableByWindowBackground }
    var isResizable: Bool { panel.styleMask.contains(.resizable) }
    var hasManualSize: Bool { manualContentSize != nil }
    var windowNumber: Int { panel.windowNumber }
    var shownLines: [String] { labelsInOrder.map(\.stringValue) }
    #if TALKTALK_DEV
    func markPreviewForSmoke() {
        panel.title = String(localized: "TalkTalk · 界面预览（无音频）")
        // Only the explicit, fixed-text development fixture can be captured for visual QA.
        // Normal windows retain .none, including the default smoke's privacy assertion.
        panel.sharingType = .readOnly
        panel.orderFrontRegardless()
    }
    #endif
}

private final class SubtitleWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
final class ConversationContentView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
final class ConversationLabel: NSTextField {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
final class ConversationScrollView: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
