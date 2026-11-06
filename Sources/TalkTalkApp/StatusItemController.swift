// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import TalkTalkCore
import TalkTalkSession

/// The menu bar icon and its menu (ARCHITECTURE.md §11 "菜单栏图标状态" and "菜单"). The menu
/// is rebuilt each time it opens, from `AppState`, so it never shows stale state.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    struct Actions {
        var openSettings: (SettingsSection?) -> Void
        var toggleMeeting: () -> Void
        var quit: () -> Void
        var stillInMeeting: () -> Void = {}
        var openOnboarding: () -> Void = {}
        var canPlayAnnouncement: () -> Bool = { false }
        var playAnnouncement: () -> Void = {}
        var usesGlobalListenFallback: () -> Bool = { false }
        /// The owner presents the capture warning before enabling the fallback.
        var setGlobalListenFallback: (Bool) -> Void = { _ in }
        /// System default input (§8.6): which menu items apply now, and their actions.
        var systemInputItems: () -> (switchBack: Bool, restoreNow: Bool, resumeFromRecord: Bool) = { (false, false, false) }
        var switchBackToMic: () -> Void = {}
        var restoreDefaultInput: () -> Void = {}
        var canRestoreSubtitleWindow: () -> Bool = { false }
        var restoreSubtitleWindow: () -> Void = {}
        /// The idle menu's quick start (redesign §7): starts directly; opens the scenario page
        /// only on failure or when a source must be chosen.
        var quickStart: (MeetingMode) -> Void = { _ in }
        /// The titlebar's voice capsule state (HUDModel.voiceState), for the in-session header.
        var voiceState: () -> VoiceState? = { nil }
    }

    /// §11 icon states from the current meeting and SPEAK session.
    enum IconState {
        case missing, standby, warming, listening, speaking, passthroughOpen, audioNeedsCheck, degraded, needsAttention

        var symbol: String {
            switch self {
            case .missing: "captions.bubble"
            case .standby: "captions.bubble"
            case .warming: "hourglass"
            case .listening: "captions.bubble.fill"
            case .speaking: "waveform"
            case .passthroughOpen: "mic.fill"
            case .audioNeedsCheck, .degraded: "exclamationmark.triangle"
            case .needsAttention: "exclamationmark.bubble"
            }
        }
    }

    private let state: AppState
    private let actions: Actions
    private let item: NSStatusItem
    private(set) var iconState: IconState = .standby
    /// The in-session header and its one-second clock while the menu is open.
    private weak var sessionHeader: NSMenuItem?
    /// The capsule's state line; refreshed with the header so a new risk shows while open.
    private weak var voiceItem: NSMenuItem?
    private var shownMenuVoice: VoiceState?
    private var headerTimer: Timer?

    init(state: AppState, actions: Actions) {
        self.state = state
        self.actions = actions
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Keep the user's menu-bar placement associated with this item across launches.
        item.autosaveName = "TalkTalkStatusItem"
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        setIcon(IconState.standby)
    }

    func setIcon(_ m: MenuBarIcon) {
        switch m {
        case .missing: setIcon(IconState.missing)
        case .warming: setIcon(IconState.warming)
        case .standby: setIcon(IconState.standby)
        case .listening: setIcon(IconState.listening)
        case .speaking: setIcon(IconState.speaking)
        case .passthroughOpen: setIcon(IconState.passthroughOpen)
        case .audioNeedsCheck: setIcon(IconState.audioNeedsCheck)
        case .degraded: setIcon(IconState.degraded)
        case .needsAttention: setIcon(IconState.needsAttention)
        }
    }

    func setIcon(_ s: IconState) {
        iconState = s
        var image = NSImage(systemSymbolName: s.symbol, accessibilityDescription: statusDescription)
        if s == .needsAttention || s == .degraded || s == .audioNeedsCheck {
            image = image?.withSymbolConfiguration(.init(paletteColors: [s == .needsAttention ? .systemRed : .systemOrange]))
        } else {
            image?.isTemplate = true
        }
        item.button?.image = image
        item.button?.appearsDisabled = false // the menu remains the way to inspect and repair setup
        let name = BuildFlavor.current == .dev ? "TalkTalk Dev" : "TalkTalk"
        item.button?.toolTip = "\(name) · \(statusDescription)"
    }

    /// Normal microphone activity is not an error. Name the state as well as changing its
    /// symbol, and keep the specific audio warning visible in the menu.
    private var statusDescription: String {
        switch iconState {
        case .missing: return String(localized: "语音组件尚未就绪")
        case .standby: return String(localized: "待机 · 尚未开始收听")
        case .warming: return String(localized: "正在准备语音引擎")
        case .listening:
            return String(localized: "\(state.meetingMode.displayTitle)运行中")
        case .speaking: return String(localized: "正在识别或播放译音")
        case .passthroughOpen: return String(localized: "原声中 · 点按右⌥开始翻译")
        case .audioNeedsCheck: return String(localized: "音频尚未就绪")
        case .degraded: return String(localized: "部分功能使用备用方案")
        case .needsAttention: return String(localized: "音频设备需要检查")
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        headerTimer?.invalidate()
        guard sessionHeader != nil || voiceItem != nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSessionHeader()
                self?.refreshVoiceLine()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        headerTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        headerTimer?.invalidate()
        headerTimer = nil
    }

    private var sessionHeaderTitle: String {
        MenuSessionHeader.title(mode: state.meetingMode, source: state.meetingApp,
                                elapsed: state.meetingStartedAt.map { Date().timeIntervalSince($0) })
    }

    private func refreshSessionHeader() {
        guard let sessionHeader, state.meetingActive else { return }
        sessionHeader.attributedTitle = NSAttributedString(string: sessionHeaderTitle, attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize)])
    }

    /// The voice line follows the titlebar while the menu is open (one-second tick).
    private func refreshVoiceLine() {
        guard let voiceItem, state.meetingActive else { return }
        let voice = actions.voiceState()
        guard voice != shownMenuVoice else { return }
        shownMenuVoice = voice
        voiceItem.isHidden = voice == nil
        if let voice { configureVoiceLine(voiceItem, voice) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        sessionHeader = nil
        voiceItem = nil
        shownMenuVoice = nil
        let mode = state.meetingMode.displayTitle
        let busy = state.meetingActive || state.meetingStarting || state.meetingStopping
        if state.meetingActive, !state.meetingStopping {
            // §7: "会议同传 · Zoom · 12:03" and the capsule's state as a dot and text.
            let header = statusLine(sessionHeaderTitle)
            menu.addItem(header)
            sessionHeader = header
            refreshSessionHeader()
            if let voice = actions.voiceState() {
                let line = voiceLine(voice)
                menu.addItem(line)
                voiceItem = line
                shownMenuVoice = voice
            }
            if iconState != .listening { menu.addItem(statusLine(statusDescription)) }
        } else if busy {
            menu.addItem(statusLine(state.meetingStarting ? String(localized: "正在准备\(mode)…")
                                                          : String(localized: "正在结束\(mode)…")))
        } else {
            addQuickStart(to: menu)
        }
        if actions.canRestoreSubtitleWindow() {
            menu.addItem(item(String(localized: "恢复字幕窗口"), #selector(restoreSubtitleWindow), symbol: "macwindow"))
        }
        menu.addItem(.separator())

        if busy {
            let stop = item(String(localized: "结束\(mode)"), #selector(toggleMeeting), symbol: SubtitleTokens.VoiceIcon.end)
            stop.isEnabled = !state.meetingStarting && !state.meetingStopping
            menu.addItem(stop)
        } else {
            let meeting = item(String(localized: "会议同传…"), #selector(openMeetingMode), symbol: SubtitleTokens.SceneIcon.meeting)
            meeting.isEnabled = state.meetingAvailable
            menu.addItem(meeting)
            let phone = item(String(localized: "电话同传…"), #selector(openPhoneMode), symbol: SubtitleTokens.SceneIcon.phone)
            phone.isEnabled = state.meetingAvailable
            menu.addItem(phone)
            let captions = item(String(localized: "视频字幕…"), #selector(openVideoMode), symbol: SubtitleTokens.SceneIcon.video)
            captions.isEnabled = state.meetingAvailable
            menu.addItem(captions)
            if iconState != .standby { menu.addItem(statusLine(statusDescription)) }
        }
        menu.addItem(.separator())

        if state.meetingMode == .phone, state.meetingActive || state.meetingStarting {
            if let status = state.phoneStatus { menu.addItem(statusLine(status)) }
            menu.addItem(item(String(localized: "打开 Phone 拨号或接听"), #selector(openPhone)))
            menu.addItem(item(String(localized: "电话同传设置…"), #selector(openPhoneMode)))
            menu.addItem(.separator())
        }

        // Problems and recovery stay one click away, including leftovers outside a session.
        var attention: [NSMenuItem] = []
        if let hint = state.meetingHint {
            attention.append(statusLine(hint))
            if hint == MeetingSession.Hint.meetingSeemsOver.rawValue ||
                (state.meetingMode == .phone && state.meetingActive && state.meetingHint != nil) {
                attention.append(item(String(localized: "继续收听，不自动停止"), #selector(stillInMeeting)))
            }
        }
        if let apple = state.appleCheck {
            attention.append(detailItem(HUDLine(String(localized: "Apple 资源待配置"), .yellow,
                                                detail: apple, symbol: "shippingbox"),
                                        actionTitle: String(localized: "打开使用引导…"), action: #selector(openOnboarding)))
        }
        if let input = state.systemInputNotice {
            attention.append(detailItem(input, actionTitle: String(localized: "查看音频设置…"), action: #selector(openAudio)))
        }
        if state.meetingActive, state.meetingMode.supportsSpeaking {
            attention.append(detailItem(meetingMicNotice, actionTitle: String(localized: "检查会议麦克风…"), action: #selector(openAudio)))
        }
        let si = actions.systemInputItems()
        if si.switchBack { attention.append(item(String(localized: "切回 TalkTalk Mic"), #selector(switchBackToMic))) }
        if si.resumeFromRecord, !state.meetingActive {
            attention.append(item(String(localized: "开始会议同传（恢复输入设备记录）"), #selector(toggleMeeting)))
        }
        if si.restoreNow { attention.append(item(String(localized: "现在还原默认输入"), #selector(restoreDefaultInput))) }
        if !attention.isEmpty {
            attention.forEach { menu.addItem($0) }
            menu.addItem(.separator())
        }

        let allApps = state.meetingActive && actions.usesGlobalListenFallback()
        if state.meetingActive {
            let sourceName = state.meetingApp ?? String(localized: "正在确认应用")
            let sourceTitle: String
            if allApps { sourceTitle = String(localized: "正在收听：所有应用（备用）") }
            else {
                switch state.meetingMode {
                case .meeting: sourceTitle = String(localized: "会议应用：\(sourceName)")
                case .phone: sourceTitle = String(localized: "通话应用：Phone")
                case .captions: sourceTitle = String(localized: "视频来源：\(sourceName)")
                }
            }
            menu.addItem(statusLine(sourceTitle))
            menu.addItem(item(String(localized: "查看当前场景…"), #selector(openCurrentScene)))
            let language = NSMenuItem(title: String(localized: "字幕：\(languageName(state.remoteLanguage)) → 中文"), action: nil, keyEquivalent: "")
            let languages = NSMenu()
            languages.autoenablesItems = false
            for lang in AppState.RemoteLanguage.allCases {
                let choice = item(lang.title, #selector(chooseLanguage(_:)))
                choice.representedObject = lang.rawValue
                choice.state = state.remoteLanguage == lang ? .on : .off
                languages.addItem(choice)
            }
            language.submenu = languages
            menu.addItem(language)

            let videoOnly = state.meetingMode == .captions && (state.meetingActive || state.meetingStarting || state.meetingStopping)
            if !videoOnly {
                let speak = NSMenuItem(title: String(localized: "我说话：中文 → \(languageName(state.speakLanguage))"), action: nil, keyEquivalent: "")
                let targets = NSMenu()
                targets.autoenablesItems = false
                targets.addItem(statusLine(String(localized: "中文可夹英语，译音统一为所选语言")))
                for lang in AppState.RemoteLanguage.allCases {
                    let choice = item(lang.title, #selector(chooseSpeakLanguage(_:)))
                    choice.representedObject = lang.rawValue
                    choice.state = state.speakLanguage == lang ? .on : .off
                    targets.addItem(choice)
                }
                speak.submenu = targets
                menu.addItem(speak)
            }
            let subtitles = item(String(localized: "显示字幕"), #selector(toggleSubtitles))
            subtitles.state = state.subtitlesVisible ? .on : .off
            menu.addItem(subtitles)
            // Video only (§6 鼠标穿透); the only place that unlocks a locked window.
            if SubtitleClickThrough.offersLock(scene: state.meetingMode == .captions ? .video : .meeting,
                                               sessionActive: videoOnly) {
                let lock = item(String(localized: "锁定字幕位置（鼠标穿透）"), #selector(toggleSubtitleLock),
                                symbol: SubtitleTokens.VoiceIcon.locked)
                lock.state = state.videoSubtitleLocked ? .on : .off
                menu.addItem(lock)
            }
            if !videoOnly {
                let monitor = item(String(localized: "在耳机中听到译音"), #selector(toggleMonitor))
                monitor.state = AppUIModels.shared.audio.monitor ? .on : .off
                menu.addItem(monitor)
                if actions.canPlayAnnouncement() {
                    menu.addItem(item(String(localized: "现在播放告知语"), #selector(playAnnouncement)))
                }
            }

        }

        var running: [NSMenuItem] = []
        if let asr = state.listenASRStatus {
            running.append(detailItem(HUDLine(String(localized: "语音识别"), detail: asr, symbol: "waveform"),
                                      actionTitle: String(localized: "识别与模型设置…"), action: #selector(openModels)))
        }
        if state.meetingActive, let translation = state.listenTranslation {
            let title: String
            let style: HUDLine.Style
            switch translation {
            case .appleOnly: title = String(localized: "字幕翻译：Apple"); style = .normal
            case .openAI where !state.listenOffline: title = String(localized: "字幕翻译：OpenAI"); style = .normal
            default: title = String(localized: "字幕翻译：Apple 备用"); style = .yellow
            }
            running.append(detailItem(HUDLine(title, style, detail: translation.menuText(offline: state.listenOffline),
                                              symbol: "character.bubble"),
                                      actionTitle: String(localized: "翻译与模型设置…"), action: #selector(openModels)))
        }
        if !running.isEmpty {
            menu.addItem(.separator())
            running.forEach { menu.addItem($0) }
        }
        menu.addItem(.separator())
        let settings = item(String(localized: "设置…"), #selector(openSettings), symbol: "gearshape")
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(item(String(localized: "隐私与诊断…"), #selector(openDiagnostics), symbol: "stethoscope"))
        let more = item(String(localized: "更多"), nil, symbol: "ellipsis.circle")
        let tools = NSMenu()
        tools.autoenablesItems = false
        tools.addItem(item(String(localized: "我的声音…"), #selector(openVoice)))
        tools.addItem(item(String(localized: "使用引导…"), #selector(openOnboarding)))
        tools.addItem(item(String(localized: "通知设置…"), #selector(openGeneral)))
        tools.addItem(item(String(localized: "关于 TalkTalk \(AppVersion.current.version)…"), #selector(openAbout)))
        tools.addItem(.separator())
        let globalListen = item(String(localized: "收听所有应用声音（备用）"), #selector(toggleGlobalListenFallback))
        globalListen.state = allApps ? .on : .off
        globalListen.isEnabled = state.meetingActive && !state.meetingStopping && state.meetingMode.allowsGlobalFallback
        tools.addItem(globalListen)
        more.submenu = tools
        menu.addItem(more)
        menu.addItem(.separator())
        let quit = item(BuildFlavor.current == .dev ? String(localized: "退出 TalkTalk Dev") : String(localized: "退出 TalkTalk"), #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    /// Idle: the bold primary "开始会议同传 · Zoom" and the gray "上次：…" line.
    private func addQuickStart(to menu: NSMenu) {
        let last = state.lastScenario
        let mode = last ?? .meeting
        let source: String? = switch mode {
        case .meeting: MenuQuickStart.sourceName(state.meetingSourceID)
        case .captions: MenuQuickStart.sourceName(state.videoSourceID)
        case .phone: nil
        }
        let quick = MenuQuickStart.make(last: last, sourceName: source, remoteLanguage: languageName(state.remoteLanguage))
        let start = item(quick.title, #selector(quickStart), symbol: MenuQuickStart.symbol)
        start.attributedTitle = NSAttributedString(string: quick.title, attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize)])
        start.representedObject = quick.mode.rawValue
        start.isEnabled = state.meetingAvailable
        menu.addItem(start)
        if let line = quick.lastLine { menu.addItem(statusLine(line)) }
    }

    /// The capsule's state with a dot of the same colour (§7).
    private func voiceLine(_ voice: VoiceState) -> NSMenuItem {
        let line = statusLine(voice.accessibilityLabel)
        configureVoiceLine(line, voice)
        return line
    }

    private func configureVoiceLine(_ line: NSMenuItem, _ voice: VoiceState) {
        line.title = voice.accessibilityLabel
        let color = Self.dotColor(voice.appearance.tone)
        line.image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        line.toolTip = voice.detail
    }

    private static func dotColor(_ tone: VoiceTone) -> NSColor {
        func token(_ role: SubtitleTokens.Color) -> NSColor {
            NSColor(name: nil) { appearance in
                let light = appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
                return SubtitleStyle.nsColor(role.rgba(lightSurface: light))
            }
        }
        return switch tone {
        case .original: token(.voiceOriginal)
        case .translate: token(.voiceTranslate)
        case .warn: token(.warn)
        case .risk: token(.riskFill)
        case .neutral: .tertiaryLabelColor
        }
    }

    private func languageName(_ language: AppState.RemoteLanguage) -> String {
        language == .en ? String(localized: "英语") : String(localized: "德语")
    }

    private func item(_ title: String, _ action: Selector?, symbol: String? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        if let symbol {
            mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            mi.image?.isTemplate = true
        }
        return mi
    }

    private func statusLine(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    private var meetingMicNotice: HUDLine {
        let check = AppUIModels.shared.audio.meetingMic
        switch check {
        case .physicalMic:
            var line = HUDModel.Warning.remoteHearsYourVoice.line
            line.detail = check.text
            return line
        case .green:
            return HUDLine(String(localized: "会议麦克风：TalkTalk Mic"), .check, detail: check.text, symbol: "checkmark.circle")
        case .notChecked:
            return HUDLine(String(localized: "会议麦克风待确认"), .secondary, detail: check.text, symbol: "mic")
        case .nobodyReads:
            return HUDLine(String(localized: "会议尚未使用 TalkTalk Mic"), .secondary, detail: check.text, symbol: "mic")
        }
    }

    /// Only the short consequence sizes the parent menu. Full explanations wrap in its submenu.
    private func detailItem(_ line: HUDLine, actionTitle: String, action: Selector) -> NSMenuItem {
        let parent = item(line.text, nil, symbol: line.symbol)
        let color: NSColor? = switch line.style {
        case .red, .redBanner: .systemRed
        case .yellow: .systemOrange
        case .check: .systemGreen
        case .normal, .secondary: nil
        }
        if let color {
            parent.attributedTitle = NSAttributedString(string: line.text, attributes: [.foregroundColor: color])
            parent.image?.isTemplate = false
            parent.image = parent.image?.withSymbolConfiguration(.init(paletteColors: [color]))
        }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(wrappedDetail(line.detail ?? line.text))
        submenu.addItem(.separator())
        submenu.addItem(item(actionTitle, action, symbol: "arrow.up.forward.app"))
        parent.submenu = submenu
        return parent
    }

    private func wrappedDetail(_ text: String) -> NSMenuItem {
        let width: CGFloat = 340
        let inset: CGFloat = 12
        let font = NSFont.menuFont(ofSize: 13)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = width - 2 * inset
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width - 2 * inset, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        let height = ceil(bounds.height) + 4
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height + 2 * inset))
        label.frame = NSRect(x: inset, y: inset, width: width - 2 * inset, height: height)
        view.addSubview(label)
        let detail = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        detail.isEnabled = false
        detail.view = view
        return detail
    }

    // MARK: - actions

    @objc private func restoreSubtitleWindow() { actions.restoreSubtitleWindow() }
    @objc private func toggleMeeting() { actions.toggleMeeting() }
    @objc private func quickStart(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = MeetingMode(rawValue: raw) else { return }
        actions.quickStart(mode)
    }
    @objc private func openMeetingMode() {
        state.requestedScenario = .meeting
        actions.openSettings(.meeting)
    }
    @objc private func openVideoMode() {
        state.requestedScenario = .captions
        actions.openSettings(.meeting)
    }
    @objc private func openCurrentScene() {
        state.requestedScenario = state.meetingMode
        actions.openSettings(.meeting)
    }
    @objc private func openPhoneMode() {
        state.requestedScenario = .phone
        actions.openSettings(.meeting)
    }
    @objc private func openPhone() { state.onOpenPhone?() }
    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let lang = AppState.RemoteLanguage(rawValue: raw) {
            state.remoteLanguage = lang
        }
    }
    @objc private func toggleSubtitles() {
        state.subtitlesVisible.toggle()
    }
    @objc private func toggleSubtitleLock() { state.videoSubtitleLocked.toggle() }
    @objc private func chooseSpeakLanguage(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let lang = AppState.RemoteLanguage(rawValue: raw) {
            state.speakLanguage = lang
        }
    }
    @objc private func toggleMonitor() { AppUIModels.shared.audio.monitor.toggle() }
    @objc private func stillInMeeting() { actions.stillInMeeting() }
    @objc private func openOnboarding() { actions.openOnboarding() }
    @objc private func playAnnouncement() { actions.playAnnouncement() }
    @objc private func toggleGlobalListenFallback() { actions.setGlobalListenFallback(!actions.usesGlobalListenFallback()) }
    @objc private func switchBackToMic() { actions.switchBackToMic() }
    @objc private func restoreDefaultInput() { actions.restoreDefaultInput() }
    @objc private func openSettings() { actions.openSettings(nil) }
    @objc private func openGeneral() { actions.openSettings(.general) }
    @objc private func openAudio() { actions.openSettings(.audio) }
    @objc private func openModels() { actions.openSettings(.translation) }
    @objc private func openAbout() { NSApp.orderFrontStandardAboutPanel(nil) }
    @objc private func openVoice() { actions.openSettings(.voice) }
    @objc private func openDiagnostics() { actions.openSettings(.privacy) }
    @objc private func quit() { actions.quit() }
}
