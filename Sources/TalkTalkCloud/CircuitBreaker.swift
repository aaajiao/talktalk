import Foundation
import TalkTalkCore

/// The shared breaker (§6.4 cloud steps 2–4, `cloud.breaker`). Counts only hard failures
/// (5xx, connection errors, validation rejects, response.failed): 3 in 30 s open it for 30 s;
/// an ordinary 429 on the primary opens it at once (Retry-After honoured). After the open
/// period one probe request is let through; success closes, failure re-opens.
/// Times are milliseconds on any monotonic clock.
public struct CircuitBreaker: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case closed
        case open(untilMs: Int)
        case halfOpen(probeInFlight: Bool)
    }

    public enum Allowance: Sendable, Equatable {
        case allowed
        /// The single trial request after an open period.
        case probe
        case rejected
    }

    public let failuresToOpen: Int
    public let windowMs: Int
    public let openMs: Int
    public let honorRetryAfter: Bool
    public private(set) var state: State = .closed
    private var failures: [Int] = []

    public init(failuresToOpen: Int, windowS: Int, openS: Int, honorRetryAfter: Bool = true) {
        self.failuresToOpen = failuresToOpen
        self.windowMs = windowS * 1000
        self.openMs = openS * 1000
        self.honorRetryAfter = honorRetryAfter
    }

    public init(_ c: PolicyProfile.Cloud.Breaker) {
        self.init(failuresToOpen: c.failuresToOpen, windowS: c.windowS, openS: c.openS, honorRetryAfter: c.honorRetryAfter)
    }

    public init(_ c: PolicyProfile.Cloud.TimeoutBreaker) {
        self.init(failuresToOpen: c.timeoutsToOpen, windowS: c.windowS, openS: c.openS, honorRetryAfter: false)
    }

    public mutating func allow(now: Int) -> Allowance {
        switch state {
        case .closed: return .allowed
        case .open(let until):
            guard now >= until else { return .rejected }
            state = .halfOpen(probeInFlight: true)
            return .probe
        case .halfOpen(let inFlight):
            if inFlight { return .rejected }
            state = .halfOpen(probeInFlight: true)
            return .probe
        }
    }

    public mutating func recordSuccess(now: Int) {
        if case .halfOpen = state { state = .closed; failures = [] }
    }

    /// Returns true when this failure opened the breaker.
    @discardableResult
    public mutating func recordFailure(now: Int) -> Bool {
        if case .halfOpen = state { open(now: now, forMs: openMs); return true }
        failures.append(now)
        failures.removeAll { now - $0 > windowMs }
        guard failures.count >= failuresToOpen, state == .closed else { return false }
        open(now: now, forMs: openMs)
        return true
    }

    /// Ordinary 429 on the primary: open now, for max(openS, Retry-After).
    public mutating func recordPrimaryRateLimit(now: Int, retryAfterS: Int?) {
        let ra = honorRetryAfter ? (retryAfterS ?? 0) * 1000 : 0
        open(now: now, forMs: max(openMs, ra))
    }

    /// A finished sentence that was neither a success nor a failure for this breaker (e.g. the
    /// probe timed out): let the next request probe again.
    public mutating func releaseProbe() {
        if case .halfOpen(true) = state { state = .halfOpen(probeInFlight: false) }
    }

    private mutating func open(now: Int, forMs: Int) {
        state = .open(untilMs: now + forMs)
        failures = []
    }
}

/// Everything that decides, per sentence, whether cloud MT is tried at all and how the result
/// is booked (§6.4): the shared breaker, a timeout breaker per direction (SPEAK / LISTEN),
/// the hedge pause after a 429 on B, and the sticky pause after 401/403/quota.
public struct CloudHealth: Sendable {
    public enum Direction: String, Sendable, CaseIterable { case speak, listen }

    public enum Gate: Sendable, Equatable {
        case cloud(probe: Bool)
        case apple(String)
    }

    public private(set) var shared: CircuitBreaker
    public private(set) var timeouts: [Direction: CircuitBreaker]
    public private(set) var hedgePausedUntilMs: Int = 0
    public private(set) var pausedReason: String?
    public private(set) var offline = false
    private let openOnPrimary429: Bool
    private var probing: [Direction: (shared: Bool, timeout: Bool)] = [:]

    public init(cloud: PolicyProfile.Cloud) {
        shared = CircuitBreaker(cloud.breaker)
        timeouts = Dictionary(uniqueKeysWithValues: Direction.allCases.map { ($0, CircuitBreaker(cloud.timeoutBreaker)) })
        openOnPrimary429 = cloud.breaker.openOnPrimary429
    }

    public func hedgingPaused(now: Int) -> Bool { now < hedgePausedUntilMs }

    public mutating func setOffline(_ off: Bool) { offline = off }

    /// Meeting end or a fixed key clears the sticky pause.
    public mutating func clearPause() { pausedReason = nil }

    public mutating func gate(_ d: Direction, now: Int) -> Gate {
        if let p = pausedReason { return .apple("paused:\(p)") }
        if offline { return .apple("offline") }
        let s = shared.allow(now: now)
        if s == .rejected { return .apple("breakerOpen") }
        let t = timeouts[d]!.allow(now: now)
        if t == .rejected {
            if s == .probe { shared.releaseProbe() }
            return .apple("timeoutBreakerOpen")
        }
        probing[d] = (s == .probe, t == .probe)
        return .cloud(probe: s == .probe || t == .probe)
    }

    /// A gate that said `.cloud(probe:)` but whose sentence never reached `record` (cancelled by
    /// the caller, deadline already passed, body failed): release the half-open probes.
    public mutating func releaseProbes(_ d: Direction) {
        let p = probing.removeValue(forKey: d) ?? (false, false)
        if p.0 { shared.releaseProbe() }
        if p.1 { timeouts[d]!.releaseProbe() }
    }

    /// Books one finished sentence. Returns log lines for state changes.
    @discardableResult
    public mutating func record(_ d: Direction, decision: HedgeDecision, hedgePauseS: Int?, now: Int) -> [String] {
        var log: [String] = []
        let probe = probing.removeValue(forKey: d) ?? (false, false)
        if let s = hedgePauseS {
            hedgePausedUntilMs = max(hedgePausedUntilMs, now + s * 1000)
            log.append("hedgePaused:\(s)s")
        }
        if let p = decision.pauseReason {
            pausedReason = p
            log.append("cloudPaused:\(p)")
        }
        if decision.outcome.winner != .apple {
            shared.recordSuccess(now: now)
            timeouts[d]!.recordSuccess(now: now)
            return log
        }
        if decision.primaryRateLimited, openOnPrimary429 {
            shared.recordPrimaryRateLimit(now: now, retryAfterS: decision.retryAfterS)
            log.append("breakerOpen:primary429")
        } else if decision.breakerFailure {
            if shared.recordFailure(now: now) { log.append("breakerOpen:hardFailures") }
        } else if probe.0 {
            shared.releaseProbe()
        }
        if decision.timedOut {
            if timeouts[d]!.recordFailure(now: now) { log.append("timeoutBreakerOpen:\(d.rawValue)") }
        } else if probe.1 {
            timeouts[d]!.releaseProbe()
        }
        return log
    }
}
