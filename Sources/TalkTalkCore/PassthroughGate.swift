// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation
import Synchronization

// MARK: - State published to the real-time side (§3.8 "feedIOProc 的切换")

/// Where passthrough samples come from, bound to the Feed channel they may reach (§3.8 privacy
/// invariants 1 and 7). The pairing cannot be split: `.mic` only ever reaches channel 1 (TalkTalk
/// Mic), `.selfTest` (synthetic pulses from `--self-test --passthrough`) only channel 2 (Test Mic).
/// Raw values are the C side's `source` field in `tt_pt_state.h` (rt-core).
public enum PassthroughSource: UInt8, Sendable, Hashable {
    case mic = 0
    case selfTest = 1

    /// The only place the source → Feed channel mapping exists (`scripts/check-audio-paths.sh`).
    public var feedChannel: Int {
        switch self {
        case .mic: 1
        case .selfTest: 2
        }
    }
}

/// A snapshot of the passthrough switch (`tt_snapshot` of rt-core's `tt_pt_state.h`): what the
/// worker's `admit` and feedIOProc compare against on every block / IO cycle. Times are host time
/// in **nanoseconds** (`CLOCK_UPTIME_RAW`, `HostClock`); the C side keeps mach ticks and its Swift
/// wrapper converts with `HostClock.machTicks(fromNanos:)` / `nanos(fromMachTicks:)`, the only
/// conversion; the gate never touches ticks. `generation` is assigned by the state on every open;
/// a source switch is a close, so the next open (of either source) has a new generation and ringP
/// blocks of any earlier one read as zero.
public struct PassthroughState: Sendable, Hashable {
    public var open: Bool
    public var generation: UInt32
    public var source: PassthroughSource
    /// When it really opened (the admit lower bound), ns.
    public var openAt: HostTime
    /// Lease end, ns; on close it becomes min(lease, close time).
    public var leaseUntil: HostTime
    /// open + `maxHoldS`, ns; the lease never passes it.
    public var deadline: HostTime

    public init(open: Bool, generation: UInt32, source: PassthroughSource, openAt: HostTime, leaseUntil: HostTime,
                deadline: HostTime) {
        self.open = open; self.generation = generation; self.source = source
        self.openAt = openAt; self.leaseUntil = leaseUntil; self.deadline = deadline
    }

    public static let closed = PassthroughState(open: false, generation: 0, source: .mic, openAt: 0, leaseUntil: 0, deadline: 0)

    /// `tt_pt_snapshot_live` plus the block check: open, `blockGeneration` current, `now` before
    /// the lease end and the deadline. Anything else reads as closed.
    public func admits(blockGeneration: UInt32, at now: HostTime) -> Bool {
        open && blockGeneration == generation && now < min(leaseUntil, deadline)
    }
}

/// The writer side of `tt_pt_state` (rt-core), one call per transition, all times in ns. The
/// gate is the only writer and calls it under its own lock, so calls never interleave. rt-core's
/// Swift wrapper implements it over the C state; `InMemoryPassthroughStateSink` until then and
/// in tests.
public protocol PassthroughStateSink: AnyObject, Sendable {
    /// `tt_pt_state_open`: open with a new generation and return it. `leaseUntil` is clamped to `deadline`.
    func open(source: PassthroughSource, openAt: HostTime, leaseUntil: HostTime, deadline: HostTime) -> UInt32
    /// `tt_pt_state_renew`: extend the lease of the open `generation` (clamped, never shortened).
    @discardableResult func renew(generation: UInt32, leaseUntil: HostTime) -> Bool
    /// `tt_pt_state_close`: close `generation` if current; the lease ends at min(lease, `at`).
    @discardableResult func close(generation: UInt32, at: HostTime) -> Bool
}

/// In-memory model of `tt_pt_state` with the same semantics (tests, and the app until rt-core's
/// wrapper is wired in).
public final class InMemoryPassthroughStateSink: PassthroughStateSink {
    private let storage = Mutex<(current: PassthroughState, history: [PassthroughState])>((.closed, []))
    public let keepsHistory: Bool

    public init(keepsHistory: Bool = false) { self.keepsHistory = keepsHistory }

    public func open(source: PassthroughSource, openAt: HostTime, leaseUntil: HostTime, deadline: HostTime) -> UInt32 {
        storage.withLock {
            let g = $0.current.generation &+ 1
            $0.current = PassthroughState(open: true, generation: g, source: source, openAt: openAt,
                                          leaseUntil: min(leaseUntil, deadline), deadline: deadline)
            if keepsHistory { $0.history.append($0.current) }
            return g
        }
    }

    public func renew(generation: UInt32, leaseUntil: HostTime) -> Bool {
        storage.withLock {
            guard $0.current.open, $0.current.generation == generation else { return false }
            $0.current.leaseUntil = max($0.current.leaseUntil, min(leaseUntil, $0.current.deadline))
            if keepsHistory { $0.history.append($0.current) }
            return true
        }
    }

