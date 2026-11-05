import Testing
@testable import TalkTalkCore

// MARK: - Shared rig (also used by PassthroughFuzzTests, PassthroughKeyMachineTests)

/// File-private like the other suites' helpers (an internal one would clash with theirs).
private func ms(_ v: Int) -> HostTime { HostTime(v) * 1_000_000 }

let rcmdFlags: ModifierFlags = [.deviceRightCommand, .command]
let roptFlags: ModifierFlags = [.deviceRightOption, .option]
let heldRightCommand = KeyStateSnapshot(keysDown: [KeyCode.rightCommand], flags: rcmdFlags)
let nothingHeld = KeyStateSnapshot(keysDown: [], flags: [])

/// Deterministic generator for the property and fuzz tests.
struct PTSplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class NoticeLog: @unchecked Sendable {
    var items: [PassthroughNotice] = []
    var handler: ((PassthroughNotice) -> Void)?
    func add(_ n: PassthroughNotice) { items.append(n); handler?(n) }

    var opens: [HostTime] { items.compactMap { if case let .opened(at, _, _) = $0 { at } else { nil } } }
    var closes: [(at: HostTime, reason: PassthroughCloseReason)] {
        items.compactMap { if case let .closed(at, r, _) = $0 { (at, r) } else { nil } }
    }
    var refusals: [PassthroughRefusal] { items.compactMap { if case let .refused(r) = $0 { r } else { nil } } }
    var cancels: [PassthroughCloseReason] { items.compactMap { if case let .cancelled(r) = $0 { r } else { nil } } }
}

final class FakePlayout: PassthroughPlayoutYielding, @unchecked Sendable {
    var requests: [(requestedAt: HostTime, cutAt: HostTime)] = []
    var ended: [HostTime] = []
    var onRequest: ((HostTime, HostTime) -> Void)?
    func yieldForPassthrough(requestedAt: HostTime, cutAt: HostTime) {
        requests.append((requestedAt, cutAt)); onRequest?(requestedAt, cutAt)
    }
    func passthroughEnded(at: HostTime) { ended.append(at) }
}

final class PassthroughRig {
    let profile: PolicyProfile.Speak.Passthrough
    let sink = InMemoryPassthroughStateSink(keepsHistory: true)
    let log = NoticeLog()
    let playout: FakePlayout?
    let gate: PassthroughGate
    let ctl: PassthroughController

    init(playout: FakePlayout? = nil, facts: PassthroughPolicy.Facts = .allGood, micWarm: Bool = true,
         cueAudible: Bool = false, recordsIntervals: Bool = false, at t0: HostTime = ms(1000)) throws {
        profile = try TestResources.profile().speak.passthrough
        self.playout = playout
        let log = self.log
        gate = PassthroughGate(config: .init(profile: profile), sink: sink, playout: playout, onNotice: { log.add($0) })
        let cfg = try #require(PassthroughKeyMachine.Config(profile: profile, recordsIntervals: recordsIntervals))
        ctl = PassthroughController(machine: PassthroughKeyMachine(config: cfg), gate: gate)
        gate.updateFacts(at: t0) { $0 = facts }
        gate.setMicWarm(micWarm)
        gate.setCueAudible(cueAudible)
        ctl.handle(KeyInputEvent(time: t0, kind: .tapEnabled))
    }

    @discardableResult
    func send(_ kind: KeyInputEvent.Kind, at t: HostTime, source: KeyEventSource = .hidSystem) -> [PassthroughKeyMachine.Action] {
        ctl.handle(KeyInputEvent(time: t, kind: kind, source: source))
    }

    func down(at t: HostTime, source: KeyEventSource = .hidSystem, extra: ModifierFlags = []) {
        send(.flagsChanged(keyCode: KeyCode.rightCommand, flags: rcmdFlags.union(extra)), at: t, source: source)
    }

    func up(at t: HostTime, remaining: ModifierFlags = []) {
        send(.flagsChanged(keyCode: KeyCode.rightCommand, flags: remaining), at: t)
    }

    func poll(at t: HostTime, _ s: KeyStateSnapshot = heldRightCommand) { send(.poll(s), at: t) }

    /// Polls every `keyPollMs` in [from, to].
    func polls(from: HostTime, to: HostTime, _ s: KeyStateSnapshot = heldRightCommand) {
        var t = from
        while t <= to { poll(at: t, s); t += ms(profile.keyPollMs) }
    }

    /// Clean press at `p`, polls until the gate opens (or `limitMs`). Returns the open time.
    @discardableResult
    func pressAndHold(at p: HostTime, limitMs: Int = 3000) -> HostTime? {
        down(at: p)
        var t = p + ms(profile.keyPollMs)
        while t <= p + ms(limitMs) {
            poll(at: t)
            if ctl.machine.isOpen { return log.opens.last }
            t += ms(profile.keyPollMs)
        }
        return nil
    }

    var isOpen: Bool { sink.current.open }

