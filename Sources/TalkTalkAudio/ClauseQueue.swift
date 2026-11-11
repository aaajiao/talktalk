import CAudioCore
import Foundation
import TalkTalkCore

/// Producer-side view of ringO / ringO2 (§3.3, §13 `tt_ring`). The C ring conforms through
/// `RingO`; tests use FakePlayoutRing, a Swift port of the same reader.
///
/// Contract: SPSC, 48 kHz mono f32, capacity ≈ 2 s. The producer (audio worker) writes and
/// places markers; the consumer (feedIOProc) reads. Counters are monotonic frame counts.
/// ringO / ringO2, producer side: the Playout section of CAudioCore's tt_ring (tt_ring.h), one
/// member per C call. One producer (the audio worker, under ClauseQueue's lock), one consumer
/// (feedIOProc for ringO, monitorIOProc for ringO2). The C wrapper maps 1:1; tests use
/// FakePlayoutRing, a Swift model of the same contract.
public protocol PlayoutRing: AnyObject {
    /// tt_ring_capacity (rounded up to a power of two).
    var capacityFrames: Int { get }
    /// tt_ring_available: frames not yet read (the 5 ms hold-back included).
    var availableFrames: Int { get }
    /// tt_ring_written_frames. `writtenFrames − availableFrames` = frames read or skipped.
    var writtenFrames: UInt64 { get }
    /// tt_ring_lead_room: what writeClause would store now (lead limit, 0.5 s for ringO).
    var leadRoom: Int { get }
    /// tt_ring_write_clause: stores min(frames, leadRoom) frames from `src` (nil = zeros) and
    /// returns that count; never overwrites unread data. `.start` puts a START mark with `tag`
    /// first, but only when something is stored or frames == 0; `.end` puts an END mark after
    /// the stored frames, only when all of them were stored.
    func writeClause(_ src: UnsafeBufferPointer<Float>?, frames: Int, marks: PlayoutMarks, tag: UInt32) -> Int
    /// tt_ring_set_pause: playback stops on the next START mark (5 ms fade before it), zeros
    /// while parked; an idle ring parks at once. false resumes there.
    func setPause(_ paused: Bool)
    /// tt_ring_is_parked.
    var isParked: Bool { get }
    /// tt_ring_request_jump: 30 ms fade (fixed, TT_RING_CUT_FADE_FRAMES), then the read index
    /// moves to the next START mark (`.nextStart`, else the write index of this call) or to the
    /// write index of this call (`.writeIndex`). Frames written later are kept. A ring that is
    /// not playing jumps without a fade. `.writeIndex` (flush) also drops every mark written
    /// before this call, a START at that write index included. A jump that drops the clause in
    /// progress (the read index moved, or the ring had run dry inside it) leaves the reader idle:
    /// the next clause starts like a first one; a parked ring stays parked. False (nothing done)
    /// while an earlier jump is pending.
    @discardableResult func requestJump(_ kind: PlayoutJump) -> Bool
    /// tt_ring_jump_pending: a jump the reader has not done yet.
    var jumpPending: Bool { get }
    /// tt_ring_playout_state: the reader's state as of its last read.
    var playoutState: PlayoutState { get }
    /// tt_ring_playout_underruns.
    var underruns: UInt64 { get }
    /// tt_ring_playout_reset: data, marks, pending requests and reader state (both sides stopped).
    func reset()
}

public struct PlayoutMarks: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let start = PlayoutMarks(rawValue: 1)     // TT_RING_CLAUSE_START
    public static let end = PlayoutMarks(rawValue: 2)       // TT_RING_CLAUSE_END
}

public enum PlayoutJump: Sendable { case nextStart, writeIndex }
/// TT_RING_STATE_*.
public enum PlayoutState: Sendable, Equatable { case idle, playing, underrun, parked }

/// feedIOProc's out.* events (tt_event_ring.h, source FEED), drained by the audio worker, which
/// converts host ticks with `HostClock.nanos(fromMachTicks:)` and passes them to `pump`. `at` is
/// the arrival at TalkTalk Mic (Feed output time + the driver's fixed lag).
public enum PlayoutRingEvent: Sendable, Equatable {
    case firstSample(tag: UInt32, at: HostTime)                      // TT_EV_OUT_FIRST_SAMPLE
    case underrun(at: HostTime)                                      // TT_EV_OUT_UNDERRUN
    case resumed(at: HostTime)                                       // TT_EV_OUT_RESUMED
    case clauseCut(tag: UInt32, skipped: Int, at: HostTime)          // TT_EV_OUT_CLAUSE_CUT
    case flushed(tag: UInt32, skipped: Int, at: HostTime)            // TT_EV_OUT_FLUSHED
    case parked(at: HostTime)                                        // TT_EV_OUT_PARKED
    case ended(at: HostTime)                                         // TT_EV_OUT_ENDED

    public var at: HostTime {
        switch self {
        case .firstSample(_, let at), .underrun(let at), .resumed(let at), .clauseCut(_, _, let at),
             .flushed(_, _, let at), .parked(let at), .ended(let at): return at
        }
    }
}

extension PlayoutRing {
    func write(_ a: ArraySlice<Float>, marks: PlayoutMarks = [], tag: UInt32 = 0) -> Int {
        a.withUnsafeBufferPointer { writeClause($0, frames: $0.count, marks: marks, tag: tag) }
    }
    func mark(_ m: PlayoutMarks, tag: UInt32 = 0) { _ = writeClause(nil, frames: 0, marks: m, tag: tag) }
}

