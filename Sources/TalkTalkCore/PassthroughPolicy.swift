/// Passthrough availability (ARCHITECTURE.md §3.8 打开条件 3; privacy invariant 5). A pure
/// function of facts gathered elsewhere, each optional: nil means unknown (a poll timed out, a
/// device is being rebuilt, the source has not reported yet) and unknown is unavailable. The gate
/// evaluates it when the hold arms, again right before opening, and on every fact change while
/// open, where anything but `.available` closes.
public enum PassthroughPolicy {
    /// MeetingMicGuard for the current meeting source (§8.6), from the sysinput session.
    public enum MicGuard: Sendable, Hashable {
        case green                    // every active meeting process reads TalkTalk Mic
        case meetingUsesPhysicalMic   // the meeting app reads a physical mic: they already hear you
        case noReaderOfTalkTalkMic    // nobody reads TalkTalk Mic: passthrough would go nowhere
    }

    public struct Facts: Sendable, Hashable {
        public var meetingModeActive: Bool?
        public var settingEnabled: Bool?
        public var micGuard: MicGuard?
        /// OutputRouteClassifier.isSpeakerMode.
        public var speakerMode: Bool?
        /// The event tap is enabled, its port alive, no tapDisabled* since the last enable.
        public var tapHealthy: Bool?
        /// After a coreaudiod restart or wake, until MeetingMicGuard confirms (§3.6).
        public var awaitingAudioConfirmation: Bool?
        /// `IsSecureEventInputEnabled()` (§3.8 "安全输入"). When the symbol cannot be called at all
        /// KeyTap reports false and the key-state poll is the fallback; nil only while unknown.
        public var secureInput: Bool?
        /// PushToTalkMachine has a press in progress.
        public var pushToTalkActive: Bool?
        /// `--self-test --passthrough` is running.
        public var selfTestRunning: Bool?
        /// The physical mic passes MicPolicy rule 2 (not virtual, not aggregate, not
        /// `com.aaajiao.talktalk.*`, §3.2, §3.5), from the sysinput session.
        public var physicalMicPassesRule2: Bool?

        public init(meetingModeActive: Bool? = nil, settingEnabled: Bool? = nil, micGuard: MicGuard? = nil,
                    speakerMode: Bool? = nil, tapHealthy: Bool? = nil, awaitingAudioConfirmation: Bool? = nil,
                    secureInput: Bool? = nil, pushToTalkActive: Bool? = nil, selfTestRunning: Bool? = nil,
                    physicalMicPassesRule2: Bool? = nil) {
            self.meetingModeActive = meetingModeActive; self.settingEnabled = settingEnabled; self.micGuard = micGuard
            self.speakerMode = speakerMode; self.tapHealthy = tapHealthy
            self.awaitingAudioConfirmation = awaitingAudioConfirmation; self.secureInput = secureInput
            self.pushToTalkActive = pushToTalkActive; self.selfTestRunning = selfTestRunning
            self.physicalMicPassesRule2 = physicalMicPassesRule2
        }

        /// Every fact known and good (tests and the fuzz harness start from this).
        public static let allGood = Facts(meetingModeActive: true, settingEnabled: true, micGuard: .green,
                                          speakerMode: false, tapHealthy: true, awaitingAudioConfirmation: false,
                                          secureInput: false, pushToTalkActive: false, selfTestRunning: false,
                                          physicalMicPassesRule2: true)
    }

    public enum Fact: String, Sendable, Hashable, CaseIterable {
        case meetingModeActive, settingEnabled, micGuard, speakerMode, tapHealthy, awaitingAudioConfirmation,
             secureInput, pushToTalkActive, selfTestRunning, physicalMicPassesRule2
    }

    public enum DenyReason: Sendable, Hashable {
        case meetingModeOff
        case settingOff
        case unknown(Fact)
        case selfTestRunning
        case speakerMode
        case meetingUsesPhysicalMic
        case noReaderOfTalkTalkMic
        case secureInput
        case pushToTalkActive
        case tapUnhealthy
        case awaitingAudioConfirmation
        case micNotAllowed

