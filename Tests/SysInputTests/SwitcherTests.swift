import Darwin
import Foundation
import Testing
import TalkTalkAudio
import TalkTalkCore
import TalkTalkTestSupport

@MainActor
final class SwitcherRig {
    let paths: SysInputPaths
    let trail = EventTrail()
    let hal: FakeHAL
    let procs: FakeProcesses
    let clock: FakeClock
    let launcher: FakeLauncher
    let meetingSwitch: FakeMeetingSwitch
    let switcher: SystemInputSwitcher
    var notices: [SystemInputSwitcher.Notice] = []
    var terminated: [Int32] = []

    init(paths: SysInputPaths? = nil, hal: FakeHAL? = nil, procs: FakeProcesses? = nil, clock: FakeClock = FakeClock(),
         bundleID: String = BuildFlavor.release.rawValue, executablePath: String = "/Applications/TalkTalk.app/Contents/MacOS/TalkTalk",
         pidRuns: (@Sendable (Int32, String) -> Bool)? = nil, terminate: (@Sendable (Int32) -> Void)? = nil,
         driver: FakeMeetingSwitch.Driver = .v020, config: SystemInputPlan.Config = .default,
         meetingSwitch shared: FakeMeetingSwitch? = nil) throws {
        let paths = try paths ?? tempPaths()
        self.paths = paths
        let trail = self.trail
        self.hal = hal ?? FakeHAL(devices: [Devs.builtIn, Devs.usb, Devs.mic], defaultUID: Devs.usb.uid, trail: trail)
        self.procs = procs ?? FakeProcesses(FakeProcesses.zoomInCall)
        self.clock = clock
        launcher = FakeLauncher(trail: trail)
        // One driver per machine: rigs that share a HAL share its switch too.
        let sw = shared ?? FakeMeetingSwitch(driver, trail: trail)
        meetingSwitch = sw
        self.hal.micSelectable = { sw.micCanBeDefault() == true }
        let deps = SystemInputSwitcher.Dependencies(
            hal: self.hal, processes: self.procs, paths: paths, launcher: launcher, bundleID: bundleID,
            executablePath: executablePath, config: config, now: { clock.now },
            closePassthrough: { trail.add("passthrough:off") },
            pidRuns: pidRuns ?? { _, _ in false },
            terminate: terminate ?? { _ in },
            autoRefresh: false,
            meetingSwitch: sw)
        switcher = SystemInputSwitcher(deps)
        switcher.onNotice = { [weak self] in self?.notices.append($0) }
    }

    var store: SysInputRecordStore { SysInputRecordStore(paths: paths) }
    var lockFree: Bool { SysInputLock.isAvailable(path: paths.lock.path) }

    func tick(_ dt: Double = 0) {
        clock.advance(dt)
        switcher.refresh()
    }
}

@MainActor @Suite(.serialized, .temporaryFiles) struct SwitcherEntryAndRestoreTests {
    @Test func enterWritesRecordThenLaunchesGuardThenSwitches() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        let store = rig.store
        let trail = rig.trail
        rig.hal.onWrite = { uid in
            // The record (0600) exists before TalkTalk Mic is written.
            if uid == Devs.mic.uid { trail.add(store.exists ? "record:present" : "record:missing") }
        }
        #expect(rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"]) == .switched)
        #expect(rig.hal.defaultInputUID() == Devs.mic.uid)
        #expect(rig.trail.all == ["guard:launch", "ttmm:1", "record:present", "write:\(Devs.mic.uid)"])
        let r = rig.store.read()
        #expect(r?.original == .init(Devs.usb))
        #expect(r?.writerBundleID == "com.aaajiao.talktalk")
        #expect(r?.writerPID == getpid())
        #expect(r?.guardPID == rig.launcher.last?.pid)
        #expect(r?.meetingApps == ["us.zoom.xos"])
        #expect(mode(of: rig.paths.record.path) == 0o600)
        #expect(!rig.lockFree)
        #expect(rig.launcher.last?.lockFD ?? -1 >= 0)
        #expect(rig.switcher.status == .holding(original: Devs.usb.name))
    }

    @Test func micMissingDoesNotSwitch() throws {
        let hal = FakeHAL(devices: [Devs.builtIn, Devs.usb], defaultUID: Devs.usb.uid)
        let rig = try SwitcherRig(hal: hal)
        rig.switcher.start()
        #expect(rig.switcher.enterMeetingMode(meetingApps: []) == .micMissing)
        #expect(hal.writeCount == 0)
        #expect(!rig.store.exists)
        #expect(rig.lockFree)
        #expect(rig.launcher.count == 0)
    }

    @Test func writeFailureUndoesEverything() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        rig.hal.failWrites = true
        #expect(rig.switcher.enterMeetingMode(meetingApps: []) == .writeFailed)
        #expect(!rig.store.exists)
        #expect(rig.launcher.last?.quitCalled == true)
        #expect(rig.lockFree)
    }

    @Test func switchOffOnlyMarksMeetingMode() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        #expect(rig.switcher.enterMeetingMode(meetingApps: [], switchDefaultInput: false) == .unchanged)
        #expect(rig.hal.writeCount == 0)
        // Meeting mode on: the no-record invariant pauses even if Mic becomes default.
        rig.hal.setDefault(Devs.mic.uid)
        rig.tick(1)
        #expect(rig.hal.writeCount == 0)
    }

    @Test func endWithCallEndedRestoresInTheFixedOrder() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"])
        rig.procs.set([])   // Zoom quit: the call is over
        rig.tick(2)
        #expect(!rig.switcher.needsEndConfirmation)
        #expect(rig.switcher.endMeetingMode(decision: .whenCallEnds) == .restored(device: Devs.usb.name))
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
        #expect(!rig.store.exists)
        #expect(rig.lockFree)
        let t = rig.trail.all
        // passthrough off → write → (read back) → record deleted → guard told → lock released.
        #expect(Array(t.suffix(4)) == ["passthrough:off", "write:\(Devs.usb.uid)", "ttmm:0", "guard:quit"])
        #expect(rig.switcher.status == .idle)
        #expect(rig.notices.last == .restored(device: Devs.usb.name, note: nil))
    }

    @Test func endWithCallOnDefersUntilThirtyQuietSeconds() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"])
        rig.tick(2)
        #expect(rig.switcher.needsEndConfirmation)
        #expect(rig.switcher.endMeetingMode(decision: .whenCallEnds) == .deferred)
        #expect(rig.switcher.status == .deferred(original: Devs.usb.name))
        #expect(rig.hal.defaultInputUID() == Devs.mic.uid)
        #expect(rig.store.exists)
        rig.procs.set(FakeProcesses.zoomIdle)   // muted, then hung up but app still open
        rig.tick(2)
        rig.tick(29)
        #expect(rig.hal.defaultInputUID() == Devs.mic.uid)
        rig.tick(2)
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
        #expect(!rig.store.exists)
        #expect(rig.lockFree)
        #expect(rig.switcher.status == .idle)
    }

    @Test func restoreNowFromTheDialogOrMenu() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        #expect(rig.switcher.endMeetingMode(decision: .whenCallEnds) == .deferred)
        #expect(rig.switcher.restoreNow() == .restored(device: Devs.usb.name))
        #expect(!rig.store.exists)

        let rig2 = try SwitcherRig()
        rig2.switcher.start()
        _ = rig2.switcher.enterMeetingMode(meetingApps: [])
        #expect(rig2.switcher.endMeetingMode(decision: .restoreNow) == .restored(device: Devs.usb.name))
    }

    @Test func manualChangeDuringDeferredOnlyDeletesRecord() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        _ = rig.switcher.endMeetingMode(decision: .whenCallEnds)
        let writes = rig.hal.writeCount
        rig.hal.setDefault(Devs.builtIn.uid)
        rig.tick(1)
        #expect(rig.hal.writeCount == writes)
        #expect(!rig.store.exists)
        #expect(rig.lockFree)
        #expect(rig.switcher.status == .idle)
    }

    @Test func restoreTargetFallsBackWhenOriginalLeft() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        rig.hal.set(devices: [Devs.builtIn, Devs.mic], defaultUID: Devs.mic.uid)   // the USB mic was unplugged
        rig.procs.set([])
        rig.tick(1)
        #expect(rig.switcher.endMeetingMode(decision: .whenCallEnds) == .restored(device: Devs.builtIn.name))
        #expect(rig.notices.last == .restored(device: Devs.builtIn.name, note: .originalMissing(name: Devs.usb.name)))
    }

    @Test func nothingPhysicalKeepsRecordAndGoesRed() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        rig.hal.set(devices: [Devs.mic, Devs.tuwa], defaultUID: Devs.mic.uid)
        rig.procs.set([])
        rig.tick(1)
        #expect(rig.switcher.endMeetingMode(decision: .whenCallEnds) == .noRestoreTarget)
        #expect(rig.store.exists)
        #expect(rig.switcher.status == .noRestoreTarget)
        #expect(rig.hal.defaultInputUID() == Devs.mic.uid)
    }

    @Test func sleepKeepsEverythingAndWakeSwitchesBack() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        rig.switcher.meetingSuspended()
        // Across sleep coreaudiod re-arbitrates: no classification while suspended.
        rig.hal.set(devices: [Devs.builtIn, Devs.usb], defaultUID: Devs.builtIn.uid)
        rig.tick(5)
        #expect(rig.store.exists)
        rig.hal.set(devices: [Devs.builtIn, Devs.usb, Devs.mic], defaultUID: Devs.builtIn.uid)
        rig.tick(1)
        rig.switcher.meetingResumed()
        #expect(rig.hal.defaultInputUID() == Devs.mic.uid)
        #expect(rig.switcher.status == .holding(original: Devs.usb.name))
    }

    @Test func guardRestartedWhenItDies() async throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        #expect(rig.launcher.count == 1)
        rig.launcher.simulateExit()
        for _ in 0..<200 where rig.launcher.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(rig.launcher.count == 2)
        #expect(rig.store.read()?.guardPID == rig.launcher.last?.pid)
    }
}