    public func close(generation: UInt32, at t: HostTime) -> Bool {
        storage.withLock {
            guard $0.current.open, $0.current.generation == generation else { return false }
            $0.current.open = false
            $0.current.leaseUntil = min($0.current.leaseUntil, t)
            if keepsHistory { $0.history.append($0.current) }
            return true
        }
    }

    public var current: PassthroughState { storage.withLock { $0.current } }
    public var history: [PassthroughState] { storage.withLock { $0.history } }
}

// MARK: - Reasons and notices

/// System events that close the passthrough at once (§3.6: every row except "进程列表变化" and
/// "Feed 采样率被改"; §3.8 "关闭"). Wake follows sleep, which already closed it, and then waits
/// for MeetingMicGuard (`awaitingAudioConfirmation`).
public enum PassthroughSystemEvent: String, Sendable, Hashable, CaseIterable {
    case sleep, screenLocked, userSwitchedOut, coreaudiodRestarted, micFormatChanged, micUnplugged,
         feedGone, talkTalkMicGone, meetingModeEnded
    /// The system default input changed (any of §8.6's three kinds).
    case defaultInputChanged
    /// The default output, the meeting's output device, or either one's sample rate changed.
    case outputDeviceChanged
    /// The monitor (自听) device's sample rate or format changed.
    case monitorFormatChanged
}

/// Why a press ended (key machine) or the passthrough closed (gate).
public enum PassthroughCloseReason: Sendable, Hashable {
    // from the key
    case keyReleased
    case otherKey
    case modifierChanged
    case mouseButton
    case scroll
    case mouseMoved
    case maxHold
    case tapFailed(TapFailure)
    /// The poll found the key up: the key-up event was lost.
    case lostKeyUp
    /// The poll found another modifier, key or mouse button held.
    case otherInputHeld
    case secureInput
    // from the gate
    case leaseExpired
    case unavailable(PassthroughPolicy.DenyReason)
    /// VAD heard speech between the press and the open (open condition 5), reported late.
    case spokeBeforeOpen
    case sourceChanged
    case system(PassthroughSystemEvent)

    /// `pt.close{reason}` tag.
    public var tag: String {
        switch self {
        case .keyReleased: "key_up"
        case .otherKey: "other_key"
        case .modifierChanged: "modifier"
        case .mouseButton: "mouse_button"
        case .scroll: "scroll"
        case .mouseMoved: "mouse_move"
        case .maxHold: "max_hold"
        case let .tapFailed(f): "tap_\(f)"
        case .lostKeyUp: "lost_key_up"
        case .otherInputHeld: "other_held"
        case .secureInput: "secure_input"
        case .leaseExpired: "lease_expired"
        case let .unavailable(r): r.tag
        case .spokeBeforeOpen: "spoke_before_open"
        case .sourceChanged: "source_changed"
        case let .system(e): e.rawValue
        }
    }

    /// The reason line under "原声已关闭" (1 s); nil for a normal release.
    public var hudText: String? {
        switch self {
        case .keyReleased: nil
        case .otherKey, .modifierChanged, .mouseButton, .scroll, .mouseMoved, .otherInputHeld: String(appLocalized: "按了其他键")
        case .maxHold: String(appLocalized: "超过 30 s")
        case .system(.coreaudiodRestarted): String(appLocalized: "音频系统重启")
        case let .unavailable(r): r.hudText
        case .spokeBeforeOpen: String(appLocalized: "先等提示音再说")
        case .tapFailed, .lostKeyUp, .secureInput, .leaseExpired, .sourceChanged, .system: String(appLocalized: "原声直通已中断")
        }
    }
}

/// A press that armed but did not open (gray HUD line for 1.5 s, no cue, `pt.deny{reason}`).
public enum PassthroughRefusal: Sendable, Hashable {
    case unavailable(PassthroughPolicy.DenyReason)
    case spokeBeforeOpen
    case yieldTimeout
    case micNotReady

    public var hudText: String? {
        switch self {
        case let .unavailable(r): r.hudText
        case .spokeBeforeOpen: String(appLocalized: "先等提示音再说")
        case .yieldTimeout, .micNotReady: String(appLocalized: "原声直通暂不可用")
        }
    }

    public var tag: String {
        switch self {
        case let .unavailable(r): r.tag
        case .spokeBeforeOpen: "spoke_before_open"
        case .yieldTimeout: "yield_timeout"
        case .micNotReady: "mic_not_ready"
        }
    }
}