/// Clause audio between the TTS stream and ringO (§3.3, §3.6, §3.8 "TTS 在播时", §5.5, §5.7).
///
/// - Each clause keeps its raw 24 kHz PCM with clauseID, job and epoch; chunks of a cancelled
///   job or an older epoch are dropped.
/// - Audio moves into ringO (through PlayoutStage) only while ringO is < `ringOAheadMs` (0.5 s)
///   ahead of the play head, so ringO never overflows and the tempo chosen for the next clause
///   still applies. /v1/playout bufferedMs = playable audio only (see `drainableMs`);
///   `bufferedAheadMs` (everything rendered, at its tempo) is for HedgePolicy.
/// - Adaptive preroll (160 / 320 ms, floors from the caller), 120 ms gap between clauses (dropped while Q > 3 s), optional per-app `leadInMs`.
/// - Passthrough yield: pause at the next boundary; not there within 1.5 s → 30 ms fade, skip to
///   the next boundary, the clause is `incomplete`; resume 700 ms after close or on a PTT press.
/// - coreaudiod restart: ringO emptied, the playing clause `incomplete`, only rendered audio
///   produced ≤ 1 s before the restart is kept (older clauses are re-rendered, never dropped).
///
/// All methods take the time explicitly (virtual clock in tests). Thread-safe (one lock); the
/// worker calls `pump` every few ms, the TTS consumer calls `ingest`. SpeakPipeline contract
/// (yield forwarding, RingO lifetime, restart): ARCHITECTURE.md, "实时音频与生命周期约束".
public final class ClauseQueue: @unchecked Sendable {
    public struct Config: Sendable, Equatable {
        public var ringOAheadMs: Int = 500
        /// Engine render horizon (§3.3): chunk intervals measured while the engine was held back by
        /// it are playback-paced, so they do not count towards the RTF estimate.
        public var renderHorizonMs: Int = 1000
        public var interClauseGapMs: Int = 120
        public var startAtFirstChunkIfRtfBelow: Double = 0.5
        public var fastPrerollMs: Int = 160
        public var elsePrerollMs: Int = 320
        public var degradedPrerollMs: Int = 640
        public var leadInMs: Int = 0
        public var leadInDbfs: Double = -60
        public var finishClauseMaxMs: Int = 1500
        public var clauseCutFadeMs: Int = 30
        public var resumeAfterCloseMs: Int = 700
        public var restartKeepMs: Int = 1000
        public var slowRatio: Double = 1.4
        public var slowTempo: Double = 1.25
        public var tempoMax: Double = 1.25
        public init() {}

        public init(_ p: PolicyProfile, leadInMs: Int = 0) {
            let t = p.speak.tts
            ringOAheadMs = t.ringOAheadMs; renderHorizonMs = t.renderHorizonMs; interClauseGapMs = t.interClauseGapMs
            startAtFirstChunkIfRtfBelow = t.startAtFirstChunkIfRtfBelow
            fastPrerollMs = Int((t.streamingIntervalS * 1000).rounded()); elsePrerollMs = t.elsePrerollMs; degradedPrerollMs = t.degradedPrerollMs
            self.leadInMs = leadInMs
            finishClauseMaxMs = p.speak.passthrough.finishClauseMaxMs
            clauseCutFadeMs = p.speak.passthrough.clauseCutFadeMs
            resumeAfterCloseMs = p.speak.passthrough.resumeAfterCloseMs
            slowRatio = t.slow.ratio; slowTempo = t.slow.tempo; tempoMax = p.speak.backlog.tempoMax
        }
    }

    /// What happened, for SpeakPipeline (→ ClauseLedger, engine, HUD, EchoFilter, EventLog).
    public enum Event: Sendable, Equatable {
        /// The clause started moving into ringO at this tempo (`tts.tempo` / HUD).
        case clauseStarted(clause: UInt64, tempo: Double, at: HostTime)
        /// → `ClauseLedger.firstSampleEnqueued(clause, job:, at:)` (per job: review 4).
        case firstSampleEnqueued(clause: UInt64, job: JobID, at: HostTime)
        /// Actual Feed read, distinct from the irreversible enqueue boundary above.
        case firstSamplePlayed(clause: UInt64, job: JobID, at: HostTime)
        case played(PlayedClause)
        /// Cut while playing (passthrough cut, audio restart): ledger `incomplete`.
        case cut(clause: UInt64, reason: ClauseLedger.Reason, at: HostTime)
        /// The clause's remaining audio was discarded: cancel this TTS job.
        case cancelJob(JobID)
        /// Rendered audio was discarded before any of it played (restart keep rule, and every
        /// clause after one that was: order): re-render the clause with the same clauseID, in
        /// event order (`ClauseLedger.resend`, then `requestTTS`).
        case rerender(clause: UInt64, job: JobID)
        /// The stream ended with no samples at all: the engine's last attempt was still runaway
        /// (`.runaway`) or echo (`.echo`) before release (review H). Nothing of it went to ringO
        /// (no gap, no firstSampleEnqueued); ledger `renderFailed`, silent, HUD "这段未发送".
        case renderFailed(clause: UInt64, job: JobID, reason: ClauseLedger.Reason)
        /// Passthrough may open: the play head is parked at a boundary.
        case yielded(at: HostTime)
        case resumed(at: HostTime)
        case underrun(at: HostTime)
        case staleChunk(job: JobID)
    }

    /// Text and interval actually played (EchoFilter, §3.5).
    public struct PlayedClause: Sendable, Equatable {
        public var clause: UInt64
        public var text: String
        public var start: HostTime
        public var end: HostTime
        public var incomplete: Bool
    }

    /// For HedgePolicy.extendToDrain (§4.1): audio still ahead of the play head.
    public struct DrainEstimate: Sendable, Equatable {
        /// ringO + rendered-not-moved audio, at each clause's tempo.
        public var renderedMs: Double
        /// Expected remaining audio of clauses still streaming (at the next tempo).
        public var unrenderedExpectedMs: Double
    }

    /// Preroll inputs the queue cannot see (§3.3 起播).
    public struct PrerollFloors: Sendable, Equatable {
        /// readread is running output, or P1/P2 jobs queued in the engine: ≥ 320 ms.
        public var gpuContended = false
        /// Low Power Mode or thermalState ≥ .serious: ≥ 320 ms.
        public var lowPowerOrHot = false
        /// Degradation step 2 (§6.4): 640 ms.
        public var degraded = false
        /// M0-T3: non-preemptible step p99 > 150 ms → 320 ms default.
        public var longSteps = false
        public init() {}
    }

    // MARK: state

    private struct Entry {
        var clause: UInt64
        var job: JobID
        var epoch: UInt32
        var text: String
        var expectedS: Double
        var predictedDurationS: Double
        var wholeClause: Bool
        var gainDb: Double?
        var excludeFromMetrics: Bool
        var raw: [Float] = []
        var producedAt: [HostTime] = []    // arrival of each chunk (restart keep rule)
        var consumed = 0
        var done = false
        var started = false                // stage begun, boundary queued
        var firstSampleSent = false        // a sample of it is in ringO
        var producedAll = false            // stage flushed, all ops queued
        var tempo: Double = 1
        var slow = false
        var outStart: UInt64?              // ring written index at its boundary
        var outEnd: UInt64?                // ring written index at its end mark (after the gap)
        /// Arrival of its first sample (out.first_sample).
        var playStart: HostTime?
        /// Read-position estimate, used only when no first_sample came before `.played` (the C
        /// reader publishes the read index before it pushes the event).
        var estStart: HostTime?
        var lastSeq = -1
        /// Its stream failed after a sample reached ringO: what arrived plays out, `.played` says
        /// incomplete (the ledger already has it `incomplete`).
        var failed = false
    }

