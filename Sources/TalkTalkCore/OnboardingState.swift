// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation

/// The eight onboarding steps (ARCHITECTURE.md §11 首次引导), in order.
public enum OnboardingStep: String, CaseIterable, Codable, Sendable, Comparable {
    case permissions      // 1 麦克风、语音识别、输入监控（+ 系统录音探针）
    case speechAssets     // 2 zh-CN / en-US / de-DE 语音资源
    case driver           // 3 虚拟麦克风
    case engine           // 4 引擎
    case openAI           // 5 OpenAI（可跳过）
    case voice            // 6 我的声音
    case meetingMic       // 7 会议 App 选 TalkTalk Mic（可“稍后核验”）
    case tryIt            // 8 试一次（LISTEN / SPEAK）

    public var number: Int { Self.allCases.firstIndex(of: self)! + 1 }

    /// Steps the user may leave undone and still go on (§11: 5 跳过, 7 稍后核验, 8 is a try-out).
    public var skippable: Bool {
        switch self {
        case .openAI, .meetingMic, .tryIt: true
        default: false
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.number < b.number }

    /// The step's glyph in the onboarding header and on its page title. Steps that set up
    /// something with a settings glyph reuse it: Apple speech recognition (`waveform`), the
    /// TalkTalk Mic device (`mic.circle`, not the physical `mic`) and my voice (never the
    /// other party's `person.wave.2`).
    public var guideSymbol: String {
        switch self {
        case .permissions: "hand.raised"
        case .speechAssets: SubtitleTokens.SettingsIcon.recognition
        case .driver: SubtitleTokens.SettingsIcon.talkTalkMic
        case .engine: "cpu"
        case .openAI: "character.bubble"
        case .voice: SubtitleTokens.SettingsIcon.myVoice
        case .meetingMic: "person.2.wave.2"
        case .tryIt: "play.circle"
        }
    }

    /// The steps for the chosen scenarios (redesign §7 首次引导). Video alone needs only app
    /// audio and speech recognition, the speech assets and the try-out ("准备视频字幕"). Step 7
    /// is about a meeting app's input, so a path without 会议 (phone, or phone and video) drops
    /// it: the phone follows the system default input.
    public static func path(for scenarios: Set<OnboardingScenario>) -> [OnboardingStep] {
        if OnboardingScenario.isVideoOnly(scenarios) { return [.permissions, .speechAssets, .tryIt] }
        return scenarios.contains(.meeting) ? allCases : allCases.filter { $0 != .meetingMic }
    }
}

/// "你会用 TalkTalk 做什么？" — the page before step 1; several may be chosen.
public enum OnboardingScenario: String, CaseIterable, Codable, Sendable, Comparable {
    case meeting, phone, video

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    /// Only video: no microphone, no virtual microphone and no speaking practice.
    public static func isVideoOnly(_ set: Set<Self>) -> Bool { set == [.video] }
}

/// How far onboarding is (`OnboardingState.progress`): the current step's 1-based position and
/// the length of the chosen path.
public struct OnboardingProgress: Sendable, Equatable {
    public let step: Int
    public let count: Int

    public init(step: Int, count: Int) {
        self.step = step
        self.count = count
    }

    /// "第 N 步，共 M 步": the onboarding header's VoiceOver value, the 使用引导… row and the menu.
    public var text: String { String(appLocalized: "第 \(step) 步，共 \(count) 步") }
}

/// The afplay probe's verdict (§3.1). nil wherever it appears: the probe has not run.
public enum OnboardingProbeVerdict: String, Sendable, Equatable { case granted, denied, inconclusive }

/// What is true on this Mac right now, gathered by the app each time a step is shown. nil:
/// not known yet (the check has not run), which never counts as done.
public struct OnboardingFacts: Sendable, Equatable {
    public var microphone: Bool?
    public var speechRecognition: Bool?
    public var inputMonitoring: Bool?
    /// afplay probe (§3.1) for system audio recording; nil: not run in this process (the
    /// state machine then uses the last persisted verdict).
    public var systemAudioProbe: OnboardingProbeVerdict?
    public var speechAssets: Bool?
    public var driverInstalled: Bool?
    public var engineInstalled: Bool?
    /// The key item exists (never its value), or the user chose to skip in step 5.
    public var openAIKeyPresent: Bool?
    public var voiceProfile: Bool?
    /// Step 6's recording flow is on screen: 继续 would throw the take away.
    public var recordingTake = false
    /// MeetingMicGuard turned green for a meeting app (§8.6).
    public var meetingMicVerified: Bool?

