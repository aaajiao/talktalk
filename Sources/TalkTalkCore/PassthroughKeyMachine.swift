/// The passthrough key (ARCHITECTURE.md, "SPEAK：实体麦到会议输入"). Pure logic on the
/// event times it is given: right ⌘ (0x36, device bit 0x10) or, for external keyboards, right ⌃
/// (0x3E, 0x2000). PassthroughKey (TalkTalkSession) feeds it KeyTap events plus a 20 ms
/// (`keyPollMs`) poll of the hardware key state while the key is held; PassthroughController
/// relays its actions to PassthroughGate.
///
/// - A press counts only when it is clean (no other modifier, key or mouse button held), comes
///   from the HID system source, and the tap is healthy.
/// - It arms after `armHoldMs` with no keyDown, modifier change, mouse button, scroll, or more
///   than `mouseMoveMaxPt` of mouse movement. Arming asks the gate to prepare; every clean poll
///   after that (`.held`) is the gate's recheck "right before opening".
/// - While open every clean poll renews the lease (`.renew`); any other input, the key going up
///   (event or poll), a tap failure, or `maxHoldS` closes it. The last `countdownS` seconds are
///   announced once per second.
/// - Polls read the HID state, which runs ahead of tap delivery. A poll that finds the key up is
///   a normal release (`.keyReleased`); only when the key-up event has not followed within
///   `holdGapMaxMs` (or the key goes down again first) is it counted in `lostKeyUps`
///   (`pt.lost_key_up`, §15 risk 20). While pressed, a poll is checked before the hold may arm
///   on it: a poll that already sees the key up or another key held ends the press with nothing
///   shown (§3.8: under 400 ms nothing appears).
/// - After anything ends a press the key must be seen released (and, after a tap failure, the
///   tap enabled again) before a new press counts. A second "down" of the key while held means a
///   key-up was lost: the press ends and the new one is timed from that event.
/// - A hold is only as good as its observation: while pressed or armed, a gap of more than
///   `holdGapMaxMs` (the lease, 100 ms) between inputs means the key thread stalled and the key
///   may have been released and pressed again unseen. The press ends; release and press again.
///   (Once open, the gate's lease does the same.)
public struct PassthroughKeyMachine: Sendable {
    public struct Config: Sendable, Hashable {
        public var key: ModifierKey
        public var armHoldMs: Int
        public var maxHoldS: Int
        public var countdownS: Int
        public var requireHidSource: Bool
        public var mouseMoveMaxPt: Double
        /// Longest gap between inputs (polls included) a hold survives before it opens.
        public var holdGapMaxMs: Int
        public var recordsIntervals: Bool

        public init(key: ModifierKey = .rightCommand, armHoldMs: Int, maxHoldS: Int, countdownS: Int,
                    requireHidSource: Bool, mouseMoveMaxPt: Double, holdGapMaxMs: Int = 100,
                    recordsIntervals: Bool = false) {
            self.key = key; self.armHoldMs = armHoldMs; self.maxHoldS = maxHoldS; self.countdownS = countdownS
            self.requireHidSource = requireHidSource; self.mouseMoveMaxPt = mouseMoveMaxPt
            self.holdGapMaxMs = holdGapMaxMs; self.recordsIntervals = recordsIntervals
        }

        /// `useAltKey`: the settings choice for external keyboards (`altKey`, right ⌃).
        /// `recordsIntervals`: dev builds or diagnostics on (§3.8 "默认与设置").
        public init?(profile p: PolicyProfile.Speak.Passthrough, useAltKey: Bool = false, recordsIntervals: Bool = false) {
            guard let key = ModifierKey(profileName: useAltKey ? p.altKey : p.key),
                  key == .rightCommand || key == .rightControl else { return nil }
            self.init(key: key, armHoldMs: p.armHoldMs, maxHoldS: p.maxHoldS, countdownS: p.countdownS,
                      requireHidSource: p.requireHidSource, mouseMoveMaxPt: Double(p.mouseMoveMaxPt),
                      holdGapMaxMs: p.leaseMs, recordsIntervals: recordsIntervals)
        }
    }

    public enum Action: Sendable, Hashable {
        /// The clean hold reached `armHoldMs`: the gate starts preparing (policy, TTS yield, cue, VAD).
        case arm(pressedAt: HostTime, armedAt: HostTime)
        /// A clean poll while armed: the key-state recheck. The gate opens on the first one at
        /// which every other open condition holds.
        case held(at: HostTime)
        /// A clean poll while open: renew the lease.
        case renew(at: HostTime)
        /// Ends whatever the gate is doing for this press (preparing or open).
        case close(at: HostTime, reason: PassthroughCloseReason)
        /// HUD countdown in the last `countdownS` seconds.
        case countdown(secondsLeft: Int)
    }