    /// Output stream in order: samples and markers land in ringO exactly where they belong.
    private enum Op {
        case boundary(UInt64)
        case samples(UInt64, [Float])
        case end(UInt64)
        var clause: UInt64 {
            switch self { case .boundary(let c), .samples(let c, _), .end(let c): c }
        }
    }

    private enum Yield: Equatable {
        case none
        case waiting(since: HostTime)
        /// Cut requested: the 30 ms fade is still playing into TalkTalk Mic.
        case cutting
        case yielded
        case resumeAt(HostTime)
    }

    public let config: Config
    private let lock = NSLock()
    private let ring: any PlayoutRing
    private let monitor: (any PlayoutRing)?
    private let stage: PlayoutStage
    private var entries: [Entry] = []
    private var ops: [Op] = []
    private var opsFrames = 0
    private var epoch: UInt32 = 0
    private var monitorEnabled = false
    private var yieldState: Yield = .none
    private var floorPaused = false
    private var events: [Event] = []
    private var lastUnderruns: UInt64 = 0
    private var chunkIntervalsMs: [Double] = []    // last 20 inter-chunk intervals
    private var chunkRtf: [Double] = []            // last 20 chunk RTFs
    private var lastChunk: (job: JobID, at: HostTime, free: Bool)?
    /// From out.first_sample (tag) until the clause's cut / flush / end.
    private(set) var playingClause: UInt64?
    /// A flush refused because a jump was still fading: retried on the next pump (≤ 30 ms later).
    private var pendingFlush = false
    private var pendingMonitorFlush = false
    /// A ringO2 flush is outstanding: refused and waiting for its retry, or accepted and not yet
    /// done by monitorIOProc (it stays pending while MonitorOutput is detached; the next
    /// attachment's first cycle suspends ringO2, which does it at once). Monitor writes meanwhile
    /// wait in `monitorBacklog`, in order, so the retry (it targets the write index at the retry)
    /// covers only what was written before, and nothing is dropped for being behind the old tail.
    private var monitorFlushing = false
    private var monitorBacklog: [MonitorOp] = []
    private var monitorBacklogFrames = 0
    /// ringO2 may hold audio of ours not flushed yet. True at init: ringO2 is app-scoped, so an
    /// earlier queue may have left some (its teardown flush refused, or no teardown).
    private var monitorDirty = true
    private var pendingCut: UInt64?
    private var lastJump: (kind: PlayoutJump, clause: UInt64?)?
    /// Tag of the last out.first_sample, kept even after the clause left `entries` (cut).
    private var playingTag: UInt32?
    /// Clause whose START is still to be written with its first samples (ringO / ringO2).
    private var pendingStart: UInt64?
    private var monitorPendingStart: UInt64?
    private var staleDropped = 0
    /// feedIOProc's rebuffer threshold after an underrun (`tt_feed_resume_frames`).
    private var feedResumeFrames = 3840
    /// The last thing written to ringO was an END mark (the reader then plays the hold-back out).
    private var endAtWrite = false

    /// Tempo for the next clause that starts (BacklogController, §5.5). Clamped to [1, tempoMax].
    public var nextTempo: Double {
        get { lock.withLock { _nextTempo } }
        set { lock.withLock { _nextTempo = min(max(newValue, 1), config.tempoMax) } }
    }
    private var _nextTempo: Double = 1
    /// Q > 3 s: no gap between clauses.
    public var dropGaps: Bool {
        get { lock.withLock { _dropGaps } }
        set { lock.withLock { _dropGaps = newValue } }
    }
    private var _dropGaps = false
    public var prerollFloors: PrerollFloors {
        get { lock.withLock { _floors } }
        set { lock.withLock { _floors = newValue } }
    }
    private var _floors = PrerollFloors()

    public init(config: Config = Config(), ring: any PlayoutRing, monitor: (any PlayoutRing)? = nil, stage: PlayoutStage) {
        self.config = config
        self.ring = ring
        self.monitor = monitor
        self.stage = stage
        self.lastUnderruns = ring.underruns
    }

    static let outRate = 48_000.0
    static let inRate = 24_000.0
    private func outFrames(ms: Int) -> Int { Int(Double(ms) * Self.outRate / 1000) }
    private func ns(ms: Int) -> HostTime { HostTime(ms) * 1_000_000 }

    // MARK: producer side

    /// Registers the clause about to be synthesized. Ignored for an epoch other than the current.
    public func open(clause: UInt64, job: JobID, epoch e: UInt32, text: String, lang: Lang, wholeClause: Bool,
                     gainDb: Double? = nil, excludeFromMetrics: Bool = false, predictedDurationS: Double? = nil) {
        lock.withLock {
            guard e == epoch, !entries.contains(where: { $0.job == job || $0.clause == clause }) else { return }
            entries.append(Entry(clause: clause, job: job, epoch: e, text: text,
                                 expectedS: ExpectedDuration.seconds(text, lang),
                                 predictedDurationS: predictedDurationS ?? ExpectedDuration.seconds(text, lang), wholeClause: wholeClause, gainDb: gainDb, excludeFromMetrics: excludeFromMetrics))
        }
    }

