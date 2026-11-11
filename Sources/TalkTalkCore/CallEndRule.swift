import Foundation

/// "通话结束" (ARCHITECTURE.md): every resolved meeting process has had neither
/// `IsRunningInput` nor `IsRunningOutput` for 30 s in a row, or has exited. Every deferred restore
/// waits for it. Shared by the app (`SystemInputSwitcher`) and the guard (`--sysinput-guard`).
///
/// It deliberately looks at both directions and not only "is it still reading TalkTalk Mic": some
/// clients stop mic IO while muted (M0-T9), and restoring then would hand a default-following
/// meeting app the physical mic as soon as you unmute. "In use" is IO only; a process being a HAL
/// client of the device means nothing (M0-T8: every Core Audio process is a client of every device).
public enum CallEndRule {
    public static let quietSeconds: Double = 30

    /// One meeting process object, as resolved by MeetingSourceResolver (§3.1).
    public struct Process: Sendable, Equatable, Hashable, Codable {
        /// The owning meeting app's bundle id (e.g. `us.zoom.xos`).
        public var appID: String
        public var pid: Int32
        public var isRunningInput: Bool
        public var isRunningOutput: Bool

        public init(appID: String, pid: Int32, isRunningInput: Bool, isRunningOutput: Bool) {
            self.appID = appID
            self.pid = pid
            self.isRunningInput = isRunningInput
            self.isRunningOutput = isRunningOutput
        }

        public var isActive: Bool { isRunningInput || isRunningOutput }
    }

    public enum Verdict: Sendable, Equatable {
        /// Some meeting process is doing IO.
        case inCall
        /// All quiet, but not for 30 s yet.
        case quiet(remaining: Double)
        case ended(Reason)

        public var hasEnded: Bool { if case .ended = self { true } else { false } }
    }

    public enum Reason: Sendable, Equatable {
        /// No process of the watched meeting apps exists any more.
        case exited
        /// All quiet for `quietSeconds`.
        case quiet
    }

    /// Carried between observations. `scope` = the meeting apps to watch (bundle ids); empty means
    /// every known meeting app (the conservative choice when the session's source is unknown).
    public struct State: Sendable, Equatable, Codable {
        public var scope: Set<String>
        public var quietSince: Double?

        public init(scope: Set<String> = []) {
            self.scope = scope
            self.quietSince = nil
        }
    }

    /// Feed one observation (all meeting processes right now) at time `now` (seconds, monotonic).
    public static func observe(_ state: inout State, processes: [Process], now: Double) -> Verdict {
        let watched = state.scope.isEmpty ? processes : processes.filter { state.scope.contains($0.appID) }
        if watched.isEmpty {
            state.quietSince = nil
            return .ended(.exited)
        }
        if watched.contains(where: \.isActive) {
            state.quietSince = nil
            return .inCall
        }
        let since = state.quietSince ?? now
        state.quietSince = since
        let quiet = now - since
        if quiet >= quietSeconds { return .ended(.quiet) }
        return .quiet(remaining: quietSeconds - quiet)
    }
}