@MainActor @Suite(.serialized, .temporaryFiles) struct SwitcherMeetingChangesTests {
    @Test func insertedHeadsetIsSwitchedBackOnce() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        rig.hal.set(devices: [Devs.builtIn, Devs.usb, Devs.mic, Devs.ear4], defaultUID: Devs.ear4.uid)
        rig.tick(0.4)
        #expect(rig.hal.defaultInputUID() == Devs.mic.uid)
        #expect(rig.notices.contains(.switchedBackAfterInsert(device: Devs.ear4.name)))
        // macOS grabs it again within 10 s: stop contesting, manual, record void.
        rig.hal.setDefault(Devs.ear4.uid)
        rig.tick(2)
        #expect(rig.hal.defaultInputUID() == Devs.ear4.uid)
        #expect(!rig.store.exists)
        #expect(rig.lockFree)
        #expect(rig.switcher.status == .overridden(by: Devs.ear4.name))
    }

    @Test func manualChangeVoidsRecordAndEndRestoresNothing() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        rig.hal.setDefault(Devs.builtIn.uid)
        rig.tick(1)
        #expect(rig.notices.contains(.manualChange(device: Devs.builtIn.name)))
        #expect(!rig.store.exists)
        let writes = rig.hal.writeCount
        #expect(rig.switcher.endMeetingMode(decision: SysInputDialogPlan.decision(.endMeeting)) == .nothingToRestore)
        #expect(rig.hal.writeCount == writes)
        #expect(rig.hal.defaultInputUID() == Devs.builtIn.uid)
    }

    @Test func switchBackToMicReusesTheOriginalBeforeTheVoid() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"])
        rig.hal.setDefault(Devs.builtIn.uid)
        rig.tick(1)
        #expect(!rig.store.exists)
        #expect(rig.switcher.switchBackToMic() == .switched)
        #expect(rig.hal.defaultInputUID() == Devs.mic.uid)
        #expect(rig.store.read()?.original == .init(Devs.usb))   // not built-in
        rig.procs.set([])
        rig.tick(1)
        #expect(rig.switcher.endMeetingMode(decision: .whenCallEnds) == .restored(device: Devs.usb.name))
    }

    @Test func micVanishAndReturnIsNotManual() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        rig.hal.set(devices: [Devs.builtIn, Devs.usb], defaultUID: nil)       // coreaudiod restart
        rig.tick(0.1)
        rig.hal.setDefault(Devs.builtIn.uid)
        rig.tick(0.1)
        #expect(rig.switcher.status == .waitingForMic(original: Devs.usb.name))
        #expect(rig.store.read()?.replacementUID == Devs.builtIn.uid)
        rig.hal.set(devices: [Devs.builtIn, Devs.usb, Devs.mic], defaultUID: Devs.builtIn.uid)
        rig.tick(1.7)
        #expect(rig.hal.defaultInputUID() == Devs.mic.uid)
        #expect(rig.store.exists)
        #expect(rig.store.read()?.replacementUID == nil)
        #expect(rig.switcher.status == .holding(original: Devs.usb.name))
    }
}

/// Regression tests for the phase-1 review (2026-11-04), one per finding.
@MainActor @Suite(.serialized, .temporaryFiles) struct SwitcherReviewTests {
    /// #1: macOS re-selected the returning Mic itself; the stale replacement must not survive.
    @Test func replacementExpiresWhenMacOSReselectsTheMic() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"])
        rig.hal.set(devices: [Devs.builtIn, Devs.usb], defaultUID: nil)
        rig.tick(0.1)
        rig.hal.setDefault(Devs.builtIn.uid)
        rig.tick(0.1)
        #expect(rig.store.read()?.replacementUID == Devs.builtIn.uid)
        rig.hal.set(devices: [Devs.builtIn, Devs.usb, Devs.mic], defaultUID: Devs.mic.uid)   // M0-T8 d3/d4
        rig.tick(0.5)
        #expect(rig.store.read()?.replacementUID == nil)
        #expect(rig.switcher.endMeetingMode(decision: .whenCallEnds) == .deferred)
        let writes = rig.hal.writeCount
        rig.hal.setDefault(Devs.builtIn.uid)       // you pick built-in during the call
        rig.tick(5)
        #expect(rig.hal.writeCount == writes)      // not "restored over macOS's pick"
        #expect(rig.hal.defaultInputUID() == Devs.builtIn.uid)
        #expect(!rig.store.exists)
        #expect(rig.lockFree)
    }

    /// #2: a virtual device you pick while the restore is deferred is your choice (not layer 4).
    @Test func virtualDeviceYouPickDuringDeferredIsLeftAlone() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"])
        #expect(rig.switcher.endMeetingMode(decision: .whenCallEnds) == .deferred)
        let writes = rig.hal.writeCount
        rig.hal.set(devices: [Devs.builtIn, Devs.usb, Devs.mic, Devs.tuwa], defaultUID: Devs.tuwa.uid)
        rig.tick(1)
        #expect(rig.hal.writeCount == writes)
        #expect(rig.hal.defaultInputUID() == Devs.tuwa.uid)
        #expect(!rig.store.exists)
        #expect(rig.switcher.status == .idle)
    }

    /// #3a: suspended → end after the call → the write fails → retried from the deferred state.
    @Test func failedRestoreFromSuspendedIsRetried() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"])
        rig.procs.set([])
        rig.tick(2)
        rig.switcher.meetingSuspended()
        rig.hal.failWrites = true
        #expect(rig.switcher.endMeetingMode(decision: .whenCallEnds) == .writeFailed)
        #expect(rig.switcher.status == .deferred(original: Devs.usb.name))
        #expect(rig.store.exists)
        rig.tick(2)
        #expect(rig.hal.defaultInputUID() == Devs.mic.uid)
        rig.hal.failWrites = false
        rig.tick(2)
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
        #expect(!rig.store.exists)
        #expect(rig.lockFree)
        #expect(rig.switcher.status == .idle)
    }

    /// #3b: "现在还原" during the call fails → the retry does not start waiting for the call to end.
    @Test func failedRestoreNowIsRetriedWithoutWaitingForTheCall() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"])   // Zoom in call
        rig.hal.failWrites = true
        #expect(rig.switcher.restoreNow() == .writeFailed)
        #expect(rig.switcher.status == .deferred(original: Devs.usb.name))
        rig.hal.failWrites = false
        rig.tick(2)
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
        #expect(!rig.store.exists)
        #expect(rig.lockFree)
    }

    /// #6: a guard that exits by itself gets handOff() (our pipe end closed) before the restart.
    @Test func guardThatExitedIsReleasedBeforeTheRestart() async throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        let first = try #require(rig.launcher.last)
        rig.launcher.simulateExit()
        for _ in 0..<200 where rig.launcher.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(rig.launcher.count == 2)
        #expect(first.handOffCalled)
        #expect(!first.quitCalled)
    }
}

/// Second review of the fixes (2026-11-05), one test per finding.
@MainActor @Suite(.serialized, .temporaryFiles) struct SwitcherReview2Tests {
    /// Last run's record, Tuwa picked by macOS after the reboot, the call still on: takeover → pending.
    func pendingRig(procs: [CallEndRule.Process]? = FakeProcesses.zoomInCall) throws -> SwitcherRig {
        let paths = try tempPaths()
        try SysInputRecordStore(paths: paths).write(SysInputRecord(original: .init(Devs.usb), writerBundleID: "x",
                                                                   writerPID: 999_999, executablePath: "/x",
                                                                   meetingApps: ["us.zoom.xos"]))
        let hal = FakeHAL(devices: [Devs.builtIn, Devs.usb, Devs.tuwa, Devs.krisp, Devs.mic], defaultUID: Devs.tuwa.uid)
        let rig = try SwitcherRig(paths: paths, hal: hal, procs: FakeProcesses(procs))
        rig.switcher.start()
        rig.switcher.beginLaunchTakeover()
        rig.tick(2.5)
        return rig
    }

    /// A: the takeover writes the layer-4 device into the record, so the guard it hands to keeps the rule.
    @Test func takeoverRecordsTheLayer4DeviceForTheGuard() throws {
        let rig = try pendingRig()
        #expect(rig.switcher.status == .pendingFromLastRun(original: Devs.usb.name))
        #expect(rig.store.read()?.layer4UID == Devs.tuwa.uid)
        #expect(rig.switcher.prepareForQuit(decision: .whenCallEnds) == .deferred)
        #expect(rig.launcher.last?.handOffCalled == true)
        #expect(rig.store.read()?.layer4UID == Devs.tuwa.uid)
        #expect(rig.hal.writeCount == 0)
    }