    /// One TTS chunk. Returns false (and counts it) when stale: unknown or cancelled job, older
    /// epoch, after isLast, or a repeated seq.
    @discardableResult
    public func ingest(_ c: TTSChunk, at now: HostTime) -> Bool {
        lock.withLock {
            guard let i = entries.firstIndex(where: { $0.job == c.job }), entries[i].epoch == epoch,
                  !entries[i].done, c.seq > entries[i].lastSeq else {
                staleDropped += 1
                events.append(.staleChunk(job: c.job))
                return false
            }
            entries[i].lastSeq = c.seq
            entries[i].raw += c.samples24k
            entries[i].producedAt.append(now)
            if let last = lastChunk, last.job == c.job, last.free, !c.samples24k.isEmpty, now > last.at {
                let dt = Double(now - last.at) / 1e6
                Self.push(&chunkIntervalsMs, dt)
                Self.push(&chunkRtf, dt / (Double(c.samples24k.count) / Self.inRate * 1000))
            }
            // The engine produces the next chunk at once only while bufferedAhead < horizon.
            lastChunk = (c.job, now, playableLocked < Double(config.renderHorizonMs))
            if c.isLast, entries[i].raw.isEmpty, !entries[i].started {
                // A zero-audio tail (engine gave up, 78c5753): nothing to play, not even the gap.
                let e = entries[i]
                let reason: ClauseLedger.Reason = c.summary?.runaway == true ? .runaway
                    : (c.summary?.echoAborts ?? 0) > 0 ? .echo : .streamBroken
                remove(at: i)
                events.append(.renderFailed(clause: e.clause, job: e.job, reason: reason))
                return true
            }
            if c.isLast { entries[i].done = true }
            // Slow render (§5.5): generated ≥ ratio × expected while still streaming (or the
            // summary says slow) → the part not yet in ringO plays at slowTempo.
            let genS = Double(entries[i].raw.count) / Self.inRate
            if !entries[i].slow, c.summary?.slow == true || (!c.isLast && genS >= config.slowRatio * entries[i].expectedS) {
                entries[i].slow = true
            }
            return true
        }
    }

    // MARK: control

    /// Self-listen (ringO2) on/off. Turning it on re-applies the current pause to ringO2.
    /// Turning it off flushes ringO2 (`.writeIndex`): its reader state lives in the ring, so up to
    /// `ringOAheadMs` left unread would otherwise play first at the next audible attachment. The
    /// first turn-on of a queue flushes too (whatever an earlier queue on this ringO2 left).
    public func setMonitorEnabled(_ on: Bool) {
        lock.withLock {
            let was = monitorEnabled
            monitorEnabled = on
            if !on { monitorBacklog.removeAll(); monitorBacklogFrames = 0 }
            if on { monitor?.setPause(holding) }
            if on != was, monitorDirty { flushMonitor() }
        }
    }

    /// Meeting end / teardown: self-listen off and ringO2 flushed, because ringO2 is app-scoped and
    /// outlives this queue. A flush refused here (an earlier jump still pending) is not retried by
    /// this queue; the next queue flushes again at its first `setMonitorEnabled(true)`.
    public func teardown() {
        lock.withLock {
            monitorEnabled = false
            monitorBacklog.removeAll(); monitorBacklogFrames = 0
            if monitorDirty { flushMonitor() }
        }
    }

    /// Passthrough wants the floor (§3.8): pause at the next boundary; cut 1.5 s after `now`.
    /// Pass the gate's `requestedAt` so the cut lands on its `cutAt`; forward only the `.yielded`
    /// event this sends to `PassthroughGate.playoutYielded(at:)`.
    public func requestYield(at now: HostTime) {
        lock.withLock {
            switch yieldState {
            case .waiting, .cutting, .yielded: return
            case .resumeAt:
                // Reopened before the resume: still paused, so the next pump finds ringO parked
                // and sends .yielded again (the gate waits for it).
                yieldState = .waiting(since: now)
                applyPause()
            case .none:
                yieldState = .waiting(since: now)
                applyPause()
            }
        }
    }

    /// FloorManager pause (§5.6): stop at the next boundary, no cut.
    public func setFloorPaused(_ on: Bool) {
        lock.withLock {
            floorPaused = on
            applyPause()
        }
    }

    /// Passthrough closed: resume `resumeAfterCloseMs` (700 ms) later.
    public func passthroughClosed(at now: HostTime) {
        lock.withLock {
            guard yieldState != .none else { return }
            yieldState = .resumeAt(now + ns(ms: config.resumeAfterCloseMs))
        }
    }

    /// A new right-⌥ press (both keys released before): resume now.
    public func resumeNow(at now: HostTime) {
        lock.withLock {
            guard yieldState != .none else { return }
            endYield(at: now)
        }
    }

    private func endYield(at now: HostTime) {
        yieldState = .none
        applyPause()
        events.append(.resumed(at: now))
    }

    private var holding: Bool { floorPaused || yieldState != .none }

    /// Every pause goes to ringO and ringO2 alike (tt_ioproc_monitor.h: the monitor mirrors the
    /// pause and the 1.5 s cut).
    private func applyPause() {
        ring.setPause(holding)
        monitor?.setPause(holding)
    }

    /// Hard interrupt (double-tap, §5.6): 30 ms fade, ringO emptied, every clause dropped, the
    /// epoch moves on so late chunks are stale. Returns the dropped clause IDs.
    @discardableResult
    public func hardInterrupt(newEpoch: UInt32, at now: HostTime) -> [UInt64] {
        lock.withLock {
            requestJump(.writeIndex)
            let ids = entries.map(\.clause)
            for e in entries where !e.done { events.append(.cancelJob(e.job)) }
            entries.removeAll()
            ops.removeAll(); opsFrames = 0
            pendingStart = nil; monitorPendingStart = nil; endAtWrite = false
            stage.abandon()
            epoch = newEpoch
            return ids
        }
    }

    public enum StreamFailure: Sendable, Equatable {
        /// No entry for the job (stale, already finished or removed).
        case unknown
        /// A sample is in ringO: what arrived plays out and ends there; `.played` is incomplete.
        case playsOut(clause: UInt64)
        /// Nothing in ringO: its audio is discarded, and so is every later clause's (review 3:
        /// a resend appended behind them would play out of order). Resend them all with their
        /// clauseIDs, in this order (oldest first); the later ones' unfinished jobs come as
        /// `.cancelJob` events, and their ledger rows go back with `ClauseLedger.resend`.
        case discarded(clauses: [UInt64])
    }

    /// The TTS stream of `job` ended without isLast: `RemoteEngineError.stalled` (any
    /// chunksYielded), an error frame, a broken stream (review G). Call it before
    /// `ClauseLedger.streamFailed(clause, job:, reason:)` and, on `.playsOut`, report
    /// `firstSampleEnqueued` to the ledger first (it is idempotent) so both sides agree even when
    /// the pump's event has not reached the ledger yet. On `.discarded` the later clauses go back
    /// with `ClauseLedger.resend` and everything is resent oldest first.
    @discardableResult
    public func streamFailed(job: JobID, at now: HostTime) -> StreamFailure {
        lock.withLock {
            guard let i = entries.firstIndex(where: { $0.job == job }), !entries[i].done else { return .unknown }
            let c = entries[i].clause
            if entries[i].firstSampleSent {
                entries[i].done = true
                entries[i].failed = true
                return .playsOut(clause: c)
            }
            var gone = [c]
            for e in entries[(i + 1)...] {
                gone.append(e.clause)
                if !e.done { events.append(.cancelJob(e.job)) }
            }
            while entries.count > i { remove(at: entries.count - 1) }
            return .discarded(clauses: gone)
        }
    }

