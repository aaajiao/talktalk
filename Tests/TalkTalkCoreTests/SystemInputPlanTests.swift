import Testing
@testable import TalkTalkCore

private typealias D = MicPolicy.Device
private typealias Plan = SystemInputPlan
private typealias Ref = SystemInputPlan.DeviceRef

private let builtIn = D(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: "bltn")
private let usb = D(uid: "usb:mv7", name: "Shure MV7", transport: "usb ")
private let usb2 = D(uid: "usb:yeti", name: "Yeti", transport: "usb ")
private let ear4 = D(uid: "bt:ear4", name: "ear (4)", transport: "blue")
private let iphone = D(uid: "ccwl:iphone", name: "iPhone Microphone", transport: "ccwl")
private let mic = D(uid: "com.aaajiao.talktalk.mic", name: "TalkTalk Mic", transport: "virt")
private let tuwa = D(uid: "tuwa:mic", name: "Tuwa Mic", transport: "virt")
private let krisp = D(uid: "krisp:mic", name: "Krisp Microphone", transport: "virt")
private let teams = D(uid: "teams:audio", name: "Microsoft Teams Audio", transport: "usb ")
private let agg = D(uid: "agg:1", name: "Aggregate", transport: "grup", isAggregate: true)

private func snap(_ devices: [D], _ def: D?) -> SystemInputPlan.Snapshot { SystemInputPlan.Snapshot(devices: devices, defaultInput: def) }

// MARK: restore target

@Suite struct RestoreTargetTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let original: SystemInputPlan.DeviceRef?
        let devices: [MicPolicy.Device]
        let uid: String?
        let source: SystemInputPlan.RestoreTarget.Source?
        let notice: SystemInputPlan.RestoreTarget.Notice?
        var testDescription: String { name }
    }

    static let rows: [Row] = [
        Row(name: "original present", original: Ref(usb), devices: [builtIn, usb, mic],
            uid: usb.uid, source: .original, notice: nil),
        Row(name: "original Bluetooth present is restored as is", original: Ref(ear4), devices: [builtIn, ear4, mic],
            uid: ear4.uid, source: .original, notice: nil),
        Row(name: "original missing → built-in", original: Ref(usb), devices: [usb2, builtIn, mic],
            uid: builtIn.uid, source: .builtIn, notice: .originalMissing(name: usb.name)),
        Row(name: "original dead → built-in", original: Ref(usb),
            devices: [builtIn, D(uid: usb.uid, name: usb.name, transport: "usb ", isAlive: false)],
            uid: builtIn.uid, source: .builtIn, notice: .originalMissing(name: usb.name)),
        Row(name: "original missing, no built-in → other candidate", original: Ref(usb), devices: [ear4, usb2, mic],
            uid: usb2.uid, source: .candidate, notice: .originalMissing(name: usb.name)),
        Row(name: "original virtual (Tuwa) → built-in, notice once", original: Ref(tuwa), devices: [tuwa, builtIn, mic],
            uid: builtIn.uid, source: .builtIn, notice: .originalWasVirtual(name: tuwa.name)),
        Row(name: "original virtual and gone → still 'virtual'", original: Ref(tuwa), devices: [builtIn],
            uid: builtIn.uid, source: .builtIn, notice: .originalWasVirtual(name: tuwa.name)),
        Row(name: "original is TalkTalk Mic → never back to it", original: Ref(mic), devices: [mic, builtIn],
            uid: builtIn.uid, source: .builtIn, notice: .originalWasVirtual(name: mic.name)),
        Row(name: "original Teams Audio (name excluded) → built-in", original: Ref(teams), devices: [teams, builtIn],
            uid: builtIn.uid, source: .builtIn, notice: .originalWasVirtual(name: teams.name)),
        Row(name: "original aggregate → built-in", original: Ref(agg), devices: [agg, builtIn],
            uid: builtIn.uid, source: .builtIn, notice: .originalWasVirtual(name: agg.name)),
        Row(name: "only Bluetooth left", original: Ref(usb), devices: [mic, tuwa, ear4],
            uid: ear4.uid, source: .otherPhysical, notice: .originalMissing(name: usb.name)),
        Row(name: "only Continuity left", original: nil, devices: [mic, iphone],
            uid: iphone.uid, source: .otherPhysical, notice: nil),
        Row(name: "nothing physical → nil (HUD red)", original: Ref(usb), devices: [mic, tuwa, teams, agg],
            uid: nil, source: nil, notice: nil),
        Row(name: "no devices → nil", original: nil, devices: [], uid: nil, source: nil, notice: nil),
    ]

    @Test(arguments: rows) func target(_ row: Row) {
        let t = SystemInputPlan.restoreTarget(original: row.original, devices: row.devices)
        #expect(t?.device.uid == row.uid)
        #expect(t?.source == row.source)
        #expect(t?.notice == row.notice)
        if let t { #expect(MicPolicy.isUsable(t.device) && !MicPolicy.isTalkTalkMic(t.device)) }
    }
}

// MARK: entry

@Suite struct EntryOriginalTests {
    @Test func existingRecordIsReused() {
        let e = SystemInputPlan.entryOriginal(existing: Ref(usb), currentDefault: mic, lastPhysical: builtIn, devices: [builtIn, mic])
        #expect(e == SystemInputPlan.EntryOriginal(original: Ref(usb), reusedRecord: true, notice: nil))
    }

    @Test func currentPhysicalDefault() {
        let e = SystemInputPlan.entryOriginal(existing: nil, currentDefault: usb, lastPhysical: builtIn, devices: [builtIn, usb, mic])
        #expect(e?.original == Ref(usb))
        #expect(e?.notice == nil)
    }

    @Test func currentIsMicTakesLastPhysical() {
        let e = SystemInputPlan.entryOriginal(existing: nil, currentDefault: mic, lastPhysical: usb, devices: [builtIn, usb, mic])
        #expect(e?.original == Ref(usb))
        #expect(e?.notice == nil)
    }