    public init(microphone: Bool? = nil, speechRecognition: Bool? = nil, inputMonitoring: Bool? = nil,
                systemAudioProbe: OnboardingProbeVerdict? = nil, speechAssets: Bool? = nil, driverInstalled: Bool? = nil,
                engineInstalled: Bool? = nil, openAIKeyPresent: Bool? = nil, voiceProfile: Bool? = nil,
                meetingMicVerified: Bool? = nil) {
        self.microphone = microphone
        self.speechRecognition = speechRecognition
        self.inputMonitoring = inputMonitoring
        self.systemAudioProbe = systemAudioProbe
        self.speechAssets = speechAssets
        self.driverInstalled = driverInstalled
        self.engineInstalled = engineInstalled
        self.openAIKeyPresent = openAIKeyPresent
        self.voiceProfile = voiceProfile
        self.meetingMicVerified = meetingMicVerified
    }

    /// Step 1 is done when the three prompts are granted and the system-audio probe has run
    /// without an explicit denial. An inconclusive probe does not block: the first meeting checks
    /// again (§3.1, MeetingSession's tccDenied path). A probe that has not run blocks.
    public var permissionsDone: Bool { permissionsDone(videoOnly: false) }

    /// Video alone needs app audio (the probe) and speech recognition, not the microphone or
    /// Input Monitoring.
    public func permissionsDone(videoOnly: Bool) -> Bool {
        let listening = speechRecognition == true && systemAudioProbe != nil && systemAudioProbe != .denied
        return videoOnly ? listening : listening && microphone == true && inputMonitoring == true
    }

    public func satisfied(_ step: OnboardingStep, videoOnly: Bool = false) -> Bool {
        switch step {
        case .permissions: permissionsDone(videoOnly: videoOnly)
        case .speechAssets: speechAssets == true
        case .driver: driverInstalled == true
        case .engine: engineInstalled == true
        case .openAI: openAIKeyPresent == true
        case .voice: voiceProfile == true && !recordingTake
        case .meetingMic: meetingMicVerified == true
        case .tryIt: true
        }
    }
}

/// The onboarding state machine (§11: "当前步骤存在 UserDefaults 里，重启 App 后从原处继续").
/// Every change is written through at once, so quitting at any point (including the relaunch
/// macOS asks for after Input Monitoring is granted) comes back to the same place.
public final class OnboardingState {
    /// `onboarding.v2.*`: an earlier draft used `onboarding.*` with other encodings; those keys
    /// are removed at launch so a stale "finished" cannot hide onboarding.
    public enum Key {
        public static let prefix = "onboarding.v2."
        public static let step = "onboarding.v2.step"
        public static let finished = "onboarding.v2.finished"
        /// Set once the last step was passed, kept by 使用引导… (restart): a run again is not
        /// "引导未完成" (the menu's start, the launch and Dock opening keep working meanwhile).
        public static let completedOnce = "onboarding.v2.completedOnce"
        public static let skipped = "onboarding.v2.skipped"
        public static let pendingRelaunch = "onboarding.v2.pendingRelaunch"
        /// Last afplay probe verdict; absent: never run. Survives the Input Monitoring relaunch.
        public static let systemAudioProbe = "onboarding.v2.systemAudioProbe"
        /// The scenarios chosen on the first page; absent: not chosen yet.
        public static let scenarios = "onboarding.v2.scenarios"
        static let legacyPrefix = "onboarding."
    }

    /// Why the app is about to be relaunched by the user (System Settings' "退出并重新打开").
    public enum Relaunch: String, Sendable { case inputMonitoring }

    /// The steps this build shows, before the scenario choice narrows them.
    public let buildSteps: [OnboardingStep]
    /// The steps of the chosen path, in order.
    public private(set) var steps: [OnboardingStep]
    private let defaults: UserDefaults