    /// feedIOProc's current rebuffer threshold (`tt_feed_resume_frames(feed)`): the worker sets it
    /// on every pump. Audio the feed holds back below it after an underrun is not playable.
    public func setFeedResumeFrames(_ frames: Int) {
        lock.withLock { feedResumeFrames = max(1, frames) }
    }

    /// coreaudiod restarted (§3.6). ringO is emptied. A clause with audio already in ringO is cut
    /// (`incomplete`: ClauseLedger never voices it again). A clause with nothing in ringO keeps
    /// its rendered audio only if all of it was produced ≤ `restartKeepMs` (1 s) before now;
    /// otherwise the audio is discarded and the clause re-rendered (C3: never dropped).
    public func audioServiceRestarted(at now: HostTime) {
        lock.withLock {
            ring.reset()
            monitor?.reset()
            pendingFlush = false; pendingMonitorFlush = false; pendingCut = nil; lastJump = nil; playingTag = nil
            monitorFlushing = false; monitorBacklog.removeAll(); monitorBacklogFrames = 0; monitorDirty = false
            playingClause = nil
            applyPause()                                     // reset drops the pause request too
            ops.removeAll(); opsFrames = 0
            pendingStart = nil; monitorPendingStart = nil; endAtWrite = false
            stage.abandon()
            let keepFrom = now >= ns(ms: config.restartKeepMs) ? now - ns(ms: config.restartKeepMs) : 0
            var kept: [Entry] = []
            var rerenderRest = false        // once one is re-rendered, so are all after it (order)
            for var e in entries {
                if e.firstSampleSent {
                    events.append(.cut(clause: e.clause, reason: .audioRestart, at: now))
                    if !e.done { events.append(.cancelJob(e.job)) }
                    continue
                }
                if rerenderRest || e.producedAll || (e.producedAt.first.map { $0 < keepFrom } ?? false) {
                    rerenderRest = true
                    if !e.done { events.append(.cancelJob(e.job)) }
                    events.append(.rerender(clause: e.clause, job: e.job))
                    continue
                }
                e.started = false; e.consumed = 0; e.outStart = nil; e.outEnd = nil; e.producedAll = false
                kept.append(e)
            }
            entries = kept
            lastUnderruns = ring.underruns
        }
    }

    // MARK: worker

    /// Moves audio into ringO, follows the play head, runs yield/resume. Returns the events since
    /// the previous call.
    public func pump(at now: HostTime, ringEvents: [PlayoutRingEvent] = []) throws -> [Event] {
        try lock.withLock {
            retryJump()
            // feedIOProc pushes one read's events in output order, each at its own frame (ends
            // before PARKED, RESUMED, FIRST_SAMPLE on the same frame; tt_event_ring.h). Sorting by
            // time again (stable for equal times) is a harmless guard.
            let ordered = ringEvents.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
            for (_, ev) in ordered { handle(ev) }
            trackUnderruns(now)
            runYield(now)
            try fill(now)
            trackPlayHead(now)
            defer { events.removeAll() }
            return events
        }
    }

    /// Underruns are counted by the consumer. The rebuffer threshold after one
    /// (max(80 ms, 2 × chunk-interval p95), doubling, 30 s decay, §3.3) is applied in feedIOProc
    /// (tt_ioproc_feed.h); the worker passes it `chunkIntervalP95Ms`. Not gating here too.
    private func trackUnderruns(_ now: HostTime) {
        let u = ring.underruns
        guard u > lastUnderruns else { return }
        lastUnderruns = u
        events.append(.underrun(at: now))
    }

    private func runYield(_ now: HostTime) {
        switch yieldState {
        case .none, .yielded: break
        case .waiting(let since):
            if ring.isParked {
                yieldState = .yielded
                events.append(.yielded(at: now))
            } else if now - since >= ns(ms: config.finishClauseMaxMs) {
                cutPlaying(now)
                yieldState = .cutting
                runYield(now)                                // a ring that was not playing jumps at once
            }
        case .cutting:
            // .yielded promises a silent ringO: wait until the reader has done the jump and parked
            // on the next START (pause is still requested), or is idle with nothing after the cut.
            // Otherwise the gate could open inside the 30 ms cut fade; since the feed suspends
            // ringO once passthrough is live, that leak is at most its 10 ms O→P handover fade.
            // An underrun with nothing left never parks (the reader waits for frames), but it is
            // silent too.
            if !ring.jumpPending, !pendingFlush, ring.isParked || ring.availableFrames == 0 {
                yieldState = .yielded
                events.append(.yielded(at: now))
            }
        case .resumeAt(let t):
            if now >= t { endYield(at: now) }
        }
    }

    /// No boundary within 1.5 s: 30 ms fade, skip to the next boundary, the clause is incomplete
    /// and whatever of it is not in ringO yet is dropped; later clauses stay.
    public func cutForFloor(at now: HostTime) {
        lock.withLock { floorPaused = true; applyPause(); cutPlaying(now, reason: .remoteFloor) }
    }

    public var isAtBoundary: Bool { lock.withLock { ring.isParked || (ring.availableFrames == 0 && playingNow == nil) } }
    public var currentPlayingText: String? { lock.withLock { playingNow.flatMap { id in entries.first { $0.clause == id }?.text } } }

    private func cutPlaying(_ now: HostTime, reason: ClauseLedger.Reason = .passthroughCut) {
        let playing = playingNow
        requestJump(.nextStart, clause: playing)
        guard let playing, let i = entries.firstIndex(where: { $0.clause == playing && $0.firstSampleSent }) else { return }
        let e = entries[i]
        events.append(.cut(clause: e.clause, reason: reason, at: now))
        events.append(.played(PlayedClause(clause: e.clause, text: e.text, start: e.playStart ?? e.estStart ?? now, end: now, incomplete: true)))
        if !e.done { events.append(.cancelJob(e.job)) }
        remove(at: i)
    }