    @Test func currentVirtualTakesLastPhysicalWithNotice() {
        let e = SystemInputPlan.entryOriginal(existing: nil, currentDefault: tuwa, lastPhysical: usb, devices: [builtIn, usb, tuwa, mic])
        #expect(e?.original == Ref(usb))
        #expect(e?.notice == .currentDefaultVirtual(current: tuwa.name, restoreTo: usb.name))
    }

    @Test func lastPhysicalGoneFallsBackToRestoreOrder() {
        let e = SystemInputPlan.entryOriginal(existing: nil, currentDefault: mic, lastPhysical: usb2, devices: [ear4, builtIn, mic])
        #expect(e?.original == Ref(builtIn))
    }

    @Test func nothingPhysicalRefusesToSwitch() {
        #expect(SystemInputPlan.entryOriginal(existing: nil, currentDefault: mic, lastPhysical: nil, devices: [mic, tuwa]) == nil)
    }
}

// MARK: meeting mode classification

@Suite struct MeetingMonitorTests {
    struct Harness {
        var tracker = SystemInputPlan.Tracker()
        var monitor = SystemInputPlan.MeetingMonitor()
        mutating func step(_ s: SystemInputPlan.Snapshot, _ now: Double) -> SystemInputPlan.MeetingAction {
            tracker.update(s, now: now)
            return monitor.observe(s, tracker: tracker, now: now)
        }
    }

    @Test func insertedDeviceSwitchesBackOnce() {
        var h = Harness()
        #expect(h.step(snap([builtIn, mic], mic), 0) == .none)
        // ear4 connects at 100 s, becomes default at 101.5 s (macOS auto switch).
        #expect(h.step(snap([builtIn, mic, ear4], mic), 100) == .none)
        #expect(h.step(snap([builtIn, mic, ear4], ear4), 101.5) == .switchToMic(.deviceInserted(ear4)))
        #expect(h.step(snap([builtIn, mic, ear4], mic), 101.6) == .none)
        #expect(h.monitor.phase == .holding)
        // Same arrival switching away again after the 10 s contest window: it was switched back once
        // already, so it is manual now.
        #expect(h.step(snap([builtIn, mic, ear4], ear4), 102.9 + 10) == .voidRecord(changedTo: ear4))
    }

    @Test func insertedAndDefaultInSameSnapshot() {
        var h = Harness()
        _ = h.step(snap([builtIn, mic], mic), 0)
        #expect(h.step(snap([builtIn, mic, ear4], ear4), 50) == .switchToMic(.deviceInserted(ear4)))
    }

    @Test func insertWindowIsThreeSeconds() {
        var h = Harness()
        _ = h.step(snap([builtIn, mic], mic), 0)
        _ = h.step(snap([builtIn, mic, ear4], mic), 10)
        #expect(h.step(snap([builtIn, mic, ear4], ear4), 13.01) == .voidRecord(changedTo: ear4))
        #expect(h.monitor.phase == .overridden(ear4))
    }

    @Test func eachArrivalSwitchesBackOnlyOnce() {
        var h = Harness()
        _ = h.step(snap([builtIn, mic], mic), 0)
        // Reconnect → a new arrival → may switch back again (outside the 10 s window).
        _ = h.step(snap([builtIn, mic, ear4], ear4), 10)
        _ = h.step(snap([builtIn, mic, ear4], mic), 10.1)
        _ = h.step(snap([builtIn, mic], mic), 30)
        #expect(h.step(snap([builtIn, mic, ear4], ear4), 40) == .switchToMic(.deviceInserted(ear4)))
    }

    @Test func reswitchedWithinTenSecondsStopsContesting() {
        var h = Harness()
        _ = h.step(snap([builtIn, mic], mic), 0)
        #expect(h.step(snap([builtIn, mic, ear4], ear4), 10) == .switchToMic(.deviceInserted(ear4)))
        _ = h.step(snap([builtIn, mic, ear4], mic), 10.1)
        // A second new device grabs it within 10 s of our switch back: stop fighting, manual.
        #expect(h.step(snap([builtIn, mic, ear4, usb], usb), 12) == .voidRecord(changedTo: usb))
        #expect(h.monitor.phase == .overridden(usb))
        // Overridden: no further actions at all until reassert.
        #expect(h.step(snap([builtIn, mic, ear4, usb], builtIn), 30) == .none)
        h.monitor.reassert()
        #expect(h.monitor.phase == .holding)
    }

    @Test func manualChangeVoidsRecord() {
        var h = Harness()
        _ = h.step(snap([builtIn, usb, mic], mic), 0)
        #expect(h.step(snap([builtIn, usb, mic], usb), 5) == .voidRecord(changedTo: usb))
    }

    @Test func micVanishWaitsAndSwitchesBackOnReturn() {
        var h = Harness()
        _ = h.step(snap([builtIn, mic], mic), 0)
        // coreaudiod restart: Mic gone, default briefly none, then built-in (M0-T8 d2/d4).
        #expect(h.step(snap([builtIn], nil), 20) == .none)
        #expect(h.monitor.phase == .waitingForMic)
        #expect(h.step(snap([builtIn], builtIn), 20.01) == .recordReplacement(builtIn))
        #expect(h.monitor.replacementUID == builtIn.uid)
        #expect(h.step(snap([builtIn], builtIn), 22) == .none)
        // Mic comes back and macOS did not re-select it: switch back, not manual.
        #expect(h.step(snap([builtIn, mic], builtIn), 22.5) == .switchToMic(.micReturned))
        #expect(h.monitor.phase == .holding)
        // Review 6 #3: macOS's pick stays the replacement until the switch back is written.
        #expect(h.monitor.replacementUID == builtIn.uid)
        h.monitor.switchBackSucceeded()
        #expect(h.monitor.replacementUID == nil)
    }

