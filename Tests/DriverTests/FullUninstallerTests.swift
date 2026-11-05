import Foundation
import Synchronization
import Testing
@testable import TalkTalkAudio
import TalkTalkCore
@testable import TalkTalkDriverSupport

/// §8.4 完全卸载: order, what is deleted, and when it refuses. Every side effect is a fake except
/// the file deletions, which run in a temp directory.
@MainActor
@Suite(.serialized)
struct FullUninstallerTests {
    final class Trail: Sendable {
        let items = Mutex<[String]>([])
        func add(_ s: String) { items.withLock { $0.append(s) } }
        var all: [String] { items.withLock { $0 } }
    }

    func layout(_ t: TempDir) throws -> (home: URL, logs: URL, caches: URL) {
        let fm = FileManager.default
        let home = t.sub("AppSupport/TalkTalk"), logs = t.sub("Logs/TalkTalk"), caches = t.sub("Caches/TalkTalk")
        for d in [home.appendingPathComponent("voice"), home.appendingPathComponent("transcripts"),
                  home.appendingPathComponent("diagnostics"), home.appendingPathComponent(".voice-staging-1234"),
                  home.appendingPathComponent("engine"), logs, caches.appendingPathComponent("hf")] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        for f in ["glossary.json", "sysinput-restore.json", "sysinput-restore.lock", "driver.json"] {
            try Data("{}".utf8).write(to: home.appendingPathComponent(f))
        }
        try Data("x".utf8).write(to: logs.appendingPathComponent("app.log"))
        // something not ours inside Application Support/TalkTalk stays
        try Data("keep".utf8).write(to: home.appendingPathComponent("not-ours.txt"))
        return (home, logs, caches)
    }

    func deps(_ t: Trail, _ l: (home: URL, logs: URL, caches: URL),
              restore: FullUninstaller.RestoreOutcome = .noRecord,
              driver: DriverInstaller.Phase? = .finished(.uninstalled)) -> FullUninstaller.Dependencies {
        var uninstallDriver: (@MainActor @Sendable () async -> DriverInstaller.Phase?)?
        if let driver { uninstallDriver = { t.add("driver"); return driver } }
        return FullUninstaller.Dependencies(
            restoreDefaultInput: { t.add("restore"); return restore },
            uninstallDriver: uninstallDriver,
            uninstallEngine: { t.add("engine"); return nil },
            deleteKeychainItem: { t.add("keychain"); return nil },
            removePreferences: { t.add("prefs") },
            unregisterLoginItem: { t.add("login"); return nil },
            resetPrivacy: { t.add("tcc"); return nil },
            home: l.home, logs: l.logs, caches: l.caches)
    }