    /// Review 3 (a): no default input at the takeover; Tuwa appears as the default afterwards.
    @Test func takeoverWithoutADefaultLearnsTheLayer4DeviceLater() throws {
        let paths = try tempPaths()
        try SysInputRecordStore(paths: paths).write(SysInputRecord(original: .init(Devs.usb), writerBundleID: "x",
                                                                   writerPID: 999_999, executablePath: "/x",
                                                                   meetingApps: ["us.zoom.xos"]))
        let hal = FakeHAL(devices: [Devs.builtIn, Devs.usb, Devs.tuwa, Devs.mic], defaultUID: nil)
        let rig = try SwitcherRig(paths: paths, hal: hal)
        rig.switcher.start()
        rig.switcher.beginLaunchTakeover()
        rig.tick(2.5)
        #expect(rig.switcher.status == .pendingFromLastRun(original: Devs.usb.name))
        #expect(rig.store.read()?.layer4ArmedUntilUptime != nil)
        hal.setDefault(Devs.tuwa.uid)
        rig.tick(0.5)                              // within the 1 s window: macOS's pick
        #expect(rig.store.read()?.layer4UID == Devs.tuwa.uid)
        #expect(rig.store.read()?.layer4ArmedUntilUptime == nil)
        #expect(rig.store.exists)
        rig.procs.set([])
        rig.tick(2)
        #expect(hal.defaultInputUID() == Devs.usb.uid)
        #expect(!rig.store.exists)
    }

    /// C1: "通话结束后再还原" while pending keeps the layer-4 monitor (does not drop the record).
    @Test func endWhilePendingKeepsTheLayer4Monitor() throws {
        let rig = try pendingRig()
        #expect(rig.switcher.endMeetingMode(decision: .whenCallEnds) == .deferred)
        #expect(rig.switcher.status == .pendingFromLastRun(original: Devs.usb.name))
        rig.tick(2)
        #expect(rig.store.exists)
        #expect(rig.hal.defaultInputUID() == Devs.tuwa.uid)
        rig.procs.set([])
        rig.tick(2)
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
        #expect(!rig.store.exists)
    }

    /// C2: a virtual device you pick after the takeover is seen, so it is your choice.
    @Test func virtualDeviceYouPickAfterTheTakeoverIsLeftAlone() throws {
        let rig = try pendingRig()
        rig.hal.setDefault(Devs.krisp.uid)
        rig.tick(1)
        rig.procs.set([])
        rig.tick(2)
        #expect(rig.hal.writeCount == 0)
        #expect(rig.hal.defaultInputUID() == Devs.krisp.uid)
        #expect(!rig.store.exists)
        #expect(rig.lockFree)
    }

    /// B1: a failed "现在还原" does not make a later "通话结束后再还原" restore during the call.
    @Test func failedRestoreNowDoesNotOutliveTheNextMeeting() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"])
        rig.hal.failWrites = true
        #expect(rig.switcher.restoreNow() == .writeFailed)
        rig.hal.failWrites = false
        #expect(rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"]) == .switched)
        #expect(rig.switcher.endMeetingMode(decision: .whenCallEnds) == .deferred)
        rig.tick(2)
        rig.tick(2)
        #expect(rig.hal.defaultInputUID() == Devs.mic.uid)   // the call is still on
        #expect(rig.store.exists)
        rig.procs.set([])
        rig.tick(2)
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
    }

    /// B2: an automatic end's failed write is retried only once the call (now a new one) ends.
    @Test func failedRestoreAfterTheCallWaitsForANewCall() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"])
        rig.procs.set([])
        rig.tick(2)
        rig.hal.failWrites = true                     // devices re-enumerating
        #expect(rig.switcher.endMeetingMode(decision: .whenCallEnds) == .writeFailed)
        rig.procs.set(FakeProcesses.zoomInCall)       // you start the next call
        rig.hal.failWrites = false
        rig.tick(2)
        #expect(rig.hal.defaultInputUID() == Devs.mic.uid)
        #expect(rig.store.exists)
        rig.procs.set([])
        rig.tick(2)
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
    }

    /// D: "现在还原" in meeting mode that succeeds on a retry ends like a first-try success.
    @Test func restoreNowRetriedEndsVoidedLikeAFirstTrySuccess() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"])
        rig.hal.failWrites = true
        #expect(rig.switcher.restoreNow() == .writeFailed)
        rig.hal.failWrites = false
        rig.tick(2)
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
        #expect(!rig.store.exists)
        #expect(rig.switcher.switchBackToMic() == .switched)
        #expect(rig.hal.defaultInputUID() == Devs.mic.uid)
        #expect(rig.store.read()?.original == .init(Devs.usb))
    }

    /// E: a late exit notice from a guard we already let go leaves the current guard alone.
    @Test func lateExitOfAnOldGuardIsIgnored() async throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"])
        let a = try #require(rig.launcher.last)
        #expect(rig.switcher.restoreNow() == .restored(device: Devs.usb.name))
        #expect(a.quitCalled)
        #expect(rig.switcher.switchBackToMic() == .switched)
        let b = try #require(rig.launcher.last)
        #expect(b !== a)
        rig.launcher.simulateExit(0)                  // A's exit arrives now
        try await Task.sleep(for: .milliseconds(100))
        #expect(!b.handOffCalled)
        #expect(!b.quitCalled)
        #expect(rig.launcher.count == 2)
    }

    /// F: Mic came back during sleep; ending from suspended clears the stale replacement at once.
    @Test func endFromSuspendedClearsAStaleReplacement() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"])
        rig.hal.set(devices: [Devs.builtIn, Devs.usb], defaultUID: nil)
        rig.tick(0.1)
        rig.hal.setDefault(Devs.builtIn.uid)
        rig.tick(0.1)
        #expect(rig.store.read()?.replacementUID == Devs.builtIn.uid)
        rig.switcher.meetingSuspended()
        rig.hal.set(devices: [Devs.builtIn, Devs.usb, Devs.mic], defaultUID: Devs.mic.uid)
        #expect(rig.switcher.endMeetingMode(decision: .whenCallEnds) == .deferred)
        #expect(rig.store.read()?.replacementUID == nil)
        let writes = rig.hal.writeCount
        rig.hal.setDefault(Devs.builtIn.uid)
        rig.tick(1)
        #expect(rig.hal.writeCount == writes)
        #expect(!rig.store.exists)
    }
}

/// Fourth review (2026-11-05): (a1) the 1 s layer-4 window, (a2) finishByRule observes first,
/// (c) the driver's 'ttmm' meeting-mode switch (driver 0.2.0).
@MainActor @Suite(.serialized, .temporaryFiles) struct SwitcherReview4Tests {
    func armedRig() throws -> SwitcherRig {
        let paths = try tempPaths()
        try SysInputRecordStore(paths: paths).write(SysInputRecord(original: .init(Devs.usb), writerBundleID: "x",
                                                                   writerPID: 999_999, executablePath: "/x",
                                                                   meetingApps: ["us.zoom.xos"]))
        let hal = FakeHAL(devices: [Devs.builtIn, Devs.usb, Devs.tuwa, Devs.krisp, Devs.mic], defaultUID: nil)
        let rig = try SwitcherRig(paths: paths, hal: hal)
        rig.switcher.start()
        rig.switcher.beginLaunchTakeover()
        rig.tick(2.5)
        #expect(rig.switcher.status == .pendingFromLastRun(original: Devs.usb.name))
        return rig
    }

    /// Review 5 #1: the value written for the guard: takeover time + 1 s on the uptime clock, this boot.
    @Test func armDeadlineWrittenForTheGuard() throws {
        let rig = try armedRig()                 // takeover at clock 1002.5
        let r = try #require(rig.store.read())
        #expect(r.layer4ArmedUntilUptime == 1003.5)
        #expect(r.bootSessionUUID == SysInputProcess.bootSessionUUID())
        #expect(r.bootSessionUUID != nil)
    }

    /// Review 5 #2: the stale-'ttmm' release holds the lock: the other build cannot take it in between.
    @Test func idleReleaseHoldsTheLockAgainstTheOtherBuild() throws {
        let rig = try SwitcherRig()
        _ = rig.meetingSwitch.setMeetingMode(true)
        let lockPath = rig.paths.lock.path
        let otherGotLock = EventTrail()
        // The second read is inside the release, after the lock check: the other build tries now.
        rig.meetingSwitch.onRead = { n in
            guard n == 2 else { return }
            let other = SysInputLock(path: lockPath)
            if other.tryAcquire() { otherGotLock.add("got"); other.release() }
        }
        rig.switcher.start()
        #expect(otherGotLock.all.isEmpty)
        #expect(!rig.meetingSwitch.value)
        #expect(rig.lockFree)
    }

    /// (a1) Krisp first appears 1.5 s after the takeover: your choice → only the record goes.
    @Test func defaultAppearingAfterTheWindowIsYours() throws {
        let rig = try armedRig()
        rig.tick(1.5)
        #expect(rig.store.read()?.layer4ArmedUntilUptime == nil)
        rig.hal.setDefault(Devs.krisp.uid)
        rig.tick(0.5)
        rig.procs.set([])
        rig.tick(1)
        #expect(rig.hal.writeCount == 0)
        #expect(rig.hal.defaultInputUID() == Devs.krisp.uid)
        #expect(!rig.store.exists)
    }