    /// Review 5 #5: a switch-back that could not be written is retried, not taken for your change.
    @Test func failedSwitchBackIsRetriedNotVoided() {
        var h = Harness()
        _ = h.step(snap([builtIn, mic], mic), 0)
        #expect(h.step(snap([builtIn, mic, ear4], ear4), 1) == .switchToMic(.deviceInserted(ear4)))
        h.monitor.switchBackFailed(.deviceInserted(ear4), current: ear4, now: 1)
        #expect(h.step(snap([builtIn, mic, ear4], ear4), 2) == .switchToMic(.deviceInserted(ear4)))
        #expect(h.monitor.phase == .holding)
        // Mic returned, switching back failed, then you pick built-in: that one is yours.
        var r = Harness()
        _ = r.step(snap([builtIn, usb, mic], mic), 0)
        _ = r.step(snap([builtIn, usb], builtIn), 1)
        #expect(r.step(snap([builtIn, usb, mic], builtIn), 2) == .switchToMic(.micReturned))
        r.monitor.switchBackFailed(.micReturned, current: builtIn, now: 2)
        #expect(r.step(snap([builtIn, usb, mic], builtIn), 3) == .switchToMic(.micReturned))
        #expect(r.step(snap([builtIn, mic, usb], usb), 20) == .voidRecord(changedTo: usb))
    }

    /// Review 6 #2: a vanish starts a new round; the old retry must not turn the second Mic
    /// return into a retry that leaves the phase at waitingForMic (your later change then went
    /// unvoided: the waitingForMic branch switched back instead).
    @Test func vanishClearsTheRetryRound() {
        var h = Harness()
        _ = h.step(snap([builtIn, usb, mic], mic), 0)
        _ = h.step(snap([builtIn, usb], builtIn), 1)
        #expect(h.step(snap([builtIn, usb, mic], builtIn), 2) == .switchToMic(.micReturned))
        h.monitor.switchBackFailed(.micReturned, current: builtIn, now: 2)
        #expect(h.step(snap([builtIn, usb], builtIn), 3) == .none)
        #expect(h.monitor.phase == .waitingForMic)
        #expect(h.monitor.retryDevice == nil)
        #expect(h.step(snap([builtIn, usb, mic], builtIn), 4) == .switchToMic(.micReturned))
        #expect(h.monitor.phase == .holding)
        h.monitor.switchBackFailed(.micReturned, current: builtIn, now: 4)
        #expect(h.step(snap([builtIn, usb, mic], usb), 30) == .voidRecord(changedTo: usb))
    }

    /// Review 6 #3: a failed switch back after the Mic returned keeps macOS's pick as the
    /// replacement (ending restores over it); #1: retries stop after `contestWindow`, the record
    /// stays, nothing is voided; your change after that is still yours.
    @Test func failedMicReturnKeepsTheReplacementAndStopsRetrying() {
        var h = Harness()
        _ = h.step(snap([builtIn, usb, mic], mic), 0)
        #expect(h.step(snap([builtIn, usb], builtIn), 1) == .recordReplacement(builtIn))
        #expect(h.step(snap([builtIn, usb, mic], builtIn), 2) == .switchToMic(.micReturned))
        h.monitor.switchBackFailed(.micReturned, current: builtIn, now: 2)
        #expect(h.monitor.replacementUID == builtIn.uid)
        #expect(h.monitor.retryDevice == builtIn)
        #expect(h.step(snap([builtIn, usb, mic], builtIn), 6) == .switchToMic(.micReturned))
        h.monitor.switchBackFailed(.micReturned, current: builtIn, now: 6)
        #expect(h.step(snap([builtIn, usb, mic], builtIn), 12) == .none)   // 10 s since the first failure
        #expect(h.monitor.phase == .switchBackFailed(builtIn))
        #expect(h.monitor.retryDevice == nil)
        #expect(h.monitor.replacementUID == builtIn.uid)
        #expect(h.step(snap([builtIn, usb, mic], builtIn), 100) == .none)
        #expect(h.step(snap([builtIn, usb, mic], usb), 101) == .voidRecord(changedTo: usb))
        // A success clears the round and the replacement.
        var g = Harness()
        _ = g.step(snap([builtIn, usb, mic], mic), 0)
        _ = g.step(snap([builtIn, usb], builtIn), 1)
        _ = g.step(snap([builtIn, usb, mic], builtIn), 2)
        g.monitor.switchBackSucceeded()
        #expect(g.monitor.replacementUID == nil && g.monitor.retryDevice == nil)
    }

    @Test func micReturnReselectedByMacOSNeedsNothing() {
        var h = Harness()
        _ = h.step(snap([builtIn, mic], mic), 0)
        _ = h.step(snap([builtIn], builtIn), 1)
        #expect(h.monitor.replacementUID == builtIn.uid)
        #expect(h.step(snap([builtIn, mic], mic), 3) == .none)
        #expect(h.monitor.phase == .holding)
        // Review #1: the replacement is gone once macOS re-selected the Mic.
        #expect(h.monitor.replacementUID == nil)
    }

    @Test func micReturnDoesNotCountAsContest() {
        var h = Harness()
        _ = h.step(snap([builtIn, mic], mic), 0)
        _ = h.step(snap([builtIn], builtIn), 1)
        #expect(h.step(snap([builtIn, mic], builtIn), 3) == .switchToMic(.micReturned))
        _ = h.step(snap([builtIn, mic], mic), 3.1)
        // An inserted device 2 s later still gets switched back (micReturned is not a contest).
        #expect(h.step(snap([builtIn, mic, ear4], ear4), 5) == .switchToMic(.deviceInserted(ear4)))
    }

    @Test func manualChangeWhileMicAbsentAfterSettleIsManual() {
        var h = Harness()
        _ = h.step(snap([builtIn, usb, mic], mic), 0)
        _ = h.step(snap([builtIn, usb], builtIn), 1)
        #expect(h.step(snap([builtIn, usb], usb), 30) == .voidRecord(changedTo: usb))
    }

    @Test func newDeviceWhileMicAbsentIsStillMacOS() {
        var h = Harness()
        _ = h.step(snap([builtIn, mic], mic), 0)
        _ = h.step(snap([builtIn], builtIn), 1)
        #expect(h.step(snap([builtIn, ear4], ear4), 30) == .recordReplacement(ear4))
    }
}

// MARK: ending, deferred restore, "only write when ours"

