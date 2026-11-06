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
    private(set) var probeNote: String?
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
        probeNote = nil
        let r = await Task.detached { TCCProbe.run() }.value
        probeRunning = false
        let v: OnboardingProbeVerdict
        switch r.verdict {
        case .granted:
            v = .granted
        case .denied:
            v = .denied
            probeNote = String(localized: "系统录音被拒绝：请在“系统设置 › 隐私与安全性 › 录屏与系统录音”里允许 TalkTalk。")
        case .inconclusive:
            v = .inconclusive
            probeNote = String(localized: "没能确认（探针没听到声音）。可以继续；第一次开始同传或字幕时会再检查。")
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

struct OnboardingView: View {
    @Bindable var model: OnboardingFlowModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                page
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
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
                    ProgressView().controlSize(.small).accessibilityLabel(String(localized: "正在检查"))
                }
            }
            // The indicator shows the position; "第 X 步，共 Y 步" is its VoiceOver value.
            if !model.choosingScenarios, let current = model.step {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(model.steps, id: \.self) { step in
                        let status = stepStatus(step)
                        VStack(spacing: 5) {
                            Image(systemName: status.symbol ?? step.guideSymbol)
                                .font(.system(size: 16, weight: .medium))
                                .frame(width: 30, height: 30)
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
                .accessibilityValue(model.state.position(of: current).map {
                    String(localized: "第 \($0) 步，共 \(model.steps.count) 步")
                } ?? "")
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    /// Current: white glyph on the accent disc. Passed and skipped: a secondary check or minus
    /// (passing a step is not proof that it was verified, so never green). Future: tertiary.
    private func stepStatus(_ step: OnboardingStep) -> (symbol: String?, foreground: AnyShapeStyle,
                                                         fill: AnyShapeStyle, text: String) {
        let quiet = AnyShapeStyle(Color.secondary.opacity(0.12))
        if step == model.step {
            return (nil, AnyShapeStyle(Color.white), AnyShapeStyle(Color.accentColor), String(localized: "当前步骤"))
        }
        if model.state.skipped.contains(step) {
            return ("minus", AnyShapeStyle(.secondary), quiet, String(localized: "已略过，可稍后设置"))
        }
        if let current = model.step, step < current {
            return ("checkmark", AnyShapeStyle(.secondary), quiet, String(localized: "已走过此步骤"))
        }
        return (nil, AnyShapeStyle(.tertiary), quiet, String(localized: "后续步骤"))
    }

    @ViewBuilder private var page: some View {
        if model.choosingScenarios {
            ScenarioChoiceStep(model: model)
        } else {
            stepPage
        }
    }

    @ViewBuilder private var stepPage: some View {
        switch model.step {
        case .permissions?: PermissionsStep(model: model)
        case .speechAssets?: SpeechAssetsStep(model: model)
        case .driver?: DriverStep(model: model)
        case .engine?: EngineStep(model: model)
        case .openAI?: OpenAIStep(model: model)
        case .voice?:
            VStack(alignment: .leading, spacing: 16) {
                StepTitle(number: OnboardingStep.voice.number, title: "准备我的声音")
                MyVoiceSettingsView(model: model.voice).frame(minHeight: 420)
            }
        case .meetingMic?: MeetingMicStep(model: model)
        case .tryIt?: TryItStep(model: model)
        case nil: DoneStep(model: model)
        }
    }

    private var footer: some View {
        HStack {
            if model.choosingScenarios {
                Button("稍后设置") { model.onFinish?() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("继续") { model.confirmScenarios() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedScenarios.isEmpty)
            } else {
                stepFooter
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }

    @ViewBuilder private var stepFooter: some View {
        if model.step != nil { Button("上一步") { model.back() } }
        if model.step == .permissions { Button("稍后设置") { model.onFinish?() }.keyboardShortcut(.cancelAction) }
        Spacer()
        if let s = model.step, s.skippable, s != .openAI, s != .tryIt {
            Button(s == .meetingMic ? String(localized: "稍后核验") : String(localized: "跳过")) { model.skip() }
        }
        if model.step == .tryIt {
            Button("完成") { model.next() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        } else if model.step != .openAI, model.step != nil {
            Button("继续") { model.next() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canContinue)
        } else if model.step == nil {
            Button("关闭") { model.onFinish?() }.keyboardShortcut(.cancelAction)
            Button("打开使用场景") { model.openScenario?(model.primaryScenario) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.openScenario == nil)
        }
    }
}

/// A permission row. The trailing slot carries the state: a green check when allowed, the
/// action button while undecided, a red cross when refused (macOS will not ask again).
private struct GrantRow: View {
    enum Status { case granted, pending, denied }

    let symbol: String
    let title: LocalizedStringKey
    let note: LocalizedStringKey
    let status: Status
    let action: () -> Void
    let actionTitle: LocalizedStringKey
    var busy = false
    /// After a refusal: the action still helps (re-running the probe after a change in System
    /// Settings) and, when given, a System Settings button for this row.
    var actionWorksWhenDenied = false
    var openSettings: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary)
                .frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                SettingsNote(note)
            }
            Spacer(minLength: 8)
            switch status {
            case .granted:
                statusGlyph(SubtitleTokens.SettingsIcon.statusOK, .green, String(localized: "已允许"))
            case .pending:
                Button(actionTitle, action: action).disabled(busy)
            case .denied:
                statusGlyph(SubtitleTokens.SettingsIcon.statusFailed, .red, String(localized: "已拒绝"))
                if let openSettings {
                    Button(action: openSettings) {
                        Label("打开“隐私与安全性”", systemImage: SubtitleTokens.VoiceIcon.openPhone)
                    }
                }
                if actionWorksWhenDenied { Button(actionTitle, action: action).disabled(busy) }
            }
        }
    }

    private func statusGlyph(_ name: String, _ color: Color, _ text: String) -> some View {
        Image(systemName: name).font(.title3).foregroundStyle(color)
            .help(text).accessibilityLabel(text)
    }
}

private struct PermissionsStep: View {
    let model: OnboardingFlowModel
    var body: some View {
        let f = model.facts
        VStack(alignment: .leading, spacing: 16) {
            if model.videoOnly {
                StepTitle(number: OnboardingStep.permissions.number, title: "允许收听应用声音与语音识别")
            } else {
                StepTitle(number: OnboardingStep.permissions.number, title: "允许需要的声音与按键访问")
            }
            OnboardingCard(title: "听对方 · 看视频字幕", symbol: "ear") {
                GrantRow(symbol: "speaker.wave.2", title: "应用声音", note: "收听选中的会议应用或浏览器，生成原文与中文字幕。",
                         status: grant(model.systemAudioShown, denied: model.systemAudioShown == false),
                         action: model.runSystemAudioProbe, actionTitle: "检查", busy: model.probeRunning,
                         actionWorksWhenDenied: true, openSettings: { model.openPrivacy("Privacy_ScreenCapture") })
                Divider()
                GrantRow(symbol: "waveform", title: "Apple 语音识别", note: "在本机识别声音，作为 Qwen 的备用。",
                         status: grant(f.speechRecognition, denied: model.speechRecognitionDenied),
                         action: model.requestSpeech, actionTitle: "允许…")
                if model.probeRunning { ProgressView("正在检查应用声音权限…").controlSize(.small) }
                if let note = model.probeNote {
                    Label(note, systemImage: SubtitleTokens.SettingsIcon.statusWarn)
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.videoOnly {
                if f.speechRecognition == false {
                    Button { model.openPrivacy("Privacy_SpeechRecognition") } label: {
                        Label("打开“隐私与安全性”", systemImage: SubtitleTokens.VoiceIcon.openPhone)
                    }
                }
                SettingsNote("只看视频时不需要麦克风和输入监控；以后要开会或打电话，可从 设置 › 通用 重新运行引导。")
            } else {
                OnboardingCard(title: "我说话 · 原声与按键翻译", symbol: "mic") {
                    GrantRow(symbol: "mic", title: "麦克风", note: "会议中持续收音：默认传原声，点按右⌥开始翻译，再点按结束发言。视频字幕不用麦克风。",
                             status: grant(f.microphone, denied: model.microphoneDenied),
                             action: model.requestMicrophone, actionTitle: "允许…")
                    Divider()
                    // Input Monitoring has no readable "refused" state; "允许…" opens System Settings.
                    GrantRow(symbol: "option", title: "右⌥快捷键", note: "需要输入监控权限。允许后，macOS 可能要求重开 TalkTalk。",
                             status: grant(f.inputMonitoring, denied: false),
                             action: model.requestInputMonitoring, actionTitle: "允许…")
                }
                if f.microphone == false || f.speechRecognition == false {
                    Button { model.openPrivacy(f.microphone == false ? "Privacy_Microphone" : "Privacy_SpeechRecognition") } label: {
                        Label("打开“隐私与安全性”", systemImage: SubtitleTokens.VoiceIcon.openPhone)
                    }
                }
                DisclosureGroup("只想看视频，或想了解权限用途？") {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsNote("可以先点“稍后设置”关闭引导，从菜单开始视频字幕；系统录音权限会在开始时检查。会议发言需要麦克风和输入监控。")
                        SettingsNote("快捷键只监听、不修改按键。权限由 macOS 管理，可在系统设置中调整。")
                    }.padding(.top, 8)
                }
            }
        }
    }

    private func grant(_ allowed: Bool?, denied: Bool) -> GrantRow.Status {
        allowed == true ? .granted : (denied ? .denied : .pending)
    }
}

private struct SpeechAssetsStep: View {
    let model: OnboardingFlowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepTitle(number: OnboardingStep.speechAssets.number, title: "准备三种语言的语音资源")
            OnboardingCard(title: "Apple 备用识别", symbol: SubtitleTokens.SettingsIcon.recognition) {
                HStack(alignment: .top, spacing: 12) {
                    language(.zh, name: String(localized: "中文"), badge: String(localized: "中"))
                    language(.en, name: String(localized: "英语"), badge: "EN")
                    language(.de, name: String(localized: "德语"), badge: "DE")
                }
                Divider()
                Button { model.downloadAssets() } label: {
                    Label("下载缺少的资源", systemImage: "arrow.down.circle")
                }
                .disabled(model.facts.speechAssets == true || model.assets.values.contains(.downloading))
                DisclosureGroup("这些资源用在哪里？") {
                    SettingsNote("Qwen 负责主要语音识别；Apple 语音资源支持备用识别与说话预览，由 macOS 下载和管理。这一步不选择文本翻译模型。")
                        .padding(.top, 8)
                }
            }
        }
    }

    private func language(_ lang: Lang, name: String, badge: String) -> some View {
        VStack(spacing: 8) {
            Text(verbatim: badge).font(.title2.weight(.medium))
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))
                .accessibilityHidden(true)
            Text(name).font(.headline)
            switch model.assets[lang] ?? .unknown {
            case .installed: Label("已安装", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .downloading: ProgressView("下载中").controlSize(.small)
            case .missing: Label("未安装", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
            case .unknown: ProgressView().controlSize(.small).accessibilityLabel(String(localized: "检查中"))
            case let .failed(error):
                Label("失败：\(error)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .top)
        .help(AppleSpeechASR.localeIdentifier(lang))
    }
}

private struct EngineStep: View {
    let model: OnboardingFlowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(number: OnboardingStep.engine.number, title: "准备本地语音引擎")
            OnboardingCard(title: "两个环节在本机完成", symbol: "desktopcomputer") {
                HStack(spacing: 20) {
                    SpeechFlow(steps: [("waveform", String(localized: "声音")), ("text.bubble", String(localized: "原文"))])
                    Divider()
                    SpeechFlow(steps: [("character.bubble", String(localized: "译文")), (SubtitleTokens.SettingsIcon.myVoice, String(localized: "我的声音"))])
                }.fixedSize(horizontal: false, vertical: true)
                SettingsNote("Qwen3-ASR 识别声音，Qwen3-TTS 合成译音。")
                DisclosureGroup("文本翻译与下载说明") {
                    SettingsNote("文本翻译由 OpenAI 或 Apple 完成；这里不安装翻译模型。下载可以取消，下次接着下。")
                        .padding(.top, 8)
                }
            }
            OnboardingCard(title: "安装与管理", symbol: "shippingbox") {
                EngineComponentsRows(model: model.engine)
            }
        }
        .onChange(of: model.engine.running) { _, running in
            if !running { Task { await model.refresh() } }
        }
    }
}

private struct OpenAIStep: View {
    let model: OnboardingFlowModel
    var body: some View {
        if let t = model.translation.model {
            OpenAIOnboardingStep(model: t, onContinue: { Task { await model.refresh(); model.next() } },
                                 onSkip: { model.skip() })
        } else if let p = model.translation.problem {
            VStack(alignment: .leading, spacing: 12) {
                StepTitle(number: OnboardingStep.openAI.number, title: "OpenAI 翻译")
                Text(p).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("跳过") { model.skip() }
            }
        } else {
            ProgressView().onAppear { model.translation.load() }
        }
    }
}

/// Step 3 reuses the installed component model, its administrator confirmation and self-test.
private struct DriverStep: View {
    let model: OnboardingFlowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepTitle(number: OnboardingStep.driver.number, title: "安装虚拟麦克风")
            OnboardingCard(title: "把你的声音送进会议", symbol: SubtitleTokens.SceneIcon.meeting) {
                // The titlebar's own 原声 and 译音 capsules name the two voices.
                HStack(spacing: 8) {
                    FlowNodeCard(symbol: nil, title: String(localized: "麦克风")) {
                        let original = VoiceState.resolve(audio: .original, scene: .meeting, phoneInputConfirmed: true)
                        let translating = VoiceState.resolve(audio: .translating, scene: .meeting, phoneInputConfirmed: true)
                        HStack(spacing: 4) {
                            VoiceCapsule(state: original).accessibilityLabel(original.title)
                            VoiceCapsule(state: translating).accessibilityLabel(translating.title)
                        }
                    }
                    FlowArrow()
                    FlowNodeCard(symbol: SubtitleTokens.SettingsIcon.talkTalkMic, title: "TalkTalk Mic")
                    FlowArrow()
                    FlowNodeCard(symbol: SubtitleTokens.SceneIcon.meeting, title: String(localized: "会议应用"))
                }
                .padding(.vertical, 4)
                SettingsNote("TalkTalk 用实体麦收音；会议应用用 TalkTalk Mic 接收原声或译音。")
            }
            // Audio interruption is a caution, not a neutral note.
            Label("首次安装需要管理员授权，系统声音会短暂中断。", systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange)
            if let page = model.driverPage {
                if let driver = page.model {
                    OnboardingCard(title: "安装状态", symbol: "shippingbox") {
                        DriverComponentSection(model: driver)
                    }
                    .onChange(of: driver.state, initial: true) { _, _ in model.refreshDriver() }
                } else if let problem = page.problem {
                    Text(verbatim: problem).foregroundStyle(.secondary)
                } else {
                    ProgressView().onAppear { page.load(); model.refreshDriver() }
                }
            } else {
                Button { model.openDriverComponents?() } label: {
                    Label("打开组件设置", systemImage: SettingsSection.components.symbol)
                }
                .disabled(model.openDriverComponents == nil)
            }
        }
    }
}
