// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import TalkTalkCore
import TalkTalkSession
import TalkTalkSettingsUI

/// The menu bar icon and its menu (settings visual system §8, ARCHITECTURE.md "菜单"). The menu
/// is rebuilt each time it opens from `AppState` through `StatusMenu.rows`, so it never shows
/// stale state; this class only draws the rows and maps their commands to actions.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    struct Actions {
        var openSettings: (SettingsSection?) -> Void
        /// A problem row's fix (§8.5): the page, its sub-page and the section that flashes.
        var openSettingsAt: (SettingsSection, SettingsSubpage?, String?) -> Void = { _, _, _ in }
        var toggleMeeting: () -> Void
        /// The in-session "结束<场景>": ends at once, as the titlebar does.
        var endSession: () -> Void = {}
        var quit: () -> Void
        var stillInMeeting: () -> Void = {}
        var openOnboarding: () -> Void = {}
        /// Whether onboarding is unfinished, and at which step (state A).
        var onboarding: () -> OnboardingProgressState = { .finished }
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
        /// The idle menu's quick start: starts directly; opens the scenario page only on failure
        /// or when a source must be chosen.
        var quickStart: (MeetingMode) -> Void = { _ in }
        /// The titlebar's voice capsule state (HUDModel.voiceState), for the in-session rows.
        var voiceState: () -> VoiceState? = { nil }
        /// TalkTalk holds the system default input (the 结束 help's raw-voice branch).
        var systemInputSwitched: () -> Bool = { false }
        /// The session's 我说话 translates with OpenAI (the cloud line, §5.4).
        var speakUsesCloud: () -> Bool = { false }
        /// The diagnostic recording and the subtitle analysis (the recording lines, §5.4).
        var recording: () -> (recording: StatusMenuFacts.Recording?, savingSubtitleText: Bool) = { (nil, false) }
    }

    enum OnboardingProgressState {
        case finished
        /// nil: not placed on a step yet (the scenario page is up).
        case unfinished(OnboardingProgress?)
    }

    private let state: AppState
    private let actions: Actions
    private let item: NSStatusItem
    private(set) var iconState: MenuBarIcon = .standby
    /// The icon's facts that have no menu line of their own (`MenuBarIcon.reasons`).
    private var iconReasons: [MenuBarIcon.Reason] = []
    /// The menu's commands by item tag, rebuilt with the menu.
    private var commands: [StatusMenuCommand] = []
    /// The rows that follow the session while the menu is open (one-second tick).
    private weak var sessionHeader: NSMenuItem?
    private weak var voiceItem: NSMenuItem?
    private weak var deliveryItem: NSMenuItem?
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
        setIcon(.standby)
    }

    func refreshAppLanguage() {
        setIcon(iconState, reasons: iconReasons)
        if let menu = item.menu { menuNeedsUpdate(menu) }
    }

    func setIcon(_ s: MenuBarIcon, reasons: [MenuBarIcon.Reason] = []) {
        iconState = s
        iconReasons = reasons
        let words = s.statusText(mode: state.meetingMode)
        item.button?.image = iconImage(s, accessibilityDescription: words)
        // Missing components dim the glyph (a shape difference from standby, not only words);
        // appearsDisabled changes appearance only, so the menu still opens to repair setup.
        item.button?.appearsDisabled = s == .missing
        let name = BuildFlavor.current == .dev ? "TalkTalk Dev" : "TalkTalk"
        item.button?.toolTip = "\(name) · \(words)"
    }

    /// The status item's image. Normal states are template images; problems keep their colour:
    /// orange for unconfirmed or degraded audio, red for repairs and for the titlebar's risk
    /// glyph (the other party hears the original).
    private func iconImage(_ s: MenuBarIcon, accessibilityDescription: String?) -> NSImage? {
        let size = NSFont.systemFontSize
        switch s {
        case .remoteHearsOriginal:
            guard let risk = SubtitleStyle.symbol(s.symbol, size: size, weight: .regular,
                                                  accessibilityDescription: accessibilityDescription) else { return nil }
            return SubtitleStyle.tinted(risk, .systemRed)
        case .needsAttention, .degraded, .audioNeedsCheck:
            let color: NSColor = s == .needsAttention ? .systemRed : .systemOrange
            return SubtitleStyle.symbol(s.symbol, size: size, weight: .regular,
                                        accessibilityDescription: accessibilityDescription, palette: [color])
        default:
            let image = SubtitleStyle.symbol(s.symbol, size: size, weight: .regular,
                                             accessibilityDescription: accessibilityDescription)
            image?.isTemplate = true
            return image
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        headerTimer?.invalidate()
        guard sessionHeader != nil || voiceItem != nil || deliveryItem != nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLiveRows() }
        }
        RunLoop.main.add(timer, forMode: .common)
        headerTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        headerTimer?.invalidate()
        headerTimer = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        commands = []
        sessionHeader = nil
        voiceItem = nil
        deliveryItem = nil
        shownMenuVoice = nil
        let facts = currentFacts()
        shownMenuVoice = facts.voice
        for row in StatusMenu.rows(facts) {
            let mi = menuItem(row)
            switch row.live {
            case .sessionTitle?: sessionHeader = mi
            case .voice?: voiceItem = mi
            case .phoneDelivery?: deliveryItem = mi
            case nil: break
            }
            menu.addItem(mi)
        }
    }

    /// What the menu reads now (§8): the session, the checks and the problems.
    private func currentFacts() -> StatusMenuFacts {
        var f = StatusMenuFacts()
        if case let .unfinished(progress) = actions.onboarding() {
            f.onboardingNeeded = true
            f.onboardingProgress = progress
        }
        f.phase = state.meetingStopping ? .stopping
            : state.meetingActive ? .running
            : state.meetingStarting ? .starting : .idle
        f.mode = state.meetingMode
        f.lastScenario = state.lastScenario
        f.quickStartSource = switch state.lastScenario ?? .meeting {
        case .meeting: MenuQuickStart.sourceName(state.meetingSourceID)
        case .captions: MenuQuickStart.sourceName(state.videoSourceID)
        case .phone: nil
        }
        let listening = state.listenLanguages(for: state.lastScenario ?? .meeting)
        f.listenLanguage = listening.source.title
        f.listenTargetLanguage = listening.target.title
        f.meetingApp = state.meetingApp
        f.elapsed = state.meetingStartedAt.map { Date().timeIntervalSince($0) }
        f.voice = actions.voiceState()
        f.phoneStatus = state.phoneStatus
        // The scene page's and 音频's check (one source): 视频字幕 and the idle menu ignore it.
        let check = ScenarioFacts(state: state, mode: state.meetingMode).sessionCheck
        f.micCheck = notice(check)
        f.meetingHint = state.meetingHint
        f.meetingHintKind = state.meetingHintKind
        f.lastEndProblem = state.lastEndProblem
        f.appleCheck = state.appleCheck
        f.systemInput = state.systemInputNotice.flatMap(notice)
        let input = actions.systemInputItems()
        f.switchBack = input.switchBack
        f.restoreNow = input.restoreNow
        f.resumeFromRecord = input.resumeFromRecord
        f.asrFallback = state.listenASRFallback
        f.asrStatus = state.listenASRStatus
        f.asrFailure = state.listenASRFailure
        f.translation = state.listenTranslation
        f.speakCloud = actions.speakUsesCloud()
        f.offline = state.listenOffline
        (f.recording, f.savingSubtitleText) = actions.recording()
        f.subtitlesVisible = state.subtitlesVisible
        f.monitor = AppUIModels.shared.audio.monitor
        f.canPlayAnnouncement = actions.canPlayAnnouncement()
        f.canRestoreWindow = actions.canRestoreSubtitleWindow()
        f.subtitleLocked = state.videoSubtitleLocked
        f.usesGlobalFallback = state.meetingActive && actions.usesGlobalListenFallback()
        f.icon = iconState
        f.iconReasons = iconReasons
        f.systemInputSwitched = actions.systemInputSwitched()
        f.meetingAvailable = state.meetingAvailable
        f.devBuild = BuildFlavor.current == .dev
        let version = AppVersion.current
        f.appName = version.name
        f.appVersion = version.displayString
        return f
    }

    /// A check that has passed is no line.
    private func notice(_ problem: SettingsProblem) -> StatusMenuFacts.Notice? {
        let tone: StatusMenuTone? = switch problem.status {
        case .risk: .risk
        case .failed: .failed
        case .warn: .warn
        case .pending, .waiting, .busy: .pending
        case .ok, .recording: nil
        }
        return tone.map { StatusMenuFacts.Notice($0, problem.text, help: problem.help) }
    }

    /// The default-input notice in the menu's tones; "系统麦克风：TalkTalk Mic" while holding is
    /// normal, no problem line.
    private func notice(_ line: HUDLine) -> StatusMenuFacts.Notice? {
        let tone: StatusMenuTone? = switch line.style {
        case .red, .redBanner: .failed
        case .yellow: .warn
        case .secondary: .pending
        case .normal, .check: nil
        }
        return tone.map { StatusMenuFacts.Notice($0, line.text, help: line.detail) }
    }

    // MARK: - drawing

    private func menuItem(_ row: StatusMenuRow) -> NSMenuItem {
        if case .separator = row.kind { return .separator() }
        let mi = NSMenuItem(title: row.title, action: nil, keyEquivalent: row.keyEquivalent ?? "")
        mi.target = self
        if let command = row.command { bind(mi, command) }
        if case let .toggle(_, on) = row.kind { mi.state = on ? .on : .off }
        mi.isEnabled = row.isEnabled && row.kind != .status
        mi.subtitle = row.subtitle
        mi.toolTip = row.help
        mi.indentationLevel = row.indented ? 1 : 0
        mi.image = row.symbol.flatMap { image($0, tone: row.tone) }
        // A problem line's words take its colour (§8.1); bold for 继续使用引导 and the quick start.
        let color = row.kind == .status ? problemColor(row.tone) : nil
        if row.bold || color != nil {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: row.bold ? NSFont.boldSystemFont(ofSize: menuFontSize) : NSFont.menuFont(ofSize: 0)]
            if let color { attributes[.foregroundColor] = color }
            mi.attributedTitle = NSAttributedString(string: row.title, attributes: attributes)
        }
        return mi
    }

    private func bind(_ mi: NSMenuItem, _ command: StatusMenuCommand) {
        mi.action = #selector(run(_:))
        mi.tag = commands.count
        commands.append(command)
    }

    private var menuFontSize: CGFloat { NSFont.menuFont(ofSize: 0).pointSize }

    /// A 13 pt menu glyph (§4 L4): template, or filled with the row's colour; the risk glyph
    /// gets its fallback badge where the system lacks it.
    private func image(_ symbol: String, tone: StatusMenuTone?) -> NSImage? {
        guard let glyph = SubtitleStyle.symbol(symbol, size: menuFontSize, weight: .regular) else { return nil }
        let color: NSColor? = switch tone {
        case let .voice(voice)?: SubtitleStyle.toneColor(voice)
        // RecordingBanner's colours: red while recording, orange while set or saving text.
        case let .recording(active)?: active ? .systemRed : .systemOrange
        default: problemColor(tone)
        }
        guard let color else {
            glyph.isTemplate = true
            return glyph
        }
        return SubtitleStyle.tinted(glyph, color)
    }

    private func problemColor(_ tone: StatusMenuTone?) -> NSColor? {
        switch tone {
        case .risk?, .failed?: .systemRed
        case .warn?: .systemOrange
        case .pending?, .voice?, .recording?, nil: nil
        }
    }

    /// The session title's clock, the voice row and Phone's delivery follow the titlebar while
    /// the menu is open.
    private func refreshLiveRows() {
        guard state.meetingActive else { return }
        if let sessionHeader {
            sessionHeader.title = MenuSessionHeader.title(mode: state.meetingMode, source: state.meetingApp,
                                                          elapsed: state.meetingStartedAt.map { Date().timeIntervalSince($0) })
        }
        let voice = actions.voiceState()
        guard voice != shownMenuVoice else { return }
        shownMenuVoice = voice
        if let voiceItem {
            voiceItem.isHidden = voice == nil
            if let voice {
                voiceItem.title = StatusMenu.voiceTitle(voice)
                voiceItem.image = image(voice.symbol, tone: .voice(voice.appearance.tone))
                voiceItem.toolTip = voice.detail
            }
        }
        if let deliveryItem {
            let confirmed = ScenarioFacts(state: state, mode: .phone).phoneCheck.status == .ok
            let delivery = voice.flatMap { PhoneDelivery($0.kind, phoneInputConfirmed: confirmed) }
            deliveryItem.isHidden = delivery == nil
            if let delivery {
                deliveryItem.title = delivery.text
                deliveryItem.image = image(delivery.symbol, tone: nil)
            }
        }
    }

    // MARK: - actions

    @objc private func run(_ sender: NSMenuItem) {
        guard commands.indices.contains(sender.tag) else { return }
        switch commands[sender.tag] {
        case .continueOnboarding: actions.openOnboarding()
        case let .quickStart(mode): actions.quickStart(mode)
        case .resumeFromRecord: actions.toggleMeeting()
        case let .openScene(mode):
            state.requestedScenario = mode
            actions.openSettings(.meeting)
        case let .open(destination): open(destination)
        case .end: actions.endSession()
        case .restoreSubtitleWindow: actions.restoreSubtitleWindow()
        case .openPhone: state.onOpenPhone?()
        case .stillInMeeting: actions.stillInMeeting()
        case .switchBackToMic: actions.switchBackToMic()
        case .restoreDefaultInput: actions.restoreDefaultInput()
        case .toggleSubtitles: state.subtitlesVisible.toggle()
        case .toggleMonitor: AppUIModels.shared.audio.monitor.toggle()
        case .toggleSubtitleLock: state.videoSubtitleLocked.toggle()
        case .toggleGlobalFallback: actions.setGlobalListenFallback(!actions.usesGlobalListenFallback())
        case .playAnnouncement: actions.playAnnouncement()
        case .settings: actions.openSettings(nil)
        // The app identity row also keeps access to the standard About panel.
        case .about: NSApp.orderFrontStandardAboutPanel(nil)
        case .quit: actions.quit()
        }
    }

    /// The exact page, sub-page and section of a problem row's fix (§6.4, §8.1, §8.5): the
    /// section scrolls into view and flashes, also when that page is already shown.
    private func open(_ destination: StatusMenuDestination) {
        switch destination {
        case .talkTalkMic: actions.openSettingsAt(.audio, nil, SettingsAnchor.talkTalkMic)
        case .playback: actions.openSettingsAt(.audio, nil, SettingsAnchor.playback)
        case .recognition: actions.openSettingsAt(.translation, .model(.recognition), SettingsAnchor.recognition)
        case .translation: actions.openSettingsAt(.translation, .model(.translation), SettingsAnchor.translation)
        case .components: actions.openSettingsAt(.components, .components(.engine), SettingsAnchor.engine)
        case .onboarding: actions.openSettingsAt(.general, nil, SettingsAnchor.onboarding)
        case .diagnosticRecording:
            actions.openSettingsAt(.privacy, .diagnostics(.troubleshooting), SettingsAnchor.diagnosticRecording)
        case .subtitleAnalysis: actions.openSettingsAt(.privacy, .diagnostics(.subtitles), SettingsAnchor.subtitleAnalysis)
        }
    }

}
