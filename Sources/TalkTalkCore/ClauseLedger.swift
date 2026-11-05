import Foundation

/// One row of state per SPEAK clause, kept by the app so an engine crash loses nothing (§5.7).
///
///     committed → asrDone → mtDone → ttsRequested → firstSampleEnqueued → played
///     terminal: cancelled, gated, dropped, incomplete
///
/// Invariants (ClauseLedgerTests, property tests on a virtual clock):
/// 1. A clause that reached `firstSampleEnqueued` is never voiced again. If its stream breaks it
///    becomes `incomplete`, and `requestTTS` refuses it forever after.
/// 2. Clone engine crash or hang during a press: clauses still waiting for TTS are kept for
///    `engineRetryS` (≈5 s) from the outage; when the engine is READY with the voice again they
///    are resent with the same clauseID. Past that window the rest of the press is voiceless:
///    its clauses are `dropped` (reason voiceUnavailable) and the HUD shows the text.
/// 3. Never a different voice within one press: the press's voice is fixed by its first send.
///    The system voice (§16 decision 5, `engineDownPolicy`) can only start with a later press.
/// 4. A passthrough cut (§3.8) or a stall marks the playing clause `incomplete`.
///
/// Pure value type; every method takes the time explicitly. Each state change goes to `sink`
/// as a `clause.state` event (§12.2); no text is stored here.
public struct ClauseLedger: Sendable {
    public enum State: String, Codable, Sendable, CaseIterable {
        case committed, asrDone, mtDone, ttsRequested, firstSampleEnqueued, played
        case cancelled, gated, dropped, incomplete

        public var isTerminal: Bool {
            switch self {
            case .played, .cancelled, .gated, .dropped, .incomplete: true
            default: false
            }
        }
        /// Position on the main path (terminal side states: nil).
        var rank: Int? {
            switch self {
            case .committed: 0
            case .asrDone: 1
            case .mtDone: 2
            case .ttsRequested: 3
            case .firstSampleEnqueued: 4
            case .played: 5
            default: nil
            }
        }
    }

    /// Why a clause left the main path (event `reason` tag, HUD wording).
    public enum Reason: String, Codable, Sendable {
        case hardInterrupt, gate, backlogDrop, engineLost, voiceUnavailable
        case passthroughCut, remoteFloor, stall, runaway, audioRestart, streamBroken, notReady
        /// The engine's last attempt still had an opening echo (`echo_aborts`), nothing released.
        case echo
    }

    /// §16 decision 5: a press that starts while the clone engine is still unavailable.
    public enum EngineDownPolicy: String, Codable, Sendable { case silent, systemVoice }

    /// What the clone path can do right now.
    public enum CloneAvailability: Sendable, Equatable {
        /// Engine READY and `voice.state == ready` with this handle.
        case ready(VoiceHandle)
        /// Crashed, hung, restarting, or the voice is (re)loading.
        case down
        /// No voice profile: C8 says the system voice is used (not decision 5).
        case noProfile
    }

    public enum Voice: Sendable, Equatable {
        case clone(VoiceHandle)
        case system
    }

    public struct Config: Sendable, Equatable {
        public var engineRetryS: Double
        public var engineDownPolicy: EngineDownPolicy
        public init(engineRetryS: Double = 5.0, engineDownPolicy: EngineDownPolicy = .silent) {
            self.engineRetryS = engineRetryS; self.engineDownPolicy = engineDownPolicy
        }
    }

    public struct Row: Sendable, Equatable {
        public var clause: UInt64
        public var press: UInt64
        public var state: State
        public var reason: Reason?
        public var job: JobID?
        public var attempts = 0
        /// The current job's stream delivered isLast: all audio of the clause is in ClauseQueue.
        public var rendered = false
        /// Sent before, but the stream broke before any sample: the next send reuses the clause ID.
        public var needsResend = false
        /// Waiting while the clone engine is down (invariant 2); measured from the outage start.
        /// Cleared when the engine is READY again, so a resend queued behind other jobs never expires.
        public var waitingSince: HostTime?
        public var changedAt: HostTime
    }

    public enum TTSDecision: Sendable, Equatable {
        case send(Voice)
        /// Not now; the clause stays and is returned by `engineReady` (unless it expires).
        case wait
        case refuse(Reason)
    }