    func block(at t: HostTime, ms d: Int, rate: Double = 48_000, origin: PassthroughSource = .mic) -> MicBlock {
        MicBlock(origin: origin, hostTime: t, sampleRate: rate, samples: [Float](repeating: 0.1, count: Int(rate) * d / 1000))
    }
}

// MARK: - Rule cases

@Suite struct PassthroughGateTests {
    // MARK: open conditions

    /// 打开条件 1: a press with another modifier or key held does not count.
    @Test func openCondition1CleanPress() throws {
        let r = try PassthroughRig()
        r.down(at: ms(1100), extra: [.deviceLeftShift, .shift])
        r.polls(from: ms(1120), to: ms(2000), KeyStateSnapshot(keysDown: [KeyCode.rightCommand, KeyCode.shift],
                                                                flags: rcmdFlags.union([.deviceLeftShift, .shift])))
        #expect(r.log.opens.isEmpty)

        let r2 = try PassthroughRig()
        r2.send(.keyDown(keyCode: 0x00, isRepeat: false), at: ms(1050))   // 'a' held
        r2.down(at: ms(1100))
        r2.polls(from: ms(1120), to: ms(2000), KeyStateSnapshot(keysDown: [KeyCode.rightCommand, 0x00], flags: rcmdFlags))
        #expect(r2.log.opens.isEmpty)

        // the same press, clean, opens: at the first poll ≥ press + 400 ms + one poll period
        let r3 = try PassthroughRig()
        let open = try #require(r3.pressAndHold(at: ms(1100)))
        #expect(open >= ms(1100 + 400 + 20) && open <= ms(1100 + 400 + 40))
        #expect(r3.isOpen && r3.sink.current.source == .mic && r3.sink.current.generation == 1)
    }

    /// 打开条件 2: 400 ms alone; any keyDown, modifier change, mouse button, scroll or > 10 pt of
    /// mouse movement inside it cancels; ≤ 10 pt does not.
    @Test(arguments: [
        KeyInputEvent.Kind.keyDown(keyCode: 0x08, isRepeat: false),           // ⌘C
        .flagsChanged(keyCode: KeyCode.shift, flags: rcmdFlags.union([.deviceLeftShift, .shift])),
        .flagsChanged(keyCode: KeyCode.rightOption, flags: rcmdFlags.union(roptFlags)),
        .flagsChanged(keyCode: KeyCode.capsLock, flags: rcmdFlags.union(.capsLock)),
        .flagsChanged(keyCode: KeyCode.function, flags: rcmdFlags.union(.function)),
        .mouseDown, .scroll, .mouseMoved(dx: 8, dy: 8),
    ])
    func openCondition2AloneForArmHold(_ second: KeyInputEvent.Kind) throws {
        let r = try PassthroughRig()
        r.down(at: ms(1000))
        r.polls(from: ms(1020), to: ms(1380))
        r.send(second, at: ms(1390))
        r.polls(from: ms(1400), to: ms(2500))
        #expect(r.log.opens.isEmpty)
        #expect(r.ctl.machine.prearmCancels == 1)
        #expect(r.log.items.isEmpty)   // a prearm cancel shows and logs nothing
    }

    @Test func openCondition2SmallMouseMovementIsFine() throws {
        let r = try PassthroughRig()
        r.down(at: ms(1000))
        r.send(.mouseMoved(dx: 3, dy: 4), at: ms(1100))   // 5 pt
        r.send(.mouseMoved(dx: 0, dy: 4.9), at: ms(1200)) // 9.9 pt
        r.polls(from: ms(1020), to: ms(1500))
        #expect(r.log.opens.count == 1)
    }

