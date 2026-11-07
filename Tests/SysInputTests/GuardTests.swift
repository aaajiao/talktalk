import Darwin
import Foundation
import Testing
@testable import TalkTalkAudio
import TalkTalkCore
import TalkTalkTestSupport

/// The guard loop in-process: a pipe we control stands in for the app, a fake HAL for Core Audio.
@Suite(.serialized, .temporaryFiles) struct GuardLoopTests {
    struct Rig {
        let paths: SysInputPaths
        let hal: FakeHAL
        let procs: FakeProcesses
        let clock = FakeClock()
        let pipeRead: Int32
        let pipeWrite: Int32
        let guardLoop: SysInputGuard
        let store: SysInputRecordStore

        init(devices: [Dev] = [Devs.builtIn, Devs.usb, Devs.mic], defaultUID: String? = Devs.mic.uid,
             procs: [CallEndRule.Process]? = FakeProcesses.zoomInCall, original: Dev = Devs.usb,
             layer4UID: String? = nil, layer4ArmedUntil: Double? = nil,
             bootSession: String? = SysInputProcess.bootSessionUUID(),
             meetingSwitch: FakeMeetingSwitch? = nil, replacementUID: String? = nil, restoreNow: Bool? = nil) throws {
            paths = try tempPaths()
            hal = FakeHAL(devices: devices, defaultUID: defaultUID)
            self.procs = FakeProcesses(procs)
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else { throw POSIXError(.EIO) }
            pipeRead = fds[0]
            pipeWrite = fds[1]
            store = SysInputRecordStore(paths: paths)
            var record = SysInputRecord(original: .init(original), writerBundleID: "com.aaajiao.talktalk",
                                        executablePath: "/x", meetingApps: ["us.zoom.xos"], layer4UID: layer4UID)
            record.layer4ArmedUntilUptime = layer4ArmedUntil     // the rig's clock starts at 1000
            record.bootSessionUUID = bootSession
            record.replacementUID = replacementUID
            record.restoreNow = restoreNow
            try store.write(record)
            var config = SystemInputPlan.Config.default
            config.pollInterval = 0.02
            let clock = self.clock
            guardLoop = SysInputGuard(environment: .init(hal: hal, processes: self.procs, store: store, config: config,
                                                         meetingSwitch: meetingSwitch, now: { clock.now }, log: { _ in }),
                                      input: pipeRead)
        }

        /// Runs the loop on a thread; returns a box that fills in when it returns.
        func start() -> ResultBox {
            let box = ResultBox()
            let g = guardLoop
            Thread.detachNewThread { box.set(g.run()) }
            return box
        }

        func send(_ s: String) { _ = s.withCString { write(pipeWrite, $0, strlen($0)) } }
        func closeApp() { close(pipeWrite) }
    }

