// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import TalkTalkCore
import TalkTalkSession

/// One non-activating window with independent text cells. Meeting and phone modes have two
/// bilingual rows; video mode has a compact subtitle strip. The parent places fixed viewports.
@MainActor
final class SubtitlePanel {
    enum Presentation: String { case meeting, phone, video }
    private(set) var presentation: Presentation = .meeting
    private let panel: NSPanel
    private let content = ConversationContentView()
    private let backgroundEffect = NSVisualEffectView()
    private let remoteColumns = ConversationColumnsView()
    private var speechView: NSView?
    private let remoteHeading = ConversationLabel(wrappingLabelWithString: String(localized: "对方"))
    private let speechHeading = ConversationLabel(wrappingLabelWithString: String(localized: "我的发言"))
    private let divider = NSBox()
    private let phoneFooter = PhoneSubtitleFooterView()
    private var phoneContext: String?
    private var displayedLines = Array(repeating: "", count: 6)
    private var resetRemoteScroll = false
    private(set) var board = SubtitleBoard(maxCharactersPerSecond: 9, retention: .meeting)
    private(set) var baseFontSize: CGFloat = 22
    var textScale: CGFloat { contentWidth / (presentation == .video ? 960 : 760) }
    var fontSize: CGFloat { max(14, baseFontSize * textScale) }
    private var backgroundOpacity: CGFloat = 0.85
    private var manualContentSize: NSSize?
    private var isLayingOut = false
    private var subtitlesRequested = false
    private var speechHeight: CGFloat = 0
    private var speechHasLocalContent = false
    private var statusView: NSView?
    private var statusHeight: CGFloat = 0
    var onPresentationChange: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    var onHintChange: ((String?) -> Void)?
    var openPhone: (() -> Void)?
    var endPhoneTranslation: (() -> Void)?
    private var liveSource = ""
    private var renderedSource = ""
    private var renderedDraft: SubtitleBoard.Line?
    private var lastPreviewRenderAt: HostTime = 0
    private static let previewInterval: HostTime = 500_000_000
    private var timer: Timer?
    private var moveObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    var analysisRecorder: SubtitleAnalysisRecorder?
    private var analysisConfiguration: UInt64 = 0
    private var presentedFinals: [SubtitleBoard.Line] = []
    private var presentedDraft: SubtitleBoard.Line?
    var frame: NSRect { panel.frame }
    var screen: NSScreen? { panel.screen }
    private var defaultContentSize: NSSize {
        presentation == .video ? NSSize(width: 960, height: 180) : NSSize(width: 760, height: 480)
    }
    private var minimumWidth: CGFloat { presentation == .video ? 640 : 480 }
    private var showsPhoneFooter: Bool { presentation == .phone && phoneContext != nil }
    var contentWidth: CGFloat {
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame.width ?? 1440
        return min(max(minimumWidth, manualContentSize?.width ?? defaultContentSize.width), max(280, visible - 40))
    }

