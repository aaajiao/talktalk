// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import AVFoundation
import CoreGraphics
import Speech
import SwiftUI
import TalkTalkApple
import TalkTalkAudio
import TalkTalkCloud
import TalkTalkCloudUI
import TalkTalkCore
import TalkTalkDriverSupport
import TalkTalkSession
import TalkTalkSettingsUI
import TalkTalkVoice

/// First-run onboarding (ARCHITECTURE.md §11 首次引导). The step lives in OnboardingState
/// (UserDefaults `onboarding.v2.*`), so quitting anywhere, including the relaunch macOS asks for
/// after Input Monitoring is granted, comes back to the same place.
///
/// All eight steps use product components. Meeting-mic verification and the SPEAK demo are
/// injected by the app owner, so onboarding never changes the default input on its own.
@MainActor
@Observable
final class OnboardingFlowModel {
    @ObservationIgnored let state: OnboardingState
    /// The scene and model diagrams' state (steps 4 and 7 draw the settings pages' flows).
    @ObservationIgnored let appState: AppState
    private(set) var step: OnboardingStep?
    private(set) var facts = OnboardingFacts()
    private(set) var checking = false
    var onFinish: (() -> Void)?
    /// The done page's "打开使用场景" and its scenario rows: open settings at that scenario.
    @ObservationIgnored var openScenario: ((MeetingMode) -> Void)?
    /// Step 3 without its component page: open Settings › 组件 › 虚拟麦克风.
    @ObservationIgnored var openDriverComponents: (() -> Void)?
    /// "你会用 TalkTalk 做什么？" (redesign §7): on screen, and the cards ticked there.
    private(set) var choosingScenarios = false
    var selectedScenarios: Set<OnboardingScenario> = []
    /// The chosen path narrows the steps; mirrored here so the header observes it.
    private(set) var steps: [OnboardingStep] = []

    // step 1
    private(set) var probeRunning = false
    /// This process's probe verdict when it is not a pass: its status line under 应用声音.
    private(set) var probeResult: SettingsProblem?
    /// The probe runs by itself once per process when step 1 is shown (and before the Input
    /// Monitoring relaunch may move on); "检查" runs it again.
    @ObservationIgnored private var autoProbed = false
    /// false: never run the probe by itself (the smoke run; afplay would play a sound and ask
    /// for the system-audio grant). "检查" still runs it.
    @ObservationIgnored private let autoProbe: Bool
    /// The probe in flight. A second refresh waits for it instead of resuming without its verdict
    /// (which would use up the Input Monitoring relaunch flag and stay on step 1).
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    // step 2
    private(set) var assets: [Lang: AssetState] = [:]
    // step 4
    let engine: EngineComponentsModel
    // step 5: the settings window's page (one TranslationSettingsModel, one consent)
    let translation: TranslationPage
    // step 6
    let voice: MyVoiceModel
    // step 8
    let demo = ListenDemo()
    var driverPage: DriverComponentsPage?
    @ObservationIgnored var startMeetingMicCheck: (@MainActor (@escaping @MainActor (MeetingMicGuardPlan.State) -> Void) -> Void)?
    @ObservationIgnored var stopMeetingMicCheck: (@MainActor () -> Void)?
    @ObservationIgnored var startSpeakDemo: (@MainActor () async throws -> Void)?
    @ObservationIgnored var stopSpeakDemo: (@MainActor () -> Void)?
    private(set) var meetingMic: MeetingMicCheck = .notChecked
    private var checkingMeetingMic = false
    enum SpeakDemoState: Equatable { case idle, preparing, listening, played, failed(String) }
    private(set) var speakDemoState: SpeakDemoState = .idle
    private(set) var speakDemoStatus: String?
    @ObservationIgnored private var speakDemoTask: Task<Void, Never>?
    @ObservationIgnored private var speakDemoToken = UUID()
    @ObservationIgnored private let bundleID: String?

    enum AssetState: Equatable { case unknown, installed, missing, downloading, failed(String) }

    init(defaults: UserDefaults = .standard, appState: AppState, engine: EngineComponentsModel,
         translation: TranslationPage, bundleID: String? = Bundle.main.bundleIdentifier, autoProbe: Bool = true) {
        state = OnboardingState(defaults: defaults, steps: OnboardingStep.allCases)
        self.appState = appState
        step = state.current
        steps = state.steps
        choosingScenarios = state.choosingScenarios
        selectedScenarios = state.scenarios ?? []
        self.engine = engine
        self.translation = translation
        self.bundleID = bundleID
        self.autoProbe = autoProbe
        let relay = ChangeRelay()
        voice = MyVoiceModel(store: appState.voiceStore, onChange: { [weak appState] in
            appState?.refreshVoiceProfile()
            relay.fire()
        })
        // A take saved or deleted in step 6 updates the facts (and so the 继续 button).
        relay.action = { [weak self] in Task { await self?.refresh() } }
        ListenDemo.removeTemporaryFiles()
    }

    var needsOnboarding: Bool { state.needsOnboarding }

    /// "第 N 步，共 M 步" while onboarding is unfinished (Settings › 通用 › 使用引导…), from
    /// `OnboardingState.progress`. Reads the mirrored step and path first, so a view showing it
    /// updates when onboarding moves.
    var progress: OnboardingProgress? {
        _ = (step, steps)
        return state.progress
    }
    var videoOnly: Bool { state.videoOnly }

