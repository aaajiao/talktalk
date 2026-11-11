import Foundation
import Synchronization
import TalkTalkCore

/// SPEAK stall rule (ARCHITECTURE.md):
/// - the engine renders TTS jobs one at a time, in its own job order (`Job.seq`, numbered on HTTP
///   arrival and sent back in the head frame), so only the **oldest open stream** in that order
///   (the head of `TTSStallBoard`) can stall; a stream queued behind it starts its window when it
///   becomes the head. Streams whose head frame has not come yet sort after those that have, in
///   speak() order;
/// - the head stalls when nothing is drainable (`PlayoutBox.aheadMs`: audio actually moving to the
///   speaker, decayed by the time since it was reported) and it has had no new chunk for
///   `stallAfter` (1.0 s) since its window started (last chunk, last progress frame, becoming the
///   head, the end of an engine `in_long_step`, or the end of a legal hold). Progress frames
///   (kind 7) come while the engine guards hold audio back (0.64 s hold, whole clause, seed
///   retries), so a clause being retried is not cut although no audio reaches the app;
/// - legal holds (`PlayoutBox.holdsEngine`): while the last fresh PlayoutReport says `paused`
///   (floor pause, passthrough), or its bufferedMs is at the render horizon (`Config.horizonMs`,
///   the engine's `--horizon-ms`) while something is actually draining, the engine is parked on
///   purpose: the head's window restarts every tick instead of being judged. At the horizon with
///   nothing draining is not a hold: the buffer may be a later clause the ClauseQueue cannot play
///   before the head (engine order ≠ queue order), and exempting it would wait forever;
/// - a stalled stream is cancelled locally and ends with `RemoteEngineError.stalled(chunksYielded:)`.
///   The SPEAK side handles every `.stalled` the same way: `ClauseQueue.streamFailed(job:)` first
///   (audio already in ringO plays out, the rest is discarded), then
///   `ClauseLedger.streamFailed(clause, reason: .stall)`, which decides by `firstSampleEnqueued` (a
///   sample written to ringO) whether it is `incomplete` or resent with the same clause id. Chunks yielded does not decide it (preroll,
///   whole-clause mode and holding keep yielded chunks out of ringO); the count is for logs only;
/// - a stall opens an engine-wide "unresolved stall" (`TTSStallBoard.markStalled` returns its
///   token): until it is resolved the streams behind it are not judged (the engine may be hung;
///   they are kept and resent, not cut one by one). At `hangAfter` (4 s) from the window start the
///   engine is asked once more, only if that same stall is still the unresolved one: no answer, or
///   a pending job (not parked at the horizon) with no GPU step, escalates to the §7.6 hang
///   handling (`EngineProcess.reportHang`: kill, crash restart; the queued streams then fail and
///   are resent by the caller); otherwise that stall is resolved and the next head gets a fresh
///   window. Any new chunk or progress frame on any stream also resolves it (progress frames come
///   only after real GPU frames, so the engine is evidently stepping; the stalled stream itself is
///   closed by then and gets none).
public enum TTSStall {
    public struct Config: Sendable, Equatable {
        public var stallAfter: Duration = .seconds(1)
        public var hangAfter: Duration = .seconds(4)
        public var tick: Duration = .milliseconds(100)
        public var healthTimeout: Double = 0.5
        /// A GPU step younger than this at the hang check means the engine is still working.
        public var hangStepAgeMs: Double = 3000
        /// The engine's render horizon (`--horizon-ms`, §3.3): a report with at least this much
        /// buffered means the engine is legally parked. `RemoteQwenTTS` sets it from
        /// `EngineConfig.horizonMs`, the value the engine was started with.
        public var horizonMs: Int = 1000
        /// A remembered `in_long_step` ends after this many health polls in a row fail, or once
        /// `hangAfter` has passed since the last poll that said so (it never sticks forever).
        public var longStepFailedPolls = 3
        public init() {}
    }