    init() {
        panel = SubtitleWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 150),
                               styleMask: [.titled, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.title = String(localized: "TalkTalk · 会议同传")
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

        content.addSubview(remoteColumns)
        for heading in [remoteHeading, speechHeading] {
            heading.font = .systemFont(ofSize: 12, weight: .semibold)
            heading.textColor = .secondaryLabelColor
            content.addSubview(heading)
        }
        divider.boxType = .separator
        content.addSubview(divider)
        phoneFooter.isHidden = true
        phoneFooter.openPhone = { [weak self] in self?.openPhone?() }
        phoneFooter.endTranslation = { [weak self] in self?.endPhoneTranslation?() }
        content.addSubview(phoneFooter)
        panel.contentView = content
        remoteColumns.onDisplayedTextChange = { [weak self] in self?.recordPresentation() }
        if let screen = NSScreen.main ?? NSScreen.screens.first { loadSize(for: screen) }
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

    func setPresentation(_ value: Presentation) {
        guard value != presentation else { return }
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        if panel.isVisible { savePosition() }
        presentation = value
        if value != .phone { phoneContext = nil }
        clear()
        board = SubtitleBoard(maxCharactersPerSecond: 9, retention: value == .video ? nil : .meeting)
        switch value {
        case .meeting: panel.title = String(localized: "TalkTalk · 会议同传")
        case .phone: panel.title = String(localized: "TalkTalk · 电话同传")
        case .video: panel.title = String(localized: "TalkTalk · 视频字幕")
        }
        remoteHeading.stringValue = value == .phone ? String(localized: "电话对方") : String(localized: "对方")
        remoteColumns.style = value == .video ? .subtitles : .columns
        if let screen { loadSize(for: screen) }
        else { manualContentSize = nil }
        render(forceLayout: true)
        placeInitially(on: screen)
        onPresentationChange?()
        onAppearanceChange?()
        updateWindowVisibility()
    }

    func setFontSize(_ size: Double) {
        baseFontSize = CGFloat(size.isFinite ? min(36, max(16, size)) : 22)
        render(forceLayout: true)
        onAppearanceChange?()
    }

    func setBackgroundOpacity(_ value: Double) {
        backgroundOpacity = CGFloat(value.isFinite ? min(1, max(0.35, value)) : 0.85)
        updateBackground()
    }

    /// Phone owns dialing and the actual call. This row describes only TalkTalk's translation
    /// session; clearing it also removes the phone actions after that session ends.
    func setPhoneContext(_ text: String?) {
        guard phoneContext != text else { return }
        let wasVisible = showsPhoneFooter
        phoneContext = text
        phoneFooter.setContext(text ?? "")
        if wasVisible != showsPhoneFooter { layout(); updateWindowVisibility() }
    }

    func setPhoneActionsEnabled(_ enabled: Bool) { phoneFooter.setActionsEnabled(enabled) }

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
        let changedView = speechView !== view
        if changedView {
            speechView?.removeFromSuperview()
            speechView = view
            content.addSubview(view)
        }
        let nextHeight = max(0, height)
        guard changedView || abs(speechHeight - nextHeight) > 0.5 || speechHasLocalContent != hasLocalSpeech else { return }
        let visibilityChanged = (speechHeight > 0) != (nextHeight > 0)
        speechHasLocalContent = hasLocalSpeech
        speechHeight = nextHeight
        layout()
        if visibilityChanged { updateWindowVisibility() }
    }

    /// One persistent status row outside both scrolling reading areas. Its usable width is
    /// contentWidth - 32; updating the row's labels at the same height never relays out text.
    func setStatusContent(_ view: NSView, height: CGFloat) {
        let changedView = statusView !== view
        if changedView {
            statusView?.removeFromSuperview()
            statusView = view
            content.addSubview(view)
        }
        let nextHeight = max(0, height)
        guard changedView || abs(statusHeight - nextHeight) > 0.5 else { return }
        let visibilityChanged = (statusHeight > 0) != (nextHeight > 0)
        statusHeight = nextHeight
        layout()
        if visibilityChanged { updateWindowVisibility() }
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
        if changed || previousSource != liveSource { render(at: now) }
    }
    func setHint(_ hint: String?) {
        guard board.hint != hint else { return }
        board.setHint(hint)
        onHintChange?(hint)
    }
    func clear() {
        let hadHint = board.hint != nil
        liveSource = ""; lastPreviewRenderAt = 0; board.clear()
        resetRemoteScroll = true
        if hadHint { onHintChange?(nil) }
        render()
        observe("subtitle_cleared", at: HostClock.now())
    }

    func setAnalysisConfiguration(_ id: UInt64) {
        guard analysisConfiguration != id else { return }
        analysisConfiguration = id
        resetRemoteScroll = true
        presentedFinals = []; presentedDraft = nil
        observe("configuration_reset", at: HostClock.now())
    }