    /// (a2) Tuwa appears and you click "现在还原" before any refresh: still restored, not dropped.
    @Test func restoreNowBeforeARefreshStillKnowsTheLayer4Device() throws {
        let rig = try armedRig()
        rig.hal.setDefault(Devs.tuwa.uid)
        #expect(rig.switcher.restoreNow() == .restored(device: Devs.usb.name))
        #expect(rig.hal.writes == [Devs.usb.uid])
        #expect(!rig.store.exists)
    }

    /// (c) Writing 'ttmm' = 1 is refused: no record, no switch, HUD result.
    @Test func refusedMeetingModeSwitchLeavesNothing() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        rig.meetingSwitch.refuse = true
        #expect(rig.switcher.enterMeetingMode(meetingApps: []) == .micNotSelectable)
        #expect(rig.hal.writeCount == 0)
        #expect(!rig.store.exists)
        #expect(rig.lockFree)
        #expect(rig.launcher.last?.quitCalled == true)
    }

    /// (c) 'ttmm' = 1 accepted but CanBeDefaultDevice never becomes 1: undone, 'ttmm' back to 0.
    @Test func micThatNeverBecomesSelectableIsUndone() throws {
        var config = SystemInputPlan.Config.default
        config.micSelectableTimeout = 0.05
        let rig = try SwitcherRig(config: config)
        rig.switcher.start()
        rig.meetingSwitch.neverSelectable = true
        #expect(rig.switcher.enterMeetingMode(meetingApps: []) == .micNotSelectable)
        #expect(rig.meetingSwitch.writes == [true, false])
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
        #expect(!rig.store.exists)
        #expect(rig.lockFree)
    }

    /// (c) Driver 0.1.0 has no 'ttmm': nothing is written, entry and restore work as before.
    @Test func oldDriverWithoutTheSwitch() throws {
        let rig = try SwitcherRig(driver: .v010)
        rig.switcher.start()
        #expect(rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"]) == .switched)
        rig.procs.set([])
        rig.tick(1)
        #expect(rig.switcher.endMeetingMode(decision: .whenCallEnds) == .restored(device: Devs.usb.name))
        #expect(rig.meetingSwitch.writes.isEmpty)
    }

    @Test func selectableMicStillRecordsSessionModeAndReleasesItOnEnd() throws {
        let rig = try SwitcherRig(driver: .v023)
        rig.switcher.start()
        #expect(rig.meetingSwitch.micCanBeDefault() == true)
        #expect(!rig.meetingSwitch.value)
        #expect(rig.switcher.enterMeetingMode(meetingApps: ["com.apple.mobilephone"]) == .switched)
        #expect(rig.meetingSwitch.value)
        #expect(rig.meetingSwitch.writes == [true])
        #expect(rig.switcher.endMeetingMode(decision: .restoreNow) == .restored(device: Devs.usb.name))
        #expect(rig.meetingSwitch.writes == [true, false])
        #expect(rig.meetingSwitch.micCanBeDefault() == true)
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
    }

    @Test func selectableCapabilityDoesNotBypassRefusedSessionMode() throws {
        let rig = try SwitcherRig(driver: .v023)
        rig.switcher.start()
        rig.meetingSwitch.refuse = true
        #expect(rig.meetingSwitch.micCanBeDefault() == true)
        #expect(rig.switcher.enterMeetingMode(meetingApps: []) == .micNotSelectable)
        #expect(rig.hal.writeCount == 0)
        #expect(!rig.store.exists)
        #expect(rig.lockFree)
        #expect(rig.launcher.last?.quitCalled == true)
    }

    /// (c) Your manual change voids the record and ends the driver's session mode.
    @Test func voidedRecordReleasesTheSwitch() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        #expect(rig.meetingSwitch.value)
        rig.hal.setDefault(Devs.builtIn.uid)
        rig.tick(1)
        #expect(!rig.store.exists)
        #expect(!rig.meetingSwitch.value)
        #expect(rig.switcher.switchBackToMic() == .switched)   // sets it again
        #expect(rig.meetingSwitch.value)
        #expect(rig.hal.defaultInputUID() == Devs.mic.uid)
    }

    /// (c) The Mic re-entered the list (the driver reset 'ttmm'): the switch-back sets it again first.
    @Test func micReturnSetsTheSwitchAgain() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        rig.hal.set(devices: [Devs.builtIn, Devs.usb], defaultUID: nil)
        rig.tick(0.1)
        rig.hal.setDefault(Devs.builtIn.uid)
        rig.tick(0.1)
        rig.meetingSwitch.driverReset()
        rig.hal.set(devices: [Devs.builtIn, Devs.usb, Devs.mic], defaultUID: Devs.builtIn.uid)
        rig.tick(1.7)
        #expect(rig.meetingSwitch.value)
        #expect(rig.hal.defaultInputUID() == Devs.mic.uid)
    }

    /// Review 5 #5: the switch back after a headset insert fails once; the next refresh retries,
    /// the record stays (not "you changed it").
    @Test func failedSwitchBackRetriesInsteadOfVoiding() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        rig.hal.failWrites = true
        rig.hal.set(devices: [Devs.builtIn, Devs.usb, Devs.mic, Devs.ear4], defaultUID: Devs.ear4.uid)
        rig.tick(0.4)
        #expect(rig.hal.defaultInputUID() == Devs.ear4.uid)
        #expect(rig.store.exists)
        rig.hal.failWrites = false
        rig.tick(1)
        #expect(rig.hal.defaultInputUID() == Devs.mic.uid)
        #expect(rig.store.exists)
        #expect(rig.switcher.status == .holding(original: Devs.usb.name))
        #expect(!rig.notices.contains(.manualChange(device: Devs.ear4.name)))
    }

    /// (c) Quit with the call on: the guard takes over and 'ttmm' stays 1 (the Mic stays the default).
    @Test func handOffKeepsTheSwitch() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        #expect(rig.switcher.prepareForQuit(decision: .whenCallEnds) == .deferred)
        #expect(rig.meetingSwitch.value)
    }

    /// (c) A 1 left by a crash is set back to 0 at idle; not while meeting mode is on (switch off).
    @Test func staleSwitchIsReleasedAtIdle() throws {
        let rig = try SwitcherRig()
        _ = rig.meetingSwitch.setMeetingMode(true)
        rig.switcher.start()
        #expect(!rig.meetingSwitch.value)

        let other = try SwitcherRig()
        other.switcher.start()
        _ = other.switcher.enterMeetingMode(meetingApps: [], switchDefaultInput: false)
        _ = other.meetingSwitch.setMeetingMode(true)
        other.tick(2)
        #expect(other.meetingSwitch.value)
    }
}

