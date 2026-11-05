import Foundation
import Testing
@testable import TalkTalkAudio
@testable import TalkTalkDriverSupport
import TalkTalkEngineHost

/// §8.4 install / uninstall through the real scripts/driver/install-driver.sh, run as the current
/// user against a temp HAL directory (`TT_HAL_DIR` + `TT_INSTALL_ALLOW_NONROOT=1`, `--no-restart`:
/// coreaudiod is never touched). The HAL is a fake that "loads" the driver after a few polls.
@MainActor
@Suite(.serialized)
struct DriverInstallerTests {
    let t: TempDir
    let resources: DriverResources
    let hal = FakeDriverHAL()

    init() throws {
        t = try TempDir("tt-driver-installer")
        let res = t.sub("Resources/driver")
        try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
        try FakeDriver.make(in: res, version: "9.9.9", sign: true)
        let repoScript = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../scripts/driver/install-driver.sh").standardizedFileURL
        try FileManager.default.copyItem(at: repoScript, to: res.appendingPathComponent("install-driver.sh"))
        let versions = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../scripts/lib/versions.sh").standardizedFileURL
        try FileManager.default.copyItem(at: versions, to: res.appendingPathComponent("versions.sh"))
        try FileManager.default.createDirectory(at: t.sub("HAL"), withIntermediateDirectories: true)
        resources = DriverResources(directory: res)
    }

    var paths: DriverPaths { DriverPaths(home: t.sub("home"), logs: t.sub("logs"), caches: t.sub("caches")) }
    var target: URL { t.sub("HAL/\(DriverIdentity.bundleName)") }