    /// The header's title for the chosen path.
    var pathTitle: String {
        if choosingScenarios { return String(localized: "开始使用 TalkTalk") }
        let chosen = state.scenarios ?? Set(OnboardingScenario.allCases)
        if OnboardingScenario.isVideoOnly(chosen) { return String(localized: "准备视频字幕") }
        if !chosen.contains(.meeting), chosen.contains(.phone) { return String(localized: "准备电话同传") }
        return String(localized: "准备会议同传")
    }

    /// The scenario the done page opens first: the first one chosen.
    var primaryScenario: MeetingMode {
        (state.scenarios ?? []).sorted().first.map(Self.mode) ?? .meeting
    }

    static func mode(_ scenario: OnboardingScenario) -> MeetingMode {
        switch scenario {
        case .meeting: .meeting
        case .phone: .phone
        case .video: .captions
        }
    }

    func toggleScenario(_ scenario: OnboardingScenario) {
        if selectedScenarios.contains(scenario) { selectedScenarios.remove(scenario) }
        else { selectedScenarios.insert(scenario) }
    }

    func confirmScenarios() {
        guard state.chooseScenarios(selectedScenarios) else { return }
        moved()
    }

    var canContinue: Bool {
        guard let s = step else { return false }
        var f = facts
        f.recordingTake = voice.enrollment != nil
        return state.canContinue(s, f)
    }

    /// The probe verdict to show: this process's, else the persisted one.
    var systemAudioShown: Bool? {
        switch state.merged(facts).systemAudioProbe {
        case .granted?: true
        case .denied?: false
        case .inconclusive?, nil: nil
        }
    }

    /// Launch and window-forward: gather facts (each written as soon as it is known, so a probe
    /// result landing meanwhile is not overwritten), then let the state machine handle the
    /// Input Monitoring relaunch.
    func refresh() async {
        checking = true
        defer { checking = false }
        facts.microphone = MicrophoneAuthorization.current == .authorized
        facts.speechRecognition = SFSpeechAuthorization.isAuthorized
        facts.inputMonitoring = CGPreflightListenEventAccess()
        // Presence only, never the value (CLAUDE.md): no TranslationSettingsModel here.
        facts.openAIKeyPresent = bundleID.flatMap { KeychainSecret.openAI(bundleID: $0) }?.exists()
        engine.reload()
        facts.engineInstalled = engine.installed
        refreshDriver()
        voice.reload()
        facts.voiceProfile = voice.hasProfile
        for l in Lang.allCases {
            if case .downloading? = assets[l] { continue }
            let ok = await AppleSpeechASR.assetsInstalled(l)
            if case .downloading? = assets[l] { continue }
            assets[l] = ok ? .installed : .missing
        }
        facts.speechAssets = Lang.allCases.allSatisfy { assets[$0] == .installed }
        if autoProbe, step == .permissions, !state.choosingScenarios, !autoProbed, state.systemAudioProbe != .granted {
            autoProbed = true
            await probe()
        } else if let t = probeTask {
            await t.value
        }
        state.resume(facts)
        step = state.current
        choosingScenarios = state.choosingScenarios
    }

    func next() {
        guard let s = step, canContinue else { return }
        var f = facts
        f.recordingTake = voice.enrollment != nil
        if state.complete(s, f) { moved() }
    }

    func skip() {
        guard let s = step else { return }
        if state.skip(s) { moved() }
    }

    func back() {
        state.back()
        moved()
    }

    func restart() {
        state.restart()
        autoProbed = false
        selectedScenarios = []
        moved()
    }

    /// Finishing the last step shows the done page ("打开使用场景"); it no longer closes itself.
    private func moved() {
        stopActivities()
        voice.endRecording()
        step = state.current
        steps = state.steps
        choosingScenarios = state.choosingScenarios
        Task { await refresh() }
    }

    func refreshDriver() {
        guard let driver = driverPage?.model else { return }
        if case .loaded = driver.state { facts.driverInstalled = true } else { facts.driverInstalled = false }
    }

    func beginMeetingMicCheck() {
        guard !checkingMeetingMic, let startMeetingMicCheck else { return }
        checkingMeetingMic = true
        meetingMic = .notChecked; facts.meetingMicVerified = false
        startMeetingMicCheck { [weak self] state in
            guard let self, self.checkingMeetingMic else { return }
            self.meetingMic = SystemInputController.check(state)
            self.facts.meetingMicVerified = state.verified
        }
    }
    func endMeetingMicCheck() {
        guard checkingMeetingMic else { return }
        checkingMeetingMic = false
        stopMeetingMicCheck?()
    }
    func beginSpeakDemo() {
        guard speakDemoTask == nil, let startSpeakDemo else { return }
        demo.stop()
        speakDemoState = .preparing
        speakDemoStatus = nil
        let token = UUID(); speakDemoToken = token
        speakDemoTask = Task { [weak self] in
            do {
                try await startSpeakDemo()
                guard let self, self.speakDemoToken == token, !Task.isCancelled else { return }
                if self.speakDemoState == .preparing { self.speakDemoState = .listening }
            } catch {
                guard let self, self.speakDemoToken == token else { return }
                self.speakDemoState = .failed(error.localizedDescription)
                self.stopSpeakDemo?()
                self.speakDemoTask = nil
            }
        }
    }
    /// The output owner observed the first audible sample, not merely a successful model request.
    func demoPlayed() { if speakDemoTask != nil { speakDemoState = .played } }
    func demoStatus(_ message: String) { if speakDemoTask != nil { speakDemoStatus = message } }
    func demoFailed(_ message: String) {
        speakDemoToken = UUID()
        speakDemoTask?.cancel(); speakDemoTask = nil
        speakDemoState = .failed(message)
    }
    func endSpeakDemo() {
        speakDemoToken = UUID()
        let active = speakDemoTask != nil
        speakDemoTask?.cancel(); speakDemoTask = nil
        if active { stopSpeakDemo?() }
        speakDemoState = .idle
        speakDemoStatus = nil
    }
    func stopActivities() { endMeetingMicCheck(); endSpeakDemo(); demo.stop() }

