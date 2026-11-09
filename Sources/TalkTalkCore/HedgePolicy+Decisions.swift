import Foundation

// The pure decisions behind HedgedRequest (ARCHITECTURE.md §4.1, §5.3, §6.4, §16 decision 13):
// when to send B, the deadline and its extension to the playout queue, who wins, whether the
// sentence counts as a breaker failure, and when to rebuild a connection. HedgedRequest only
// sends and cancels. All times are integer milliseconds since request A was sent (virtual
// clock), so the tests drive this with plain numbers.

/// The two long-lived URLSessions: A (primary) and B (hedge).
public enum Leg: String, Codable, Sendable, CaseIterable { case A, B }

/// How one leg ended without a usable result.
public enum LegFailure: Sendable, Equatable {
    case http5xx(Int)
    case connectionError
    case responseFailed
    /// Response validation failed (§5.4), including an unusable `response.incomplete`.
    case validationReject(String)
    /// Ordinary 429 (incl. `slow_down`); seconds from Retry-After when present.
    case rateLimited(retryAfterS: Int?)
    /// 401, 403 or a quota 429: pause cloud MT (§6.4 cloud step 7).
    case pause(String)
    /// Any other 4xx (400 for an unsupported effort, 404 for a retired model, ...).
    case clientError(Int)

    /// The shared breaker's `cloud.breaker.counts` key, nil when it is not a hard failure.
    public var breakerKey: String? {
        switch self {
        case .http5xx: "5xx"
        case .connectionError: "connectionError"
        case .responseFailed: "responseFailed"
        case .validationReject: "validationReject"
        case .rateLimited, .pause, .clientError: nil
        }
    }

    /// Failures after which the other leg may still be sent (§4.1 fastFailHedge). 429, 401,
    /// 403 and quota errors never trigger B.
    public var allowsHedge: Bool { breakerKey != nil }
}

public enum LegResult: Sendable, Equatable {
    case valid
    case failed(LegFailure)
}

public enum HedgeEvent: Sendable, Equatable {
    case tick(Int)
    case headers(Leg, Int)
    /// A `response.output_text.delta`.
    case delta(Leg, Int)
    /// Any other SSE event on that leg (progress, for the stall rule).
    case event(Leg, Int)
    case finished(Leg, Int, LegResult)

    var now: Int {
        switch self {
        case .tick(let t), .headers(_, let t), .delta(_, let t), .event(_, let t), .finished(_, let t, _): t
        }
    }
}

public enum FallbackReason: String, Codable, Sendable {
    /// Deadline passed with no usable cloud result.
    case deadline
    /// Every leg that was sent failed (or the only one failed and B could not be sent).
    case allFailed
    /// A failed after its first delta, too close to the deadline to send B.
    case failAfterDeltaNoTime
    /// No live leg had started to answer by the caller's reply time. Not a timeout: requests
    /// stall in bursts at a session's opening, and those must not open the timeout breaker.
    case noReply
}

public struct HedgeDecision: Sendable, Equatable {
    /// .A / .B: use that leg's text. .apple: no usable cloud result; the caller falls back
    /// (Apple Translation, or for a guard retry the first attempt / the next recovery step).
    public var outcome: HedgeOutcome
    public var fallback: FallbackReason?
    /// Counts once toward the shared breaker: every leg that was sent ended in a hard failure.
    public var breakerFailure: Bool
    /// Deadline passed: counts toward this direction's timeout breaker, never the shared one.
    public var timedOut: Bool
    /// The primary got an ordinary 429: the shared breaker opens (openOnPrimary429).
    public var primaryRateLimited: Bool
    public var retryAfterS: Int?
    /// 401/403/quota seen: pause cloud MT.
    public var pauseReason: String?

    public init(outcome: HedgeOutcome, fallback: FallbackReason?, breakerFailure: Bool, timedOut: Bool,
                primaryRateLimited: Bool, retryAfterS: Int?, pauseReason: String?) {
        self.outcome = outcome; self.fallback = fallback; self.breakerFailure = breakerFailure; self.timedOut = timedOut
        self.primaryRateLimited = primaryRateLimited; self.retryAfterS = retryAfterS; self.pauseReason = pauseReason
    }
}

