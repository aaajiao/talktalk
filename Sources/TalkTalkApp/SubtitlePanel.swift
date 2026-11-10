// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import TalkTalkCore
import TalkTalkSession
import TalkTalkSettingsUI

/// One non-activating window. Meeting and phone modes show one conversation timeline of pair
/// rows above the microphone status dock (redesign §4, §5); video mode has a compact subtitle
/// strip. Content and dock changes only split the fixed content area; they never resize it.
@MainActor
final class SubtitlePanel {
    enum Presentation: String { case meeting, phone, video }
    private(set) var presentation: Presentation = .meeting
    private let panel: SubtitleWindow
    private let content = ConversationContentView()
    private let backgroundEffect = NSVisualEffectView()
    private let conversation = ConversationTimelineView()
    private let dock = MicStatusDock()
    /// Remote pairs and my turns in arrival order; memory only, cleared with the session.
    private var timeline = ConversationTimeline()
    private var dockContent: MicStatusDock.Content?
    private var dockHeight: CGFloat = 0
    private var dockAnimation: (from: CGFloat, to: CGFloat, start: TimeInterval)?
    private var dockTimer: Timer?
    private var conversationSize = NSSize(width: 760, height: 480)
    private var localSpeechVisible = false
    private var remoteSilent = false
    /// "朗读新译文" (§4 无障碍), default off.
    var announcesNewTranslations = false
    private var announcedThrough: UInt64 = 0
    /// Video can show a late sentence after a newer one, which a watermark would never announce.
    private var announcedVideoFinals: Set<UInt64> = []
    /// Keycap, "修复…" / "详情" and the "暂未听到对方声音" placeholder open the details popover.
    var onDockAction: ((NSView) -> Void)?
    var onPlaceholderClick: ((NSView) -> Void)?
    private let videoCaptions = VideoSubtitleView()
    private var videoBoard = VideoSubtitleBoard()
    private var renderedVideoCue: VideoSubtitleBoard.Cue?
    private var videoDraftTail = VideoDraftTail()
    /// When the video captions stopped being on screen; that pause is not lag.
    private var videoHiddenSince: HostTime?
    /// Video-only preferences (redesign §6): caption style and block order.
    private(set) var videoCaptionStyle: VideoCaptionStyle = .default
    private(set) var videoCaptionArrangement: VideoCaptionArrangement = .default
    private var seenSkippedCount = 0
    /// The video captions trail the audio by more than 5 s. The titlebar/hover dot turns yellow
    /// from this (§6 视觉反馈).
    private(set) var videoLagging = false
    /// PTTHUD turns this into the "字幕落后" warning chip (`VideoStatusDot.lagChip`). Called only
    /// when lagging starts or ends, never for each new second.
    var onVideoLagChange: ((Bool) -> Void)?
    // All scenes share hover-only chrome; video retains its warning mark and position lock.
    private var hoverBar = VideoHoverBar()
    private var hoverTimer: Timer?
    private var chromeShown: Bool?
    #if TALKTALK_DEV
    private var previewPinsChrome = false
    #endif
    /// The hover bar became visible (PTTHUD shows a deferred popover then).
    var onTitlebarShown: (() -> Void)?
    var titlebarIsShown: Bool { chromeShown == true }
    /// Typography width while a live resize runs: the reading sizes depend on width, so they
    /// are frozen during the drag and applied once when it ends.
    private var liveResizeTypographyWidth: CGFloat?
    private var liveResizeObservers: [NSObjectProtocol] = []
    private var chromeGeneration = 0
    private let hoverStrip = SubtitleChromeView()
    private var isLayingOutChrome = false
    private let statusDot = VideoStatusDotView()
    private let lockIndicator = NSImageView()
    private let hintBubble = WindowHintView()
    private var hintTimer: Timer?
    private var hintCheck: DispatchWorkItem?
    private var heldPopovers = Set<ObjectIdentifier>()
    private var popoverObservers: [NSObjectProtocol] = []
    private var spaceObserver: NSObjectProtocol?
    private static let fullScreenHintKey = "ui.videoFullScreenHintShown"
    /// "锁定字幕位置（鼠标穿透）", saved for the video scene by AppState.
    private(set) var clickThroughLocked = false
    /// The hover bar's ⋯ menu asks the owner to lock; only the menu bar unlocks.
    var onLockRequest: (() -> Void)?
    /// The persistent dot opens the details popover.
    var onStatusDotClick: ((NSView) -> Void)?
    var onLanguage: ((NSView) -> Void)?
    private var quietDim = VideoQuietDim()
    /// Shared titlebar controls (redesign §3); PTTHUD supplies voice, issue and key state.
    let titlebar = SubtitleTitlebarView()
    private let titleView = SubtitleTitleView()
    private var titlebarVoice: VoiceState?
    private var titlebarIssue: IssueSlot?
    private var titlebarKey: TitlebarKey?
    private var sourceName: String?
    private var phoneContext: String?
    private var phoneActionsEnabled = true
    private var sessionActionsActive = false
    private var sessionActionsEnabled = true
    private var remoteLanguageTitle = String(appLocalized: "英语")
    private var translationLanguageTitle = String(appLocalized: "中文")
    private var listeningLanguages = ListenLanguageSelection()
    private var subtitleReadingRate: Int { Int(VideoCaptionPacing.charactersPerSecond(listeningLanguages.target)) }
    private var languageTitle: String?
    private var languageDetail: String?
    private var displayedLines = Array(repeating: "", count: 6)
    private(set) var board = SubtitleBoard(maxCharactersPerSecond: 9, retention: .meeting)
    private(set) var baseFontSize: CGFloat = 22
    /// Reading sizes come from the shared typography tokens (redesign §2).
    var conversationTypography: ConversationTypography {
        ConversationTypography(base: Double(baseFontSize), width: Double(typographyWidth))
    }
    var videoTypography: VideoCaptionTypography {
        VideoCaptionTypography(base: Double(baseFontSize), width: Double(typographyWidth))
    }
    private var typographyWidth: CGFloat { liveResizeTypographyWidth ?? contentWidth }
    var fontSize: CGFloat {
        presentation == .video ? videoTypography.translation.size : conversationTypography.remoteTranslation.size
    }
    private var backgroundOpacity: CGFloat = 0.85
    private var manualContentSize: NSSize?
    private var isLayingOut = false
    private var subtitlesRequested = false
    private var statusVisible: Bool { titlebarVoice != nil || titlebarIssue != nil }
    var onPresentationChange: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    var onHintChange: ((String?) -> Void)?
    var openPhone: (() -> Void)?
    /// The session window just closed: anything anchored to it (a details popover) goes too.
    var onSessionClosed: (() -> Void)?
    /// Only `beginSession` opens it; `endSession` closes it before any layout (redesign §9.2.2).
    private var presence = SubtitleWindowPresence()
    private var endInputSwitched = false
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
    /// VoiceOver does not move the pointer, so while it runs the controls stay shown.
    /// `accessibilityDisplayOptionsDidChange` does not fire for VoiceOver; KVO does.
    private var voiceOverObservation: NSKeyValueObservation?
    private var restoreObserver: NSObjectProtocol?
    var analysisRecorder: SubtitleAnalysisRecorder?
    private var analysisConfiguration: UInt64 = 0
    private var presentedFinals: [SubtitleBoard.Line] = []
    private var presentedDraft: SubtitleBoard.Line?
    private var presentedVideoIdentity: SubtitleBoard.Line?
    var frame: NSRect { panel.frame }
    var screen: NSScreen? { panel.screen }
    private var defaultContentSize: NSSize {
        presentation == .video
            ? NSSize(width: VideoCaptionLayout.defaultContentWidth, height: VideoCaptionLayout.defaultContentHeight)
            : NSSize(width: 760, height: 480)
    }
    private var minimumWidth: CGFloat { presentation == .video ? 640 : 480 }
    private var showsPhoneActions: Bool { presentation == .phone && phoneContext != nil }
    /// Meeting/phone conversation (timeline + dock): subtitles on, or my local speech shown.
    private var hasConversation: Bool { presentation != .video && (subtitlesRequested || localSpeechVisible) }
    private var hasWindowContent: Bool {
        presence.hasContent(subtitles: subtitlesRequested, conversation: hasConversation, status: statusVisible,
                            sessionActions: sessionActionsActive, scene: scene,
                            videoSource: videoBoard.current?.line.source ?? liveSource,
                            videoTranslation: videoBoard.current?.line.text ?? "")
    }
    var contentWidth: CGFloat {
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame.width ?? 1440
        return min(max(minimumWidth, manualContentSize?.width ?? defaultContentSize.width), max(280, visible - 40))
    }