    // MARK: step 1

    func requestMicrophone() {
        Task {
            _ = await MicrophoneAuthorization.request()
            await refresh()
        }
    }

    func requestSpeech() {
        Task {
            _ = await AppleSpeechASR.authorize()
            await refresh()
        }
    }

    /// macOS asks to quit and reopen after the grant; the flag makes the next launch continue
    /// after step 1.
    func requestInputMonitoring() {
        if CGPreflightListenEventAccess() { Task { await refresh() }; return }
        state.willRelaunch(for: .inputMonitoring)
        if !CGRequestListenEventAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
        Task { await refresh() }
    }

    /// "检查": the afplay probe (§3.1) asks for the system-audio grant and checks it.
    func runSystemAudioProbe() {
        Task { await probe() }
    }

    /// One probe at a time; a caller arriving meanwhile waits for the running one.
    private func probe() async {
        if let t = probeTask { return await t.value }
        let t = Task { [weak self] in
            await self?.runProbe()
            self?.probeTask = nil   // as it finishes, so a later 检查 starts a new one
        }
        probeTask = t
        await t.value
    }

    private func runProbe() async {
        probeRunning = true
        probeResult = nil
        let r = await Task.detached { TCCProbe.run() }.value
        probeRunning = false
        let v: OnboardingProbeVerdict
        switch r.verdict {
        case .granted:
            v = .granted
        case .denied:
            v = .denied
            probeResult = SettingsProblem(.failed, String(localized: "系统录音被拒绝"),
                                          help: String(localized: "在“隐私与安全性 › 录屏与系统录音”里允许"))
        case .inconclusive:
            v = .inconclusive
            probeResult = SettingsProblem(.warn, String(localized: "未确认 · 开始时再查"),
                                          help: String(localized: "探针没听到声音；可继续，开始时再查"))
        }
        facts.systemAudioProbe = v
        state.recordSystemAudioProbe(v)
    }

    /// A refusal macOS will not ask about again (only System Settings can change it).
    var microphoneDenied: Bool {
        facts.microphone == false && [.denied, .restricted].contains(MicrophoneAuthorization.current)
    }

    var speechRecognitionDenied: Bool {
        facts.speechRecognition == false && [.denied, .restricted].contains(SFSpeechRecognizer.authorizationStatus())
    }

    func openPrivacy(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    // MARK: step 2

    func downloadAssets() {
        for l in Lang.allCases where assets[l] != .installed && assets[l] != .downloading {
            assets[l] = .downloading
            Task {
                do {
                    try await AppleSpeechASR.installAssets(l)
                    assets[l] = await AppleSpeechASR.assetsInstalled(l) ? .installed : .failed(String(localized: "没有装上"))
                } catch {
                    assets[l] = .failed(error.localizedDescription)
                }
                facts.speechAssets = Lang.allCases.allSatisfy { assets[$0] == .installed }
            }
        }
    }
}

#if TALKTALK_DEV
/// Dev-only (`--smoke-ui`): walk the flow on a throwaway defaults suite without TCC prompts or
/// downloads. `devAdvance` completes (or skips, when skippable and not satisfied) the current
/// step with the given facts; `devFinish` does that until the flow is done.
extension OnboardingFlowModel {
    static let devAllFacts = OnboardingFacts(microphone: true, speechRecognition: true, inputMonitoring: true,
                                             systemAudioProbe: .granted, speechAssets: true, driverInstalled: true,
                                             engineInstalled: true, openAIKeyPresent: true, voiceProfile: true,
                                             meetingMicVerified: true)

    @discardableResult
    func devAdvance(_ given: OnboardingFacts = OnboardingFlowModel.devAllFacts) -> OnboardingStep? {
        if state.choosingScenarios { state.chooseScenarios(Set(OnboardingScenario.allCases)) }
        guard let s = state.current else { return nil }
        facts = given
        if !state.complete(s, given) { state.skip(s) }
        step = state.current
        if step == nil { onFinish?() }
        return step
    }

    /// Returns the steps visited, in order.
    func devFinish(_ given: OnboardingFacts = OnboardingFlowModel.devAllFacts) -> [OnboardingStep] {
        var visited: [OnboardingStep] = []
        while let s = state.current, visited.count <= OnboardingStep.allCases.count {
            visited.append(s)
            devAdvance(given)
        }
        return visited
    }
}
#endif

@MainActor
private final class ChangeRelay {
    var action: (() -> Void)?
    func fire() { action?() }
}

/// Speech recognition authorization without prompting.
enum SFSpeechAuthorization {
    static var isAuthorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }
}

/// Settings, onboarding and native miniwindows need a Dock presence. A visible subtitle
/// panel remains nonactivating and does not by itself make this a regular application.
@MainActor
enum AppActivation {
    private static var minimizedPanels = Set<ObjectIdentifier>()

    static func panelWillMiniaturize(_ panel: NSPanel) {
        minimizedPanels.insert(ObjectIdentifier(panel))
        NSApp.setActivationPolicy(.regular)
    }

    static func minimizedPanelRestored(_ panel: NSPanel) {
        guard minimizedPanels.remove(ObjectIdentifier(panel)) != nil else { return }
        updatePolicy(excluding: nil)
    }

    static func windowWillClose(_ closing: NSWindow?) {
        if let closing { minimizedPanels.remove(ObjectIdentifier(closing)) }
        updatePolicy(excluding: closing)
    }