@Suite struct DeferredRestoreTests {
    @Test func endSteps() {
        #expect(SystemInputPlan.endStep(.restoreNow, callEnded: false) == .restore)
        #expect(SystemInputPlan.endStep(.restoreNow, callEnded: true) == .restore)
        #expect(SystemInputPlan.endStep(.whenCallEnds, callEnded: true) == .restore)
        #expect(SystemInputPlan.endStep(.whenCallEnds, callEnded: false) == .deferUntilCallEnds)
    }

    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let original: SystemInputPlan.DeviceRef
        let replacement: String?
        let snapshot: SystemInputPlan.Snapshot
        let callEnded: Bool
        let want: SystemInputPlan.DeferredDecision
        var layer4UID: String?
        var testDescription: String { name }
    }

    static let usbTarget = SystemInputPlan.RestoreTarget(device: usb, source: .original, notice: nil)
    static let rows: [Row] = [
        Row(name: "Mic default, call on → wait", original: Ref(usb), replacement: nil,
            snapshot: snap([builtIn, usb, mic], mic), callEnded: false, want: .wait(.callOngoing)),
        Row(name: "Mic default, call ended → restore", original: Ref(usb), replacement: nil,
            snapshot: snap([builtIn, usb, mic], mic), callEnded: true, want: .restore(usbTarget)),
        Row(name: "no default (re-arbitrating) → wait", original: Ref(usb), replacement: nil,
            snapshot: snap([builtIn, usb], nil), callEnded: true, want: .wait(.noDefaultInput)),
        Row(name: "Mic vanished, macOS picked built-in → restore at once", original: Ref(usb), replacement: builtIn.uid,
            snapshot: snap([builtIn, usb], builtIn), callEnded: false, want: .restore(usbTarget)),
        Row(name: "replacement already is the original → drop", original: Ref(builtIn), replacement: builtIn.uid,
            snapshot: snap([builtIn], builtIn), callEnded: false, want: .dropRecord(.alreadyRestored)),
        Row(name: "you changed it → drop, never write", original: Ref(usb), replacement: nil,
            snapshot: snap([builtIn, usb, mic], builtIn), callEnded: true, want: .dropRecord(.changedTo(builtIn))),
        Row(name: "inserted device (unseen) → drop", original: Ref(usb), replacement: nil,
            snapshot: snap([builtIn, usb, mic, ear4], ear4), callEnded: false, want: .dropRecord(.changedTo(ear4))),
        Row(name: "already the original → drop", original: Ref(usb), replacement: nil,
            snapshot: snap([builtIn, usb, mic], usb), callEnded: false, want: .dropRecord(.alreadyRestored)),
        Row(name: "layer 4: Tuwa picked after reboot, Mic absent → restore", original: Ref(usb), replacement: nil,
            snapshot: snap([builtIn, usb, tuwa], tuwa), callEnded: false, want: .restore(usbTarget), layer4UID: tuwa.uid),
        Row(name: "layer 4: other virtual with Mic present, call on → wait", original: Ref(usb), replacement: nil,
            snapshot: snap([builtIn, usb, tuwa, mic], tuwa), callEnded: false, want: .wait(.callOngoing), layer4UID: tuwa.uid),
        Row(name: "layer 4: other virtual, call ended → restore", original: Ref(usb), replacement: nil,
            snapshot: snap([builtIn, usb, tuwa, mic], tuwa), callEnded: true, want: .restore(usbTarget), layer4UID: tuwa.uid),
        // Review #2: outside layer 4 a virtual device you picked (Krisp, Loopback, an aggregate) is your choice.
        Row(name: "you picked a virtual device, Mic present, call on → drop", original: Ref(usb), replacement: nil,
            snapshot: snap([builtIn, usb, tuwa, mic], tuwa), callEnded: false, want: .dropRecord(.changedTo(tuwa))),
        Row(name: "you picked a virtual device, call ended → still drop", original: Ref(usb), replacement: nil,
            snapshot: snap([builtIn, usb, tuwa, mic], tuwa), callEnded: true, want: .dropRecord(.changedTo(tuwa))),
        // Review C2: layer 4 covers only the device that was the default at the takeover.
        Row(name: "layer 4 is Tuwa, you picked Krisp after the takeover → drop", original: Ref(usb), replacement: nil,
            snapshot: snap([builtIn, usb, tuwa, krisp, mic], krisp), callEnded: true, want: .dropRecord(.changedTo(krisp)),
            layer4UID: tuwa.uid),
        Row(name: "virtual, Mic gone, not the replacement → drop (not layer 4)", original: Ref(usb), replacement: nil,
            snapshot: snap([builtIn, usb, tuwa], tuwa), callEnded: false, want: .dropRecord(.changedTo(tuwa))),
        Row(name: "Mic default, nothing physical → noTarget", original: Ref(usb), replacement: nil,
            snapshot: snap([mic, tuwa], mic), callEnded: true, want: .noTarget),
        Row(name: "original gone → built-in", original: Ref(usb2), replacement: nil,
            snapshot: snap([builtIn, mic], mic), callEnded: true,
            want: .restore(SystemInputPlan.RestoreTarget(device: builtIn, source: .builtIn, notice: .originalMissing(name: usb2.name)))),
    ]

    @Test(arguments: rows) func decision(_ row: Row) {
        #expect(SystemInputPlan.deferredDecision(original: row.original, replacementUID: row.replacement,
                                      snapshot: row.snapshot, callEnded: row.callEnded, layer4UID: row.layer4UID) == row.want)
    }

    @Test func deferredMonitorLearnsReplacementWhileWaiting() {
        var tracker = SystemInputPlan.Tracker()
        var m = SystemInputPlan.DeferredMonitor(original: Ref(usb), replacementUID: nil)
        func step(_ s: SystemInputPlan.Snapshot, _ t: Double, ended: Bool = false) -> SystemInputPlan.DeferredDecision {
            tracker.update(s, now: t)
            return m.observe(s, tracker: tracker, callEnded: ended, now: t)
        }
        #expect(step(snap([builtIn, usb, mic], mic), 0) == .wait(.callOngoing))
        // The meeting app stops reading, the app is gone: driver removes Mic, macOS picks built-in.
        #expect(step(snap([builtIn, usb], nil), 40) == .wait(.noDefaultInput))
        // Call still on: macOS's pick stays until the Mic returns or the call ends (review 6 #4).
        #expect(step(snap([builtIn, usb], builtIn), 40.02) == .wait(.micAbsent))
        #expect(m.replacementUID == builtIn.uid)
        #expect(m.micVanished)
        #expect(step(snap([builtIn, usb], builtIn), 90, ended: true) == .restore(Self.usbTarget))
    }

    /// Review 6 #4 (the guard through a coreaudiod restart, d4t): Mic vanishes, macOS picks
    /// built-in, the Mic returns with the call on → back to the Mic, record kept; the call ends →
    /// the original. The original not listed yet right after the restart → wait, never
    /// "already restored" on the fallback.
    @Test func micVanishWithTheCallOnSwitchesBackWhenItReturns() {
        var tracker = SystemInputPlan.Tracker()
        var m = SystemInputPlan.DeferredMonitor(original: Ref(usb), replacementUID: nil)
        func step(_ s: SystemInputPlan.Snapshot, _ t: Double, ended: Bool = false) -> SystemInputPlan.DeferredDecision {
            tracker.update(s, now: t)
            return m.observe(s, tracker: tracker, callEnded: ended, now: t)
        }
        #expect(step(snap([builtIn, usb, mic], mic), 0) == .wait(.callOngoing))
        #expect(step(snap([], nil), 10) == .wait(.noDefaultInput))
        #expect(step(snap([builtIn], builtIn), 10.986) == .wait(.micAbsent))
        #expect(step(snap([builtIn, mic], builtIn), 11.006) == .switchToMic)
        #expect(step(snap([builtIn, mic], builtIn), 13) == .switchToMic)   // the write failed: again
        #expect(step(snap([builtIn, usb, mic], mic), 13.1) == .wait(.callOngoing))
        #expect(!m.micVanished)
        #expect(step(snap([builtIn, usb, mic], mic), 60, ended: true) == .restore(Self.usbTarget))

        // The call ends while usb is not back yet: wait (up to micVanishSettle), then restore.
        var t2 = SystemInputPlan.Tracker()
        var n = SystemInputPlan.DeferredMonitor(original: Ref(usb), replacementUID: nil)
        func step2(_ s: SystemInputPlan.Snapshot, _ t: Double, ended: Bool) -> SystemInputPlan.DeferredDecision {
            t2.update(s, now: t)
            return n.observe(s, tracker: t2, callEnded: ended, now: t)
        }
        _ = step2(snap([builtIn, usb, mic], mic), 0, ended: false)
        _ = step2(snap([builtIn], builtIn), 10, ended: false)
        #expect(step2(snap([builtIn, mic], builtIn), 11, ended: true) == .wait(.devicesSettling))
        #expect(step2(snap([builtIn, usb, mic], builtIn), 11.5, ended: true) == .restore(Self.usbTarget))
        // usb really gone: after the settle the fallback stands.
        var t3 = SystemInputPlan.Tracker()
        var o = SystemInputPlan.DeferredMonitor(original: Ref(usb), replacementUID: nil)
        t3.update(snap([builtIn, usb, mic], mic), now: 0)
        _ = o.observe(snap([builtIn, usb, mic], mic), tracker: t3, callEnded: false, now: 0)
        t3.update(snap([builtIn], builtIn), now: 10)
        #expect(o.observe(snap([builtIn], builtIn), tracker: t3, callEnded: true, now: 10) == .wait(.devicesSettling))
        t3.update(snap([builtIn], builtIn), now: 14)
        #expect(o.observe(snap([builtIn], builtIn), tracker: t3, callEnded: true, now: 14) == .dropRecord(.alreadyRestored))
    }

    @Test func deferredReplacementExpiresWhenTheDefaultMoves() {
        // Review #1: replacement builtIn, Mic returns and macOS re-selects it, later you pick built-in.
        var tracker = SystemInputPlan.Tracker()
        var m = SystemInputPlan.DeferredMonitor(original: Ref(usb), replacementUID: builtIn.uid)
        tracker.update(snap([builtIn, usb, mic], mic), now: 0)
        #expect(m.observe(snap([builtIn, usb, mic], mic), tracker: tracker, callEnded: false, now: 0) == .wait(.callOngoing))
        #expect(m.replacementUID == nil)
        tracker.update(snap([builtIn, usb, mic], builtIn), now: 100)
        #expect(m.observe(snap([builtIn, usb, mic], builtIn), tracker: tracker, callEnded: false, now: 100)
                == .dropRecord(.changedTo(builtIn)))
    }

    @Test func layer4MonitorKeepsTheVirtualRule() {
        var tracker = SystemInputPlan.Tracker()
        var m = SystemInputPlan.DeferredMonitor(original: Ref(usb), replacementUID: nil, layer4UID: tuwa.uid)
        tracker.update(snap([builtIn, usb, tuwa], tuwa), now: 0)
        #expect(m.observe(snap([builtIn, usb, tuwa], tuwa), tracker: tracker, callEnded: false, now: 0)
                == .restore(Self.usbTarget))
        var app = SystemInputPlan.DeferredMonitor(original: Ref(usb), replacementUID: nil)
        #expect(app.observe(snap([builtIn, usb, tuwa], tuwa), tracker: tracker, callEnded: false, now: 0)
                == .dropRecord(.changedTo(tuwa)))
    }

    @Test func layer4UIDIsTheVirtualDefaultAtTheTakeover() {
        typealias M = SystemInputPlan.DeferredMonitor
        #expect(M.layer4UID(original: Ref(usb), snapshot: snap([builtIn, usb, tuwa, mic], tuwa)) == tuwa.uid)
        #expect(M.layer4UID(original: Ref(usb), snapshot: snap([builtIn, usb, tuwa, mic], mic)) == nil)
        #expect(M.layer4UID(original: Ref(usb), snapshot: snap([builtIn, usb, tuwa, mic], builtIn)) == nil)
        #expect(M.layer4UID(original: Ref(tuwa), snapshot: snap([builtIn, usb, tuwa, mic], tuwa)) == nil)
        #expect(M.layer4UID(original: Ref(usb), snapshot: snap([builtIn, usb, mic], nil)) == nil)
    }

    /// Review 3 (a): no default input at the takeover → the first default that appears within
    /// 1 s (macOS's pick, M0-T8 d2) is the layer-4 device.
    @Test func takeoverWithoutADefaultArmsLayer4() {
        var tracker = SystemInputPlan.Tracker()
        var m = SystemInputPlan.DeferredMonitor.takeover(original: Ref(usb), replacementUID: nil,
                                                         snapshot: snap([builtIn, usb, tuwa, mic], nil), now: 10)
        #expect(m.layer4Armed)
        #expect(m.layer4UID == nil)
        tracker.update(snap([builtIn, usb, tuwa, mic], nil), now: 10)
        #expect(m.observe(snap([builtIn, usb, tuwa, mic], nil), tracker: tracker, callEnded: false, now: 10)
                == .wait(.noDefaultInput))
        #expect(m.layer4Armed)
        tracker.update(snap([builtIn, usb, tuwa, mic], tuwa), now: 10.5)
        #expect(m.observe(snap([builtIn, usb, tuwa, mic], tuwa), tracker: tracker, callEnded: false, now: 10.5)
                == .wait(.callOngoing))
        #expect(!m.layer4Armed)
        #expect(m.layer4UID == tuwa.uid)
        #expect(m.observe(snap([builtIn, usb, tuwa, mic], tuwa), tracker: tracker, callEnded: true, now: 12)
                == .restore(Self.usbTarget))
        // Armed once only: the first default is the Mic; a later virtual device you pick is yours.
        var n = SystemInputPlan.DeferredMonitor.takeover(original: Ref(usb), replacementUID: nil,
                                                         snapshot: snap([builtIn, usb, tuwa, krisp, mic], nil), now: 20)
        _ = n.observe(snap([builtIn, usb, tuwa, krisp, mic], mic), tracker: tracker, callEnded: false, now: 20.1)
        #expect(!n.layer4Armed && n.layer4UID == nil)
        #expect(n.observe(snap([builtIn, usb, tuwa, krisp, mic], krisp), tracker: tracker, callEnded: true, now: 25)
                == .dropRecord(.changedTo(krisp)))
    }

    /// Review 4 (a1): a default that first appears after the 1 s window is yours (Krisp at 1.5 s → drop).
    @Test func layer4ArmWindowIsOneSecond() {
        let tracker = SystemInputPlan.Tracker()
        var m = SystemInputPlan.DeferredMonitor.takeover(original: Ref(usb), replacementUID: nil,
                                                         snapshot: snap([builtIn, usb, krisp, mic], nil), now: 0)
        #expect(m.layer4ArmedUntil == 1)
        #expect(m.observe(snap([builtIn, usb, krisp, mic], krisp), tracker: tracker, callEnded: true, now: 1.5)
                == .dropRecord(.changedTo(krisp)))
        #expect(!m.layer4Armed)
        #expect(m.layer4UID == nil)
        var w = SystemInputPlan.DeferredMonitor.takeover(original: Ref(usb), replacementUID: nil,
                                                         snapshot: snap([builtIn, usb, tuwa, mic], nil), now: 0)
        #expect(w.observe(snap([builtIn, usb, tuwa, mic], tuwa), tracker: tracker, callEnded: true, now: 0.9)
                == .restore(Self.usbTarget))
    }

    @Test func deferredMonitorManualAfterSettleDrops() {
        var tracker = SystemInputPlan.Tracker()
        var m = SystemInputPlan.DeferredMonitor(original: Ref(usb), replacementUID: nil)
        tracker.update(snap([builtIn, usb, mic], mic), now: 0)
        tracker.update(snap([builtIn, usb], builtIn), now: 1)
        _ = m.observe(snap([builtIn, usb], builtIn), tracker: tracker, callEnded: false, now: 1)
        tracker.update(snap([builtIn, usb, usb2], usb2), now: 100)   // a just-plugged device: macOS's pick
        #expect(m.observe(snap([builtIn, usb, usb2], usb2), tracker: tracker, callEnded: false, now: 100)
                == .wait(.micAbsent))
        #expect(m.replacementUID == usb2.uid)
        tracker.update(snap([builtIn, usb, usb2], builtIn), now: 200)   // old device, long after: you
        #expect(m.observe(snap([builtIn, usb, usb2], builtIn), tracker: tracker, callEnded: false, now: 200)
                == .dropRecord(.changedTo(builtIn)))
    }
}