    private enum PressVoice: Sendable, Equatable { case fixed(Voice), voiceless }

    public let config: Config
    public private(set) var rows: [UInt64: Row] = [:]
    private var pressVoice: [UInt64: PressVoice] = [:]
    public private(set) var engineDownSince: HostTime?
    public var sink: (any ClauseStateSink)?

    public init(config: Config = Config(), sink: (any ClauseStateSink)? = nil) {
        self.config = config; self.sink = sink
    }

    public func state(_ clause: UInt64) -> State? { rows[clause]?.state }
    public func row(_ clause: UInt64) -> Row? { rows[clause] }
    public func voice(ofPress press: UInt64) -> Voice? {
        if case .fixed(let v)? = pressVoice[press] { return v }
        return nil
    }
    public func isVoiceless(press: UInt64) -> Bool { pressVoice[press] == .voiceless }

    private var retryNs: HostTime { HostTime(config.engineRetryS * 1e9) }

    // MARK: main path

    public mutating func commit(_ clause: UInt64, press: UInt64, at t: HostTime) {
        guard rows[clause] == nil else { return }
        rows[clause] = Row(clause: clause, press: press, state: .committed, changedAt: t)
        emit(clause, at: t)
    }

    /// Forward-only moves before TTS (asrDone, mtDone). Returns false when refused.
    @discardableResult
    public mutating func advance(_ clause: UInt64, to s: State, at t: HostTime) -> Bool {
        guard var r = rows[clause], !r.state.isTerminal, let from = r.state.rank, let to = s.rank,
              to > from, s == .asrDone || s == .mtDone else { return false }
        r.state = s; r.changedAt = t
        rows[clause] = r
        emit(clause, at: t)
        return true
    }

    /// Whether `clause` may be (re)sent to TTS now and with which voice. On `.send` the row is
    /// `ttsRequested` with `job`.
    public mutating func requestTTS(_ clause: UInt64, job: JobID, clone: CloneAvailability, at t: HostTime) -> TTSDecision {
        guard var r = rows[clause] else { return .refuse(.notReady) }
        if r.state.isTerminal || r.state == .firstSampleEnqueued { return .refuse(r.reason ?? .streamBroken) }   // inv. 1
        guard r.state == .mtDone || (r.state == .ttsRequested && r.needsResend) else { return .refuse(.notReady) }

        switch clone {
        case .ready: engineDownSince = nil
        case .down: if engineDownSince == nil { engineDownSince = t }
        case .noProfile: break
        }
        let voice: Voice
        switch pressVoice[r.press] {
        case .voiceless?:
            drop(clause, reason: .voiceUnavailable, at: t)
            return .refuse(.voiceUnavailable)
        case .fixed(.system)?:
            voice = .system
        case .fixed(.clone(let h))?:
            guard clone == .ready(h) else { return wait(&r, at: t) }        // inv. 3: never another voice
            voice = .clone(h)
        case nil:
            switch clone {
            case .ready(let h):
                voice = .clone(h)
            case .noProfile:
                voice = .system                                             // C8
            case .down:
                // A recent outage is treated like a mid-press crash (wait, inv. 2); an outage
                // older than the retry window is decision 5.
                if let since = engineDownSince, t >= since, t - since <= retryNs { return wait(&r, at: t) }
                guard config.engineDownPolicy == .systemVoice else {
                    pressVoice[r.press] = .voiceless
                    drop(clause, reason: .voiceUnavailable, at: t)
                    return .refuse(.voiceUnavailable)
                }
                voice = .system
            }
            pressVoice[r.press] = .fixed(voice)
        }
        r.state = .ttsRequested; r.job = job; r.attempts += 1; r.rendered = false
        r.needsResend = false; r.waitingSince = nil; r.changedAt = t
        rows[clause] = r
        emit(clause, at: t)
        return .send(voice)
    }

    private mutating func wait(_ r: inout Row, at t: HostTime) -> TTSDecision {
        if r.waitingSince == nil { r.waitingSince = engineDownSince ?? t }
        rows[r.clause] = r
        if let since = r.waitingSince, t >= since, t - since > retryNs {
            expire(at: t)
            return .refuse(.voiceUnavailable)
        }
        return .wait
    }

