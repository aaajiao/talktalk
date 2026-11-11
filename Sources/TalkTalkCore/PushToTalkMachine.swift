/// The push-to-talk key, right ⌥ (ARCHITECTURE.md, "SPEAK：实体麦到会议输入"). Pure logic on the
/// event times it is given; PushToTalkKey (TalkTalkSession) feeds it the same KeyTap stream as
/// PassthroughKeyMachine plus a flags poll, and tells it about VAD and the first commit.
///
/// - A press starts only when clean: right ⌥ alone, no other modifier or key held (so never
///   while the passthrough key is held: rule 10), tap healthy.
/// - A chord (another keyDown or a modifier change) within `chordCancelWindowMs` of the press
///   and before the first commit cancels the whole press; any later chord counts as a release,
///   and what was committed still plays.
/// - A press shorter than `minHoldMs` with no VAD onset is a tap: no speech, nothing cancelled.
///   Two taps, each shorter than `doubleTap.maxPressMs`, with no VAD, the second pressed within
///   `doubleTap.maxGapMs` of the first's release, are a double tap (the hard interrupt, M3).
///   A press of `minHoldMs` or longer is never part of a double tap.
/// - `maxHoldS` forces a release (a lost key-up must not leave the mic hanging); so does a tap
///   failure.
/// - Polls read the HID state, which runs ahead of tap delivery. A poll that sees another key or
///   modifier held is a chord. A poll that finds the key up only marks a tentative release
///   (`.releasing`, at the poll time, an upper bound on the physical release): events arrive in
///   order, so a chord whose events are still in flight lands first and cancels or releases the
///   press as a chord. The key-up event settles it as a release, tap or double tap at the poll
///   time; with no key-up within `holdGapMaxMs` it settles the same way at that deadline, a
///   press that is not a tap reporting `.lostKeyUp`. Taps never come straight from a poll.
/// - After a cancel or forced release the key must be seen up before a new press counts.
public struct PushToTalkMachine: Sendable {
    public struct Config: Sendable, Hashable {
        public var key: ModifierKey
        public var minHoldMs: Int
        public var maxHoldS: Int
        public var chordCancelWindowMs: Int
        public var chordCancelOnlyBeforeFirstCommit: Bool
        public var doubleTapMaxPressMs: Int
        public var doubleTapMaxGapMs: Int
        public var doubleTapRequiresNoVad: Bool
        /// How long a poll-seen release waits for its key-up event (the passthrough lease).
        public var holdGapMaxMs: Int

        public init(key: ModifierKey = .rightOption, minHoldMs: Int, maxHoldS: Int, chordCancelWindowMs: Int,
                    chordCancelOnlyBeforeFirstCommit: Bool, doubleTapMaxPressMs: Int, doubleTapMaxGapMs: Int,
                    doubleTapRequiresNoVad: Bool, holdGapMaxMs: Int = 100) {
            self.holdGapMaxMs = holdGapMaxMs
            self.key = key; self.minHoldMs = minHoldMs; self.maxHoldS = maxHoldS
            self.chordCancelWindowMs = chordCancelWindowMs
            self.chordCancelOnlyBeforeFirstCommit = chordCancelOnlyBeforeFirstCommit
            self.doubleTapMaxPressMs = doubleTapMaxPressMs; self.doubleTapMaxGapMs = doubleTapMaxGapMs
            self.doubleTapRequiresNoVad = doubleTapRequiresNoVad
        }

        /// `holdGapMaxMs` is the passthrough lease (`speak.passthrough.leaseMs`), as in
        /// PassthroughKeyMachine.
        public init(speak s: PolicyProfile.Speak) {
            let p = s.ptt
            self.init(minHoldMs: p.minHoldMs, maxHoldS: p.maxHoldS, chordCancelWindowMs: p.chordCancelWindowMs,
                      chordCancelOnlyBeforeFirstCommit: p.chordCancelOnlyBeforeFirstCommit,
                      doubleTapMaxPressMs: p.doubleTap.maxPressMs, doubleTapMaxGapMs: p.doubleTap.maxGapMs,
                      doubleTapRequiresNoVad: p.doubleTap.requireNoVad, holdGapMaxMs: s.passthrough.leaseMs)
        }
    }

    public enum ReleaseReason: Sendable, Hashable {
        case keyUp
        /// A chord after the cancel window or after the first commit (rule 1: treated as a release).
        case chord
        case maxHold
        case tapFailed(TapFailure)
        /// A poll found the key up and no key-up event followed within `holdGapMaxMs` (or the
        /// key went down again first), on a press that is not a tap.
        case lostKeyUp
    }

