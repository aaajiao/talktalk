import AppKit
import TalkTalkApple
import TalkTalkAudio
import TalkTalkCore
import TalkTalkEngineHost
import TalkTalkCloudUI
import TalkTalkSession

/// Menu ↔ MeetingSession ↔ SubtitlePanel (ARCHITECTURE.md §11). Starting asks only what the
/// user must decide: which meeting app when several are in a call, the system permission when
/// it is missing, the speech-asset download when the locale is not installed.
@MainActor
final class MeetingController {
    private enum Key { static let lastSource = "meeting.lastSource" }

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
    private let engineProcess: @Sendable () -> EngineProcess?
    private let defaults: UserDefaults
    var onActiveChange: ((Bool) -> Void)?
    /// The finals' source or the network changed (menu line, icon).
    var onTranslationChange: (() -> Void)?
    /// Runs before a user end, while meeting mode is still on (the system-input question, §8.6);
    /// false = you cancelled and meeting mode goes on.
    var beforeUserEnd: (() -> Bool)?
    var prepareCloud: (() async -> Bool)?
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
        state.onSubtitleAppearanceChange = { [weak self] in self?.applySubtitleAppearance() }
        panel.onPresentationChange = { [weak self] in self?.applySubtitleAppearance() }
        state.onSubtitleVisibilityChange = { [weak self] on in self?.setSubtitlesVisible(on) }
        applySubtitleAppearance()
        panel.analysisRecorder = privacy?.subtitleAnalysis
        ui = events.subscribe { [weak self] e in
            switch e {
            case let .state(st): self?.sessionState(st)
            case let .hint(h):
                self?.state.meetingHint = h?.rawValue
                self?.hud?.listen(h)
            case .started(_, _, let lang, _):
                self?.hud?.meetingStarted()
                self?.privacy?.recorder.meetingStarted(lang: lang)
            case .suspended(let reason): self?.privacy?.recorder.meetingSuspended(String(describing: reason))
            case .resumed: self?.privacy?.recorder.meetingResumed()
            case .ended(let reason):
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

    var lastSource: String? {
        get { defaults.string(forKey: Key.lastSource) }
        set { defaults.set(newValue, forKey: Key.lastSource) }
    }

    /// Meeting apps that currently have Core Audio process objects (menu › 会议来源).
    func sources() -> [MeetingApp] {
        ((try? MeetingSourceResolver().currentCandidates()) ?? []).map(\.app)
    }

    func setSubtitlesVisible(_ on: Bool) {
        panel.setVisible(on && state.meetingActive)
        hud?.setSubtitlesVisible(on)
    }

    private func applySubtitleAppearance() {
        switch panel.presentation {
        case .meeting:
            panel.setFontSize(state.subtitleFontSize)
            panel.setBackgroundOpacity(state.subtitleBackgroundOpacity)
        case .video:
            panel.setFontSize(state.videoSubtitleFontSize)
            panel.setBackgroundOpacity(state.videoSubtitleBackgroundOpacity)
        }
    }

    func toggle(mode: MeetingMode = .meeting) {
        guard !state.meetingStopping else { return }   // one end question, one stop
        if state.meetingActive {
            guard session?.mode != .meeting || (beforeUserEnd?() ?? true) else { return }   // cancelled in the dialog
            state.meetingStopping = true
            Task {
                await session?.stop(.user)
                state.meetingStopping = false
            }
        } else if !state.meetingStarting {
            Task { await start(mode: mode) }
        }
    }

    func stillInMeeting() { session?.stillInMeeting() }

    func setGlobalListenFallback(_ enabled: Bool) {
        guard let session else { return }
        if enabled, !confirm("采集所有应用的声音？", MeetingSession.globalFallbackWarning, ok: "开启全局采集") { return }
        do { try session.setGlobalFallback(enabled) }
        catch { alert("无法切换声音来源", error.localizedDescription) }
    }

    private func listenConfigurationChanged() {
        listenConfigurationTask?.cancel()
        let requestID = UUID(); listenRequestID = requestID
        guard let session, !state.meetingStopping else { return }
        let language = state.remoteLanguage.lang
        // Fence delivery immediately, before the async session method gets its actor turn.
        awaitingListenReset = true
        panel.clear(); state.listenTranslation = nil
        state.listenASRStatus = String(localized: "正在切换字幕识别…")
        listenConfigurationTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                // Same-language changes rebuild the ASR too. The session owns cancellation and
                // coalesces changes during startup/suspension without touching SPEAK or input.
                try await session.switchListenLanguage(to: language, forceRebuild: true)
                guard self.session === session, listenRequestID == requestID, !Task.isCancelled else { return }
                if state.listenASREngine == .apple, session.listenLanguage == language, case .running = session.state {
                    state.listenASRStatus = "Apple Speech"
                }
            } catch {
                guard self.session === session, listenRequestID == requestID, !Task.isCancelled else { return }
                let text = String(localized: "字幕识别切换未完成：\(error.localizedDescription)")
                state.listenASRStatus = text
                panel.setHint(text)
            }
            if listenRequestID == requestID { listenConfigurationTask = nil }
        }
    }