    init() {
        panel = SubtitleWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 150),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.identifier = NSUserInterfaceItemIdentifier("TalkTalkConversation")
        // TalkTalk is an accessory app, inactive during a meeting: 结束's consequence lives in its
        // tooltip, which AppKit otherwise shows only in the active app.
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.appearance = NSAppearance(named: .darkAqua)
        // The leading accessory draws the scene title; the window title remains for AX/menus.
        panel.titleVisibility = .hidden
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        backgroundEffect.material = .hudWindow
        backgroundEffect.blendingMode = .behindWindow
        backgroundEffect.state = .active
        backgroundEffect.autoresizingMask = [.width, .height]
        content.addSubview(backgroundEffect)

        content.addSubview(conversation)
        content.addSubview(dock)
        conversation.isHidden = true
        dock.isHidden = true
        dock.onAction = { [weak self] anchor in self?.onDockAction?(anchor) }
        conversation.onPlaceholderClick = { [weak self] anchor in self?.onPlaceholderClick?(anchor) }
        content.addSubview(videoCaptions)
        videoCaptions.isHidden = true
        hoverStrip.install(title: titleView, actions: titlebar)
        hoverStrip.isHidden = true
        content.addSubview(hoverStrip)
        statusDot.isHidden = true
        statusDot.onPress = { [weak self] in self?.statusDotPressed() }
        content.addSubview(statusDot)
        titlebar.onStatusDot = { [weak self] anchor in self?.onStatusDotClick?(anchor) }
        titlebar.onFrameChange = { [weak self] in
            guard let self else { return }
            self.layoutVideoChrome()
        }
        lockIndicator.image = SubtitleStyle.symbol(SubtitleTokens.VoiceIcon.locked,
                                                   size: CGFloat(SubtitleClickThrough.indicatorSize), weight: .semibold)
        lockIndicator.imageScaling = .scaleNone
        // Legible on any frame: the reading shadow, as captions below 0.75 opacity.
        lockIndicator.wantsLayer = true
        let lockShadow = NSShadow()
        lockShadow.shadowColor = SubtitleStyle.nsColor(SubtitleTokens.readingShadow.color)
        lockShadow.shadowBlurRadius = SubtitleTokens.readingShadow.blur
        lockShadow.shadowOffset = NSSize(width: SubtitleTokens.readingShadow.offsetX, height: SubtitleTokens.readingShadow.offsetY)
        lockIndicator.shadow = lockShadow
        lockIndicator.setAccessibilityLabel(String(appLocalized: "字幕位置已锁定"))
        // The locked window takes no pointer events, so no tooltip can explain how to unlock.
        lockIndicator.setAccessibilityHelp(String(appLocalized: "鼠标会穿过字幕窗口；从菜单栏的 TalkTalk 菜单解锁"))
        lockIndicator.isHidden = true
        content.addSubview(lockIndicator)
        hintBubble.isHidden = true
        content.addSubview(hintBubble)
        content.onHover = { [weak self] inside in self?.pointerMoved(inside: inside) }
        hoverStrip.onHover = { [weak self] inside in self?.pointerMoved(inside: inside) }
        titlebar.onMore = { [weak self] anchor in self?.showMoreMenu(from: anchor) }
        titlebar.onLanguage = { [weak self] anchor in self?.onLanguage?(anchor) }
        titlebar.onPhone = { [weak self] in self?.openPhone?() }
        titlebar.onLayoutChange = { [weak self] in self?.updateTitlebarActions() }
        updateWindowTitle()
        updateRemoteHeadings()
        panel.contentView = content
        panel.interactiveTitlebar = hoverStrip
        conversation.onDisplayedRowsChange = { [weak self] in self?.displayedRowsChanged() }
        videoCaptions.onDisplayedTextChange = { [weak self] in self?.recordPresentation() }
        videoCaptions.onReadingBoundsChange = { [weak self] in
            self?.layoutVideoChrome()
            self?.updateTitlebarActions()
        }
        if let screen = rememberedScreen() ?? NSScreen.main ?? NSScreen.screens.first { loadSize(for: screen) }
        setFontSize(22)
        updateBackground()
        applyWindowChrome()
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
                        self.updateWindowVisibility()
                        guard self.hasWindowContent else { return }
                        self.renderVideo(at: HostClock.now(), forceLayout: true)
                        self.resetVideoReading()
                    }
                    self.windowShownAgain()
                    self.recordPresentation()
                }
            }
        panel.onPresentationHidden = { [weak self] in self?.windowHidden() }
        liveResizeObservers = [
            NotificationCenter.default.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: panel,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.liveResizeStarted() }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: panel,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.liveResizeEnded() }
            },
        ]
        for name in [NSPopover.didShowNotification, NSPopover.didCloseNotification] {
            let shown = name == NSPopover.didShowNotification
            popoverObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // Delivered on the main queue, so the popover is used on the main actor only.
                let popover = note.object as? NSPopover
                MainActor.assumeIsolated { if let popover { self?.popoverChanged(popover, shown: shown) } }
            })
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleFullScreenHintCheck() }
            }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateBackground()
                    self?.updateTitlebarActions()
                    self?.updateVideoChrome(animated: false)
                    self?.onAppearanceChange?()
                }
            }
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.new]) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.updateVideoChrome(animated: false) }
        }
    }

    isolated deinit {
        timer?.invalidate()
        dockTimer?.invalidate()
        hoverTimer?.invalidate()
        hintTimer?.invalidate()
        hintCheck?.cancel()
        popoverObservers.forEach { NotificationCenter.default.removeObserver($0) }
        liveResizeObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
        if let restoreObserver { NotificationCenter.default.removeObserver(restoreObserver) }
    }

    func setPresentation(_ value: Presentation) {
        guard value != presentation else { return }
        panel.cancelTitlebarInteraction()
        let currentScreen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        if panel.isVisible { savePosition() }
        presentation = value
        // Each scene returns to the display it was last on while that display is connected.
        let screen = rememberedScreen() ?? currentScreen
        sourceName = nil
        if value != .phone { phoneContext = nil }
        updateTitlebarActions()
        remoteSilent = false
        clear(includingMyTurns: true)
        board = SubtitleBoard(maxCharactersPerSecond: subtitleReadingRate, retention: value == .video ? nil : .meeting)
        updateWindowTitle()
        updateRemoteHeadings()
        applyWindowChrome()
        updateBackground()
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

    func setVideoCaptionStyle(_ style: VideoCaptionStyle) {
        guard videoCaptionStyle != style else { return }
        videoCaptionStyle = style
        updateBackground()
    }

    /// "译文在上" swaps the two blocks; bottom anchoring follows the lower one.
    func setVideoCaptionArrangement(_ arrangement: VideoCaptionArrangement) {
        guard videoCaptionArrangement != arrangement else { return }
        videoCaptionArrangement = arrangement
        updateVideoAppearance()
    }

    /// Style after Reduce Transparency (plates).
    var effectiveVideoCaptionStyle: VideoCaptionStyle {
        videoCaptionStyle.effective(reduceTransparency: SubtitleStyle.Display.current.reduceTransparency)
    }

    private func updateVideoAppearance() {
        let display = SubtitleStyle.Display.current
        videoCaptions.appearanceSettings = .init(style: effectiveVideoCaptionStyle, arrangement: videoCaptionArrangement,
                                                 opacity: effectiveOpacity, reduceTransparency: display.reduceTransparency,
                                                 reduceMotion: display.reduceMotion,
                                                 increaseContrast: display.increaseContrast)
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
        layoutVideoChrome()
        if wasVisible != statusVisible { updateWindowVisibility() }
    }

    /// The same content the titlebar draws, for previews and smoke checks.
    var titlebarContent: SubtitleTitlebarContent {
        SubtitleTitlebarContent(scene: scene, source: sourceName, voice: titlebarVoice, issue: titlebarIssue,
                                key: titlebarKey, showsPhone: showsPhoneActions,
                                phoneEnabled: phoneActionsEnabled && sessionActionsEnabled,
                                showsEnd: sessionActionsActive, endEnabled: sessionActionsEnabled,
                                endInputSwitched: endInputSwitched,
                                showsMore: presentation == .video && sessionActionsActive,
                                languageTitle: languageTitle, languageDetail: languageDetail)
    }

    /// TalkTalk holds the system default input: 结束's help names the raw-voice consequence.
    func setEndInputSwitched(_ on: Bool) {
        guard endInputSwitched != on else { return }
        endInputSwitched = on
        updateTitlebarActions()
    }

    func setSessionActions(active: Bool, enabled: Bool = true) {
        guard sessionActionsActive != active || sessionActionsEnabled != enabled else { return }
        sessionActionsActive = active
        sessionActionsEnabled = enabled
        updateTitlebarActions()
        updateWindowVisibility()
    }

    func refreshAppLanguage() {
        updateWindowTitle()
        updateRemoteHeadings()
        conversation.setPlaceholder(conversationPlaceholder)
        conversation.refreshAppLanguage()
        dock.refreshAppLanguage()
        videoCaptions.placeholder = videoPlaceholder
        videoCaptions.refreshAppLanguage()
        hintBubble.text = FullScreenSpaceHint.text
        lockIndicator.setAccessibilityLabel(String(appLocalized: "字幕位置已锁定"))
        lockIndicator.setAccessibilityHelp(String(appLocalized: "鼠标会穿过字幕窗口；从菜单栏的 TalkTalk 菜单解锁"))
        updateWindowControlHelp()
        updateTitlebarActions()
        // Layout keeps the current frame and each timeline/video reading position.
        content.needsLayout = true
    }

    func setSourceName(_ name: String?) {
        guard sourceName != name else { return }
        sourceName = name
        updateWindowTitle()
        if presentation == .video { videoCaptions.placeholder = videoPlaceholder }
        else { conversation.setPlaceholder(conversationPlaceholder) }
    }

    private func updateWindowTitle() {
        let title = scene.title
        let source = titlebarContent.sourceTitle
        panel.title = source.map { String(appLocalized: "\(title) · \($0)") } ?? title
        titleView.apply(scene: scene, source: source)
        updateTitlebarActions()
    }

    func setRemoteLanguageTitle(_ title: String) {
        guard remoteLanguageTitle != title else { return }
        remoteLanguageTitle = title
        updateRemoteHeadings()
    }

    func setLanguages(listening: ListenLanguageSelection, speaking: SpeakLanguageSelection?) {
        if listeningLanguages != listening {
            listeningLanguages = listening
            // A new direction gets new reading deadlines. The session reset clears remote
            // rows separately; my speaking timeline and its delivery facts stay intact.
            board = SubtitleBoard(maxCharactersPerSecond: subtitleReadingRate, retention: presentation == .video ? nil : .meeting)
        }
        remoteLanguageTitle = listening.source.title
        translationLanguageTitle = listening.target.title
        languageTitle = String(appLocalized: "\(listening.source.title) → \(listening.target.title)")
        // The language popover's own words: 对方说/原文 → 字幕.
        let listen = speaking == nil
            ? String(appLocalized: "原文：\(listening.source.title) → 字幕：\(listening.target.title)")
            : String(appLocalized: "对方说：\(listening.source.title) → 字幕：\(listening.target.title)")
        languageDetail = speaking.map {
            listen + "\n" + String(appLocalized: "我说：\($0.source.title) → 译音：\($0.target.title)")
        } ?? listen
        videoCaptions.setLanguages(source: listening.source, target: listening.target)
        updateRemoteHeadings()
        updateTitlebarActions()
        layoutVideoChrome()
    }

    /// Conversation columns contain both speakers and may retain earlier directions.
    /// Only the video pair can be labelled with one current source/target language.
    private func updateRemoteHeadings() {
        conversation.setHeader(source: String(appLocalized: "原文"), translation: String(appLocalized: "译文"))
        videoCaptions.setAccessibilityTitles(source: String(appLocalized: "原文 · \(remoteLanguageTitle)"),
                                             translation: String(appLocalized: "译文 · \(translationLanguageTitle)"))
    }

    private func updateTitlebarActions() {
        titleView.apply(display: .current)
        let content = titlebarContent
        let chromeWidth = hoverStrip.frame.width > 0 ? hoverStrip.frame.width : contentWidth
        let width = Double(chromeWidth)
        let reserved = Double(SubtitleTitlebarView.windowChrome + titleView.minimumWidth)
        let compaction = TitlebarCompaction.choose(windowWidth: width, reservedLeading: reserved) {
            Double(titlebar.measure(content, $0))
        }
        titlebar.apply(content, compaction: compaction)
        // The source name yields first: the leading title takes only the remaining width.
        titleView.setWidth(min(titleView.naturalWidth,
                               max(titleView.minimumWidth, chromeWidth - SubtitleTitlebarView.windowChrome - titlebar.frame.width)))
        hoverStrip.needsLayout = true
    }

    /// Opacity that decides the reading shadow for every row of this window.
    var readingOpacity: Double { Double(effectiveOpacity) }

    /// Scene opacity after Increase Contrast (at least 0.95).
    private var effectiveOpacity: CGFloat {
        CGFloat(SubtitleTokens.effectiveOpacity(Double(backgroundOpacity),
                                                increaseContrast: SubtitleStyle.Display.current.increaseContrast))
    }

    private func updateBackground() {
        let display = SubtitleStyle.Display.current
        let opacity = effectiveOpacity
        updateVideoAppearance()
        if presentation == .video {
            // Video draws its own fitted glass, stroke or plates (§6 字幕样式); text-free areas
            // stay fully transparent, also under Reduce Transparency (plates at 0.85).
            panel.isOpaque = false
            panel.backgroundColor = .clear
            backgroundEffect.isHidden = true
            panel.invalidateShadow()
            render(forceLayout: true)
            return
        }
        let opaque = display.reduceTransparency || opacity >= 1
        // The hidden control strip is transparent; Reduce Transparency applies to reading only.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        backgroundEffect.isHidden = false
        backgroundEffect.material = .hudWindow
        backgroundEffect.wantsLayer = true
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            backgroundEffect.layer?.backgroundColor = opaque ? NSColor.windowBackgroundColor.cgColor : nil
        }
        // This view is a background sibling: labels, buttons and scrolling content keep alpha 1.
        backgroundEffect.alphaValue = opaque ? 1 : opacity
        panel.invalidateShadow()
        render(forceLayout: true)
    }

    // MARK: conversation (PTTHUD supplies my side; it never creates or orders another window)

    /// My speech is shown (session running, subtitles on, not video): the conversation stays
    /// even before any remote subtitle.
    func setLocalSpeechVisible(_ on: Bool) {
        guard localSpeechVisible != on else { return }
        localSpeechVisible = on
        if !on { dock.stopLevel() }
        layout()
        updateWindowVisibility()
    }

    /// The dock's status, keycap and live turn. Status changes never rebuild the timeline.
    func setDock(_ next: MicStatusDock.Content?) {
        guard dockContent != next else { return }
        let previous = dockContent
        dockContent = next
        applyDock()
        let rules = conversationRules
        // In the last-row-only window the live turn is the timeline's last row instead.
        if rules.lastRowOnly, previous?.turn != next?.turn || previous?.expanded != next?.expanded {
            updateConversation()
        }
        if (previous == nil) != (next == nil) || previous?.expanded != next?.expanded {
            updateDockHeight(animated: previous != nil && next != nil)
        }
    }

    /// My finished turn becomes (or updates) a "我的行" in the timeline.
    func commitMyTurn(_ turn: ConversationTimeline.Turn) {
        guard presentation != .video, timeline.commit(turn, at: HostClock.now()) else { return }
        updateConversation()
    }

    /// A new own turn or a reset ends a frozen reading position at once.
    func followLatest() { conversation.followLatest() }

    /// Meter ticks: only the dock curve redraws.
    func setInputLevel(_ level: Float?) {
        guard hasConversation, isWindowVisible else { dock.stopLevel(); return }
        dock.setLevel(level)
    }

    func stopInputLevel() { dock.stopLevel() }

    /// LISTEN's `meetingSilent`: the empty meeting timeline says "[waveform.slash] 暂未听到对方声音".
    func setRemoteSilent(_ on: Bool) {
        guard remoteSilent != on else { return }
        remoteSilent = on
        conversation.setPlaceholder(conversationPlaceholder)
        reportTimelineSilence()
    }

    /// The empty meeting timeline itself says "暂未听到对方声音", so the titlebar's gray silence
    /// chip yields (HUDModel.issueSlot). It returns once rows exist or subtitles are off.
    var timelineShowsSilence: Bool {
        presentation == .meeting && hasConversation && remoteSilent && conversation.isEmpty
    }
    /// `timelineShowsSilence` flipped (a first row, subtitles on/off): PTTHUD redraws the slot.
    var onTimelineSilenceChange: (() -> Void)?
    private var reportedTimelineSilence = false

    private func reportTimelineSilence() {
        let silence = timelineShowsSilence
        guard silence != reportedTimelineSilence else { return }
        reportedTimelineSilence = silence
        onTimelineSilenceChange?()
    }

    private var conversationRules: ConversationLayout {
        ConversationLayout(contentWidth: Double(conversationSize.width), contentHeight: Double(conversationSize.height))
    }

    private var conversationStyle: ConversationStyle {
        ConversationStyle(typography: conversationTypography, opacity: readingOpacity, display: .current, scene: scene,
                          stacked: conversationRules.stacked)
    }

    private var conversationPlaceholder: TimelinePlaceholder.Content? {
        switch presentation {
        case .video:
            return nil
        case .phone:
            // Dialing and hang-up belong to the Phone button's help, the ready state to the capsule.
            return .init(primary: String(appLocalized: "等待对方字幕…"), secondary: nil, clickable: false,
                         symbol: SubtitleTokens.SceneIcon.phone)
        case .meeting:
            if remoteSilent {
                return .init(primary: String(appLocalized: "暂未听到对方声音"), secondary: nil, clickable: true,
                             // The titlebar chip's and menu line's glyph for the same fact.
                             symbol: HUDModel.Warning.meetingSilent.symbol, help: String(appLocalized: "查看详情"),
                             accessibilityLabel: String(appLocalized: "暂未听到对方声音，查看详情"))
            }
            // The titlebar already names the scene: the same short form as video.
            let primary = titlebarContent.sourceTitle.map { String(appLocalized: "正在听 \($0)…") }
                ?? String(appLocalized: "正在听…")
            return .init(primary: primary, secondary: nil, clickable: false, symbol: SubtitleTokens.VoiceIcon.listening)
        }
    }

    /// Pushes the rows to the view. Only rows whose content changed are rebuilt.
    private func updateConversation() {
        guard presentation != .video else { return }
        let rules = conversationRules
        let live = rules.lastRowOnly && dockContent?.expanded == true ? dockContent?.turn : nil
        conversation.setPlaceholder(conversationPlaceholder)
        conversation.apply(rows: timeline.rows(including: live), style: conversationStyle,
                           lastRowOnly: rules.lastRowOnly, showsHeader: rules.showsColumnHeader)
        reportTimelineSilence()
        // The start hint belongs to the empty conversation only; size or style changes reach
        // the dock too. Unchanged content returns at once.
        applyDock()
    }

    private func applyDock() {
        var content = dockContent
        let rules = conversationRules
        if var value = content {
            value.showsStartHint = value.showsStartHint && conversation.isEmpty
            // Too low to expand: the live turn is the timeline's last row instead.
            if !rules.dockExpands { value.turn = nil }
            content = value
        }
        dock.apply(content, style: conversationStyle, compact: rules.compactDock)
        dock.setStatusVisible(chromeShown == true)
        dock.isHidden = !hasConversation || content == nil
        if dock.isHidden { dock.stopLevel() }
    }

    private var targetDockHeight: CGFloat {
        guard let dockContent else { return 0 }
        return CGFloat(conversationRules.dockHeight(speaking: dockContent.expanded))
    }

    /// 180 ms ease-in-out (§4 发言态); instant with Reduce Motion or while not on screen.
    private func updateDockHeight(animated: Bool) {
        let target = targetDockHeight
        dockTimer?.invalidate(); dockTimer = nil
        dockAnimation = nil
        let duration = SubtitleStyle.duration(.statusBandResize)
        guard animated, duration > 0, isWindowVisible, hasConversation, abs(target - dockHeight) > 0.5 else {
            dockHeight = target
            layoutConversation()
            return
        }
        dockAnimation = (dockHeight, target, ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepDockAnimation(duration: duration) }
        }
        RunLoop.main.add(timer, forMode: .common)
        dockTimer = timer
    }

    private func stepDockAnimation(duration: TimeInterval) {
        guard let animation = dockAnimation else { dockTimer?.invalidate(); dockTimer = nil; return }
        let progress = min(1, max(0, (ProcessInfo.processInfo.systemUptime - animation.start) / duration))
        let eased = progress < 0.5 ? 2 * progress * progress : 1 - pow(-2 * progress + 2, 2) / 2
        dockHeight = animation.from + (animation.to - animation.from) * CGFloat(eased)
        if progress >= 1 {
            dockHeight = animation.to
            dockAnimation = nil
            dockTimer?.invalidate(); dockTimer = nil
        }
        layoutConversation()
    }

    /// Splits the fixed content area between the timeline and the dock.
    private func layoutConversation() {
        guard hasConversation else { return }
        let width = conversationSize.width, height = conversationSize.height
        if dockAnimation == nil { dockHeight = targetDockHeight }
        let dockFrameHeight = min(height, dockHeight)
        let padding = CGFloat(SubtitleTokens.Size.panelHorizontalPadding)
        let top = hoverStripHeight
        conversation.frame = NSRect(x: padding, y: top, width: max(0, width - 2 * padding),
                                    height: max(0, height - dockFrameHeight))
        dock.frame = NSRect(x: 0, y: top + height - dockFrameHeight, width: width, height: dockFrameHeight)
        conversation.layoutSubtreeIfNeeded()
        dock.layoutSubtreeIfNeeded()
    }

    private func displayedRowsChanged() {
        let rows = conversation.displayedRows
        var lines: [String] = []
        for row in rows { lines += [row.source, row.translation] }
        while lines.count < 6 { lines.append("") }
        displayedLines = lines
        recordPresentation()
    }

    /// "朗读新译文": each new remote final, never a draft, at medium priority while visible.
    private func announceFinals(_ finals: [(sentence: UInt64, text: String)]) {
        let isVideo = presentation == .video
        let fresh = finals.filter { isVideo ? !announcedVideoFinals.contains($0.sentence) : $0.sentence > announcedThrough }
        guard let newest = fresh.map(\.sentence).max() else { return }
        announcedThrough = newest
        if isVideo { announcedVideoFinals.formUnion(fresh.map(\.sentence)) }
        guard announcesNewTranslations, isVisible else { return }
        for line in fresh where !line.text.isEmpty {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: line.text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }
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
        timeline.noteRemote(update, at: now)
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
    /// A subtitle reset (language/configuration switch): remote pairs go, my turns stay.
    /// `includingMyTurns` (session end, scene change) empties the whole conversation.
    func clear(includingMyTurns: Bool = false) {
        let hadHint = board.hint != nil
        liveSource = ""; renderedSource = ""; renderedDraft = nil; lastPreviewRenderAt = 0; board.clear()
        videoBoard.clear(); renderedVideoCue = nil; videoDraftTail.reset()
        if presentation == .video { updateWindowVisibility() }
        videoHiddenSince = isVisible || presentation != .video ? nil : HostClock.now()
        videoCaptions.setCaption(source: NSAttributedString(string: ""), translation: NSAttributedString(string: ""),
                                 sentence: nil, isFinal: false, at: Double(HostClock.now()) / 1_000_000_000)
        if includingMyTurns { timeline.clear() } else { timeline.clearRemote() }
        restoreFromQuietDim()
        if videoLagging { videoLagging = false; onVideoLagChange?(false) }
        announcedThrough = 0
        announcedVideoFinals = []
        conversation.followLatest()
        if hadHint { onHintChange?(nil) }
        updateConversation()
        render()
        observe("subtitle_cleared", at: HostClock.now())
    }

    func setAnalysisConfiguration(_ id: UInt64) {
        guard analysisConfiguration != id else { return }
        analysisConfiguration = id
        conversation.followLatest()
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
        board.notePresentedDraft(renderedDraft)
        // The timeline mirrors the paced board: finals at once, previews at the 500 ms cadence.
        let changed = timeline.syncRemote(finals: board.finals, draft: renderedDraft, liveSource: renderedSource, at: now)
        announceFinals(board.finals.map { ($0.sentence, $0.display) })
        if changed || forceLayout { updateConversation() }
        // Text only reflows inside its own rows; it never determines the window or dock heights.
        if forceLayout { layout() }
        recordPresentation()
    }

    private var videoSourceFont: NSFont { SubtitleStyle.font(videoTypography.source) }
    private var videoTranslationFont: NSFont { SubtitleStyle.font(videoTypography.translation) }

    private func applyVideo(_ update: SubtitleUpdate, at now: HostTime) {
        let previousPending = videoBoard.pendingFinalSentenceIDs
        let previousSource = liveSource
        var droppedSentence: UInt64?
        if case .source(let text) = update { liveSource = text }
        let changed = videoBoard.apply(update, at: now)
        // New cues, draft revisions and changed source text end long-silence dimming at once.
        switch update {
        case .final, .draft: if changed { restoreFromQuietDim() }
        case .source(let text): if text != previousSource, !text.isEmpty { restoreFromQuietDim() }
        case .dropped: break
        }
        if videoBoard.skippedCount > seenSkippedCount {
            let skipped = videoBoard.skippedCount - seenSkippedCount
            videoCaptions.showSkipped(count: skipped, at: Double(now) / 1_000_000_000)
            // Only with "朗读新译文" (§4): VoiceOver users otherwise never learn a sentence went.
            if announcesNewTranslations, isVisible {
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                    .announcement: VideoSubtitleView.skippedText(count: skipped),
                    .priority: NSAccessibilityPriorityLevel.low.rawValue,
                ])
            }
        }
        seenSkippedCount = videoBoard.skippedCount
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
        updateWindowVisibility()
        renderVideo(at: now)
    }

    private func renderVideo(at now: HostTime, forceLayout: Bool = false, preparingToShow: Bool = false) {
        // Defer hidden updates so corrections cannot be credited as read while off screen.
        // The first caption is laid out while still hidden, before ordering the window front.
        guard isWindowVisible || preparingToShow else {
            if forceLayout { layout() }
            return
        }
        let cue = videoBoard.current
        // Draft updates are already rate-limited upstream, so a changed cue never waits for the
        // preview clock; that clock only limits source-only placeholder text.
        let cueChanged = cue != renderedVideoCue
        let previewDue = now >= lastPreviewRenderAt && now - lastPreviewRenderAt >= Self.previewInterval
        guard forceLayout || cueChanged || previewDue else { return }
        let source = cue?.line.source ?? liveSource
        let sourceText = VideoSubtitleView.sourceText(source, font: videoSourceFont, display: .current)
        let targetText = videoTranslationText(cue)
        videoCaptions.placeholder = videoPlaceholder
        renderedVideoCue = cue
        renderedSource = liveSource
        lastPreviewRenderAt = now
        videoCaptions.setCaption(source: sourceText, translation: targetText,
                                 sentence: cue?.line.sentence, isFinal: cue?.isFinal ?? false,
                                 at: Double(now) / 1_000_000_000)
        if let cue, cue.isFinal, !preparingToShow { announceFinals([(cue.line.sentence, cue.line.display)]) }
        if forceLayout { layout() }
        recordPresentation()
    }

    /// Empty state at the source position, naming the actual source (§6).
    private var videoPlaceholder: String? {
        titlebarContent.sourceTitle.map { String(appLocalized: "正在听 \($0)…") }
    }

    /// A draft keeps the text it shares with the previous version of the same sentence at
    /// full white; only the changed tail is dimmed (§6 视觉反馈).
    private func videoTranslationText(_ cue: VideoSubtitleBoard.Cue?) -> NSAttributedString {
        guard let cue, !cue.line.text.isEmpty else { return NSAttributedString(string: "") }
        guard !cue.isFinal else {
            return VideoSubtitleView.translationText(VideoCaptionPager.withoutClauseMarks(cue.line.display), isFinal: true,
                                                     stablePrefix: 0, font: videoTranslationFont)
        }
        let text = VideoCaptionPager.withoutClauseMarks(cue.line.text)
        let previous = renderedVideoCue.flatMap {
            $0.line.sentence == cue.line.sentence && !$0.isFinal ? VideoCaptionPager.withoutClauseMarks($0.line.text) : nil
        }
        // Measured when the draft changes; an unchanged draft keeps its dimmed tail.
        let stable = videoDraftTail.stablePrefix(sentence: cue.line.sentence, text: text, previous: previous)
        return VideoSubtitleView.translationText(text, isFinal: false, stablePrefix: stable, font: videoTranslationFont)
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
        // A frozen timeline still shows its snapshot; newer rows are not on screen yet.
        guard !conversation.isFrozen else { return }
        let now = HostClock.now()
        let shown = Set(conversation.displayedRows.map(\.id))
        let finals = board.finals.filter { shown.contains(.remote($0.sentence)) }
        let draft = renderedDraft.flatMap { shown.contains(.remote($0.sentence)) ? $0 : nil }
        // Log actual label changes after board pacing, including revisions, not timer ticks or
        // font/layout refreshes. This is AppKit submission time, not a display hardware timestamp.
        for line in finals where !presentedFinals.contains(line) {
            observe("subtitle_displayed", at: now, line: line, kind: "final")
        }
        for line in presentedFinals where !finals.contains(where: { $0.sentence == line.sentence }) {
            observe("subtitle_removed", at: now, line: line, kind: "final")
        }
        if let draft, draft != presentedDraft {
            observe("subtitle_displayed", at: now, line: draft, kind: "draft")
        } else if draft == nil, let old = presentedDraft {
            observe("subtitle_removed", at: now, line: old, kind: "draft")
        }
        presentedFinals = finals; presentedDraft = draft
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
        let chromeInset: CGFloat = presentation == .video ? 0 : hoverStripHeight
        let maxHeight = max(140, visible.height - 40)
        let hasReadingArea = presentation == .video ? subtitlesRequested : hasConversation
        // Video: two Chinese lines, one source line and 24 pt already include its margins (§6).
        // Meeting/phone: the 28 pt dock and one two-line pair, so the last-row-only window
        // below 140 pt can still be reached (§4 断点).
        let minimumReading = presentation == .video
            ? VideoSubtitleView.minimumReadingHeight(sourceFont: videoSourceFont, translationFont: videoTranslationFont)
                + hoverStripHeight + CGFloat(VideoCaptionLayout.controlBarGap)
            : CGFloat(ConversationLayout.minimumContentHeight(translationSize: conversationTypography.remoteTranslation.size))
        // Video uses a full-size content view, so its frame is the content: without captions
        // it keeps the hover bar's height, never zero (§6 关闭正文时只保留标题栏).
        let titlebarOnly = ceil(hoverStripHeight)
        let minHeight: CGFloat = hasReadingArea ? min(maxHeight, ceil(minimumReading) + chromeInset) : titlebarOnly
        panel.contentMinSize = NSSize(width: min(minimumWidth, width), height: minHeight)
        panel.contentMaxSize = NSSize(width: max(280, visible.width - 40), height: maxHeight)
        // Status-only mode collapses to the titlebar without changing saved reading sizes.
        let height = hasReadingArea
            ? min(maxHeight, max(minHeight, (manualContentSize?.height ?? defaultContentSize.height) + chromeInset))
            : minHeight
        videoCaptions.isHidden = !subtitlesRequested || presentation != .video
        conversation.isHidden = !hasConversation
        dock.isHidden = !hasConversation || dockContent == nil
        if dock.isHidden { dock.stopLevel() }
        if subtitlesRequested, presentation == .video {
            // Block widths and bottom anchoring are measured from the whole content area.
            videoCaptions.reservedChromeHeight = hoverStripHeight + CGFloat(VideoCaptionLayout.controlBarGap)
            videoCaptions.frame = NSRect(x: 0, y: 0, width: width, height: height)
            videoCaptions.layoutSubtreeIfNeeded()
        }
        if hasConversation {
            let previous = conversationRules
            conversationSize = NSSize(width: width, height: max(0, height - chromeInset))
            let rules = conversationRules
            if rules.stacked != previous.stacked || rules.compactDock != previous.compactDock
                || rules.lastRowOnly != previous.lastRowOnly {
                applyDock()
                updateConversation()
            }
            layoutConversation()
        }
        let size = NSSize(width: width, height: height)
        let old = panel.frame
        let oldSize = panel.contentRect(forFrameRect: old).size
        let sizeChanged = abs(oldSize.width - size.width) > 0.5 || abs(oldSize.height - size.height) > 0.5
        if sizeChanged { panel.setContentSize(size) }
        content.frame = NSRect(origin: .zero, size: size)
        backgroundEffect.frame = NSRect(x: 0, y: chromeInset, width: width, height: max(0, height - chromeInset))
        layoutVideoChrome()
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
        updateVideoChrome(animated: false)
        if on {
            if presentation == .video {
                renderVideo(at: HostClock.now(), forceLayout: true)
                resetVideoReading()
                scheduleFullScreenHintCheck()
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
            pauseVideoLag(at: HostClock.now())
            observe("panel_hidden", at: HostClock.now())
            presentedFinals = []; presentedDraft = nil
        }
    }
    private func updateWindowVisibility() {
        reportTimelineSilence()
        if hasWindowContent {
            // Minimized is a user-owned presentation state, independent of subtitles being
            // enabled and of audio work. A status transition must never bring it back.
            guard presence.allowsAutomaticDisplay(contentAvailable: true, userHidden: panel.userHidden,
                                                   minimized: isMiniaturized) else { return }
            if !panel.isVisible {
                if presentation == .video {
                    renderVideo(at: HostClock.now(), forceLayout: true, preparingToShow: true)
                }
                panel.orderFrontRegardless()
                windowShownAgain()
                scheduleFullScreenHintCheck()
                if presentation == .video {
                    if let cue = renderedVideoCue, cue.isFinal { announceFinals([(cue.line.sentence, cue.line.display)]) }
                    recordPresentation()
                }
            }
        } else {
            // An empty video reset must not discard the user's existing Dock miniwindow.
            // Ending the session still removes it below, as for the other scenes.
            if presentation == .video, presence.sessionOpen, isMiniaturized { return }
            // A popover anchored here (the language chips reset the captions) keeps the window
            // until it closes; popoverChanged then applies the usual "no content, no window" rule.
            if presentation == .video, presence.sessionOpen, !heldPopovers.isEmpty { return }
            // Ending the last visible work removes its Dock thumbnail without flashing the
            // window on screen. Reusing this retained panel later starts a fresh presentation.
            if panel.isMiniaturized || panel.minimizationPending { panel.dismissMiniaturizedWindow() }
            else if panel.isVisible { panel.orderOut(nil); windowHidden() }
        }
    }

    var isMiniaturized: Bool { panel.userMinimized || panel.isMiniaturized || panel.minimizationPending }
    var canRestoreWindow: Bool { hasWindowContent && (isMiniaturized || panel.userHidden || !panel.isVisible) }

    /// A new session is an explicit start, unlike an ordinary update or a late failure notice.
    /// It is the only call that lets the window appear again after `endSession`.
    func beginSession() {
        presence.begin()
        if panel.isMiniaturized || panel.minimizationPending { panel.dismissMiniaturizedWindow() }
        panel.clearUserPresentationState()
        updateWindowVisibility()
    }

    /// Any end (user, automatic, failure, after sleep, demo, quit): the window leaves in one step,
    /// ordered out before any layout, while the stop continues in the background. Late status
    /// for this session cannot bring it back. Idempotent.
    func endSession() {
        let announce = presence.sessionOpen && isWindowVisible && sessionActionsActive
        let wasOpen = presence.end()
        updateWindowVisibility()
        setVisible(false)
        guard wasOpen else { return }
        onSessionClosed?()
        if announce {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: String(appLocalized: "\(scene.title)已结束"),
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }
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
            resetVideoReading()
            scheduleFullScreenHintCheck()
        }
        windowShownAgain()
        recordPresentation()
    }

    /// Ordered out or minimised: AppKit sends no mouseExited, so hover state is dropped here.
    private func windowHidden() {
        panel.cancelTitlebarInteraction()
        hoverBar.windowHidden()
        Self.clearHover(in: panel.contentView?.superview ?? content)
        if presentation == .video { updateVideoChrome(animated: false) }
    }

    /// Shown again: the pointer may be anywhere now, and no tracking event says so.
    private func windowShownAgain() {
        guard panel.isVisible else { return }
        hoverBar.windowHidden()
        hoverBar.pointer(inside: pointerIsInsideWindow, at: uptime)
        updateVideoChrome(animated: false)
    }

    private static func clearHover(in view: NSView) {
        (view as? HoverClearing)?.clearHover()
        view.subviews.forEach { clearHover(in: $0) }
    }

    var isVisible: Bool { subtitlesRequested && isWindowVisible }
    var isWindowVisible: Bool { panel.isVisible && !isMiniaturized && !panel.userHidden }
    /// My side of the conversation (the dock) is on screen.
    var speechIsVisible: Bool { presentation != .video && localSpeechVisible && isWindowVisible }
    var statusIsVisible: Bool { statusVisible && isWindowVisible }

    private func poll() {
        let now = HostClock.now()
        if presentation == .video {
            guard isWindowVisible else { pauseVideoLag(at: now); return }
            if let since = videoHiddenSince {
                // The hidden time was a deliberate pause; queued cues did not wait through it.
                videoBoard.excludeHiddenTime(now > since ? now - since : 0)
                videoHiddenSince = nil
            }
            renderVideo(at: now)
            updateVideoLag(at: now)
            let seconds = Double(now) / 1_000_000_000
            videoCaptions.catchingUp = !videoBoard.pendingSentenceIDs.isEmpty
            let pageChanged = videoCaptions.advance(at: seconds)
            if videoCaptions.canAdvance(at: seconds), videoBoard.advance() {
                renderVideo(at: now)
            } else if pageChanged { recordPresentation() }
            quietDim.update(lastPageRead: videoCaptions.hasReadLastPage(at: seconds),
                            pending: !videoBoard.pendingSentenceIDs.isEmpty, at: seconds)
            videoCaptions.setQuietDimmed(quietDim.isDimmed(at: seconds))
            return
        }
        let advanced = board.advance(at: now)
        let previewPending = liveSource != renderedSource || board.draft != renderedDraft
        let previewDue = now >= lastPreviewRenderAt && now - lastPreviewRenderAt >= Self.previewInterval
        if advanced || (previewPending && previewDue) { render(at: now) }
        else { recordPresentation() }
    }

    /// Hidden, minimised or captions off: no lag is measured or shown until they are back.
    private func pauseVideoLag(at now: HostTime) {
        guard presentation == .video else { return }
        if videoHiddenSince == nil { videoHiddenSince = now }
        if videoLagging { videoLagging = false; onVideoLagChange?(false) }
    }

    private func updateVideoLag(at now: HostTime) {
        let lagging = presentation == .video && videoBoard.lag(at: now) != nil
        guard lagging != videoLagging else { return }
        videoLagging = lagging
        onVideoLagChange?(lagging)
    }

    private func liveResizeStarted() {
        liveResizeTypographyWidth = contentWidth
    }

    private func liveResizeEnded() {
        guard liveResizeTypographyWidth != nil else { return }
        liveResizeTypographyWidth = nil
        render(forceLayout: true)
        onAppearanceChange?()
    }

    private func userResized() {
        guard !isLayingOut, !isMiniaturized else { return }
        let resized = panel.contentRect(forFrameRect: panel.frame).size
        let hasReadingArea = presentation == .video ? subtitlesRequested : hasConversation
        let readingHeight = max(0, resized.height - (presentation == .video ? 0 : hoverStripHeight))
        manualContentSize = NSSize(width: resized.width, height: hasReadingArea
                                   ? readingHeight : (manualContentSize?.height ?? defaultContentSize.height))
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
        guard let screen = preferredScreen ?? rememberedScreen() ?? NSScreen.main ?? NSScreen.screens.first else { return }
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
        // Video starts 8% of the visible height above the bottom edge, centred (§6 窗口).
        let bottom = presentation == .video ? visible.minY + (visible.height * 0.08).rounded() : visible.minY + 80
        panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: bottom))
    }
    private func savePosition() {
        guard !isLayingOut, !isMiniaturized, let screen = panel.screen else { return }
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: key(for: screen))
        UserDefaults.standard.set(screenID(screen), forKey: screenKey)
    }
    /// The display this scene's window was last on (same `ui.subtitleOrigin.<scene>` key family).
    private var screenKey: String { "ui.subtitleOrigin.\(presentation.rawValue).screen" }
    /// That display when it is still connected; otherwise nil, and the caller falls back.
    private func rememberedScreen() -> NSScreen? {
        guard let id = UserDefaults.standard.string(forKey: screenKey) else { return nil }
        return NSScreen.screens.first { screenID($0) == id }
    }

    // MARK: video window chrome (§6 窗口 / 鼠标穿透, §1 长静默变暗)

    /// The same native controls in all scenes, placed independently from the reading area.
    /// A full-size content view lets the video strip follow its captions rather than the frame.
    private func updateWindowControlHelp() {
        let video = presentation == .video
        // Red close and yellow minimise only hide the presentation; the session goes on.
        panel.standardWindowButton(.closeButton)?.toolTip = video
            ? String(appLocalized: "隐藏字幕，收听和翻译继续") : String(appLocalized: "隐藏字幕，同传继续")
        panel.standardWindowButton(.miniaturizeButton)?.toolTip = video
            ? String(appLocalized: "最小化字幕，收听和翻译继续") : String(appLocalized: "最小化字幕，同传继续")
    }

    private func applyWindowChrome() {
        let video = presentation == .video
        panel.styleMask.insert(.fullSizeContentView)
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        titlebarContainer?.isHidden = true
        hoverStrip.apply(scene: scene)
        content.dragsWindow = !video
        updateWindowControlHelp()
        titlebar.trailingInset = video ? CGFloat(VideoStatusDot.reservedTrailingWidth) : 0
        hoverTimer?.invalidate(); hoverTimer = nil
        hoverBar = VideoHoverBar()
        applyClickThrough()
        hoverBar.pointer(inside: pointerIsInsideWindow, at: uptime)
        if !video { hideHint() }
        chromeShown = nil
        updateVideoChrome(animated: false)
        updateTitlebarActions()
    }

    private var uptime: Double { ProcessInfo.processInfo.systemUptime }
    private var pointerInContent: NSPoint {
        content.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    }

    private var pointerIsInsideWindow: Bool {
        guard panel.isVisible, NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) else { return false }
        guard presentation == .video, subtitlesRequested else { return true }
        let reading = videoCaptions.textBlockRect
        let active = reading.isNull ? hoverStrip.frame : hoverStrip.frame.union(reading)
        return active.insetBy(dx: -4, dy: -4).contains(pointerInContent)
    }

    /// The native titlebar view that holds the traffic lights and the accessories.
    private var titlebarContainer: NSView? {
        guard let titlebarView = panel.standardWindowButton(.closeButton)?.superview else { return nil }
        if let container = titlebarView.superview, NSStringFromClass(type(of: container)).contains("TitlebarContainer") {
            return container
        }
        return titlebarView
    }

    /// Fixed heights preserve the established scene typography and window chrome.
    private var hoverStripHeight: CGFloat {
        CGFloat(presentation == .video ? SubtitleTokens.Size.videoHoverBarHeight : SubtitleTokens.Size.titlebarHeight)
    }

    private func pointerMoved(inside: Bool) {
        // Child tracking areas can exit into another part of this same window.
        hoverBar.pointer(inside: pointerIsInsideWindow, at: uptime)
        updateVideoChrome(animated: true)
    }

    /// A popover opened from this window (details, end confirmation) keeps a shown bar.
    private func popoverChanged(_ popover: NSPopover, shown: Bool) {
        let id = ObjectIdentifier(popover)
        if shown {
            guard popover.contentViewController?.view.window?.parent === panel else { return }
            heldPopovers.insert(id)
        } else {
            guard heldPopovers.remove(id) != nil else { return }
        }
        hoverBar.setHeld(!heldPopovers.isEmpty, at: uptime)
        updateVideoChrome(animated: true)
        if !shown, heldPopovers.isEmpty, presentation == .video { updateWindowVisibility() }
    }

    private func updateVideoChrome(animated: Bool) {
        hoverTimer?.invalidate(); hoverTimer = nil
        let now = uptime
        // Captions off: the window is only its bar. VoiceOver: hover-only controls would leave
        // the accessibility tree. A locked window still hides the bar.
        let hasReadingArea = presentation == .video ? subtitlesRequested : hasConversation
        var pinned = !hasReadingArea || NSWorkspace.shared.isVoiceOverEnabled
        #if TALKTALK_DEV
        pinned = pinned || previewPinsChrome
        #endif
        hoverBar.setPinned(pinned)
        if let deadline = hoverBar.hideDeadline(at: now) {
            let timer = Timer(timeInterval: max(0.01, deadline - now), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateVideoChrome(animated: true) }
            }
            RunLoop.main.add(timer, forMode: .common)
            hoverTimer = timer
        }
        setChrome(shown: hoverBar.isShown(at: now), animated: animated)
        layoutVideoChrome()
    }

    /// Fades only window chrome, never the reading area or my live turn.
    private func setChrome(shown: Bool, animated: Bool) {
        guard chromeShown != shown else { return }
        chromeShown = shown
        if shown {
            DispatchQueue.main.async { [weak self] in self?.onTitlebarShown?() }
        }
        chromeGeneration += 1
        let generation = chromeGeneration
        titlebarContainer?.isHidden = true
        dock.setStatusVisible(shown, animated: animated)
        let views: [NSView] = [hoverStrip]
        let target: CGFloat = shown ? 1 : 0
        if shown { views.forEach { $0.isHidden = false } }
        let duration = animated ? VideoHoverBar.fadeDuration(reduceMotion: SubtitleStyle.Display.current.reduceMotion) : 0
        guard duration > 0, panel.isVisible else {
            views.forEach { $0.alphaValue = target }
            chromeFadeFinished(generation: generation)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            views.forEach { $0.animator().alphaValue = target }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.chromeFadeFinished(generation: generation) }
        })
    }

    private func chromeFadeFinished(generation: Int) {
        guard generation == chromeGeneration else { return }
        if chromeShown == false {
            titlebarContainer?.isHidden = true
            hoverStrip.isHidden = true
        }
        panel.invalidateShadow()
    }

    /// Strip, persistent dot and lock indicator in the top-right corner, and the hint.
    private func layoutVideoChrome() {
        guard !isLayingOutChrome else { return }
        isLayingOutChrome = true
        defer { isLayingOutChrome = false }
        let video = presentation == .video
        let width = content.bounds.width
        let strip = hoverStripHeight
        titlebarContainer?.isHidden = true
        hoverStrip.apply(scene: scene)
        let proposed = video && subtitlesRequested
            ? videoCaptions.controlBarFrame(height: strip)
            : NSRect(x: 0, y: 0, width: width, height: strip)
        // Never move a button out from under the pointer or its open popover as a draft grows.
        let holdsPosition = video && chromeShown == true && liveResizeTypographyWidth == nil
            && (!heldPopovers.isEmpty || hoverStrip.frame.contains(pointerInContent))
            && abs(proposed.width - hoverStrip.frame.width) < 0.5
            && content.bounds.contains(hoverStrip.frame)
            && (videoCaptions.textBlockRect.isNull || hoverStrip.frame.maxY + CGFloat(VideoCaptionLayout.controlBarGap)
                <= videoCaptions.textBlockRect.minY)
        if !holdsPosition { hoverStrip.frame = proposed }
        hoverStrip.layoutSubtreeIfNeeded()
        let barFrame = hoverStrip.frame
        let dot = video ? VideoStatusDot.make(issue: titlebarIssue) : nil
        statusDot.isHidden = dot == nil
        titlebar.showsStatusDotTarget = dot != nil
        let inset = CGFloat(VideoStatusDot.edgeInset)
        let box = VideoStatusDotView.boxSize
        var dotFrame = NSRect(x: barFrame.maxX - inset - CGFloat(VideoStatusDot.diameter) / 2 - box / 2,
                              y: barFrame.minY + strip / 2 - box / 2, width: box, height: box)
        // Draw the dot exactly under its click target in the titlebar when that is placed.
        let target = titlebar.statusDotTarget
        if dot != nil, titlebar.window === panel, target.frame.width > 0 {
            let converted = content.convert(target.convert(target.bounds, to: nil), from: nil)
            if converted.minX.isFinite, content.bounds.insetBy(dx: -1, dy: -1).contains(converted) { dotFrame = converted }
        }
        if let dot {
            statusDot.frame = dotFrame
            statusDot.color = SubtitleStyle.color(dot.color)
            statusDot.dot = dot
            let chip = titlebarIssue?.chip
            target.setAccessibilityLabel(chip?.label)
            target.setAccessibilityHelp(chip?.detail)
            target.toolTip = chip?.detail
            // The dot is its own button while the bar (and its target) is hidden, e.g. locked.
            statusDot.setAccessibilityElement(chromeShown != true)
            statusDot.setAccessibilityLabel(chip?.label)
            statusDot.setAccessibilityHelp(chip?.detail)
        }
        lockIndicator.isHidden = !(video && panel.ignoresMouseEvents)
        lockIndicator.contentTintColor = SubtitleStyle.white(CGFloat(SubtitleClickThrough.indicatorAlpha(
            increaseContrast: SubtitleStyle.Display.current.increaseContrast)))
        let lockSize: CGFloat = 12
        let lockRight = dot == nil ? barFrame.maxX - inset : dotFrame.minX
        lockIndicator.frame = NSRect(x: lockRight - lockSize, y: barFrame.minY + strip / 2 - lockSize / 2,
                                     width: lockSize, height: lockSize)
        if !hintBubble.isHidden {
            let size = hintBubble.fittingSize
            let top = barFrame.minY - size.height - 6
            if top >= 0 {
                hintBubble.frame = NSRect(x: (width - size.width) / 2, y: top, width: size.width, height: size.height)
            } else { hideHint() }
        }
    }

    /// VoiceOver pressed the status dot: anchor the details at the titlebar target when the
    /// bar shows it, else at the dot.
    private func statusDotPressed() {
        let target = titlebar.statusDotTarget
        let anchor: NSView = chromeShown == true && !target.isHidden && target.window === panel ? target : statusDot
        onStatusDotClick?(anchor)
    }

    /// Locked: the whole window ignores the mouse and cannot be dragged; only the menu-bar
    /// menu unlocks it (§6 鼠标穿透).
    func setClickThroughLocked(_ locked: Bool) {
        guard clickThroughLocked != locked else { return }
        clickThroughLocked = locked
        applyClickThrough()
        if locked { hideHint() }
        updateVideoChrome(animated: false)
    }

    private func applyClickThrough() {
        let ignores = SubtitleClickThrough.ignoresMouse(locked: clickThroughLocked, scene: scene)
        panel.ignoresMouseEvents = ignores
        panel.isMovable = !ignores
        hoverBar.setLocked(ignores)
        if !ignores, presentation == .video { hoverBar.pointer(inside: pointerIsInsideWindow, at: uptime) }
    }

    private func showMoreMenu(from anchor: NSView) {
        guard presentation == .video else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let lock = NSMenuItem(title: String(appLocalized: "锁定字幕位置（鼠标穿透）"), action: #selector(PanelMenuAction.run),
                              keyEquivalent: "")
        let action = PanelMenuAction { [weak self] in self?.onLockRequest?() }
        lock.target = action
        lock.representedObject = action
        lock.image = NSImage(systemSymbolName: SubtitleTokens.VoiceIcon.locked, accessibilityDescription: nil)
        lock.toolTip = String(appLocalized: "锁定后鼠标会穿过字幕窗口；从菜单栏的 TalkTalk 菜单解锁。")
        menu.addItem(lock)
        hoverBar.setHeld(true, at: uptime)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.isFlipped ? anchor.bounds.maxY + 4 : -4), in: anchor)
        hoverBar.setHeld(false, at: uptime)
        hoverBar.pointer(inside: pointerIsInsideWindow, at: uptime)
        updateVideoChrome(animated: true)
    }

    // Long-silence dimming.

    /// Settings › 字幕 "静默变暗" (default on). Off restores at once.
    func setVideoQuietDimEnabled(_ on: Bool) {
        guard quietDim.enabled != on else { return }
        quietDim.enabled = on
        if !on { videoCaptions.setQuietDimmed(false) }
    }

    private func restoreFromQuietDim() {
        quietDim.contentArrived()
        videoCaptions.setQuietDimmed(false)
    }

    /// Hidden time is not reading time; a restored page starts undimmed with a fresh budget.
    private func resetVideoReading() {
        restoreFromQuietDim()
        videoCaptions.resetReadingTime(at: Double(HostClock.now()) / 1_000_000_000)
    }

    // One-time full-screen Space hint.

    /// Space changes settle after the switch animation; check shortly after.
    private func scheduleFullScreenHintCheck() {
        guard presentation == .video, !UserDefaults.standard.bool(forKey: Self.fullScreenHintKey) else { return }
        hintCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.checkFullScreenHint() } }
        hintCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func checkFullScreenHint() {
        let shown = UserDefaults.standard.bool(forKey: Self.fullScreenHintKey)
        let visible = isVisible && panel.isOnActiveSpace
        guard presentation == .video, visible, !shown,
              FullScreenSpaceHint.shouldShow(alreadyShown: shown, scene: scene, windowVisible: visible,
                                             locked: clickThroughLocked, onFullScreenSpace: activeSpaceIsFullScreen)
        else { return }
        hintBubble.text = FullScreenSpaceHint.text
        hintBubble.increaseContrast = SubtitleStyle.Display.current.increaseContrast
        // A compact caption window may have no room above its controls. Try again on a later
        // Space change instead of covering live captions with this optional one-time hint.
        guard hoverStrip.frame.minY >= hintBubble.fittingSize.height + 6 else { return }
        UserDefaults.standard.set(true, forKey: Self.fullScreenHintKey)
        hintBubble.alphaValue = 1
        hintBubble.isHidden = false
        layoutVideoChrome()
        // The hint appears without focus; VoiceOver hears it once.
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: FullScreenSpaceHint.text,
            .priority: NSAccessibilityPriorityLevel.low.rawValue,
        ])
        hintTimer?.invalidate()
        let timer = Timer(timeInterval: FullScreenSpaceHint.seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideHint(animated: true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        hintTimer = timer
    }

    private func hideHint(animated: Bool = false) {
        hintTimer?.invalidate(); hintTimer = nil
        guard !hintBubble.isHidden else { return }
        let duration = animated ? SubtitleStyle.duration(.noticeFadeOut) : 0
        guard duration > 0 else { hintBubble.isHidden = true; return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            hintBubble.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.hintBubble.isHidden = true }
        })
    }

    /// Another app's normal window covers this display, menu-bar area included. Only window
    /// bounds, levels and owner process numbers are read; nothing is stored or logged.
    private var activeSpaceIsFullScreen: Bool {
        guard let screen = panel.screen ?? NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let display = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        let windows = list.compactMap { entry -> FullScreenSpaceHint.Window? in
            guard let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return .init(layer: layer, ownerPID: pid, x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        }
        return FullScreenSpaceHint.isFullScreenSpace(
            windows: windows, display: (display.minX, display.minY, display.width, display.height),
            ownPID: ProcessInfo.processInfo.processIdentifier)
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
        // The explicit fixed-text fixture keeps controls visible for reproducible UI checks.
        // Normal subtitle windows retain their hover-only chrome.
        previewPinsChrome = true
        panel.title = String(appLocalized: "TalkTalk · 界面预览（无音频）")
        // Only the explicit, fixed-text development fixture can be captured for visual QA.
        // Normal windows retain .none, including the default smoke's privacy assertion.
        panel.sharingType = .readOnly
        panel.orderFrontRegardless()
        updateVideoChrome(animated: false)
    }
    #endif
}