@MainActor @Suite(.serialized, .temporaryFiles) struct SwitcherOwnershipTests {
    @Test func noRecordInvariantPutsPhysicalBackWithinOneRefresh() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()                     // remembers USB as the last physical default
        rig.hal.setDefault(Devs.mic.uid)         // macOS re-selected TalkTalk Mic (M0-T8 d3)
        rig.tick(0.1)
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
        #expect(rig.notices == [.invariantRestored(device: Devs.usb.name)])
    }

    @Test func idleRestoreHoldsOwnershipLockWhileWriting() throws {
        let rig = try SwitcherRig(driver: .v023)
        rig.switcher.start()
        rig.hal.setDefault(Devs.mic.uid)
        let lockPath = rig.paths.lock.path
        let lockObservations = EventTrail()
        rig.hal.onWrite = { _ in
            lockObservations.add(SysInputLock.isAvailable(path: lockPath) ? "free" : "held")
        }
        rig.tick()
        #expect(lockObservations.all == ["held"])
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
        #expect(rig.lockFree)
    }

    @Test func idleRestoreLeavesASelectionChangedAfterItsFreshSnapshot() throws {
        let rig = try SwitcherRig(driver: .v023)
        rig.switcher.start()
        rig.hal.setDefault(Devs.mic.uid)
        let hal = rig.hal
        var snapshots = 0
        hal.afterSnapshot = { _ in
            snapshots += 1
            if snapshots == 2 { hal.setDefault(Devs.builtIn.uid) }
        }
        rig.tick()
        #expect(snapshots == 2)
        #expect(rig.hal.writeCount == 0)
        #expect(rig.hal.defaultInputUID() == Devs.builtIn.uid)
        #expect(rig.lockFree)
    }

    @Test func idleRestoreRechecksARecordCreatedAfterItsFreshSnapshot() throws {
        let rig = try SwitcherRig(driver: .v023)
        rig.switcher.start()
        rig.hal.setDefault(Devs.mic.uid)
        let record = SysInputRecord(original: .init(Devs.usb), writerBundleID: "other",
                                   executablePath: "/other")
        let store = rig.store
        var snapshots = 0
        rig.hal.afterSnapshot = { _ in
            snapshots += 1
            if snapshots == 2 { try? store.write(record) }
        }
        rig.tick()
        let saved = try #require(store.read())
        #expect(saved.writerBundleID == "other")
        #expect(rig.hal.writeCount == 0)
        #expect(rig.hal.defaultInputUID() == Devs.mic.uid)
        #expect(rig.lockFree)
    }

    @Test func idleRestoreStopsWhenMeetingIntentBeginsDuringItsFreshSnapshot() throws {
        let rig = try SwitcherRig(driver: .v023)
        rig.switcher.start()
        rig.hal.setDefault(Devs.mic.uid)
        var snapshots = 0
        rig.hal.afterSnapshot = { _ in
            snapshots += 1
            if snapshots == 2 {
                _ = rig.switcher.enterMeetingMode(meetingApps: [], switchDefaultInput: false)
            }
        }
        rig.tick()
        #expect(rig.hal.writeCount == 0)
        #expect(rig.hal.defaultInputUID() == Devs.mic.uid)
        #expect(rig.switcher.isMeetingModeOn)
        #expect(rig.lockFree)
    }

    @Test func earlyStartKeepsBaselineWhenTheControllerStartsAgain() throws {
        let rig = try SwitcherRig(driver: .v023)
        rig.switcher.start()
        rig.hal.setDefault(Devs.mic.uid)
        rig.switcher.start()
        rig.tick()
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
        #expect(rig.notices == [.invariantRestored(device: Devs.usb.name)])
    }

    @Test func otherBuildOwnsItSoWeChangeNothing() throws {
        let paths = try tempPaths()
        let hal = FakeHAL(devices: [Devs.builtIn, Devs.usb, Devs.mic], defaultUID: Devs.usb.uid)
        let procs = FakeProcesses(FakeProcesses.zoomInCall)
        let ttmm = FakeMeetingSwitch()
        let release = try SwitcherRig(paths: paths, hal: hal, procs: procs, meetingSwitch: ttmm)
        let dev = try SwitcherRig(paths: paths, hal: hal, procs: procs, bundleID: BuildFlavor.dev.rawValue,
                              executablePath: "/x/TalkTalk-Dev.app/Contents/MacOS/TalkTalk", meetingSwitch: ttmm)
        release.switcher.start()
        dev.switcher.start()
        dev.switcher.beginLaunchTakeover()
        #expect(release.switcher.enterMeetingMode(meetingApps: []) == .switched)
        let writes = hal.writeCount
        // The dev build: no switching, no restoring, no invariant.
        #expect(dev.switcher.enterMeetingMode(meetingApps: []) == .otherInstanceManages)
        #expect(dev.switcher.status == .otherInstanceManages)
        #expect(dev.switcher.endMeetingMode(decision: .restoreNow) == .notOwner)
        #expect(dev.switcher.restoreNow() == .notOwner)
        dev.tick(3)
        #expect(dev.switcher.status == .otherInstanceManages)
        #expect(dev.launcher.count == 0)
        #expect(hal.writeCount == writes)
        #expect(hal.defaultInputUID() == Devs.mic.uid)
        // Release ends: dev goes idle, and the invariant would work for dev again.
        procs.set([])
        release.tick(1)
        _ = release.switcher.endMeetingMode(decision: .whenCallEnds)
        dev.tick(1)
        #expect(dev.switcher.status == .idle)
    }

    @Test func invariantSkipsWhileAnyRecordExists() throws {
        let paths = try tempPaths()
        try? SysInputRecordStore(paths: paths).write(SysInputRecord(original: .init(Devs.usb), writerBundleID: "x",
                                                                   executablePath: "/x"))
        let hal = FakeHAL(devices: [Devs.builtIn, Devs.usb, Devs.mic], defaultUID: Devs.mic.uid)
        let rig = try SwitcherRig(paths: paths, hal: hal)
        rig.switcher.start()     // no takeover armed yet (Feed not attached)
        rig.tick(1)
        #expect(hal.writeCount == 0)
    }

    @Test func takeoverChecksTheExecutablePathBeforeSignalling() throws {
        let paths = try tempPaths()
        // An old "guard" (/bin/sleep) holding the lock via an inherited descriptor.
        let holderLock = SysInputLock(path: paths.lock.path)
        #expect(holderLock.tryAcquire())
        let old = try #require(Spawned.run("/bin/sleep", ["300"], inherit: [holderLock.fd]))
        holderLock.detach()
        defer { old.kill(SIGKILL); _ = old.wait(timeout: 5) }
        let store = SysInputRecordStore(paths: paths)
        try store.write(SysInputRecord(original: .init(Devs.usb), writerBundleID: BuildFlavor.dev.rawValue,
                                       writerPID: 999_999, executablePath: "/not/our/binary", guardPID: old.pid))
        let hal = FakeHAL(devices: [Devs.builtIn, Devs.usb, Devs.mic], defaultUID: Devs.mic.uid)
        let killed = EventTrail()
        let rig = try SwitcherRig(paths: paths, hal: hal, pidRuns: SysInputProcess.runs,
                              terminate: { killed.add("\($0)"); _ = kill($0, SIGTERM) })
        rig.switcher.start()
        rig.switcher.beginLaunchTakeover()
        rig.tick(2.1)
        // Path does not match: not signalled, not ours.
        #expect(killed.all.isEmpty)
        #expect(rig.switcher.status == .otherInstanceManages)
        #expect(hal.writeCount == 0)

        // Same record naming /bin/sleep's real path: signalled, lock taken, record ours.
        var r = try #require(store.read())
        r.executablePath = SysInputProcess.resolved("/bin/sleep")
        try store.write(r)
        let rig2 = try SwitcherRig(paths: paths, hal: hal, pidRuns: SysInputProcess.runs,
                               terminate: { killed.add("\($0)"); _ = kill($0, SIGTERM) })
        rig2.switcher.start()
        rig2.switcher.beginLaunchTakeover()
        rig2.tick(2.1)
        #expect(killed.all == ["\(old.pid)"])
        #expect(rig2.switcher.status == .pendingFromLastRun(original: Devs.usb.name))   // call still on
        #expect(rig2.store.read()?.writerBundleID == BuildFlavor.release.rawValue)    // shared record, now release's
        #expect(rig2.launcher.count == 1)
        // The call ends → restores by itself.
        rig2.procs.set([])
        rig2.tick(1)
        #expect(hal.defaultInputUID() == Devs.usb.uid)
        #expect(!rig2.store.exists)
    }

    @Test func takeoverWithPhysicalDefaultOnlyDeletesTheRecord() throws {
        let paths = try tempPaths()
        try SysInputRecordStore(paths: paths).write(SysInputRecord(original: .init(Devs.usb), writerBundleID: "x",
                                                                   writerPID: 999_999, executablePath: "/x"))
        let hal = FakeHAL(devices: [Devs.builtIn, Devs.usb], defaultUID: Devs.builtIn.uid)
        let rig = try SwitcherRig(paths: paths, hal: hal)
        rig.switcher.start()
        rig.switcher.beginLaunchTakeover()
        rig.tick(1)
        #expect(rig.store.exists)     // waits the 2 s settle after the Feed is attached
        rig.tick(1.5)
        #expect(!rig.store.exists)
        #expect(hal.writeCount == 0)
        #expect(rig.lockFree)
    }

    @Test func takeoverAfterRebootWithTuwaDefaultRestores() throws {
        let paths = try tempPaths()
        try SysInputRecordStore(paths: paths).write(SysInputRecord(original: .init(Devs.usb), writerBundleID: "x",
                                                                   writerPID: 999_999, executablePath: "/x"))
        let hal = FakeHAL(devices: [Devs.builtIn, Devs.usb, Devs.tuwa, Devs.mic], defaultUID: Devs.tuwa.uid)
        let rig = try SwitcherRig(paths: paths, hal: hal, procs: FakeProcesses([]))
        rig.switcher.start()
        rig.switcher.beginLaunchTakeover()
        rig.tick(2.5)
        #expect(hal.defaultInputUID() == Devs.usb.uid)
        #expect(!rig.store.exists)
    }

    @Test func quitWithCallOnHandsOffToTheGuard() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        #expect(rig.switcher.needsEndConfirmation)
        #expect(rig.switcher.prepareForQuit(decision: .whenCallEnds) == .deferred)
        #expect(rig.launcher.last?.handOffCalled == true)
        #expect(rig.launcher.last?.quitCalled == false)
        #expect(rig.store.exists)
        #expect(rig.hal.defaultInputUID() == Devs.mic.uid)
    }

    @Test func noSignalHandlersAreInstalled() throws {
        func handlers() -> [UInt] {
            [SIGTERM, SIGINT, SIGHUP].map { sig in
                var old = sigaction()
                sigaction(sig, nil, &old)
                return unsafeBitCast(old.__sigaction_u.__sa_handler, to: UInt.self)
            }
        }
        let before = handlers()
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        _ = rig.switcher.endMeetingMode(decision: .whenCallEnds)
        #expect(handlers() == before)
        // So SIGTERM/SIGINT/SIGHUP just end the process; the record stays for the guard.
        #expect(rig.store.exists)
    }
}

/// Review of 54e9fca (2026-11-05): a switch back that keeps failing.
@MainActor @Suite(.serialized, .temporaryFiles) struct SwitcherReview6Tests {
    /// Mic gone, macOS picks built-in, the Mic returns but the driver reset 'ttmm' and refuses the
    /// write: the rig with the switch back failing.
    func failingRig() throws -> SwitcherRig {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        rig.hal.set(devices: [Devs.builtIn, Devs.usb], defaultUID: Devs.builtIn.uid)
        rig.tick(0.1)
        rig.meetingSwitch.driverReset()
        rig.meetingSwitch.refuse = true
        rig.hal.set(devices: [Devs.builtIn, Devs.usb, Devs.mic], defaultUID: Devs.builtIn.uid)
        rig.tick(0.5)
        return rig
    }