    private func render(at now: HostTime = HostClock.now(), forceLayout: Bool = false) {
        // Keep transient recognition/translation changes together. Finals use their own
        // board cadence and never wait for this preview clock; obsolete previews clear at once.
        if now >= lastPreviewRenderAt, now - lastPreviewRenderAt >= Self.previewInterval {
            if renderedSource != liveSource || renderedDraft != board.draft {
                renderedSource = liveSource
                renderedDraft = board.draft
                lastPreviewRenderAt = now
            }
        }
        if liveSource.isEmpty { renderedSource = "" }
        if board.draft == nil { renderedDraft = nil }
        let lines = board.finals
        var nextLines: [String] = []
        for index in 0..<max(2, lines.count) {
            let line = index < lines.count ? lines[index] : nil
            nextLines += [line?.source ?? "", line?.display ?? ""]
        }
        nextLines += [renderedSource, renderedDraft?.text ?? ""]
        if nextLines != displayedLines || forceLayout || resetRemoteScroll {
            displayedLines = nextLines
            let source = NSMutableAttributedString(string: "")
            let translation = NSMutableAttributedString(string: "")
            let sourceFont = NSFont.systemFont(ofSize: max(11, max(12, baseFontSize * 0.65) * textScale))
            let targetFont = NSFont.systemFont(ofSize: fontSize, weight: .medium)
            let draftFont = NSFont.systemFont(ofSize: max(12, max(14, baseFontSize * 0.88) * textScale))
            func append(_ text: String, to output: NSMutableAttributedString, font: NSFont, color: NSColor) {
                guard !text.isEmpty else { return }
                if output.length > 0 { output.append(NSAttributedString(string: "\n")) }
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byWordWrapping
                paragraph.alignment = presentation == .video ? .center : .left
                paragraph.paragraphSpacing = 12
                output.append(NSAttributedString(string: text, attributes: [
                    .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
                ]))
            }
            for line in lines {
                append(line.source, to: source, font: sourceFont, color: NSColor(white: 0.65, alpha: 1))
                append(line.display, to: translation, font: targetFont, color: .white)
            }
            append(renderedSource, to: source, font: sourceFont, color: NSColor(white: 0.65, alpha: 1))
            if let renderedDraft {
                append(renderedDraft.text, to: translation, font: draftFont, color: NSColor(white: 0.68, alpha: 1))
            }
            remoteColumns.setText(source: source, translation: translation, resetScroll: resetRemoteScroll)
            resetRemoteScroll = false
        }
        // Text only reflows inside its own cells; it never determines the window or row heights.
        if forceLayout { layout() }
        recordPresentation()
    }

