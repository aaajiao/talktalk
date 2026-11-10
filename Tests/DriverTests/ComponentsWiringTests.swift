import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TalkTalkAudio
@testable import TalkTalkDriverSupport
import TalkTalkEngineHost
import TalkTalkSettingsUI

/// Settings › 组件 as the app wires it (TalkTalkApp's DriverComponentsPage → `forCurrentApp`):
///  - the switcher's meeting mode feeds the driver preflight;
///  - its restore feeds 完全卸载 step 1 through `FullUninstaller.Dependencies.live`;
///  - the result row shows `FullUninstallSummary`.
/// The driver step runs the real install-driver.sh against a temp HAL directory, as in
/// DriverInstallerTests. Keychain, defaults, login item and TCC are faked, the stale-record path
/// reads a temp directory, and nothing needs root, restarts coreaudiod or touches the real
/// default input.
@MainActor
@Suite(.serialized)
struct ComponentsWiringTests {
    final class Trail: @unchecked Sendable {
        private(set) var items: [String] = []
        func add(_ s: String) { items.append(s) }
    }

    /// Looks at the model from inside the engine step.
    final class Probe: @unchecked Sendable {
        var model: DriverComponentModel?
        var busyDuringEngineStep: Bool?
        /// What DriverComponentsPage hands to EngineComponentsModel.blockedBy, seen mid-run.
        var engineRowsBlockedDuringEngineStep: Bool?
    }

    let t: TempDir
    let resources: DriverResources
    let hal = FakeDriverHAL()
    let trail = Trail()

    init() throws {
        t = try TempDir("tt-components")
        let res = t.sub("Resources/driver")
        try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
        try FakeDriver.make(in: res, version: "9.9.9", sign: true)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..")
        try FileManager.default.copyItem(at: repo.appendingPathComponent("scripts/driver/install-driver.sh").standardizedFileURL,
                                         to: res.appendingPathComponent("install-driver.sh"))
        try FileManager.default.copyItem(at: repo.appendingPathComponent("scripts/lib/versions.sh").standardizedFileURL,
                                         to: res.appendingPathComponent("versions.sh"))
        try FileManager.default.createDirectory(at: t.sub("HAL"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: t.sub("home/voice"), withIntermediateDirectories: true)
        resources = DriverResources(directory: res)
    }

    var target: URL { t.sub("HAL/\(DriverIdentity.bundleName)") }
    var sysinput: SysInputPaths { SysInputPaths(directory: t.sub("sysinput")) }

    func realScript() -> DirectScriptRunner {
        DirectScriptRunner(environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TT_HAL_DIR": t.sub("HAL").path,
                                         "TT_INSTALL_ALLOW_NONROOT": "1"],
                           extraArguments: ["--no-restart"])
    }

    /// What `DriverComponentModel.forCurrentApp` builds, on this fixture: the meeting-mode closure
    /// goes into the preflight inputs and the model, `restore` stands for
    /// `SysInputRestore.withSwitcher(switcher)` (nil = not this app's record).
    func model(meetingModeOn: Bool = false, restore: FullUninstaller.RestoreOutcome?,
               runner: (any DriverScriptRunner)? = nil,
               keychain: String? = nil, probe: Probe? = nil, engine: EngineInstaller? = nil) -> DriverComponentModel {
        let isMeetingModeOn: @MainActor () -> Bool = { meetingModeOn }
        let i = DriverInstaller(resources: resources,
                                paths: DriverPaths(home: t.sub("home"), logs: t.sub("logs"), caches: t.sub("caches")),
                                hal: hal, runner: runner ?? realScript(), pollInterval: .milliseconds(5),
                                pollAttempts: 30, installedBundle: target,
                                preflightInputs: { DriverPreflight.Inputs(meetingModeOn: isMeetingModeOn(), ownPID: 1) })
        let paths = EnginePaths(home: t.sub("home"), logs: t.sub("logs"), caches: t.sub("caches"), engineSource: nil,
                                installerScript: nil)
        let switcherRestore: @MainActor @Sendable () -> FullUninstaller.RestoreOutcome? = { restore }
        var d = FullUninstaller.Dependencies.live(bundleID: "com.example.tt-test", driver: i, engine: engine,
                                                  restoreWithSwitcher: switcherRestore, sysInputPaths: sysinput,
                                                  enginePaths: paths)
        let trail = self.trail
        d.deleteKeychainItem = { trail.add("keychain"); return keychain }
        d.removePreferences = { trail.add("prefs") }
        d.unregisterLoginItem = { trail.add("login"); return nil }
        d.resetPrivacy = { trail.add("tcc"); return nil }
        if let probe {
            d.uninstallEngine = {
                probe.busyDuringEngineStep = probe.model?.isBusy
                probe.engineRowsBlockedDuringEngineStep = probe.model?.fullUninstallRunning
                return nil
            }
        }
        let m = DriverComponentModel(installer: i, fullUninstaller: FullUninstaller(d), isMeetingModeOn: isMeetingModeOn,
                                     selfTestOptions: { .init() })
        probe?.model = m
        return m
    }