/// What the gate tells the HUD, the cue player, the mic and the log. Delivered outside the gate's
/// lock, in order per calling thread. Never carries audio or text.
public enum PassthroughNotice: Sendable, Hashable {
    /// Hot mic is off: start the stream, then call `micStreamStarted(at:)`.
    case startMic
    /// Preparation is waiting for the current TTS clause (HUD "原声 · 等这句说完").
    case waitingForClause
    /// Play the rising cue now (MonitorOutput only, never Feed); the gate opens after it.
    case playOpenCue
    case opened(at: HostTime, waitMs: Int, generation: UInt32)
    case countdown(secondsLeft: Int)
    case closed(at: HostTime, reason: PassthroughCloseReason, heldMs: Int)
    /// Play the falling cue (after the close, so outside the interval).
    case playCloseCue
    case refused(PassthroughRefusal)
    /// An armed press ended before opening (a shortcut after 400 ms, a release); nothing is shown.
    case cancelled(reason: PassthroughCloseReason)
}

/// ClauseQueue's side of "TTS 在播时" (§3.8): the speak-playout session implements it.
public protocol PassthroughPlayoutYielding: AnyObject, Sendable {
    /// Stop ringO at the next clause boundary; if that is not reached by `cutAt`, fade it out
    /// there and mark the clause incomplete. Call `PassthroughGate.playoutYielded(at:)` once ringO
    /// is silent, at once when nothing is playing. Pause ClauseQueue until `passthroughEnded`.
    func yieldForPassthrough(requestedAt: HostTime, cutAt: HostTime)
    /// The passthrough closed, or a preparation that asked for the floor was abandoned: resume
    /// under the 700 ms rule (`resumeAfterCloseMs`). Never clears the queue (C3).
    func passthroughEnded(at: HostTime)
}

// MARK: - Mic blocks in, passthrough frames out

/// A block of mono samples on its way from ringM to PassthroughStage. `hostTime` is the capture
/// time of `samples[0]` in ns (mHostTime through TimeMap, already converted by the worker).
public struct MicBlock: Sendable {
    public let origin: PassthroughSource
    public let hostTime: HostTime
    public let sampleRate: Double
    public let samples: [Float]

    public init(origin: PassthroughSource, hostTime: HostTime, sampleRate: Double, samples: [Float]) {
        self.origin = origin; self.hostTime = hostTime; self.sampleRate = sampleRate; self.samples = samples
    }

    /// Capture time of sample `i` (also valid for `i == samples.count`, the block's end).
    public func sampleTime(_ i: Int) -> HostTime {
        hostTime &+ HostTime((Double(i) * 1e9 / sampleRate).rounded(.down))
    }

    /// The smallest index whose capture time is ≥ `t` (`samples.count` when none is).
    public func firstIndex(atOrAfter t: HostTime) -> Int {
        let n = samples.count
        guard t > hostTime else { return 0 }
        var i = min(n, Int((Double(t - hostTime) * sampleRate / 1e9).rounded(.up)))
        while i > 0 && sampleTime(i - 1) >= t { i -= 1 }
        while i < n && sampleTime(i) < t { i += 1 }
        return i
    }
}

/// Microphone samples admitted to the passthrough. Only `PassthroughGate.admit` can make one
/// (the initializer is fileprivate, `scripts/check-audio-paths.sh` checks no other file spells
/// `PassthroughFrames(`): FeedOutput takes these and `TTSChunk`, nothing else takes these.
public struct PassthroughFrames: Sendable {
    public let samples: ArraySlice<Float>
    /// Capture time of `samples.first`.
    public let firstSampleHostTime: HostTime
    public let sampleRate: Double
    public let generation: UInt32
    public let source: PassthroughSource
    /// The admitted indices of the block they came from.
    public let blockRange: Range<Int>

    fileprivate init(block: MicBlock, range: Range<Int>, generation: UInt32) {
        samples = block.samples[range]
        firstSampleHostTime = block.sampleTime(range.lowerBound)
        sampleRate = block.sampleRate
        self.generation = generation
        source = block.origin
        blockRange = range
    }
}

// MARK: - The gate

/// Open/close state machine and the interval floor of the passthrough (ARCHITECTURE.md §3.8;
/// privacy invariants 1–7). Thread-safe: KeyTap's thread drives the hold, the control plane
/// updates facts and system events, the audio worker calls `admit`. Every call takes the current
/// host time; the gate never reads a clock, so tests run it on a virtual one.
///
/// Opening needs, in order: the key machine's clean 400 ms hold (`beginHold`), the policy,
/// no speech since the press, one poll period for late tap events to land (`keyPollMs`), the
/// TTS yield, the cold-mic pre-open VAD window, the open cue; then the next clean poll
/// (`confirmHold`, the key-state recheck) opens it at that poll's time. That time is
/// `openHostTime`; no earlier sample is ever admitted (no pre-roll).
///
/// While open each clean poll renews the lease to now + `leaseMs`, never past open + `maxHoldS`.
/// Every entry point first checks the lease, so a stalled key thread closes the passthrough at
/// the lease's end even if nothing else runs; feedIOProc checks the same lease on its own.
public final class PassthroughGate: Sendable {
    public struct Config: Sendable, Hashable {
        public var maxHoldS: Int
        public var leaseMs: Int
        public var keyPollMs: Int
        public var coldMicPreOpenVadMs: Int
        public var finishClauseMaxMs: Int
        public var clauseCutFadeMs: Int
        public var denyIfSpeechBeforeOpen: Bool
        public var cueBeforeOpen: Bool
        public var cueMs: Int
        public var allowInSpeakerMode: Bool
        /// Fail-safe for a cold mic that never reports started (not a profile value).
        public var micStartTimeoutMs: Int