    /// 打开条件 3: every fact, unknown or bad, refuses with its reason.
    @Test(arguments: PassthroughPolicy.Fact.allCases)
    func openCondition3Policy(_ fact: PassthroughPolicy.Fact) throws {
        for unknown in [true, false] {
            var f = PassthroughPolicy.Facts.allGood
            set(&f, fact, unknown: unknown)
            let r = try PassthroughRig(facts: f)
            r.pressAndHold(at: ms(1100), limitMs: 1500)
            #expect(r.log.opens.isEmpty, "\(fact) unknown=\(unknown)")
            let expected = PassthroughPolicy.evaluate(f)
            guard case let .unavailable(reason) = expected else { Issue.record("\(fact) evaluated available"); continue }
            if unknown { #expect(reason == .unknown(fact)) }
            #expect(r.log.refusals == [.unavailable(reason)])
        }
    }

    /// 打开条件 4: TTS yield. The gate asks ClauseQueue, shows "等这句说完", opens only after the answer.
    @Test func openCondition4WaitsForTheClause() throws {
        let playout = FakePlayout()
        let r = try PassthroughRig(playout: playout)
        r.down(at: ms(1000))
        r.polls(from: ms(1020), to: ms(1980))
        #expect(playout.requests.count == 1)
        #expect(playout.requests[0].cutAt == playout.requests[0].requestedAt + ms(1500))
        #expect(r.log.opens.isEmpty)
        #expect(r.log.items.contains(.waitingForClause))
        r.gate.playoutYielded(at: ms(1990))
        r.polls(from: ms(2000), to: ms(2480))
        #expect(r.log.opens == [ms(2000)])
        r.up(at: ms(2500))
        #expect(playout.ended == [ms(2500)])
    }

    @Test func openCondition4YieldTimeoutRefuses() throws {
        let playout = FakePlayout()
        let r = try PassthroughRig(playout: playout)
        r.down(at: ms(1000))
        r.polls(from: ms(1020), to: ms(4000))
        #expect(r.log.opens.isEmpty)
        #expect(r.log.refusals == [.yieldTimeout])
        #expect(playout.ended.count == 1)   // the paused queue resumes
    }

    /// 打开条件 5: speech between press and open refuses ("先等提示音再说"); speech after the open is the point.
    @Test func openCondition5SpokeBeforeCue() throws {
        let r = try PassthroughRig()
        r.down(at: ms(1000))
        r.polls(from: ms(1020), to: ms(1200))
        r.gate.vadSpeechStarted(onset: ms(1150), now: ms(1210))
        r.polls(from: ms(1220), to: ms(2000))
        #expect(r.log.opens.isEmpty)
        #expect(r.log.refusals == [.spokeBeforeOpen])
        #expect(PassthroughRefusal.spokeBeforeOpen.hudText == "先等提示音再说")

        let r2 = try PassthroughRig()
        let open = try #require(r2.pressAndHold(at: ms(1000)))
        r2.polls(from: open + ms(20), to: open + ms(240))
        r2.gate.vadSpeechStarted(onset: open + ms(200), now: open + ms(250))
        r2.polls(from: open + ms(260), to: open + ms(1000))
        #expect(r2.isOpen)
    }

    /// Speech that began before the press and is still going also refuses.
    @Test func openCondition5OngoingSpeech() throws {
        let r = try PassthroughRig()
        r.gate.vadSpeechStarted(onset: ms(900), now: ms(950))
        r.pressAndHold(at: ms(1000), limitMs: 1000)
        #expect(r.log.opens.isEmpty && r.log.refusals == [.spokeBeforeOpen])
    }

    /// An onset before the open that VAD reports after it closes the passthrough.
    @Test func lateOnsetBeforeOpenCloses() throws {
        let r = try PassthroughRig()
        let open = try #require(r.pressAndHold(at: ms(1000)))
        r.gate.vadSpeechStarted(onset: open - ms(5), now: open + ms(40))
        #expect(!r.isOpen)
        #expect(r.log.closes.last?.reason == .spokeBeforeOpen)
    }

    @Test func coldMicStartsTheStreamAndListens100ms() throws {
        let r = try PassthroughRig(micWarm: false)
        r.down(at: ms(1000))
        r.polls(from: ms(1020), to: ms(1400))
        #expect(r.log.items.contains(.startMic))
        r.gate.micStreamStarted(at: ms(1460))
        r.polls(from: ms(1420), to: ms(1540))
        #expect(r.log.opens.isEmpty)
        r.polls(from: ms(1560), to: ms(1600))
        #expect(r.log.opens == [ms(1560)])
    }

    @Test func cuePlaysBeforeOpen() throws {
        let r = try PassthroughRig(cueAudible: true)
        r.down(at: ms(1000))
        r.polls(from: ms(1020), to: ms(1600))
        let cueIndex = try #require(r.log.items.firstIndex(of: .playOpenCue))
        let openIndex = try #require(r.log.items.firstIndex { if case .opened = $0 { true } else { false } })
        #expect(cueIndex < openIndex)
        #expect(r.log.opens == [ms(1460)])   // cue at the 1420 poll, 30 ms, open on the first poll ≥ 1450
        r.up(at: ms(1690))
        #expect(r.log.items.last == .playCloseCue)
    }

    @Test func onlyHardwareEventsOpen() throws {
        let r = try PassthroughRig()
        r.down(at: ms(1000), source: .other)
        r.polls(from: ms(1020), to: ms(2000))
        #expect(r.log.opens.isEmpty)
        r.up(at: ms(2010))
        // ... but a non-HID event closes
        let open = try #require(r.pressAndHold(at: ms(2100)))
        r.send(.keyDown(keyCode: 0x09, isRepeat: false), at: open + ms(50), source: .other)
        #expect(r.log.closes.last?.reason == .otherKey)
        #expect(!r.isOpen)
    }

    /// The recheck right before opening: the poll at the open finds another modifier held.
    @Test func recheckBeforeOpen() throws {
        let r = try PassthroughRig()
        r.down(at: ms(1000))
        r.polls(from: ms(1020), to: ms(1400))
        r.poll(at: ms(1420), KeyStateSnapshot(keysDown: [KeyCode.rightCommand, KeyCode.command], flags: rcmdFlags.union(.deviceLeftCommand)))
        r.polls(from: ms(1440), to: ms(2000))
        #expect(r.log.opens.isEmpty)
        // lost key-up during preparation
        let r2 = try PassthroughRig()
        r2.down(at: ms(1000))
        r2.polls(from: ms(1020), to: ms(1400))
        r2.poll(at: ms(1420), nothingHeld)
        r2.polls(from: ms(1440), to: ms(2000))
        #expect(r2.log.opens.isEmpty)
    }

    // MARK: no pre-roll

    @Test func admitsOnlySamplesInsideTheInterval() throws {
        let r = try PassthroughRig()
        #expect(r.gate.admit(r.block(at: ms(1000), ms: 10), now: ms(1011)) == nil)
        let open = try #require(r.pressAndHold(at: ms(1100)))
        // a block still in ringM from before the open: nothing
        #expect(r.gate.admit(r.block(at: open - ms(15), ms: 10), now: open + ms(1)) == nil)
        // a block across the open: only samples at or after open
        let b = r.block(at: open - ms(5), ms: 10)
        let f = try #require(r.gate.admit(b, now: open + ms(6)))
        #expect(b.sampleTime(f.blockRange.lowerBound) >= open)
        #expect(b.sampleTime(f.blockRange.lowerBound - 1) < open)
        #expect(f.blockRange.upperBound == b.samples.count)
        #expect(f.generation == r.sink.current.generation && f.source == .mic)
        // a block across the close: only samples before it
        r.up(at: open + ms(100))
        let close = try #require(r.log.closes.last?.at)
        #expect(r.gate.admit(r.block(at: close - ms(5), ms: 10), now: close + ms(6)) == nil)   // closed: nothing at all
        #expect(r.gate.lastCloseHostTime == close)
    }

    @Test func blockPastTheLeaseIsCut() throws {
        let r = try PassthroughRig()
        let open = try #require(r.pressAndHold(at: ms(1100)))
        let lease = r.sink.current.leaseUntil
        #expect(lease == open + ms(100))
        let b = r.block(at: open + ms(50), ms: 20, rate: 44_100)
        let f = try #require(r.gate.admit(b, now: open + ms(99)))
        #expect(b.sampleTime(f.blockRange.upperBound - 1) < open + ms(99))
    }

    // MARK: close rules (§3.8 "关闭")

    @Test(arguments: [
        (KeyInputEvent.Kind.flagsChanged(keyCode: KeyCode.rightCommand, flags: []), PassthroughCloseReason.keyReleased),
        (.keyDown(keyCode: 0x08, isRepeat: false), .otherKey),
        (.flagsChanged(keyCode: KeyCode.rightOption, flags: rcmdFlags.union(roptFlags)), .modifierChanged),
        (.flagsChanged(keyCode: KeyCode.capsLock, flags: rcmdFlags.union(.capsLock)), .modifierChanged),
        (.flagsChanged(keyCode: KeyCode.function, flags: rcmdFlags.union(.function)), .modifierChanged),
        (.mouseDown, .mouseButton),
        (.scroll, .scroll),
        (.tapDisabled(.disabledByTimeout), .tapFailed(.disabledByTimeout)),
        (.tapDisabled(.disabledByUserInput), .tapFailed(.disabledByUserInput)),
        (.tapDisabled(.notEnabled), .tapFailed(.notEnabled)),
        (.tapDisabled(.portInvalid), .tapFailed(.portInvalid)),
        (.poll(nothingHeld), .keyReleased),           // HID state runs ahead of the tap: a release
        (.poll(KeyStateSnapshot(keysDown: [KeyCode.rightCommand, KeyCode.shift], flags: rcmdFlags.union([.deviceLeftShift, .shift]))), .otherInputHeld),
        (.poll(KeyStateSnapshot(keysDown: [KeyCode.rightCommand], flags: rcmdFlags, mouseButtonDown: true)), .otherInputHeld),
        (.poll(KeyStateSnapshot(keysDown: [KeyCode.rightCommand], flags: rcmdFlags, secureInput: true)), .secureInput),
    ])
    func keyCloseRules(_ kind: KeyInputEvent.Kind, _ reason: PassthroughCloseReason) throws {
        let r = try PassthroughRig()
        let open = try #require(r.pressAndHold(at: ms(1000)))
        r.polls(from: open + ms(20), to: open + ms(500))
        #expect(r.isOpen)
        let t = open + ms(510)
        r.send(kind, at: t)
        // closed in the same tick, at the event's time
        #expect(!r.isOpen)
        #expect(r.log.closes.map(\.at) == [t])
        #expect(r.log.closes.first?.reason == reason)
        #expect(r.gate.admit(r.block(at: t, ms: 5), now: t + ms(6)) == nil)
        // a new press is needed
        r.polls(from: t + ms(20), to: t + ms(1000))
        #expect(r.log.opens.count == 1)
    }

    /// ⌘⇧4: the 400 ms poll already sees ⇧ held, its flagsChanged lands 5 ms later. Nothing may
    /// show (§3.8: under 400 ms nothing appears): no yield, no mic, no HUD, available or not.
    @Test(arguments: [false, true])
    func pollCheckedBeforeArming(speakerMode: Bool) throws {
        var facts = PassthroughPolicy.Facts.allGood
        facts.speakerMode = speakerMode
        let playout = FakePlayout()
        let r = try PassthroughRig(playout: playout, facts: facts, micWarm: false)
        r.down(at: ms(1000))
        r.polls(from: ms(1020), to: ms(1380))
        let shiftHeld = KeyStateSnapshot(keysDown: [KeyCode.rightCommand, KeyCode.shift], flags: rcmdFlags.union([.deviceLeftShift, .shift]))
        #expect(r.send(.poll(shiftHeld), at: ms(1400)).isEmpty)
        r.send(.flagsChanged(keyCode: KeyCode.shift, flags: rcmdFlags.union([.deviceLeftShift, .shift])), at: ms(1405))
        #expect(r.log.items.isEmpty && playout.requests.isEmpty)
        #expect(r.ctl.machine.prearmCancels == 1)
        // only ⌘, the poll sees it up before the key-up event: a plain tap, nothing either
        let r2 = try PassthroughRig(playout: playout, facts: facts, micWarm: false)
        r2.down(at: ms(1000))
        r2.polls(from: ms(1020), to: ms(1380))
        #expect(r2.send(.poll(nothingHeld), at: ms(1400)).isEmpty)
        r2.up(at: ms(1405))
        #expect(r2.log.items.isEmpty && playout.requests.isEmpty)
        #expect(r2.ctl.machine.prearmCancels == 0 && r2.ctl.machine.lostKeyUps == 0)
    }

    @Test func mouseMovementWhileOpenDoesNotClose() throws {
        let r = try PassthroughRig()
        let open = try #require(r.pressAndHold(at: ms(1000)))
        r.send(.mouseMoved(dx: 200, dy: 100), at: open + ms(30))
        r.polls(from: open + ms(40), to: open + ms(400))
        #expect(r.isOpen)
    }

    @Test(arguments: PassthroughSystemEvent.allCases)
    func systemEventCloses(_ e: PassthroughSystemEvent) throws {
        let r = try PassthroughRig()
        let open = try #require(r.pressAndHold(at: ms(1000)))
        r.polls(from: open + ms(20), to: open + ms(180))
        r.gate.systemEvent(e, at: open + ms(200))
        #expect(!r.isOpen)
        #expect(r.log.closes.first?.reason == .system(e))
        r.polls(from: open + ms(220), to: open + ms(1000))
        #expect(r.log.opens.count == 1)
    }

    @Test(arguments: PassthroughPolicy.Fact.allCases)
    func factTurningBadOrUnknownCloses(_ fact: PassthroughPolicy.Fact) throws {
        for unknown in [true, false] {
            let r = try PassthroughRig()
            let open = try #require(r.pressAndHold(at: ms(1000)))
            r.polls(from: open + ms(20), to: open + ms(80))
            r.gate.updateFacts(at: open + ms(100)) { set(&$0, fact, unknown: unknown) }
            #expect(!r.isOpen, "\(fact)")
            guard case let .unavailable(reason) = r.log.closes.first?.reason else {
                Issue.record("\(fact) did not close as unavailable"); continue
            }
            #expect(.unavailable(reason) == PassthroughPolicy.evaluate(r.gate.facts))
            // turning it good again does not reopen: a new press is needed
            r.gate.updateFacts(at: open + ms(200)) { $0 = .allGood }
            r.polls(from: open + ms(220), to: open + ms(1000))
            #expect(r.log.opens.count == 1)
        }
    }

    @Test func maxHold30sWithCountdown() throws {
        let r = try PassthroughRig()
        let open = try #require(r.pressAndHold(at: ms(1000)))
        r.polls(from: open + ms(20), to: open + ms(31_000))
        let countdowns = r.log.items.compactMap { if case let .countdown(s) = $0 { s } else { nil } }
        #expect(countdowns == [5, 4, 3, 2, 1])
        #expect(r.log.closes.count == 1)
        let close = try #require(r.log.closes.first)
        #expect(close.reason == .maxHold)
        #expect(close.at == open + ms(30_000))
        #expect(r.log.opens.count == 1)
    }

    /// Key thread stalled for 1 s (no polls, no events): the lease closes it within 130 ms.
    @Test func stalledKeyThreadClosesByLease() throws {
        let r = try PassthroughRig()
        let open = try #require(r.pressAndHold(at: ms(1000)))
        r.polls(from: open + ms(20), to: open + ms(300))
        let lastPoll = open + ms(300)
        let stall = lastPoll + ms(7)                        // the thread stops 7 ms after its last poll
        // the worker keeps running: blocks every 5 ms
        var admittedPastLease = false
        var t = stall
        while t < stall + ms(1000) {
            if let f = r.gate.admit(r.block(at: t - ms(5), ms: 5), now: t) {
                if f.firstSampleHostTime >= lastPoll + ms(100) { admittedPastLease = true }
            }
            t += ms(5)
        }
        #expect(!admittedPastLease)
        let close = try #require(r.log.closes.first)
        #expect(close.reason == .leaseExpired)
        #expect(close.at <= stall + ms(130))
        #expect(close.at == lastPoll + ms(100))
        // feedIOProc's own check of the published state agrees
        let live = PassthroughState(open: true, generation: 1, source: .mic, openAt: open, leaseUntil: lastPoll + ms(100),
                                    deadline: open + ms(30_000))
        #expect(!live.admits(blockGeneration: 1, at: stall + ms(130)))
        #expect(live.admits(blockGeneration: 1, at: lastPoll + ms(99)) && !live.admits(blockGeneration: 2, at: lastPoll + ms(99)))
        #expect(r.sink.current.open == false && r.sink.current.leaseUntil == lastPoll + ms(100))
        // the thread resumes with the key still held: no reopen without a fresh press
        r.polls(from: stall + ms(1000), to: stall + ms(2000))
        #expect(r.log.opens.count == 1)
        r.up(at: stall + ms(2010))
        #expect(r.pressAndHold(at: stall + ms(2100)) != nil)
    }

    @Test func tapFailureNeedsReenableAndRelease() throws {
        let r = try PassthroughRig()
        let open = try #require(r.pressAndHold(at: ms(1000)))
        r.send(.tapDisabled(.disabledByTimeout), at: open + ms(100))
        #expect(!r.isOpen)
        r.up(at: open + ms(200))
        r.down(at: open + ms(300))                          // tap still down: does not count
        r.polls(from: open + ms(320), to: open + ms(1000))
        #expect(r.log.opens.count == 1)
        r.send(.tapEnabled, at: open + ms(1010))
        r.polls(from: open + ms(1020), to: open + ms(1500))   // still held since before the enable
        #expect(r.log.opens.count == 1)
        r.up(at: open + ms(1510))
        #expect(r.pressAndHold(at: open + ms(1600)) != nil)
        #expect(r.log.opens.count == 2)
    }

    // MARK: push-to-talk interleavings (§5.2 rule 10)

    @Test func rightCommandWhilePushToTalkHeldDoesNotOpen() throws {
        var f = PassthroughPolicy.Facts.allGood
        f.pushToTalkActive = true
        let r = try PassthroughRig(facts: f)
        r.down(at: ms(1000), extra: roptFlags)
        r.polls(from: ms(1020), to: ms(2000), KeyStateSnapshot(keysDown: [KeyCode.rightCommand, KeyCode.rightOption],
                                                                flags: rcmdFlags.union(roptFlags)))
        #expect(r.log.opens.isEmpty)
        // PTT released, ⌘ still held: still nothing until both are up
        r.send(.flagsChanged(keyCode: KeyCode.rightOption, flags: rcmdFlags), at: ms(2010))
        r.gate.updateFacts(at: ms(2010)) { $0.pushToTalkActive = false }
        r.polls(from: ms(2020), to: ms(3000))
        #expect(r.log.opens.isEmpty)
    }

    @Test func rightOptionWhileOpenClosesAndIsNotPushToTalk() throws {
        let r = try PassthroughRig()
        var p = try PushToTalkMachine(config: .init(speak: TestResources.profile().speak))
        _ = p.handle(KeyInputEvent(time: ms(1000), kind: .tapEnabled))
        let open = try #require(r.pressAndHold(at: ms(1000)))
        r.polls(from: open + ms(20), to: open + ms(280))
        let e = KeyInputEvent(time: open + ms(300), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: rcmdFlags.union(roptFlags)))
        let pttActions = p.handle(e)
        r.ctl.handle(e)
        #expect(!r.isOpen && r.log.closes.first?.reason == .modifierChanged)
        #expect(pttActions.isEmpty && !p.isActive)
    }