    /// The stall half of the rule, pure: no new chunk for `stallAfter`, nothing drainable, and the
    /// engine not inside a long step. `bufferedMs == nil` (no playout report yet) counts as 0.
    public static func isStalled(sinceLastChunk: Duration, bufferedMs: Int?, inLongStep: Bool, config: Config) -> Bool {
        sinceLastChunk >= config.stallAfter && (bufferedMs ?? 0) <= 0 && !inLongStep
    }

    /// The hang half, pure, evaluated once `hangAfter` has passed since the window start. `health`
    /// nil = the health call failed or timed out.
    public static func isHung(_ health: EngineHealth.GPU?, config: Config) -> Bool {
        guard let g = health else { return true }
        if g.inLongStep { return false }
        return g.activeJobs > 0 && (g.lastStepAgeMs ?? .infinity) >= config.hangStepAgeMs
    }

    /// One stream's stall window, pure (the clock is passed in). The window restarts on every chunk
    /// and while the engine reports `in_long_step`, so a long step postpones the verdict to
    /// `stallAfter` after the step ended, not merely to the next check.
    public struct Window: Sendable, Equatable {
        public private(set) var start: ContinuousClock.Instant
        /// The last health answer said `in_long_step`: ask again every tick until it ends.
        public private(set) var inLongStep = false
        /// When a health answer last said `in_long_step`, and failed polls since the last answer.
        public private(set) var longSeenAt: ContinuousClock.Instant?
        public private(set) var failedPolls = 0

        public init(start: ContinuousClock.Instant) { self.start = start }

        public mutating func chunk(at now: ContinuousClock.Instant) { start = max(start, now); inLongStep = false }
        /// Becoming the head, or a resolved stall: a fresh window.
        public mutating func restart(at now: ContinuousClock.Instant) { start = max(start, now) }

        /// Whether the watchdog must ask the engine for `in_long_step` now.
        public func needsHealth(at now: ContinuousClock.Instant, aheadMs: Int, config: Config) -> Bool {
            inLongStep || (now - start >= config.stallAfter && aheadMs <= 0)
        }

        /// Applies a health answer; true = stalled. `inLongStep` nil = the health call failed or timed
        /// out: the previous answer stands (a long step is not taken as ended because one poll failed),
        /// but only for `longStepFailedPolls` failures in a row and within `hangAfter` of the last
        /// poll that said `in_long_step`. Failed polls do not move the window: once the remembered
        /// long step lapses, the verdict counts from that last real observation.
        public mutating func observe(at now: ContinuousClock.Instant, inLongStep answer: Bool?, aheadMs: Int,
                                     config: Config) -> Bool {
            switch answer {
            case true?:
                inLongStep = true
                failedPolls = 0
                longSeenAt = now
                start = max(start, now)
                return false
            case false?:
                inLongStep = false
                failedPolls = 0
            case nil:
                failedPolls += 1
                if inLongStep {
                    let lapsed = failedPolls >= config.longStepFailedPolls
                        || longSeenAt.map { now - $0 >= config.hangAfter } ?? true
                    if !lapsed { return false }
                    inLongStep = false
                }
            }
            return TTSStall.isStalled(sinceLastChunk: now - start, bufferedMs: aheadMs, inLongStep: false, config: config)
        }
    }
}

/// The open SPEAK streams of one RemoteQwenTTS, in the engine's render order, with each one's stall
/// window and the engine-wide unresolved stall (`TTSStall`). Shared by every copy of the
/// RemoteQwenTTS value.
///
/// Order: the engine numbers jobs (`Job.seq`) as their HTTP requests arrive, and the requests of
/// concurrent speak() calls race over separate connections, so speak() order is not render order.
/// A stream is placed by the engine seq from its head frame (`sequenced`); streams without one yet
/// come after, in speak() order. When the head changes, the new head's window starts then.
public final class TTSStallBoard: Sendable {
    struct Entry {
        let id: UInt64
        var engineSeq: Int?
        var window: TTSStall.Window
        var chunks = 0
    }
    struct Unresolved {
        let token: UInt64
        let since: ContinuousClock.Instant
    }
    struct State {
        var entries: [Entry] = []
        var next: UInt64 = 0
        var nextToken: UInt64 = 0
        var unresolved: Unresolved?