    public enum Action: Sendable, Hashable {
        /// A clean press: start pre-roll, preview analyzer and VAD.
        case began(at: HostTime)
        /// End the press normally (rule 6: record the tail, finalize, commit the rest).
        case released(at: HostTime, reason: ReleaseReason)
        /// Chord inside the window before the first commit: discard the whole press.
        case cancelled(at: HostTime)
        /// Shorter than `minHoldMs` with no VAD: nothing to say, nothing cancelled.
        case tapped(at: HostTime)
        /// The second tap of a double tap (hard interrupt).
        case doubleTapped(at: HostTime)
    }

    public enum Phase: Sendable, Hashable {
        case idle
        case held(downAt: HostTime, committed: Bool, spoke: Bool)
        /// A poll saw the key up at `upAt`; waiting for the key-up event (or a chord) to settle it.
        case releasing(downAt: HostTime, committed: Bool, spoke: Bool, upAt: HostTime)
        case mustRelease
    }

    public let config: Config
    public private(set) var phase: Phase = .idle
    public private(set) var tapHealthy = false
    public private(set) var otherKeysDown: Set<UInt16> = []
    private var lastFlags: ModifierFlags = []
    /// Release time of the last qualifying tap, waiting for a second one.
    private var pendingTapReleasedAt: HostTime?
    private var speechActive = false

    public init(config: Config) { self.config = config }

    /// A press is in progress (PassthroughPolicy's `pushToTalkActive`).
    public var isActive: Bool {
        switch phase {
        case .held, .releasing: true
        case .idle, .mustRelease: false
        }
    }

    // MARK: inputs

    public mutating func handle(_ e: KeyInputEvent) -> [Action] {
        var out = advance(to: e.time)
        switch e.kind {
        case let .flagsChanged(code, flags):
            out += flagsChanged(code: code, flags: flags, at: e.time)
        case let .keyDown(code, _):
            if !KeyCode.modifiers.contains(code) { otherKeysDown.insert(code) }
            out += chord(at: e.time)
        case let .keyUp(code):
            otherKeysDown.remove(code)
        case .mouseDown, .scroll, .mouseMoved:
            break   // the mouse does not chord push-to-talk (cicada RightOptionKey)
        case let .tapDisabled(f):
            tapHealthy = false
            if isActive {
                out.append(.released(at: e.time, reason: .tapFailed(f)))
                phase = .mustRelease
            }
            pendingTapReleasedAt = nil
        case .tapEnabled:
            tapHealthy = true
        case let .poll(s):
            otherKeysDown = s.keysDown.filter { !KeyCode.modifiers.contains($0) }
            switch phase {
            case let .held(downAt, committed, spoke):
                if othersHeld(in: s) { out += chord(at: e.time) }
                else if !s.isDown(config.key) {
                    phase = .releasing(downAt: downAt, committed: committed, spoke: spoke, upAt: e.time)
                }
            case .releasing:
                if othersHeld(in: s) { out += chord(at: e.time) }
            case .mustRelease:
                if !s.isDown(config.key) && tapHealthy { phase = .idle }
            case .idle:
                break
            }
        }
        return out
    }

    public mutating func tick(now: HostTime) -> [Action] { advance(to: now) }

    /// SpeakSegmenter committed the first segment of this press.
    public mutating func didCommit() {
        switch phase {
        case let .held(d, _, s): phase = .held(downAt: d, committed: true, spoke: s)
        case let .releasing(d, _, s, u): phase = .releasing(downAt: d, committed: true, spoke: s, upAt: u)
        case .idle, .mustRelease: break
        }
    }

    /// SPEAK VAD onset / end.
    public mutating func vad(speech: Bool, at _: HostTime) {
        speechActive = speech
        if speech, case let .held(d, c, _) = phase { phase = .held(downAt: d, committed: c, spoke: true) }
    }

    // MARK: rules

    private mutating func advance(to t: HostTime) -> [Action] {
        if case let .releasing(downAt, _, spoke, upAt) = phase, t > upAt &+ ms(config.holdGapMaxMs) {
            return settle(downAt: downAt, spoke: spoke, upAt: upAt, keyUpSeen: false)
        }
        if case let .held(downAt, _, _) = phase, t >= downAt &+ ms(config.maxHoldS * 1000) {
            phase = .mustRelease
            pendingTapReleasedAt = nil
            return [.released(at: t, reason: .maxHold)]
        }
        return []
    }

