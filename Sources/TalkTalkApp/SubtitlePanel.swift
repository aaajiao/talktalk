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
    private let panel: SubtitleWindow
    private let content = ConversationContentView()
    private let backgroundEffect = NSVisualEffectView()
    private let remoteColumns = ConversationColumnsView()
    private let videoCaptions = VideoSubtitleView()
    private var videoBoard = VideoSubtitleBoard()
    private var renderedVideoCue: VideoSubtitleBoard.Cue?
    private var speechView: NSView?
    private let divider = NSBox()
    /// Shared titlebar controls (redesign §3); PTTHUD supplies voice, issue and key state.
    let titlebar = SubtitleTitlebarView()
    private let titleView = SubtitleTitleView()
    private let titlebarAccessory = NSTitlebarAccessoryViewController()
    private let sceneAccessory = NSTitlebarAccessoryViewController()
    private var titlebarVoice: VoiceState?
    private var titlebarIssue: IssueSlot?
    private var titlebarKey: TitlebarKey?
    private var sourceName: String?
    private var titlebarAccessoryInstalled = false
    private var phoneContext: String?
    private var phoneActionsEnabled = true
    private var sessionActionsActive = false
    private var sessionActionsEnabled = true
    private var remoteLanguageTitle = String(localized: "英语")
    private var displayedLines = Array(repeating: "", count: 6)
    private var resetRemoteScroll = false
    private(set) var board = SubtitleBoard(maxCharactersPerSecond: 9, retention: .meeting)
    private(set) var baseFontSize: CGFloat = 22
    /// Reading sizes come from the shared typography tokens (redesign §2).
    var conversationTypography: ConversationTypography {
        ConversationTypography(base: Double(baseFontSize), width: Double(contentWidth))
    }
    var videoTypography: VideoCaptionTypography {
        VideoCaptionTypography(base: Double(baseFontSize), width: Double(contentWidth))
    }
    var fontSize: CGFloat {
        presentation == .video ? videoTypography.translation.size : conversationTypography.remoteTranslation.size
    }
    private var backgroundOpacity: CGFloat = 0.85
    private var manualContentSize: NSSize?
    private var isLayingOut = false
    private var subtitlesRequested = false
    private var speechHeight: CGFloat = 0
    private var speechHasLocalContent = false
    private var statusVisible: Bool { titlebarVoice != nil || titlebarIssue != nil }
    var onPresentationChange: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    var onHintChange: ((String?) -> Void)?
    var openPhone: (() -> Void)?
    var endPhoneTranslation: (() -> Void)?
    var scene: SubtitleScene {
        switch presentation {
        case .meeting: .meeting
        case .phone: .phone
        case .video: .video
        }
    }
    private var liveSource = ""
    private var renderedSource = ""
    private var renderedDraft: SubtitleBoard.Line?
    private var lastPreviewRenderAt: HostTime = 0
    private static let previewInterval: HostTime = 500_000_000
    private var timer: Timer?
    private var moveObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private var restoreObserver: NSObjectProtocol?
    var analysisRecorder: SubtitleAnalysisRecorder?
    private var analysisConfiguration: UInt64 = 0
    private var presentedFinals: [SubtitleBoard.Line] = []
    private var presentedDraft: SubtitleBoard.Line?
    private var presentedVideoIdentity: SubtitleBoard.Line?
    var frame: NSRect { panel.frame }
    var screen: NSScreen? { panel.screen }
    private var defaultContentSize: NSSize {
        presentation == .video ? NSSize(width: 960, height: 180) : NSSize(width: 760, height: 480)
    }
    private var minimumWidth: CGFloat { presentation == .video ? 640 : 480 }
    private var showsPhoneActions: Bool { presentation == .phone && phoneContext != nil }
    private var hasWindowContent: Bool {
        subtitlesRequested || (presentation != .video && speechHeight > 0) || statusVisible || sessionActionsActive || showsPhoneActions
    }
    var contentWidth: CGFloat {
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame.width ?? 1440
        return min(max(minimumWidth, manualContentSize?.width ?? defaultContentSize.width), max(280, visible - 40))
    }

    init() {
        panel = SubtitleWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 150),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.title = String(localized: "TalkTalk · 会议同传")
        panel.identifier = NSUserInterfaceItemIdentifier("TalkTalkConversation")
        panel.appearance = NSAppearance(named: .darkAqua)
        // The leading accessory draws the scene title; the window title remains for AX/menus.
        panel.titleVisibility = .hidden
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.toolTip = String(localized: "隐藏字幕，同传继续")
        panel.standardWindowButton(.miniaturizeButton)?.toolTip = String(localized: "最小化字幕，同传继续")
        panel.animationBehavior = .none
        backgroundEffect.material = .hudWindow
        backgroundEffect.blendingMode = .behindWindow
        backgroundEffect.state = .active
        backgroundEffect.autoresizingMask = [.width, .height]
        content.addSubview(backgroundEffect)

        content.addSubview(remoteColumns)
        content.addSubview(videoCaptions)
        videoCaptions.isHidden = true
        divider.boxType = .separator
        content.addSubview(divider)
        titlebar.onPhone = { [weak self] in self?.openPhone?() }
        titlebar.onLayoutChange = { [weak self] in self?.updateTitlebarActions() }
        titlebarAccessory.layoutAttribute = .trailing
        titlebarAccessory.view = titlebar
        sceneAccessory.layoutAttribute = .leading
        sceneAccessory.view = titleView
        panel.addTitlebarAccessoryViewController(sceneAccessory)
        updateWindowTitle()
        updateRemoteHeadings()
        panel.contentView = content
        remoteColumns.onDisplayedTextChange = { [weak self] in self?.recordPresentation() }
        videoCaptions.onDisplayedTextChange = { [weak self] in self?.recordPresentation() }
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
        restoreObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didDeminiaturizeNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.panel.didRestoreFromDock()
                    if self.presentation == .video {
                        self.renderVideo(at: HostClock.now(), forceLayout: true)
                        self.videoCaptions.resetReadingTime(at: Double(HostClock.now()) / 1_000_000_000)
                    }
                    self.recordPresentation()
                }
            }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateBackground()
                    self?.updateTitlebarActions()
                    self?.onAppearanceChange?()
                }
            }
    }

    isolated deinit {
        timer?.invalidate()
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
        if let restoreObserver { NotificationCenter.default.removeObserver(restoreObserver) }
    }

    func setPresentation(_ value: Presentation) {
        guard value != presentation else { return }
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        if panel.isVisible { savePosition() }
        presentation = value
        sourceName = nil
        if value != .phone { phoneContext = nil }
        updateTitlebarActions()
        clear()
        board = SubtitleBoard(maxCharactersPerSecond: 9, retention: value == .video ? nil : .meeting)
        updateWindowTitle()
        updateRemoteHeadings()
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

    /// Phone owns dialing and the actual call. Its opener shares the compact titlebar;
    /// explanatory context stays out of the reading area.
    func setPhoneContext(_ text: String?) {
        guard phoneContext != text else { return }
        phoneContext = text
        updateTitlebarActions()
        updateWindowVisibility()
    }

    func setPhoneActionsEnabled(_ enabled: Bool) {
        phoneActionsEnabled = enabled
        updateTitlebarActions()
    }

    /// HUD owns voice, issue and key semantics; the panel adds scene, source, Phone and end.
    func setTitlebarStatus(voice: VoiceState?, issue: IssueSlot?, key: TitlebarKey?) {
        guard titlebarVoice != voice || titlebarIssue != issue || titlebarKey != key else { return }
        let wasVisible = statusVisible
        titlebarVoice = voice; titlebarIssue = issue; titlebarKey = key
        updateTitlebarActions()
        if wasVisible != statusVisible { updateWindowVisibility() }
    }

    /// The same content the titlebar draws, for previews and smoke checks.
    var titlebarContent: SubtitleTitlebarContent {
        SubtitleTitlebarContent(scene: scene, source: sourceName, voice: titlebarVoice, issue: titlebarIssue,
                                key: titlebarKey, showsPhone: showsPhoneActions,
                                phoneEnabled: phoneActionsEnabled && sessionActionsEnabled,
                                showsEnd: sessionActionsActive, endEnabled: sessionActionsEnabled)
    }

    func setSessionActions(active: Bool, enabled: Bool = true) {
        guard sessionActionsActive != active || sessionActionsEnabled != enabled else { return }
        sessionActionsActive = active
        sessionActionsEnabled = enabled
        updateTitlebarActions()
        updateWindowVisibility()
    }

    func setSourceName(_ name: String?) {
        guard sourceName != name else { return }
        sourceName = name
        updateWindowTitle()
    }

    private func updateWindowTitle() {
        let title = scene.title
        let source = titlebarContent.sourceTitle
        panel.title = source.map { String(localized: "\(title) · \($0)") } ?? title
        titleView.apply(scene: scene, source: source)
        updateTitlebarActions()
    }

    func setRemoteLanguageTitle(_ title: String) {
        guard remoteLanguageTitle != title else { return }
        remoteLanguageTitle = title
        updateRemoteHeadings()
    }

    private func updateRemoteHeadings() {
        remoteColumns.setHeadings(source: String(localized: "对方 · \(remoteLanguageTitle)"),
                                  sourceSymbol: "person", translation: String(localized: "中文"))
    }

    /// Traffic lights plus margins before the leading accessory, and after the trailing one.
    private static let titlebarChrome: CGFloat = 78 + 12 + 16

    private func updateTitlebarActions() {
        let content = titlebarContent
        let width = Double(contentWidth)
        let reserved = Double(Self.titlebarChrome + titleView.minimumWidth)
        let compaction = TitlebarCompaction.choose(windowWidth: width, reservedLeading: reserved) {
            Double(titlebar.measure(content, $0))
        }
        titlebar.apply(content, compaction: compaction)
        // The source name yields first: the leading title takes only the remaining width.
        titleView.setWidth(min(titleView.naturalWidth,
                               max(titleView.minimumWidth, contentWidth - Self.titlebarChrome - titlebar.frame.width)))
        let wanted = titlebar.hasItems
        guard wanted != titlebarAccessoryInstalled else { return }
        if wanted {
            panel.addTitlebarAccessoryViewController(titlebarAccessory)
        } else if let index = panel.titlebarAccessoryViewControllers.firstIndex(where: { $0 === titlebarAccessory }) {
            panel.removeTitlebarAccessoryViewController(at: index)
        }
        titlebarAccessoryInstalled = wanted
    }

    /// Scene opacity after Increase Contrast (at least 0.95).
    private var effectiveOpacity: CGFloat {
        CGFloat(SubtitleTokens.effectiveOpacity(Double(backgroundOpacity),
                                                increaseContrast: SubtitleStyle.Display.current.increaseContrast))
    }

    private func updateBackground() {
        let display = SubtitleStyle.Display.current
        let opacity = effectiveOpacity
        let opaque = display.reduceTransparency || opacity >= 1
        panel.isOpaque = opaque
        panel.backgroundColor = opaque ? .windowBackgroundColor : .clear
        backgroundEffect.isHidden = opaque
        // This view is a background sibling: labels, buttons and scrolling content keep alpha 1.
        backgroundEffect.alphaValue = opacity
        panel.invalidateShadow()
        render(forceLayout: true)
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

    func apply(_ update: SubtitleUpdate) {
        let now = HostClock.now()
        if presentation == .video {
            applyVideo(update, at: now)
            return
        }
        let previousPending = board.pendingFinalSentenceIDs
        let previousSource = liveSource
        if case .source(let text) = update { liveSource = text }
        let changed = board.apply(update, at: now)
        switch update {
        case let .final(sentence, text, source, approx, numberWarning):
            observe("subtitle_queued", at: now,
                    line: .init(sentence: sentence, text: text, source: source, approx: approx, numberWarning: numberWarning), kind: "final")
        case let .draft(sentence, text, source):
            observe("subtitle_queued", at: now,
                    line: .init(sentence: sentence, text: text, source: source, approx: false, numberWarning: false), kind: "draft")
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
        videoBoard.clear(); renderedVideoCue = nil
        videoCaptions.setCaption(source: NSAttributedString(string: ""), translation: NSAttributedString(string: ""),
                                 sentence: nil, isFinal: false, at: Double(HostClock.now()) / 1_000_000_000)
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
        presentedVideoIdentity = nil
        observe("configuration_reset", at: HostClock.now())
    }

    private func render(at now: HostTime = HostClock.now(), forceLayout: Bool = false) {
        if presentation == .video {
            renderVideo(at: now, forceLayout: forceLayout)
            return
        }
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
            let typography = conversationTypography
            let display = SubtitleStyle.Display.current
            let shadow = SubtitleStyle.readingShadow(opacity: Double(effectiveOpacity))
            // Draft and final translations share size and weight; only the colour differs.
            func append(_ text: String, to output: NSMutableAttributedString, role: ConversationTypography.Role,
                        color: SubtitleTokens.Color) {
                guard !text.isEmpty else { return }
                if output.length > 0 { output.append(NSAttributedString(string: "\n")) }
                let paragraph = SubtitleStyle.paragraph(role, alignment: presentation == .video ? .center : .left)
                paragraph.paragraphSpacing = 12
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: SubtitleStyle.font(role), .foregroundColor: SubtitleStyle.color(color, display: display),
                    .paragraphStyle: paragraph,
                ]
                if let shadow { attributes[.shadow] = shadow }
                output.append(NSAttributedString(string: text, attributes: attributes))
            }
            for line in lines {
                append(line.source, to: source, role: typography.source, color: .textSource)
                append(line.display, to: translation, role: typography.remoteTranslation, color: .textPrimary)
            }
            append(renderedSource, to: source, role: typography.source, color: .textSourceLive)
            if let renderedDraft {
                append(renderedDraft.text, to: translation, role: typography.remoteTranslation, color: .textDraft)
            }
            remoteColumns.setText(source: source, translation: translation, resetScroll: resetRemoteScroll)
            resetRemoteScroll = false
        }
        // Text only reflows inside its own cells; it never determines the window or row heights.
        if forceLayout { layout() }
        recordPresentation()
    }

    private var videoSourceFont: NSFont { SubtitleStyle.font(videoTypography.source) }
    private var videoTranslationFont: NSFont { SubtitleStyle.font(videoTypography.translation) }

    private func applyVideo(_ update: SubtitleUpdate, at now: HostTime) {
        let previousPending = videoBoard.pendingSentenceIDs
        var droppedSentence: UInt64?
        if case .source(let text) = update { liveSource = text }
        let changed = videoBoard.apply(update)
        switch update {
        case let .final(sentence, text, source, approx, warning):
            observe("subtitle_queued", at: now,
                    line: .init(sentence: sentence, text: text, source: source, approx: approx, numberWarning: warning), kind: "final")
        case let .draft(sentence, text, source):
            observe("subtitle_queued", at: now,
                    line: .init(sentence: sentence, text: text, source: source, approx: false, numberWarning: false), kind: "draft")
        case let .dropped(sentence):
            droppedSentence = sentence
            if changed { liveSource = "" }
            observe("subtitle_dropped", at: now,
                    line: .init(sentence: sentence, text: "", approx: false, numberWarning: false))
        case .source: break
        }
        if videoBoard.current == nil { _ = videoBoard.advance() }
        for sentence in previousPending where !videoBoard.pendingSentenceIDs.contains(sentence)
            && videoBoard.current?.line.sentence != sentence && sentence != droppedSentence {
            observe("subtitle_discarded", at: now,
                    line: .init(sentence: sentence, text: "", approx: false, numberWarning: false), kind: "pacing_overflow")
        }
        renderVideo(at: now)
    }

    private func renderVideo(at now: HostTime, forceLayout: Bool = false) {
        // Defer hidden updates so corrections cannot be credited as read while off screen.
        guard isWindowVisible else {
            if forceLayout { layout() }
            return
        }
        let cue = videoBoard.current
        let newSentence = cue?.line.sentence != renderedVideoCue?.line.sentence
        let finalChanged = cue?.isFinal == true && cue != renderedVideoCue
        let previewDue = now >= lastPreviewRenderAt && now - lastPreviewRenderAt >= Self.previewInterval
        guard forceLayout || newSentence || finalChanged || previewDue else { return }
        let source = cue?.line.source ?? liveSource
        let translation = cue?.line.display ?? ""
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let display = SubtitleStyle.Display.current
        var sourceAttributes: [NSAttributedString.Key: Any] = [
            .font: videoSourceFont, .foregroundColor: SubtitleStyle.color(.videoSource, display: display),
            .paragraphStyle: paragraph
        ]
        var targetAttributes: [NSAttributedString.Key: Any] = [
            .font: videoTranslationFont,
            .foregroundColor: cue?.isFinal == true ? NSColor.white : SubtitleStyle.white(0.80),
            .paragraphStyle: paragraph
        ]
        if let shadow = SubtitleStyle.readingShadow(opacity: Double(effectiveOpacity)) {
            sourceAttributes[.shadow] = shadow
            targetAttributes[.shadow] = shadow
        }
        let sourceText = NSAttributedString(string: source, attributes: sourceAttributes)
        let targetText = NSAttributedString(string: translation, attributes: targetAttributes)
        renderedVideoCue = cue
        renderedSource = liveSource
        lastPreviewRenderAt = now
        videoCaptions.setCaption(source: sourceText, translation: targetText,
                                 sentence: cue?.line.sentence, isFinal: cue?.isFinal ?? false,
                                 at: Double(now) / 1_000_000_000)
        resetRemoteScroll = false
        if forceLayout { layout() }
        recordPresentation()
    }

    /// Only the page actually assigned to the video view counts as displayed. Pending cues
    /// and hidden portions of a long sentence must not masquerade as visible subtitles.
    private func recordVideoPresentation() {
        displayedLines = [videoCaptions.displayedSource, videoCaptions.displayedTranslation, "", "", "", ""]
        let now = HostClock.now()
        var finals: [SubtitleBoard.Line] = []
        var draft: SubtitleBoard.Line?
        if let cue = renderedVideoCue {
            let visible = SubtitleBoard.Line(sentence: cue.line.sentence,
                text: videoCaptions.displayedTranslation, source: videoCaptions.displayedSource,
                approx: cue.line.approx, numberWarning: cue.line.numberWarning)
            if cue.isFinal { finals = [visible] } else { draft = visible }
        }
        for line in finals where !presentedFinals.contains(line) {
            observe("subtitle_displayed", at: now, line: line, kind: "final", cueIdentity: renderedVideoCue?.line)
        }
        for line in presentedFinals where !finals.contains(where: { $0.sentence == line.sentence }) {
            observe("subtitle_removed", at: now, line: line, kind: "final", cueIdentity: presentedVideoIdentity)
        }
        if let draft, draft != presentedDraft {
            observe("subtitle_displayed", at: now, line: draft, kind: "draft", cueIdentity: renderedVideoCue?.line)
        } else if draft == nil, let old = presentedDraft {
            observe("subtitle_removed", at: now, line: old, kind: "draft", cueIdentity: presentedVideoIdentity)
        }
        presentedFinals = finals; presentedDraft = draft
        presentedVideoIdentity = renderedVideoCue?.line
    }

    private func recordPresentation() {
        guard subtitlesRequested, isWindowVisible else { return }
        if presentation == .video { recordVideoPresentation(); return }
        guard !remoteColumns.hasPendingText else { return }
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

    private func observe(_ event: String, at time: HostTime, line: SubtitleBoard.Line? = nil, kind: String? = nil,
                         cueIdentity: SubtitleBoard.Line? = nil) {
        analysisRecorder?.recordPanel(event, configuration: analysisConfiguration, at: time,
                                      line: line, kind: kind, visible: subtitlesRequested && isWindowVisible,
                                      pendingFinals: presentation == .video ? videoBoard.pendingFinalSentenceIDs : board.pendingFinalSentenceIDs,
                                      pendingDraft: presentation == .video ? videoBoard.pendingDraftSentenceIDs.last : board.pendingDraftSentenceID,
                                      cueIdentity: cueIdentity)
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
        let hasReadingArea = subtitlesRequested || hasSpeech
        let rowGap: CGFloat = subtitlesRequested && hasSpeech ? 22 : 0
        let sectionChrome: CGFloat = 24 + rowGap
        let minimumReading = presentation == .video
            ? VideoSubtitleView.minimumReadingHeight(sourceFont: videoSourceFont, translationFont: videoTranslationFont)
            : (subtitlesRequested && hasSpeech ? 80 : 48)
        let minHeight: CGFloat = hasReadingArea
            ? min(maxHeight, max(140, sectionChrome + minimumReading))
            : 0
        panel.contentMinSize = NSSize(width: min(minimumWidth, width), height: minHeight)
        panel.contentMaxSize = NSSize(width: max(280, visible.width - 40), height: maxHeight)
        // Status-only mode collapses to the titlebar without changing saved reading sizes.
        let height = hasReadingArea
            ? min(maxHeight, max(minHeight, manualContentSize?.height ?? defaultContentSize.height))
            : minHeight
        let budget = max(0, height - sectionChrome)
        let remoteHeight = subtitlesRequested ? (hasSpeech ? budget / 2 : budget) : 0
        let localHeight = hasSpeech ? budget - remoteHeight : 0
        var top: CGFloat = 12
        remoteColumns.isHidden = !subtitlesRequested || presentation == .video
        videoCaptions.isHidden = !subtitlesRequested || presentation != .video
        speechView?.isHidden = !hasSpeech
        divider.isHidden = !subtitlesRequested || !hasSpeech
        if subtitlesRequested {
            if presentation == .video {
                videoCaptions.frame = NSRect(x: 16, y: top, width: width - 32, height: remoteHeight)
                videoCaptions.layoutSubtreeIfNeeded()
            } else {
                remoteColumns.frame = NSRect(x: 16, y: top, width: width - 32, height: remoteHeight)
                remoteColumns.layoutSubtreeIfNeeded()
            }
            top += remoteHeight
        }
        if hasSpeech {
            if subtitlesRequested {
                divider.frame = NSRect(x: 0, y: top + rowGap / 2, width: width, height: 1)
                top += rowGap
            }
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
        updateTitlebarActions()
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
            if presentation == .video {
                renderVideo(at: HostClock.now(), forceLayout: true)
                videoCaptions.resetReadingTime(at: Double(HostClock.now()) / 1_000_000_000)
            }
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
        if hasWindowContent {
            // Minimized is a user-owned presentation state, independent of subtitles being
            // enabled and of audio work. A status transition must never bring it back.
            guard !isMiniaturized, !panel.userHidden else { return }
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else {
            // Ending the last visible work removes its Dock thumbnail without flashing the
            // window on screen. Reusing this retained panel later starts a fresh presentation.
            if panel.isMiniaturized || panel.minimizationPending { panel.dismissMiniaturizedWindow() }
            else if panel.isVisible { panel.orderOut(nil) }
        }
    }

    var isMiniaturized: Bool { panel.userMinimized || panel.isMiniaturized || panel.minimizationPending }
    var canRestoreWindow: Bool { hasWindowContent && (isMiniaturized || panel.userHidden || !panel.isVisible) }

    /// A new session is an explicit start, unlike an ordinary update or a late failure notice.
    func prepareForNewSession() {
        if panel.isMiniaturized || panel.minimizationPending { panel.dismissMiniaturizedWindow() }
        panel.clearUserPresentationState()
        updateWindowVisibility()
    }

    /// Explicit user intent only: the menu and Dock can restore the existing reading views.
    /// Do not toggle the subtitle preference, restart a timer, or rebuild the transcript.
    func restoreWindow() {
        guard hasWindowContent else { return }
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        panel.deminiaturize(nil)
        panel.orderFrontRegardless()
        if presentation == .video {
            renderVideo(at: HostClock.now(), forceLayout: true)
            videoCaptions.resetReadingTime(at: Double(HostClock.now()) / 1_000_000_000)
        }
        recordPresentation()
    }

    var isVisible: Bool { subtitlesRequested && isWindowVisible }
    var isWindowVisible: Bool { panel.isVisible && !isMiniaturized && !panel.userHidden }
    var speechIsVisible: Bool { presentation != .video && speechHeight > 0 && isWindowVisible }
    var statusIsVisible: Bool { statusVisible && isWindowVisible }

    private func poll() {
        let now = HostClock.now()
        if presentation == .video {
            renderVideo(at: now)
            guard isWindowVisible else { return }
            let seconds = Double(now) / 1_000_000_000
            let pageChanged = videoCaptions.advance(at: seconds)
            if videoCaptions.canAdvance(at: seconds), videoBoard.advance() {
                renderVideo(at: now)
            } else if pageChanged { recordPresentation() }
            return
        }
        let advanced = board.advance(at: now)
        let previewPending = liveSource != renderedSource || board.draft != renderedDraft
        let previewDue = now >= lastPreviewRenderAt && now - lastPreviewRenderAt >= Self.previewInterval
        if advanced || (previewPending && previewDue) { render(at: now) }
        else { recordPresentation() }
    }

    private func userResized() {
        guard !isLayingOut, !isMiniaturized else { return }
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
        guard !isLayingOut, !isMiniaturized, let screen = panel.screen else { return }
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: key(for: screen))
    }

    var sharingTypeIsNone: Bool { panel.sharingType == .none }
    var collectionBehavior: NSWindow.CollectionBehavior { panel.collectionBehavior }
    var clickThrough: Bool { panel.ignoresMouseEvents }
    var canBecomeKey: Bool { panel.canBecomeKey }
    var isMovable: Bool { panel.isMovable && panel.isMovableByWindowBackground }
    var isResizable: Bool { panel.styleMask.contains(.resizable) }
    var isMiniaturizable: Bool { panel.styleMask.contains(.miniaturizable) }
    var isClosable: Bool { panel.styleMask.contains(.closable) }
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

private final class SubtitleWindow: NSPanel {
    private(set) var minimizationPending = false
    private(set) var userMinimized = false
    private(set) var userHidden = false
    private var dismissingMiniwindow = false
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Red close hides only the presentation. The owner still runs audio, translation and
    /// shortcuts; only the independent titlebar stop action ends that work.
    override func close() {
        if dismissingMiniwindow { super.close(); return }
        userHidden = true
        minimizationPending = false
        if isMiniaturized {
            dismissingMiniwindow = true
            super.close()
            dismissingMiniwindow = false
        } else { orderOut(nil) }
        AppActivation.minimizedPanelRestored(self)
    }

    override func miniaturize(_ sender: Any?) {
        guard !isMiniaturized, !minimizationPending else { return }
        minimizationPending = true
        userMinimized = true
        let needsDock = NSApp.activationPolicy() != .regular
        AppActivation.panelWillMiniaturize(self)
        // Menu-bar apps need a Dock presence for a native miniwindow. Give the activation
        // policy transition a main-runloop turn before asking AppKit to create it.
        if needsDock {
            DispatchQueue.main.async { [weak self] in self?.finishMiniaturizing() }
        } else { finishMiniaturizing() }
    }

    private func finishMiniaturizing() {
        guard minimizationPending else { return }
        super.miniaturize(nil)
        minimizationPending = false
        if !isMiniaturized { AppActivation.minimizedPanelRestored(self) }
    }

    override func deminiaturize(_ sender: Any?) {
        minimizationPending = false
        if !dismissingMiniwindow { userMinimized = false; userHidden = false }
        super.deminiaturize(sender)
        AppActivation.minimizedPanelRestored(self)
    }

    func didRestoreFromDock() {
        if !dismissingMiniwindow { userMinimized = false; userHidden = false }
        minimizationPending = false
        AppActivation.minimizedPanelRestored(self)
    }

    func clearUserPresentationState() { userMinimized = false; userHidden = false }

    func dismissMiniaturizedWindow() {
        minimizationPending = false
        dismissingMiniwindow = true
        close()
        dismissingMiniwindow = false
        // Keep the user's intent even after AppKit removes its miniwindow. Late notices
        // must not revive the panel after the active session has finished.
        userMinimized = true
        AppActivation.minimizedPanelRestored(self)
    }
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