    /// Whether audio of `job` for `clause` may still go to ClauseQueue: only the clause's current
    /// job, and only while it is requested (not waiting for a resend) or already playing.
    public func accepts(_ clause: UInt64, job: JobID) -> Bool {
        guard let r = rows[clause], r.job == job else { return false }
        return (r.state == .ttsRequested && !r.needsResend) || r.state == .firstSampleEnqueued
    }

    /// ClauseQueue wrote the first sample of `job`'s audio for the clause into ringO. Matched by
    /// job, not by needsResend (review 4): after `engineLost` the old job's held audio can still
    /// reach ringO; then it is being voiced, so the pending resend is cancelled (invariant 1).
    /// Another job's sample (stale) is ignored; a repeat is a no-op.
    public mutating func firstSampleEnqueued(_ clause: UInt64, job: JobID, at t: HostTime) {
        guard var r = rows[clause], r.state == .ttsRequested, r.job == job else { return }
        r.state = .firstSampleEnqueued; r.needsResend = false; r.waitingSince = nil; r.changedAt = t
        rows[clause] = r
        emit(clause, at: t)
    }

    /// ClauseQueue discarded the clause's audio although its stream did not fail: it came after a
    /// clause that has to be resent (`ClauseQueue.StreamFailure.discarded`) or the restart keep
    /// rule (`.rerender`). Back to waiting for a resend with the same clauseID, even when fully
    /// rendered. Returns false when there is nothing to resend (not sent yet, playing, or ended).
    @discardableResult
    public mutating func resend(_ clause: UInt64, at t: HostTime) -> Bool {
        guard var r = rows[clause], r.state == .ttsRequested else { return false }
        r.needsResend = true; r.rendered = false; r.changedAt = t
        rows[clause] = r
        return true
    }

    /// The stream of the clause's current job ended with isLast.
    public mutating func streamFinished(_ clause: UInt64, job: JobID) {
        guard var r = rows[clause], r.job == job, !r.state.isTerminal else { return }
        r.rendered = true
        rows[clause] = r
    }

    /// The stream of the clause's current job failed (engine error frame, runaway before start).
    /// No sample yet → it waits for a resend; samples already enqueued → `incomplete`.
    public mutating func streamFailed(_ clause: UInt64, job: JobID, reason: Reason, at t: HostTime) {
        guard var r = rows[clause], r.job == job, !r.state.isTerminal, !r.rendered else { return }
        if r.state == .firstSampleEnqueued {
            finish(clause, .incomplete, reason, at: t)
        } else if r.state == .ttsRequested, !r.needsResend {
            r.needsResend = true
            rows[clause] = r
        }
    }

    /// The engine gave up on the clause: its last attempt was still runaway or echo before
    /// release, so the tail came with no samples (§3.3: silent, HUD "这段未发送", review H).
    /// Terminal `dropped`: the engine already tried its next seeds, so it is never resent (a
    /// resend would restart from the same seed).
    public mutating func renderFailed(_ clause: UInt64, job: JobID, reason: Reason, at t: HostTime) {
        guard let r = rows[clause], r.job == job, !r.state.isTerminal else { return }
        finish(clause, r.state == .firstSampleEnqueued ? .incomplete : .dropped, reason, at: t)
    }

    /// The play head passed the clause's end.
    public mutating func played(_ clause: UInt64, at t: HostTime) {
        guard let r = rows[clause], r.state == .firstSampleEnqueued else { return }
        finish(clause, .played, nil, at: t)
    }

    /// Cut while playing (passthrough 1.5 s cut, stall, runaway after start, audio restart).
    public mutating func cut(_ clause: UInt64, reason: Reason, at t: HostTime) {
        guard let r = rows[clause], !r.state.isTerminal else { return }
        finish(clause, r.state == .firstSampleEnqueued ? .incomplete : .dropped, reason, at: t)
    }

    /// TargetTextGate / NumberGuard refused every MT result (§5.7).
    public mutating func gate(_ clause: UInt64, at t: HostTime) {
        guard let r = rows[clause], let rank = r.state.rank, rank < State.ttsRequested.rank! else { return }
        finish(clause, .gated, .gate, at: t)
    }

    /// Removes a clause that has not played anything (backlog drop, voiceless press).
    public mutating func drop(_ clause: UInt64, reason: Reason, at t: HostTime) {
        guard let r = rows[clause], !r.state.isTerminal else { return }
        if r.state == .firstSampleEnqueued { cut(clause, reason: reason, at: t); return }
        finish(clause, .dropped, reason, at: t)
    }