public enum HedgeAction: Sendable, Equatable {
    case send(Leg, HedgeReason?)
    case startApple
    case cancel(Leg)
    /// B got a 429: no hedging for this many seconds (Retry-After if longer).
    case pauseHedging(seconds: Int)
    case finish(HedgeDecision)
}

/// State of one sentence's hedged request.
public struct HedgeRun: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// SPEAK clause (or LISTEN final): A first, B per the hedge rules.
        case normal
        /// NumberGuard / TargetTextGate retry: A and B from the start (§4.1, guardRetry).
        case guardRetry
    }

    struct LegState: Sendable, Equatable {
        var sentAt: Int?
        var headersAt: Int?
        var firstDeltaAt: Int?
        var lastEventAt: Int?
        var result: LegResult?
        var cancelled = false
        var inFlight: Bool { sentAt != nil && result == nil && !cancelled }
    }

    public internal(set) var kind: Kind
    public internal(set) var deadlineMs: Int
    var a = LegState()
    var b = LegState()
    var hedgeAllowed: Bool
    var appleAtHedge: Bool
    var appleLate: Bool
    /// Give up here unless a live leg has response headers; `deadlineMs` bounds one that does.
    var replyByMs: Int?
    var appleStarted = false
    var reason: HedgeReason?
    var bRateLimited: Int? = nil
    public internal(set) var decision: HedgeDecision?

    public var isDone: Bool { decision != nil }
    public var hedgeFired: Bool { b.sentAt != nil }
    /// Whether that leg had response headers before the decision (for SessionResetPolicy).
    public func hadHeaders(_ leg: Leg) -> Bool { (leg == .A ? a : b).headersAt != nil }
    /// Something is still in flight and none of it has started to answer.
    var waitingForReply: Bool {
        let live = [a, b].filter(\.inFlight)
        return !live.isEmpty && live.allSatisfy { $0.headersAt == nil }
    }

    subscript(leg: Leg) -> LegState {
        get { leg == .A ? a : b }
        set { if leg == .A { a = newValue } else { b = newValue } }
    }
}

extension HedgePolicy {
    // MARK: deadlines

    /// Time from A's send until the preceding clauses' audio finishes, per extendToDrain:
    /// rendered audio counts fully, unrendered clauses at `unrenderedFactor` of their expected
    /// length, clauses still in MT at `inFlightFactor` (0) of their source speech.
    public func precedingAudioMs(renderedMs: Double, unrenderedExpectedMs: Double, inFlightSourceMs: Double) -> Int {
        Int((renderedMs + unrenderedExpectedMs * extendToDrain.unrenderedFactor
             + inFlightSourceMs * extendToDrain.inFlightFactor).rounded())
    }

    /// Total deadline = max(totalDeadlineMs, preceding audio end − TTS first-chunk p95 − margin),
    /// at most maxDeadlineMs. When Apple only starts at the deadline (GPU step 3, `appleLate`),
    /// the extension above totalDeadlineMs is reduced by Apple's rolling p95, never below
    /// totalDeadlineMs.
    public func deadlineMs(precedingAudioMs: Int?, ttsFirstChunkP95Ms: Int, appleP95Ms: Int? = nil,
                           appleLate: Bool = false) -> Int {
        let base = totalDeadlineMs
        guard extendToDrain.enabled, let ahead = precedingAudioMs else { return base }
        var extended = ahead - ttsFirstChunkP95Ms - extendToDrain.marginMs
        if appleLate, extendToDrain.subtractAppleP95WhenLate, let apple = appleP95Ms { extended -= apple }
        return min(max(base, extended), max(base, extendToDrain.maxDeadlineMs))
    }

