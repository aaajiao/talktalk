import Foundation

/// The app-local conversation state for MT (ARCHITECTURE.md). One list per
/// direction of what the other side actually heard (spoken), followed by clauses that already
/// have a translation but have not played yet (pending). Requests are stateless; this is the
/// only state, shared by every MT backend.
///
/// - Context for clause N+1 = spoken + pending-with-translation before it, in clause order.
///   A clause still in MT is simply missing (logged as mt.ctx_gap); nobody waits for it.
/// - `out.first_sample` → `markSpoken`.
/// - Drop / cancel / gate / merge of clause N → `rollback(from:)`: N leaves, later pending
///   clauses lose their translation and are retranslated when synthesis is still ≥ 2.0 s away;
///   the others keep their translation (mt.ctx_stale) and will be heard.
/// - Hedging: only the winning leg is recorded (`receive` ignores a second result).
public struct MTHistory: Sendable {
    public enum State: Sendable, Equatable {
        case inFlight
        case pending(String)
        case spoken(String)
    }

    public struct Entry: Sendable, Equatable {
        public var job: JobID
        public var source: String
        public var state: State
        /// Set when the entry kept a translation produced with now-wrong context.
        public var stale = false
        /// Set once audio for it started rendering (TTS requested); such clauses always play.
        public var synthesisStarted = false
    }

    public enum Event: Sendable, Equatable {
        /// Clause `job` was submitted while `missing` (earlier clauses) were still in MT.
        case ctxGap(job: JobID, missing: [JobID])
        /// Clause `job` keeps a translation made with stale context.
        case ctxStale(job: JobID)
    }

    public struct Retranslation: Sendable, Equatable {
        public var job: JobID
        public var source: String
        public var history: [MTTurn]
    }

    /// Minimum time until expected synthesis for a retranslation to be worth it (§5.4: ~2.0 s,
    /// about the hedged MT p90). Not in PolicyProfile §5.3, so it lives here (估).
    public static let retranslateMinLeadMs = 2000

    public private(set) var entries: [MTSession: [Entry]] = [:]
    public private(set) var events: [Event] = []

    public init() {}

    /// Registers a new clause and returns its context (stateless request history).
    public mutating func submit(_ job: JobID, session: MTSession, source: String, before successor: JobID? = nil) -> [MTTurn] {
        let position = successor.flatMap { index(of: $0, in: session) } ?? (entries[session]?.count ?? 0)
        let ctx = context(before: position, in: session)
        let missing = (entries[session] ?? []).prefix(position).filter { $0.state == .inFlight }.map(\.job)
        if !missing.isEmpty { events.append(.ctxGap(job: job, missing: missing)) }
        entries[session, default: []].insert(Entry(job: job, source: source, state: .inFlight), at: position)
        return ctx
    }

    /// Records the winning translation. Returns false (and records nothing) for an unknown job
    /// or when a translation was already recorded (the losing hedge leg).
    @discardableResult
    public mutating func receive(_ job: JobID, session: MTSession, target: String) -> Bool {
        guard let i = index(of: job, in: session), entries[session]![i].state == .inFlight else { return false }
        entries[session]![i].state = .pending(target)
        return true
    }

    /// TTS was requested for this clause: from now on it always plays (it is never retranslated).
    public mutating func markSynthesisStarted(_ job: JobID, session: MTSession) {
        guard let i = index(of: job, in: session) else { return }
        entries[session]![i].synthesisStarted = true
    }

    /// `out.first_sample`: pending → spoken.
    public mutating func markSpoken(_ job: JobID, session: MTSession) {
        guard let i = index(of: job, in: session), case .pending(let t) = entries[session]![i].state else { return }
        entries[session]![i].state = .spoken(t)
    }