    public private(set) var current: OnboardingStep? {
        didSet { defaults.set(current?.rawValue, forKey: Key.step) }
    }
    public private(set) var finished: Bool {
        didSet { defaults.set(finished, forKey: Key.finished) }
    }
    public private(set) var completedOnce: Bool {
        didSet { defaults.set(completedOnce, forKey: Key.completedOnce) }
    }
    public private(set) var skipped: Set<OnboardingStep> {
        didSet { defaults.set(skipped.map(\.rawValue).sorted(), forKey: Key.skipped) }
    }
    public private(set) var pendingRelaunch: Relaunch? {
        didSet { defaults.set(pendingRelaunch?.rawValue, forKey: Key.pendingRelaunch) }
    }
    /// The last system-audio probe verdict, persisted (a denial is not forgotten by a relaunch).
    public private(set) var systemAudioProbe: OnboardingProbeVerdict? {
        didSet { defaults.set(systemAudioProbe?.rawValue, forKey: Key.systemAudioProbe) }
    }
    /// nil: not chosen (a fresh start, a restart, or onboarding begun before the page existed,
    /// which keeps the full path and its saved step).
    public private(set) var scenarios: Set<OnboardingScenario>? {
        didSet {
            if let scenarios { defaults.set(scenarios.map(\.rawValue).sorted(), forKey: Key.scenarios) }
            else { defaults.removeObject(forKey: Key.scenarios) }
        }
    }
    /// The scenario page is on screen (before step 1, or after 上一步 from the first step).
    public private(set) var choosingScenarios: Bool
    public var videoOnly: Bool { scenarios.map(OnboardingScenario.isVideoOnly) ?? false }

    /// `steps`: the steps this build shows, in order (all eight by default).
    public init(defaults: UserDefaults = .standard, steps: [OnboardingStep] = OnboardingStep.allCases) {
        self.defaults = defaults
        buildSteps = steps.sorted()
        Self.removeLegacyKeys(defaults)
        let saved = OnboardingStep(rawValue: defaults.string(forKey: Key.step) ?? "")
        finished = defaults.bool(forKey: Key.finished)
        // A finished run from before the mark existed counts as completed.
        completedOnce = defaults.bool(forKey: Key.completedOnce) || finished
        if completedOnce { defaults.set(true, forKey: Key.completedOnce) }
        let chosen = defaults.stringArray(forKey: Key.scenarios).map { Set($0.compactMap(OnboardingScenario.init(rawValue:))) }
        let kept = chosen?.isEmpty == true ? nil : chosen
        scenarios = kept
        self.steps = Self.steps(buildSteps, for: kept)
        // A fresh start shows the scenario page; a saved step continues where it was.
        choosingScenarios = !finished && saved == nil && kept == nil
        skipped = Set((defaults.stringArray(forKey: Key.skipped) ?? []).compactMap(OnboardingStep.init(rawValue:)))
        pendingRelaunch = Relaunch(rawValue: defaults.string(forKey: Key.pendingRelaunch) ?? "")
        systemAudioProbe = OnboardingProbeVerdict(rawValue: defaults.string(forKey: Key.systemAudioProbe) ?? "")
        if finished {
            current = nil
        } else if let saved, self.steps.contains(saved) {
            current = saved
        } else if let saved {
            // A step this build does not show: the next one it does.
            current = self.steps.first { $0 > saved } ?? self.steps.first
        } else {
            current = self.steps.first
        }
    }

    /// "引导未完成": never finished. A run again from 使用引导… does not take back what was
    /// already set up, so it is not "needed" (its progress still shows in Settings › 通用).
    public var needsOnboarding: Bool { !finished && !completedOnce }

    /// 1-based position of `step` in the chosen path ("第 2 步，共 3 步").
    public func position(of step: OnboardingStep) -> Int? { steps.firstIndex(of: step).map { $0 + 1 } }

    /// Where unfinished onboarding stands: the current step in the chosen path (step 1 while
    /// the scenario page is up). nil once finished. The one source of "第 N 步，共 M 步" for
    /// Settings › 通用 › 使用引导… and the menu bar menu's 继续使用引导 row.
    public var progress: OnboardingProgress? {
        guard !finished, let current, let n = position(of: current) else { return nil }
        return OnboardingProgress(step: n, count: steps.count)
    }

