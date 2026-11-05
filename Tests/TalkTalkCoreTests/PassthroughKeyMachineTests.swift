import Testing
@testable import TalkTalkCore

/// File-private like the other suites' helpers (an internal one would clash with theirs).
private func ms(_ v: Int) -> HostTime { HostTime(v) * 1_000_000 }

@Suite struct PassthroughKeyMachineTests {
    func machine(altKey: Bool = false, intervals: Bool = false) throws -> PassthroughKeyMachine {
        let p = try TestResources.profile().speak.passthrough
        var m = PassthroughKeyMachine(config: try #require(.init(profile: p, useAltKey: altKey, recordsIntervals: intervals)))
        _ = m.handle(KeyInputEvent(time: ms(100), kind: .tapEnabled))
        return m
    }

    /// The 20 ms poll KeyTap runs while the key is held, over [from, to]; returns every action.
    @discardableResult
    func polls(_ m: inout PassthroughKeyMachine, from: Int, to: Int, _ s: KeyStateSnapshot = heldRightCommand) -> [PassthroughKeyMachine.Action] {
        stride(from: from, through: to, by: 20).flatMap { m.handle(KeyInputEvent(time: ms($0), kind: .poll(s))) }
    }

    @Test func configFromProfile() throws {
        let p = try TestResources.profile().speak.passthrough
        let c = try #require(PassthroughKeyMachine.Config(profile: p))
        #expect(c.key == .rightCommand && c.key.keyCode == 0x36 && c.key.deviceBit.rawValue == 0x10)
        #expect(c.armHoldMs == 400 && c.maxHoldS == 30 && c.countdownS == 5 && c.requireHidSource && c.mouseMoveMaxPt == 10)
        #expect(c.holdGapMaxMs == 100)
        var other = p
        other.leaseMs = 160                                          // read from the profile, not a default
        #expect(PassthroughKeyMachine.Config(profile: other)?.holdGapMaxMs == 160)
        let alt = try #require(PassthroughKeyMachine.Config(profile: p, useAltKey: true))
        #expect(alt.key == .rightControl && alt.key.keyCode == 0x3E && alt.key.deviceBit.rawValue == 0x2000)
    }

    @Test func armsAfterHoldThenWaitsForTheGate() throws {
        var m = try machine()
        #expect(m.handle(KeyInputEvent(time: ms(1000), kind: .flagsChanged(keyCode: 0x36, flags: rcmdFlags))).isEmpty)
        #expect(polls(&m, from: 1020, to: 1380).isEmpty)
        #expect(m.handle(KeyInputEvent(time: ms(1400), kind: .poll(heldRightCommand)))
            == [.arm(pressedAt: ms(1000), armedAt: ms(1400)), .held(at: ms(1400))])
        #expect(m.handle(KeyInputEvent(time: ms(1420), kind: .poll(heldRightCommand))) == [.held(at: ms(1420))])
        m.gateOpened(at: ms(1420))
        #expect(m.handle(KeyInputEvent(time: ms(1440), kind: .poll(heldRightCommand))) == [.renew(at: ms(1440))])
        #expect(m.handle(KeyInputEvent(time: ms(1500), kind: .flagsChanged(keyCode: 0x36, flags: [])))
            == [.close(at: ms(1500), reason: .keyReleased)])
        #expect(m.phase == .idle)
    }

    @Test func rightControlVariant() throws {
        var m = try machine(altKey: true)
        let rctl: ModifierFlags = [.deviceRightControl, .control]
        _ = m.handle(KeyInputEvent(time: ms(1000), kind: .flagsChanged(keyCode: 0x3E, flags: rctl)))
        let snap = KeyStateSnapshot(keysDown: [0x3E], flags: rctl)
        #expect(polls(&m, from: 1020, to: 1380, snap).isEmpty)
        #expect(m.handle(KeyInputEvent(time: ms(1400), kind: .poll(snap))).first == .arm(pressedAt: ms(1000), armedAt: ms(1400)))
        // right ⌘ is just another modifier for this machine
        var m2 = try machine(altKey: true)
        _ = m2.handle(KeyInputEvent(time: ms(1000), kind: .flagsChanged(keyCode: 0x36, flags: rcmdFlags)))
        #expect(polls(&m2, from: 1020, to: 1400).isEmpty)
    }

    /// A second "down" means a key-up was lost: the hold restarts from it, and an open press closes.
    @Test func duplicateKeyDownRestartsTheHold() throws {
        var m = try machine()
        _ = m.handle(KeyInputEvent(time: ms(1000), kind: .flagsChanged(keyCode: 0x36, flags: rcmdFlags)))
        #expect(polls(&m, from: 1020, to: 1190).isEmpty)
        #expect(m.handle(KeyInputEvent(time: ms(1200), kind: .flagsChanged(keyCode: 0x36, flags: rcmdFlags))).isEmpty)
        #expect(polls(&m, from: 1210, to: 1590).isEmpty)
        #expect(m.handle(KeyInputEvent(time: ms(1600), kind: .poll(heldRightCommand))).first == .arm(pressedAt: ms(1200), armedAt: ms(1600)))
        m.gateOpened(at: ms(1620))
        polls(&m, from: 1620, to: 1690)
        #expect(m.handle(KeyInputEvent(time: ms(1700), kind: .flagsChanged(keyCode: 0x36, flags: rcmdFlags)))
            == [.close(at: ms(1700), reason: .lostKeyUp)])
        #expect(m.phase == .pressed(downAt: ms(1700), moved: 0))
    }

    @Test func intervalHistogramRecordsOnlyTheGap() throws {
        var m = try machine(intervals: true)
        for (i, gap) in [120, 250, 390, 600].enumerated() {
            let t = ms(2000 * (i + 1))
            _ = m.handle(KeyInputEvent(time: t, kind: .flagsChanged(keyCode: 0x36, flags: rcmdFlags)))
            let t0 = 2000 * (i + 1)
            polls(&m, from: t0 + 20, to: t0 + gap - 1)
            _ = m.handle(KeyInputEvent(time: t + ms(gap), kind: .keyDown(keyCode: 0x08, isRepeat: false)))
            _ = m.handle(KeyInputEvent(time: t + ms(gap + 50), kind: .keyUp(keyCode: 0x08)))
            _ = m.handle(KeyInputEvent(time: t + ms(gap + 80), kind: .flagsChanged(keyCode: 0x36, flags: [])))
        }
        // a plain ⌘ tap (release is not a "next input") records nothing
        _ = m.handle(KeyInputEvent(time: ms(20_000), kind: .flagsChanged(keyCode: 0x36, flags: rcmdFlags)))
        _ = m.handle(KeyInputEvent(time: ms(20_100), kind: .flagsChanged(keyCode: 0x36, flags: [])))
        #expect(m.intervals.total == 4)
        #expect(m.intervals.counts[12] == 1 && m.intervals.counts[25] == 1 && m.intervals.counts[39] == 1 && m.intervals.counts[60] == 1)
        #expect(m.intervals.quantileUpperMs(0.5) == 260)
        #expect(m.prearmCancels == 3)                      // the 600 ms one armed first
        // off by default
        var off = try machine()
        _ = off.handle(KeyInputEvent(time: ms(1000), kind: .flagsChanged(keyCode: 0x36, flags: rcmdFlags)))
        _ = off.handle(KeyInputEvent(time: ms(1100), kind: .keyDown(keyCode: 0x08, isRepeat: false)))
        #expect(off.intervals.total == 0)
    }

    /// A key thread that goes quiet for more than the lease during a hold: the hold was not
    /// observed (a release and re-press could have been missed), so it does not open.
    @Test func unobservedGapEndsTheHold() throws {
        var m = try machine()
        _ = m.handle(KeyInputEvent(time: ms(1000), kind: .flagsChanged(keyCode: 0x36, flags: rcmdFlags)))
        polls(&m, from: 1020, to: 1200)
        #expect(polls(&m, from: 1400, to: 2000).isEmpty)                    // 200 ms gap before arming
        #expect(m.phase == .mustRelease(released: false))
        // armed, then a stall: the gate's preparation is called off
        var a = try machine()
        _ = a.handle(KeyInputEvent(time: ms(1000), kind: .flagsChanged(keyCode: 0x36, flags: rcmdFlags)))
        #expect(polls(&a, from: 1020, to: 1400).first == .arm(pressedAt: ms(1000), armedAt: ms(1400)))
        #expect(a.handle(KeyInputEvent(time: ms(1650), kind: .poll(heldRightCommand))) == [.close(at: ms(1650), reason: .leaseExpired)])
        #expect(a.phase == .mustRelease(released: false))
        _ = a.handle(KeyInputEvent(time: ms(1700), kind: .flagsChanged(keyCode: 0x36, flags: [])))
        #expect(a.phase == .idle)
        // exactly the limit is still observed
        var b = try machine()
        _ = b.handle(KeyInputEvent(time: ms(1000), kind: .flagsChanged(keyCode: 0x36, flags: rcmdFlags)))
        #expect(polls(&b, from: 1100, to: 1400).first == .arm(pressedAt: ms(1000), armedAt: ms(1400)))
    }

    /// A poll that sees the key up first is a normal release; only a key-up that never follows
    /// (or a new down before it) counts as lost (§15 risk 20).
    @Test func pollSeenReleaseIsKeyReleased() throws {
        func openMachine() throws -> PassthroughKeyMachine {
            var m = try machine()
            _ = m.handle(KeyInputEvent(time: ms(1000), kind: .flagsChanged(keyCode: 0x36, flags: rcmdFlags)))
            polls(&m, from: 1020, to: 1420)
            m.gateOpened(at: ms(1420))
            polls(&m, from: 1440, to: 1500)
            return m
        }
        var a = try openMachine()
        #expect(a.handle(KeyInputEvent(time: ms(1510), kind: .poll(nothingHeld))) == [.close(at: ms(1510), reason: .keyReleased)])
        #expect(a.handle(KeyInputEvent(time: ms(1513), kind: .flagsChanged(keyCode: 0x36, flags: []))).isEmpty)
        _ = a.tick(now: ms(2000))
        #expect(a.lostKeyUps == 0 && a.phase == .idle)
        // the key-up never comes
        var b = try openMachine()
        _ = b.handle(KeyInputEvent(time: ms(1510), kind: .poll(nothingHeld)))
        _ = b.tick(now: ms(1600))
        #expect(b.lostKeyUps == 0)
        _ = b.tick(now: ms(1620))
        #expect(b.lostKeyUps == 1)
        // the next down arrives before any key-up
        var c = try openMachine()
        _ = c.handle(KeyInputEvent(time: ms(1510), kind: .poll(nothingHeld)))
        _ = c.handle(KeyInputEvent(time: ms(1550), kind: .flagsChanged(keyCode: 0x36, flags: rcmdFlags)))
        #expect(c.lostKeyUps == 1 && c.phase == .pressed(downAt: ms(1550), moved: 0))
        // a duplicate down while held counts too
        var d = try openMachine()
        _ = d.handle(KeyInputEvent(time: ms(1510), kind: .flagsChanged(keyCode: 0x36, flags: rcmdFlags)))
        #expect(d.lostKeyUps == 1)
    }

    /// Caps lock on: its key code may read as "down" in the poll; the hold is still clean.
    @Test func capsLockDoesNotBreakTheHold() throws {
        var m = try machine()
        let flags = rcmdFlags.union(.capsLock)
        _ = m.handle(KeyInputEvent(time: ms(1000), kind: .flagsChanged(keyCode: 0x36, flags: flags)))
        let snap = KeyStateSnapshot(keysDown: [KeyCode.rightCommand, KeyCode.capsLock], flags: flags)
        #expect(polls(&m, from: 1020, to: 1400, snap).first == .arm(pressedAt: ms(1000), armedAt: ms(1400)))
    }

    @Test func nothingArmsBeforeTheTapIsEnabled() throws {
        let p = try TestResources.profile().speak.passthrough
        var m = PassthroughKeyMachine(config: try #require(.init(profile: p)))
        _ = m.handle(KeyInputEvent(time: ms(1000), kind: .flagsChanged(keyCode: 0x36, flags: rcmdFlags)))
        #expect(m.handle(KeyInputEvent(time: ms(1400), kind: .poll(heldRightCommand))).isEmpty)
    }
}