    func fullUninstall(_ m: DriverComponentModel) async throws -> (FullUninstaller.Phase, FullUninstallSummary) {
        m.requestFullUninstall()
        #expect(m.confirmingFullUninstall)
        await m.confirm(.fullUninstall)
        let full = try #require(m.fullUninstaller)
        #expect(m.notice == nil, "the result is the row's, not a notice")
        return (full.phase, try #require(m.fullUninstallSummary))
    }

    /// Wiring (d): meeting mode on, the call over. Step 1 restores the default input. The driver step
    /// then stops at "先结束会议模式", and the result still says the input was restored.
    @Test func meetingModeOnRestoresThenStopsAtTheDriverAndSaysSo() async throws {
        try FakeDriver.make(in: t.sub("HAL"), version: "9.9.9", sign: true)
        let counting = CountingRunner()
        let m = model(meetingModeOn: true, restore: .restored("MacBook Pro 麦克风"), runner: counting)
        let (phase, summary) = try await fullUninstall(m)
        #expect(phase == .blocked(DriverPreflight.Blocker.meetingModeOn.text))
        #expect(counting.calls == 0)
        #expect(target.exists && t.sub("home/voice").exists)
        #expect(trail.items.isEmpty)
        #expect(summary.outcome == .stopped)
        #expect(summary.reason == "先结束会议模式。")
        #expect(summary.done == ["默认输入已还原到 MacBook Pro 麦克风"])
        #expect(summary.headline.contains("停下之前已经做了"))
        // the row's own 卸载 reads the same meeting-mode closure
        m.requestUninstall()
        #expect(m.confirmation == nil)
        #expect(m.notice == "先结束会议模式。")
    }

    @Test func callStillOnRefusesBeforeAnythingElse() async throws {
        try FakeDriver.make(in: t.sub("HAL"), version: "9.9.9", sign: true)
        let counting = CountingRunner()
        let (phase, summary) = try await fullUninstall(model(restore: .callOngoing, runner: counting))
        #expect(phase == .blocked("通话还在进行：先离开会议，再完全卸载。"))
        #expect(counting.calls == 0 && target.exists && trail.items.isEmpty)
        #expect(summary.reason == "通话还在进行：先离开会议，再完全卸载。")
        #expect(summary.done.isEmpty)
        #expect(summary.headline == "没有完全卸载，什么都没删。")
        #expect(summary.short == "通话还在进行" && !summary.failed)
    }

    /// Not this app's record (the switcher says nil): `restoreStale` decides, at the paths given.
    @Test func notOurRecordGoesToTheStalePath() async throws {
        // a record whose lock another TalkTalk holds: refused, the record stays
        try SysInputRecordStore(paths: sysinput).write(
            SysInputRecord(original: .init(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro 麦克风", transport: "bltn"),
                           writerBundleID: "com.aaajiao.talktalk", executablePath: "/x"))
        let other = SysInputLock(path: sysinput.lock.path)
        #expect(other.tryAcquire())
        let (phase, _) = try await fullUninstall(model(restore: nil))
        #expect(phase == .blocked("另一个 TalkTalk 正在管系统默认输入：先在那边结束会议模式。"))
        #expect(SysInputRecordStore(paths: sysinput).exists && trail.items.isEmpty)
        other.release()
        // no record at all: the run goes on (no driver on disk: no authorization, nothing reported)
        SysInputRecordStore(paths: sysinput).delete()
        let counting = CountingRunner()
        let (done, summary) = try await fullUninstall(model(restore: nil, runner: counting))
        guard case .finished = done else { Issue.record("\(done)"); return }
        #expect(counting.calls == 0)
        #expect(trail.items == ["keychain", "prefs", "login", "tcc"])
        #expect(summary.outcome == .complete)
        #expect(!summary.done.contains("虚拟麦克风"))
        #expect(!t.sub("home/voice").exists)
    }

    @Test func cancelledAuthorizationKeepsWhatStepOneDid() async throws {
        try FakeDriver.make(in: t.sub("HAL"), version: "9.9.9", sign: true)
        let cancel = CountingRunner(result: .failure(.cancelled))
        let (phase, summary) = try await fullUninstall(model(restore: .restored("Shure MV7"), runner: cancel))
        #expect(phase == .cancelled)
        #expect(cancel.calls == 1 && target.exists && t.sub("home/voice").exists && trail.items.isEmpty)
        #expect(summary.headline.hasPrefix("已取消，停下之前已经做了"))
        #expect(summary.done == ["默认输入已还原到 Shure MV7"])
        #expect(summary.reason == nil)
    }

    /// Every step ran, two did not work: each is listed, nothing claims otherwise.
    @Test func finishedWithProblemsListsEachOne() async throws {
        try FakeDriver.make(in: t.sub("HAL"), version: "9.9.9", sign: true)
        try FileManager.default.createDirectory(at: t.sub("home/engine"), withIntermediateDirectories: true)
        let (phase, summary) = try await fullUninstall(model(restore: .noRecord, keychain: "errSecInteractionNotAllowed"))
        guard case .finished(let r) = phase else { Issue.record("\(phase)"); return }
        #expect(!target.exists)
        #expect(r.removed.contains("虚拟麦克风"))
        #expect(!r.removed.contains("引擎和模型"), "a build without install-engine.sh removed no engine")
        #expect(summary.outcome == .incomplete)
        #expect(summary.notRemoved == [
            "引擎：这个构建没有带 install-engine.sh，引擎没有卸载",
            "引擎：\(t.sub("home/engine").path) 没有删除（卸载以后还在；确定不要的话，在访达里删除）",
            "钥匙串：errSecInteractionNotAllowed",
        ])
        #expect(summary.headline.contains("有 3 项没有删除或没有做成"))
        #expect(t.sub("home/engine").exists)
    }