    /// Guard retry deadline = max(floorMs, preceding audio end − p95 − margin), at most maxMs,
    /// measured from the retry's send.
    public func guardRetryDeadlineMs(precedingAudioMs: Int?, ttsFirstChunkP95Ms: Int) -> Int {
        var d = guardRetry.floorMs
        if guardRetry.fromDrain, let ahead = precedingAudioMs {
            d = max(d, ahead - ttsFirstChunkP95Ms - extendToDrain.marginMs)
        }
        return min(d, guardRetry.maxMs)
    }

    /// NumberGuard retries only when the clause is masked by ≥ onlyIfMaskedMs of preceding audio,
    /// or the numbers hard-mismatch (§5.4).
    public func shouldRetryNumberGuard(maskedMs: Int, hardMismatch: Bool) -> Bool {
        hardMismatch || maskedMs >= guardRetry.onlyIfMaskedMs
    }

    // MARK: the state machine

    /// Starts a sentence at t = 0. `hedgingPaused`: a recent 429 on B (pauseAfter429S).
    /// `appleLate`: GPU step 3, Apple starts only at the deadline.
    public func begin(kind: HedgeRun.Kind = .normal, deadlineMs: Int, replyByMs: Int? = nil, hedgingPaused: Bool = false,
                      appleLate: Bool = false) -> (HedgeRun, [HedgeAction]) {
        let allowed = hedge.enabled && !hedgingPaused && hedge.maxInFlight >= 2
        var run = HedgeRun(kind: kind, deadlineMs: deadlineMs, hedgeAllowed: allowed,
                           appleAtHedge: hedge.startAppleAtHedge && !appleLate && kind == .normal,
                           appleLate: appleLate, replyByMs: replyByMs)
        var actions: [HedgeAction] = []
        run.a.sentAt = 0
        actions.append(.send(.A, nil))
        switch kind {
        case .guardRetry:
            // Prepare the same fallback while the cloud retries. Its result stays with
            // FallbackMT; a successful retry (or retained first translation) still wins.
            if hedge.startAppleAtHedge && !appleLate {
                run.appleStarted = true
                actions.append(.startApple)
            }
            // Retries are double-sent from the start (guardRetry.hedgeAfterMs = 0), even when
            // ordinary hedging is off or paused: they are rare and a late B can never make the floor.
            if guardRetry.hedgeAfterMs == 0, hedge.maxInFlight >= 2 {
                run.b.sentAt = 0
                run.reason = .guardRetry
                actions.append(.send(.B, .guardRetry))
            }
        case .normal:
            if allowed, hedge.afterMs == 0 {          // LISTEN double-send when enabled
                actions += fire(&run, .noDelta, at: 0)
            }
        }
        return (run, actions)
    }

    /// Feeds one event; returns what HedgedRequest must do now.
    public func step(_ run: inout HedgeRun, _ event: HedgeEvent) -> [HedgeAction] {
        guard !run.isDone else { return [] }
        let now = event.now
        switch event {
        case .tick:
            break
        case .headers(let leg, let t):
            if run[leg].inFlight, run[leg].headersAt == nil { run[leg].headersAt = t }
        case .delta(let leg, let t):
            guard run[leg].inFlight else { return [] }
            if run[leg].firstDeltaAt == nil { run[leg].firstDeltaAt = t }
            run[leg].lastEventAt = t
        case .event(let leg, let t):
            guard run[leg].inFlight else { return [] }
            run[leg].lastEventAt = t
        case .finished(let leg, _, let result):
            guard run[leg].inFlight else { return [] }   // late result after cancel: ignored
            run[leg].result = result
            // A double-send's legs are identical, so a 429 on either one means the same thing.
            if case .failed(.rateLimited(let ra)) = result, leg == .B || (hedge.afterMs == 0 && run.b.sentAt != nil) {
                run.bRateLimited = max(hedge.pauseAfter429S, ra ?? 0)
            }
        }
        var actions = evaluate(&run, now: now)
        if let s = run.bRateLimited {
            actions.insert(.pauseHedging(seconds: s), at: 0)
            run.bRateLimited = nil
        }
        return actions
    }