    private static func updatePolicy(excluding closing: NSWindow?) {
        let others = NSApp.windows.contains { w in
            w !== closing && (w.isVisible || w.isMiniaturized) && !(w is NSPanel) && w.styleMask.contains(.titled)
        }
        if !others && minimizedPanels.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - step 8 (LISTEN half): a sample through the real pipeline

/// "播放示例音频看字幕": `say` renders an English sample into a UUID-named temporary directory,
/// which is read into memory and deleted at once; the sample plays on the default output and
/// goes through ListenPipeline (Apple ASR, the same MT engines as meeting mode) into the shared
/// conversation panel. Every run has a token: 停止, closing the window or a new run makes the
/// older run stop at its next await (pipeline stopped, panel hidden).
@MainActor
@Observable
final class ListenDemo {
    enum Phase: Equatable { case idle, preparing, playing, done, failed(String) }
    private(set) var phase: Phase = .idle
    private(set) var lines: [String] = []
    @ObservationIgnored var panel: SubtitlePanel?
    @ObservationIgnored var canStart: () -> Bool = { true }
    @ObservationIgnored private var showingPanel = false
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var run: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?

    nonisolated static let sample = "Thanks everyone for joining. Let's start with the budget for next year, and then we look at the hiring plan."
    /// `talktalk-onboarding+<bundle id>+<uuid>`: the Dev and release builds share $TMPDIR.
    nonisolated static let tempName = ScopedTempName(tag: "talktalk-onboarding", bundleID: Bundle.main.bundleIdentifier)

    func start() {
        guard phase != .preparing, phase != .playing else { return }
        guard canStart() else {
            phase = .failed(String(localized: "请先结束当前收听，再播放示例。"))
            return
        }
        let id = UUID()
        run = id
        phase = .preparing
        lines = []
        task = Task { await play(id) }
    }

    func stop() {
        run = nil
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        if showingPanel {
            panel?.endSession()
            panel?.clear()
            showingPanel = false
        }
        if phase == .playing || phase == .preparing { phase = .idle }
    }

    /// Leftovers of a run that was killed between render and delete (launch and quit).
    nonisolated static func removeTemporaryFiles() {
        let tmp = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where tempName.owns(name) {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    private func current(_ id: UUID) -> Bool { run == id && !Task.isCancelled }

    private func play(_ id: UUID) async {
        var pipeline: ListenPipeline?
        func abandon() async {
            if let pipeline { await pipeline.stop() }
        }
        do {
            let (samples, wavData) = try await Self.renderSample()
            guard current(id) else { return await abandon() }
            let profile = try PolicyProfile.loadDefault()
            let engines = await MeetingController.engines(.en)
            guard current(id) else { return await abandon() }
            let ingest = AudioIngest()            // one per run
            let p = ListenPipeline(lang: .en, profile: profile.listen, engines: engines, log: EventLog(inMemory: HostClock.now),
                                   ingest: ingest, onUpdate: { [weak self] u in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.show(u, id) } }
            })
            pipeline = p
            try await p.start()
            guard current(id) else { return await abandon() }
            guard let panel else {
                throw NSError(domain: "TalkTalk.Onboarding", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: String(localized: "字幕窗口尚未就绪")])
            }
            let player = try AVAudioPlayer(data: wavData)
            self.player = player
            panel.setPresentation(.video)
            panel.clear()
            showingPanel = true
            // Lay the captions out first, then open the window at its final size (as a session
            // does at `.started`): no titlebar-only frame on the way in.
            panel.setVisible(true)
            panel.beginSession()
            phase = .playing
            player.play()
            // Real-time feed in 20 ms chunks, like MeetingTap.
            let chunk = 320
            var i = 0
            while i < samples.count, current(id) {
                ingest.push(Array(samples[i ..< min(i + chunk, samples.count)]), host: HostClock.now())
                i += chunk
                try? await Task.sleep(for: .milliseconds(20))
            }
            // Trailing silence so the last sentence finalizes.
            for _ in 0 ..< 75 where current(id) {
                ingest.push([Float](repeating: 0, count: chunk), host: HostClock.now())
                try? await Task.sleep(for: .milliseconds(20))
            }
            if current(id) { try? await Task.sleep(for: .seconds(2)) }
            await p.stop()
            if current(id), phase == .playing { phase = .done }
        } catch {
            await abandon()
            if current(id) { phase = .failed(String(localized: "示例没能播放：\(error.localizedDescription)")) }
        }
    }

    private func show(_ u: SubtitleUpdate, _ id: UUID) {
        guard run == id else { return }
        panel?.apply(u)
        if case let .final(_, text, _, _, _) = u { lines.append(text) }
    }

    /// Renders the sample, reads it (16 kHz mono samples + the WAV bytes for playback) and
    /// deletes the directory before returning.
    nonisolated private static func renderSample() async throws -> ([Float], Data) {
        try await Task.detached {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(tempName.make(), isDirectory: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let wav = dir.appendingPathComponent("sample.wav")
            try render(sample, to: wav)
            let data = try Data(contentsOf: wav)
            return (try read16k(wav), data)
        }.value
    }

    /// `say` to 16 kHz mono float WAV, asking for an English voice so a Chinese system voice is
    /// not used; falls back to the default voice.
    nonisolated static func render(_ text: String, to url: URL) throws {
        for voice in [["-v", "Samantha"], []] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = voice + ["--file-format=WAVE", "--data-format=LEF32@16000", "-o", url.path, text]
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 { return }
        }
        throw CocoaError(.fileWriteUnknown)
    }

    nonisolated static func read16k(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try f.read(into: buf)
        if f.processingFormat.sampleRate == 16000, f.processingFormat.channelCount == 1, let d = buf.floatChannelData {
            return Array(UnsafeBufferPointer(start: d[0], count: Int(buf.frameLength)))
        }
        guard let conv = AVAudioConverter(from: f.processingFormat, to: fmt),
              let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * 16000 / f.processingFormat.sampleRate) + 1024) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        if let err { throw err }
        guard let d = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: d[0], count: Int(out.frameLength)))
    }
}