    // MARK: source binding (privacy invariants 1, 7)

    @Test func sourceSwitchBumpsGenerationAndBindsChannels() throws {
        let r = try PassthroughRig()
        #expect(PassthroughSource.mic.feedChannel == 1 && PassthroughSource.selfTest.feedChannel == 2)
        let open = try #require(r.pressAndHold(at: ms(1000)))
        let g1 = r.sink.current.generation
        r.gate.setSource(.selfTest, at: open + ms(50))
        #expect(!r.isOpen && r.log.closes.first?.reason == .sourceChanged)
        #expect(r.sink.current.generation == g1 && r.sink.current.leaseUntil == open + ms(50))   // closed at the switch
        // the key path cannot open while the source is the self-test
        r.up(at: open + ms(200))
        r.pressAndHold(at: open + ms(300), limitMs: 1000)
        #expect(r.log.opens.count == 1)
        #expect(r.gate.openSelfTest(at: open + ms(2000), durationMs: 300))
        #expect(r.sink.current.open && r.sink.current.source == .selfTest && r.sink.current.generation == g1 &+ 1)
        let t = open + ms(2100)
        #expect(r.gate.admit(r.block(at: t, ms: 5, origin: .mic), now: t + ms(6)) == nil)   // mic never reaches ch2
        let f = try #require(r.gate.admit(r.block(at: t, ms: 5, origin: .selfTest), now: t + ms(6)))
        #expect(f.source == .selfTest && f.source.feedChannel == 2)
        #expect(r.gate.isOpen(at: open + ms(2300)) == false)          // ends at its lease
        r.gate.setSource(.mic, at: open + ms(2400))
        #expect(r.gate.openSelfTest(at: open + ms(2500), durationMs: 300) == false)   // never on ch1
    }