    final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var v: Int32?
        func set(_ x: Int32) { lock.withLock { v = x } }
        var value: Int32? { lock.withLock { v } }
    }

    @Test func quitFromTheAppExitsWithoutRestoring() throws {
        let rig = try Rig(procs: [])
        let r = rig.start()
        rig.send("quit\n")
        #expect(waitUntil(5) { r.value != nil })
        #expect(rig.guardLoop.outcome == .quitByApp)
        #expect(rig.hal.writeCount == 0)
        #expect(rig.store.exists)   // the app deletes the record itself, in its fixed order
    }

    @Test func pipeOpenMeansDoNothing() throws {
        let rig = try Rig(procs: [])   // the call even "ended": while the app lives, the app decides
        let r = rig.start()
        usleep(200_000)
        #expect(r.value == nil)
        #expect(rig.hal.writeCount == 0)
        rig.send("quit\n")
        #expect(waitUntil(5) { r.value != nil })
    }

    @Test func eofWaitsForTheCallThenRestoresDeletesAndExits() throws {
        let rig = try Rig()
        let r = rig.start()
        rig.closeApp()                       // app crashed / kill -9 / SIGTERM
        usleep(200_000)
        #expect(r.value == nil)              // call on: Mic only sends silence, keep waiting
        #expect(rig.hal.writeCount == 0)
        rig.procs.set(FakeProcesses.zoomIdle)
        usleep(100_000)
        rig.clock.advance(29)
        usleep(100_000)
        #expect(r.value == nil)              // 29 s quiet is not 30
        rig.clock.advance(2)
        #expect(waitUntil(5) { r.value != nil })
        #expect(r.value == 0)
        #expect(rig.hal.writes == [Devs.usb.uid])
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
        #expect(!rig.store.exists)
        #expect(rig.guardLoop.outcome == .restored(Devs.usb.uid))
    }

    @Test func eofAndMeetingAppQuitRestoresAtOnce() throws {
        let rig = try Rig()
        let r = rig.start()
        rig.closeApp()
        rig.procs.set([])                    // Zoom exited
        #expect(waitUntil(5) { r.value != nil })
        #expect(rig.hal.writes == [Devs.usb.uid])
        #expect(!rig.store.exists)
    }

    /// Review of 54e9fca #4: the Mic gone with the call on → macOS's pick stays (no restore during
    /// the call); the call ends → the original.
    @Test func eofAndMicVanishWaitsForTheCallThenRestoresOverMacOSPick() throws {
        let rig = try Rig()
        let r = rig.start()
        rig.closeApp()
        usleep(100_000)
        rig.hal.set(devices: [Devs.builtIn, Devs.usb], defaultUID: nil)
        usleep(100_000)
        rig.hal.setDefault(Devs.builtIn.uid)
        usleep(200_000)
        #expect(r.value == nil)
        #expect(rig.hal.writeCount == 0)
        rig.procs.set([])
        #expect(waitUntil(5) { r.value != nil })
        #expect(rig.hal.writes == [Devs.usb.uid])
        #expect(!rig.store.exists)
    }

    /// Review of 54e9fca #4 (coreaudiod restart, d4t): everything vanishes, built-in takes over,
    /// the Mic returns with 'ttmm' reset, the call still on → 'ttmm' = 1 and the Mic again, record
    /// kept; the call ends → the original, 'ttmm' back to 0.
    @Test func eofMicVanishAndReturnWithTheCallOnSwitchesBackToTheMic() throws {
        let sw = FakeMeetingSwitch(.v020, ttmm: true)
        let rig = try Rig(meetingSwitch: sw)
        let r = rig.start()
        rig.closeApp()
        usleep(100_000)
        rig.hal.set(devices: [], defaultUID: nil)
        usleep(100_000)
        rig.hal.set(devices: [Devs.builtIn], defaultUID: Devs.builtIn.uid)
        usleep(100_000)
        #expect(rig.hal.writeCount == 0)
        sw.driverReset()
        rig.hal.set(devices: [Devs.builtIn, Devs.usb, Devs.mic], defaultUID: Devs.builtIn.uid)
        #expect(waitUntil(5) { rig.hal.defaultInputUID() == Devs.mic.uid })
        usleep(100_000)
        #expect(r.value == nil)
        #expect(rig.store.exists)
        #expect(rig.hal.writes == [Devs.mic.uid])
        #expect(sw.writes == [true])
        rig.procs.set([])
        #expect(waitUntil(5) { r.value != nil })
        #expect(rig.guardLoop.outcome == .restored(Devs.usb.uid))
        #expect(rig.hal.writes == [Devs.mic.uid, Devs.usb.uid])
        #expect(!rig.store.exists)
        #expect(sw.writes == [true, false])
    }

    /// Review of 9d9b3a4 #2: a coreaudiod restart no tick saw in between (only ServiceRestarted):
    /// the Mic is listed again, built-in is the default → macOS's pick: the Mic again, and the
    /// pick written back into the record (#4); the call ends → the original.
    @Test func restartBetweenTwoTicksStillSwitchesBack() throws {
        let sw = FakeMeetingSwitch(.v020, ttmm: true)
        let rig = try Rig(meetingSwitch: sw)
        let r = rig.start()
        rig.closeApp()
        usleep(100_000)
        sw.driverReset()
        rig.hal.serviceRestarted(devices: [Devs.builtIn, Devs.usb, Devs.mic], defaultUID: Devs.builtIn.uid)
        #expect(waitUntil(5) { rig.hal.defaultInputUID() == Devs.mic.uid })
        usleep(100_000)
        #expect(r.value == nil)
        #expect(rig.store.exists)
        #expect(rig.hal.writes == [Devs.mic.uid])
        rig.procs.set([])
        #expect(waitUntil(5) { r.value != nil })
        #expect(rig.guardLoop.outcome == .restored(Devs.usb.uid))
    }

    /// #3: a record with macOS's pick (the app ended "通话结束后再还原" during a failed switch back,
    /// then went away): the call on, the Mic listed, built-in the default → the Mic, record kept.
    /// #4: what the guard learns goes back into the record.
    @Test func recordedReplacementMakesTheGuardSwitchBack() throws {
        let sw = FakeMeetingSwitch(.v020, ttmm: false)
        let rig = try Rig(defaultUID: Devs.builtIn.uid, meetingSwitch: sw, replacementUID: Devs.builtIn.uid)
        let r = rig.start()
        rig.closeApp()
        #expect(waitUntil(5) { rig.hal.defaultInputUID() == Devs.mic.uid })
        usleep(100_000)
        #expect(r.value == nil)
        #expect(rig.store.exists)
        #expect(!rig.hal.writes.contains(Devs.usb.uid))
        // The Mic is the default now: the replacement is stale and leaves the record too.
        #expect(waitUntil(5) { rig.store.read()?.replacementUID == nil })
        rig.procs.set([])
        #expect(waitUntil(5) { r.value != nil })
        #expect(rig.hal.defaultInputUID() == Devs.usb.uid)
    }

    /// Review of a7ef015 #5: "现在还原" at quit failed; the guard goes on restoring, the call on,
    /// and never switches back to the Mic despite the sticky replacement.
    @Test func restoreNowRecordIsRestoredNotSwitchedBack() throws {
        let sw = FakeMeetingSwitch(.v020, ttmm: false)
        let rig = try Rig(defaultUID: Devs.builtIn.uid, meetingSwitch: sw, replacementUID: Devs.builtIn.uid,
                          restoreNow: true)
        let r = rig.start()
        rig.closeApp()
        #expect(waitUntil(5) { r.value != nil })
        #expect(rig.hal.writes == [Devs.usb.uid])
        #expect(rig.guardLoop.outcome == .restored(Devs.usb.uid))
        #expect(!rig.store.exists)
    }

    @Test func guardWritesMacOSPickBackIntoTheRecord() throws {
        let rig = try Rig()
        let r = rig.start()
        rig.closeApp()
        usleep(100_000)
        rig.hal.set(devices: [Devs.builtIn, Devs.usb], defaultUID: Devs.builtIn.uid)   // the Mic gone, call on
        #expect(waitUntil(5) { rig.store.read()?.replacementUID == Devs.builtIn.uid })
        #expect(r.value == nil)
        #expect(rig.hal.writeCount == 0)
        rig.procs.set([])
        #expect(waitUntil(5) { r.value != nil })
    }

    @Test func eofAndManualChangeOnlyDeletesTheRecord() throws {
        let rig = try Rig(devices: [Devs.builtIn, Devs.usb, Devs.mic])
        let r = rig.start()
        rig.closeApp()
        usleep(100_000)
        rig.hal.setDefault(Devs.builtIn.uid)        // you picked built-in while Mic is still there
        #expect(waitUntil(5) { r.value != nil })
        #expect(rig.hal.writeCount == 0)
        #expect(!rig.store.exists)
        #expect(rig.guardLoop.outcome == .droppedRecord(.changedTo(Devs.builtIn)))
    }

    @Test func recordDeletedElsewhereMeansExit() throws {
        let rig = try Rig()
        let r = rig.start()
        rig.store.delete()
        rig.closeApp()
        #expect(waitUntil(5) { r.value != nil })
        #expect(rig.guardLoop.outcome == .recordGone)
        #expect(rig.hal.writeCount == 0)
    }

    /// Review #5: the first process read fails; the session's meeting apps still scope "通话结束"
    /// (Chrome playing a video must not keep Zoom's call alive).
    @Test func scopeHoldsWhenTheFirstProcessReadFails() throws {
        let rig = try Rig(procs: nil)
        let r = rig.start()
        rig.closeApp()
        usleep(150_000)                         // at least one tick with no process list
        rig.procs.set(FakeProcesses.zoomIdle + [CallEndRule.Process(appID: "com.google.Chrome", pid: 777,
                                                                    isRunningInput: true, isRunningOutput: true)])
        usleep(150_000)
        rig.clock.advance(31)
        #expect(waitUntil(5) { r.value != nil })
        #expect(rig.hal.writes == [Devs.usb.uid])
        #expect(!rig.store.exists)
    }

    /// Review 2 A: a layer-4 record handed to the guard keeps the layer-4 rule (Tuwa → USB after the call).
    @Test func layer4RecordKeepsTheVirtualRuleInTheGuard() throws {
        let rig = try Rig(devices: [Devs.builtIn, Devs.usb, Devs.tuwa, Devs.mic], defaultUID: Devs.tuwa.uid,
                          layer4UID: Devs.tuwa.uid)
        let r = rig.start()
        rig.closeApp()
        usleep(200_000)
        #expect(r.value == nil)                 // call on: wait, keep the record
        #expect(rig.store.exists)
        rig.procs.set([])
        #expect(waitUntil(5) { r.value != nil })
        #expect(rig.hal.writes == [Devs.usb.uid])
        #expect(!rig.store.exists)
    }

    /// Review 3 (a): handed over while still armed (no default yet); Tuwa appears; restored after the call.
    @Test func armedLayer4RecordLearnsTheDeviceInTheGuard() throws {
        let rig = try Rig(devices: [Devs.builtIn, Devs.usb, Devs.tuwa, Devs.mic], defaultUID: nil,
                          layer4ArmedUntil: 1001)
        let r = rig.start()
        rig.closeApp()
        usleep(100_000)
        rig.hal.setDefault(Devs.tuwa.uid)
        usleep(200_000)
        #expect(r.value == nil)
        #expect(rig.store.exists)
        rig.procs.set([])
        #expect(waitUntil(5) { r.value != nil })
        #expect(rig.hal.writes == [Devs.usb.uid])
        #expect(!rig.store.exists)
    }

    /// Review 4 (a1): the record's window has passed when the guard sees the first default: yours.
    @Test func expiredLayer4WindowInTheGuardDropsTheRecord() throws {
        let rig = try Rig(devices: [Devs.builtIn, Devs.usb, Devs.krisp, Devs.mic], defaultUID: nil, procs: [],
                          layer4ArmedUntil: 999.5)
        let r = rig.start()
        rig.closeApp()
        usleep(100_000)
        rig.clock.advance(0.1)
        rig.hal.setDefault(Devs.krisp.uid)
        #expect(waitUntil(5) { r.value != nil })
        #expect(rig.hal.writeCount == 0)
        #expect(rig.guardLoop.outcome == .droppedRecord(.changedTo(Devs.krisp)))
    }

    /// Review 5 #1: a deadline far in the future (a bad clock) is capped at one window.
    @Test func farFutureLayer4DeadlineIsCappedInTheGuard() throws {
        let rig = try Rig(devices: [Devs.builtIn, Devs.usb, Devs.krisp, Devs.mic], defaultUID: nil, procs: [],
                          layer4ArmedUntil: 1000 + 1e6)
        let r = rig.start()
        rig.closeApp()
        usleep(100_000)                         // first tick: the monitor is built at clock 1000
        rig.clock.advance(1.5)
        rig.hal.setDefault(Devs.krisp.uid)       // 1.5 s later: yours
        #expect(waitUntil(5) { r.value != nil })
        #expect(rig.hal.writeCount == 0)
        #expect(rig.guardLoop.outcome == .droppedRecord(.changedTo(Devs.krisp)))
    }

    /// Review 5 #1: a deadline from another boot is not armed at all.
    @Test func layer4DeadlineFromAnotherBootIsIgnored() throws {
        let rig = try Rig(devices: [Devs.builtIn, Devs.usb, Devs.tuwa, Devs.mic], defaultUID: nil, procs: [],
                          layer4ArmedUntil: 1001, bootSession: "00000000-0000-0000-0000-000000000000")
        let r = rig.start()
        rig.closeApp()
        usleep(100_000)
        rig.hal.setDefault(Devs.tuwa.uid)
        #expect(waitUntil(5) { r.value != nil })
        #expect(rig.hal.writeCount == 0)
        #expect(rig.guardLoop.outcome == .droppedRecord(.changedTo(Devs.tuwa)))
    }

    /// Review 4 (c): after restoring, the guard sets 'ttmm' back to 0 (best effort).
    @Test func guardReleasesTheMeetingModeSwitchAfterRestoring() throws {
        let sw = FakeMeetingSwitch(.v020, ttmm: true)
        let rig = try Rig(procs: [], meetingSwitch: sw)
        let r = rig.start()
        rig.closeApp()
        #expect(waitUntil(5) { r.value != nil })
        #expect(rig.hal.writes == [Devs.usb.uid])
        #expect(sw.writes == [false])
        #expect(!sw.value)
    }

    @Test func unreadableProcessListNeverEndsTheCall() throws {
        let rig = try Rig(procs: nil)
        let r = rig.start()
        rig.closeApp()
        rig.clock.advance(100)
        usleep(200_000)
        #expect(r.value == nil)
        #expect(rig.hal.writeCount == 0)
        rig.procs.set([])
        #expect(waitUntil(5) { r.value != nil })
    }
}