// MARK: - window

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    let model: OnboardingFlowModel
    private var window: NSWindow?

    init(model: OnboardingFlowModel) {
        self.model = model
        super.init()
        model.onFinish = { [weak self] in self?.close() }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let w = window ?? make()
        window = w
        NSApp.setActivationPolicy(.regular)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Task { await model.refresh() }
    }

    func close() { window?.close() }

    private func make() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = String(localized: "欢迎使用 TalkTalk")
        let host = NSHostingView(rootView: OnboardingView(model: model))
        host.sizingOptions = []          // same reason as the settings window
        w.contentView = host
        w.contentMinSize = NSSize(width: 700, height: 560)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(NSSize(width: 760, height: 600))
        w.center()
        return w
    }

    func windowWillClose(_ notification: Notification) {
        model.voice.endRecording()
        model.stopActivities()
        AppActivation.windowWillClose(notification.object as? NSWindow)
    }
}

// MARK: - views

private typealias Icon = SubtitleTokens.SettingsIcon
private typealias Ladder = SubtitleTokens.SettingsIcon.Size

/// The window (settings visual system §7.17): the path and step indicator, one step page (its
/// StepTitle over the settings sections, see `OnboardingPage`), the buttons. Only the page
/// scrolls.
struct OnboardingView: View {
    @Bindable var model: OnboardingFlowModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(model.choosingScenarios ? "scenarios" : model.step?.rawValue ?? "done")
            Divider()
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.pathTitle).font(.headline)
                Spacer()
                if model.checking {
                    StatusGlyph(.busy)
                        .help(String(localized: "正在检查"))
                        .accessibilityLabel(String(localized: "正在检查"))
                }
            }
            // The indicator shows the position; "第 N 步，共 M 步" is its VoiceOver value.
            if !model.choosingScenarios, model.step != nil {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(model.steps, id: \.self) { step in
                        let status = stepStatus(step)
                        VStack(spacing: 5) {
                            Image(systemName: status.symbol ?? step.guideSymbol)
                                .font(.system(size: Ladder.onboardingStep, weight: .medium))
                                .frame(width: Ladder.onboardingStepDisc, height: Ladder.onboardingStepDisc)
                                .foregroundStyle(status.foreground)
                                .background(Circle().fill(status.fill))
                            Text(step.guideTitle).font(.caption)
                                .foregroundStyle(step == model.step ? Color.primary : Color.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("第 \(model.state.position(of: step) ?? step.number) 步，\(step.guideTitle)，\(status.text)"))
                        .help(status.text)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(String(localized: "引导步骤"))
                .accessibilityValue(model.progress?.text ?? "")
            }
        }
        .padding(.horizontal, OnboardingLayout.inset).padding(.vertical, 16)
    }

    /// Current: white glyph on the accent disc. Passed and skipped: a secondary check or minus
    /// (passing a step is not proof that it was verified, so never green). Future: tertiary.
    private func stepStatus(_ step: OnboardingStep) -> (symbol: String?, foreground: AnyShapeStyle,
                                                         fill: AnyShapeStyle, text: String) {
        typealias O = SubtitleTokens.OnboardingIcon
        let quiet = AnyShapeStyle(Color.secondary.opacity(0.12))
        if step == model.step {
            return (nil, AnyShapeStyle(Color.white), AnyShapeStyle(Color.accentColor), String(localized: "当前步骤"))
        }
        if model.state.skipped.contains(step) {
            return (O.stepSkipped, AnyShapeStyle(.secondary), quiet, String(localized: "已略过，可稍后设置"))
        }
        if let current = model.step, step < current {
            return (O.stepPassed, AnyShapeStyle(.secondary), quiet, String(localized: "已走过此步骤"))
        }
        return (nil, AnyShapeStyle(.tertiary), quiet, String(localized: "后续步骤"))
    }

    @ViewBuilder private var page: some View {
        if model.choosingScenarios {
            ScenarioChoiceStep(model: model)
        } else {
            switch model.step {
            case .permissions?: PermissionsStep(model: model)
            case .speechAssets?: SpeechAssetsStep(model: model)
            case .driver?: DriverStep(model: model)
            case .engine?: EngineStep(model: model)
            case .openAI?: OpenAIStep(model: model)
            case .voice?: VoiceStep(model: model)
            case .meetingMic?: MeetingMicStep(model: model)
            case .tryIt?: TryItStep(model: model)
            case nil: DoneStep(model: model)
            }
        }
    }

    private var footer: some View {
        HStack {
            if model.choosingScenarios {
                Button("稍后设置") { model.onFinish?() }
                    .keyboardShortcut(.cancelAction)
                    .help(String(localized: "关闭引导，可从菜单开始视频字幕"))
                Spacer()
                Button("继续") { model.confirmScenarios() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedScenarios.isEmpty)
            } else {
                stepFooter
            }
        }
        .padding(.horizontal, OnboardingLayout.inset).padding(.vertical, 12)
    }

    @ViewBuilder private var stepFooter: some View {
        if model.step != nil { Button("上一步") { model.back() } }
        if model.step == .permissions {
            Button("稍后设置") { model.onFinish?() }
                .keyboardShortcut(.cancelAction)
                .help(String(localized: "关闭引导，可从菜单开始视频字幕"))
        }
        Spacer()
        if let s = model.step, s.skippable, s != .openAI, s != .tryIt {
            Button(s == .meetingMic ? String(localized: "稍后核验") : String(localized: "跳过")) { model.skip() }
        }
        switch model.step {
        case .tryIt?:
            Button("完成") { model.next() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        case .openAI?:
            // Optional: 稍后设置 moves on without a key; 继续 once the key passed both checks.
            let verified = model.translation.model.map(OpenAIOnboardingStep.canContinue) ?? false
            Button("稍后设置") { model.skip() }
                .help(String(localized: "没有 key 时两个方向都用 Apple"))
            Button("继续") { Task { await model.refresh(); model.next() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(verified ? .defaultAction : nil)
                .disabled(!verified)
        case nil:
            Button("关闭") { model.onFinish?() }
                .keyboardShortcut(.cancelAction)
                .help(String(localized: "可从 设置 › 通用 › 使用引导… 再打开"))
            Button("打开使用场景") { model.openScenario?(model.primaryScenario) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.openScenario == nil)
        default:
            Button("继续") { model.next() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canContinue)
        }
    }
}

/// A permission row (§7.17): the settings row's glyph and title (the 右⌥ row draws the keycap),
/// then the state at the end: the status glyph once allowed or refused, the action while
/// undecided. After a refusal macOS will not ask again, so the row offers 打开“隐私与安全性”.
/// What the permission is for is the help; the ⓘ, if any, ends the row (§3.8). `title` and
/// `actionTitle` are already localized.
private struct GrantRow: View {
    enum Status { case granted, pending, denied }

    let symbol: String
    let title: String
    /// The 右⌥ row: a decorative keycap draws the title; the row stays one static element that
    /// speaks `title` and shows `help`.
    var key: TitlebarKey?
    let help: String
    var info: [String]?
    let status: Status
    let actionTitle: String
    let action: () -> Void
    var busy = false
    /// After a refusal the action still helps (re-running the probe after a change in System
    /// Settings).
    var actionWorksWhenDenied = false
    var openSettings: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Label {
                if let key {
                    Keycap(key: key)
                        .accessibilityHidden(true)
                } else {
                    Text(verbatim: title)
                }
            } icon: {
                Image(systemName: symbol)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: title))
            .help(help)
            Spacer(minLength: 8)
            if busy {
                StatusGlyph(.busy).help(String(localized: "正在检查")).accessibilityLabel(String(localized: "正在检查"))
            }
            switch status {
            case .granted:
                StatusGlyph(.ok).help(String(localized: "已允许")).accessibilityLabel(String(localized: "已允许"))
            case .pending:
                Button(actionTitle, action: action).disabled(busy)
            case .denied:
                StatusGlyph(.failed).help(String(localized: "已拒绝")).accessibilityLabel(String(localized: "已拒绝"))
                if let openSettings {
                    Button(action: openSettings) {
                        Label("打开“隐私与安全性”", systemImage: Icon.openApp).labelStyle(.titleAndIcon)
                    }
                }
                if actionWorksWhenDenied { Button(actionTitle, action: action).disabled(busy) }
            }
            if let info { InfoButton(topic: title, lines: info) }
        }
    }
}