        /// The gray HUD line (shown 1.5 s, no cue, §3.8 "提示"). nil: no reaction at all (outside
        /// meeting mode, or the setting is off: pressing ⌘ there must look like nothing happened).
        public var hudText: String? {
            switch self {
            case .meetingModeOff, .settingOff: nil
            case .unknown: "原声直通暂不可用"
            case .selfTestRunning: "自检进行中，原声直通暂不可用"
            case .speakerMode: "外放时不能用原声直通"
            case .meetingUsesPhysicalMic: "会议 App 正在用实体麦，对方本来就听得到你"
            case .noReaderOfTalkTalkMic: "会议没用 TalkTalk Mic"
            case .secureInput: "安全输入开启中"
            case .pushToTalkActive: "按键说话进行中"
            case .tapUnhealthy: "按键监听失效，原声直通暂不可用"
            case .awaitingAudioConfirmation: "音频系统重启中"
            case .micNotAllowed: "当前麦克风不能用于原声直通"
            }
        }

        /// `pt.deny{reason}` / `pt.close{reason}` tag: no text, no device names.
        public var tag: String {
            switch self {
            case .meetingModeOff: "meeting_off"
            case .settingOff: "setting_off"
            case let .unknown(f): "unknown_\(f.rawValue)"
            case .selfTestRunning: "self_test"
            case .speakerMode: "speaker_mode"
            case .meetingUsesPhysicalMic: "guard_physical_mic"
            case .noReaderOfTalkTalkMic: "guard_no_reader"
            case .secureInput: "secure_input"
            case .pushToTalkActive: "ptt_active"
            case .tapUnhealthy: "tap_unhealthy"
            case .awaitingAudioConfirmation: "awaiting_confirmation"
            case .micNotAllowed: "mic_rule2"
            }
        }
    }

    public enum Verdict: Sendable, Hashable {
        case available
        case unavailable(DenyReason)

        public var isAvailable: Bool { self == .available }
    }

    /// The order puts the silent reasons first (outside meeting mode nothing reacts), then the one
    /// the user can act on.
    /// `allowInSpeakerMode`: `speak.passthrough.allowInSpeakerMode` (false until M4's AEC3, §3.8).
    public static func evaluate(_ f: Facts, allowInSpeakerMode: Bool = false) -> Verdict {
        guard let meeting = f.meetingModeActive else { return .unavailable(.unknown(.meetingModeActive)) }
        guard meeting else { return .unavailable(.meetingModeOff) }
        guard let setting = f.settingEnabled else { return .unavailable(.unknown(.settingEnabled)) }
        guard setting else { return .unavailable(.settingOff) }
        guard let selfTest = f.selfTestRunning else { return .unavailable(.unknown(.selfTestRunning)) }
        if selfTest { return .unavailable(.selfTestRunning) }
        guard let speaker = f.speakerMode else { return .unavailable(.unknown(.speakerMode)) }
        if speaker && !allowInSpeakerMode { return .unavailable(.speakerMode) }
        guard let guardState = f.micGuard else { return .unavailable(.unknown(.micGuard)) }
        switch guardState {
        case .green: break
        case .meetingUsesPhysicalMic: return .unavailable(.meetingUsesPhysicalMic)
        case .noReaderOfTalkTalkMic: return .unavailable(.noReaderOfTalkTalkMic)
        }
        guard let awaiting = f.awaitingAudioConfirmation else { return .unavailable(.unknown(.awaitingAudioConfirmation)) }
        if awaiting { return .unavailable(.awaitingAudioConfirmation) }
        guard let secure = f.secureInput else { return .unavailable(.unknown(.secureInput)) }
        if secure { return .unavailable(.secureInput) }
        guard let ptt = f.pushToTalkActive else { return .unavailable(.unknown(.pushToTalkActive)) }
        if ptt { return .unavailable(.pushToTalkActive) }
        guard let tap = f.tapHealthy else { return .unavailable(.unknown(.tapHealthy)) }
        if !tap { return .unavailable(.tapUnhealthy) }
        guard let mic = f.physicalMicPassesRule2 else { return .unavailable(.unknown(.physicalMicPassesRule2)) }
        if !mic { return .unavailable(.micNotAllowed) }
        return .available
    }
}
