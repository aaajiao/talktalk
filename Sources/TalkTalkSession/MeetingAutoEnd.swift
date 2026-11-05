/// Meeting-mode auto end (ARCHITECTURE.md §6.3, §16 决定 9). Pure; fed about once per second.
///  - Every resolved meeting process has had neither IsRunningInput nor IsRunningOutput for
///    `idleMinutes` (10): ask "会议似乎已结束"; no answer within `confirmSeconds` (60): end.
///  - Audio coming back, or the user saying "still in a meeting", cancels the question.
public struct MeetingAutoEnd: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable { case ok, ask, end }

    public let idleMs: Int
    public let confirmMs: Int
    private var quietSinceMs: Int?
    private var askedAtMs: Int?

    public init(idleMinutes: Double = 10, confirmSeconds: Double = 60) {
        idleMs = Int(idleMinutes * 60_000)
        confirmMs = Int(confirmSeconds * 1000)
    }

    public var asking: Bool { askedAtMs != nil }

    public mutating func observe(nowMs: Int, anyAudio: Bool) -> Verdict {
        if anyAudio {
            quietSinceMs = nil
            askedAtMs = nil
            return .ok
        }
        let since = quietSinceMs ?? nowMs
        quietSinceMs = since
        if let asked = askedAtMs { return nowMs - asked >= confirmMs ? .end : .ok }
        guard nowMs - since >= idleMs else { return .ok }
        askedAtMs = nowMs
        return .ask
    }

    /// "还在开会": start the quiet count again.
    public mutating func stillInMeeting(nowMs: Int) {
        quietSinceMs = nowMs
        askedAtMs = nil
    }
}