    func installer(preflight: DriverPreflight.Inputs = .init(), runner: (any DriverScriptRunner)? = nil) -> DriverInstaller {
        let r = runner ?? DirectScriptRunner(environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                                                           "TT_HAL_DIR": t.sub("HAL").path,
                                                           "TT_INSTALL_ALLOW_NONROOT": "1"],
                                             extraArguments: ["--no-restart"])
        return DriverInstaller(resources: resources, paths: paths, hal: hal, runner: r, pollInterval: .milliseconds(5),
                               pollAttempts: 30, installedBundle: target, preflightInputs: { preflight })
    }

    func log() -> String { (try? String(contentsOf: paths.installLog, encoding: .utf8)) ?? "" }

    @Test func installThenUninstallWithTheRealScript() async throws {
        hal.state.withLock {
            $0.appearAfterPolls = 3
            $0.pendingDevices = [DriverIdentity.feedUID: FakeDriverHAL.feed(), DriverIdentity.testMicUID: FakeDriverHAL.testMic()]
        }
        let i = installer()
        let p = await i.install()
        #expect(p == .finished(.installed(version: "9.9.9")), "\(log())")
        #expect(target.appendingPathComponent("Contents/Info.plist").exists)
        #expect(i.messages.contains { $0.hasPrefix("manifest ok") })
        let record = try #require(try i.installation.readRecord())
        #expect(record.version == "9.9.9")
        #expect(record.sha256 == (try DriverManifest.sha256(of: resources.manifestURL)))
        #expect(i.installation.check().state == .loaded(version: "9.9.9"))
        // staging is cleaned up
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: paths.installerTmp.path)) ?? []
        #expect(staged.isEmpty)
        #expect(log().contains("result=ok"))

        hal.state.withLock { $0.devices = [:] }
        let u = await i.uninstall()
        #expect(u == .finished(.uninstalled), "\(log())")
        #expect(!target.exists)
        #expect(try i.installation.readRecord() == nil)
    }

    @Test func tamperedBundleIsRejectedBeforeAuthorization() async throws {
        let lic = resources.bundle.appendingPathComponent("Contents/Resources/libASPL-LICENSE.txt")
        try Data("MIT (tampered)\n".utf8).write(to: lic)
        let runner = CountingRunner()
        let p = await installer(runner: runner).install()
        guard case .failed(let why) = p else { Issue.record("expected failure, got \(p)"); return }
        #expect(why.contains("libASPL-LICENSE.txt"))
        #expect(runner.calls == 0)
        #expect(!target.exists)
    }

    @Test func foreignTargetIsRefusedByTheScript() async throws {
        try FakeDriver.make(in: t.sub("HAL"), identifier: "com.example.other", sign: false)
        let p = await installer().install()
        guard case .failed(let why) = p else { Issue.record("expected refusal, got \(p)"); return }
        #expect(why.contains("not ours"))
        let id = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: target.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        #expect(id?["CFBundleIdentifier"] as? String == "com.example.other")
    }

    @Test func preflightBlocksAndNothingRuns() async {
        let runner = CountingRunner()
        let p = await installer(preflight: .init(meetingModeOn: true, restoreRecordExists: true), runner: runner).install()
        #expect(p == .blocked(DriverPreflight(blockers: [.meetingModeOn, .restoreRecordPresent])))
        #expect(runner.calls == 0)
    }

    @Test func cancelledAuthorizationAndExit3() async throws {
        let cancel = CountingRunner(result: .failure(.cancelled))
        #expect(await installer(runner: cancel).install() == .cancelled)
        #expect(try installer().installation.readRecord() == nil)

        let notRestarted = CountingRunner(result: .success(.init(events: [.value(key: "result", value: "on-disk-not-loaded")],
                                                                 exitCode: 3)))
        let i = installer(runner: notRestarted)
        #expect(await i.install() == .finished(.needsLogout))
        #expect(try i.installation.readRecord()?.version == "9.9.9")
    }

    // 完全卸载's driver step, as `FullUninstaller.Dependencies.live` builds it (review m0-driver [2], [3]).
    func liveDriverStep(_ i: DriverInstaller) -> (@MainActor @Sendable () async -> DriverInstaller.Phase?)? {
        let p = EnginePaths(home: t.sub("home"), logs: t.sub("logs"), caches: t.sub("caches"), engineSource: nil,
                            installerScript: nil)
        return FullUninstaller.Dependencies.live(bundleID: "com.example.tt-test", driver: i, engine: nil, enginePaths: p)
            .uninstallDriver
    }

    @Test func fullUninstallLooksAtTheDiskWhenTheStepRuns() async throws {
        // built while nothing was installed; the driver gets installed later in the same settings window
        let step = try #require(liveDriverStep(installer()))
        try FakeDriver.make(in: t.sub("HAL"), version: "9.9.9", sign: true)
        #expect(target.exists)
        #expect(await step() == .finished(.uninstalled), "\(log())")
        #expect(!target.exists)
        // built while it was installed, removed since: no authorization, no coreaudiod restart
        try FakeDriver.make(in: t.sub("HAL"), version: "9.9.9", sign: true)
        let counting = CountingRunner()
        let again = try #require(liveDriverStep(installer(runner: counting)))
        try FileManager.default.removeItem(at: target)
        #expect(await again() == nil)
        #expect(counting.calls == 0)
    }

    @Test func fullUninstallStillRefusesDuringACall() async throws {
        try FakeDriver.make(in: t.sub("HAL"), version: "9.9.9", sign: true)
        let zoom = MeetingCandidate(app: MeetingApp.named("us.zoom.xos")!,
                                    processes: [AudioProcessInfo(objectID: 10, pid: 10, bundleID: "us.zoom.xos",
                                                                 isRunningInput: true, isRunningOutput: false)])
        // a call going on and no restore record: blocked, the script never runs, the Mic stays
        let counting = CountingRunner()
        let step = try #require(liveDriverStep(installer(preflight: .init(meetings: [zoom], ownPID: 1), runner: counting)))
        #expect(await step() == .blocked(DriverPreflight(blockers: [.meetingInProgress(["Zoom"])])))
        #expect(counting.calls == 0)
        #expect(target.exists)
        // the restore record alone does not block here: 完全卸载's first step dealt with it
        let ok = CountingRunner(result: .success(.init(events: [.value(key: "result", value: "ok")], exitCode: 0)))
        let step2 = try #require(liveDriverStep(installer(preflight: .init(restoreRecordExists: true, ownPID: 1), runner: ok)))
        #expect(await step2() == .finished(.uninstalled))
        #expect(ok.calls == 1)
        // the settings row's own uninstall still treats the record as a blocker
        let counting2 = CountingRunner()
        #expect(await installer(preflight: .init(restoreRecordExists: true, ownPID: 1), runner: counting2).uninstall()
            == .blocked(DriverPreflight(blockers: [.restoreRecordPresent])))
        #expect(counting2.calls == 0)
    }

    /// An interrupted install leaves root-owned `.TalkTalkAudio.driver.tmp-*` / `.old` next to a
    /// missing bundle: 完全卸载 must still run the script, which removes them (review m0-driver 0ab2135 #2).
    @Test func fullUninstallRemovesInstallLeftovers() async throws {
        let hal = t.sub("HAL")
        for leftover in [".\(DriverIdentity.bundleName).tmp-4242", ".\(DriverIdentity.bundleName).old"] {
            try FakeDriver.make(in: hal, version: "9.9.9", sign: true)
            try FileManager.default.moveItem(at: target, to: hal.appendingPathComponent(leftover))
            try? FileManager.default.removeItem(at: hal.appendingPathComponent("driver-manifest.json"))
            let i = installer()
            #expect(i.installation.diskState() == .absent)
            #expect(i.installation.leftovers().map(\.lastPathComponent) == [leftover])
            let step = try #require(liveDriverStep(i))
            #expect(await step() == .finished(.uninstalled), "\(log())")
            #expect(i.installation.leftovers().isEmpty, "\(leftover) is still there")
            #expect(!target.exists)
        }
    }

    /// A leftover name that is not ours (here a half-copied tmp without Info.plist) is left alone by
    /// the script, so it must not trigger the authorization by itself, and 完全卸载 reports it
    /// instead of claiming everything was removed (review m0-driver 3c2cffc #1).
    @Test func foreignLeftoverIsKeptAndReported() async throws {
        let hal = t.sub("HAL")
        let foreign = hal.appendingPathComponent(".\(DriverIdentity.bundleName).tmp-77")
        try FileManager.default.createDirectory(at: foreign.appendingPathComponent("Contents/MacOS"),
                                                withIntermediateDirectories: true)
        // next to one of ours: the script runs, removes ours, leaves the foreign one
        let ours = hal.appendingPathComponent(".\(DriverIdentity.bundleName).tmp-4242")
        try FakeDriver.make(in: hal, version: "9.9.9", sign: true)
        try FileManager.default.moveItem(at: target, to: ours)
        let i = installer()
        #expect(i.installation.removableLeftovers().map(\.lastPathComponent) == [ours.lastPathComponent])
        let first = try await liveUninstall(i)
        #expect(first.removed.contains("虚拟麦克风"))
        #expect(first.problems.contains { $0.contains(foreign.path) }, "\(first.problems)")
        #expect(!ours.exists && foreign.exists)
        // only the foreign one: no authorization, no coreaudiod restart, still reported
        let counting = CountingRunner()
        let again = installer(runner: counting)
        #expect(again.installation.removableLeftovers().isEmpty)
        let second = try await liveUninstall(again)
        #expect(counting.calls == 0)
        #expect(!second.removed.contains { $0.hasPrefix("虚拟麦克风") })
        #expect(second.problems.contains { $0.contains(foreign.path) }, "\(second.problems)")
    }

    /// The live 完全卸载 with this installer; Keychain, defaults, login item and TCC are faked.
    func liveUninstall(_ i: DriverInstaller) async throws -> FullUninstaller.Report {
        let p = EnginePaths(home: t.sub("home"), logs: t.sub("logs"), caches: t.sub("caches"), engineSource: nil,
                            installerScript: nil)
        var d = FullUninstaller.Dependencies.live(bundleID: "com.example.tt-test", driver: i, engine: nil, enginePaths: p)
        d.restoreDefaultInput = { .noRecord }
        d.deleteKeychainItem = { nil }
        d.removePreferences = {}
        d.unregisterLoginItem = { nil }
        d.resetPrivacy = { nil }
        let phase = await FullUninstaller(d).run()
        guard case .finished(let report) = phase else {
            Issue.record("expected finished, got \(phase): \(log())")
            throw CancellationError()
        }
        return report
    }

    /// install-driver.sh's EXIT trap: a failure after the copy into `.tmp-<pid>` removes the copy.
    @Test func failedInstallLeavesNoTmpCopy() async throws {
        let failing = DirectScriptRunner(environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                                                       "TT_HAL_DIR": t.sub("HAL").path,
                                                       "TT_INSTALL_ALLOW_NONROOT": "1",
                                                       "TT_INSTALL_TEST_FAIL_AFTER_COPY": "1"],
                                         extraArguments: ["--no-restart"])
        let i = installer(runner: failing)
        let p = await i.install()
        guard case .failed(let why) = p else { Issue.record("expected failure, got \(p)"); return }
        #expect(why.contains("failing after the copy"), "\(why)")
        #expect(i.installation.leftovers().isEmpty)
        #expect(!target.exists)
    }

    @Test func devicesThatNeverAppearFailTheInstall() async throws {
        let ok = CountingRunner(result: .success(.init(events: [.value(key: "result", value: "ok")], exitCode: 0)))
        let p = await installer(runner: ok).install()
        guard case .failed(let why) = p else { Issue.record("expected failure, got \(p)"); return }
        #expect(why.contains("did not appear"))
    }
}