        public init(maxHoldS: Int, leaseMs: Int, keyPollMs: Int, coldMicPreOpenVadMs: Int, finishClauseMaxMs: Int,
                    clauseCutFadeMs: Int, denyIfSpeechBeforeOpen: Bool, cueBeforeOpen: Bool, cueMs: Int,
                    allowInSpeakerMode: Bool, micStartTimeoutMs: Int = 1000) {
            self.maxHoldS = maxHoldS; self.leaseMs = leaseMs; self.keyPollMs = keyPollMs
            self.coldMicPreOpenVadMs = coldMicPreOpenVadMs; self.finishClauseMaxMs = finishClauseMaxMs
            self.clauseCutFadeMs = clauseCutFadeMs; self.denyIfSpeechBeforeOpen = denyIfSpeechBeforeOpen
            self.cueBeforeOpen = cueBeforeOpen; self.cueMs = cueMs; self.allowInSpeakerMode = allowInSpeakerMode
            self.micStartTimeoutMs = micStartTimeoutMs
        }

        public init(profile p: PolicyProfile.Speak.Passthrough) {
            self.init(maxHoldS: p.maxHoldS, leaseMs: p.leaseMs, keyPollMs: p.keyPollMs,
                      coldMicPreOpenVadMs: p.coldMicPreOpenVadMs, finishClauseMaxMs: p.finishClauseMaxMs,
                      clauseCutFadeMs: p.clauseCutFadeMs, denyIfSpeechBeforeOpen: p.denyIfSpeechBeforeOpen,
                      cueBeforeOpen: p.cues.enabled && p.cues.beforeOpen, cueMs: p.cues.ms,
                      allowInSpeakerMode: p.allowInSpeakerMode)
        }
    }

    public enum HoldResult: Sendable, Hashable {
        case preparing
        case opened(at: HostTime)
        case renewed
        /// Refused, cancelled or closed: the key machine must see a fresh press.
        case ended
    }

    private struct Prep: Sendable {
        var pressedAt: HostTime
        var armedAt: HostTime
        var automatic = false
        var yieldRequested = false
        var yieldDoneAt: HostTime?
        var micRequested = false
        var micStartedAt: HostTime?
        var cueUntil: HostTime?
        var waitingNoticeSent = false
    }

    private struct OpenInterval: Sendable {
        var pressedAt: HostTime
        var armedAt: HostTime
        var openedAt: HostTime
        var leaseUntil: HostTime
        var deadline: HostTime
        var yieldRequested: Bool
        var selfTest: Bool
        var automatic = false
    }

    private enum Phase: Sendable {
        case idle
        case preparing(Prep)
        case open(OpenInterval)
    }

    private struct Core: Sendable {
        var facts = PassthroughPolicy.Facts()
        var micWarm: Bool?
        var cueAudible: Bool?
        var source: PassthroughSource = .mic
        var generation: UInt32 = 0
        var phase: Phase = .idle
        var lastCloseAt: HostTime?
        var speechSince: HostTime?
        var lastSpeechEnd: HostTime?
    }

    private enum Effect {
        case notice(PassthroughNotice)
        case yield(requestedAt: HostTime, cutAt: HostTime)
        case playoutEnded(at: HostTime)
    }

    public let config: Config
    private let core = Mutex(Core())
    private let sink: any PassthroughStateSink
    private let playout: (any PassthroughPlayoutYielding)?
    private let onNotice: @Sendable (PassthroughNotice) -> Void

    public init(config: Config, sink: any PassthroughStateSink, playout: (any PassthroughPlayoutYielding)? = nil,
                onNotice: @escaping @Sendable (PassthroughNotice) -> Void = { _ in }) {
        self.config = config; self.sink = sink; self.playout = playout; self.onNotice = onNotice
    }

    // MARK: queries