    public enum Phase: Sendable, Hashable {
        case idle
        case pressed(downAt: HostTime, moved: Double)
        case armed(downAt: HostTime, armedAt: HostTime, moved: Double)
        case open(downAt: HostTime, openedAt: HostTime, lastCountdown: Int?)
        /// Waiting for the key to be seen up (and the tap to be enabled again after a failure).
        case mustRelease(released: Bool)
    }

    public let config: Config
    public private(set) var phase: Phase = .idle
    /// Starts false: nothing arms until KeyTap reports the tap enabled.
    public private(set) var tapHealthy = false
    /// Non-modifier keys held, from keyDown/keyUp and refreshed by every poll.
    public private(set) var otherKeysDown: Set<UInt16> = []
    /// Presses cancelled before arming by another input (`pt.prearm_cancels`, logged per session).
    public private(set) var prearmCancels = 0
    public private(set) var intervals = IntervalHistogram()
    private var lastFlags: ModifierFlags = []
    private var intervalPending: HostTime?
    /// Time of the last input handled (any kind, polls included).
    private var lastInputAt: HostTime?
    /// Key-ups that never arrived: a poll saw the key up and no key-up event followed in time.
    public private(set) var lostKeyUps = 0
    /// A poll saw the key up at this time; the key-up event has not arrived yet.
    private var keyUpAwaitedSince: HostTime?

    public init(config: Config) { self.config = config }

    /// Armed or open: the gate is working on this press.
    public var isEngaged: Bool {
        switch phase {
        case .armed, .open: true
        case .idle, .pressed, .mustRelease: false
        }
    }

    public var isOpen: Bool { if case .open = phase { true } else { false } }

    // MARK: inputs

    public mutating func handle(_ e: KeyInputEvent) -> [Action] {
        var out = unobservedGap(at: e.time)
        lastInputAt = max(lastInputAt ?? 0, e.time)
        awaitKeyUp(e)
        if case .pressed = phase, case let .poll(s) = e.kind, !s.isSoleHeld(config.key) {
            return out + poll(s, at: e.time)   // checked before the hold can arm on this poll
        }
        out += advance(to: e.time)
        recordInterval(e)
        switch e.kind {
        case let .flagsChanged(code, flags):
            out += flagsChanged(code: code, flags: flags, at: e.time, source: e.source)
        case let .keyDown(code, _):
            if !KeyCode.modifiers.contains(code) { otherKeysDown.insert(code) }
            out += breakHold(at: e.time, reason: .otherKey)
        case let .keyUp(code):
            otherKeysDown.remove(code)
            out += breakHold(at: e.time, reason: .otherKey)
        case .mouseDown:
            out += breakHold(at: e.time, reason: .mouseButton)
        case .scroll:
            out += breakHold(at: e.time, reason: .scroll)
        case let .mouseMoved(dx, dy):
            out += mouseMoved(dx: dx, dy: dy, at: e.time)
        case let .tapDisabled(failure):
            tapHealthy = false
            out += end(at: e.time, reason: .tapFailed(failure), released: false)
        case .tapEnabled:
            tapHealthy = true
            settleRelease()
        case let .poll(snapshot):
            out += poll(snapshot, at: e.time)
        }
        return out
    }

    /// Time passing without events (the poll timer normally covers this).
    public mutating func tick(now: HostTime) -> [Action] {
        if let since = keyUpAwaitedSince, now > since &+ ms(config.holdGapMaxMs) { lostKeyUps += 1; keyUpAwaitedSince = nil }
        return unobservedGap(at: now) + advance(to: now)
    }

    /// Settles a poll-seen release: the key-up event arrived (fine), is overdue, or the key went
    /// down again first (lost).
    private mutating func awaitKeyUp(_ e: KeyInputEvent) {
        guard let since = keyUpAwaitedSince else { return }
        if case let .flagsChanged(code, flags) = e.kind, code == config.key.keyCode {
            if !config.key.isDown(in: flags) { keyUpAwaitedSince = nil; return }
            lostKeyUps += 1; keyUpAwaitedSince = nil; return
        }
        if e.time > since &+ ms(config.holdGapMaxMs) { lostKeyUps += 1; keyUpAwaitedSince = nil }
    }

    /// The gate opened at `at`.
    public mutating func gateOpened(at: HostTime) {
        guard case let .armed(downAt, _, _) = phase else { return }
        phase = .open(downAt: downAt, openedAt: at, lastCountdown: nil)
    }

