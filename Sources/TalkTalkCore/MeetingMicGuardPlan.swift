// l10n: zh-Hans (scripts/check-strings.sh)
/// MeetingMicGuard's rules (ARCHITECTURE.md §8.6, §3.6, §3.8), pure: which microphone each
/// meeting app reads, the verdict for the current meeting source, and the "等确认" phase after a
/// coreaudiod restart or wake. TalkTalkAudio's `MeetingMicGuard` reads Core Audio (process
/// objects' `kAudioProcessPropertyDevices` input scope and `IsRunningInput`, device UIDs) and
/// feeds snapshots in; everything here compares UIDs, never AudioObjectIDs (they change on a
/// coreaudiod restart). Device and process properties only: no audio, no TCC.
public enum MeetingMicGuardPlan {
    /// An input device a meeting process reads, as Core Audio reported it just now.
    public struct InputDevice: Sendable, Hashable {
        public var uid: String
        public var name: String
        public var isAggregate: Bool
        /// An aggregate's active sub-devices that have input streams (UIDs). Empty when not an
        /// aggregate, or when it has none or they could not be read.
        public var inputSubDeviceUIDs: [String]

        public init(uid: String, name: String, isAggregate: Bool = false, inputSubDeviceUIDs: [String] = []) {
            self.uid = uid; self.name = name; self.isAggregate = isAggregate; self.inputSubDeviceUIDs = inputSubDeviceUIDs
        }
    }

    /// One meeting process object (attributed to its app by MeetingSourceResolver).
    public struct Process: Sendable, Hashable {
        public var appID: String
        public var appName: String
        public var pid: Int32
        public var isRunningInput: Bool
        /// `kAudioProcessPropertyDevices`, input scope. nil: could not be read (unknown).
        public var inputDevices: [InputDevice]?

        public init(appID: String, appName: String, pid: Int32, isRunningInput: Bool, inputDevices: [InputDevice]?) {
            self.appID = appID; self.appName = appName; self.pid = pid
            self.isRunningInput = isRunningInput; self.inputDevices = inputDevices
        }
    }

    /// TalkTalk Mic itself, or an aggregate whose only input sub-devices are TalkTalk Mic.
    /// Anything else is "not TalkTalk Mic": a physical mic, another virtual device (Krisp,
    /// Teams Audio: they pass the physical mic on), an aggregate with a physical input in it, or
    /// an aggregate whose sub-devices are unknown (conservative).
    public static func isTalkTalkMic(_ d: InputDevice) -> Bool {
        if d.uid == MicPolicy.talkTalkMicUID { return true }
        guard d.isAggregate, !d.inputSubDeviceUIDs.isEmpty else { return false }
        return d.inputSubDeviceUIDs.allSatisfy { $0 == MicPolicy.talkTalkMicUID }
    }

    /// One meeting app right now.
    public enum AppState: Sendable, Hashable {
        /// Every process of it that reads input reads TalkTalk Mic.
        case readsTalkTalkMic
        /// Some process of it reads this device (the first one that is not TalkTalk Mic).
        case readsOther(device: String)
        /// No process of it reads input (not in a call, muted with IO stopped, …).
        case notReading
        /// A process reads input but its devices could not be read.
        case unknown
    }

    public struct AppVerdict: Sendable, Hashable {
        public var appID: String
        public var appName: String
        public var state: AppState
    }

    /// Per app, in the order the apps first appear in `processes`.
    public static func apps(_ processes: [Process]) -> [AppVerdict] {
        var order: [String] = []
        var byApp: [String: [Process]] = [:]
        for p in processes {
            if byApp[p.appID] == nil { order.append(p.appID) }
            byApp[p.appID, default: []].append(p)
        }
        return order.map { id in
            let ps = byApp[id] ?? []
            let name = ps.first?.appName ?? id
            let reading = ps.filter(\.isRunningInput)
            guard !reading.isEmpty else { return AppVerdict(appID: id, appName: name, state: .notReading) }
            var unknown = false
            for p in reading {
                guard let devs = p.inputDevices else { unknown = true; continue }
                // Running input with no device listed: unknown, not "reads nothing".
                if devs.isEmpty { unknown = true; continue }
                if let other = devs.first(where: { !isTalkTalkMic($0) }) {
                    return AppVerdict(appID: id, appName: name, state: .readsOther(device: other.name))
                }
            }
            return AppVerdict(appID: id, appName: name, state: unknown ? .unknown : .readsTalkTalkMic)
        }
    }