private final class SubtitleWindow: TitlebarInteractionPanel {
    private(set) var minimizationPending = false
    private(set) var userMinimized = false
    private(set) var userHidden = false
    private var dismissingMiniwindow = false
    /// Red close or yellow minimise took the window off screen.
    var onPresentationHidden: (() -> Void)?
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
        onPresentationHidden?()
        AppActivation.minimizedPanelRestored(self)
    }

    override func miniaturize(_ sender: Any?) {
        guard !isMiniaturized, !minimizationPending else { return }
        minimizationPending = true
        userMinimized = true
        onPresentationHidden?()
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
    /// Video sets this off: only its text blocks and the hover bar drag the window (§6).
    var dragsWindow = true
    /// Pointer over the window, from an `.activeAlways` tracking area (the panel is never key).
    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { dragsWindow }
    override func mouseDown(with event: NSEvent) { if dragsWindow { window?.performDrag(with: event) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    // Subviews forward their own tracking events up the responder chain; only ours count.
    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea === hoverArea { onHover?(true) } else { super.mouseEntered(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === hoverArea { onHover?(false) } else { super.mouseExited(with: event) }
    }

    override func mouseMoved(with event: NSEvent) { onHover?(true) }
}

/// The 10 pt status mark (§6): a white "!" on a yellow triangle (warning) or a red octagon
/// (risk), so severity reads by shape too, with the reading shadow for bright or orange frames.
/// It is drawn in the content; mouse clicks go to its target in the titlebar. While the bar is
/// hidden it is its own VoiceOver button.
@MainActor
final class VideoStatusDotView: NSView {
    static let boxSize: CGFloat = 16
    var color: NSColor = .systemOrange { didSet { if color != oldValue { needsDisplay = true } } }
    var dot: VideoStatusDot = .warn { didSet { if dot != oldValue { needsDisplay = true } } }
    var onPress: (() -> Void)?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image = SubtitleStyle.symbol(dot.symbol, size: CGFloat(VideoStatusDot.symbolPointSize), weight: .bold,
                                               palette: [.white, color]) else { return }
        let size = image.size
        let token = SubtitleTokens.readingShadow
        let shadow = NSShadow()
        shadow.shadowColor = SubtitleStyle.nsColor(token.color)
        shadow.shadowBlurRadius = token.blur
        shadow.shadowOffset = NSSize(width: token.offsetX, height: token.offsetY)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A short hint capsule inside the window (the full-screen Space hint).
@MainActor
final class WindowHintView: NSView {
    private let label = NSTextField(labelWithString: "")
    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; needsLayout = true }
    }
    /// Increase Contrast outlines the capsule (1 pt white 35%).
    var increaseContrast = false {
        didSet {
            layer?.borderWidth = increaseContrast ? 1 : 0
            layer?.borderColor = SubtitleStyle.white(0.35).cgColor
        }
    }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        layer?.cornerRadius = CGFloat(SubtitleTokens.Radius.chip)
        label.font = .systemFont(ofSize: ControlTypography.windowHint, weight: .medium)
        label.textColor = SubtitleStyle.white(0.9)
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var fittingSize: NSSize {
        let size = label.intrinsicContentSize
        return NSSize(width: ceil(size.width) + 20, height: ceil(size.height) + 8)
    }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: 10, y: (bounds.height - size.height) / 2, width: bounds.width - 20, height: size.height)
    }
}

private final class PanelMenuAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}
final class ConversationLabel: NSTextField {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
final class ConversationScrollView: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