    /// Setting the source the gate already has is not a switch: an open interval stays open (fuzz
    /// seed 0xd21dcf75d25, where the oracle had counted it as a closer).
    @Test func sameSourceIsNotASwitch() throws {
        let r = try PassthroughRig()
        let open = try #require(r.pressAndHold(at: ms(1000)))
        let g = r.sink.current.generation
        r.gate.setSource(.mic, at: open + ms(4))
        #expect(r.isOpen && r.log.closes.isEmpty && r.sink.current.generation == g)
        r.gate.setSource(.selfTest, at: open + ms(10))
        #expect(!r.isOpen && r.log.closes.map(\.reason) == [.sourceChanged])
    }

    /// MeetingMicGuard's 2 s poll, tap health or PTT state changing while the self-test runs
    /// (its verdict is "self-test running") does not cut the self-test short.
    @Test func factsUpdateLeavesTheSelfTestOpen() throws {
        let r = try PassthroughRig()
        r.gate.setSource(.selfTest, at: ms(1000))
        r.gate.updateFacts(at: ms(1000)) { $0.selfTestRunning = true }
        #expect(r.gate.openSelfTest(at: ms(1100), durationMs: 300))
        r.gate.updateFacts(at: ms(1200)) { $0.micGuard = .green; $0.tapHealthy = false; $0.pushToTalkActive = true }
        #expect(r.isOpen && r.log.closes.isEmpty)
        r.gate.updateFacts(at: ms(1300)) { $0.meetingModeActive = false }
        #expect(r.gate.isOpen(at: ms(1350)))
        r.gate.tick(now: ms(1450))
        #expect(!r.isOpen && r.log.closes.map(\.reason) == [.leaseExpired] && r.log.closes.first?.at == ms(1400))
        // a system event still closes it
        #expect(r.gate.openSelfTest(at: ms(2000), durationMs: 300))
        r.gate.systemEvent(.sleep, at: ms(2100))
        #expect(!r.isOpen && r.log.closes.last?.reason == .system(.sleep))
    }