    /// The gate's view of the switch (the sink holds the same; closed shows the last generation).
    public var state: PassthroughState {
        core.withLock { c in
            if case let .open(o) = c.phase {
                return PassthroughState(open: true, generation: c.generation, source: c.source, openAt: o.openedAt,
                                        leaseUntil: o.leaseUntil, deadline: o.deadline)
            }
            return PassthroughState(open: false, generation: c.generation, source: c.source, openAt: 0, leaseUntil: 0, deadline: 0)
        }
    }

    /// Preparing or open.
    public var isEngaged: Bool {
        core.withLock { c in if case .idle = c.phase { false } else { true } }
    }

    /// Open at `now` (lease included); also closes on an expired lease.
    public func isOpen(at now: HostTime) -> Bool {
        run { c, fx in
            self.lapse(&c, now: now, &fx)
            if case .open = c.phase { return true }
            return false
        }
    }

    /// The last close (privacy invariant 3: the PTT pre-roll floor never reaches back past it).
    public var lastCloseHostTime: HostTime? { core.withLock { $0.lastCloseAt } }

    public var facts: PassthroughPolicy.Facts { core.withLock { $0.facts } }

    // MARK: facts

    /// Update policy facts; anything that makes the passthrough unavailable closes it at `now`.
    /// An open self-test is exempt: its verdict is `.selfTestRunning` (or `.meetingModeOff`) for
    /// as long as it runs, and it ends by its own lease (§12.3: safe to run mid-meeting).
    public func updateFacts(at now: HostTime, _ change: (inout PassthroughPolicy.Facts) -> Void) {
        run { c, fx in
            change(&c.facts)
            self.lapse(&c, now: now, &fx)
            if case let .open(o) = c.phase, o.selfTest { return }
            if case let .unavailable(r) = self.verdict(c) { self.end(&c, at: now, reason: .unavailable(r), &fx) }
        }
    }

    /// Hot mic on (true) or off (false; preparation starts the stream and waits for it).
    public func setMicWarm(_ warm: Bool?) { core.withLock { $0.micWarm = warm } }

    public func micStreamStarted(at t: HostTime) {
        run { c, _ in
            if case var .preparing(p) = c.phase, p.micRequested, p.micStartedAt == nil {
                p.micStartedAt = t
                c.phase = .preparing(p)
            }
        }
    }

    /// Cues enabled in settings and the default output classified as headphones.
    public func setCueAudible(_ audible: Bool?) { core.withLock { $0.cueAudible = audible } }

    /// SPEAK VAD (§3.2): speech started at `onset` (reported at `now`). Speech any time between a
    /// press and its open refuses the open; an onset before the open that is reported after it
    /// closes the passthrough.
    public func vadSpeechStarted(onset: HostTime, now: HostTime) {
        run { c, fx in
            if c.speechSince == nil { c.speechSince = onset }
            self.lapse(&c, now: now, &fx)
            switch c.phase {
            case let .preparing(p) where !p.automatic && self.config.denyIfSpeechBeforeOpen && onset <= now && now >= p.pressedAt:
                self.refuse(&c, p, .spokeBeforeOpen, at: now, &fx)
            case let .open(o) where !o.automatic && self.config.denyIfSpeechBeforeOpen && !o.selfTest && onset < o.openedAt:
                self.end(&c, at: now, reason: .spokeBeforeOpen, &fx)
            default: break
            }
        }
    }

    public func vadSpeechEnded(at t: HostTime) {
        core.withLock { c in
            if c.speechSince != nil { c.lastSpeechEnd = max(c.lastSpeechEnd ?? 0, t) }
            c.speechSince = nil
        }
    }

    /// ClauseQueue: ringO is silent (boundary reached or the clause was cut).
    public func playoutYielded(at t: HostTime) {
        run { c, _ in
            if case var .preparing(p) = c.phase, p.yieldRequested, p.yieldDoneAt == nil {
                p.yieldDoneAt = t
                c.phase = .preparing(p)
            }
        }
    }

    // MARK: the hold (PassthroughController)

    /// The key machine's clean hold reached `armHoldMs`.
    public func beginHold(pressedAt: HostTime, armedAt: HostTime) -> HoldResult {
        run { c, fx in
            self.lapse(&c, now: armedAt, &fx)
            guard case .idle = c.phase else { return .ended }
            var p = Prep(pressedAt: pressedAt, armedAt: armedAt)
            if case let .unavailable(r) = self.verdict(c) {
                fx.append(.notice(.refused(.unavailable(r))))
                return .ended
            }
            if c.source != .mic {
                fx.append(.notice(.refused(.unavailable(.selfTestRunning))))
                return .ended
            }
            if self.config.denyIfSpeechBeforeOpen && self.spoke(c, from: pressedAt, to: armedAt) {
                fx.append(.notice(.refused(.spokeBeforeOpen)))
                return .ended
            }
            if self.playout != nil {
                p.yieldRequested = true
                fx.append(.yield(requestedAt: armedAt, cutAt: armedAt &+ self.ms(self.config.finishClauseMaxMs)))
            }
            if c.micWarm != true {
                p.micRequested = true
                fx.append(.notice(.startMic))
            }
            c.phase = .preparing(p)
            return .preparing
        }
    }