/// Step 1 (§7.17): 收听 (应用声音, Apple 语音识别) and 我说话 (麦克风, 右⌥), one status at
/// each row's end; video alone needs only the first.
private struct PermissionsStep: View {
    let model: OnboardingFlowModel

    var body: some View {
        let f = model.facts
        OnboardingPage(title: StepTitle(.permissions, model.videoOnly ? String(localized: "允许收听应用声音与语音识别")
                                                                      : String(localized: "允许需要的声音与按键访问"))) {
            Section {
                GrantRow(symbol: Icon.speech, title: String(localized: "应用声音"),
                         help: String(localized: "收听所选应用，生成原文与中文字幕"),
                         status: grant(model.systemAudioShown, denied: model.systemAudioShown == false),
                         actionTitle: String(localized: "检查"), action: model.runSystemAudioProbe,
                         busy: model.probeRunning, actionWorksWhenDenied: true,
                         openSettings: { model.openPrivacy("Privacy_ScreenCapture") })
                if let result = model.probeResult {
                    StatusLabel(result.text, result.status, help: result.help)
                        .padding(.leading, Ladder.rowTextInset)
                }
                GrantRow(symbol: Icon.recognition, title: String(localized: "Apple 语音识别"),
                         help: String(localized: "在本机识别声音，作为 Qwen 的备用"),
                         status: grant(f.speechRecognition, denied: model.speechRecognitionDenied),
                         actionTitle: String(localized: "允许…"), action: model.requestSpeech,
                         openSettings: { model.openPrivacy("Privacy_SpeechRecognition") })
                if model.videoOnly {
                    FactRow([FactChip(String(localized: "不用麦克风"), symbol: Icon.noMicrophone,
                                      help: String(localized: "开会或打电话前可从 使用引导… 补齐"),
                                      spoken: String(localized: "只看视频时不需要麦克风和输入监控；以后要开会或打电话，可从 设置 › 通用 › 使用引导… 打开"))],
                            indented: true)
                }
            } header: {
                SectionHeader(String(localized: "收听"), symbol: Icon.listen)
            }
            if !model.videoOnly {
                Section {
                    GrantRow(symbol: Icon.physicalMic, title: String(localized: "麦克风"),
                             help: String(localized: "会议中持续收音，默认传原声"),
                             status: grant(f.microphone, denied: model.microphoneDenied),
                             actionTitle: String(localized: "允许…"), action: model.requestMicrophone,
                             openSettings: { model.openPrivacy("Privacy_Microphone") })
                    // Input Monitoring has no readable "refused" state; "允许…" opens System Settings.
                    GrantRow(symbol: SubtitleTokens.OnboardingIcon.inputMonitoring, title: String(localized: "右⌥快捷键"),
                             key: TitlebarKey(action: String(localized: "开始翻译"), drawsAction: false, style: .idle),
                             help: String(localized: "需要输入监控；允许后 macOS 可能要求重开 TalkTalk"),
                             info: [String(localized: "快捷键只监听、不修改按键。权限由 macOS 管理，可在系统设置中调整。")],
                             status: grant(f.inputMonitoring, denied: false),
                             actionTitle: String(localized: "允许…"), action: model.requestInputMonitoring)
                } header: {
                    SectionHeader(String(localized: "我说话"), symbol: Icon.me)
                }
            }
        }
    }