    private func makeListenASR(log: EventLog, configuration: UInt64, sessionID: UUID,
                               jobs: JobIDSequence) -> any StreamingASREngine {
        if state.listenASREngine == .apple {
            state.listenASRStatus = String(localized: "Apple Speech（准备中）")
            return AppleSpeechASR()
        }
        state.listenASRStatus = String(localized: "Qwen3-ASR（准备中）")
        let requestID = listenRequestID
        let process = engineProcess()
        listenEngine = process
        return QwenStreamingASR(engine: process, fallback: AppleSpeechASR(), jobs: jobs, log: log,
            onEngine: { [weak self] engine in
                Task { @MainActor in
                    guard let self, self.subtitleSessionID == sessionID, self.listenRequestID == requestID,
                          self.session?.listenConfigurationID == configuration else { return }
                    self.state.listenASRStatus = engine.placement == .engineGPU
                        ? "Qwen3-ASR" : String(localized: "Apple Speech（Qwen 不可用，备用接管）")
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
            let text = self?.state.remoteLanguage.lang == .de
                ? "Ich nutze maschinelle Live-Übersetzung und eine synthetische Stimme. Gesprochene Inhalte werden als Text zur Übersetzung an OpenAI gesendet."
                : "I'm using live machine interpretation and a synthesized voice. Spoken content is sent as text to OpenAI for translation."
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        })
    }

    /// Selected local ASR + Apple Translation (drafts, and the "≈" fallback for finals) + OpenAIMT as
    /// the finals' primary when the user set it up (ListenCloud); without it every final is Apple
    /// with "≈" (§4.2: the no-key path).
    static func engines(cloud: ListenCloud.Box?,
                        makeASR: (@MainActor @Sendable (EventLog, UInt64) -> (any StreamingASREngine)?)? = nil) -> MeetingSession.EngineFactory {
        { lang, log, configuration in
            // The app validates the generation and obtains the meeting backend in one main-actor
            // turn. A late factory from an ended meeting cannot repopulate the shared cloud box.
            let prepared = await MainActor.run { () -> ListenPipeline.Engines? in
                let asr: any StreamingASREngine
                if let makeASR {
                    guard let chosen = makeASR(log, configuration) else { return nil }
                    asr = chosen
                } else { asr = AppleSpeechASR() }
                let primary = cloud?.make(log: log).map { GlossaryMT(base: $0) }
                return ListenPipeline.Engines(asr: asr, apple: nil, primary: primary)
            }
            guard var engines = prepared else {
                return ListenPipeline.Engines(asr: AppleSpeechASR(), apple: nil, primary: nil)
            }
            if #available(macOS 26.4, *) {
                let mt = AppleTranslationMT()
                try? await mt.prepare(lang == .de ? .listenDeZh : .listenEnZh)
                engines.apple = mt
            }
            return engines
        }
    }

    /// The onboarding demo (app-ui's ListenDemo, step 8): Apple only, no cloud, no key.
    static func engines(_ lang: Lang) async -> ListenPipeline.Engines {
        await engines(cloud: nil)(lang, EventLog(inMemory: HostClock.now), 0)
    }