        /// Sorts by engine seq (unknown last, then speak() order); a new head's window starts now.
        mutating func reorder(at now: ContinuousClock.Instant) {
            let before = entries.first?.id
            entries.sort { a, b in (a.engineSeq ?? .max, a.id) < (b.engineSeq ?? .max, b.id) }
            if let h = entries.first?.id, h != before { entries[0].window.restart(at: now) }
        }
    }
    private let state = Mutex(State())
    public init() {}

    /// Registers a stream at speak() time; returns its id.
    public func open(at now: ContinuousClock.Instant) -> UInt64 {
        state.withLock { s in
            s.next += 1
            s.entries.append(Entry(id: s.next, window: .init(start: now)))
            s.reorder(at: now)
            return s.next
        }
    }

    /// The head frame came: the engine's job seq places the stream in render order.
    public func sequenced(_ id: UInt64, engineSeq: Int, at now: ContinuousClock.Instant) {
        state.withLock { s in
            guard let i = s.entries.firstIndex(where: { $0.id == id }) else { return }
            s.entries[i].engineSeq = engineSeq
            s.reorder(at: now)
        }
    }

    /// The stream ended (any way). If it was the head, the next stream's window starts now.
    public func close(_ id: UInt64, at now: ContinuousClock.Instant) {
        state.withLock { s in
            guard let i = s.entries.firstIndex(where: { $0.id == id }) else { return }
            s.entries.remove(at: i)
            if i == 0, !s.entries.isEmpty { s.entries[0].window.restart(at: now) }
        }
    }

    /// A chunk arrived: the stream's window restarts and the engine is evidently not hung.
    public func chunk(_ id: UInt64, at now: ContinuousClock.Instant) {
        state.withLock { s in
            guard let i = s.entries.firstIndex(where: { $0.id == id }) else { return }
            s.entries[i].window.chunk(at: now)
            s.entries[i].chunks += 1
            s.unresolved = nil
        }
    }

    /// A progress frame (the engine holds this job's audio for the guards): like a chunk, the window
    /// restarts and the unresolved stall is resolved (§5.7); unlike one, nothing is counted.
    public func progress(_ id: UInt64, at now: ContinuousClock.Instant) {
        state.withLock { s in
            guard let i = s.entries.firstIndex(where: { $0.id == id }) else { return }
            s.entries[i].window.chunk(at: now)
            s.unresolved = nil
        }
    }

    /// A legal hold (paused, or parked at the render horizon): the stream's window restarts.
    public func hold(_ id: UInt64, at now: ContinuousClock.Instant) {
        state.withLock { s in
            guard let i = s.entries.firstIndex(where: { $0.id == id }) else { return }
            s.entries[i].window.restart(at: now)
        }
    }

    public func isHead(_ id: UInt64) -> Bool { state.withLock { $0.entries.first?.id == id } }
    public func chunks(_ id: UInt64) -> Int { state.withLock { s in s.entries.first { $0.id == id }?.chunks ?? 0 } }
    public func window(_ id: UInt64) -> TTSStall.Window? { state.withLock { s in s.entries.first { $0.id == id }?.window } }
    public var unresolvedSince: ContinuousClock.Instant? { state.withLock { $0.unresolved?.since } }
    public var openCount: Int { state.withLock { $0.entries.count } }
    /// Open stream ids, head first (tests).
    var order: [UInt64] { state.withLock { $0.entries.map(\.id) } }

    /// Writes back a window the watchdog advanced (`observe`).
    func update(_ id: UInt64, _ w: TTSStall.Window) {
        state.withLock { s in
            guard let i = s.entries.firstIndex(where: { $0.id == id }) else { return }
            s.entries[i].window = w
        }
    }

