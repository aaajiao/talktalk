// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import Observation
import TalkTalkApple
import TalkTalkAudio
import TalkTalkCore
import TalkTalkCloudUI
import TalkTalkSession
import TalkTalkVoice
import UserNotifications

/// The normal launch path (ARCHITECTURE.md §13): `TalkTalk` with no arguments starts the menu
/// bar app. One instance per build flavor (SingleInstance); a second launch brings the running
/// one's settings window forward and exits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var retained: AppDelegate?

    let state = AppState()
    private var statusItem: StatusItemController?
    private var settings: SettingsWindowController?
    private var meeting: MeetingController?
    private var onboarding: OnboardingWindowController?
    private var systemInput: SystemInputController?
    private var speak: SpeakController?
    private let conversationPanel = SubtitlePanel()
    private lazy var hud = PTTHUD(panel: conversationPanel)
    /// §1 / §7.6: the app's engine instance and the voice lifecycle built with it.
    let engineHost = EngineHost()
    private let smokeOut: String?
    private let isSmoke: Bool
    private var quitting = false
    private var languageObserver: NSObjectProtocol?
    private var appleCheckTask: Task<Void, Never>?

    init(smoke: Bool, smokeOut: String?) {
        isSmoke = smoke
        self.smokeOut = smokeOut
        super.init()
    }

    static func run(smoke: Bool = false, smokeOut: String? = nil) -> Never {
        guard SingleInstance.acquire() else {
            SingleInstance.signalRunningInstance()
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate(smoke: smoke, smokeOut: smokeOut)
        retained = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        exit(0)
    }

    private func refreshAppLanguage() {
        NSApp.mainMenu = MainMenu.make(settingsTarget: self)
        settings?.refreshAppLanguage()
        onboarding?.refreshAppLanguage()
        meeting?.refreshAppLanguage()
        systemInput?.refreshAppLanguage()   // its menu line is a stored sentence
        refreshAppleCheck()                 // so is 通用's and the menu's Apple summary
        hud.refreshAppLanguage()
        conversationPanel.refreshAppLanguage()
        statusItem?.refreshAppLanguage()
        updateIcon()   // a failure's status word is a localized menu line
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Capture the physical default before settings/audio setup can register a Feed client
        // and make the Mic appear. Reuse this watcher below; smoke never touches real input.
        let inputSwitcher = isSmoke ? nil : SystemInputSwitcher()
        inputSwitcher?.start()
        NSApp.mainMenu = MainMenu.make(settingsTarget: self)
        state.voiceStore.removeStaleStaging()   // §9.2: staging left by a crash
        let settings = SettingsWindowController(state: state, engineHost: engineHost)
        self.settings = settings
        // §11 首次引导 (app-ui): step 5 shares the settings window's TranslationPage.
        let onboardingModel = OnboardingFlowModel(appState: state, engine: AppUIModels.shared.engine,
                                                  translation: settings.translation)
        onboardingModel.voice.engineHost = engineHost
        onboardingModel.demo.panel = conversationPanel
        onboardingModel.demo.canStart = { [weak state] in
            state?.meetingActive == false && state?.meetingStarting == false
        }
        let onboarding = OnboardingWindowController(model: onboardingModel)
        onboardingModel.openScenario = { [weak state, weak settings, weak onboarding] mode in
            state?.requestedScenario = mode
            onboarding?.close()
            settings?.show(.meeting)
        }
        onboardingModel.openDriverComponents = { [weak settings, weak onboarding] in
            onboarding?.close()
            settings?.navigation.componentsTab = .driver
            settings?.show(.components)
        }
        AppUIModels.shared.general.onboarding = onboardingModel
        // 使用引导… continues unfinished onboarding at its step (the row shows "第 N 步，共 M 步")
        // and runs finished onboarding again.
        AppUIModels.shared.general.onOpenOnboarding = { [weak onboarding] in
            guard let onboarding else { return }
            if !onboarding.model.needsOnboarding { onboarding.model.restart() }
            onboarding.show()
        }
        self.onboarding = onboarding
        let privacy = isSmoke ? nil : PrivacySettings.shared
        let meeting = MeetingController(state: state, panel: conversationPanel, hud: hud, privacy: privacy,
            engineProcess: { [bridge = engineHost.speakBridge] in bridge.process })
        self.meeting = meeting
        hud.onEndSession = { [weak meeting, weak state, weak onboardingModel, weak conversationPanel] in
            if let state, state.meetingActive { meeting?.toggle(mode: state.meetingMode) }
            else {
                // Only the onboarding demo has 结束 without a session: it leaves in one step too.
                conversationPanel?.endSession()
                onboardingModel?.endSpeakDemo(); onboardingModel?.demo.stop()
            }
        }
        state.onToggleListening = { [weak meeting] mode in meeting?.toggle(mode: mode) }
        hud.onOpenSettings = { [weak settings, weak self] destination in
            switch destination {
            // As the menu's 检查麦克风…: the TalkTalk Mic section, which flashes.
            case .audio: settings?.show(.audio, nil, anchor: SettingsAnchor.talkTalkMic)
            case .translation:
                settings?.navigation.openModel(.translation)
                settings?.show(.translation)
            case .permissions: self?.openSystemAudioPermission()
            }
        }
        meeting.onSpeechAssetsInstalled = { [weak self] in self?.refreshAppleCheck() }
        meeting.prepareCloud = { [weak settings, weak onboardingModel] in
            onboardingModel?.demo.stop()
            let prefs = TranslationPreferences.load(.standard)
            guard prefs.cloudConsentGiven, prefs.listenCloudEnabled || prefs.speakCloudEnabled else { return false }
            settings?.translation.load()
            guard let model = settings?.translation.model else { return false }
            await model.loadKeyState()
            return model.prepareForSession()
        }
        meeting.knownCloudKeyPresence = { [weak settings] in
            guard let model = settings?.translation.model, model.keyStateKnown else { return nil }
            return model.hasKey
        }
        let profile = try? PolicyProfile.loadDefault()
        let output = isSmoke ? nil : profile.flatMap { try? SpeakOutput(profile: $0) }
        if let output { engineHost.setAuditionMonitor(MonitorAudition(monitor: output.monitor)) }
        // §8.6: not in the smoke run, which must not read or write the real default input.
        let systemInput = inputSwitcher.map { switcher in
            SystemInputController(state: state, events: meeting.events, hud: hud, switcher: switcher,
                waitForFeed: true, monitorUID: { output?.monitor.isSelfListenAudible == true ? output?.monitor.device?.uid : nil })
        }
        self.systemInput = systemInput
        hud.phoneInputIsConfirmed = { [weak systemInput] in
            guard let systemInput, systemInput.micGuard.state.verified,
                  let verdict = systemInput.micGuard.state.verdict,
                  case let .green(appID, _) = verdict else { return false }
            return appID == MeetingMode.phoneAppID
        }
        hud.onMeetingVoiceChange = { [weak state] voice in state?.meetingVoice = voice }
        hud.onPhoneVoiceChange = { [weak state] voice in
            state?.phoneVoice = voice
            if voice == nil { state?.phoneStatusDetailsPresented = false }
        }
        settings.driver.systemInput = systemInput   // 组件 › 虚拟麦克风 / 完全卸载 (§8.4)
        settings.driver.isChannel1Busy = { output?.isChannel1Busy ?? false }
        if let output, let profile, let systemInput {
            let speak = SpeakController(state: state, meeting: meeting, systemInput: systemInput,
                engineHost: engineHost, output: output, profile: profile, hud: hud,
                privacy: privacy,
                selfTestRunning: { [weak settings, weak privacy] in
                    settings?.driver.model?.selfTestRunning == true || privacy?.diagnosticsStatus.isAudioSelfTestRunning == true
                })
            speak.onChange = { [weak self, weak speak] in
                self?.state.speakSessionActive = speak?.isActive == true
                self?.updateIcon()
            }
            speak.onMonitorAvailabilityChange = { [weak settings, weak onboardingModel] in
                settings?.voice.refreshMonitorAvailability()
                onboardingModel?.voice.refreshMonitorAvailability()
            }
            onboardingModel.startSpeakDemo = { [weak speak, weak conversationPanel] in
                guard let speak else { throw SpeakController.DemoFailure.unavailable }
                conversationPanel?.setPresentation(.meeting)
                try await speak.beginOnboardingDemo()
            }
            onboardingModel.stopSpeakDemo = { [weak speak] in speak?.endOnboardingDemo() }
            speak.onDemoPlayed = { [weak onboardingModel] in onboardingModel?.demoPlayed() }
            speak.onDemoFailure = { [weak onboardingModel] message in onboardingModel?.demoFailed(message) }
            speak.onDemoStatus = { [weak onboardingModel] message in onboardingModel?.demoStatus(message) }
            self.speak = speak
        }
        onboardingModel.driverPage = settings.driver
        onboardingModel.startMeetingMicCheck = { [weak systemInput] update in systemInput?.startOnboardingCheck(update) }
        onboardingModel.stopMeetingMicCheck = { [weak systemInput] in systemInput?.stopOnboardingCheck() }
        if let privacy {
            privacy.diagnosticsStatus.beforeAudioSelfTest = { [weak engineHost] in await engineHost?.engine()?.stop() }
            privacy.diagnosticsStatus.canRunAudioSelfTest = { [weak self, weak settings, weak onboardingModel] in
                guard let self, let settings, let onboardingModel else { return false }
                return !state.meetingActive && !state.meetingStarting && speak?.isActive != true
                    && settings.voice.enrollment == nil && settings.voice.auditioning == nil
                    && onboardingModel.voice.enrollment == nil && onboardingModel.voice.auditioning == nil
                    && !AppUIModels.shared.engine.running && settings.driver.model?.selfTestRunning != true
            }
            settings.voice.externalBusy = { [weak privacy] in privacy?.diagnosticsStatus.isAudioSelfTestRunning == true }
            onboardingModel.voice.externalBusy = { [weak privacy] in privacy?.diagnosticsStatus.isAudioSelfTestRunning == true }
            settings.driver.externalBusy = { [weak privacy] in privacy?.diagnosticsStatus.isAudioSelfTestRunning == true }
        }
        meeting.canStartMeeting = { [weak privacy, weak self] in
            privacy?.diagnosticsStatus.isAudioSelfTestRunning != true && self?.speak?.isActive != true
                && !AppUIModels.shared.engine.running && self?.engineHost.maintenanceActive != true
        }
        meeting.beforeUserEnd = { [weak systemInput] in systemInput?.confirmUserEnd() }
        let status = StatusItemController(state: state, actions: .init(
            openSettings: { [weak self] section in self?.settings?.show(section) },
            openSettingsAt: { [weak self] section, subpage, anchor in self?.settings?.show(section, subpage, anchor: anchor) },
            toggleMeeting: { [weak meeting] in meeting?.toggle() },
            // As the titlebar's 结束: only a running session ends; a menu left open after the
            // session ended by itself never starts a new one.
            endSession: { [weak meeting, weak state] in
                if let state, state.meetingActive { meeting?.toggle(mode: state.meetingMode) }
            },
            quit: { NSApp.terminate(nil) },
            stillInMeeting: { [weak meeting] in meeting?.stillInMeeting() },
            // 继续使用引导 opens onboarding at its saved step (§8.2).
            openOnboarding: { [weak onboarding] in onboarding?.show() },
            openPermissions: { [weak self] in self?.openSystemAudioPermission() },
            onboarding: { [weak onboardingModel] in
                guard let onboardingModel, onboardingModel.needsOnboarding else { return .finished }
                return .unfinished(onboardingModel.progress)
            },
            canPlayAnnouncement: { [weak speak] in speak?.canPlayAnnouncement ?? false },
            playAnnouncement: { [weak speak] in speak?.playAnnouncement() },
            usesGlobalListenFallback: { [weak meeting] in meeting?.session?.usesGlobalFallback ?? false },
            setGlobalListenFallback: { [weak meeting] enabled in meeting?.setGlobalListenFallback(enabled) },
            systemInputItems: { [weak systemInput] in
                guard let s = systemInput else { return (false, false, false) }
                return (s.showsSwitchBack, s.showsRestoreNow, s.showsResumeFromRecord)
            },
            switchBackToMic: { [weak systemInput] in systemInput?.switchBack() },
            restoreDefaultInput: { [weak systemInput] in systemInput?.restoreNow() },
            canRestoreSubtitleWindow: { [weak conversationPanel] in conversationPanel?.canRestoreWindow ?? false },
            restoreSubtitleWindow: { [weak conversationPanel] in conversationPanel?.restoreWindow() },
            quickStart: { [weak meeting, weak self] mode in
                meeting?.quickStart(mode: mode) { mode in
                    self?.state.requestedScenario = mode
                    self?.settings?.show(.meeting)
                }
            },
            voiceState: { [weak hud] in hud?.model.voiceState },
            systemInputSwitched: { [weak self] in self?.systemInputSwitched ?? false },
            speakUsesCloud: { [weak meeting] in meeting?.cloud.box.speak != nil },
            recording: { [weak privacy] in
                guard let privacy else { return (nil, false) }
                let recorder = privacy.recorder, analysis = privacy.subtitleAnalysis
                // RecordingBanner's words (DiagnosticsBanners): the tracks, else what is set.
                let recording: StatusMenuFacts.Recording? = !recorder.recordingTracks.isEmpty
                    ? .recording(tracks: DiagnosticRecorder.Track.allCases.filter(recorder.recordingTracks.contains)
                                    .map(\.label).joined(separator: " · "))
                    : recorder.micAndTTSArmed ? .planned(thisSession: recorder.meetingRunning) : nil
                return (recording, analysis.isRecording || analysis.isStarting)
            }))
        statusItem = status
        meeting.onActiveChange = { [weak self] _ in self?.updateIcon() }
        meeting.onTranslationChange = { [weak self] in self?.updateIcon() }
        systemInput?.onStatusChange = { [weak self] in
            self?.updateIcon()
            self?.syncEndHelp()
        }
        syncEndHelp()
        languageObserver = NotificationCenter.default.addObserver(
            forName: AppLanguageStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAppLanguage() }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: SingleInstance.reopenNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showFront() }
        }

        // §7.5 item 6, in the background; the menu shows a status line when something is missing.
        Task { [weak self, isSmoke] in
            if !isSmoke { await AppleSpeechASR.reserveInstalledLocales() }   // the smoke run changes nothing
            self?.refreshAppleCheck()
        }
        followAppleAssets()

        // The installer (onboarding step 4, Settings › 组件) changed the installation: build or
        // drop the engine instance; Settings' 重启引擎 restarts that instance.
        engineHost.onChange = { [weak self] in self?.engineChanged() }
        engineChanged()
        followInstallation()
        followIconFacts()
        followStartAvailability()

        systemInput?.start()
        speak?.prepareLaunchTakeover()
        updateIcon()
        hud.setSubtitlesVisible(state.subtitlesVisible)

        if isSmoke {
            runSmoke()
        } else if onboardingModel.needsOnboarding {
            onboarding.show()   // §11 首次引导, resumes at the saved step
        }
        if !isSmoke {
            Task { await AppUIModels.shared.general.refreshNotifications() }
            // Clicking the auto-end notification restores a minimized subtitle window.
            if BuildFlavor.current != .bare { UNUserNotificationCenter.current().delegate = self }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isSmoke else { return }
        Task { await AppUIModels.shared.general.refreshNotifications() }
        // Back from System Settings or a download elsewhere: Apple resources may be complete now.
        refreshAppleCheck()
    }

    /// §7.5 item 6 again (status APIs only: no prompt, no download, no network), so 通用's row
    /// and the menu's "Apple 资源待配置" leave once the resources are in place.
    private func refreshAppleCheck() {
        appleCheckTask?.cancel()
        appleCheckTask = Task { [state] in
            let r = await AppleStartupCheckItem().run()
            guard !Task.isCancelled else { return }
            state.appleCheck = r.level == .ok ? nil : String(appLocalized: "Apple：\(r.summary)")
        }
    }

    /// Onboarding step 2's downloads, and onboarding finishing: the Apple check runs again.
    private func followAppleAssets() {
        guard let model = onboarding?.model else { return }
        withObservationTracking { _ = (model.assets, model.step) } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshAppleCheck()
                self?.followAppleAssets()
            }
        }
    }

    /// `state.meetingAvailable`: the menu's quick start and the scenario page's 开始 share one
    /// answer, from the same facts `canStartMeeting` reads and the onboarding state (§8.2).
    private func followStartAvailability() {
        let available = withObservationTracking {
            _ = (state.speakSessionActive, onboarding?.model.step, onboarding?.model.steps,
                 onboarding?.model.choosingScenarios, engineHost.maintenanceActive, AppUIModels.shared.engine.running)
            return onboarding?.model.needsOnboarding != true && meeting?.canStartMeeting() != false
        } onChange: { [weak self] in
            Task { @MainActor in self?.followStartAvailability() }
        }
        if state.meetingAvailable != available { state.meetingAvailable = available }
    }

    /// The titlebar's and the menu's 权限设置… for an unconfirmed system-audio grant: onboarding
    /// when it waits on that very step, else System Settings' pane (as a denied start does).
    private func openSystemAudioPermission() {
        if let o = onboarding, o.model.needsOnboarding, o.model.step == .permissions { o.show() }
        else { MeetingController.openSystemAudioPrivacy() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showFront()
        return false
    }

    @objc func openSettings(_ sender: Any?) { settings?.show() }

    private func engineChanged() {
        let engine = engineHost.engine()
        state.installedEngineProfile = engineHost.recognitionProfile
        let components = AppUIModels.shared.engine
        // nil on success; EngineFailure's description already says "去设置 › 组件 修复".
        // restartFromSettings also schedules the §7.6 idle exit after the restart.
        components.restart = engine == nil ? nil : { [weak engineHost] in
            do { try await engineHost?.restartFromSettings(); return nil } catch { return "\(error)" }
        }
        components.stopEngine = { [weak engineHost] in await engineHost?.engine()?.stop() }
        components.beginMaintenance = { [weak engineHost] in await engineHost?.beginMaintenance() }
        components.maintenanceFinished = { [weak engineHost] in engineHost?.endMaintenance() }
        components.sessionActive = { [weak self] in
            guard let self else { return true }
            // These observable voice fields cover recording, enrollment/save, generation and
            // playback. SPEAK owns its demo until asynchronous shutdown has fully completed.
            let voices = [settings?.voice, onboarding?.model.voice].compactMap { $0 }
            return state.meetingActive || state.meetingStarting || state.meetingStopping
                || state.speakSessionActive || speak?.isActive == true
                || voices.contains { $0.enrollment != nil || $0.auditioning != nil || $0.deleting || $0.externalBusy() }
                || settings?.driver.model?.selfTestRunning == true
                || AppUIModels.shared.engine.blocked
        }
        // 组件未就绪 and the system voice follow the engine at once, not the next session.
        updateIcon()
    }

    /// The icon's facts that change without a callback of their own: preparing and ending, the
    /// recognition fallback or failure, how the last session ended, engine maintenance and the
    /// onboarding path (§11, settings visual system §8.5).
    private func followIconFacts() {
        withObservationTracking {
            _ = (state.meetingStarting, state.meetingStopping, state.listenASRFallback, state.listenASRFailure,
                 state.lastEndProblem, state.lastEndAutomatic, engineHost.maintenanceActive, onboarding?.model.steps)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateIcon()
                self?.followIconFacts()
            }
        }
    }

    private func followInstallation() {
        let model = AppUIModels.shared.engine
        withObservationTracking { _ = (model.state, model.record) } onChange: { [weak self] in
            Task { @MainActor in
                self?.engineHost.sync()
                self?.followInstallation()
            }
        }
    }

    /// TalkTalk holds the system default input, so ending gives an app that follows it the
    /// physical microphone back (the 结束 help, titlebar and menu).
    private var systemInputSwitched: Bool {
        if case .holding = systemInput?.switcher.status { return true }
        return false
    }

    private func syncEndHelp() {
        conversationPanel.setEndInputSwitched(systemInputSwitched)
        state.systemInputHeld = systemInputSwitched
    }

    /// §11 icon from the meeting, its translation and the system input's leftovers (§8.6), and
    /// the facts behind it that the menu names in their own lines (§8.1).
    private func updateIcon() {
        let micGuard = systemInput?.micGuard.state ?? .init()
        let readWhileInactive = systemInput?.micReadWhileInactive ?? false
        let speakerMode = systemInput?.route.state.speakerMode
        let systemVoice = state.voiceProfilePresent && engineHost.routing.source == .systemVoice
        let speakDegraded = (speak?.degraded ?? false) && meeting?.cloud.box.speak != nil
        // Engine maintenance drops the instance on purpose; a path without the engine step (视频
        // only, which runs on Apple recognition) never installed one.
        let enginePath = onboarding?.model.steps.contains(.engine) ?? true
        let componentsMissing = engineHost.engine() == nil && !engineHost.maintenanceActive && enginePath
        let asrFailed = state.listenASRFailure != nil
        let lastEndFailed = state.lastEndProblem != nil
        let icon = MenuBarIcon.compute(meetingActive: state.meetingActive,
                                       systemInput: systemInput?.switcher.status ?? .idle,
                                       translationDegraded: state.listenTranslationDegraded && state.listenTranslation != .appleOnly,
                                       micGuard: micGuard,
                                       mode: state.meetingMode,
                                       phonePrepared: state.phoneReadyToDial,
                                       talkTalkMicReadWhileInactive: readWhileInactive,
                                       componentsMissing: componentsMissing,
                                       listenReady: meeting?.session?.listenLanguage != nil,
                                       // 正在准备… / 正在结束… in the menu: hourglass here too.
                                       warming: (speak?.warming ?? false) || state.meetingStarting || state.meetingStopping,
                                       speaking: speak?.speaking ?? false,
                                       passthroughOpen: speak?.passthroughOpen ?? false,
                                       speakerMode: speakerMode,
                                       systemVoice: systemVoice,
                                       speakTranslationDegraded: speakDegraded,
                                       asrFallback: state.listenASRFallback,
                                       asrFailed: asrFailed,
                                       lastEndFailed: lastEndFailed)
        let reasons = MenuBarIcon.reasons(meetingActive: state.meetingActive, micGuard: micGuard, mode: state.meetingMode,
                                          phonePrepared: state.phoneReadyToDial, talkTalkMicReadWhileInactive: readWhileInactive,
                                          speakerMode: speakerMode, systemVoice: systemVoice,
                                          speakTranslationDegraded: speakDegraded)
        statusItem?.setIcon(icon, reasons: reasons,
                            words: MenuBarIcon.failureText(icon, meetingActive: state.meetingActive, mode: state.meetingMode,
                                                           asrFailed: asrFailed, lastEndFailed: lastEndFailed))
    }

    /// A second launch or a Dock click restores a minimized subtitle window first; otherwise
    /// it opens the unfinished onboarding or settings as before.
    private func showFront() {
        #if TALKTALK_DEV
        if isSmoke, CommandLine.arguments.contains("--preview") {
            guard hud.model.meetingActive else { return }
            if conversationPanel.canRestoreWindow { conversationPanel.restoreWindow() }
            conversationPanel.markPreviewForSmoke()
            return
        }
        #endif
        if conversationPanel.canRestoreWindow {
            conversationPanel.restoreWindow()
            return
        }
        if let o = onboarding, o.model.needsOnboarding { o.show() } else { settings?.show() }
    }

    /// Quit restores the input managed by this instance, then tears down speech and the engine.
    /// Only a restore failure needs an actionable notice; normal exit has no choice dialog.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateLater }
        // quit() never cancels termination, so the window may leave first, in one step.
        conversationPanel.endSession()
        let reply = systemInput?.quit() ?? .terminateNow
        guard reply == .terminateNow else { return reply }
        quitting = true
        AppUIModels.shared.engine.installer?.cancel()
        settings?.voice.endRecording()
        Task {
            // A running session ends as 结束 does: meeting.end, the recordings' .json, the
            // transcript and the auto-end notification are finished before SPEAK goes.
            await meeting?.session?.stop(.user)
            await speak?.shutdown()
            await engineHost.engine()?.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        settings?.voice.endRecording()
        ListenDemo.removeTemporaryFiles()
    }

    /// `--smoke-ui` (dev build): opens settings on 我的声音, reports what is on screen, quits after
    /// 1.5 s. `--preview` keeps a UI-only fixture open; `--preview-scene` chooses a scene and
    /// `--preview-speaking` keeps my live text visible. No audio or system-input owner is started.
    private func runSmoke() {
        settings?.show(.voice)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            let window = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue == "TalkTalkSettings" }
            var r: [String: Any] = [
                "op": "smoke-ui",
                "flavor": BuildFlavor.current.rawValue,
                "status_item": statusItem != nil,
                "settings_visible": window != nil,
                "section": settings?.navigation.selection?.rawValue ?? "",
                "profile_present": state.voiceProfilePresent,
                "recording_view": settings?.voice.enrollment != nil,
                "onboarding_needed": onboarding?.model.needsOnboarding ?? false,
                "system_input_switcher": systemInput != nil,   // must be false: smoke never touches the default input
                "speak_output": speak != nil,
                "activation_policy": NSApp.activationPolicy() == .regular ? "regular" : "accessory",
            ]
            if let window {
                r["window_size"] = [Int(window.frame.width), Int(window.frame.height)]
                if let fit = window.contentView?.fittingSize { r["content_fitting_size"] = [Int(fit.width), Int(fit.height)] }
                if let screen = window.screen { r["screen_visible_height"] = Int(screen.visibleFrame.height) }
            }
            if let panel = meeting?.panel {
                // The subtitle panel's configuration (§11), with a sample board; no audio involved.
                panel.apply(.source("so the budget for next year"))
                panel.apply(.final(sentence: 1, text: "明年的预算", source: "the budget for next year", approx: true, numberWarning: false)) // l10n-ignore
                panel.apply(.draft(sentence: 2, text: "草稿")) // l10n-ignore
                panel.beginSession()
                panel.setVisible(true)
                let cb = panel.collectionBehavior
                r["subtitle_panel"] = [
                    "visible": panel.isVisible,
                    "sharing_none": panel.sharingTypeIsNone,
                    "all_spaces": cb.contains(.canJoinAllSpaces),
                    "full_screen_aux": cb.contains(.fullScreenAuxiliary),
                    "click_through": panel.clickThrough,
                    "lines": panel.shownLines,
                ] as [String: Any]
                #if TALKTALK_DEV
                hud.setSubtitlesVisible(true)
                hud.meetingStarted()
                hud.setPushToTalkAvailable(true)
                hud.meetingAudio(.translating)
                hud.transcript(.init(press: 1, source: "明天讨论 API 的预算。", target: "We will discuss the API budget tomorrow.", isFinal: false)) // l10n-ignore
                hud.pushToTalk(.holding(level: 0.4, preview: "", committed: [], queued: 0))
                hud.renderForSmoke()
                var combined: [String: Any] = [
                    "same_window": hud.windowNumber == panel.windowNumber,
                    "visible_window_count": NSApp.windows.filter { $0.isVisible && $0.identifier?.rawValue == "TalkTalkConversation" }.count,
                    "remote_visible": panel.isVisible,
                    "local_visible": hud.isVisible && hud.transcriptSourceForSmoke != nil,
                    "movable": panel.isMovable,
                    "resizable": panel.isResizable,
                    "manual_size": panel.hasManualSize,
                    "base_font_size": panel.baseFontSize,
                    "effective_font_size": panel.fontSize,
                    "can_become_key": panel.canBecomeKey,
                    "sharing_none": panel.sharingTypeIsNone && hud.sharingTypeIsNone,
                ]
                hud.meetingAudio(.original)
                hud.renderForSmoke()
                combined["original_hides_draft"] = hud.transcriptSourceForSmoke == nil
                hud.meetingAudio(.translating)
                hud.transcript(.init(press: 1, source: "明天讨论 API 的预算。", target: "We will discuss the API budget tomorrow.", isFinal: true)) // l10n-ignore
                hud.renderForSmoke()
                panel.setVisible(false)
                hud.setSubtitlesVisible(false)
                combined["subtitle_toggle_hides_both_texts"] = !panel.isVisible && hud.transcriptSourceForSmoke == nil
                combined["audio_status_remains"] = hud.isVisible && !hud.shownLines.isEmpty
                r["conversation_panel"] = combined
                if CommandLine.arguments.contains("--preview") {
                    let scene = argumentValue("--preview-scene").flatMap { SubtitlePanel.Presentation(rawValue: $0) }
                    let speaking = CommandLine.arguments.contains("--preview-speaking")
                    configureSmokePreview(panel, scene: scene, speaking: speaking)
                    panel.markPreviewForSmoke()
                    window?.orderOut(nil)
                    NSApp.setActivationPolicy(.accessory)
                    r["preview"] = true
                    r["preview_scene"] = panel.presentation.rawValue
                    r["preview_speaking"] = speaking
                    r["preview_fixture"] = scene == nil && !speaking ? "original-risk" : "static-scene"
                    r["preview_window_visible"] = panel.isWindowVisible
                    r["settings_visible"] = false
                    writeResult(r, to: smokeOut)
                    return
                }
                hud.meetingEnded()
                hud.setSubtitlesVisible(state.subtitlesVisible)
                #endif
                panel.endSession()
                panel.clear(includingMyTurns: true)
            }
            if let devices = settings?.voice.enrollment?.devices {
                r["devices"] = devices.map { ["transport": $0.info.transport, "accepted": $0.verdict.isAccepted] as [String: Any] }
            }
            smokeOnboarding(into: r)
        }
    }

    #if TALKTALK_DEV
    /// Feed only the presentation models. In particular, no MeetingController start/toggle,
    /// Phone opener, microphone capture, output device or default-input write is involved.
    private func configureSmokePreview(_ panel: SubtitlePanel, scene requested: SubtitlePanel.Presentation?, speaking: Bool) {
        let previewTime = hud.clock()
        hud.clock = { previewTime }
        panel.openPhone = {} // Show the real Phone control without launching another app.
        hud.onEndSession = { [weak hud, weak panel] in
            panel?.endSession()
            hud?.meetingEnded()
        }
        // Keep the established risk/details fixture when no scene or speaking sample is asked for.
        guard requested != nil || speaking else {
            hud.pushToTalk(.idle)
            hud.meetingAudio(.unavailable(reason: String(appLocalized: "会议仍在使用实体麦")))
            hud.post(.remoteHearsYourVoice)
            hud.setSubtitlesVisible(true)
            hud.renderForSmoke()
            panel.setVisible(true)
            return
        }

        let scene = requested ?? .meeting
        hud.meetingEnded()
        panel.clear(includingMyTurns: true)
        panel.setPresentation(scene)
        panel.setSourceName(scene == .video ? "Safari" : scene == .phone ? "Phone" : "Google Meet")
        panel.setRemoteLanguageTitle(Lang.en.title)
        panel.setPhoneContext(scene == .phone ? String(appLocalized: "界面预览（无音频）") : nil)
        panel.setPhoneActionsEnabled(true)
        panel.setClickThroughLocked(false)
        panel.setVideoQuietDimEnabled(false)
        // This is a simulated input fact only; the smoke path has no SystemInputController.
        hud.phoneInputIsConfirmed = { scene == .phone }
        hud.meetingStarted()
        hud.setPushToTalkAvailable(scene != .video)
        hud.meetingAudio(scene == .video ? nil : speaking ? .translating : .original)
        hud.pushToTalk(speaking ? .holding(level: 0.4, preview: "", committed: [], queued: 0) : .idle)
        if speaking {
            hud.transcript(.init(press: 2, source: "我们可以先确认时间，再讨论展览的具体安排。", // l10n-ignore
                                 target: "Let's confirm the time first, then discuss the exhibition arrangements.", isFinal: false))
        }
        let source = scene == .video
            ? "Tomorrow we will explore how artists use sound and moving images to shape a shared space."
            : "We can review the exhibition schedule together and confirm the details tomorrow."
        let translation = scene == .video
            ? "明天我们将探讨艺术家如何用声音与影像，构建一个共同的空间。" // l10n-ignore
            : "我们可以一起查看展览日程，明天再确认具体安排。" // l10n-ignore
        panel.apply(.final(sentence: 1, text: translation, source: source, approx: false, numberWarning: false))
        hud.setSubtitlesVisible(true)
        hud.renderForSmoke()
        panel.setVisible(true)
    }
    #endif

    /// app-ui's onboarding on a throwaway defaults suite (the user's own progress is untouched):
    /// step 1 is passed with the dev facts *before* the window opens, so its automatic afplay
    /// probe (TCC) never runs; then the window is shown and the rest is walked with `devFinish`.
    private func smokeOnboarding(into result: [String: Any]) {
        #if TALKTALK_DEV
        guard let settings else { writeResult(result, to: smokeOut); exit(0) }
        let suite = "talktalk.smoke.onboarding"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        // voice.engineHost stays nil: step 6 cannot start a take (no microphone in the smoke run).
        let model = OnboardingFlowModel(defaults: defaults, appState: state, engine: AppUIModels.shared.engine,
                                        translation: settings.translation, autoProbe: false)
        let o = OnboardingWindowController(model: model)
        let first = model.step
        model.devAdvance()
        o.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            var r = result
            let w = NSApp.windows.first { $0.isVisible && $0.title == String(appLocalized: "欢迎使用 TalkTalk") }
            let shown = model.step
            let visited = [first].compactMap { $0 } + model.devFinish()
            r["onboarding_window"] = [
                "visible": w != nil,
                "size": w.map { [Int($0.frame.width), Int($0.frame.height)] } ?? [],
                "shown_step": shown.map { "\($0)" } ?? "done",
                "visited": visited.map { "\($0)" },
                "finished": model.step == nil,
                "closed_on_finish": !o.isVisible,
            ] as [String: Any]
            o.close()
            defaults.removePersistentDomain(forName: suite)
            writeResult(r, to: smokeOut)
            exit(0)
        }
        #else
        writeResult(result, to: smokeOut)
        exit(0)
        #endif
    }
}