    func start(mode: MeetingMode = .meeting, choice: String? = nil) async {
        guard canStartMeeting() else {
            alert("暂时不能开始收听", "请先结束正在运行的自检或说话测试。")
            return
        }
        await captionsEngineCleanup?.value
        state.meetingMode = mode
        panel.setPresentation(mode == .captions ? .video : .meeting)
        try? AppGlossary.store.reload()
        let profile: PolicyProfile
        do { profile = try PolicyProfile.loadDefault() } catch {
            alert("无法开始收听", "找不到策略文件（PolicyProfile.default.json）：\(error)")
            return
        }
        state.meetingStarting = true
        defer { state.meetingStarting = false }
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
            return self.makeListenASR(log: log, configuration: configuration, sessionID: sessionID, jobs: jobs)
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
                self.state.listenASRStatus = String(localized: "正在切换字幕识别…")
            }, onSubtitle: { [weak self] u in
                guard let self, self.subtitleSessionID == sessionID, !self.awaitingListenReset else { return }
                if let configuration = self.session?.listenConfigurationID {
                    self.panel.setAnalysisConfiguration(configuration)
                }
                self.panel.apply(u)
                self.privacy?.recorder.subtitle(u)
            })
        session = s
        if mode == .captions, let engine = engineProcess() {
            captionsEngine = engine
            await engine.setMeetingMode(true)
            captionsWarmup = Task { _ = try? await engine.start() }
        }
        let lang = state.remoteLanguage.lang
        let result = await s.start(lang: lang, choice: choice, preferred: lastSource)
        guard session === s else { return }
        if case .started = result { } else {
            if mode == .captions { releaseCaptionsEngine() }
            else if let engine = listenEngine { scheduleEngineIdle(engine) }
            listenEngine = nil
            privacy?.subtitleAnalysis.stop(reason: "session_ended")
        }
        switch result {
        case .started:
            if let id = s.app?.id { lastSource = id }
            if s.listenLanguage != state.remoteLanguage.lang { listenConfigurationChanged() }
            else if state.listenASREngine == .apple { state.listenASRStatus = "Apple Speech" }
            cloudReminder()
            if retiredModel { hud?.post(.modelRetired) }
        case .noMeetingApp:
            session = nil
            if mode == .captions {
                alert("没有找到播放应用", "请先在浏览器中播放视频，再开始视频字幕。")
            } else {
                alert("没有找到声音来源", "请先打开 Zoom、Teams 等会议应用，或在 Chrome、Safari 中播放视频，再开始收听。")
            }
        case let .needsChoice(ids):
            session = nil
            if let pick = choose(ids) { await start(mode: mode, choice: pick) }
        case .tccDenied:
            session = nil
            if confirm("需要“系统录音”权限",
                       "TalkTalk 收听所选应用的声音来生成字幕。请在“系统设置 › 隐私与安全性 › 录屏与系统录音”里允许 TalkTalk，然后重新开始。",
                       ok: "打开系统设置") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
        case let .speechAssetsMissing(l):
            session = nil
            let name = l == .de ? "Deutsch" : "English"
            if confirm("需要下载 \(name) 语音识别资源",
                       "字幕要用 macOS 的语音识别。\(name) 资源约 140 MB，由 macOS 下载和管理。现在下载吗？",
                       ok: "下载") {
                do {
                    try await AppleSpeechASR.installAssets(l)
                    await start(mode: mode, choice: choice)
                } catch {
                    alert("下载没有完成", "\(error)")
                }
            }
        case .speechNotAuthorized:
            session = nil
            if confirm("需要“语音识别”权限", "请在“系统设置 › 隐私与安全性 › 语音识别”里允许 TalkTalk。", ok: "打开系统设置") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!)
            }
        case let .failed(why):
            session = nil
            alert("无法开始收听", why)
        }
    }

    private func showListenFailure(_ message: String) {
        let text = String(localized: "字幕识别未能恢复：\(message)")
        state.listenASRStatus = text
        panel.setHint(text)
    }

    /// LISTEN-only playback keeps the same app engine alive; leaving schedules its normal idle
    /// shutdown. The next capture waits for this cleanup before another owner can keep it alive.
    private func releaseCaptionsEngine() {
        guard let engine = captionsEngine else { return }
        captionsEngine = nil; captionsWarmup?.cancel(); captionsWarmup = nil
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
            if case .running = st, state.listenASREngine == .apple, session?.listenLanguage == state.remoteLanguage.lang {
                state.listenASRStatus = "Apple Speech"
            }
            state.meetingActive = true
            if let session { state.meetingMode = session.mode }
            state.meetingApp = name
            if state.meetingStartedAt == nil { state.meetingStartedAt = session?.startedAt ?? Date() }
            panel.setVisible(state.subtitlesVisible)
            onActiveChange?(true)
        case .starting:
            break
        case .idle, .ended:
            privacy?.subtitleAnalysis.stop(reason: "session_ended")
            listenConfigurationTask?.cancel(); listenConfigurationTask = nil
            listenRequestID = UUID(); awaitingListenReset = false
            state.listenASRStatus = nil
            subtitleSessionID = nil
            state.meetingActive = false
            state.meetingApp = nil
            state.meetingStartedAt = nil
            state.meetingHint = nil
            state.listenTranslation = nil
            panel.setVisible(false)
            panel.clear()
            onActiveChange?(false)
        }
    }

    // MARK: - dialogs

    private func choose(_ ids: [String]) -> String? {
        let apps = ids.compactMap(MeetingApp.named).prefix(3)
        let a = NSAlert()
        a.messageText = state.meetingMode == .captions ? "选择视频声音来源" : "选择要听的应用"
        a.informativeText = "选择要转成字幕的应用声音（下次会记住它）。"
        for app in apps { a.addButton(withTitle: app.name) }
        a.addButton(withTitle: "取消")
        NSApp.activate()
        let r = a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return r >= 0 && r < apps.count ? Array(apps)[r].id : nil
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
        a.addButton(withTitle: "取消")
        NSApp.activate()
        return a.runModal() == .alertFirstButtonReturn
    }
}