// MARK: the no-record invariant

@Suite struct NoRecordInvariantTests {
    @Test func micWithoutRecordGoesBackToLastPhysical() {
        let d = SystemInputPlan.noRecordInvariant(snapshot: snap([builtIn, usb, mic], mic), meetingModeOn: false,
                                       recordExists: false, lockAvailable: true, lastPhysical: usb)
        #expect(d == .restore(SystemInputPlan.RestoreTarget(device: usb, source: .lastPhysical, notice: nil)))
    }

    @Test func lastPhysicalGoneUsesRestoreOrder() {
        let d = SystemInputPlan.noRecordInvariant(snapshot: snap([ear4, builtIn, mic], mic), meetingModeOn: false,
                                       recordExists: false, lockAvailable: true, lastPhysical: usb)
        #expect(d == .restore(SystemInputPlan.RestoreTarget(device: builtIn, source: .builtIn, notice: nil)))
    }

    @Test func nothingPhysical() {
        #expect(SystemInputPlan.noRecordInvariant(snapshot: snap([mic], mic), meetingModeOn: false, recordExists: false,
                                       lockAvailable: true, lastPhysical: nil) == .noTarget)
    }

    struct Guarded: Sendable, CustomTestStringConvertible {
        let name: String
        let meeting: Bool
        let record: Bool
        let lock: Bool
        let def: MicPolicy.Device?
        var testDescription: String { name }
    }

    @Test(arguments: [
        Guarded(name: "meeting mode on", meeting: true, record: false, lock: true, def: mic),
        Guarded(name: "a record exists (ours, other build's or deferred)", meeting: false, record: true, lock: true, def: mic),
        Guarded(name: "lock held by the other build", meeting: false, record: false, lock: false, def: mic),
        Guarded(name: "default is physical", meeting: false, record: false, lock: true, def: builtIn),
        Guarded(name: "default is another virtual device", meeting: false, record: false, lock: true, def: tuwa),
        Guarded(name: "no default", meeting: false, record: false, lock: true, def: nil),
    ])
    func leavesAlone(_ g: Guarded) {
        #expect(SystemInputPlan.noRecordInvariant(snapshot: snap([builtIn, mic, tuwa], g.def), meetingModeOn: g.meeting,
                                       recordExists: g.record, lockAvailable: g.lock, lastPhysical: builtIn) == .none)
    }
}