    @Test func publishedStateOrder() throws {
        let r = try PassthroughRig()
        let open = try #require(r.pressAndHold(at: ms(1000)))
        r.polls(from: open + ms(20), to: open + ms(60))
        r.up(at: open + ms(70))
        let h = r.sink.history
        let opens = h.filter(\.open)
        #expect(opens.count >= 3)                                  // open + renewals
        #expect(Set(opens.map(\.generation)).count == 1)
        let last = try #require(h.last)
        #expect(!last.open && last.generation == opens[0].generation && last.leaseUntil == open + ms(70))
        #expect(last.deadline == open + ms(30_000) && last.openAt == open)
        #expect(zip(opens, opens.dropFirst()).allSatisfy { $0.leaseUntil <= $1.leaseUntil })
    }

    // MARK: dev hook (§14 M2 完成标准)

    #if TALKTALK_DEV
    /// ≥ 170 injected ⌘ shortcuts, the second input 0–390 ms after the press: 0 opens.
    @Test func injectedShortcutsNeverOpen() throws {
        let hook = PassthroughKeyMachine.DevInjection(benchMode: true, otherTalkTalkMicReaders: 0)
        let seconds: [KeyInputEvent.Kind] = [
            .keyDown(keyCode: 0x08, isRepeat: false), .keyDown(keyCode: 0x09, isRepeat: false),   // ⌘C ⌘V
            .keyDown(keyCode: 0x30, isRepeat: false), .keyDown(keyCode: 0x31, isRepeat: false),   // ⌘Tab ⌘Space
            .mouseDown,                                                                           // ⌘-click
        ]
        var rng = PTSplitMix64(seed: 170)
        var cases = 0
        let r = try PassthroughRig()
        var t = ms(2000)
        for i in 0..<200 {
            let at = Int.random(in: 0...390, using: &rng)
            let delivery = Int.random(in: 0...20, using: &rng)
            r.ctl.inject(KeyInputEvent(time: t, kind: .flagsChanged(keyCode: KeyCode.rightCommand, flags: rcmdFlags)), hook)
            var p = t + ms(20)
            let secondAt = t + ms(at + delivery)
            var sentSecond = false
            while p <= t + ms(1200) {
                if !sentSecond && secondAt <= p {
                    r.ctl.inject(KeyInputEvent(time: secondAt, kind: seconds[i % seconds.count]), hook)
                    sentSecond = true
                }
                // the hardware state shows the second key/button from its physical time on
                let physicallyDown = p >= t + ms(at)
                let snap = KeyStateSnapshot(keysDown: physicallyDown && i % 5 != 4 ? [KeyCode.rightCommand, 0x08] : [KeyCode.rightCommand],
                                            flags: rcmdFlags, mouseButtonDown: physicallyDown && i % 5 == 4)
                r.ctl.inject(KeyInputEvent(time: p, kind: .poll(snap)), hook)
                p += ms(20)
            }
            r.ctl.inject(KeyInputEvent(time: p, kind: .flagsChanged(keyCode: KeyCode.rightCommand, flags: [])), hook)
            r.ctl.inject(KeyInputEvent(time: p + ms(20), kind: .poll(nothingHeld)), hook)
            cases += 1
            t = p + ms(300)
        }
        #expect(cases >= 170)
        #expect(r.log.opens.isEmpty)
    }

