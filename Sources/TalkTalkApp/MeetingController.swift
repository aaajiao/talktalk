// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import SwiftUI
import TalkTalkApple
import TalkTalkAudio
import TalkTalkCore
import TalkTalkEngineHost
import TalkTalkCloudUI
import TalkTalkSession
import TalkTalkSettingsUI

/// Menu ↔ MeetingSession ↔ SubtitlePanel (ARCHITECTURE.md §11). Starting asks only what the
/// user must decide: which meeting app when several are in a call, the system permission when
/// it is missing, the speech-asset download when the locale is not installed.
@MainActor
final class MeetingController {
    private let state: AppState
    let panel: SubtitlePanel
    private(set) var session: MeetingSession?
    private var subtitleSessionID: UUID?
    private var listenConfigurationTask: Task<Void, Never>?
    private var listenRequestID = UUID()
    private var awaitingListenReset = false
    private var captionsEngine: EngineProcess?
    private var captionsWarmup: Task<Void, Never>?
    private var captionsEngineCleanup: Task<Void, Never>?
    /// The concrete process used by this session's Qwen factory, including a failed start.
    private var listenEngine: EngineProcess?
    private var earlyEngine: EngineProcess?
    private var phoneReadinessDetail: String?
    private let languagePopover = NSPopover()
    private let engineProcess: @Sendable () -> EngineProcess?
    private let defaults: UserDefaults
    var onActiveChange: ((Bool) -> Void)?
    /// The finals' source or the network changed (menu line, icon).
    var onTranslationChange: (() -> Void)?
    /// Runs before a user end, while meeting mode is still on: restores the system input (§8.6).
    var beforeUserEnd: (() -> Void)?
    var prepareCloud: (() async -> Bool)?
    /// Live metadata only, read on the main actor when the session's backend is constructed.
    var knownCloudKeyPresence: (@MainActor @Sendable () -> Bool?)?
    var canStartMeeting: () -> Bool = { true }
    private let hud: PTTHUD?
    private let privacy: PrivacySettings?
    private var transcript: TranscriptWriter?
    /// Meeting lifecycle for every subscriber (system input switching, SPEAK, diagnostics); one
    /// hub for the app's lifetime, handed to each meeting's session.
    let events = MeetingEvents()
    private var ui: MeetingSubscription?
    private(set) lazy var cloud = ListenCloud(events: events)

    init(state: AppState, panel: SubtitlePanel, hud: PTTHUD? = nil, defaults: UserDefaults = .standard, privacy: PrivacySettings? = nil,
         engineProcess: @escaping @Sendable () -> EngineProcess? = { nil }) {
        self.state = state
        self.panel = panel
        self.hud = hud
        self.defaults = defaults
        self.privacy = privacy
        self.engineProcess = engineProcess
        state.onListenConfigurationChange = { [weak self] in self?.listenConfigurationChanged() }
        state.onLanguagePresentationChange = { [weak self] in self?.applyLanguagePresentation() }
        state.onSubtitleAppearanceChange = { [weak self] in self?.applySubtitleAppearance() }
        panel.onPresentationChange = { [weak self] in self?.applySubtitleAppearance() }
        state.onSubtitleVisibilityChange = { [weak self] on in self?.setSubtitlesVisible(on) }
        state.onOpenPhone = { [weak self] in self?.openPhone() }
        state.onRefreshSources = { [weak self] in self?.refreshSourceOptions() }
        panel.openPhone = { [weak self] in self?.openPhone() }
        panel.onLockRequest = { [weak self] in self?.state.videoSubtitleLocked = true }
        panel.onLanguage = { [weak self] anchor in self?.showLanguageEditor(from: anchor) }
        languagePopover.behavior = .transient
        languagePopover.animates = false
        applySubtitleAppearance()
        panel.analysisRecorder = privacy?.subtitleAnalysis
        ui = events.subscribe { [weak self] e in
            switch e {
            case let .state(st): self?.sessionState(st)
            case .stopping:
                self?.languagePopover.close()
                // Every end reason: the window leaves as the stop begins (redesign §9.2.2); the menu shows
                // 正在结束… until the session reaches idle.
                self?.state.meetingStopping = true
                self?.panel.endSession()
                self?.refreshPhoneContext()
            case let .hint(h):
                self?.state.meetingHintKind = self?.state.meetingMode == .phone && h == .meetingSilent ? nil : h
                if self?.state.meetingMode == .phone {
                    let text: String?
                    switch h {
                    case .meetingSilent?: text = nil
                    case .meetingSeemsOver?: text = String(appLocalized: "Phone 已长时间没有通话音频，即将结束电话同传。")
                    default: text = h?.localizedDescription
                    }
                    self?.state.meetingHint = text
                    // Phone uses the same persistent issue surface as the other scenes.
                    // Silence itself is ordinary; the auto-end warning and actual failures
                    // must survive removal of the old explanatory footer.
                    self?.hud?.listen(h == .meetingSilent ? nil : h)
                    self?.refreshPhoneContext()
                } else {
                    self?.state.meetingHint = h?.localizedDescription
                    self?.hud?.listen(h)
                }
            case .started(_, _, let lang, _):
                self?.hud?.meetingStarted()
                self?.privacy?.recorder.meetingStarted(lang: lang)
            case .suspended(let reason): self?.privacy?.recorder.meetingSuspended(String(describing: reason))
            case .resumed: self?.privacy?.recorder.meetingResumed()
            case .ended(let reason):
                self?.state.lastEndProblem = reason == .failed ? self?.state.meetingMode : nil
                self?.releaseCaptionsEngine()
                self?.hud?.meetingEnded()
                self?.privacy?.recorder.meetingEnded(reason.rawValue)
                self?.transcript?.finish(); self?.transcript = nil
            case let .translation(t):
                guard let self, !self.awaitingListenReset else { return }
                self.state.listenTranslation = t
                self.onTranslationChange?()
            default: break
            }
        }
        cloud.onChange = { [weak self] in
            guard let self else { return }
            self.state.listenOffline = self.cloud.offline
            self.onTranslationChange?()
        }
    }