    /// A clean poll of the held key at `at`: opens when everything is ready, renews when open.
    public func confirmHold(at t: HostTime) -> HoldResult {
        run { c, fx in
            self.lapse(&c, now: t, &fx)
            switch c.phase {
            case .idle:
                return .ended
            case let .open(o):
                guard !o.selfTest else { return .ended }
                let cap = o.deadline
                guard t < cap else {
                    self.end(&c, at: t, reason: .maxHold, &fx)
                    return .ended
                }
                var n = o
                n.leaseUntil = min(t &+ self.ms(self.config.leaseMs), cap)
                c.phase = .open(n)
                self.sink.renew(generation: c.generation, leaseUntil: n.leaseUntil)
                return .renewed
            case var .preparing(p):
                if case let .unavailable(r) = self.verdict(c) {
                    self.refuse(&c, p, .unavailable(r), at: t, &fx)
                    return .ended
                }
                if self.config.denyIfSpeechBeforeOpen && self.spoke(c, from: p.pressedAt, to: t) {
                    self.refuse(&c, p, .spokeBeforeOpen, at: t, &fx)
                    return .ended
                }
                let yieldDeadline = p.armedAt &+ self.ms(self.config.finishClauseMaxMs + 2 * self.config.clauseCutFadeMs
                                                          + 2 * self.config.keyPollMs)
                if p.yieldRequested && p.yieldDoneAt == nil && t >= yieldDeadline {
                    self.refuse(&c, p, .yieldTimeout, at: t, &fx)
                    return .ended
                }
                if p.micRequested && p.micStartedAt == nil && t >= p.armedAt &+ self.ms(self.config.micStartTimeoutMs) {
                    self.refuse(&c, p, .micNotReady, at: t, &fx)
                    return .ended
                }
                let settled = t >= p.armedAt &+ self.ms(self.config.keyPollMs)
                let yielded = !p.yieldRequested || p.yieldDoneAt != nil
                let micReady = !p.micRequested
                    || (p.micStartedAt.map { t >= $0 &+ self.ms(self.config.coldMicPreOpenVadMs) } ?? false)
                guard settled, yielded, micReady else {
                    if !yielded && settled && !p.waitingNoticeSent {
                        p.waitingNoticeSent = true
                        fx.append(.notice(.waitingForClause))
                    }
                    c.phase = .preparing(p)
                    return .preparing
                }
                if self.config.cueBeforeOpen && c.cueAudible == true {
                    guard let until = p.cueUntil else {
                        p.cueUntil = t &+ self.ms(self.config.cueMs)
                        c.phase = .preparing(p)
                        fx.append(.notice(.playOpenCue))
                        return .preparing
                    }
                    guard t >= until else { return .preparing }
                }
                let deadline = t &+ self.ms(self.config.maxHoldS * 1000)
                let lease = min(t &+ self.ms(self.config.leaseMs), deadline)
                c.generation = self.sink.open(source: .mic, openAt: t, leaseUntil: lease, deadline: deadline)
                c.phase = .open(OpenInterval(pressedAt: p.pressedAt, armedAt: p.armedAt, openedAt: t, leaseUntil: lease,
                                             deadline: deadline, yieldRequested: p.yieldRequested, selfTest: false))
                fx.append(.notice(.opened(at: t, waitMs: HostClock.ms(p.armedAt, to: t), generation: c.generation)))
                return .opened(at: t)
            }
        }
    }

    /// Default meeting original audio uses the same source, generation and short lease as the
    /// manual gate. The runtime has already fenced physical PTT and all unfinished translation
    /// work. It never interrupts playout or asks for a key hold, cue, pre-open silence or max hold.
    public func confirmAutomatic(at t: HostTime) -> HoldResult {
        run { c, fx in
            self.lapse(&c, now: t, &fx)
            guard c.source == .mic else { return .ended }
            if case let .unavailable(reason) = self.verdict(c) {
                self.end(&c, at: t, reason: .unavailable(reason), &fx)
                return .ended
            }
            var prep: Prep
            switch c.phase {
            case .idle:
                prep = Prep(pressedAt: t, armedAt: t, automatic: true)
            case let .preparing(p):
                guard p.automatic else { return .ended }
                prep = p
            case var .open(open):
                guard open.automatic else { return .ended }
                open.leaseUntil = t &+ self.ms(self.config.leaseMs)
                c.phase = .open(open)
                self.sink.renew(generation: c.generation, leaseUntil: open.leaseUntil)
                return .renewed
            }
            if c.micWarm != true && prep.micStartedAt == nil {
                if prep.micRequested, t >= prep.armedAt &+ self.ms(self.config.micStartTimeoutMs) {
                    self.refuse(&c, prep, .micNotReady, at: t, &fx)
                    return .ended
                }
                if !prep.micRequested { prep.micRequested = true; fx.append(.notice(.startMic)) }
                c.phase = .preparing(prep)
                return .preparing
            }
            let lease = t &+ self.ms(self.config.leaseMs)
            c.generation = self.sink.open(source: .mic, openAt: t, leaseUntil: lease, deadline: .max)
            c.phase = .open(OpenInterval(pressedAt: prep.pressedAt, armedAt: prep.armedAt,
                openedAt: t, leaseUntil: lease, deadline: .max, yieldRequested: false, selfTest: false, automatic: true))
            fx.append(.notice(.opened(at: t, waitMs: HostClock.ms(prep.armedAt, to: t), generation: c.generation)))
            return .opened(at: t)
        }
    }