    @Test func summaryTexts() {
        #expect(FullUninstallSummary(phase: .idle, report: .init()) == nil)
        #expect(FullUninstallSummary(phase: .running(.engine), report: .init()) == nil)
        let failed = FullUninstallSummary(phase: .failed(.driver, "install-driver.sh exited 4"),
                                          report: .init(removed: ["默认输入已还原到 X"]))
        #expect(failed?.headline == "完全卸载停在“卸载虚拟麦克风”，停下之前已经做了下面这些，其余什么都没删。")
        #expect(failed?.reason == "install-driver.sh exited 4")
        #expect(failed?.short == "停在“卸载虚拟麦克风”" && failed?.failed == true)
        let cancelled = FullUninstallSummary(phase: .cancelled, report: .init())
        #expect(cancelled?.headline == "已取消，什么都没删。" && cancelled?.short == "已取消")
        let clean = FullUninstallSummary(phase: .finished(.init(removed: ["虚拟麦克风"])), report: .init())
        #expect(clean?.outcome == .complete && clean?.notRemoved.isEmpty == true)
        #expect(clean?.short == "已删除 1 项")
        #expect(FullUninstallSummary(phase: .blocked("先结束会议模式。"), report: .init())?.short == "先结束会议模式")
        // English clauses end at punctuation before a space or the end, not inside names or versions.
        #expect(FullUninstallSummary.firstClause("Calls are still on. Leave first.") == "Calls are still on")
        #expect(FullUninstallSummary.firstClause("Update Demo.app to 1.0.15 first.") == "Update Demo.app to 1.0.15 first")
        for step in FullUninstaller.Step.allCases { #expect(step.title.unicodeScalars.contains { $0.value > 0x2E80 }) }
    }

    /// The model is busy for the whole 完全卸载 run, not only during the driver step: install,
    /// uninstall and self-test stay disabled while the engine and files steps run.
    @Test func busyForTheWholeRun() async throws {
        let probe = Probe()
        let m = model(restore: .noRecord, probe: probe)
        #expect(!m.isBusy && !m.fullUninstallRunning)
        await m.confirm(.fullUninstall)
        #expect(probe.busyDuringEngineStep == true)
        // the engine rows' blockedBy (DriverComponentsPage) is true for the run, false after it
        #expect(probe.engineRowsBlockedDuringEngineStep == true)
        #expect(!m.fullUninstallRunning)
        #expect(!m.isBusy)
        // A complete run left nothing to remove: the button stays disabled (quit and trash the app).
        #expect(m.fullUninstallSummary?.outcome == .complete)
        m.requestFullUninstall()
        #expect(!m.confirmingFullUninstall)
    }

    /// A running session disables 完全卸载 beforehand instead of refusing it after the confirmation.
    @Test func aRunningSessionDisablesFullUninstall() {
        let m = model(restore: .noRecord)
        final class Session: @unchecked Sendable { var running = true }
        let session = Session()
        m.sessionActive = { session.running }
        #expect(m.fullUninstallBlocked)
        m.requestFullUninstall()
        #expect(!m.confirmingFullUninstall)
        session.running = false
        #expect(!m.fullUninstallBlocked)
    }

    /// A fake install-engine.sh at `t/engine-installer.sh` running `body`.
    func engineInstaller(_ body: String) throws -> EngineInstaller {
        let script = t.sub("install-engine.sh")
        try Data("#!/bin/bash\n\(body)\n".utf8).write(to: script)
        let paths = EnginePaths(home: t.sub("home"), logs: t.sub("logs"), caches: t.sub("caches"), engineSource: nil,
                                installerScript: script)
        return EngineInstaller(script: script, paths: paths)
    }

    /// The real EngineInstaller with a script that exits 0 and keeps things, as install-engine.sh
    /// does with foreign files, old revisions and a cancelled install's `.python.tmp-<pid>`
    /// (review of 639f957 #1): "没有删除" for each, the engine not reported removed.
    @Test func engineScriptThatKeepsThingsIsReportedNotRemoved() async throws {
        let home = t.sub("home/engine")
        for d in ["models/Qwen--Qwen3-TTS@0123456789ab", "models/Qwen--Qwen3-TTS@ba9876543210", ".python.tmp-4242", "venv"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        try Data().write(to: home.appendingPathComponent("models/Qwen--Qwen3-TTS@0123456789ab/.DS_Store"))
        try Data("x".utf8).write(to: t.sub("home/notes.txt"))
        let engine = try engineInstaller(#"/bin/rm -rf "$TALKTALK_ENGINE_HOME/venv"; exit 0"#)
        let (phase, summary) = try await fullUninstall(model(restore: .noRecord, engine: engine))
        guard case .finished(let r) = phase else { Issue.record("\(phase)"); return }
        #expect(engine.state == .finished)
        #expect(!r.removed.contains("引擎和模型"))
        #expect(!home.appendingPathComponent("venv").exists)
        let kept = { (p: String) in "引擎：\(home.appendingPathComponent(p).path) 没有删除（卸载以后还在；确定不要的话，在访达里删除）" }
        #expect(summary.outcome == .incomplete)
        #expect(summary.notRemoved == [
            kept(".python.tmp-4242"),
            kept("models/Qwen--Qwen3-TTS@0123456789ab"),
            kept("models/Qwen--Qwen3-TTS@ba9876543210"),
            "\(t.sub("home/notes.txt").path) 没有删除（不在完全卸载要删的清单里；确定不要的话，在访达里删除）",
        ])
        #expect(t.sub("home").exists)
    }

    /// The engine installer runs (here a check that takes a while): 完全卸载 is greyed out and,
    /// when asked anyway, refuses before step 1; the engine run goes on (review of 639f957 #2).
    @Test func engineInstallerRunningBlocksFullUninstall() async throws {
        try FakeDriver.make(in: t.sub("HAL"), version: "9.9.9", sign: true)
        let engine = try engineInstaller("/bin/sleep 10")
        let counting = CountingRunner()
        let m = model(restore: .restored("MacBook Pro 麦克风"), runner: counting, engine: engine)
        let run = Task { await engine.run(.check) }
        for _ in 0..<200 where !engine.state.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.state.isRunning)
        #expect(m.fullUninstallBlocked && !m.isBusy, "driver actions do not wait for the engine")
        m.requestFullUninstall()
        #expect(!m.confirmingFullUninstall)
        await m.confirm(.fullUninstall)
        #expect(m.fullUninstaller?.phase == .blocked(FullUninstaller.engineBusyText))
        #expect(m.fullUninstallSummary?.done == [], "step 1 did not run")
        #expect(counting.calls == 0 && target.exists && t.sub("home/voice").exists && t.sub("logs").exists)
        #expect(engine.state.isRunning)
        engine.cancel()
        #expect(await run.value == .cancelled)
        #expect(!m.fullUninstallBlocked)
    }