    private func grant(_ allowed: Bool?, denied: Bool) -> GrantRow.Status {
        allowed == true ? .granted : (denied ? .denied : .pending)
    }
}

/// Step 2 (§7.17): the three languages as badges with their status in the corner, one 下载 for
/// what is missing; Apple's backup role is a chip.
private struct SpeechAssetsStep: View {
    let model: OnboardingFlowModel

    /// The language badge's tile (§7.17), its own component.
    private static let tile: Double = 48

    var body: some View {
        let failed = Lang.allCases.compactMap { lang -> String? in
            if case let .failed(error)? = model.assets[lang] { return error }
            return nil
        }
        OnboardingPage(title: StepTitle(.speechAssets, String(localized: "准备三种语言的语音资源"))) {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 16) {
                        language(.zh, name: String(localized: "中文"), badge: String(localized: "中"))
                        language(.en, name: String(localized: "英语"), badge: "EN")
                        language(.de, name: String(localized: "德语"), badge: "DE")
                        Spacer(minLength: 8)
                        Button { model.downloadAssets() } label: {
                            Label("下载", systemImage: Icon.download).labelStyle(.titleAndIcon)
                        }
                        .disabled(model.facts.speechAssets == true || model.assets.values.contains(.downloading))
                        .help(String(localized: "下载缺少的语音资源"))
                    }
                    if !failed.isEmpty {
                        StatusLabel(String(localized: "下载失败"), .failed, help: failed.joined(separator: "\n"))
                    }
                    FactRow([FactChip(String(localized: "Apple 备用识别"), symbol: Icon.recognition,
                                      help: String(localized: "备用识别与说话预览 · 由 macOS 下载和管理"),
                                      spoken: String(localized: "Qwen 负责主要语音识别；Apple 语音资源支持备用识别与说话预览，由 macOS 下载和管理。这一步不选择文本翻译模型。"))])
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func language(_ lang: Lang, name: String, badge: String) -> some View {
        let status = assetStatus(lang)
        return VStack(spacing: 6) {
            Text(verbatim: badge).font(.title2.weight(.medium))
                .frame(width: Self.tile, height: Self.tile)
                .background(RoundedRectangle(cornerRadius: SubtitleTokens.Radius.settingsCard).fill(.quaternary))
                .overlay(alignment: .topTrailing) {
                    StatusGlyph(status.status, size: .badge).offset(x: Ladder.badgeDisc / 3, y: -Ladder.badgeDisc / 3)
                }
            Text(verbatim: name).font(.callout)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(name)，\(status.text)"))
        .help([status.help ?? status.text, AppleSpeechASR.localeIdentifier(lang)].joined(separator: " · "))
    }

    private func assetStatus(_ lang: Lang) -> SettingsProblem {
        switch model.assets[lang] ?? .unknown {
        case .installed: SettingsProblem(.ok, String(localized: "已安装"))
        case .downloading: SettingsProblem(.busy, String(localized: "下载中"))
        case .missing: SettingsProblem(.pending, String(localized: "未安装"))
        case .unknown: SettingsProblem(.busy, String(localized: "检查中"))
        case let .failed(error): SettingsProblem(.failed, String(localized: "失败"), help: error)
        }
    }
}

/// Step 3 (§7.17): Settings › 组件's driver diagram and the install fact, then its 驱动 rows as
/// Form rows of their own, without the header (the administrator confirmation and self-test of
/// the installed component model).
private struct DriverStep: View {
    let model: OnboardingFlowModel

    var body: some View {
        // The rows' refresh and confirmations go on the page once, as Settings › 组件 puts them
        // on its Form; never on a Section, which would hand them to every row.
        if let driver = model.driverPage?.model {
            page
                .driverComponentLifecycle(driver)
                .onChange(of: driver.state, initial: true) { _, _ in model.refreshDriver() }
        } else {
            page
        }
    }

    private var page: some View {
        OnboardingPage(title: StepTitle(.driver, String(localized: "安装虚拟麦克风"))) {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    FlowGrid.driver(model.driverPage?.model)
                    FactRow([FactChip(String(localized: "需管理员授权 · 声音中断约 1 秒"), symbol: Icon.locked, tone: .warn,
                                      help: String(localized: "安装时输入一次密码，系统声音短暂中断"),
                                      spoken: String(localized: "首次安装需要管理员授权，系统声音会短暂中断"))])
                }
                .padding(.vertical, 4)
            }
            Section { rows }
        }
    }