    /// The next time a `.tick` can change anything (absolute ms), nil when only events matter.
    public func nextWakeup(_ run: HedgeRun) -> Int? {
        guard !run.isDone else { return nil }
        var t = run.deadlineMs
        if let replyBy = run.replyByMs, run.waitingForReply { t = min(t, replyBy) }
        if run.hedgeAllowed, run.b.sentAt == nil, run.a.inFlight {
            if run.a.firstDeltaAt == nil {
                t = min(t, hedge.afterMs)
            } else if let last = run.a.lastEventAt {
                t = min(t, last + hedge.stallAfterDeltaMs)
            }
        }
        return t
    }

    private func fire(_ run: inout HedgeRun, _ reason: HedgeReason, at now: Int, forceApple: Bool = false) -> [HedgeAction] {
        run.b.sentAt = now
        run.reason = reason
        var out: [HedgeAction] = [.send(.B, reason)]
        if run.appleAtHedge || (forceApple && !run.appleLate), !run.appleStarted, run.kind == .normal {
            run.appleStarted = true
            out.append(.startApple)
        }
        return out
    }

    private func evaluate(_ run: inout HedgeRun, now: Int) -> [HedgeAction] {
        var out: [HedgeAction] = []

        // 1. A valid result wins; the other leg is cancelled at once.
        for leg in [Leg.A, .B] where run[leg].result == .valid {
            let other: Leg = leg == .A ? .B : .A
            if run[other].inFlight { run[other].cancelled = true; out.append(.cancel(other)) }
            let winner: HedgeWinner = leg == .A ? .A : .B
            out.append(.finish(decide(&run, winner: winner, fallback: nil, now: now)))
            return out
        }

        // 2. Deadline, or nothing has started to answer by the reply time: cancel everything
        // in flight, fall back.
        let noReply = run.replyByMs.map { now >= $0 && run.waitingForReply } ?? false
        if now >= run.deadlineMs || noReply {
            let reason: FallbackReason = now >= run.deadlineMs ? .deadline : .noReply
            for leg in Leg.allCases where run[leg].inFlight { run[leg].cancelled = true; out.append(.cancel(leg)) }
            return out + finishApple(&run, reason, now: now)
        }

        // 3. Sending B.
        if run.b.sentAt == nil {
            if let result = run.a.result, case .failed(let f) = result {
                guard run.hedgeAllowed, f.allowsHedge else { return finishApple(&run, .allFailed, now: now) }
                if run.a.firstDeltaAt == nil {
                    guard hedge.fastFailHedge else { return finishApple(&run, .allFailed, now: now) }
                    return fire(&run, .fastFail, at: now)
                }
                guard run.deadlineMs - now >= hedge.failAfterDeltaMinRemainMs else {
                    return finishApple(&run, .failAfterDeltaNoTime, now: now)
                }
                return fire(&run, .failAfterDelta, at: now, forceApple: true)
            }
            if run.hedgeAllowed, run.a.inFlight {
                if run.a.firstDeltaAt == nil, now >= hedge.afterMs {
                    return fire(&run, .noDelta, at: now)
                }
                if run.a.firstDeltaAt != nil, let last = run.a.lastEventAt, now - last >= hedge.stallAfterDeltaMs {
                    return fire(&run, .stall, at: now)
                }
            }
            return out
        }

        // 4. Both sent: nothing left in flight and no winner → fall back.
        if !run.a.inFlight, !run.b.inFlight {
            return out + finishApple(&run, .allFailed, now: now)
        }
        return out
    }

    private func finishApple(_ run: inout HedgeRun, _ reason: FallbackReason, now: Int) -> [HedgeAction] {
        var out: [HedgeAction] = []
        if !run.appleStarted, run.kind == .normal { run.appleStarted = true; out.append(.startApple) }
        out.append(.finish(decide(&run, winner: .apple, fallback: reason, now: now)))
        return out
    }