    /// ≥ 50 "pressed right ⌘ thinking it was right ⌥ and started talking": 0 opens.
    @Test func pressAndSpeakImmediatelyNeverOpens() throws {
        let hook = PassthroughKeyMachine.DevInjection(benchMode: true, otherTalkTalkMicReaders: 0)
        var rng = PTSplitMix64(seed: 50)
        let r = try PassthroughRig()
        var t = ms(2000)
        for _ in 0..<60 {
            let onset = Int.random(in: 0...350, using: &rng)
            let report = Int.random(in: 20...60, using: &rng)       // VAD latency
            r.ctl.inject(KeyInputEvent(time: t, kind: .flagsChanged(keyCode: KeyCode.rightCommand, flags: rcmdFlags)), hook)
            var p = t + ms(20)
            var reported = false
            while p <= t + ms(1500) {
                if !reported && t + ms(onset + report) <= p {
                    r.gate.vadSpeechStarted(onset: t + ms(onset), now: t + ms(onset + report))
                    reported = true
                }
                r.ctl.inject(KeyInputEvent(time: p, kind: .poll(heldRightCommand)), hook)
                p += ms(20)
            }
            r.gate.vadSpeechEnded(at: p)
            r.ctl.inject(KeyInputEvent(time: p, kind: .flagsChanged(keyCode: KeyCode.rightCommand, flags: [])), hook)
            t = p + ms(500)
        }
        #expect(r.log.opens.isEmpty)
        #expect(r.log.refusals.count == 60 && r.log.refusals.allSatisfy { $0 == .spokeBeforeOpen })
    }