    /// The gate refused, cancelled or closed on its own (policy, VAD, lease, system event): this
    /// press is over; a new clean press is needed.
    public mutating func gateEnded() {
        switch phase {
        case .armed, .open: phase = .mustRelease(released: false)
        case .idle, .pressed, .mustRelease: break
        }
    }

    // MARK: rules

    private var held: Bool {
        switch phase {
        case .pressed, .armed, .open: true
        case .idle, .mustRelease: false
        }
    }

    /// The key thread went quiet for longer than `holdGapMaxMs` during a hold that has not opened.
    private mutating func unobservedGap(at t: HostTime) -> [Action] {
        guard let last = lastInputAt, t > last &+ ms(config.holdGapMaxMs) else { return [] }
        switch phase {
        case .pressed:
            intervalPending = nil
            phase = .mustRelease(released: false)
            return []
        case .armed:
            return end(at: t, reason: .leaseExpired, released: false)
        case .idle, .open, .mustRelease:
            return []
        }
    }

    private mutating func advance(to t: HostTime) -> [Action] {
        switch phase {
        case let .pressed(downAt, moved):
            if t >= downAt &+ ms(config.armHoldMs) {
                phase = .armed(downAt: downAt, armedAt: t, moved: moved)
                return [.arm(pressedAt: downAt, armedAt: t)]
            }
        case let .open(downAt, openedAt, lastCountdown):
            let maxEnd = openedAt &+ ms(config.maxHoldS * 1000)
            if t >= maxEnd { return end(at: t, reason: .maxHold, released: false) }
            let left = Int(((maxEnd - t) + 999_999_999) / 1_000_000_000)   // ceil seconds
            if left <= config.countdownS && left != lastCountdown {
                phase = .open(downAt: downAt, openedAt: openedAt, lastCountdown: left)
                return [.countdown(secondsLeft: left)]
            }
        case .idle, .armed, .mustRelease:
            break
        }
        return []
    }

    private mutating func flagsChanged(code: UInt16, flags: ModifierFlags, at t: HostTime, source: KeyEventSource) -> [Action] {
        let previous = lastFlags
        lastFlags = flags
        let key = config.key
        switch phase {
        case .idle:
            guard code == key.keyCode, key.isDown(in: flags) else { return [] }
            let clean = key.isSoleHeldModifier(in: flags) && otherKeysDown.isEmpty
                && (source == .hidSystem || !config.requireHidSource) && tapHealthy
            phase = clean ? .pressed(downAt: t, moved: 0) : .mustRelease(released: false)
            if clean { intervalPending = config.recordsIntervals ? t : nil }
            return []
        case .mustRelease:
            if code == key.keyCode {
                phase = .mustRelease(released: !key.isDown(in: flags))
                settleRelease()
            }
            return []
        case .pressed, .armed, .open:
            if code == key.keyCode && !key.isDown(in: flags) {
                return end(at: t, reason: .keyReleased, released: true)
            }
            // Our own key "down" again with the same flags: a key-up was lost and the key was
            // pressed again. End this press and count the new one from now, so a hold is never
            // measured across a release the tap did not see.
            if code == key.keyCode && flags.intersection(.held) == previous.intersection(.held) {
                if keyUpAwaitedSince == nil { lostKeyUps += 1 }   // else awaitKeyUp counted it
                var out = end(at: t, reason: .lostKeyUp, released: true)
                out += flagsChanged(code: code, flags: flags, at: t, source: source)
                return out
            }
            return breakHold(at: t, reason: .modifierChanged)
        }
    }

    private mutating func mouseMoved(dx: Double, dy: Double, at t: HostTime) -> [Action] {
        let d = (dx * dx + dy * dy).squareRoot()
        switch phase {
        case let .pressed(downAt, moved):
            if moved + d > config.mouseMoveMaxPt { return breakHold(at: t, reason: .mouseMoved) }
            phase = .pressed(downAt: downAt, moved: moved + d)
        case let .armed(downAt, armedAt, moved):
            if moved + d > config.mouseMoveMaxPt { return breakHold(at: t, reason: .mouseMoved) }
            phase = .armed(downAt: downAt, armedAt: armedAt, moved: moved + d)
        case .open, .idle, .mustRelease:
            break   // once open, moving the mouse does not close (§3.8 "关闭")
        }
        return []
    }