    /// Drops an entry and whatever of it is not in ringO yet.
    private func remove(at i: Int) {
        let e = entries[i]
        if e.started, !e.producedAll { stage.abandon() }      // it is the clause in the stage
        if playingClause == e.clause { playingClause = nil }
        if pendingStart == e.clause { pendingStart = nil }
        if monitorPendingStart == e.clause { monitorPendingStart = nil }
        ops.removeAll { $0.clause == e.clause }
        opsFrames = ops.reduce(0) { if case .samples(_, let x) = $1 { $0 + x.count } else { $0 } }
        entries.remove(at: i)
    }

    private var prerollMs: Int {
        let fast = chunkRtf.count >= 2 && Self.mean(chunkRtf) <= config.startAtFirstChunkIfRtfBelow
        var p = fast ? config.fastPrerollMs : config.elsePrerollMs
        if _floors.gpuContended || _floors.lowPowerOrHot || _floors.longSteps { p = max(p, config.elsePrerollMs) }
        if _floors.degraded { p = max(p, config.degradedPrerollMs) }
        return p
    }

    private func fill(_ now: HostTime) throws {
        let ahead = outFrames(ms: config.ringOAheadMs)
        while true {
            drainOps(ahead: ahead, now: now)
            if ring.availableFrames >= ahead || !ops.isEmpty { return }
            guard try produce(now) else { return }
        }
    }

    /// Writes queued ops while ringO is less than `ahead` in front of the play head.
    private func drainOps(ahead: Int, now: HostTime) {
        guard !pendingFlush else { return }               // see requestJump
        while let op = ops.first {
            switch op {
            case .boundary(let c):
                // The START mark rides on the clause's first non-empty write (never a zero-frame
                // START at the write index, review C). The ring now drops such a START on a flush
                // too (rt-core review [6]); writing it with the first frames stays the rule.
                pendingStart = c
                monitorPendingStart = monitorEnabled ? c : nil
            case .end(let c):
                if pendingStart == c {
                    // Nothing of it was written: no START, no END.
                    pendingStart = nil
                    if let i = index(c) { entries[i].outStart = ring.writtenFrames }
                } else {
                    ring.mark(.end)
                    endAtWrite = true
                }
                if monitorPendingStart == c { monitorPendingStart = nil }
                else if monitorEnabled { monitorEnd() }
                if let i = index(c) { entries[i].outEnd = ring.writtenFrames }
            case .samples(let c, let x):
                let room = min(ahead - ring.availableFrames, ring.leadRoom)
                guard room > 0 else { return }
                let starts = pendingStart == c
                let stored = ring.write(x[0..<min(room, x.count)], marks: starts ? .start : [], tag: Self.tag(c))
                if stored > 0 { endAtWrite = false }
                if starts, stored > 0 {
                    pendingStart = nil
                    if let i = index(c) { entries[i].outStart = ring.writtenFrames - UInt64(stored) }
                }
                if monitorEnabled, stored > 0 {
                    let ms = monitorPendingStart == c
                    if monitorWrite(x[0..<stored], start: ms, tag: Self.tag(c)), ms { monitorPendingStart = nil }
                }
                if stored > 0, let i = index(c), !entries[i].firstSampleSent {
                    entries[i].firstSampleSent = true
                    events.append(.firstSampleEnqueued(clause: c, job: entries[i].job, at: now))
                }
                opsFrames -= stored
                if stored < x.count {
                    ops[0] = .samples(c, Array(x[stored...]))
                    return
                }
            }
            ops.removeFirst()
        }
    }

    /// Runs one step of the stage for the clause being written. False when nothing can move now.
    private func produce(_ now: HostTime) throws -> Bool {
        guard let i = entries.firstIndex(where: { !$0.producedAll }) else { return false }
        var e = entries[i]
        let unconsumedMs = Double(e.raw.count - e.consumed) / Self.inRate * 1000
        if !e.started {
            if holding { return false }                        // the next clause starts after the pause
            if e.wholeClause && !e.done { return false }
            if !e.done && unconsumedMs < Double(prerollMs) { return false }
            e.tempo = e.slow ? max(_nextTempo, config.slowTempo) : _nextTempo
            if let gain = e.gainDb { stage.setGainDb(gain) }
            try stage.begin(tempo: e.tempo)
            e.started = true
            events.append(.clauseStarted(clause: e.clause, tempo: e.tempo, at: now))
            ops.append(.boundary(e.clause))
            if config.leadInMs > 0 { push(e.clause, leadIn()) }
            entries[i] = e
            return true
        }
        if e.slow, e.tempo < config.slowTempo {
            push(e.clause, try stage.setTempo(config.slowTempo))
            e.tempo = config.slowTempo
        }
        let block = min(e.raw.count - e.consumed, 480)        // 20 ms of 24 kHz
        if block > 0 {
            push(e.clause, try stage.process(Array(e.raw[e.consumed..<(e.consumed + block)])))
            e.consumed += block
            entries[i] = e
            return true
        }
        guard e.done else { entries[i] = e; return false }    // starved: wait for the next chunk
        // isLast and all raw consumed: flush the stage, the inter-clause gap, then the end mark.
        push(e.clause, try stage.finish())
        if !_dropGaps, config.interClauseGapMs > 0 {
            push(e.clause, [Float](repeating: 0, count: outFrames(ms: config.interClauseGapMs)))
        }
        ops.append(.end(e.clause))
        e.producedAll = true
        e.raw = []; e.consumed = 0
        entries[i] = e
        return true
    }

    private func push(_ c: UInt64, _ x: [Float]) {
        guard !x.isEmpty else { return }
        ops.append(.samples(c, x))
        opsFrames += x.count
    }

    private func index(_ c: UInt64) -> Int? { entries.firstIndex { $0.clause == c } }

    private func leadIn() -> [Float] {
        // Low-level guide signal for meeting apps whose noise suppression eats the first syllable
        // (§3.3, default 0 ms): deterministic white noise at leadInDbfs.
        let n = outFrames(ms: config.leadInMs)
        let a = Float(pow(10, config.leadInDbfs / 20) * 3.0.squareRoot())
        var s: UInt32 = 0x1234_5678
        return (0..<n).map { _ in
            s = s &* 1_664_525 &+ 1_013_904_223
            return a * (Float(s >> 8) / Float(1 << 24) * 2 - 1)
        }
    }