    /// The key machine ended the press (release, another input, tap failure, max hold).
    public func release(at t: HostTime, reason: PassthroughCloseReason) {
        run { c, fx in
            self.lapse(&c, now: t, &fx)
            self.end(&c, at: t, reason: reason, &fx)
        }
    }

    /// HUD countdown relayed from the key machine.
    public func countdown(secondsLeft: Int) { onNotice(.countdown(secondsLeft: secondsLeft)) }

    /// Sleep, lock, coreaudiod restart, device changes, meeting mode end: close at once.
    public func systemEvent(_ e: PassthroughSystemEvent, at t: HostTime) {
        run { c, fx in
            self.lapse(&c, now: t, &fx)
            self.end(&c, at: t, reason: .system(e), &fx)
        }
    }

    /// Lease bookkeeping without other input (the worker calls `admit` anyway; this is for idle paths).
    public func tick(now: HostTime) { run { c, fx in self.lapse(&c, now: now, &fx) } }

    // MARK: self-test (§3.8 "自检", §12.3)

    /// Switch the source. Any open or preparing passthrough closes first; the next open, of either
    /// source, gets a new generation from the state, so ringP blocks of the old source never play.
    public func setSource(_ s: PassthroughSource, at t: HostTime) {
        run { c, fx in
            guard s != c.source else { return }
            self.end(&c, at: t, reason: .sourceChanged, &fx)
            c.source = s
        }
    }

    /// `--self-test --passthrough`: open for synthetic pulses on channel 2 only. Refused unless the
    /// source is `.selfTest`; the key path never gets here, so it can never open channel 1.
    public func openSelfTest(at t: HostTime, durationMs: Int) -> Bool {
        run { c, fx in
            self.lapse(&c, now: t, &fx)
            guard c.source == .selfTest, case .idle = c.phase else { return false }
            let lease = t &+ self.ms(min(max(0, durationMs), self.config.maxHoldS * 1000))
            c.generation = self.sink.open(source: .selfTest, openAt: t, leaseUntil: lease, deadline: lease)
            c.phase = .open(OpenInterval(pressedAt: t, armedAt: t, openedAt: t, leaseUntil: lease, deadline: lease,
                                         yieldRequested: false, selfTest: true))
            fx.append(.notice(.opened(at: t, waitMs: 0, generation: c.generation)))
            return true
        }
    }

    // MARK: the audio worker

    /// The samples of `block` captured in `[openHostTime, close)`: nil when closed, when the block
    /// is of the other source, or when none of it falls inside. `now` is the worker's current host
    /// time; samples are never admitted at or past `now` or the lease.
    public func admit(_ block: MicBlock, now: HostTime) -> PassthroughFrames? {
        run { c, fx -> PassthroughFrames? in
            self.lapse(&c, now: now, &fx)
            guard case let .open(o) = c.phase, block.origin == c.source, block.sampleRate > 0 else { return nil }
            let lo = block.firstIndex(atOrAfter: o.openedAt)
            let hi = block.firstIndex(atOrAfter: min(o.leaseUntil, now))
            guard lo < hi else { return nil }
            return PassthroughFrames(block: block, range: lo..<hi, generation: c.generation)
        }
    }

    // MARK: internals

    private func run<R>(_ body: (inout Core, inout [Effect]) -> R) -> R {
        var fx: [Effect] = []
        let r = core.withLock { c in body(&c, &fx) }
        for e in fx {
            switch e {
            case let .notice(n): onNotice(n)
            case let .yield(at, cut): playout?.yieldForPassthrough(requestedAt: at, cutAt: cut)
            case let .playoutEnded(at): playout?.passthroughEnded(at: at)
            }
        }
        return r
    }

    private func verdict(_ c: Core) -> PassthroughPolicy.Verdict {
        PassthroughPolicy.evaluate(c.facts, allowInSpeakerMode: config.allowInSpeakerMode)
    }