    @ViewBuilder private var rows: some View {
        if let page = model.driverPage {
            if let driver = page.model {
                DriverComponentRows(model: driver)
            } else if let problem = page.problem {
                // A development binary without a bundle id (§5.2): the reason is the help.
                ContentUnavailableView(String(localized: "此构建不可用"), systemImage: Icon.unavailable)
                    .help(problem)
            } else {
                StatusGlyph(.busy)
                    .help(String(localized: "正在读取组件"))
                    .accessibilityLabel(String(localized: "正在读取组件"))
                    .frame(maxWidth: .infinity)
                    .onAppear { page.load(); model.refreshDriver() }
            }
        } else {
            Button { model.openDriverComponents?() } label: {
                Label("打开安装与维护", systemImage: Icon.Page.components).labelStyle(.titleAndIcon)
            }
            .disabled(model.openDriverComponents == nil)
        }
    }
}

/// Step 4 (§7.17): the two parts that run on this Mac, recognition and synthesis, with their
/// models as satellites; then Settings › 组件's 引擎 and 模型 sections with the same rows.
private struct EngineStep: View {
    let model: OnboardingFlowModel

    var body: some View {
        OnboardingPage(title: StepTitle(.engine, String(localized: "准备本地语音引擎"))) {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    FlowGrid.localEngine(model.engine, state: model.appState)
                    FactRow([FactChip(String(localized: "本机"), symbol: Icon.thisMac,
                                      help: String(localized: "识别与合成都在这台 Mac"),
                                      spoken: String(localized: "识别与合成都在这台 Mac 完成；下载可以取消，下次接着下"))])
                }
                .padding(.vertical, 4)
            }
            if model.engine.installer == nil {
                Section { EngineUnavailableView() }
            } else {
                Section {
                    EngineControlRows(model: model.engine)
                } header: {
                    SectionHeader(String(localized: "引擎"), symbol: Icon.engine)
                }
                Section {
                    EngineModelRows(model: model.engine)
                } header: {
                    SectionHeader(String(localized: "模型"), symbol: Icon.Page.models)
                }
            }
        }
        .onAppear { model.engine.reload() }
        .onChange(of: model.engine.running) { _, running in
            if !running { Task { await model.refresh() } }
        }
    }
}

/// Step 5 (§7.17): 模型 › 文本翻译's DataBoundary and API key section; the buttons are the
/// window's footer.
private struct OpenAIStep: View {
    let model: OnboardingFlowModel

    var body: some View {
        OnboardingPage(title: StepTitle(.openAI, String(localized: "OpenAI 文本翻译"))) {
            if let t = model.translation.model {
                OpenAIOnboardingStep(model: t)
            } else if let p = model.translation.problem {
                Section {
                    ContentUnavailableView(String(localized: "此构建不可用"), systemImage: Icon.unavailable)
                        .help(p)
                }
            } else {
                Section {
                    StatusGlyph(.busy)
                        .help(String(localized: "正在读取翻译设置"))
                        .accessibilityLabel(String(localized: "正在读取翻译设置"))
                        .frame(maxWidth: .infinity)
                        .onAppear { model.translation.load() }
                }
            }
        }
    }
}

/// Step 6 (§7.17): Settings › 我的声音 itself, overview or take. The overview fills the page;
/// a take keeps its own height and the page scrolls when the window is shorter.
private struct VoiceStep: View {
    let model: OnboardingFlowModel

    /// MyVoiceSettingsView's line above a take (engine switched, installer running).
    private static let takeNotes: Double = 44

    var body: some View {
        let voice = model.voice
        let take = voice.enrollment == nil ? nil
            : EnrollmentView.minimumHeight + (voice.recordingNote != nil || voice.saveBlocked ? Self.takeNotes : 0)
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(.voice, String(localized: "准备我的声音"))
            ScrollView {
                MyVoiceSettingsView(model: voice)
                    .containerRelativeFrame(.vertical, alignment: .top) { length, _ in
                        take.map { max(length, $0) } ?? length
                    }
            }
        }
    }
}

// MARK: - diagrams

@MainActor
extension FlowGrid {
    /// Step 4 (§7.17): 声音 → 原文 (Qwen3-ASR) and 译文 → 我的声音 (Qwen3-TTS), the two parts
    /// the engine runs on this Mac; translation itself is not installed here.
    static func localEngine(_ engine: EngineComponentsModel, state: AppState) -> FlowGrid {
        let recognition = engine.recognitionProblem(state)
        let synthesis = engine.synthesisProblem
        return FlowGrid(String(localized: "本地语音引擎"), lanes: [
            FlowLane(String(localized: "识别"), cells: [
                .node(FlowNode(String(localized: "声音"), glyph: .symbol(Icon.recognition), badge: recognition?.status,
                               badgeReason: recognition?.text,
                               satellite: FlowSatellite(engine.usesAppleRecognition ? "Apple Speech" : "Qwen3-ASR", symbol: Icon.Page.models,
                                                        help: String(localized: "识别声音")))),
                .node(FlowNode(String(localized: "原文"), glyph: .symbol(Icon.sourceText))),
                .empty, .empty
            ]),
            FlowLane(String(localized: "合成"), cells: [
                .node(FlowNode(String(localized: "译文"), glyph: .symbol(Icon.translation),
                               help: String(localized: "由 OpenAI 或 Apple 翻译，不在这里安装"))),
                .node(FlowNode(String(localized: "我的声音"), glyph: .symbol(Icon.myVoice), badge: synthesis?.status,
                               badgeReason: synthesis?.text,
                               satellite: FlowSatellite("Qwen3-TTS", symbol: Icon.Page.models,
                                                        help: String(localized: "合成译音")))),
                .empty, .empty
            ])
        ])
    }
}