@Suite struct SystemInputConfigTests {
    @Test func defaultsMatchDesign() {
        let c = SystemInputPlan.Config.default
        #expect(c.insertWindow == 3)
        #expect(c.contestWindow == 10)
        #expect(c.pollInterval == 2)
        #expect(c.launchSettle == 2)
        // Driver 0.2.0 (pinned): the Mic is never re-selected (d2t, d4t), the driver layer counts.
        #expect(DriverPins.version == "0.2.0")
        #expect(c.driverLayerCounts)
        #expect(!c.loginStartStronglyRecommended)
        var old = c
        old.driverLayerCounts = false   // 0.1.0 (M0-T8 d3)
        #expect(old.loginStartStronglyRecommended)
    }

    @Test func trackerRemembersLastPhysicalDefault() {
        var t = SystemInputPlan.Tracker()
        t.update(snap([builtIn, usb, mic], usb), now: 0)
        t.update(snap([builtIn, usb, mic], mic), now: 1)
        t.update(snap([builtIn, usb, mic, tuwa], tuwa), now: 2)
        #expect(t.lastPhysicalDefault == usb)
        #expect(t.arrivals[tuwa.uid] == 2)
        #expect(t.arrivals[usb.uid] == nil)   // present at the first snapshot: not an arrival
    }
}