    /// The verdict for the current meeting source (§8.6), the one PassthroughPolicy, the HUD, the
    /// settings page and onboarding read.
    public enum Verdict: Sendable, Hashable {
        /// Every scoped app that reads input reads TalkTalk Mic (at least one does).
        case green(appID: String, app: String)
        /// A scoped app reads something else: they hear your own voice.
        case physicalMic(appID: String, app: String, device: String)
        /// No scoped app reads input.
        case noReader

        public var micGuard: PassthroughPolicy.MicGuard {
            switch self {
            case .green: .green
            case .physicalMic: .meetingUsesPhysicalMic
            case .noReader: .noReaderOfTalkTalkMic
            }
        }

        /// "Zoom 正在用 MacBook Pro Microphone" plus where to change it (§8.6).
        public var detail: String? {
            switch self {
            case let .green(_, app): String(localized: "\(app) 正在用 TalkTalk Mic")
            case let .physicalMic(id, app, device):
                String(localized: "\(app) 正在用 \(device)：在 \(MeetingMicGuardPlan.settingsPath(appID: id, app: app)) 里选 TalkTalk Mic")
            case .noReader: nil
            }
        }
    }

    /// `scope`: the meeting apps of this session (bundle ids); empty = every known meeting app.
    /// nil: the process list could not be read, or a scoped app reads input from devices that
    /// could not be read and no other scoped app is red (unknown is unavailable, §3.8).
    public static func verdict(_ processes: [Process]?, scope: Set<String>) -> Verdict? {
        guard let processes else { return nil }
        let scoped = scope.isEmpty ? processes : processes.filter { scope.contains($0.appID) }
        let vs = apps(scoped)
        // Red first: one app on a physical mic is enough, whatever the others do.
        for v in vs {
            if case let .readsOther(device) = v.state {
                return .physicalMic(appID: v.appID, app: v.appName, device: device)
            }
        }
        if vs.contains(where: { $0.state == .unknown }) { return nil }
        if let g = vs.first(where: { $0.state == .readsTalkTalkMic }) { return .green(appID: g.appID, app: g.appName) }
        return .noReader
    }

    /// Where the app's microphone is chosen (shown with the red line). Paths of the apps in
    /// MeetingApp.known; checked against each app on the machine at M2 acceptance.
    public static func settingsPath(appID: String, app: String) -> String {
        switch appID {
        case "us.zoom.xos": String(localized: "Zoom › 设置 › 音频 › 麦克风")
        case "com.microsoft.teams2": String(localized: "Teams › 设置 › 设备 › 麦克风")
        case "com.tencent.meeting": String(localized: "腾讯会议 › 设置 › 音频 › 麦克风")
        case "com.apple.FaceTime": String(localized: "FaceTime 菜单栏 › 视频 › 麦克风")
        case "com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.apple.Safari":
            String(localized: "网页里的设备设置，或 \(app) 的网站设置 › 麦克风")
        default: String(localized: "\(app) 的音频设置")
        }
    }

    // MARK: the running guard

    public struct Config: Sendable, Equatable {
        /// After a coreaudiod restart or wake, green must hold this long before push to talk and
        /// passthrough are allowed again (估: lets a meeting app that is about to fall back to a
        /// physical mic show it first; §3.6 asks only for "确认", M2 measures).
        public var confirmSettle: Double
        /// The poll behind the listeners (§8.6 "每 2 s 一次轮询作后备").
        public var pollInterval: Double
        /// Right after meeting mode switched the default input to TalkTalk Mic, a meeting app set
        /// to "与系统相同" still reads the physical mic until it follows. The verdict is red at once
        /// (it is true); only the red line and the cue wait this long, so the recommended setup
        /// does not flash red on every start (估, M2 measures how long apps take to follow).
        public var startSettle: Double