    private func decide(_ run: inout HedgeRun, winner: HedgeWinner, fallback: FallbackReason?, now: Int) -> HedgeDecision {
        let sent = Leg.allCases.filter { run[$0].sentAt != nil }
        let failures: [LegFailure] = sent.compactMap {
            if case .failed(let f) = run[$0].result { return f } else { return nil }
        }
        let allHard = winner == .apple && fallback != .deadline && failures.count == sent.count
            && failures.allSatisfy { $0.breakerKey != nil }
        var primary429 = false
        var retryAfter: Int?
        if case .failed(.rateLimited(let ra)) = run.a.result { primary429 = true; retryAfter = ra }
        var pause: String?
        for f in failures { if case .pause(let why) = f { pause = why } }
        let d = HedgeDecision(
            outcome: HedgeOutcome(fired: run.b.sentAt != nil, winner: winner, reason: run.reason, ms: now),
            fallback: fallback, breakerFailure: allHard, timedOut: fallback == .deadline,
            primaryRateLimited: primary429, retryAfterS: retryAfter, pauseReason: pause)
        run.decision = d
        return d
    }
}

// MARK: - connection rebuilds (§6.4 cloud step 6)

/// Decides when to rebuild URLSession A or B (`cloud.sessionReset`). Pure; one instance lives
/// next to the two sessions. Every returned reset is logged as cloud.session_reset{conn, reason}.
public struct SessionResetPolicy: Sendable, Equatable {
    public struct Reset: Sendable, Equatable {
        public var leg: Leg
        public var reason: String
    }

    public var config: PolicyProfile.Cloud.SessionReset
    var hedgeWinsWithoutLoserHeaders: [Leg: Int] = [:]   // key: the loser leg
    var keepWarmFailures: [Leg: Int] = [:]
    var listenNoHeaders = 0

    public init(config: PolicyProfile.Cloud.SessionReset) { self.config = config }

    /// After a hedged sentence was won. `loserHadHeaders`: the losing leg got response headers
    /// before the winner completed. Two wins in a row against a header-less loser → rebuild the loser.
    public mutating func recordHedgeWin(winner: Leg, loserHadHeaders: Bool) -> [Reset] {
        let loser: Leg = winner == .A ? .B : .A
        hedgeWinsWithoutLoserHeaders[winner] = 0
        guard !loserHadHeaders else { hedgeWinsWithoutLoserHeaders[loser] = 0; return [] }
        let n = (hedgeWinsWithoutLoserHeaders[loser] ?? 0) + 1
        hedgeWinsWithoutLoserHeaders[loser] = n
        guard n >= config.hedgeWinsWithoutPrimaryHeaders else { return [] }
        hedgeWinsWithoutLoserHeaders[loser] = 0
        return [Reset(leg: loser, reason: "hedgeWinsWithoutHeaders")]
    }

    /// Result of a keep-warm GET on that connection.
    public mutating func recordKeepWarm(_ leg: Leg, ok: Bool) -> [Reset] {
        guard !ok else { keepWarmFailures[leg] = 0; return [] }
        let n = (keepWarmFailures[leg] ?? 0) + 1
        keepWarmFailures[leg] = n
        guard n >= config.keepWarmFailuresInARow else { return [] }
        keepWarmFailures[leg] = 0
        return [Reset(leg: leg, reason: "keepWarmFailures")]
    }

    /// A LISTEN request on A: `headersAfterMs` nil when no headers arrived at all.
    public mutating func recordListenRequest(headersAfterMs: Int?) -> [Reset] {
        if let h = headersAfterMs, h <= config.listenNoHeadersMs { listenNoHeaders = 0; return [] }
        listenNoHeaders += 1
        guard listenNoHeaders >= config.listenNoHeadersInARow else { return [] }
        listenNoHeaders = 0
        return [Reset(leg: .A, reason: "listenNoHeaders")]
    }

    public mutating func onWake() -> [Reset] {
        guard config.onWake else { return [] }
        clear()
        return Leg.allCases.map { Reset(leg: $0, reason: "wake") }
    }

    public mutating func onPathChange() -> [Reset] {
        guard config.onPathChange else { return [] }
        clear()
        return Leg.allCases.map { Reset(leg: $0, reason: "pathChange") }
    }

    private mutating func clear() {
        hedgeWinsWithoutLoserHeaders = [:]; keepWarmFailures = [:]; listenNoHeaders = 0
    }
}