/// The only notification is the auto-end warning: clicking it activates TalkTalk and brings a
/// minimized subtitle window back, as a Dock click does; 继续收听 stays in the menu.
extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            if conversationPanel.canRestoreWindow { conversationPanel.restoreWindow() }
        }
    }
}

/// An accessory app has no menu bar of its own, but the settings window still needs the Edit
/// menu's key equivalents (⌘C / ⌘V / ⌘A in the OpenAI key box) and ⌘W / ⌘Q.
enum MainMenu {
    @MainActor static func make(settingsTarget: AnyObject? = nil) -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: String(appLocalized: "关于 TalkTalk"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: String(appLocalized: "设置…"), action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: ",")
        settings.target = settingsTarget
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: String(appLocalized: "隐藏 TalkTalk"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: String(appLocalized: "隐藏其他"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: String(appLocalized: "全部显示"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: String(appLocalized: "退出 TalkTalk"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: String(appLocalized: "编辑"))
        edit.addItem(NSMenuItem(title: String(appLocalized: "撤销"), action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: String(appLocalized: "重做"), action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: String(appLocalized: "剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: String(appLocalized: "拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: String(appLocalized: "粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: String(appLocalized: "全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: String(appLocalized: "窗口"))
        window.addItem(NSMenuItem(title: String(appLocalized: "关闭"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }
}