    /// Presentation only: switching the interface never restarts the listening/audio session.
    func refreshAppLanguage() {
        if let kind = state.meetingHintKind {
            state.meetingHint = state.meetingMode == .phone && kind == .meetingSeemsOver
                ? String(appLocalized: "Phone 已长时间没有通话音频，即将结束电话同传。")
                : kind.localizedDescription
        }
        applyLanguagePresentation()
        refreshPhoneContext()
    }

    /// Apps that currently have Core Audio process objects. Phone is reserved for its scene.
    func sources() -> [MeetingApp] {
        ((try? MeetingSourceResolver().currentCandidates()) ?? []).map(\.app)
    }

    func refreshSourceOptions() {
        let options = sources().filter { $0.id != MeetingMode.phoneAppID }
            .map { AppState.SourceOption(id: $0.id, name: $0.name) }
        if state.availableSources != options { state.availableSources = options }
    }

    func setSubtitlesVisible(_ on: Bool) {
        panel.setVisible(on && state.meetingActive)
        hud?.setSubtitlesVisible(on)
    }

    private func applySubtitleAppearance() {
        applyLanguagePresentation()
        panel.setSourceName(state.meetingMode == .phone ? "Phone" : state.meetingApp)
        panel.announcesNewTranslations = state.announceNewTranslations
        // Only the video window uses these; the panel ignores them in other scenes.
        panel.setClickThroughLocked(state.videoSubtitleLocked)
        panel.setVideoQuietDimEnabled(state.videoLongSilenceDim)
        switch panel.presentation {
        case .meeting:
            panel.setFontSize(state.subtitleFontSize)
            panel.setBackgroundOpacity(state.subtitleBackgroundOpacity)
        case .video:
            panel.setVideoCaptionStyle(state.videoCaptionStyle)
            panel.setVideoCaptionArrangement(state.videoCaptionArrangement)
            panel.setFontSize(state.videoSubtitleFontSize)
            panel.setBackgroundOpacity(state.videoSubtitleBackgroundOpacity)
        case .phone:
            panel.setFontSize(state.phoneSubtitleFontSize)
            panel.setBackgroundOpacity(state.phoneSubtitleBackgroundOpacity)
        }
    }

    private var subtitleMode: MeetingMode {
        switch panel.presentation { case .meeting: .meeting; case .phone: .phone; case .video: .captions }
    }

    private func applyLanguagePresentation() {
        let mode = subtitleMode
        panel.setLanguages(listening: state.listenLanguages(for: mode),
                           speaking: mode.supportsSpeaking ? state.speakLanguages(for: mode) : nil)
    }

