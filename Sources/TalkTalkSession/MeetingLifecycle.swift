/// Meeting mode across sleep, screen lock and fast user switching (ARCHITECTURE.md, "实时音频与生命周期约束").
/// Pure. Any of them suspends (the tap stops). Resuming waits until every reason is gone (a
/// Mac that wakes to a locked screen stays suspended until unlock). Then it continues only if
/// the meeting process is still sending or receiving audio; otherwise meeting mode ends.
/// A sleep counts even when it came while already suspended (lock first, then the lid): the
/// resume says `afterSleep`, so the cloud connections are rebuilt (§6.4 wake).
public struct MeetingLifecycle: Sendable, Equatable {
    public enum Reason: String, Sendable, Hashable, CaseIterable { case sleep, lock, session }
    public enum Action: Sendable, Equatable { case none, suspend, resume(afterSleep: Bool), end }

    public private(set) var reasons: Set<Reason> = []
    /// A sleep happened since the last resume (whatever suspended first).
    public private(set) var sleptWhileSuspended = false
    public var isSuspended: Bool { !reasons.isEmpty }

    public init() {}

    public mutating func suspend(_ r: Reason) -> Action {
        let was = isSuspended
        reasons.insert(r)
        if r == .sleep { sleptWhileSuspended = true }
        return was ? .none : .suspend
    }

    /// `meetingHasAudio`: some resolved meeting process has IsRunningInput or IsRunningOutput now.
    public mutating func clear(_ r: Reason, meetingHasAudio: Bool) -> Action {
        guard reasons.remove(r) != nil, reasons.isEmpty else { return .none }
        defer { sleptWhileSuspended = false }
        return meetingHasAudio ? .resume(afterSleep: sleptWhileSuspended) : .end
    }
}