/// Review of 9d9b3a4 (2026-11-05): a coreaudiod restart that no snapshot caught in between.
@Suite struct RestartPickTests {
    private func restarted(_ devices: [D], _ def: D?, _ n: Int) -> SystemInputPlan.Snapshot {
        SystemInputPlan.Snapshot(devices: devices, defaultInput: def, serviceRestarts: n)
    }

    @Test func trackerKnowsTheRestartPick() {
        var t = SystemInputPlan.Tracker()
        let c = SystemInputPlan.Config.default
        t.update(snap([builtIn, usb, mic], mic), now: 0)
        t.update(snap([], nil), now: 10)                          // the vanish, default none
        t.update(snap([builtIn, mic], builtIn), now: 11)          // built-in at once, the Mic back
        #expect(t.isRestartPick(builtIn.uid, now: 11, config: c))
        #expect(t.lastVanishAt == 10)
        // Only ServiceRestarted saw it: the Mic never left a snapshot, the default moved off it.
        var r = SystemInputPlan.Tracker()
        r.update(snap([builtIn, usb, mic], mic), now: 0)
        r.update(restarted([builtIn, usb, mic], builtIn, 1), now: 20)
        #expect(r.isRestartPick(builtIn.uid, now: 20, config: c))
        // A change long after the vanish, or from another physical device, is yours.
        r.update(restarted([builtIn, usb, mic], usb, 1), now: 40)
        #expect(!r.isRestartPick(usb.uid, now: 40, config: c))
        var u = SystemInputPlan.Tracker()
        u.update(snap([builtIn, usb, mic], mic), now: 0)
        u.update(snap([builtIn, usb], nil), now: 10)
        u.update(snap([builtIn, usb, mic], builtIn), now: 14)    // > micVanishSettle after it
        #expect(!u.isRestartPick(builtIn.uid, now: 14, config: c))
        // The Mic was the default again after the vanish (macOS re-selected it): built-in a second
        // later is yours.
        var w = SystemInputPlan.Tracker()
        w.update(snap([builtIn, usb, mic], mic), now: 0)
        w.update(snap([builtIn, usb], builtIn), now: 10)
        w.update(snap([builtIn, usb, mic], mic), now: 10.5)
        w.update(snap([builtIn, usb, mic], builtIn), now: 11.5)
        #expect(!w.isRestartPick(builtIn.uid, now: 11.5, config: c))
    }

    /// #2, meeting mode: the vanish showed no default; at the return the default is built-in and
    /// the switch back fails → built-in is the replacement (ending restores over it).
    @Test func meetingMonitorRecordsTheReplacementSeenOnlyAtTheReturn() {
        var h = MeetingMonitorTests.Harness()
        _ = h.step(snap([builtIn, usb, mic], mic), 0)
        #expect(h.step(snap([], nil), 10) == .none)
        #expect(h.step(snap([builtIn, usb, mic], builtIn), 11) == .switchToMic(.micReturned))
        #expect(h.monitor.replacementUID == builtIn.uid)
        // No vanish snapshot at all, only ServiceRestarted.
        var r = MeetingMonitorTests.Harness()
        _ = r.step(snap([builtIn, usb, mic], mic), 0)
        #expect(r.step(restarted([builtIn, usb, mic], builtIn, 1), 30) == .switchToMic(.micReturned))
        #expect(r.monitor.replacementUID == builtIn.uid)
        #expect(r.monitor.phase == .holding)
    }

    /// #2, deferred / guard: the same order (d4t) → the Mic again with the call on; original
    /// built-in is not "already restored" during the call.
    @Test func deferredMonitorSwitchesBackWithoutTheMiddleSnapshot() {
        for original in [usb, builtIn] {
            var t = SystemInputPlan.Tracker()
            var m = SystemInputPlan.DeferredMonitor(original: Ref(original), replacementUID: nil)
            func step(_ s: SystemInputPlan.Snapshot, _ now: Double, ended: Bool = false) -> SystemInputPlan.DeferredDecision {
                t.update(s, now: now)
                return m.observe(s, tracker: t, callEnded: ended, now: now)
            }
            #expect(step(snap([builtIn, usb, mic], mic), 0) == .wait(.callOngoing))
            #expect(step(restarted([builtIn, usb, mic], builtIn, 1), 30) == .switchToMic)
            #expect(m.replacementUID == builtIn.uid && m.micVanished)
            #expect(step(restarted([builtIn, usb, mic], mic, 1), 31) == .wait(.callOngoing))
        }
    }