    private func spoke(_ c: Core, from p: HostTime, to t: HostTime) -> Bool {
        if let s = c.speechSince, s <= t { return true }
        if let e = c.lastSpeechEnd, e >= p { return true }
        return false
    }

    /// An expired lease closes at the lease's end, whatever the caller was doing.
    private func lapse(_ c: inout Core, now: HostTime, _ fx: inout [Effect]) {
        guard case let .open(o) = c.phase, now >= o.leaseUntil else { return }
        closeOpen(&c, o, at: o.leaseUntil, reason: o.leaseUntil >= o.deadline && !o.selfTest ? .maxHold : .leaseExpired, &fx)
    }

    private func refuse(_ c: inout Core, _ p: Prep, _ r: PassthroughRefusal, at t: HostTime, _ fx: inout [Effect]) {
        c.phase = .idle
        fx.append(.notice(.refused(r)))
        if p.yieldRequested { fx.append(.playoutEnded(at: t)) }
    }

    private func end(_ c: inout Core, at t: HostTime, reason: PassthroughCloseReason, _ fx: inout [Effect]) {
        switch c.phase {
        case .idle:
            return
        case let .preparing(p):
            if case let .unavailable(r) = reason {
                refuse(&c, p, .unavailable(r), at: t, &fx)
            } else if case .spokeBeforeOpen = reason {
                refuse(&c, p, .spokeBeforeOpen, at: t, &fx)
            } else {
                c.phase = .idle
                fx.append(.notice(.cancelled(reason: reason)))
                if p.yieldRequested { fx.append(.playoutEnded(at: t)) }
            }
        case let .open(o):
            closeOpen(&c, o, at: t, reason: reason, &fx)
        }
    }

    private func closeOpen(_ c: inout Core, _ o: OpenInterval, at t: HostTime, reason: PassthroughCloseReason,
                           _ fx: inout [Effect]) {
        let closeAt = max(o.openedAt, min(t, o.leaseUntil))
        c.phase = .idle
        c.lastCloseAt = closeAt
        sink.close(generation: c.generation, at: closeAt)
        fx.append(.notice(.closed(at: closeAt, reason: reason, heldMs: HostClock.ms(o.pressedAt, to: closeAt))))
        if !o.selfTest && !o.automatic && config.cueBeforeOpen && c.cueAudible == true { fx.append(.notice(.playCloseCue)) }
        if o.yieldRequested { fx.append(.playoutEnded(at: closeAt)) }
    }

    private func ms(_ v: Int) -> HostTime { HostTime(max(0, v)) * 1_000_000 }
}

// MARK: - Key machine ↔ gate

/// Runs PassthroughKeyMachine against a PassthroughGate. PassthroughKey (TalkTalkSession) owns
/// one on KeyTap's thread and hands it every KeyTap event and every 20 ms poll; the fuzz tests
/// drive the same object. Not thread-safe: confine to one thread.
public final class PassthroughController {
    public private(set) var machine: PassthroughKeyMachine
    public let gate: PassthroughGate

    public init(machine: PassthroughKeyMachine, gate: PassthroughGate) {
        self.machine = machine; self.gate = gate
    }

    @discardableResult
    public func handle(_ e: KeyInputEvent) -> [PassthroughKeyMachine.Action] {
        sync()
        let actions = machine.handle(e)
        apply(actions)
        return actions
    }

    @discardableResult
    public func tick(now: HostTime) -> [PassthroughKeyMachine.Action] {
        sync()
        let actions = machine.tick(now: now)
        apply(actions)
        return actions
    }

    #if TALKTALK_DEV
    @discardableResult
    public func inject(_ e: KeyInputEvent, _ context: PassthroughKeyMachine.DevInjection) -> [PassthroughKeyMachine.Action] {
        sync()
        let actions = machine.inject(e, context)
        apply(actions)
        return actions
    }
    #endif

    /// The gate may have ended the press on another thread (facts, lease, system event).
    private func sync() {
        if machine.isEngaged && !gate.isEngaged { machine.gateEnded() }
    }

    private func apply(_ actions: [PassthroughKeyMachine.Action]) {
        for a in actions {
            switch a {
            case let .arm(pressedAt, armedAt):
                if gate.beginHold(pressedAt: pressedAt, armedAt: armedAt) == .ended { machine.gateEnded() }
            case let .held(t), let .renew(t):
                switch gate.confirmHold(at: t) {
                case let .opened(at): machine.gateOpened(at: at)
                case .ended: machine.gateEnded()
                case .preparing, .renewed: break
                }
            case let .close(t, reason):
                gate.release(at: t, reason: reason)
            case let .countdown(s):
                gate.countdown(secondsLeft: s)
            }
        }
    }
}