    private mutating func flagsChanged(code: UInt16, flags: ModifierFlags, at t: HostTime) -> [Action] {
        let previous = lastFlags
        lastFlags = flags
        let key = config.key
        switch phase {
        case .idle:
            guard code == key.keyCode, key.isDown(in: flags) else { return [] }
            guard key.isSoleHeldModifier(in: flags), otherKeysDown.isEmpty, tapHealthy else {
                phase = .mustRelease
                pendingTapReleasedAt = nil
                return []
            }
            phase = .held(downAt: t, committed: false, spoke: speechActive)
            return [.began(at: t)]
        case .mustRelease:
            if code == key.keyCode && !key.isDown(in: flags) && tapHealthy { phase = .idle }
            return []
        case let .held(downAt, _, spoke):
            if code == key.keyCode && !key.isDown(in: flags) {
                phase = .idle
                return release(downAt: downAt, spoke: spoke, at: t)
            }
            if code == key.keyCode && flags.intersection(.held) == previous.intersection(.held) { return [] }
            return chord(at: t)
        case let .releasing(downAt, _, spoke, upAt):
            if code == key.keyCode && !key.isDown(in: flags) {
                return settle(downAt: downAt, spoke: spoke, upAt: upAt, keyUpSeen: true)
            }
            if code == key.keyCode {
                // down again with no key-up in between: the key-up was lost; this is a new press
                return settle(downAt: downAt, spoke: spoke, upAt: upAt, keyUpSeen: false)
                    + flagsChanged(code: code, flags: flags, at: t)
            }
            return chord(at: t)
        }
    }

    /// Another key, or a modifier other than the press's own, held in a poll (caps lock and fn
    /// key codes excluded: `KeyStateSnapshot.stateKeyCodes`).
    private func othersHeld(in s: KeyStateSnapshot) -> Bool { s.othersHeld(besides: config.key) }

    /// The tentative release becomes the release, tap or double tap, timed at the poll.
    private mutating func settle(downAt: HostTime, spoke: Bool, upAt: HostTime, keyUpSeen: Bool) -> [Action] {
        phase = .idle
        let out = release(downAt: downAt, spoke: spoke, at: upAt)
        if keyUpSeen { return out }
        pendingTapReleasedAt = nil   // a release whose key-up never came is not the first half of a double tap
        // ... nor the second: the hard interrupt needs a real key-up (a chord's events may still
        // be behind the deadline)
        return out.map { a in
            switch a {
            case let .released(at, .keyUp): return .released(at: at, reason: .lostKeyUp)
            case let .doubleTapped(at): return .tapped(at: at)
            default: return a
            }
        }
    }

    private mutating func chord(at t: HostTime) -> [Action] {
        let downAt: HostTime, committed: Bool
        switch phase {
        case let .held(d, c, _), let .releasing(d, c, _, _): downAt = d; committed = c
        case .idle, .mustRelease: return []
        }
        phase = .mustRelease
        pendingTapReleasedAt = nil
        let inWindow = t < downAt &+ ms(config.chordCancelWindowMs)
        let beforeCommit = !committed || !config.chordCancelOnlyBeforeFirstCommit
        return inWindow && beforeCommit ? [.cancelled(at: t)] : [.released(at: t, reason: .chord)]
    }

    /// A wrapper-denied press is not one half of an accepted double tap.
    public mutating func discardTapSequence() { pendingTapReleasedAt = nil }

    /// A wrapper invalidated this gesture (toggle mode / device fault). No later release of
    /// the same held key may become a new gesture; observe it up before accepting another down.
    public mutating func discardUntilRelease() {
        phase = .mustRelease
        pendingTapReleasedAt = nil
    }

    private mutating func release(downAt: HostTime, spoke: Bool, at t: HostTime) -> [Action] {
        let held = t >= downAt ? t - downAt : 0
        guard held < ms(config.minHoldMs) && !spoke else {
            pendingTapReleasedAt = nil
            return [.released(at: t, reason: .keyUp)]
        }
        let doubleTapEligible = held < ms(config.doubleTapMaxPressMs) && (!spoke || !config.doubleTapRequiresNoVad)
        if doubleTapEligible, let first = pendingTapReleasedAt, downAt >= first,
           downAt - first <= ms(config.doubleTapMaxGapMs) {
            pendingTapReleasedAt = nil
            return [.doubleTapped(at: t)]
        }
        pendingTapReleasedAt = doubleTapEligible ? t : nil
        return [.tapped(at: t)]
    }

    private func ms(_ v: Int) -> HostTime { HostTime(max(0, v)) * 1_000_000 }
}