    /// ringO marks carry 32-bit tags (tt_ring); clause IDs are per-session counters.
    static func tag(_ clause: UInt64) -> UInt32 { UInt32(truncatingIfNeeded: clause) }

    /// `.writeIndex` also flushes ringO2. ringO refuses a jump while an earlier one is pending
    /// (the reader has not done it yet: ≤ 30 ms + one IO period while feed reads ringO; during
    /// passthrough feedIOProc suspends ringO every cycle, which makes a jump at once, so ≤ one IO
    /// period; only while feedIOProc is not running at all does a jump stay pending; rt-core
    /// b3b74f9):
    /// - a refused flush is retried on every pump, and nothing is written to ringO until it is
    ///   accepted, because the retry targets the write index at the retry and would flush new
    ///   audio too;
    /// - a refused cut is dropped when the pending jump already covers it (a flush, or a cut of
    ///   the same clause); otherwise it is retried while that clause is still the one playing.
    private func requestJump(_ kind: PlayoutJump, clause: UInt64? = nil) {
        switch kind {
        case .writeIndex:
            flushMonitor()
            if ring.requestJump(.writeIndex) { lastJump = (.writeIndex, nil) } else { pendingFlush = true }
            pendingCut = nil
        case .nextStart:
            _ = monitor?.requestJump(.nextStart)            // self-listen only: a refused cut is dropped
            cutMonitorBacklog()
            if ring.requestJump(.nextStart) { lastJump = (.nextStart, clause); return }
            let covered = pendingFlush || lastJump?.kind == .writeIndex
                || (lastJump?.kind == .nextStart && lastJump?.clause == clause)
            if !covered, let clause { pendingCut = clause }
        }
    }

    // MARK: ringO2 (self-listen)

    private enum MonitorOp { case samples([Float], start: Bool, tag: UInt32), end }

    /// Flushes everything written to ringO2 so far, the backlog included. While the flush is
    /// outstanding (`monitorFlushing`) later writes wait in the backlog: a refused flush is
    /// retried with nothing new in ringO2, so its target is still this call's write index.
    private func flushMonitor() {
        guard let m = monitor else { return }
        monitorBacklog.removeAll(); monitorBacklogFrames = 0
        monitorFlushing = true; monitorDirty = false
        if !m.requestJump(.writeIndex) { pendingMonitorFlush = true }
    }

    /// Mirrors a cut on what ringO2 has not received yet: up to the next clause's START.
    private func cutMonitorBacklog() {
        guard let i = monitorBacklog.firstIndex(where: { if case .samples(_, true, _) = $0 { true } else { false } }) else {
            monitorBacklog.removeAll(); monitorBacklogFrames = 0
            return
        }
        for op in monitorBacklog[..<i] { if case .samples(let x, _, _) = op { monitorBacklogFrames -= x.count } }
        monitorBacklog.removeFirst(i)
    }

    /// One monitor write, mirroring `stored` frames of ringO. Best effort, as before: what ringO2's
    /// lead limit refuses is dropped. While a flush is outstanding it is queued instead (at most
    /// `ringOAheadMs`; past that it is dropped). True when the START (if any) went in or is queued.
    private func monitorWrite(_ x: ArraySlice<Float>, start: Bool, tag: UInt32) -> Bool {
        guard let m = monitor else { return false }
        if monitorFlushing {
            let n = min(x.count, max(0, outFrames(ms: config.ringOAheadMs) - monitorBacklogFrames))
            guard n > 0 else { return false }
            monitorBacklog.append(.samples(Array(x.prefix(n)), start: start, tag: tag))
            monitorBacklogFrames += n
            return true
        }
        let n = m.write(x, marks: start ? .start : [], tag: tag)
        if n > 0 { monitorDirty = true }
        return n > 0
    }

    private func monitorEnd() {
        if monitorFlushing { monitorBacklog.append(.end) } else { monitor?.mark(.end) }
    }

    /// The flush is done once it was accepted and monitorIOProc has jumped: the backlog goes in
    /// behind it (the reader is idle there, so the whole lead is free; anything refused is dropped).
    private func finishMonitorFlush() {
        guard monitorFlushing, !pendingMonitorFlush, let m = monitor, !m.jumpPending else { return }
        monitorFlushing = false
        let ops = monitorBacklog
        monitorBacklog.removeAll(); monitorBacklogFrames = 0
        for op in ops {
            switch op {
            case .end: m.mark(.end)
            case .samples(let x, let start, let tag):
                if m.write(x[...], marks: start ? .start : [], tag: tag) > 0 { monitorDirty = true }
            }
        }
    }

    private func retryJump() {
        if pendingMonitorFlush, let m = monitor, m.requestJump(.writeIndex) { pendingMonitorFlush = false }
        finishMonitorFlush()
        if pendingFlush {
            if ring.requestJump(.writeIndex) { pendingFlush = false; lastJump = (.writeIndex, nil) }
        } else if let c = pendingCut {
            if let t = playingTag, t != Self.tag(c) { pendingCut = nil }          // moved on
            else if ring.availableFrames == 0 { pendingCut = nil }               // nothing left to cut
            else if playingTag == Self.tag(c), ring.requestJump(.nextStart) {
                pendingCut = nil; lastJump = (.nextStart, c)
            }
        }
    }

    private func handle(_ ev: PlayoutRingEvent) {
        switch ev {
        case .firstSample(let tag, let at):
            playingTag = tag
            guard let i = entries.firstIndex(where: { Self.tag($0.clause) == tag && $0.outStart != nil }) else { return }
            playingClause = entries[i].clause
            if entries[i].playStart == nil {
                if entries[i].estStart == nil { events.append(.firstSamplePlayed(clause: entries[i].clause, job: entries[i].job, at: at)) }
                entries[i].playStart = at
            }
        case .clauseCut, .flushed, .ended:
            playingClause = nil
            playingTag = nil
        case .underrun, .resumed, .parked:
            break
        }
    }

    /// The clause the reader is in: from out.first_sample, else from the read position.
    private var playingNow: UInt64? {
        if let c = playingClause { return c }
        let read = ring.writtenFrames - UInt64(ring.availableFrames)
        return entries.first(where: { e in
            guard let s = e.outStart, e.firstSampleSent else { return false }
            return read > s && (e.outEnd.map { read < $0 } ?? true)
        })?.clause
    }

