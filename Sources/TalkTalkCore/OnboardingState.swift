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
    public var permissionsDone: Bool {
        microphone == true && speechRecognition == true && inputMonitoring == true
            && systemAudioProbe != nil && systemAudioProbe != .denied
    }

    public func satisfied(_ step: OnboardingStep) -> Bool {
        switch step {
        case .permissions: permissionsDone
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
        public static let skipped = "onboarding.v2.skipped"
        public static let pendingRelaunch = "onboarding.v2.pendingRelaunch"
        /// Last afplay probe verdict; absent: never run. Survives the Input Monitoring relaunch.
        public static let systemAudioProbe = "onboarding.v2.systemAudioProbe"
        static let legacyPrefix = "onboarding."
    }

    /// Why the app is about to be relaunched by the user (System Settings' "退出并重新打开").
    public enum Relaunch: String, Sendable { case inputMonitoring }

    public let steps: [OnboardingStep]
    private let defaults: UserDefaults

    public private(set) var current: OnboardingStep? {
        didSet { defaults.set(current?.rawValue, forKey: Key.step) }
    }
    public private(set) var finished: Bool {
        didSet { defaults.set(finished, forKey: Key.finished) }
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

    /// `steps`: the steps this build shows, in order (all eight by default).
    public init(defaults: UserDefaults = .standard, steps: [OnboardingStep] = OnboardingStep.allCases) {
        self.defaults = defaults
        self.steps = steps.sorted()
        Self.removeLegacyKeys(defaults)
        let saved = OnboardingStep(rawValue: defaults.string(forKey: Key.step) ?? "")
        finished = defaults.bool(forKey: Key.finished)
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

    public var needsOnboarding: Bool { !finished }

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
        if current == .permissions, facts.permissionsDone { advance(from: .permissions) }
    }

    /// The user is about to quit for the Input Monitoring relaunch (or System Settings will do it).
    public func willRelaunch(for r: Relaunch) { pendingRelaunch = r }

    public func canContinue(_ step: OnboardingStep, _ facts: OnboardingFacts) -> Bool {
        step.skippable || merged(facts).satisfied(step)
    }

    /// "继续": only when the step is satisfied (or skippable, which then counts as skipped when
    /// it is not satisfied). Returns false and stays when it cannot go on.
    @discardableResult
    public func complete(_ step: OnboardingStep, _ given: OnboardingFacts) -> Bool {
        let facts = merged(given)
        guard step == current, canContinue(step, facts) else { return false }
        if facts.satisfied(step) { skipped.remove(step) } else { skipped.insert(step) }
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

    public func back() {
        guard let c = current, let i = steps.firstIndex(of: c), i > 0 else { return }
        current = steps[i - 1]
    }

    /// Settings "重新运行引导".
    public func restart() {
        finished = false
        skipped = []
        pendingRelaunch = nil
        systemAudioProbe = nil
        current = steps.first
    }

    private func advance(from step: OnboardingStep) {
        if let next = steps.first(where: { $0 > step }) {
            current = next
        } else {
            current = nil
            finished = true
        }
    }
}