    func failNotices(_ rig: SwitcherRig) -> Int {
        rig.notices.filter { $0 == .switchBackFailed(device: Devs.builtIn.name) }.count
    }

    /// #1: the status says what the default really is, one HUD notice, retries for contestWindow,
    /// then stops with the record kept; #3: macOS's pick stays the replacement, so "现在还原"
    /// restores the original.
    @Test func failedSwitchBackIsShownCappedAndStillRestored() throws {
        let rig = try failingRig()
        #expect(rig.hal.defaultInputUID() == Devs.builtIn.uid)
        #expect(rig.switcher.status == .switchBackFailed(current: Devs.builtIn.name, retrying: true))
        #expect(failNotices(rig) == 1)
        #expect(rig.store.read()?.replacementUID == Devs.builtIn.uid)
        rig.tick(2)
        rig.tick(2)
        #expect(rig.switcher.status == .switchBackFailed(current: Devs.builtIn.name, retrying: true))
        #expect(failNotices(rig) == 1)
        rig.tick(6)                                     // 10 s since the first failure
        #expect(rig.switcher.status == .switchBackFailed(current: Devs.builtIn.name, retrying: false))
        rig.tick(30)
        #expect(rig.switcher.status == .switchBackFailed(current: Devs.builtIn.name, retrying: false))
        #expect(rig.store.exists)
        #expect(!rig.notices.contains(.manualChange(device: Devs.builtIn.name)))
        #expect(rig.store.read()?.replacementUID == Devs.builtIn.uid)
        #expect(rig.switcher.endMeetingMode(decision: .restoreNow) == .restored(device: Devs.usb.name))
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
        #expect(!rig.store.exists)
    }

    /// The menu's "切回 TalkTalk Mic" that fails starts a new round (notice again), never voids;
    /// once the driver accepts, it switches and the replacement is gone.
    @Test func menuSwitchBackFailureIsRetriedNotVoided() throws {
        let rig = try failingRig()
        rig.tick(10)
        #expect(rig.switcher.status == .switchBackFailed(current: Devs.builtIn.name, retrying: false))
        #expect(rig.switcher.switchBackToMic() == .writeFailed)
        #expect(rig.switcher.status == .switchBackFailed(current: Devs.builtIn.name, retrying: true))
        #expect(failNotices(rig) == 2)
        rig.tick(2)
        #expect(rig.store.exists)
        #expect(!rig.notices.contains(.manualChange(device: Devs.builtIn.name)))
        rig.meetingSwitch.refuse = false
        #expect(rig.switcher.switchBackToMic() == .switched)
        #expect(rig.hal.defaultInputUID() == Devs.mic.uid)
        #expect(rig.switcher.status == .holding(original: Devs.usb.name))
        #expect(rig.store.read()?.replacementUID == nil)
    }

    /// #4 in the app's deferred state: Mic gone with the call on → no restore during the call;
    /// it returns → the Mic again; the call ends → the original.
    @Test func deferredSwitchesBackWhenTheMicReturns() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        #expect(rig.switcher.endMeetingMode(decision: .whenCallEnds) == .deferred)
        rig.hal.set(devices: [Devs.builtIn, Devs.usb], defaultUID: Devs.builtIn.uid)
        rig.tick(0.1)
        rig.tick(1)
        #expect(rig.hal.defaultInputUID() == Devs.builtIn.uid)
        #expect(rig.switcher.status == .deferredOnPhysical(current: Devs.builtIn.name, micAbsent: true, fromLastRun: false))
        rig.meetingSwitch.driverReset()
        rig.hal.set(devices: [Devs.builtIn, Devs.usb, Devs.mic], defaultUID: Devs.builtIn.uid)
        rig.tick(0.5)
        #expect(rig.hal.defaultInputUID() == Devs.mic.uid)
        #expect(rig.meetingSwitch.value)
        #expect(rig.store.exists)
        rig.procs.set([])
        rig.tick(1)
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
        #expect(!rig.store.exists)
    }
}

/// Review of 9d9b3a4 (2026-11-05).
@MainActor @Suite(.serialized, .temporaryFiles) struct SwitcherReview7Tests {
    /// #2: the vanish snapshot shows no default; at the return the default is built-in and the
    /// switch back fails → "现在还原" still restores the original.
    @Test func replacementSeenOnlyAtTheReturnIsRestoredOver() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        rig.hal.set(devices: [], defaultUID: nil)
        rig.tick(0.1)
        rig.meetingSwitch.driverReset()
        rig.meetingSwitch.refuse = true
        rig.hal.set(devices: [Devs.builtIn, Devs.usb, Devs.mic], defaultUID: Devs.builtIn.uid)
        rig.tick(1)
        #expect(rig.switcher.status == .switchBackFailed(current: Devs.builtIn.name, retrying: true))
        #expect(rig.store.read()?.replacementUID == Devs.builtIn.uid)
        #expect(rig.switcher.endMeetingMode(decision: .restoreNow) == .restored(device: Devs.usb.name))
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
    }

    /// #3: ending "通话结束后再还原" during a failing switch back: the deferred state keeps
    /// switching back, never restores usb during the call, says what the default really is.
    @Test func handOverKeepsTheStickyState() throws {
        let rig = try SwitcherReview6Tests().failingRig()
        #expect(rig.switcher.endMeetingMode(decision: .whenCallEnds) == .deferred)
        #expect(rig.switcher.status == .deferredOnPhysical(current: Devs.builtIn.name, micAbsent: false, fromLastRun: false))
        rig.tick(2)
        rig.tick(2)
        #expect(!rig.hal.writes.contains(Devs.usb.uid))
        #expect(rig.store.exists)
        #expect(rig.switcher.status == .deferredOnPhysical(current: Devs.builtIn.name, micAbsent: false, fromLastRun: false))
        // Review of a7ef015 #2: the same round goes on: still the one notice from meeting mode.
        #expect(rig.notices.filter { $0 == .switchBackFailed(device: Devs.builtIn.name) }.count == 1)
        rig.procs.set([])
        rig.tick(1)
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
        #expect(!rig.store.exists)
    }

    /// #1: deferred, the Mic vanishes and returns, the switch back fails: one notice, a truthful
    /// status, retries stop after contestWindow, the record stays until the call ends.
    @Test func deferredSwitchBackFailureIsShownAndCapped() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        #expect(rig.switcher.endMeetingMode(decision: .whenCallEnds) == .deferred)
        rig.hal.set(devices: [Devs.builtIn, Devs.usb], defaultUID: Devs.builtIn.uid)
        rig.tick(0.1)
        rig.meetingSwitch.driverReset()
        rig.meetingSwitch.refuse = true
        rig.hal.set(devices: [Devs.builtIn, Devs.usb, Devs.mic], defaultUID: Devs.builtIn.uid)
        rig.tick(0.5)
        #expect(rig.switcher.status == .deferredOnPhysical(current: Devs.builtIn.name, micAbsent: false, fromLastRun: false))
        let failed = { rig.notices.filter { $0 == .switchBackFailed(device: Devs.builtIn.name) }.count }
        #expect(failed() == 1)
        let first = rig.meetingSwitch.attempts
        rig.tick(4)
        rig.tick(4)
        #expect(rig.meetingSwitch.attempts > first)       // still retrying
        rig.tick(4)                                       // past contestWindow
        let afterCap = rig.meetingSwitch.attempts
        rig.tick(4)
        rig.tick(4)
        #expect(rig.meetingSwitch.attempts == afterCap)   // stopped
        #expect(failed() == 1)
        #expect(rig.store.exists)
        #expect(!rig.hal.writes.contains(Devs.usb.uid))
        rig.procs.set([])
        rig.tick(1)
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
    }

    /// #6: a failing menu "切回 TalkTalk Mic" gives one HUD line (the switcher's), not two.
    @Test func menuSwitchBackFailureStatusStaysSwitchBackFailed() throws {
        let rig = try SwitcherReview6Tests().failingRig()
        #expect(rig.switcher.switchBackToMic() == .writeFailed)
        if case .switchBackFailed = rig.switcher.status {} else { Issue.record("status \(rig.switcher.status)") }
    }
}

/// Review of a7ef015 (2026-11-05): every waiting path says what the default really is; an entry
/// from a waiting state that fails keeps the record.
@MainActor @Suite(.serialized, .temporaryFiles) struct SwitcherReview8Tests {
    /// Deferred, then TalkTalk Mic gone and macOS on built-in (the record has it as replacement).
    func deferredMicGoneRig() throws -> SwitcherRig {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        _ = rig.switcher.endMeetingMode(decision: .whenCallEnds)
        rig.hal.set(devices: [Devs.builtIn, Devs.usb], defaultUID: Devs.builtIn.uid)
        rig.tick(0.1)
        return rig
    }
    let gone = SystemInputSwitcher.Status.deferredOnPhysical(current: Devs.builtIn.name, micAbsent: true, fromLastRun: false)

    /// keepWaiting while already deferred: entry fails (.micMissing), then "通话结束后再还原".
    @Test func reEndWhileTheMicIsGone() throws {
        let rig = try deferredMicGoneRig()
        #expect(rig.switcher.status == gone)
        #expect(rig.switcher.enterMeetingMode(meetingApps: []) == .micMissing)
        #expect(rig.switcher.endMeetingMode(decision: .whenCallEnds) == .deferred)
        #expect(rig.switcher.status == gone)
    }