    private func trackPlayHead(_ now: HostTime) {
        let read = ring.writtenFrames - UInt64(ring.availableFrames)   // read or skipped
        var i = 0
        while i < entries.count {
            var e = entries[i]
            if e.playStart == nil, e.estStart == nil, let s = e.outStart, read > s {
                e.estStart = now - min(now, HostTime(Double(read - s) / Self.outRate * 1e9))
                events.append(.firstSamplePlayed(clause: e.clause, job: e.job, at: e.estStart!))
            }
            if let end = e.outEnd, read >= end {
                let endT = now - min(now, HostTime(Double(read - end) / Self.outRate * 1e9))
                events.append(.played(PlayedClause(clause: e.clause, text: e.text, start: e.playStart ?? e.estStart ?? endT, end: endT,
                                                   incomplete: e.failed)))
                if playingClause == e.clause { playingClause = nil }
                entries.remove(at: i)
                continue
            }
            entries[i] = e
            i += 1
        }
    }

    // MARK: reports

    /// bufferedAhead (§3.3): ringO fill + rendered audio not yet moved, at each clause's tempo.
    public var bufferedAheadMs: Double {
        lock.withLock { bufferedLocked }
    }

    private var bufferedLocked: Double {
        var ms = Double(ring.availableFrames + opsFrames) / Self.outRate * 1000
        for e in entries where !e.producedAll {
            let t = e.started ? e.tempo : _nextTempo
            ms += Double(e.raw.count - e.consumed) / Self.inRate * 1000 / t
        }
        return ms
    }

    /// The stall rule's input (§5.7, `PlayoutReporter` `drainable` → `tts.noteDrainable`): audio
    /// actually moving to the speaker. ringO + rendered output not yet written + raw audio of the
    /// clause being written, then of the clauses after it that could start right now, in order,
    /// stopping at the first one preroll or whole-clause mode holds back (and after a clause
    /// still streaming: the next one cannot start before it is done). Floor pause and passthrough
    /// yield are not subtracted: the engine side exempts a paused queue.
    public var drainableMs: Int { lock.withLock { Int(playableLocked.rounded()) } }

    /// Playable audio (review 2): what drainableMs reports, and the PlayoutReport's bufferedMs
    /// (the engine's render horizon must not count audio that cannot play: held for preroll or
    /// whole-clause mode, or held by the feed after an underrun below its rebuffer threshold —
    /// otherwise the engine stops rendering the very audio that would release it).
    private var playableLocked: Double {
        if feedHolds { return 0 }
        var ms = Double(ring.availableFrames + opsFrames) / Self.outRate * 1000
        for e in entries where !e.producedAll {
            let unconsumed = Double(e.raw.count - e.consumed) / Self.inRate * 1000
            if !e.started {
                if e.wholeClause && !e.done { break }
                if !e.done && unconsumed < Double(prerollMs) { break }
            }
            ms += unconsumed / (e.started ? e.tempo : _nextTempo)
            if !e.done { break }
        }
        return ms
    }

    /// The feed is in underrun and will not resume on what ringO holds (tt_ring_playout_read:
    /// more than the hold-back + the threshold capped at lead − hold-back, or the END has
    /// arrived). Fill has already put everything movable into ringO, so nothing drains.
    private var feedHolds: Bool {
        guard ring.playoutState == .underrun else { return false }
        let avail = ring.availableFrames, hold = Int(TT_RING_HOLD_FRAMES)   // tt_ring.h, not a copy
        let lead = avail + ring.leadRoom
        let resume = min(feedResumeFrames, lead > hold ? lead - hold : 1)
        if avail > 0 && endAtWrite { return false }
        return !(avail > hold && avail - hold >= resume)
    }

    public func drainEstimate(excludingAnnouncements: Bool = false) -> DrainEstimate {
        lock.withLock {
            var unrendered = 0.0
            for e in entries where !e.done && !(excludingAnnouncements && e.excludeFromMetrics) {
                let t = e.started ? e.tempo : _nextTempo
                let produced = Double(e.raw.count) / Self.inRate
                unrendered += max(0, e.predictedDurationS - produced) * 1000 / t
            }
            var excluded = 0.0
            if excludingAnnouncements {
                let read = ring.writtenFrames - UInt64(ring.availableFrames)
                for e in entries where e.excludeFromMetrics {
                    if let start = e.outStart {
                        let end = e.outEnd ?? ring.writtenFrames
                        excluded += Double(end > max(start, read) ? end - max(start, read) : 0) / Self.outRate * 1000
                    }
                    for op in ops where op.clause == e.clause {
                        if case .samples(_, let samples) = op { excluded += Double(samples.count) / Self.outRate * 1000 }
                    }
                    if !e.producedAll { excluded += Double(e.raw.count - e.consumed) / Self.inRate * 1000 / (e.started ? e.tempo : _nextTempo) }
                }
            }
            return DrainEstimate(renderedMs: max(0, bufferedLocked - excluded), unrenderedExpectedMs: unrendered)
        }
    }

    public func report(at now: HostTime) -> PlayoutReport {
        lock.withLock {
            let playing = entries.first(where: { $0.started })
            return PlayoutReport(job: playing?.job ?? entries.first?.job, bufferedMs: Int(playableLocked.rounded()),
                                 underruns: Int(truncatingIfNeeded: ring.underruns), paused: yieldState != .none || floorPaused,
                                 tempo: playing?.tempo ?? _nextTempo, epoch: epoch, at: now)
        }
    }

    public var currentEpoch: UInt32 { lock.withLock { epoch } }
    public var staleChunks: Int { lock.withLock { staleDropped } }
    public var clauseCount: Int { lock.withLock { entries.count } }
    public var lastChunkAt: HostTime? { lock.withLock { lastChunk?.at } }
    /// p95 of the recent TTS chunk arrival interval, for `tt_feed_set_chunk_interval_p95_frames`.
    public var chunkIntervalP95Ms: Double { lock.withLock { Self.p95(chunkIntervalsMs) } }
    public var currentPrerollMs: Int { lock.withLock { prerollMs } }
    /// Rendered (raw, not yet moved) audio still held, with its production times (restart rule).
    public var heldProducedAt: [HostTime] { lock.withLock { entries.filter { !$0.producedAll }.flatMap(\.producedAt) } }

    // MARK: helpers

    private static func push(_ a: inout [Double], _ v: Double) {
        a.append(v)
        if a.count > 20 { a.removeFirst(a.count - 20) }
    }
    private static func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
    private static func p95(_ a: [Double]) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * 0.95).rounded()))]
    }
}