    /// Onboarding step 3's meeting-path run (`runSelfTest(includeMeetingPath: true)`) asks the
    /// model's restore-record check right before the sweep, never a fixed `false`.
    @Test func selfTestAsksTheModelsRestoreRecordCheck() {
        let m = DriverComponentModel(installer: model(restore: nil).installer, fullUninstaller: nil,
                                     isMeetingModeOn: { false }, restoreRecordExists: { true },
                                     selfTestOptions: { .init() })
        let test = m.makeSelfTest()
        #expect(test.restoreRecordExists())
        #expect(DriverSelfTest.meetingPathBlocker(hal: hal, restoreRecordExists: test.restoreRecordExists()) == "有默认输入还原记录")
    }

    /// One status for the flow node, the 虚拟麦克风 card and the 驱动 row, and the results in the
    /// settings vocabulary (§7.12): after an uninstall the meeting hears the physical microphone.
    @Test func statusAndResultsInSettingsWords() {
        let m = model(restore: nil)
        #expect(m.status == SettingsProblem(.pending, "未安装"))
        #expect(DriverComponentModel.result(.finished(.uninstalled))
            == SettingsProblem(.risk, "已卸载 · 会议改用实体麦（对方听到原声）"))
        #expect(DriverComponentModel.result(.finished(.installed(version: "9.9.9"))) == SettingsProblem(.ok, "已安装 9.9.9"))
        #expect(DriverComponentModel.result(.failed("退出码 1")) == SettingsProblem(.failed, "未成功", help: "退出码 1"))
        #expect(DriverComponentModel.result(.staging) == nil)
    }

    // MARK: rendering (for review: TALKTALK_RENDER_DIR=<dir> swift test --filter ComponentsWiringTests)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TALKTALK_RENDER_DIR"] != nil))
    func renderComponentRows() async throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TALKTALK_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // not installed, nothing run yet
        try render(model(restore: .noRecord), to: dir.appendingPathComponent("components-idle.png"))
        // wiring (d): restored, then stopped at the driver
        try FakeDriver.make(in: t.sub("HAL"), version: "9.9.9", sign: true)
        let stopped = model(meetingModeOn: true, restore: .restored("MacBook Pro 麦克风"), runner: CountingRunner())
        await stopped.confirm(.fullUninstall)
        try render(stopped, to: dir.appendingPathComponent("components-stopped.png"))
        // finished with two problems
        try FileManager.default.createDirectory(at: t.sub("home/engine"), withIntermediateDirectories: true)
        let partial = model(restore: .noRecord, keychain: "errSecInteractionNotAllowed")
        await partial.confirm(.fullUninstall)
        try render(partial, to: dir.appendingPathComponent("components-incomplete.png"))
    }

    func render(_ m: DriverComponentModel, to url: URL) throws {
        // 完全卸载 as Settings › 通用 shows it: its own section of a grouped Form.
        let root = Form {
            Section { DriverComponentRows(model: m) }
            Section { FullUninstallSection(model: m) }
        }
        .formStyle(.grouped)
        .labelStyle(.settingsRow)
        .driverComponentLifecycle(m)
        .frame(width: 640, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        _ = NSApplication.shared
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 560)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