    /// #3: a monitor built with a replacement is in the "Mic vanished" state from the start.
    @Test func monitorWithAReplacementStartsSticky() {
        var t = SystemInputPlan.Tracker()
        var m = SystemInputPlan.DeferredMonitor(original: Ref(usb), replacementUID: builtIn.uid)
        #expect(m.micVanished)
        t.update(snap([builtIn, usb, mic], builtIn), now: 0)
        #expect(m.observe(snap([builtIn, usb, mic], builtIn), tracker: t, callEnded: false, now: 0) == .switchToMic)
        #expect(m.observe(snap([builtIn, usb, mic], builtIn), tracker: t, callEnded: true, now: 50) == .restore(DeferredRestoreTests.usbTarget))
    }

    /// #1: the deferred switch back stops after contestWindow; the record stays until the call ends.
    @Test func deferredRetriesStopAfterTheContestWindow() {
        var t = SystemInputPlan.Tracker()
        var m = SystemInputPlan.DeferredMonitor(original: Ref(usb), replacementUID: builtIn.uid)
        t.update(snap([builtIn, usb, mic], builtIn), now: 0)
        #expect(m.observe(snap([builtIn, usb, mic], builtIn), tracker: t, callEnded: false, now: 0) == .switchToMic)
        m.switchBackFailed(now: 0)
        #expect(m.observe(snap([builtIn, usb, mic], builtIn), tracker: t, callEnded: false, now: 5) == .switchToMic)
        m.switchBackFailed(now: 5)
        #expect(m.observe(snap([builtIn, usb, mic], builtIn), tracker: t, callEnded: false, now: 10) == .wait(.switchBackFailed))
        #expect(m.switchBackGaveUp)
        #expect(m.observe(snap([builtIn, usb, mic], builtIn), tracker: t, callEnded: true, now: 60) == .restore(DeferredRestoreTests.usbTarget))
    }

    /// #5: a failed insert switch back keeps the inserted device as macOS's pick.
    @Test func failedInsertSwitchBackKeepsTheReplacement() {
        var h = MeetingMonitorTests.Harness()
        _ = h.step(snap([builtIn, usb, mic], mic), 0)
        #expect(h.step(snap([builtIn, usb, mic, ear4], ear4), 50) == .switchToMic(.deviceInserted(ear4)))
        h.monitor.switchBackFailed(.deviceInserted(ear4), current: ear4, now: 50)
        #expect(h.monitor.replacementUID == ear4.uid)
    }
}

/// Review of a7ef015 (2026-11-05) #4: vanishes only the Tracker saw start new rounds; the deferred
/// state follows macOS's pick when it moves on right after the vanish.
@Suite struct VanishRoundTests {
    private func restarted(_ devices: [D], _ def: D?, _ n: Int) -> SystemInputPlan.Snapshot {
        SystemInputPlan.Snapshot(devices: devices, defaultInput: def, serviceRestarts: n)
    }

    @Test func meetingMonitorGaveUpThenARestartStartsANewRound() {
        var h = MeetingMonitorTests.Harness()
        _ = h.step(snap([builtIn, usb, mic], mic), 0)
        _ = h.step(snap([builtIn, usb], builtIn), 1)
        _ = h.step(snap([builtIn, usb, mic], builtIn), 2)
        h.monitor.switchBackFailed(.micReturned, current: builtIn, now: 2)
        _ = h.step(snap([builtIn, usb, mic], builtIn), 13)
        #expect(h.monitor.gaveUpSwitchingBack)
        // coreaudiod restarts; only the counter says so; the default stays built-in.
        #expect(h.step(restarted([builtIn, usb, mic], builtIn, 1), 100) == .switchToMic(.micReturned))
        #expect(!h.monitor.gaveUpSwitchingBack)
    }

    @Test func deferredGaveUpThenARestartStartsANewRound() {
        var t = SystemInputPlan.Tracker()
        var m = SystemInputPlan.DeferredMonitor(original: Ref(usb), replacementUID: builtIn.uid,
                                                retrySince: 0, switchBackGaveUp: true)
        t.update(snap([builtIn, usb, mic], builtIn), now: 50)
        #expect(m.observe(snap([builtIn, usb, mic], builtIn), tracker: t, callEnded: false, now: 50) == .wait(.switchBackFailed))
        t.update(restarted([builtIn, usb, mic], builtIn, 1), now: 60)
        #expect(m.observe(restarted([builtIn, usb, mic], builtIn, 1), tracker: t, callEnded: false, now: 60) == .switchToMic)
        #expect(!m.switchBackGaveUp && m.retrySince == nil)
    }

    @Test func deferredFollowsMacOSPickMovingOnRightAfterTheVanish() {
        var t = SystemInputPlan.Tracker()
        var m = SystemInputPlan.DeferredMonitor(original: Ref(usb), replacementUID: nil)
        func step(_ s: SystemInputPlan.Snapshot, _ now: Double, ended: Bool = false) -> SystemInputPlan.DeferredDecision {
            t.update(s, now: now)
            return m.observe(s, tracker: t, callEnded: ended, now: now)
        }
        _ = step(snap([builtIn, usb, usb2, mic], mic), 0)
        #expect(step(snap([builtIn, usb, usb2], builtIn), 10) == .wait(.micAbsent))
        // 1.5 s later macOS settles on usb2: still its pick, not a drop during the call.
        #expect(step(snap([builtIn, usb, usb2], usb2), 11.5) == .wait(.micAbsent))
        #expect(m.replacementUID == usb2.uid)
        // Long after, a change is yours.
        #expect(step(snap([builtIn, usb, usb2], builtIn), 40) == .dropRecord(.changedTo(builtIn)))
    }
}