/// The real executable (`TalkTalk --sysinput-guard`), spawned the way the app spawns it. The
/// fake-HAL tests need the dev build (check.sh builds with -DTALKTALK_DEV); none of these
/// touches the real default input.
@Suite(.serialized, .temporaryFiles) struct GuardProcessTests {
    static var hasBinary: Bool { Product.talkTalk != nil }
    static var hasDevBinary: Bool { Product.talkTalk != nil && Product.isDevBuild }

    @Test(.enabled(if: hasBinary)) func withoutAnInheritedLockItExitsNonZero() throws {
        let exe = try #require(Product.talkTalk)
        let p = try #require(Spawned.run(exe, ["--sysinput-guard"]))
        let st = p.wait(timeout: 20)
        #expect(st?.code == 3)
        let err = p.readAll(p.stderr)
        #expect(err.contains("nsapp=0"))
    }

    @Test(.enabled(if: hasBinary)) func aDescriptorThatIsNotTheLockIsRefused() throws {
        let exe = try #require(Product.talkTalk)
        let paths = try tempPaths()
        let null = open("/dev/null", O_RDONLY)
        defer { close(null) }
        let p = try #require(Spawned.run(exe, ["--sysinput-guard", "--lock-fd", String(null),
                                                "--sysinput-dir", paths.directory.path], inherit: [null]))
        #expect(p.wait(timeout: 20)?.code == 3)
        // Someone else's lock on the right file: also refused.
        let holder = SysInputLock(path: paths.lock.path)
        #expect(holder.tryAcquire())
        defer { holder.release() }
        let other = open(paths.lock.path, O_RDWR)
        defer { close(other) }
        let q = try #require(Spawned.run(exe, ["--sysinput-guard", "--lock-fd", String(other),
                                                "--sysinput-dir", paths.directory.path], inherit: [other]))
        #expect(q.wait(timeout: 20)?.code == 3)
    }

    /// A rig with the real launcher: lock held, record written, fake HAL file.
    struct ProcRig {
        let paths: SysInputPaths
        let lock: SysInputLock
        let file: SysInputFileHAL
        let store: SysInputRecordStore
        let launcher: PosixSpawnGuardLauncher
        let exited = ExitBox()

        init(exe: String) throws {
            paths = try tempPaths()
            lock = SysInputLock(path: paths.lock.path)
            guard lock.tryAcquire() else { throw POSIXError(.EAGAIN) }
            file = SysInputFileHAL(path: paths.directory.appendingPathComponent("hal.json").path)
            file.save(.init(devices: [Devs.builtIn, Devs.usb, Devs.mic], defaultUID: Devs.mic.uid,
                            processes: FakeProcesses.zoomInCall))
            store = SysInputRecordStore(paths: paths)
            try store.write(SysInputRecord(original: .init(Devs.usb), writerBundleID: "com.aaajiao.talktalk.dev",
                                           executablePath: exe, meetingApps: ["us.zoom.xos"]))
            launcher = PosixSpawnGuardLauncher(executable: exe, extraArguments: [
                "--sysinput-fake-hal", file.path, "--sysinput-poll", "0.05"])
        }

        func launch() throws -> SysInputGuardHandle {
            let box = exited
            return try launcher.launch(lockFD: lock.fd, paths: paths) { box.set($0) }
        }
    }

    final class ExitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var v: Int32?
        func set(_ x: Int32) { lock.withLock { v = x } }
        var status: Int32? { lock.withLock { v } }
    }

    @Test(.enabled(if: hasDevBinary)) func appKilledGuardKeepsLockWaitsRestoresAndExits() throws {
        let exe = try #require(Product.talkTalk)
        let rig = try ProcRig(exe: exe)
        let g = try rig.launch()
        #expect(g.pid > 0)
        // What the kernel does to a `kill -9`'d app: every descriptor closed, nothing else.
        g.handOff()
        rig.lock.detach()
        usleep(500_000)
        #expect(rig.exited.status == nil)                                // still running
        #expect(!SysInputLock.isAvailable(path: rig.paths.lock.path))    // and holding the lock
        #expect(rig.file.load()?.writes == [])                           // call on: no restore
        #expect(rig.store.exists)
        // Zoom quits → the call is over.
        var s = try #require(rig.file.load())
        s.processes = []
        rig.file.save(s)
        #expect(waitUntil(10) { rig.exited.status != nil })
        #expect(rig.exited.status == 0)
        #expect(rig.file.load()?.writes == [Devs.usb.uid])
        #expect(rig.file.load()?.defaultUID == Devs.usb.uid)
        #expect(!rig.store.exists)
        #expect(waitUntil(5) { SysInputLock.isAvailable(path: rig.paths.lock.path) })
    }

    @Test(.enabled(if: hasDevBinary)) func sigtermToTheGuardExitsWithoutRestoring() throws {
        let exe = try #require(Product.talkTalk)
        let rig = try ProcRig(exe: exe)
        var s = try #require(rig.file.load())
        s.processes = []   // the call has even ended: SIGTERM must still not restore
        rig.file.save(s)
        let g = try rig.launch()
        usleep(300_000)
        _ = kill(g.pid, SIGTERM)
        #expect(waitUntil(10) { rig.exited.status != nil })
        #expect((rig.exited.status ?? 0) & 0x7f == SIGTERM)
        #expect(rig.file.load()?.writes == [])
        #expect(rig.store.exists)
        rig.lock.release()
    }

    @Test(.enabled(if: hasDevBinary)) func quitExitsWithoutRestoring() throws {
        let exe = try #require(Product.talkTalk)
        let rig = try ProcRig(exe: exe)
        let g = try rig.launch()
        usleep(300_000)
        g.quit()
        #expect(waitUntil(10) { rig.exited.status != nil })
        #expect(rig.exited.status == 0)
        #expect(rig.file.load()?.writes == [])
        rig.lock.release()
    }

    /// Review #4: the app was started with `| tee` and the reader died: stderr is a closed pipe.
    /// The guard's log lines get EPIPE and are dropped; it still restores and exits 0.
    @Test(.enabled(if: hasDevBinary)) func closedStderrDoesNotStopTheRestore() throws {
        let exe = try #require(Product.talkTalk)
        let rig = try ProcRig(exe: exe)
        var s = try #require(rig.file.load())
        s.processes = []
        rig.file.save(s)
        var input: [Int32] = [-1, -1]
        #expect(pipe(&input) == 0)
        _ = fcntl(input[1], F_SETFD, FD_CLOEXEC)
        let p = try #require(Spawned.run(exe, ["--sysinput-guard", "--lock-fd", String(rig.lock.fd),
                                                "--sysinput-dir", rig.paths.directory.path,
                                                "--sysinput-fake-hal", rig.file.path, "--sysinput-poll", "0.05"],
                                         inherit: [rig.lock.fd], stdin: input[0]))
        close(input[0])
        close(p.stderr)                        // nobody reads stderr any more
        rig.lock.detach()
        close(input[1])                        // the app is gone: EOF
        let st = p.wait(timeout: 20)
        #expect(st?.signal == nil)
        #expect(st?.code == 0)
        #expect(rig.file.load()?.writes == [Devs.usb.uid])
        #expect(!rig.store.exists)
    }

    /// Review #6: a guard that exits by itself (never told quit/handOff) must not leak our pipe end.
    /// The handle reports its own close (fd, close's result), so nothing here depends on fd numbers
    /// or pipe inodes another test may reuse (reviews 2 G and 3 (b)).
    @Test(.enabled(if: hasDevBinary)) func pipeEndClosedWhenAGuardThatExitedIsReleased() throws {
        final class Closes: @unchecked Sendable {
            private let lock = NSLock()
            private var v: [(Int32, Int32)] = []
            func add(_ fd: Int32, _ rc: Int32) { lock.withLock { v.append((fd, rc)) } }
            var all: [(Int32, Int32)] { lock.withLock { v } }
        }
        let exe = try #require(Product.talkTalk)
        let rig = try ProcRig(exe: exe)
        let closes = Closes()
        var g: SysInputGuardHandle? = try rig.launch()
        weak var released = g
        // Read the fd and pid and set the hook without keeping a second strong reference.
        let (fd, pid): (Int32, Int32) = try {
            let s = try #require(g as? SpawnedGuard)
            s.onPipeClosed = { closes.add($0, $1) }
            return (s.writeFD, s.pid)
        }()
        #expect(fd >= 0)
        usleep(200_000)
        _ = kill(pid, SIGTERM)                  // exits by itself, from the handle's point of view
        #expect(waitUntil(10) { rig.exited.status != nil })
        #expect(closes.all.isEmpty)             // nobody closed it yet
        g = nil
        #expect(released == nil)
        let c = closes.all
        #expect(c.count == 1)
        #expect(c.first?.0 == fd)
        #expect(c.first?.1 == 0)                // close succeeded: the descriptor was still ours
        rig.lock.release()
    }

    @Test(.enabled(if: hasDevBinary)) func guardIsInItsOwnProcessGroup() throws {
        let exe = try #require(Product.talkTalk)
        let rig = try ProcRig(exe: exe)
        let g = try rig.launch()
        usleep(200_000)
        #expect(getpgid(g.pid) == g.pid)
        #expect(getpgid(g.pid) != getpgrp())
        g.quit()
        #expect(waitUntil(10) { rig.exited.status != nil })
        rig.lock.release()
    }
}