        public init(confirmSettle: Double = 0.5, pollInterval: Double = 2, startSettle: Double = 1.5) {
            self.confirmSettle = confirmSettle; self.pollInterval = pollInterval; self.startSettle = startSettle
        }

        public static let `default` = Config()
    }

    /// What the guard says now, for every consumer.
    public struct State: Sendable, Hashable {
        /// nil: unknown (not observed yet, the list or a device could not be read).
        public var verdict: Verdict?
        /// After a coreaudiod restart or wake until green held `confirmSettle` (§3.6).
        public var awaitingConfirmation: Bool

        public init(verdict: Verdict? = nil, awaitingConfirmation: Bool = false) {
            self.verdict = verdict; self.awaitingConfirmation = awaitingConfirmation
        }

        /// PassthroughPolicy.Facts.micGuard.
        public var micGuard: PassthroughPolicy.MicGuard? { verdict?.micGuard }
        /// Push to talk is allowed by the guard: green and confirmed (red: the TTS would not reach
        /// them anyway and the remote hears you; §8.6). Unknown and no reader are not red: they
        /// leave push to talk to its other checks, except while awaiting confirmation.
        public var allowsPushToTalk: Bool {
            if awaitingConfirmation { return false }
            if case .physicalMic = verdict { return false }
            return true
        }
        /// OnboardingFacts.meetingMicVerified.
        public var verified: Bool { if case .green = verdict { !awaitingConfirmation } else { false } }
    }

    public enum Event: Sendable, Hashable {
        /// Became red (from anything else, or the red app / device changed): HUD red line, cue.
        case turnedRed(appID: String, app: String, device: String)
        /// No longer red.
        case clearedRed
        /// The wait after a restart or wake ended (green held `confirmSettle`).
        case confirmed
    }

    /// The guard's memory between observations.
    public struct Monitor: Sendable, Equatable {
        public let config: Config
        public private(set) var state = State()
        private var greenSince: Double?
        private var lastRed: Verdict?
        private var holdRedEventsUntil: Double?

        public init(config: Config = .default) { self.config = config }

        /// A coreaudiod restart (`ServiceRestarted`) or wake: wait for green again. Process and
        /// device objects are re-resolved by the caller (by UID).
        public mutating func audioRestarted() {
            state.awaitingConfirmation = true
            greenSince = nil
        }

        /// The default input was just switched to TalkTalk Mic: red events wait `startSettle`.
        public mutating func holdRedEvents(from now: Double) {
            holdRedEventsUntil = now + config.startSettle
        }

        /// Meeting mode ended or the guard stopped: nothing to wait for.
        public mutating func reset() {
            state = State()
            greenSince = nil
            lastRed = nil
            holdRedEventsUntil = nil
        }

        public struct Output: Sendable, Equatable {
            public var events: [Event]
            /// Observe again at this time even without a change (the end of `confirmSettle`).
            public var recheckAt: Double?
        }

        public mutating func observe(_ processes: [Process]?, scope: Set<String>, now: Double) -> Output {
            let v = MeetingMicGuardPlan.verdict(processes, scope: scope)
            var events: [Event] = []
            var recheck: Double?
            if let until = holdRedEventsUntil, now >= until { holdRedEventsUntil = nil }
            if case let .physicalMic(id, app, device) = v {
                if let until = holdRedEventsUntil {
                    // Still red when the start window ends: said then (a recheck, even with no change).
                    recheck = until
                } else {
                    if lastRed != v { events.append(.turnedRed(appID: id, app: app, device: device)) }
                    lastRed = v
                }
            } else if lastRed != nil, v != nil {
                // Unknown keeps the red line: it is cleared only by a verdict that is known.
                events.append(.clearedRed)
                lastRed = nil
            }
            state.verdict = v
            if case .green = v {
                let since = greenSince ?? now
                greenSince = since
                if state.awaitingConfirmation {
                    if now - since >= config.confirmSettle {
                        state.awaitingConfirmation = false
                        events.append(.confirmed)
                    } else {
                        let at = since + config.confirmSettle
                        recheck = min(recheck ?? at, at)
                    }
                }
            } else {
                greenSince = nil
            }
            return Output(events: events, recheckAt: recheck)
        }
    }
}
