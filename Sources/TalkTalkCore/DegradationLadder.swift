import Foundation

/// §6.4 v1 path: compilation is off, and the unvalidated 12-codebook optimization is skipped.
/// Changes are advice; the app applies them at a safe clause boundary, without changing voice.
public struct DegradationLadder: Sendable {
    public enum Tier: Int, Sendable, Comparable {
        case normal, buffered, pauseAppleDrafts, wholeClause, cloneUnavailable
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
        public var pausesAppleDrafts: Bool { self >= .pauseAppleDrafts }
        public var appleStartsAtDeadline: Bool { pausesAppleDrafts }
        public var usesWholeClauses: Bool { self >= .wholeClause }
    }
    public enum Reason: Sendable { case highRTF, underruns, thermal, lowPower, recovered }
    public struct Change: Sendable, Equatable {
        public var from, to: Tier
        public var reason: Reason
    }
    public private(set) var tier: Tier = .normal
    private var highSince: HostTime?
    private var thermalSince: HostTime?
    private var healthySince: HostTime?
    private var lastUnderruns: UInt64?
    private var underruns: [HostTime] = []
    private var lastTime: HostTime?
    public init() {}

    public func prerollMs(_ profile: PolicyProfile.Speak.TTS) -> Int {
        tier >= .buffered ? profile.degradedPrerollMs : profile.elsePrerollMs
    }

    /// `underrunCount` is the cumulative counter. The first observation establishes its
    /// baseline; a counter reset does not look like an enormous burst of underruns.
    /// A sustained trigger is re-evaluated after 10 s at each new tier, not on every poll.
    public mutating func observe(rtf: Double?, underrunCount: UInt64, thermalSerious: Bool,
                                  lowPower: Bool, at now: HostTime) -> Change? {
        guard lastTime.map({ now >= $0 }) ?? true else { return nil }
        lastTime = now
        let added = lastUnderruns.map { underrunCount >= $0 ? underrunCount - $0 : 0 } ?? 0
        lastUnderruns = underrunCount
        if added > 0 { underruns += Array(repeating: now, count: Int(min(added, 2))) }
        underruns.removeAll { now >= $0 && now - $0 > 60_000_000_000 }
        let validRTF = rtf.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if validRTF.map({ $0 > 0.6 }) == true { if highSince == nil { highSince = now } }
        else { highSince = nil }
        if thermalSerious { if thermalSince == nil { thermalSince = now } }
        else { thermalSince = nil }

        let old = tier
        var reason: Reason?
        if lowPower, tier == .normal { tier = .buffered; reason = .lowPower }
        else if underruns.count >= 2 { reason = .underruns }
        else if let since = highSince, now - since >= 10_000_000_000 { reason = .highRTF }
        else if let since = thermalSince, tier == .normal || now - since >= 10_000_000_000 { reason = .thermal }
        if let reason {
            if tier == old, tier < .cloneUnavailable { tier = Tier(rawValue: tier.rawValue + 1)! }
            highSince = highSince.map { _ in now }; thermalSince = thermalSince.map { _ in now }
            healthySince = nil; underruns.removeAll()
            return tier == old ? nil : Change(from: old, to: tier, reason: reason)
        }

        let healthy = validRTF.map({ $0 <= 0.35 }) == true && added == 0 && !thermalSerious
        if healthy { if healthySince == nil { healthySince = now } }
        else { healthySince = nil }
        let minimum: Tier = lowPower ? .buffered : .normal
        if tier > minimum, let since = healthySince, now - since >= 120_000_000_000 {
            tier = Tier(rawValue: tier.rawValue - 1)!
            healthySince = now
            return Change(from: old, to: tier, reason: .recovered)
        }
        return nil
    }
}