/// Records calls; returns a fixed result.
final class CountingRunner: DriverScriptRunner, @unchecked Sendable {
    let result: Result<DriverScriptOutput, DriverRunError>
    private(set) var calls = 0
    init(result: Result<DriverScriptOutput, DriverRunError> = .failure(.failed("should not run"))) { self.result = result }
    @MainActor func run(script: URL, op: DriverScriptOp, prompt: String) async -> Result<DriverScriptOutput, DriverRunError> {
        calls += 1
        return result
    }
}

@Suite struct DriverPreflightTests {
    func proc(_ pid: Int32, _ bundle: String?, input: Bool = false, output: Bool = false) -> AudioProcessInfo {
        AudioProcessInfo(objectID: UInt32(pid), pid: pid, bundleID: bundle, isRunningInput: input, isRunningOutput: output)
    }

    @Test func clearMachineHasNoBlockers() {
        let r = DriverPreflight.evaluate(.init(ownPID: 1))
        #expect(r.canProceed && r.warnings.isEmpty)
    }

    @Test func meetingMicUsersRecordAndMeetingMode() {
        let zoom = MeetingCandidate(app: MeetingApp.named("us.zoom.xos")!, processes: [proc(10, "us.zoom.xos", input: true)])
        let idleChrome = MeetingCandidate(app: MeetingApp.named("com.google.Chrome")!, processes: [proc(11, "com.google.Chrome")])
        let users = [DriverDiagnostics.Client(device: "mic", pid: 10, bundleID: "us.zoom.xos", allowed: true, ioRunning: true),
                     DriverDiagnostics.Client(device: "mic", pid: 1, bundleID: "com.aaajiao.talktalk.dev", allowed: true,
                                              ioRunning: true)]
        let r = DriverPreflight.evaluate(.init(meetingModeOn: true, meetings: [zoom, idleChrome], micUsers: users,
                                               restoreRecordExists: true, ownPID: 1))
        #expect(r.blockers == [.meetingModeOn, .meetingInProgress(["Zoom"]), .micInUse(["us.zoom.xos"]), .restoreRecordPresent])
        #expect(!r.canProceed)
    }

    @Test func unknownMicUseFallsBackToIsRunningSomewhere() {
        let r = DriverPreflight.evaluate(.init(mic: FakeDriverHAL.mic(running: true), micUsers: nil, ownPID: 1))
        #expect(r.blockers == [.micInUse(["未知 App"])])
        // our own IO on the Mic is not a blocker when the driver tells us who it is
        let own = DriverDiagnostics.Client(device: "mic", pid: 1, bundleID: nil, allowed: true, ioRunning: true)
        #expect(DriverPreflight.evaluate(.init(mic: FakeDriverHAL.mic(running: true), micUsers: [own], ownPID: 1)).canProceed)
    }

    @Test func playingAppsAreAWarningNotABlocker() {
        let r = DriverPreflight.evaluate(.init(processes: [proc(20, "com.example.readread", output: true),
                                                           proc(21, "com.apple.Music", output: true),
                                                           proc(1, "com.aaajiao.talktalk.dev", output: true)],
                                               ownPID: 1))
        #expect(r.canProceed)
        #expect(r.warnings == [.audioWillStop(["Readread", "Music"])])
        #expect(r.warnings[0].text.contains("约 1–2 秒"))
    }
}