    @Test func runsEveryStepInOrderAndDeletesOnlyTheListedFiles() async throws {
        let tmp = try TempDir()
        let l = try layout(tmp)
        let trail = Trail()
        let u = FullUninstaller(deps(trail, l, restore: .restored("MacBook Pro Microphone")))
        u.beforeBegin = { trail.add("stop-engine") }
        let p = await u.run()
        guard case .finished(let report) = p else { Issue.record("\(p)"); return }
        #expect(trail.all == ["restore", "driver", "stop-engine", "engine", "keychain", "prefs", "login", "tcc"])
        // what is left in Application Support/TalkTalk is named, not passed over (review of 639f957 #1)
        #expect(report.problems == [
            "\(l.home.appendingPathComponent("engine").path) 没有删除（不在完全卸载要删的清单里；确定不要的话，在访达里删除）",
            "\(l.home.appendingPathComponent("not-ours.txt").path) 没有删除（不在完全卸载要删的清单里；确定不要的话，在访达里删除）",
        ])
        #expect(report.removed.first == "默认输入已还原到 MacBook Pro Microphone")
        for gone in ["voice", "transcripts", "diagnostics", ".voice-staging-1234", "glossary.json", "sysinput-restore.json",
                     "sysinput-restore.lock", "driver.json"] {
            #expect(!l.home.appendingPathComponent(gone).exists, "\(gone) still there")
        }
        #expect(!l.logs.exists && !l.caches.exists)
        // the engine directory is install-engine.sh's to remove (faked here), and a foreign file stays
        #expect(l.home.appendingPathComponent("not-ours.txt").exists)
        #expect(l.home.appendingPathComponent("engine").exists)
    }

    @Test func callOngoingOrOtherOwnerRefusesBeforeAnythingIsTouched() async throws {
        for outcome in [FullUninstaller.RestoreOutcome.callOngoing, .ownedByAnotherTalkTalk] {
            let tmp = try TempDir()
            let l = try layout(tmp)
            let trail = Trail()
            let p = await FullUninstaller(deps(trail, l, restore: outcome)).run()
            guard case .blocked = p else { Issue.record("\(outcome): \(p)"); continue }
            #expect(trail.all == ["restore"])
            #expect(l.home.appendingPathComponent("voice").exists)
        }
    }

    @Test func cancelledDriverAuthorizationStopsTheRun() async throws {
        let tmp = try TempDir()
        let l = try layout(tmp)
        let trail = Trail()
        let p = await FullUninstaller(deps(trail, l, driver: .cancelled)).run()
        #expect(p == .cancelled)
        #expect(trail.all == ["restore", "driver"])
        #expect(l.home.appendingPathComponent("glossary.json").exists)
    }

    @Test func noDriverOnDiskSkipsTheAuthorization() async throws {
        let tmp = try TempDir()
        let l = try layout(tmp)
        let trail = Trail()
        let p = await FullUninstaller(deps(trail, l, driver: nil)).run()
        guard case .finished = p else { Issue.record("\(p)"); return }
        #expect(!trail.all.contains("driver"))
    }

    @Test func driverGoneWhenTheStepRunsIsSkippedQuietly() async throws {
        let tmp = try TempDir()
        let l = try layout(tmp)
        let trail = Trail()
        var d = deps(trail, l)
        d.uninstallDriver = { trail.add("driver?"); return nil }
        let p = await FullUninstaller(d).run()
        guard case .finished(let report) = p else { Issue.record("\(p)"); return }
        #expect(trail.all == ["restore", "driver?", "engine", "keychain", "prefs", "login", "tcc"])
        #expect(!report.removed.contains { $0.hasPrefix("虚拟麦克风") })
    }

    /// What the driver script left behind is reported, whether the script ran or the step was
    /// skipped (review m0-driver 3c2cffc #1).
    @Test func driverLeftoversAreReported() async throws {
        let left = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/.TalkTalkAudio.driver.tmp-77")
        for driver in [DriverInstaller.Phase?.some(.finished(.uninstalled)), nil] {
            let tmp = try TempDir()
            let l = try layout(tmp)
            var d = deps(Trail(), l)
            d.uninstallDriver = { driver }   // nil: nothing of ours on disk, the step is skipped
            d.driverLeftovers = { [left] }
            let p = await FullUninstaller(d).run()
            guard case .finished(let report) = p else { Issue.record("\(p)"); continue }
            #expect(report.problems.contains { $0.hasPrefix("虚拟麦克风：") && $0.contains(left.path) }, "\(report.problems)")
            #expect(report.removed.contains("虚拟麦克风") == (driver != nil))
        }
        // nothing left: no problem line
        let tmp = try TempDir()
        guard case .finished(let clean) = await FullUninstaller(deps(Trail(), try layout(tmp))).run() else {
            Issue.record("not finished"); return
        }
        #expect(!clean.problems.contains { $0.hasPrefix("虚拟麦克风") })
    }

    @Test func emptyApplicationSupportDirectoryIsRemovedToo() async throws {
        let tmp = try TempDir()
        let l = try layout(tmp)
        try FileManager.default.removeItem(at: l.home.appendingPathComponent("not-ours.txt"))
        try FileManager.default.removeItem(at: l.home.appendingPathComponent("engine"))
        // SingleInstance's lock goes too (this app's, held, and another flavor's)
        try Data().write(to: l.home.appendingPathComponent(".instance-dev.lock"))
        try Data().write(to: l.home.appendingPathComponent(".instance-release.lock"))
        let held = SysInputLock(path: l.home.appendingPathComponent(".instance-dev.lock").path)
        #expect(held.tryAcquire())
        defer { held.release() }
        let p = await FullUninstaller(deps(Trail(), l)).run()
        guard case .finished(let r) = p else { Issue.record("\(p)"); return }
        #expect(r.problems.isEmpty, "\(r.problems)")
        #expect(!l.home.exists)
    }

    /// The engine installer is running (the engine rows' install, check, a model): nothing is
    /// done, not even step 1 (review of 639f957 #2).
    @Test func engineInstallerRunningRefusesBeforeAnything() async throws {
        let tmp = try TempDir()
        let l = try layout(tmp)
        let trail = Trail()
        var d = deps(trail, l, restore: .restored("X"))
        d.engineBusy = { true }
        let u = FullUninstaller(d)
        #expect(u.isEngineBusy)
        #expect(await u.run() == .blocked(FullUninstaller.engineBusyText))
        #expect(trail.all.isEmpty)
        #expect(u.lastReport == .init())
        #expect(l.home.appendingPathComponent("voice").exists && l.logs.exists && l.caches.exists)
    }

    /// install-engine.sh exits 0 when it keeps something: each thing left is named, the engine is
    /// not reported removed, and the engine directory is not named twice.
    @Test func engineLeftoversAreListed() async throws {
        let tmp = try TempDir()
        let l = try layout(tmp)
        let engine = l.home.appendingPathComponent("engine")
        let model = engine.appendingPathComponent("models/Qwen--Qwen3-TTS@0123456789ab")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data().write(to: model.appendingPathComponent(".DS_Store"))
        try FileManager.default.createDirectory(at: engine.appendingPathComponent(".python.tmp-4242"),
                                                withIntermediateDirectories: true)
        let left = FullUninstaller.engineLeftovers(engineHome: engine)
        #expect(left.map(\.lastPathComponent) == [".python.tmp-4242", "Qwen--Qwen3-TTS@0123456789ab"])
        var d = deps(Trail(), l)
        d.engineLeftovers = { left }
        let p = await FullUninstaller(d).run()
        guard case .finished(let r) = p else { Issue.record("\(p)"); return }
        #expect(!r.removed.contains("引擎和模型"))
        #expect(r.problems.filter { $0.hasPrefix("引擎：") }.count == 2)
        #expect(r.problems.contains { $0.hasPrefix("引擎：\(model.path) 没有删除") })
        #expect(!r.problems.contains { $0.hasPrefix("\(engine.path) 没有删除") }, "\(r.problems)")
        #expect(FullUninstaller.engineLeftovers(engineHome: l.home.appendingPathComponent("absent")).isEmpty)
    }
}