    private mutating func poll(_ s: KeyStateSnapshot, at t: HostTime) -> [Action] {
        otherKeysDown = s.keysDown.filter { !KeyCode.modifiers.contains($0) }
        let key = config.key
        switch phase {
        case .idle:
            return []
        case .mustRelease:
            phase = .mustRelease(released: !s.isDown(key))
            settleRelease()
            return []
        case .pressed:
            if !s.isDown(key) { keyUpAwaitedSince = t; return end(at: t, reason: .keyReleased, released: true) }
            if !s.isSoleHeld(key) { return breakHold(at: t, reason: .otherInputHeld) }
            return []
        case .armed, .open:
            if !s.isDown(key) { keyUpAwaitedSince = t; return end(at: t, reason: .keyReleased, released: true) }
            if !s.isSoleHeld(key) { return breakHold(at: t, reason: .otherInputHeld) }
            if s.secureInput == true { return breakHold(at: t, reason: .secureInput) }
            if case .open = phase { return [.renew(at: t)] }
            return [.held(at: t)]
        }
    }

    /// Any other input during a press: before arming it is a ⌘ shortcut (counted, never shown);
    /// after arming it ends the press through the gate.
    private mutating func breakHold(at t: HostTime, reason: PassthroughCloseReason) -> [Action] {
        guard held else { return [] }
        return end(at: t, reason: reason, released: false)
    }

    private mutating func end(at t: HostTime, reason: PassthroughCloseReason, released: Bool) -> [Action] {
        intervalPending = nil
        let wasEngaged = isEngaged
        if case .pressed = phase, !released { prearmCancels += 1 }
        switch phase {
        case .idle:
            // A tap failure while nothing is pressed: released already unless the key is down.
            if !released { phase = .mustRelease(released: !config.key.isDown(in: lastFlags)) }
        case .mustRelease:
            if !released { phase = .mustRelease(released: false) }
        case .pressed, .armed, .open:
            phase = released ? .idle : .mustRelease(released: false)
        }
        settleRelease()
        return wasEngaged ? [.close(at: t, reason: reason)] : []
    }

    private mutating func settleRelease() {
        if case .mustRelease(true) = phase, tapHealthy { phase = .idle }
    }

    private mutating func recordInterval(_ e: KeyInputEvent) {
        guard let start = intervalPending, e.isUserInput else { return }
        // The press's own key going up is not "the next input" of a shortcut.
        if case let .flagsChanged(code, _) = e.kind, code == config.key.keyCode { return }
        if case .mouseMoved = e.kind { return }
        intervals.record(ms: e.time >= start ? Double(e.time - start) / 1e6 : 0)
        intervalPending = nil
    }

    private func ms(_ v: Int) -> HostTime { HostTime(max(0, v)) * 1_000_000 }

    // MARK: dev hook (§3.8 privacy invariant 7, §14 M0-T16)

    #if TALKTALK_DEV
    /// Dev builds only: events injected by the bench hook. They count as hardware events only in
    /// `--bench` mode with no other process reading TalkTalk Mic; otherwise they are non-HID, so they
    /// can end a press but never start one.
    public struct DevInjection: Sendable, Hashable {
        public var benchMode: Bool
        public var otherTalkTalkMicReaders: Int
        public init(benchMode: Bool, otherTalkTalkMicReaders: Int) {
            self.benchMode = benchMode; self.otherTalkTalkMicReaders = otherTalkTalkMicReaders
        }
        public var treatsAsHardware: Bool { benchMode && otherTalkTalkMicReaders == 0 }
    }

    public mutating func inject(_ e: KeyInputEvent, _ context: DevInjection) -> [Action] {
        var e = e
        if !context.treatsAsHardware { e.source = .other }
        return handle(e)
    }
    #endif
}

/// "右⌘ 按下 → 下一个输入事件" intervals (§3.8 "默认与设置"): counts in 10 ms bins up to 1 s, no
/// key identity, no timestamps. M2 reviews `armHoldMs` against its p99.5.
public struct IntervalHistogram: Sendable, Hashable {
    public static let binMs = 10
    public static let bins = 100
    public private(set) var counts = [Int](repeating: 0, count: IntervalHistogram.bins)
    public private(set) var overflow = 0

    public init() {}

    public var total: Int { counts.reduce(0, +) + overflow }

    public mutating func record(ms: Double) {
        let i = Int(ms.isFinite ? max(0, ms) : 0) / Self.binMs
        if i < Self.bins { counts[i] += 1 } else { overflow += 1 }
    }

    /// Upper edge (ms) of the bin holding quantile `q`; nil when empty or the quantile overflows.
    public func quantileUpperMs(_ q: Double) -> Int? {
        let n = total
        guard n > 0 else { return nil }
        let need = Int((q * Double(n)).rounded(.up))
        var acc = 0
        for (i, c) in counts.enumerated() {
            acc += c
            if acc >= need { return (i + 1) * Self.binMs }
        }
        return nil
    }
}