    /// finishByRule's restore that fails (and keepWaiting after it).
    @Test func restoreNowThatFailsKeepsTheTruth() throws {
        let rig = try deferredMicGoneRig()
        rig.hal.failWrites = true
        #expect(rig.switcher.restoreNow() == .writeFailed)
        #expect(rig.switcher.status == gone)
        #expect(rig.store.exists)
    }

    /// apply(.wait(.devicesSettling)): right after a restart, the original not listed yet.
    @Test func restoreNowWhileTheOriginalIsNotBackYet() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        _ = rig.switcher.endMeetingMode(decision: .whenCallEnds)
        rig.hal.set(devices: [Devs.builtIn], defaultUID: Devs.builtIn.uid)
        rig.tick(0.1)
        #expect(rig.switcher.restoreNow() == .deferred)
        #expect(rig.switcher.status == gone)
        #expect(rig.store.exists)
        // The original comes back: the restore you asked for happens, the call still on.
        rig.hal.set(devices: [Devs.builtIn, Devs.usb], defaultUID: Devs.builtIn.uid)
        rig.tick(0.5)
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
        #expect(!rig.store.exists)
    }

    /// apply(.restore) that fails when the call ends.
    @Test func restoreAtTheCallEndThatFails() throws {
        let rig = try deferredMicGoneRig()
        rig.hal.failWrites = true
        rig.procs.set([])
        rig.tick(1)
        #expect(rig.switcher.status == gone)
        #expect(rig.store.exists)
        rig.hal.failWrites = false
        rig.tick(1)
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
    }

    /// #3: entering meeting mode from deferred when the Mic cannot be made the default: the record
    /// (with macOS's pick) goes back as it was, lock and guard kept, the status says the truth.
    @Test func failedEntryFromDeferredKeepsTheRecord() throws {
        let rig = try deferredMicGoneRig()
        rig.meetingSwitch.driverReset()
        rig.meetingSwitch.refuse = true
        rig.hal.set(devices: [Devs.builtIn, Devs.usb, Devs.mic], defaultUID: Devs.builtIn.uid)
        rig.tick(0.1)
        let before = try #require(rig.store.read())
        #expect(before.replacementUID == Devs.builtIn.uid)
        #expect(rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"]) == .micNotSelectable)
        let after = try #require(rig.store.read())
        #expect(after.replacementUID == Devs.builtIn.uid)
        #expect(after.original == before.original)
        #expect(!rig.lockFree)
        #expect(rig.switcher.status == .deferredOnPhysical(current: Devs.builtIn.name, micAbsent: false, fromLastRun: false))
        rig.procs.set([])
        rig.tick(1)
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
        #expect(!rig.store.exists)
    }

    /// #5: "现在还原" at quit that fails marks the record, so the guard keeps restoring.
    @Test func failedRestoreNowAtQuitMarksTheRecord() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        rig.hal.failWrites = true
        #expect(rig.switcher.prepareForQuit(decision: .restoreNow) == .writeFailed)
        #expect(rig.store.read()?.restoreNow == true)
        // "通话结束后再还原" at quit leaves it unset.
        let other = try SwitcherRig()
        other.switcher.start()
        _ = other.switcher.enterMeetingMode(meetingApps: [])
        #expect(other.switcher.prepareForQuit(decision: .whenCallEnds) == .deferred)
        #expect(other.store.read()?.restoreNow == nil)
    }

    /// #3: an entry that fails with no earlier record leaves nothing that implies one.
    @Test func failedFreshEntryIsIdle() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        rig.meetingSwitch.refuse = true
        #expect(rig.switcher.enterMeetingMode(meetingApps: []) == .micNotSelectable)
        #expect(rig.switcher.status == .idle)
        #expect(!rig.store.exists)
    }
}

/// Review of 37c505d (2026-11-05): a virtual macOS pick in the status line, "现在还原" kept by a
/// layer-4 takeover, the guard pid a failed entry writes back.
@MainActor @Suite(.serialized, .temporaryFiles) struct SwitcherReview9Tests {
    /// #1: deferred, TalkTalk Mic gone, macOS on a virtual device: the status names it, not
    /// "仍是 TalkTalk Mic"; a moment with no default input keeps that line.
    @Test func deferredOnAVirtualPickWithTheMicGone() throws {
        let rig = try SwitcherRig(hal: FakeHAL(devices: [Devs.builtIn, Devs.usb, Devs.krisp, Devs.mic], defaultUID: Devs.usb.uid))
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        _ = rig.switcher.endMeetingMode(decision: .whenCallEnds)
        rig.hal.set(devices: [Devs.builtIn, Devs.usb, Devs.krisp], defaultUID: Devs.krisp.uid)
        rig.tick(0.1)
        let line = SystemInputSwitcher.Status.deferredOnPhysical(current: Devs.krisp.name, micAbsent: true, fromLastRun: false)
        #expect(rig.switcher.status == line)
        #expect(rig.store.exists)
        rig.hal.set(devices: [Devs.builtIn, Devs.usb, Devs.krisp], defaultUID: nil)
        rig.tick(0.1)
        #expect(rig.switcher.status == line)
        #expect(rig.store.exists)
    }

    /// #2: last run's "现在还原" failed and the guard was retrying; the app is opened again during
    /// the call: the takeover restores, it does not switch back to TalkTalk Mic.
    @Test func takeoverOfARestoreNowRecordRestores() throws {
        let paths = try tempPaths()
        var rec = SysInputRecord(original: .init(Devs.usb), writerBundleID: "x", writerPID: 999_999,
                                 executablePath: "/x", meetingApps: ["us.zoom.xos"], replacementUID: Devs.builtIn.uid)
        rec.restoreNow = true
        try SysInputRecordStore(paths: paths).write(rec)
        let hal = FakeHAL(devices: [Devs.builtIn, Devs.usb, Devs.mic], defaultUID: Devs.builtIn.uid)
        let rig = try SwitcherRig(paths: paths, hal: hal)
        rig.switcher.start()
        rig.switcher.beginLaunchTakeover()
        rig.tick(2.5)
        rig.tick(0.5)
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
        #expect(!rig.store.exists)
    }

    /// #2: a new end decision clears the flag in the record too (the guard reads it there).
    @Test func newEndDecisionClearsRestoreNow() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        _ = rig.switcher.endMeetingMode(decision: .whenCallEnds)
        rig.hal.set(devices: [Devs.builtIn], defaultUID: Devs.builtIn.uid)   // the original not back yet
        rig.tick(0.1)
        #expect(rig.switcher.restoreNow() == .deferred)
        #expect(try #require(rig.store.read()).restoreNow == true)
        #expect(rig.switcher.endMeetingMode(decision: .whenCallEnds) == .deferred)
        #expect(try #require(rig.store.read()).restoreNow == nil)
    }

    /// #3: pending with no guard (it could not start at the takeover); entering meeting mode starts
    /// one, then fails: the record written back names that guard.
    @Test func failedEntryFromPendingRecordsTheNewGuard() throws {
        let paths = try tempPaths()
        try SysInputRecordStore(paths: paths).write(SysInputRecord(original: .init(Devs.usb), writerBundleID: "x",
                                                                   writerPID: 999_999, executablePath: "/x",
                                                                   meetingApps: ["us.zoom.xos"]))
        let hal = FakeHAL(devices: [Devs.builtIn, Devs.usb, Devs.tuwa, Devs.mic], defaultUID: Devs.tuwa.uid)
        let rig = try SwitcherRig(paths: paths, hal: hal)
        rig.launcher.fail = true
        rig.switcher.start()
        rig.switcher.beginLaunchTakeover()
        rig.tick(2.5)
        #expect(rig.switcher.status == .pendingFromLastRun(original: Devs.usb.name))
        #expect(try #require(rig.store.read()).guardPID == nil)
        rig.launcher.fail = false
        rig.meetingSwitch.refuse = true
        #expect(rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"]) == .micNotSelectable)
        let pid = try #require(rig.launcher.last?.pid)
        #expect(try #require(rig.store.read()).guardPID == pid)
        #expect(!rig.lockFree)
    }
}

