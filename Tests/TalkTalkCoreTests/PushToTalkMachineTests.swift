import Testing
@testable import TalkTalkCore

/// File-private like the other suites' helpers (an internal one would clash with theirs).
private func ms(_ v: Int) -> HostTime { HostTime(v) * 1_000_000 }

@Suite struct PushToTalkMachineTests {
    func machine() throws -> PushToTalkMachine {
        var m = PushToTalkMachine(config: .init(speak: try TestResources.profile().speak))
        _ = m.handle(KeyInputEvent(time: ms(100), kind: .tapEnabled))
        return m
    }
    func down(_ t: HostTime, extra: ModifierFlags = []) -> KeyInputEvent {
        KeyInputEvent(time: t, kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: roptFlags.union(extra)))
    }
    func up(_ t: HostTime) -> KeyInputEvent { KeyInputEvent(time: t, kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: [])) }

    @Test func configFromProfile() throws {
        let c = PushToTalkMachine.Config(speak: try TestResources.profile().speak)
        #expect(c.key == .rightOption && c.minHoldMs == 150 && c.maxHoldS == 60 && c.chordCancelWindowMs == 400)
        #expect(c.chordCancelOnlyBeforeFirstCommit && c.doubleTapMaxPressMs == 150 && c.doubleTapMaxGapMs == 300)
    }

    /// holdGapMaxMs is speak.passthrough.leaseMs (PTT has no field of its own): a profile with a
    /// lease other than the 100 ms default sets how long a poll-seen release waits for its key-up.
    @Test func holdGapFromThePassthroughLease() throws {
        var speak = try TestResources.profile().speak
        speak.passthrough.leaseMs = 160
        var m = PushToTalkMachine(config: .init(speak: speak))
        #expect(m.config.holdGapMaxMs == 160)
        _ = m.handle(KeyInputEvent(time: ms(100), kind: .tapEnabled))
        #expect(m.handle(down(ms(1000))) == [.began(at: ms(1000))])
        #expect(m.handle(KeyInputEvent(time: ms(1500), kind: .poll(nothingHeld))).isEmpty)   // tentative
        #expect(m.tick(now: ms(1660)).isEmpty)                      // 160 ms, not 100
        #expect(m.isActive)
        #expect(m.tick(now: ms(1661)) == [.released(at: ms(1500), reason: .lostKeyUp)])
    }

    @Test func pressAndRelease() throws {
        var m = try machine()
        #expect(m.handle(down(ms(1000))) == [.began(at: ms(1000))])
        #expect(m.isActive)
        #expect(m.handle(up(ms(2000))) == [.released(at: ms(2000), reason: .keyUp)])
        #expect(!m.isActive)
    }

    @Test func notCleanWhenRightCommandHeld() throws {
        var m = try machine()
        #expect(m.handle(down(ms(1000), extra: rcmdFlags)).isEmpty)
        #expect(m.handle(up(ms(1500))).isEmpty)                  // still must see everything up
        #expect(m.handle(down(ms(1600))) == [.began(at: ms(1600))])
    }

    @Test func chordInsideWindowBeforeCommitCancels() throws {
        var m = try machine()
        _ = m.handle(down(ms(1000)))
        #expect(m.handle(KeyInputEvent(time: ms(1399), kind: .keyDown(keyCode: 0x08, isRepeat: false))) == [.cancelled(at: ms(1399))])
        #expect(m.handle(up(ms(1500))).isEmpty)
    }

    @Test func chordAfterWindowOrCommitIsARelease() throws {
        var m = try machine()
        _ = m.handle(down(ms(1000)))
        #expect(m.handle(KeyInputEvent(time: ms(1400), kind: .keyDown(keyCode: 0x08, isRepeat: false)))
            == [.released(at: ms(1400), reason: .chord)])
        var m2 = try machine()
        _ = m2.handle(down(ms(1000)))
        m2.didCommit()
        #expect(m2.handle(KeyInputEvent(time: ms(1200), kind: .flagsChanged(keyCode: KeyCode.shift, flags: roptFlags.union([.deviceLeftShift, .shift]))))
            == [.released(at: ms(1200), reason: .chord)])
    }

    @Test func tapAndDoubleTap() throws {
        var m = try machine()
        _ = m.handle(down(ms(1000)))
        #expect(m.handle(up(ms(1100))) == [.tapped(at: ms(1100))])
        _ = m.handle(down(ms(1350)))                                 // 250 ms gap
        #expect(m.handle(up(ms(1450))) == [.doubleTapped(at: ms(1450))])
        // a third tap starts over
        _ = m.handle(down(ms(1600)))
        #expect(m.handle(up(ms(1700))) == [.tapped(at: ms(1700))])
    }

    @Test func pressWithSpeechIsNotATap() throws {
        var m = try machine()
        _ = m.handle(down(ms(1000)))
        m.vad(speech: true, at: ms(1050))
        #expect(m.handle(up(ms(1100))) == [.released(at: ms(1100), reason: .keyUp)])
    }

    @Test func maxHoldAndLostKeyUp() throws {
        var m = try machine()
        _ = m.handle(down(ms(1000)))
        #expect(m.tick(now: ms(61_000)) == [.released(at: ms(61_000), reason: .maxHold)])
        #expect(m.handle(down(ms(61_100))).isEmpty)                // must be seen up first
        _ = m.handle(KeyInputEvent(time: ms(61_200), kind: .poll(nothingHeld)))
        #expect(m.handle(down(ms(61_300))) == [.began(at: ms(61_300))])
        #expect(m.handle(KeyInputEvent(time: ms(61_500), kind: .poll(nothingHeld))).isEmpty)   // tentative
        #expect(m.isActive)
        #expect(m.tick(now: ms(61_600)).isEmpty)                    // still within holdGapMaxMs
        #expect(m.tick(now: ms(61_601)) == [.released(at: ms(61_500), reason: .lostKeyUp)])
        #expect(!m.isActive)
        // a short press whose key-up never comes is still a tap, timed at the poll
        _ = m.handle(down(ms(62_000)))
        _ = m.handle(KeyInputEvent(time: ms(62_080), kind: .poll(nothingHeld)))
        #expect(m.tick(now: ms(62_181)) == [.tapped(at: ms(62_080))])
    }

    /// The poll reads HID state, ahead of the tap: it sees right ⌥ up before the key-up event.
    /// That is the release, so a tap is still a tap and the late key-up does nothing.
    @Test func pollAheadOfKeyUpIsTheRelease() throws {
        var m = try machine()
        _ = m.handle(down(ms(1000)))
        #expect(m.handle(KeyInputEvent(time: ms(1105), kind: .poll(nothingHeld))).isEmpty)
        #expect(m.handle(up(ms(1108))) == [.tapped(at: ms(1105))])
        _ = m.handle(down(ms(1300)))
        #expect(m.handle(KeyInputEvent(time: ms(1390), kind: .poll(nothingHeld))).isEmpty)
        #expect(m.handle(up(ms(1395))) == [.doubleTapped(at: ms(1390))])
        // a held press seen up by the poll first is a release (rule 6), not a tap
        _ = m.handle(down(ms(3000)))
        #expect(m.handle(KeyInputEvent(time: ms(3400), kind: .poll(nothingHeld))).isEmpty)
        #expect(m.handle(up(ms(3404))) == [.released(at: ms(3400), reason: .keyUp)])
        #expect(m.handle(down(ms(3500))) == [.began(at: ms(3500))])
    }

    /// Caps lock on (its key code may read as "down" in the poll) and fn's key code are not chords.
    @Test func capsLockAndFnKeyCodesAreNotChords() throws {
        var m = try machine()
        let caps = KeyStateSnapshot(keysDown: [KeyCode.rightOption, KeyCode.capsLock, KeyCode.function],
                                    flags: roptFlags.union(.capsLock))
        #expect(m.handle(down(ms(1000), extra: .capsLock)) == [.began(at: ms(1000))])
        for t in stride(from: 1020, through: 1500, by: 20) {
            #expect(m.handle(KeyInputEvent(time: ms(t), kind: .poll(caps))).isEmpty)
        }
        #expect(m.isActive)
        #expect(m.handle(KeyInputEvent(time: ms(1600), kind: .flagsChanged(keyCode: KeyCode.rightOption, flags: .capsLock)))
            == [.released(at: ms(1600), reason: .keyUp)])
        // a held fn still shows in the flags and is a chord
        _ = m.handle(down(ms(2000)))
        let fnHeld = KeyStateSnapshot(keysDown: [KeyCode.rightOption, KeyCode.function], flags: roptFlags.union(.function))
        #expect(m.handle(KeyInputEvent(time: ms(2100), kind: .poll(fnHeld))) == [.cancelled(at: ms(2100))])
    }

    /// The deadline settles a poll-seen release before a late chord event is handled: that may be
    /// a tap, never a double tap (the hard interrupt needs a real key-up).
    @Test func deadlineSettleNeverDoubleTaps() throws {
        var m = try machine()
        _ = m.handle(down(ms(700)))
        #expect(m.handle(up(ms(780))) == [.tapped(at: ms(780))])
        _ = m.handle(down(ms(1000)))
        #expect(m.handle(KeyInputEvent(time: ms(1090), kind: .poll(nothingHeld))).isEmpty)
        #expect(m.handle(KeyInputEvent(time: ms(1195), kind: .keyDown(keyCode: 0x08, isRepeat: false))) == [.tapped(at: ms(1090))])
    }

    /// A quick right ⌥ chord: the poll sees ⌥ up, the chord's events are still in flight. They
    /// land before the key-up and cancel the press; no tap, so no hard interrupt.
    @Test func chordBehindAPollSeenReleaseIsNotATap() throws {
        var m = try machine()
        _ = m.handle(down(ms(700)))
        #expect(m.handle(up(ms(780))) == [.tapped(at: ms(780))])         // a real first tap
        _ = m.handle(down(ms(1000)))
        #expect(m.handle(KeyInputEvent(time: ms(1090), kind: .poll(nothingHeld))).isEmpty)
        #expect(m.handle(KeyInputEvent(time: ms(1092), kind: .keyDown(keyCode: 0x08, isRepeat: false))) == [.cancelled(at: ms(1092))])
        #expect(m.handle(KeyInputEvent(time: ms(1093), kind: .keyUp(keyCode: 0x08))).isEmpty)
        #expect(m.handle(up(ms(1095))).isEmpty)
        #expect(m.phase == .idle)
        // a poll that still sees the other key held is a chord at once
        _ = m.handle(down(ms(2000)))
        let cHeld = KeyStateSnapshot(keysDown: [0x08], flags: [])
        #expect(m.handle(KeyInputEvent(time: ms(2090), kind: .poll(cHeld))) == [.cancelled(at: ms(2090))])
        // and so does another modifier in the poll's flags, with right ⌥ still down
        var m2 = try machine()
        _ = m2.handle(down(ms(1000)))
        let shift = KeyStateSnapshot(keysDown: [KeyCode.rightOption, KeyCode.shift], flags: roptFlags.union([.deviceLeftShift, .shift]))
        #expect(m2.handle(KeyInputEvent(time: ms(1500), kind: .poll(shift))) == [.released(at: ms(1500), reason: .chord)])
    }

    /// Property: with the poll arriving 0–10 ms ahead of the key-up event, two short presses with
    /// a gap ≤ 280 ms are a tap then a double tap, and a press ≥ 160 ms is a release.
    @Test func pollAheadOfKeyUpProperty() throws {
        let cfg = try machine().config
        for seed in 0..<1000 {
            var rng = PTSplitMix64(seed: UInt64(seed) &+ 0x5054_5450)
            var m = try machine()
            var t = ms(1000)
            var log: [PushToTalkMachine.Action] = []
            func press(_ hold: Int) {
                log += m.handle(down(t))
                let upAt = t + ms(hold)
                let lead = Int.random(in: 0...10, using: &rng)
                if Bool.random(using: &rng) { log += m.handle(KeyInputEvent(time: upAt - ms(lead), kind: .poll(nothingHeld))) }
                log += m.handle(up(upAt))
                t = upAt
            }
            press(Int.random(in: 20...(cfg.doubleTapMaxPressMs - 10), using: &rng))
            t += ms(Int.random(in: 20...(cfg.doubleTapMaxGapMs - 20), using: &rng))
            press(Int.random(in: 20...(cfg.doubleTapMaxPressMs - 10), using: &rng))
            t += ms(Int.random(in: 400...800, using: &rng))
            press(Int.random(in: (cfg.minHoldMs + 10)...2000, using: &rng))
            let kinds = log.map { a -> String in
                switch a {
                case .began: "began"
                case .tapped: "tap"
                case .doubleTapped: "double"
                case .released: "released"
                case .cancelled: "cancelled"
                }
            }
            #expect(kinds == ["began", "tap", "began", "double", "began", "released"], "seed \(seed): \(log)")
        }
    }

    @Test func tapFailureReleases() throws {
        var m = try machine()
        _ = m.handle(down(ms(1000)))
        #expect(m.handle(KeyInputEvent(time: ms(1500), kind: .tapDisabled(.disabledByTimeout)))
            == [.released(at: ms(1500), reason: .tapFailed(.disabledByTimeout))])
        _ = m.handle(KeyInputEvent(time: ms(1600), kind: .poll(nothingHeld)))
        #expect(m.handle(down(ms(1700))).isEmpty)                  // tap still disabled
        _ = m.handle(KeyInputEvent(time: ms(1800), kind: .tapEnabled))
        _ = m.handle(KeyInputEvent(time: ms(1820), kind: .poll(nothingHeld)))
        #expect(m.handle(down(ms(1900))) == [.began(at: ms(1900))])
    }

    /// Property test over random re-press timings (§5.2 rule 9, §14 "PTT 重按时序属性测试").
    @Test func properties() throws {
        let cfg = try machine().config
        for seed in 0..<2000 {
            var rng = PTSplitMix64(seed: UInt64(seed))
            var m = try machine()
            var t = ms(1000)
            var log: [(t: HostTime, a: PushToTalkMachine.Action)] = []
            for _ in 0..<40 {
                let gap = Int.random(in: 0...600, using: &rng)
                t += ms(gap)
                let hold = [Int.random(in: 10...149, using: &rng), Int.random(in: 150...2000, using: &rng),
                            Int.random(in: 100...200, using: &rng)][Int.random(in: 0...2, using: &rng)]
                let spoke = Bool.random(using: &rng) && Bool.random(using: &rng)
                let chordAt: Int? = Int.random(in: 0...3, using: &rng) == 0 ? Int.random(in: 0...hold, using: &rng) : nil
                let commitAt: Int? = Bool.random(using: &rng) ? Int.random(in: 0...hold, using: &rng) : nil
                let loseUp = Int.random(in: 0...9, using: &rng) == 0
                func run(_ e: KeyInputEvent) {
                    for a in m.handle(e) { log.append((e.time, a)) }
                }
                run(down(t))
                var sub: [(Int, Int)] = []    // (offset, kind) 0 chord, 1 commit, 2 vad
                if let c = chordAt { sub.append((c, 0)) }
                if let c = commitAt { sub.append((c, 1)) }
                if spoke { sub.append((Int.random(in: 0...hold, using: &rng), 2)) }
                for (off, kind) in sub.sorted(by: { $0.0 < $1.0 }) {
                    let at = t + ms(off)
                    switch kind {
                    case 0: run(KeyInputEvent(time: at, kind: .keyDown(keyCode: 0x08, isRepeat: false)))
                            run(KeyInputEvent(time: at + 1, kind: .keyUp(keyCode: 0x08)))
                    case 1: m.didCommit()
                    default: m.vad(speech: true, at: at)
                    }
                }
                let upAt = t + ms(hold)
                if !loseUp { run(up(upAt)) }
                m.vad(speech: false, at: upAt)
                run(KeyInputEvent(time: upAt + ms(20), kind: .poll(nothingHeld)))
                t = upAt + ms(20)
            }
            // the poll keeps running while the machine is not idle: a tentative release settles
            for a in m.tick(now: t + ms(200)) { log.append((t + ms(200), a)) }
            // P1: every began is followed by exactly one terminal action before the next began
            var open: HostTime?
            for (_, a) in log {
                switch a {
                case let .began(at):
                    #expect(open == nil, "seed \(seed): began while active")
                    open = at
                case let .released(at, _), let .cancelled(at), let .tapped(at), let .doubleTapped(at):
                    let b = try #require(open, "seed \(seed): terminal without began")
                    #expect(at >= b)
                    #expect(at - b <= ms(cfg.maxHoldS * 1000 + 20))   // P2: never past 60 s (+ one poll)
                    if case .tapped = a { #expect(at - b < ms(cfg.minHoldMs)) }
                    if case .doubleTapped = a { #expect(at - b < ms(cfg.doubleTapMaxPressMs)) }
                    if case .cancelled = a { #expect(at - b < ms(cfg.chordCancelWindowMs)) }
                    open = nil
                }
            }
            #expect(open == nil, "seed \(seed): left active")
            // P3: a double tap's first half is a tap that ended ≤ 300 ms before the second press
            for (i, (_, a)) in log.enumerated() {
                guard case .doubleTapped = a else { continue }
                let before = log[..<i]
                guard let secondBegan = before.last(where: { if case .began = $0.a { true } else { false } }),
                      let firstTap = before.last(where: { if case .tapped = $0.a { true } else { false } }) else {
                    Issue.record("seed \(seed): double tap without a preceding tap"); continue
                }
                #expect(secondBegan.t >= firstTap.t && secondBegan.t - firstTap.t <= ms(cfg.doubleTapMaxGapMs))
                // nothing but the second press between the first tap and the double tap
                let between = log[..<i].filter { $0.t > firstTap.t }
                #expect(between.count == 1, "seed \(seed)")
            }
        }
    }
}