    private func showLanguageEditor(from anchor: NSView) {
        if languagePopover.isShown { languagePopover.performClose(anchor); return }
        let content = SceneLanguageEditor(state: state, mode: subtitleMode).padding(16).frame(width: 360)
        let controller = NSHostingController(rootView: content.appLanguage())
        let size = controller.view.fittingSize
        controller.preferredContentSize = size
        controller.view.frame = NSRect(origin: .zero, size: size)
        languagePopover.contentViewController = controller
        languagePopover.contentSize = size
        languagePopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    /// Ends at once, with no confirmation: the window leaves in this turn, before the input
    /// restore can post a notice into it, and the stop continues in the background.
    func toggle(mode: MeetingMode = .meeting) {
        guard !state.meetingStopping else { return }   // one stop
        if state.meetingActive {
            let requestedAt = HostClock.now()
            session?.eventLog?.event("meeting.end_requested", at: requestedAt)
            panel.endSession()
            state.meetingStopping = true
            if session?.mode.supportsSpeaking == true {
                beforeUserEnd?()
                session?.eventLog?.event("meeting.input_restore_finished", [
                    "elapsed_ms": .int(HostClock.ms(requestedAt, to: HostClock.now()))
                ])
            }
            refreshPhoneContext()
            Task {
                await session?.stop(.user)
                state.meetingStopping = false
            }
        } else if !state.meetingStarting {
            state.requestedScenario = mode
            Task { await start(mode: mode) }
        }
    }

    /// The menu's quick start (redesign §7): start the scenario directly with its remembered
    /// source. When a source must be chosen, or starting fails, the scenario page opens instead
    /// (after the usual alert); an explicitly chosen source that is missing is never replaced.
    func quickStart(mode: MeetingMode, openScenario: @escaping @MainActor (MeetingMode) -> Void) {
        guard !state.meetingActive, !state.meetingStarting, !state.meetingStopping else { return }
        state.requestedScenario = mode
        Task {
            await start(mode: mode, askForChoice: false)
            if !lastStartSucceeded, !state.meetingActive, !state.meetingStarting { openScenario(mode) }
        }
    }

    func stillInMeeting() { session?.stillInMeeting() }

    func openPhone() {
        Task {
            do { try await NativePhone.open() }
            catch {
                state.phoneProblem = String(appLocalized: "无法打开 Phone，请从“应用程序”中打开后重试。")
                refreshPhoneContext()
            }
        }
    }

    /// Readiness is reported by the actual SPEAK/Feed and input path, never by a timer.
    func updatePhoneReadiness(_ ready: Bool, detail: String? = nil) {
        guard state.meetingMode == .phone else { return }
        let available = ready && state.meetingActive && !state.meetingStopping
        guard state.phoneReadyToDial != available || phoneReadinessDetail != detail else { return }
        state.phoneReadyToDial = available
        phoneReadinessDetail = detail
        refreshPhoneContext()
    }

    func phoneSpeechFailed(_ failedSession: MeetingSession?) {
        guard let failedSession, session === failedSession, state.meetingMode == .phone else { return }
        state.phoneReadyToDial = false
        state.phoneProblem = String(appLocalized: "电话发言链路未能启动，同传已结束。请检查组件、麦克风和输入监控权限后重新准备。")
        refreshPhoneContext()
        Task {
            guard self.session === failedSession else { return }
            await failedSession.stop(.failed)
        }
    }

    private func refreshPhoneContext() {
        guard state.meetingMode == .phone else { return }
        // While stopping, the window is already gone and the menu says 正在结束… once.
        guard (state.meetingActive || state.meetingStarting) && !state.meetingStopping else {
            hud?.setSceneIssue(nil)
            panel.setPhoneContext(nil)
            return
        }
        // Audio readiness already has typed gate/route warnings. Only distinct Phone
        // operation failures belong here, avoiding a second generic ready/status sentence.
        hud?.setSceneIssue(state.phoneProblem.map {
            HUDChip(titlebarLabel("电话需要检查"), symbol: "exclamationmark.triangle", tone: .warn, detail: $0)
        })
        panel.setPhoneActionsEnabled(state.meetingActive && !state.meetingStarting && !state.meetingStopping)
        let text: String
        if let problem = state.phoneProblem {
            text = problem
        } else if state.meetingStarting {
            text = String(appLocalized: "正在准备电话字幕、声音与麦克风…")
        } else if case .suspended = session?.state {
            text = String(appLocalized: "电话同传已暂停，等待系统恢复。")
        } else if let hint = state.meetingHint {
            text = hint
        } else if let detail = phoneReadinessDetail {
            text = detail
        } else if !state.phoneReadyToDial {
            text = String(appLocalized: "正在准备电话发言，请稍候…")
        } else if state.phoneAudioActive {
            text = String(appLocalized: "电话音频已接入 · 点按右⌥切换原声与翻译")
        } else {
            text = String(appLocalized: "收音已就绪 · 点按右⌥开始翻译，也可在 Phone 拨号或接听")
        }
        if state.phoneStatus != text { state.phoneStatus = text; onTranslationChange?() }
        panel.setPhoneContext(text)
    }

    func setGlobalListenFallback(_ enabled: Bool) {
        guard let session else { return }
        guard session.mode.allowsGlobalFallback else { return }
        if enabled, !confirm(String(appLocalized: "采集所有应用的声音？"), MeetingSession.globalFallbackWarning, ok: String(appLocalized: "开启全局采集")) { return }
        do { try session.setGlobalFallback(enabled) }
        catch { alert(String(appLocalized: "无法切换声音来源"), error.localizedDescription) }
    }

    private func listenConfigurationChanged() {
        applyLanguagePresentation()
        listenConfigurationTask?.cancel()
        let requestID = UUID(); listenRequestID = requestID
        guard let session, !state.meetingStopping else { return }
        switch session.state {
        case .starting, .running, .suspended: break
        case .idle, .ended: return
        }
        let selection = state.listenLanguages(for: session.mode)
        let language = selection.source
        // Fence delivery immediately, before the async session method gets its actor turn.
        awaitingListenReset = true
        panel.clear(); state.listenTranslation = nil
        state.listenASRStatus = String(appLocalized: "正在切换字幕识别…")
        state.listenASRFailure = nil
        listenConfigurationTask = Task { [weak self, weak session] in
            guard let self, let session, self.session === session,
                  listenRequestID == requestID, !Task.isCancelled else { return }
            do {
                // Same-language changes rebuild the ASR too. The session owns cancellation and
                // coalesces changes during startup/suspension without touching SPEAK or input.
                try await session.switchListenDirection(source: language, target: selection.target, forceRebuild: true)
                guard self.session === session, listenRequestID == requestID, !Task.isCancelled else { return }
                if state.effectiveListenASREngine == .apple, session.listenLanguage == language,
                   session.listenTarget == selection.target, case .running = session.state {
                    state.listenASRStatus = "Apple Speech"
                }
            } catch {
                guard self.session === session, listenRequestID == requestID, !Task.isCancelled else { return }
                let text = String(appLocalized: "字幕识别切换未完成：\(error.localizedDescription)")
                state.listenASRStatus = text
                state.listenASRFailure = text
                panel.setHint(text)
            }
            if listenRequestID == requestID { listenConfigurationTask = nil }
        }
    }

    private func makeListenASR(log: EventLog, configuration: UInt64, sessionID: UUID,
                               jobs: JobIDSequence, mode: MeetingMode) -> any StreamingASREngine {
        state.listenASRFallback = false
        state.listenASRFailure = nil
        if state.effectiveListenASREngine == .apple {
            state.listenASRStatus = String(appLocalized: "Apple Speech（准备中）")
            return AppleSpeechASR()
        }
        state.listenASRStatus = String(appLocalized: "Qwen3-ASR（准备中）")
        let requestID = listenRequestID
        let process = engineProcess()
        listenEngine = process
        // Video generates no speech, so the GPU is free to read the recognizer twice as often.
        return QwenStreamingASR(engine: process, fallback: AppleSpeechASR(), jobs: jobs, log: log,
            cadenceMs: mode == .captions ? 500 : 1000, earlySentences: mode == .captions,
            onEngine: { [weak self] engine in
                Task { @MainActor in
                    guard let self, self.subtitleSessionID == sessionID, self.listenRequestID == requestID,
                          self.session?.listenConfigurationID == configuration else { return }
                    self.state.listenASRFallback = engine.placement != .engineGPU
                    self.state.listenASRStatus = engine.placement == .engineGPU
                        ? "Qwen3-ASR" : String(appLocalized: "Apple Speech（Qwen 不可用，备用接管）")
                }
            })
    }

    /// Copying happens only in response to the reminder's button, never sends a message.
    private func cloudReminder() {
        let prefs = TranslationPreferences.load(defaults)
        guard prefs.meetingReminderEnabled, prefs.cloudConsentGiven, prefs.listenCloudEnabled else { return }
        hud?.showCloudReminder(useApple: { [weak self] in
            Task { await self?.session?.useAppleForThisMeeting() }
        }, copyNotice: { [weak self] in
            let text: String
            switch self?.state.remoteLanguage.lang ?? .en {
            case .zh:
                text = "我正在使用机器实时翻译和合成声音。说话内容会以文本形式发送给 OpenAI 进行翻译。" // l10n-ignore
            case .de:
                text = "Ich nutze maschinelle Live-Übersetzung und eine synthetische Stimme. Gesprochene Inhalte werden als Text zur Übersetzung an OpenAI gesendet."
            case .en:
                text = "I'm using live machine interpretation and a synthesized voice. Spoken content is sent as text to OpenAI for translation."
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        })
    }

    /// Selected local ASR + Apple Translation (drafts, and the fallback for finals) + OpenAIMT as
    /// the finals' primary when the user set it up (ListenCloud); without it every final is
    /// Apple (§4.2: the no-key path).
    static func engines(cloud: ListenCloud.Box?,
                        makeASR: (@MainActor @Sendable (EventLog, UInt64) -> (any StreamingASREngine)?)? = nil,
                        knownKeyPresence: (@MainActor @Sendable () -> Bool?)? = nil) -> MeetingSession.EngineFactory {
        { direction, log, configuration in
            // The app validates the generation and obtains the meeting backend in one main-actor
            // turn. A late factory from an ended meeting cannot repopulate the shared cloud box.
            let prepared = await MainActor.run { () -> ListenPipeline.Engines? in
                let asr: any StreamingASREngine
                if let makeASR {
                    guard let chosen = makeASR(log, configuration) else { return nil }
                    asr = chosen
                } else { asr = AppleSpeechASR() }
                let primary = cloud?.make(log: log, knownPresence: knownKeyPresence?()).map { GlossaryMT(base: $0) }
                return ListenPipeline.Engines(asr: asr, apple: nil, primary: primary)
            }
            guard var engines = prepared else {
                return ListenPipeline.Engines(asr: AppleSpeechASR(), apple: nil, primary: nil)
            }
            if #available(macOS 26.4, *) {
                let mt = AppleTranslationMT()
                engines.apple = mt
                let session = MTSession.listen(source: direction.source, target: direction.target)!
                // Independent preparation overlaps ASR.open; the pipeline still awaits both
                // before reporting ready, and permission checks remain ahead of either one.
                engines.prepareTranslation = { try? await mt.prepare(session) }
            }
            return engines
        }
    }

    /// The onboarding demo (app-ui's ListenDemo, step 8): Apple only, no cloud, no key.
    static func engines(_ lang: Lang) async -> ListenPipeline.Engines {
        await engines(cloud: nil)(Direction(source: lang, target: .zh), EventLog(inMemory: HostClock.now), 0)
    }

    /// Whether the latest `start` reached `.started` (the quick start opens settings otherwise).
    private var lastStartSucceeded = false

    func start(mode: MeetingMode = .meeting, choice: String? = nil, askForChoice: Bool = true) async {
        let requestedAt = HostClock.now()
        lastStartSucceeded = false
        guard !state.meetingActive, !state.meetingStarting else { return }
        guard canStartMeeting() else {
            alert(String(appLocalized: "暂时不能开始收听"), String(appLocalized: "请先结束正在运行的自检或说话测试，或等待语音资源维护完成。"))
            return
        }
        state.meetingMode = mode
        state.requestedScenario = mode
        state.meetingStarting = true
        state.lastEndProblem = nil
        defer {
            state.meetingStarting = false
            // A failed or abandoned start leaves no window behind (idempotent).
            if !state.meetingActive { panel.endSession() }
            if mode == .phone {
                if !state.meetingActive { state.phoneStatus = String(appLocalized: "电话同传尚未开始，请准备后再拨号或接听。") }
                refreshPhoneContext()
            }
        }
        panel.setPresentation(mode == .phone ? .phone : mode == .captions ? .video : .meeting)
        // Every scene opens its window at `.started`, already at its final size: phone's
        // preparation stays in the menu (phoneStatus), never a bare titlebar strip, and a
        // leftover notice never shows as a strip while starting.
        if mode == .phone {
            state.phoneProblem = nil; phoneReadinessDetail = nil
            state.phoneReadyToDial = false; state.phoneAudioActive = false
            refreshPhoneContext()
            await captionsEngineCleanup?.value
            startEngineEarly(for: mode)
            do {
                try await NativePhone.open(activates: false)
                // The app creates its Core Audio object shortly after launch. No recording or
                // dial occurs during this bounded discovery wait.
                for _ in 0..<30 {
                    if sources().contains(where: { $0.id == MeetingMode.phoneAppID }) { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch {
                state.phoneProblem = String(appLocalized: "无法打开系统 Phone 应用，请确认它已安装并可正常启动。")
                releaseEarlyEngine()
                return
            }
        }
        await captionsEngineCleanup?.value
        let selectedSource = choice ?? state.selectedSource(for: mode)
        if mode != .phone {
            refreshSourceOptions()
            if let selectedSource, !state.availableSources.contains(where: { $0.id == selectedSource }) {
                let name = MeetingApp.named(selectedSource)?.name ?? selectedSource
                alert(String(appLocalized: "所选应用尚未就绪"), String(appLocalized: "请先打开 \(name)，或在当前场景中选择其他应用。不会自动改为收听其他应用。"))
                return
            }
        }
        startEngineEarly(for: mode)
        try? AppGlossary.store.reload()
        let profile: PolicyProfile
        do { profile = try PolicyProfile.loadDefault() } catch {
            alert(String(appLocalized: "无法开始收听"), String(appLocalized: "找不到策略文件（PolicyProfile.default.json）：\(String(describing: error))"))
            releaseEarlyEngine()
            return
        }
        let retiredModel = await prepareCloud?() ?? false
        let sessionID = UUID()
        subtitleSessionID = sessionID
        listenEngine = nil
        let recorder = privacy?.recorder
        let transcript = privacy.map { TranscriptWriter(directory: $0.transcriptsDirectory) }
        self.transcript = transcript
        let jobs = JobIDSequence()
        let factory = Self.engines(cloud: cloud.box, makeASR: { [weak self] log, configuration in
            guard let self, self.subtitleSessionID == sessionID,
                  self.session?.listenConfigurationID == configuration else { return nil }
            return self.makeListenASR(log: log, configuration: configuration, sessionID: sessionID, jobs: jobs, mode: mode)
        }, knownKeyPresence: { [weak self] in
            self?.knownCloudKeyPresence?()
        })
        let s = MeetingSession(profile: profile, mode: mode, makeEngines: factory, events: events, jobs: jobs,
            onRemoteAudio: { samples, at in recorder?.appendRemote(samples, host: at) },
            onTranscript: { [weak self] source, target, at in
                guard let self, self.subtitleSessionID == sessionID, !self.awaitingListenReset,
                      self.privacy?.saveTranscripts == true else { return }
                transcript?.append(direction: "listen", source: source, target: target, at: at)
            }, onAnalysis: { [weak self] observation, configuration in
                guard let self, self.subtitleSessionID == sessionID, !self.awaitingListenReset else { return }
                self.panel.setAnalysisConfiguration(configuration)
                self.privacy?.subtitleAnalysis.record(observation, configuration: configuration,
                                                     asrStatus: self.state.listenASRStatus)
            }, glossary: { AppGlossary.store.snapshot() }, onListenFailure: { [weak self] _, message in
                guard let self, self.subtitleSessionID == sessionID else { return }
                self.showListenFailure(message)
            }, onListenReset: { [weak self] in
                guard let self, self.subtitleSessionID == sessionID else { return }
                self.awaitingListenReset = false
                if let configuration = self.session?.listenConfigurationID {
                    self.panel.setAnalysisConfiguration(configuration)
                }
                self.panel.clear()
                self.state.listenTranslation = nil
                self.state.listenASRStatus = String(appLocalized: "正在切换字幕识别…")
                self.state.listenASRFailure = nil
            }, onSubtitle: { [weak self] u in
                guard let self, self.subtitleSessionID == sessionID, !self.awaitingListenReset else { return }
                if let configuration = self.session?.listenConfigurationID {
                    self.panel.setAnalysisConfiguration(configuration)
                }
                self.panel.apply(u)
                self.privacy?.recorder.subtitle(u)
            })
        session = s
        s.onPhoneAudioActivity = { [weak self, weak s] active in
            guard let self, let s, self.session === s else { return }
            self.state.phoneAudioActive = active
            self.refreshPhoneContext()
        }
        if mode == .captions, state.effectiveListenASREngine == .qwen, let engine = engineProcess() {
            captionsEngine = engine
            await engine.setMeetingMode(true)
            captionsWarmup = Task { _ = try? await engine.start(prioritizingASR: true) }
        }
        let selection = state.listenLanguages(for: mode)
        let result = await s.start(lang: selection.source, target: selection.target,
                                   choice: selectedSource, preferred: nil, requestedAt: requestedAt)
        guard session === s else {
            if session == nil { releaseEarlyEngine() }
            return
        }
        if case .started = result {
            earlyEngine = nil   // SPEAK owns the engine's meeting mode from here
        } else {
            if mode == .captions { releaseCaptionsEngine() }
            else if earlyEngine != nil { releaseEarlyEngine() }
            else if let engine = listenEngine { scheduleEngineIdle(engine) }
            listenEngine = nil
            privacy?.subtitleAnalysis.stop(reason: "session_ended")
        }
        switch result {
        case .started:
            lastStartSucceeded = true
            state.lastScenario = mode
            let latest = state.listenLanguages(for: mode)
            if s.listenLanguage != latest.source || s.listenTarget != latest.target { listenConfigurationChanged() }
            else if state.effectiveListenASREngine == .apple { state.listenASRStatus = "Apple Speech" }
            cloudReminder()
            if retiredModel { hud?.post(.modelRetired) }
        case .noMeetingApp:
            session = nil
            if mode == .phone {
                state.phoneProblem = String(appLocalized: "Phone 的音频尚未就绪。请打开 Phone 后重新准备电话同传。")
            } else if let selectedSource {
                let name = MeetingApp.named(selectedSource)?.name ?? selectedSource
                alert(String(appLocalized: "所选应用尚未就绪"), String(appLocalized: "\(name) 的声音来源已不可用，请打开应用后重试，或在当前场景中重新选择。"))
            } else if mode == .captions {
                alert(String(appLocalized: "没有找到播放应用"), String(appLocalized: "请先在浏览器中播放视频，再开始视频字幕。"))
            } else {
                alert(String(appLocalized: "没有找到声音来源"), String(appLocalized: "请先打开 Zoom、Teams 等会议应用，或在 Chrome、Safari 中播放视频，再开始收听。"))
            }
        case let .needsChoice(ids):
            session = nil
            guard askForChoice else { return }   // the caller opens the scenario page
            if let pick = choose(ids) {
                state.selectSource(pick, for: mode)
                state.meetingStarting = false
                await start(mode: mode, choice: pick)
            }
        case .tccDenied:
            session = nil
            if confirm(String(appLocalized: "需要“系统录音”权限"),
                       String(appLocalized: "TalkTalk 收听所选应用的声音来生成字幕。请在“系统设置 › 隐私与安全性 › 录屏与系统录音”里允许 TalkTalk，然后重新开始。"),
                       ok: String(appLocalized: "打开系统设置")) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
        case let .speechAssetsMissing(l):
            session = nil
            let name = l.title
            if confirm(String(appLocalized: "需要下载 \(name) 语音识别资源"),
                       String(appLocalized: "字幕要用 macOS 的语音识别。\(name) 资源约 140 MB，由 macOS 下载和管理。现在下载吗？"),
                       ok: String(appLocalized: "下载")) {
                do {
                    try await AppleSpeechASR.installAssets(l)
                    state.meetingStarting = false
                    await start(mode: mode, choice: choice)
                } catch {
                    alert(String(appLocalized: "下载没有完成"), "\(error)")
                }
            }
        case .speechNotAuthorized:
            session = nil
            if confirm(String(appLocalized: "需要“语音识别”权限"), String(appLocalized: "请在“系统设置 › 隐私与安全性 › 语音识别”里允许 TalkTalk。"), ok: String(appLocalized: "打开系统设置")) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!)
            }
        case let .failed(why):
            session = nil
            if mode == .phone { state.phoneProblem = why }
            alert(String(appLocalized: "无法开始收听"), why)
        }
    }

    private func showListenFailure(_ message: String) {
        let text = String(appLocalized: "字幕识别未能恢复：\(message)")
        state.listenASRStatus = text
        state.listenASRFailure = text
        panel.setHint(text)
    }

    /// LISTEN-only playback keeps the same app engine alive; leaving schedules its normal idle
    /// shutdown. The next capture waits for this cleanup before another owner can keep it alive.
    private func releaseCaptionsEngine() {
        guard let engine = captionsEngine else { return }
        captionsEngine = nil; captionsWarmup?.cancel(); captionsWarmup = nil
        scheduleEngineIdle(engine)
    }

    /// Meeting and phone use the engine as soon as SPEAK begins, so model loading can overlap the
    /// permission probe and Phone's launch instead of following them. This keeps the engine's
    /// original load order and does not enter meeting mode; every exit before `.started` must
    /// return it to its normal idle shutdown with `releaseEarlyEngine()`.
    private func startEngineEarly(for mode: MeetingMode) {
        guard mode.supportsSpeaking, earlyEngine == nil, let engine = engineProcess() else { return }
        earlyEngine = engine
        Task { _ = try? await engine.start() }
    }

    private func releaseEarlyEngine() {
        guard let engine = earlyEngine else { return }
        earlyEngine = nil
        scheduleEngineIdle(engine)
    }

    /// Failed Qwen startup can precede SPEAK's started event. Use the same serial cleanup as
    /// captions, with the captured process, before a later session may keep an engine alive.
    private func scheduleEngineIdle(_ engine: EngineProcess) {
        let previous = captionsEngineCleanup
        captionsEngineCleanup = Task {
            await previous?.value
            await engine.setMeetingMode(false)
        }
    }

    private func sessionState(_ st: MeetingSession.State) {
        switch st {
        case .running(let name), .suspended(let name):
            if case .running = st, state.effectiveListenASREngine == .apple, session?.listenLanguage == state.remoteLanguage.lang {
                state.listenASRStatus = "Apple Speech"
            }
            state.meetingActive = true
            if let session { state.meetingMode = session.mode }
            state.meetingApp = name
            panel.setSourceName(name)
            if state.meetingStartedAt == nil { state.meetingStartedAt = session?.startedAt ?? Date() }
            panel.setVisible(state.subtitlesVisible)
            if state.meetingMode == .phone { refreshPhoneContext() }
            onActiveChange?(true)
        case .starting:
            break
        case .idle, .ended:
            privacy?.subtitleAnalysis.stop(reason: "session_ended")
            listenConfigurationTask?.cancel(); listenConfigurationTask = nil
            listenRequestID = UUID(); awaitingListenReset = false
            state.listenASRStatus = nil
            state.listenASRFailure = nil
            subtitleSessionID = nil
            state.meetingActive = false
            state.meetingStopping = false
            state.meetingApp = nil
            state.meetingStartedAt = nil
            state.meetingHint = nil
            state.meetingHintKind = nil
            state.listenTranslation = nil
            state.phoneReadyToDial = false; state.phoneAudioActive = false
            if state.meetingMode == .phone {
                state.phoneStatus = String(appLocalized: "电话同传已结束；如仍在通话，请在 Phone 中挂断。")
            }
            hud?.setSceneIssue(nil)
            panel.setPhoneContext(nil)
            panel.endSession()
            panel.clear(includingMyTurns: true)
            onActiveChange?(false)
        }
    }

    // MARK: - dialogs

    private func choose(_ ids: [String]) -> String? {
        let apps = ids.compactMap(MeetingApp.named)
        guard !apps.isEmpty else { return nil }
        let a = NSAlert()
        a.messageText = state.meetingMode == .captions ? String(appLocalized: "选择视频声音来源") : String(appLocalized: "选择会议应用")
        a.informativeText = String(appLocalized: "有多个可用应用，请为当前场景选择一个来源。这个场景会记住你的选择。")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 28), pullsDown: false)
        picker.addItems(withTitles: apps.map(\.name))
        picker.setAccessibilityLabel(a.messageText)
        a.accessoryView = picker
        a.addButton(withTitle: String(appLocalized: "使用所选应用"))
        a.addButton(withTitle: String(appLocalized: "取消"))
        NSApp.activate()
        guard a.runModal() == .alertFirstButtonReturn, apps.indices.contains(picker.indexOfSelectedItem) else { return nil }
        return apps[picker.indexOfSelectedItem].id
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate()
        a.runModal()
    }

    private func confirm(_ title: String, _ text: String, ok: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: ok)
        a.addButton(withTitle: String(appLocalized: "取消"))
        NSApp.activate()
        return a.runModal() == .alertFirstButtonReturn
    }
}