    /// Clause `job` will not be heard (dropped at Q > 12 s, cancelled, gated): remove it and roll
    /// back the pending translations after it. `msUntilSynthesis(job)` is the expected time until
    /// that clause starts synthesis (nil = unknown, treated as far away).
    /// Returns the clauses to retranslate, each with its new context; at call time they are all
    /// in flight again, so each later one's context stops before the first of them.
    public mutating func rollback(from job: JobID, session: MTSession,
                                  msUntilSynthesis: (JobID) -> Int?) -> [Retranslation] {
        guard let i = index(of: job, in: session) else { return [] }
        entries[session]!.remove(at: i)
        return invalidate(from: i, session: session, msUntilSynthesis: msUntilSynthesis)
    }

    public mutating func invalidateAfter(_ job: JobID, session: MTSession,
                                          msUntilSynthesis: (JobID) -> Int?) -> [Retranslation] {
        guard let i = index(of: job, in: session) else { return [] }
        return invalidate(from: i + 1, session: session, msUntilSynthesis: msUntilSynthesis)
    }

    private mutating func invalidate(from position: Int, session: MTSession,
                                     msUntilSynthesis: (JobID) -> Int?) -> [Retranslation] {
        var out: [Retranslation] = []
        var k = position
        while k < entries[session]!.count {
            let e = entries[session]![k]
            let unheard: Bool
            switch e.state { case .spoken: unheard = false; case .pending, .inFlight: unheard = true }
            if unheard, !e.synthesisStarted {
                if (msUntilSynthesis(e.job) ?? Int.max) >= Self.retranslateMinLeadMs {
                    entries[session]![k].state = .inFlight
                    entries[session]![k].stale = false
                    out.append(Retranslation(job: e.job, source: e.source, history: context(before: k, in: session)))
                } else {
                    entries[session]![k].stale = true
                    events.append(.ctxStale(job: e.job))
                }
            }
            k += 1
        }
        return out
    }

    /// A retranslation has a fresh backend job ID, so cancelling the old request cannot cancel
    /// its replacement. Preserve this entry's position and return its corrected earlier context.
    public mutating func replaceJob(_ old: JobID, with job: JobID, session: MTSession) -> [MTTurn] {
        guard let i = index(of: old, in: session) else { return [] }
        entries[session]![i].job = job
        entries[session]![i].state = .inFlight
        entries[session]![i].stale = false
        return context(before: i, in: session)
    }

    /// summarize: the merged clauses (not yet synthesized) are replaced by one new clause at the
    /// position of the first of them; their pending translations are dropped.
    public mutating func merge(_ merged: [JobID], into job: JobID, session: MTSession, source: String) -> [MTTurn] {
        let positions = merged.compactMap { index(of: $0, in: session) }
        guard let first = positions.min() else { return submit(job, session: session, source: source) }
        for p in positions.sorted(by: >) { entries[session]!.remove(at: p) }
        let ctx = context(before: first, in: session)
        entries[session]!.insert(Entry(job: job, source: source, state: .inFlight), at: first)
        return ctx
    }

    /// Hard interrupt (double tap): every pending and in-flight clause is dropped.
    public mutating func cancelAll(session: MTSession) {
        entries[session]?.removeAll { if case .spoken = $0.state { false } else { true } }
    }

    /// Meeting end.
    public mutating func reset() { entries = [:]; events = [] }

    public mutating func drainEvents() -> [Event] { defer { events = [] }; return events }

    /// The heard history only (for tests and diagnostics).
    public func spoken(_ session: MTSession) -> [MTTurn] {
        (entries[session] ?? []).compactMap { if case .spoken(let t) = $0.state { MTTurn(source: $0.source, target: t) } else { nil } }
    }

    private func context(before position: Int, in session: MTSession) -> [MTTurn] {
        (entries[session] ?? []).prefix(position).compactMap {
            switch $0.state {
            case .spoken(let t), .pending(let t): MTTurn(source: $0.source, target: t)
            case .inFlight: nil
            }
        }
    }

    private func index(of job: JobID, in session: MTSession) -> Int? {
        entries[session]?.firstIndex { $0.job == job }
    }
}