    /// The head stalled: from now on nothing else is judged until this stall is resolved. The token
    /// names this stall: its hang check and its `resolve` act only while it is still the unresolved
    /// one (a chunk may have resolved it and another stream stalled since).
    func markStalled(since t: ContinuousClock.Instant) -> UInt64 {
        state.withLock { s in
            s.nextToken += 1
            s.unresolved = Unresolved(token: s.nextToken, since: t)
            return s.nextToken
        }
    }

    /// Whether the stall with this token is still the unresolved one.
    func isUnresolved(_ token: UInt64) -> Bool { state.withLock { $0.unresolved?.token == token } }

    /// The hang check of stall `token` is done (not hung, or the hang handling ran): if it is still
    /// the unresolved one, it is cleared and the head starts afresh; otherwise nothing changes.
    func resolve(_ token: UInt64, at now: ContinuousClock.Instant) {
        state.withLock { s in
            guard s.unresolved?.token == token else { return }
            s.unresolved = nil
            if !s.entries.isEmpty { s.entries[0].window.restart(at: now) }
        }
    }
}

/// What the stall rule reads from the playout side, shared by every copy of the RemoteQwenTTS value:
/// the last PlayoutReport (sent to the engine) and, when the reporter provides it, the drainable
/// amount (`PlayoutReporter` `drainable`: audio actually moving to the speaker, without what the
/// ClauseQueue holds back for preroll or whole-clause mode). Both are stamped on arrival and decay
/// with elapsed time, so a stuck reporter reads as an empty buffer instead of a frozen one.
public final class PlayoutBox: Sendable {
    private struct State {
        var report: PlayoutReport?
        var reportAt: ContinuousClock.Instant?
        var drainable: Int?
        var drainableAt: ContinuousClock.Instant?
    }
    private let state = Mutex(State())
    public init() {}

    public var report: PlayoutReport? { state.withLock { $0.report } }

    func set(_ r: PlayoutReport, at now: ContinuousClock.Instant = .now) {
        state.withLock { $0.report = r; $0.reportAt = now }
    }

    func setDrainable(_ ms: Int, at now: ContinuousClock.Instant = .now) {
        state.withLock { $0.drainable = ms; $0.drainableAt = now }
    }

    /// Whether the engine is legally parked as of `now`: the last report is fresh (younger than
    /// `stallAfter`; the reporter sends one every 100 ms) and says `paused`, or its bufferedMs, decayed
    /// like `aheadMs`, is still at the render horizon **and** something is draining (`aheadMs > 0`).
    /// A full buffer that does not drain is not a hold: it can be a later clause the ClauseQueue holds
    /// behind the head (the engine rendered it first), and the head must still be judged.
    public func holdsEngine(at now: ContinuousClock.Instant, config: TTSStall.Config) -> Bool {
        let draining = aheadMs(at: now) > 0
        return state.withLock { s in
            guard let r = s.report, let t = s.reportAt, now - t < config.stallAfter else { return false }
            if r.paused { return true }
            let elapsed = Int(((now - t) / .milliseconds(1)).rounded(.down))
            return draining && r.bufferedMs - elapsed >= config.horizonMs
        }
    }

    /// Audio ahead of the play head as of `now`: the drainable amount if the reporter sends it,
    /// else the last report's bufferedMs; minus the time since it arrived. 0 when nothing came yet.
    public func aheadMs(at now: ContinuousClock.Instant) -> Int {
        state.withLock { s in
            let (v, t): (Int?, ContinuousClock.Instant?) = s.drainable != nil ? (s.drainable, s.drainableAt)
                                                                              : (s.report?.bufferedMs, s.reportAt)
            guard let v, let t else { return 0 }
            let elapsed = (now - t) / .milliseconds(1)
            return max(0, v - Int(elapsed.rounded(.down)))
        }
    }
}