    private func recordPresentation() {
        guard subtitlesRequested, panel.isVisible, !remoteColumns.hasPendingText else { return }
        let now = HostClock.now()
        // Log actual label changes after board pacing, including revisions, not timer ticks or
        // font/layout refreshes. This is AppKit submission time, not a display hardware timestamp.
        for line in board.finals where !presentedFinals.contains(line) {
            observe("subtitle_displayed", at: now, line: line, kind: "final")
        }
        for line in presentedFinals where !board.finals.contains(where: { $0.sentence == line.sentence }) {
            observe("subtitle_removed", at: now, line: line, kind: "final")
        }
        if let draft = renderedDraft, draft != presentedDraft {
            observe("subtitle_displayed", at: now, line: draft, kind: "draft")
        } else if renderedDraft == nil, let draft = presentedDraft {
            observe("subtitle_removed", at: now, line: draft, kind: "draft")
        }
        presentedFinals = board.finals; presentedDraft = renderedDraft
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
        let hasSpeech = presentation != .video && speechHeight > 0
        let hasRemoteHeading = presentation != .video && subtitlesRequested
        let hasReadingArea = subtitlesRequested || hasSpeech
        let phoneFooterHeight: CGFloat = showsPhoneFooter ? PhoneSubtitleFooterView.height : 0
        let footerContentHeight = statusHeight + phoneFooterHeight + (statusHeight > 0 && showsPhoneFooter ? 8 : 0)
        let footerSpace = footerContentHeight > 0 ? footerContentHeight + (hasReadingArea ? 12 : 0) : 0
        let sectionChrome: CGFloat = 24 + (hasRemoteHeading ? 24 : 0) + (hasSpeech ? 24 : 0)
            + (subtitlesRequested && hasSpeech ? 22 : 0) + footerSpace
        let minHeight: CGFloat = hasReadingArea
            ? min(maxHeight, max(140, sectionChrome + (subtitlesRequested && hasSpeech ? 80 : 48)))
            : max(24, footerContentHeight + 24)
        panel.contentMinSize = NSSize(width: min(minimumWidth, width), height: minHeight)
        panel.contentMaxSize = NSSize(width: max(280, visible.width - 40), height: maxHeight)
        // Each presentation has its own fixed reading size. Status-only mode temporarily
        // collapses to a strip without overwriting that mode's saved reading dimensions.
        let height = hasReadingArea
            ? min(maxHeight, max(minHeight, manualContentSize?.height ?? defaultContentSize.height))
            : minHeight
        let budget = max(0, height - sectionChrome)
        let remoteHeight = subtitlesRequested ? (hasSpeech ? budget * 0.55 : budget) : 0
        let localHeight = hasSpeech ? budget - remoteHeight : 0
        var top: CGFloat = 12
        remoteHeading.isHidden = !hasRemoteHeading
        remoteColumns.isHidden = !subtitlesRequested
        speechHeading.isHidden = !hasSpeech
        speechView?.isHidden = !hasSpeech
        divider.isHidden = !subtitlesRequested || !hasSpeech
        if subtitlesRequested {
            if hasRemoteHeading {
                remoteHeading.frame = NSRect(x: 16, y: top, width: width - 32, height: 18)
                top += 24
            }
            remoteColumns.frame = NSRect(x: 16, y: top, width: width - 32, height: remoteHeight)
            remoteColumns.layoutSubtreeIfNeeded()
            top += remoteHeight
        }
        if hasSpeech {
            if subtitlesRequested {
                divider.frame = NSRect(x: 16, y: top + 10, width: width - 32, height: 1)
                top += 22
            }
            speechHeading.frame = NSRect(x: 16, y: top, width: width - 32, height: 18)
            top += 24
            speechView?.frame = NSRect(x: 16, y: top, width: width - 32, height: localHeight)
            speechView?.layoutSubtreeIfNeeded()
        }
        let size = NSSize(width: width, height: height)
        let old = panel.frame
        let oldSize = panel.contentRect(forFrameRect: old).size
        let sizeChanged = abs(oldSize.width - size.width) > 0.5 || abs(oldSize.height - size.height) > 0.5
        if sizeChanged { panel.setContentSize(size) }
        content.frame = NSRect(origin: .zero, size: size)
        backgroundEffect.frame = content.bounds
        statusView?.isHidden = statusHeight <= 0
        statusView?.frame = NSRect(x: 16, y: size.height - 12 - footerContentHeight, width: width - 32, height: statusHeight)
        phoneFooter.isHidden = !showsPhoneFooter
        phoneFooter.frame = NSRect(x: 16, y: size.height - 12 - phoneFooterHeight, width: width - 32, height: phoneFooterHeight)
        phoneFooter.layoutSubtreeIfNeeded()
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
        if subtitlesRequested || (presentation != .video && speechHeight > 0) || statusHeight > 0 || showsPhoneFooter {
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else if panel.isVisible { panel.orderOut(nil) }
    }
    var isVisible: Bool { subtitlesRequested && panel.isVisible }
    var isWindowVisible: Bool { panel.isVisible }
    var speechIsVisible: Bool { presentation != .video && speechHeight > 0 && panel.isVisible }
    var statusIsVisible: Bool { statusHeight > 0 && panel.isVisible }

    private func poll() {
        let now = HostClock.now()
        let advanced = board.advance(at: now)
        let previewPending = liveSource != renderedSource || board.draft != renderedDraft
        let previewDue = now >= lastPreviewRenderAt && now - lastPreviewRenderAt >= Self.previewInterval
        if advanced || (previewPending && previewDue) { render(at: now) }
        else { recordPresentation() }
    }

    private func userResized() {
        guard !isLayingOut else { return }
        let resized = panel.contentRect(forFrameRect: panel.frame).size
        let hasReadingArea = subtitlesRequested || (presentation != .video && speechHeight > 0)
        manualContentSize = NSSize(width: resized.width, height: hasReadingArea
                                   ? resized.height : (manualContentSize?.height ?? defaultContentSize.height))
        render(forceLayout: true)
        onAppearanceChange?()
        if let screen = panel.screen, let savedSize = manualContentSize {
            UserDefaults.standard.set(NSStringFromSize(savedSize), forKey: sizeKey(for: screen))
        }
        savePosition()
    }

    private func screenID(_ screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.stringValue ?? "main"
    }
    private func key(for screen: NSScreen) -> String {
        "ui.subtitleOrigin.\(presentation.rawValue).\(screenID(screen))"
    }
    private func sizeKey(for screen: NSScreen) -> String {
        "ui.subtitleSize.\(presentation.rawValue).\(screenID(screen))"
    }
    private func savedGeometry(_ component: String, for screen: NSScreen) -> String? {
        let key = "ui.subtitle\(component).\(presentation.rawValue).\(screenID(screen))"
        if let value = UserDefaults.standard.string(forKey: key) { return value }
        // The former shared geometry belongs only to meeting mode. Other modes start independently.
        guard presentation == .meeting,
              let value = UserDefaults.standard.string(forKey: "ui.subtitle\(component).\(screenID(screen))") else { return nil }
        UserDefaults.standard.set(value, forKey: key)
        return value
    }
    private func loadSize(for screen: NSScreen) {
        manualContentSize = nil
        guard let saved = savedGeometry("Size", for: screen) else { return }
        let size = NSSizeFromString(saved)
        if size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 { manualContentSize = size }
    }
    private func placeInitially(on preferredScreen: NSScreen? = nil) {
        guard let screen = preferredScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        if let saved = savedGeometry("Origin", for: screen) {
            let point = NSPointFromString(saved)
            if point.x.isFinite, point.y.isFinite, screen.visibleFrame.insetBy(dx: -40, dy: -40).contains(point) {
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
    var shownLines: [String] { displayedLines }
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

/// Shared by the live phone window and its static settings preview.
final class PhoneSubtitleFooterView: NSView {
    static let height: CGFloat = 28
    var openPhone: (() -> Void)?
    var endTranslation: (() -> Void)?
    private let contextLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: String(localized: "打开 Phone"), target: nil, action: nil)
    private let endButton = NSButton(title: String(localized: "结束同传"), target: nil, action: nil)
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        contextLabel.font = .systemFont(ofSize: 11)
        contextLabel.textColor = .secondaryLabelColor
        contextLabel.lineBreakMode = .byTruncatingTail
        contextLabel.maximumNumberOfLines = 1
        addSubview(contextLabel)
        for button in [openButton, endButton] {
            button.controlSize = .small
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.target = self
            button.setButtonType(.momentaryPushIn)
            addSubview(button)
        }
        openButton.action = #selector(openPhonePressed)
        openButton.toolTip = String(localized: "在 Phone 中拨号、接听或挂断电话。")
        endButton.action = #selector(endTranslationPressed)
        endButton.toolTip = String(localized: "结束 TalkTalk 同传并还原麦克风；电话仍由 Phone 管理。")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setContext(_ text: String) {
        contextLabel.stringValue = text
        contextLabel.toolTip = text
    }

    func setActionsEnabled(_ enabled: Bool) {
        openButton.isEnabled = enabled
        endButton.isEnabled = enabled
    }

    override func layout() {
        super.layout()
        let endWidth = max(78, endButton.fittingSize.width)
        let openWidth = max(90, openButton.fittingSize.width)
        let buttonHeight: CGFloat = 24
        let y = max(0, (bounds.height - buttonHeight) / 2)
        endButton.frame = NSRect(x: bounds.width - endWidth, y: y, width: endWidth, height: buttonHeight)
        openButton.frame = NSRect(x: endButton.frame.minX - 8 - openWidth, y: y, width: openWidth, height: buttonHeight)
        contextLabel.frame = NSRect(x: 0, y: max(0, (bounds.height - 16) / 2),
                                    width: max(0, openButton.frame.minX - 12), height: 16)
    }

    @objc private func openPhonePressed() { openPhone?() }
    @objc private func endTranslationPressed() { endTranslation?() }
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