/// Review of f5e22ac and the 完全卸载 wiring (m2-driver notes (a)–(d)), 2026-11-05.
@MainActor @Suite(.serialized, .temporaryFiles) struct SwitcherReview10Tests {
    /// The record's restoreNow is set in memory even when the disk write fails: this process's
    /// "现在还原" still does not wait for the call.
    @Test func restoreNowSurvivesAFailedRecordWrite() throws {
        let rig = try SwitcherRig()
        var logged: [String] = []
        rig.switcher.onLog = { logged.append($0) }
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: [])
        _ = rig.switcher.endMeetingMode(decision: .whenCallEnds)
        rig.hal.set(devices: [Devs.builtIn], defaultUID: Devs.builtIn.uid)   // the original not back yet
        rig.tick(0.1)
        chmod(rig.paths.directory.path, 0o500)
        defer { chmod(rig.paths.directory.path, 0o700) }
        #expect(rig.switcher.restoreNow() == .deferred)
        #expect(logged.count == 1)
        rig.hal.set(devices: [Devs.builtIn, Devs.usb], defaultUID: Devs.builtIn.uid)
        rig.tick(0.5)
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)   // the call is still on
    }

    /// (b): during the call the uninstall step refuses; restoreNow() would have restored.
    @Test func uninstallRefusesDuringTheCall() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"])
        _ = rig.switcher.endMeetingMode(decision: .whenCallEnds)
        #expect(rig.switcher.restoreForUninstall() == .callOngoing)
        #expect(rig.hal.defaultInputUID() == MicPolicy.talkTalkMicUID)
        #expect(rig.store.exists)
        // Quiet, but not for 30 s yet: still the call.
        rig.procs.set(FakeProcesses.zoomIdle)
        rig.tick(5)
        #expect(rig.switcher.restoreForUninstall() == .callOngoing)
        #expect(rig.store.exists)
    }

    /// (d): meeting mode on, the call over: restored, meeting mode stays on (the driver step then
    /// asks you to end it); a second run finds no record of ours.
    @Test func uninstallInMeetingModeAfterTheCall() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"])
        rig.procs.set([])
        #expect(rig.switcher.restoreForUninstall() == .restored(device: Devs.usb.name))
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
        #expect(!rig.store.exists)
        #expect(rig.switcher.isMeetingModeOn)
        #expect(rig.switcher.restoreForUninstall() == .notOwner)
        rig.switcher.endMeetingMode(decision: .whenCallEnds)
        #expect(!rig.switcher.isMeetingModeOn)
    }

    /// (a): meeting mode without switching the default input still counts as on.
    @Test func meetingModeWithoutTheSwitchIsOn() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        #expect(!rig.switcher.isMeetingModeOn)
        _ = rig.switcher.enterMeetingMode(meetingApps: [], switchDefaultInput: false)
        #expect(rig.switcher.isMeetingModeOn)
        #expect(rig.switcher.restoreForUninstall() == .notOwner)
    }
}

/// Review of 608af9d (2026-11-05): the uninstall step's failed restore waits for the real call
/// end; "通话结束后再还原" at quit clears an earlier "现在还原"; a record newer in memory reaches the disk.
@MainActor @Suite(.serialized, .temporaryFiles) struct SwitcherReview11Tests {
    func deferredInCall() throws -> SwitcherRig {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"])
        _ = rig.switcher.endMeetingMode(decision: .whenCallEnds)
        return rig
    }

    /// #1: meeting mode, Zoom gone, 完全卸载's write fails; a new Zoom call before the retry keeps
    /// TalkTalk Mic.
    @Test func uninstallWriteFailureWaitsForTheRealCallEnd() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"])
        rig.procs.set([])
        rig.hal.failWrites = true
        if case .failed = rig.switcher.restoreForUninstall() {} else { Issue.record("not failed") }
        #expect(try #require(rig.store.read()).restoreNow == nil)
        rig.procs.set(FakeProcesses.zoomInCall)
        rig.hal.failWrites = false
        rig.tick(1)
        #expect(rig.hal.defaultInputUID() == MicPolicy.talkTalkMicUID)
        #expect(rig.store.exists)
    }

    /// #2: "现在还原" failed, then quit with "通话结束后再还原": the guard gets no restoreNow.
    @Test func quitWhenCallEndsClearsAnEarlierRestoreNow() throws {
        let rig = try deferredInCall()
        rig.hal.failWrites = true
        #expect(rig.switcher.restoreNow() == .writeFailed)
        #expect(try #require(rig.store.read()).restoreNow == true)
        #expect(rig.switcher.prepareForQuit(decision: .whenCallEnds) == .deferred)
        #expect(try #require(rig.store.read()).restoreNow == nil)
    }

    /// #3: a failed write is retried on the next refresh.
    @Test func dirtyRecordIsRewrittenOnRefresh() throws {
        let rig = try deferredInCall()
        rig.hal.failWrites = true
        chmod(rig.paths.directory.path, 0o500)
        defer { chmod(rig.paths.directory.path, 0o700) }
        #expect(rig.switcher.restoreNow() == .writeFailed)
        #expect(try #require(rig.store.read()).restoreNow == nil)   // the disk missed it
        chmod(rig.paths.directory.path, 0o700)
        rig.tick(0.1)
        #expect(try #require(rig.store.read()).restoreNow == true)
    }

    /// #3: macOS's pick learned while the disk refused it reaches the disk before the guard takes over.
    @Test func dirtyRecordReachesTheDiskBeforeTheHandOff() throws {
        let rig = try deferredInCall()
        chmod(rig.paths.directory.path, 0o500)
        defer { chmod(rig.paths.directory.path, 0o700) }
        rig.hal.set(devices: [Devs.builtIn, Devs.usb], defaultUID: Devs.builtIn.uid)
        rig.tick(0.1)
        #expect(try #require(rig.store.read()).replacementUID == nil)
        chmod(rig.paths.directory.path, 0o700)
        #expect(rig.switcher.prepareForQuit(decision: .whenCallEnds) == .deferred)
        #expect(try #require(rig.store.read()).replacementUID == Devs.builtIn.uid)
    }
}

/// Review of ecb8f8c: 完全卸载 in meeting mode whose write fails keeps meeting mode too.
@MainActor @Suite(.serialized, .temporaryFiles) struct SwitcherReview13Tests {
    @Test func uninstallWriteFailureKeepsMeetingMode() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"])
        rig.procs.set([])                                            // Zoom quit
        rig.hal.failWrites = true
        if case let .failed(why) = rig.switcher.restoreForUninstall() {
            #expect(why == "写默认输入失败，稍后再试")
        } else { Issue.record("not failed") }
        #expect(rig.switcher.status == .holding(original: Devs.usb.name))
        #expect(rig.store.exists)
        rig.hal.failWrites = false
        // A new Zoom call; you plug a headset in and macOS makes it the default: switched back.
        rig.procs.set(FakeProcesses.zoomInCall)
        rig.hal.set(devices: [Devs.builtIn, Devs.usb, Devs.mic, Devs.ear4], defaultUID: Devs.ear4.uid)
        rig.tick(0.4)
        #expect(rig.hal.defaultInputUID() == Devs.mic.uid)
        #expect(rig.store.exists)
    }
}

/// Review of a5b2b6b #2: 完全卸载 in meeting mode with nothing physical to restore to leaves
/// meeting mode as it was: a USB mic plugged in during the next call is still switched back.
@MainActor @Suite(.serialized, .temporaryFiles) struct SwitcherReview12Tests {
    @Test func uninstallWithNoTargetKeepsMeetingMode() throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"])
        rig.hal.set(devices: [Devs.mic], defaultUID: Devs.mic.uid)   // the USB mic and built-in gone
        rig.tick(0.4)
        rig.procs.set([])                                            // Zoom quit
        if case let .failed(why) = rig.switcher.restoreForUninstall() {
            #expect(why == "没有可还原的实体输入设备：接上一个麦克风再试")
        } else { Issue.record("not failed") }
        #expect(rig.switcher.status == .holding(original: Devs.usb.name))
        #expect(rig.store.exists)
        // A new Zoom call; you plug the USB mic in and macOS makes it the default: switched back.
        rig.procs.set(FakeProcesses.zoomInCall)
        rig.hal.set(devices: [Devs.mic, Devs.usb], defaultUID: Devs.usb.uid)
        rig.tick(0.4)
        #expect(rig.hal.defaultInputUID() == Devs.mic.uid)
        #expect(rig.store.exists)
    }
}


@MainActor @Suite(.serialized, .temporaryFiles) struct AutomaticSystemInputEndTests {
    @Test(arguments: [SysInputDialogPlan.Context.endMeeting, .quit, .automatic, .logoutOrShutdown])
    func restoresDuringAnOngoingCall(_ context: SysInputDialogPlan.Context) throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        #expect(rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"]) == .switched)
        #expect(!rig.switcher.callEnded)
        let decision = SysInputDialogPlan.decision(context)
        let result = context == .quit || context == .logoutOrShutdown
            ? rig.switcher.prepareForQuit(decision: decision)
            : rig.switcher.endMeetingMode(decision: decision)
        #expect(result == .restored(device: Devs.usb.name))
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
        #expect(!rig.store.exists)
        #expect(rig.lockFree)
        #expect(rig.launcher.last?.quitCalled == true)
    }

    @Test(arguments: [true, false])
    func unavailableDeviceKeepsImmediateRestoreIntent(hasDefault: Bool) throws {
        let rig = try SwitcherRig()
        rig.switcher.start()
        _ = rig.switcher.enterMeetingMode(meetingApps: ["us.zoom.xos"])
        rig.hal.set(devices: [Devs.mic], defaultUID: hasDefault ? Devs.mic.uid : nil)
        let result = rig.switcher.endMeetingMode(decision: SysInputDialogPlan.decision(.endMeeting))
        #expect(result == (hasDefault ? .noRestoreTarget : .deferred))
        #expect(rig.store.read()?.restoreNow == true)
        #expect(!rig.lockFree)
        #expect(rig.hal.writeCount == 1) // Only the initial switch to TalkTalk Mic.
        rig.hal.set(devices: [Devs.mic, Devs.usb], defaultUID: Devs.mic.uid)
        rig.tick(2)
        #expect(!rig.switcher.callEnded)
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
        #expect(!rig.store.exists)
    }
}