    private static func steps(_ build: [OnboardingStep], for scenarios: Set<OnboardingScenario>?) -> [OnboardingStep] {
        guard let scenarios else { return build }
        let path = Set(OnboardingStep.path(for: scenarios))
        let narrowed = build.filter(path.contains)
        return narrowed.isEmpty ? build : narrowed
    }

    /// The first page's 继续. A fresh choice starts the path at its first step; a step saved
    /// before the page existed is kept when the new path still contains it (else the next one).
    @discardableResult
    public func chooseScenarios(_ chosen: Set<OnboardingScenario>) -> Bool {
        guard !chosen.isEmpty, !finished else { return false }
        let fresh = choosingScenarios
        scenarios = chosen
        steps = Self.steps(buildSteps, for: chosen)
        choosingScenarios = false
        if fresh || current == nil {
            current = steps.first
        } else if let c = current, !steps.contains(c) {
            current = steps.first { $0 > c } ?? steps.first
        }
        return true
    }

    static func removeLegacyKeys(_ d: UserDefaults) {
        for k in d.dictionaryRepresentation().keys where k.hasPrefix(Key.legacyPrefix) && !k.hasPrefix(Key.prefix) {
            d.removeObject(forKey: k)
        }
    }

    /// Records a probe run (the app runs it when step 1 appears and before `resume`).
    public func recordSystemAudioProbe(_ v: OnboardingProbeVerdict) { systemAudioProbe = v }

    /// The facts with the persisted probe verdict filled in when this process has not run it.
    public func merged(_ f: OnboardingFacts) -> OnboardingFacts {
        var m = f
        if m.systemAudioProbe == nil { m.systemAudioProbe = systemAudioProbe }
        return m
    }

    /// Called at launch and whenever the onboarding window comes forward. Handles the Input
    /// Monitoring relaunch: once the grant is visible and the rest of step 1 is done, the flow
    /// continues with the step after it ("重开后回到这一步之后"). Nothing else moves by itself.
    public func resume(_ given: OnboardingFacts) {
        let facts = merged(given)
        guard pendingRelaunch == .inputMonitoring else { return }
        guard facts.inputMonitoring == true else { return }   // not granted yet: stay, keep the flag
        pendingRelaunch = nil
        if current == .permissions, facts.permissionsDone(videoOnly: videoOnly) { advance(from: .permissions) }
    }

    /// The user is about to quit for the Input Monitoring relaunch (or System Settings will do it).
    public func willRelaunch(for r: Relaunch) { pendingRelaunch = r }

    public func canContinue(_ step: OnboardingStep, _ facts: OnboardingFacts) -> Bool {
        step.skippable || merged(facts).satisfied(step, videoOnly: videoOnly)
    }

    /// "继续": only when the step is satisfied (or skippable, which then counts as skipped when
    /// it is not satisfied). Returns false and stays when it cannot go on.
    @discardableResult
    public func complete(_ step: OnboardingStep, _ given: OnboardingFacts) -> Bool {
        let facts = merged(given)
        guard step == current, canContinue(step, facts) else { return false }
        if facts.satisfied(step, videoOnly: videoOnly) { skipped.remove(step) } else { skipped.insert(step) }
        advance(from: step)
        return true
    }

    /// "跳过" / "稍后核验".
    @discardableResult
    public func skip(_ step: OnboardingStep) -> Bool {
        guard step == current, step.skippable else { return false }
        skipped.insert(step)
        advance(from: step)
        return true
    }

    /// From the first step this returns to the scenario page.
    public func back() {
        guard let c = current, let i = steps.firstIndex(of: c) else { return }
        if i > 0 { current = steps[i - 1] } else if !finished { choosingScenarios = true }
    }

    /// Settings › 通用 › 使用引导… once onboarding is finished (unfinished, it only continues).
    public func restart() {
        finished = false
        skipped = []
        pendingRelaunch = nil
        systemAudioProbe = nil
        scenarios = nil
        steps = buildSteps
        choosingScenarios = true
        current = steps.first
        // Not persisted: a quit on the scenario page comes back to it (a saved step with no
        // scenarios would read as onboarding begun before the page existed).
        defaults.removeObject(forKey: Key.step)
    }

    private func advance(from step: OnboardingStep) {
        choosingScenarios = false
        if let next = steps.first(where: { $0 > step }) {
            current = next
        } else {
            current = nil
            finished = true
            completedOnce = true
        }
    }
}