    /// Held 400 ms and open, then a second key: closed in the same tick, nothing admitted after.
    @Test func secondKeyAfterOpenClosesSameTick() throws {
        let hook = PassthroughKeyMachine.DevInjection(benchMode: true, otherTalkTalkMicReaders: 0)
        let r = try PassthroughRig()
        r.ctl.inject(KeyInputEvent(time: ms(1000), kind: .flagsChanged(keyCode: KeyCode.rightCommand, flags: rcmdFlags)), hook)
        var p = ms(1020)
        while !r.isOpen { r.ctl.inject(KeyInputEvent(time: p, kind: .poll(heldRightCommand)), hook); p += ms(20) }
        let second = p + ms(3)
        r.ctl.inject(KeyInputEvent(time: second, kind: .keyDown(keyCode: 0x08, isRepeat: false)), hook)
        #expect(!r.isOpen)
        #expect(r.log.closes.first?.at == second)
    }

    /// Without bench mode, or with another TalkTalk Mic reader, injected events cannot open.
    @Test func hookCannotOpenOutsideBench() throws {
        for hook in [PassthroughKeyMachine.DevInjection(benchMode: false, otherTalkTalkMicReaders: 0),
                     PassthroughKeyMachine.DevInjection(benchMode: true, otherTalkTalkMicReaders: 1)] {
            let r = try PassthroughRig()
            r.ctl.inject(KeyInputEvent(time: ms(1000), kind: .flagsChanged(keyCode: KeyCode.rightCommand, flags: rcmdFlags)), hook)
            var p = ms(1020)
            while p < ms(2000) { r.ctl.inject(KeyInputEvent(time: p, kind: .poll(heldRightCommand)), hook); p += ms(20) }
            #expect(r.log.opens.isEmpty)
        }
    }
    #endif
}

/// Make one fact unknown or bad.
func set(_ f: inout PassthroughPolicy.Facts, _ fact: PassthroughPolicy.Fact, unknown: Bool) {
    switch fact {
    case .meetingModeActive: f.meetingModeActive = unknown ? nil : false
    case .settingEnabled: f.settingEnabled = unknown ? nil : false
    case .micGuard: f.micGuard = unknown ? nil : .meetingUsesPhysicalMic
    case .speakerMode: f.speakerMode = unknown ? nil : true
    case .tapHealthy: f.tapHealthy = unknown ? nil : false
    case .awaitingAudioConfirmation: f.awaitingAudioConfirmation = unknown ? nil : true
    case .secureInput: f.secureInput = unknown ? nil : true
    case .pushToTalkActive: f.pushToTalkActive = unknown ? nil : true
    case .selfTestRunning: f.selfTestRunning = unknown ? nil : true
    case .physicalMicPassesRule2: f.physicalMicPassesRule2 = unknown ? nil : false
    }
}