/// `SysInputRestore.restoreStale`: a record nobody owns (§8.6 "记录归谁").
@Suite(.serialized)
struct StaleRestoreTests {
    final class HAL: SysInputHAL, @unchecked Sendable {
        let lock = NSLock()
        var devices: [MicPolicy.Device]
        var defaultUID: String?
        init(_ d: [MicPolicy.Device], _ def: String?) { devices = d; defaultUID = def }
        func snapshot() -> SystemInputPlan.Snapshot {
            lock.withLock { .init(devices: devices, defaultInput: devices.first { $0.uid == defaultUID }) }
        }
        func setDefaultInput(uid: String) -> Bool { lock.withLock { defaultUID = uid }; return true }
        func defaultInputUID() -> String? { lock.withLock { defaultUID } }
        func startWatching(_ onChange: @escaping @Sendable () -> Void) {}
        func stopWatching() {}
    }

    let builtIn = MicPolicy.Device(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: "bltn")
    let mic = MicPolicy.Device(uid: MicPolicy.talkTalkMicUID, name: "TalkTalk Mic", transport: "virt")

    func record(_ paths: SysInputPaths) throws {
        try SysInputRecordStore(paths: paths).write(SysInputRecord(original: .init(builtIn), writerBundleID: "com.aaajiao.talktalk.dev",
                                                                   executablePath: "/nonexistent"))
    }

    @Test func restoresWhenTheCallHasEnded() throws {
        let t = try TempDir()
        let paths = SysInputPaths(directory: t.url)
        try record(paths)
        let hal = HAL([builtIn, mic], mic.uid)
        #expect(SysInputRestore.restoreStale(paths: paths, hal: hal, processes: { [] }) == .restored("MacBook Pro Microphone"))
        #expect(hal.defaultInputUID() == builtIn.uid)
        #expect(!SysInputRecordStore(paths: paths).exists)
    }

    @Test func refusesDuringACallAndWhenLocked() throws {
        let t = try TempDir()
        let paths = SysInputPaths(directory: t.url)
        try record(paths)
        let hal = HAL([builtIn, mic], mic.uid)
        let zoom = MeetingCandidate(app: MeetingApp.named("us.zoom.xos")!,
                                    processes: [AudioProcessInfo(objectID: 1, pid: 5, bundleID: "us.zoom.xos",
                                                                 isRunningInput: true, isRunningOutput: false)])
        #expect(SysInputRestore.restoreStale(paths: paths, hal: hal, processes: { [zoom] }) == .callOngoing)
        #expect(hal.defaultInputUID() == mic.uid)
        let owner = SysInputLock(path: paths.lock.path)
        #expect(owner.tryAcquire())
        #expect(SysInputRestore.restoreStale(paths: paths, hal: hal, processes: { [] }) == .ownedByAnotherTalkTalk)
        owner.release()
    }

    @Test func userChangedInputOnlyDropsTheRecord() throws {
        let t = try TempDir()
        let paths = SysInputPaths(directory: t.url)
        try record(paths)
        let usb = MicPolicy.Device(uid: "usb:mv7", name: "Shure MV7", transport: "usb ")
        let hal = HAL([builtIn, mic, usb], usb.uid)
        #expect(SysInputRestore.restoreStale(paths: paths, hal: hal, processes: { [] }) == .recordDropped)
        #expect(hal.defaultInputUID() == usb.uid)
        #expect(!SysInputRecordStore(paths: paths).exists)
        #expect(SysInputRestore.restoreStale(paths: paths, hal: hal, processes: { [] }) == .noRecord)
    }
}