    /// Hard interrupt (double-tap right ⌥): every open clause is cancelled. Returns them.
    @discardableResult
    public mutating func cancelAll(at t: HostTime) -> [UInt64] {
        let open = rows.values.filter { !$0.state.isTerminal }.map(\.clause).sorted()
        for c in open { finish(c, .cancelled, .hardInterrupt, at: t) }
        return open
    }

    // MARK: engine lifecycle

    /// The clone engine crashed or hung. Open streams break: a clause with samples enqueued and
    /// not fully rendered becomes `incomplete`; one without samples waits for a resend.
    public mutating func engineLost(at t: HostTime) {
        if engineDownSince == nil { engineDownSince = t }
        for c in rows.keys.sorted() {
            guard var r = rows[c], !r.rendered else { continue }
            switch r.state {
            case .firstSampleEnqueued:
                finish(c, .incomplete, .engineLost, at: t)
            case .ttsRequested:
                r.needsResend = true
                if r.waitingSince == nil { r.waitingSince = t }
                rows[c] = r
            default: break
            }
        }
    }

    /// The engine is READY and the voice loaded again. Expires stale waits, then returns the
    /// clauses to resend now with their same clauseID, oldest first; call `requestTTS` for each.
    public mutating func engineReady(at t: HostTime) -> [UInt64] {
        expire(at: t)
        engineDownSince = nil
        for c in rows.keys where rows[c]!.waitingSince != nil { rows[c]!.waitingSince = nil }
        return rows.values.filter { $0.needsResend && !$0.state.isTerminal }.map(\.clause).sorted()
    }

    /// Periodic (every 100 ms is plenty). Returns clauses dropped because their press ran out of
    /// time waiting for the clone engine (the caller removes them from TTSQueue).
    @discardableResult
    public mutating func tick(at t: HostTime) -> [UInt64] { expire(at: t) }

    @discardableResult
    private mutating func expire(at t: HostTime) -> [UInt64] {
        var dead = Set<UInt64>()
        for r in rows.values where !r.state.isTerminal {
            if let since = r.waitingSince, t >= since, t - since > retryNs { dead.insert(r.press) }
        }
        var dropped: [UInt64] = []
        for p in dead.sorted() {
            pressVoice[p] = .voiceless
            // Clauses already playing keep their rendered audio; clauses still in ASR/MT keep going
            // for the HUD and are refused when they reach TTS.
            for c in rows.keys.sorted() {
                guard let r = rows[c], r.press == p, r.state == .mtDone || r.state == .ttsRequested else { continue }
                finish(c, .dropped, .voiceUnavailable, at: t)
                dropped.append(c)
            }
        }
        return dropped
    }

    private mutating func finish(_ clause: UInt64, _ s: State, _ reason: Reason?, at t: HostTime) {
        guard var r = rows[clause] else { return }
        r.state = s; r.reason = reason; r.needsResend = false; r.waitingSince = nil; r.changedAt = t
        rows[clause] = r
        emit(clause, at: t)
    }

    private func emit(_ clause: UInt64, at t: HostTime) {
        guard let r = rows[clause] else { return }
        sink?.clauseState(clause: r.clause, press: r.press, state: r.state, reason: r.reason, attempts: r.attempts, at: t)
    }
}

/// Receives `clause.state` changes (§12.2). EventLog conforms; tests record them.
public protocol ClauseStateSink: Sendable {
    func clauseState(clause: UInt64, press: UInt64, state: ClauseLedger.State, reason: ClauseLedger.Reason?,
                     attempts: Int, at: HostTime)
}

extension EventLog: ClauseStateSink {
    public func clauseState(clause: UInt64, press: UInt64, state: ClauseLedger.State, reason: ClauseLedger.Reason?,
                            attempts: Int, at t: HostTime) {
        var f: [String: Value] = ["clause": .int(Int(truncatingIfNeeded: clause)),
                                  "press": .int(Int(truncatingIfNeeded: press)),
                                  "state": .tag(state.rawValue), "attempts": .int(attempts)]
        if let reason { f["reason"] = .tag(reason.rawValue) }
        event("clause.state", f, at: t)
    }
}
