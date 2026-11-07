import Foundation
import Testing
@testable import TalkTalkDriverSupport

/// §8.4: manifest checks, the six install states, driver.json, and the install-driver.sh output
/// contract (docs/decisions/m0-t8-driver.md "Merge notes").
@Suite struct DriverManifestTests {
    @Test func freshBundleMatchesItsManifest() throws {
        let t = try TempDir()
        let (bundle, manifestURL) = try FakeDriver.make(in: t.url, sign: false)
        let m = try DriverManifest.read(manifestURL)
        #expect(m.version == "9.9.9")
        #expect(m.verify(bundle: bundle) == [])
    }

    @Test func tamperedExtraMissingAndSymlinkAreReported() throws {
        let t = try TempDir()
        let (bundle, manifestURL) = try FakeDriver.make(in: t.url, sign: false)
        let m = try DriverManifest.read(manifestURL)
        let lic = bundle.appendingPathComponent("Contents/Resources/libASPL-LICENSE.txt")
        try Data("MIT (tampered)\n".utf8).write(to: lic)   // same length? no: size or hash differs
        try Data("x".utf8).write(to: bundle.appendingPathComponent("Contents/Resources/extra.txt"))
        try FileManager.default.createSymbolicLink(at: bundle.appendingPathComponent("Contents/link"),
                                                   withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let problems = m.verify(bundle: bundle)
        #expect(problems.contains { $0.hasPrefix("Contents/Resources/libASPL-LICENSE.txt") })
        #expect(problems.contains("not in manifest: Contents/Resources/extra.txt"))
        #expect(problems.contains("symlink Contents/link"))
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("Contents/Info.plist"))
        #expect(m.verify(bundle: bundle).contains("missing Contents/Info.plist"))
    }

    @Test func foreignIdentifierIsRejected() throws {
        let t = try TempDir()
        let (bundle, manifestURL) = try FakeDriver.make(in: t.url, identifier: "com.example.other", sign: false)
        #expect(try DriverManifest.read(manifestURL).verify(bundle: bundle).first?.contains("com.example.other") == true)
    }
}

@Suite struct DriverInstallationTests {
    func installation(_ t: TempDir, hal: FakeDriverHAL, bundled: String? = "9.9.9") -> DriverInstallation {
        DriverInstallation(paths: DriverPaths(home: t.sub("home"), logs: t.sub("logs"), caches: t.sub("caches")),
                           bundledVersion: bundled, hal: hal, installedBundle: t.sub("HAL/\(DriverIdentity.bundleName)"))
    }

    @Test func notInstalled() throws {
        let t = try TempDir()
        #expect(installation(t, hal: FakeDriverHAL()).check().state == .notInstalled)
    }

    @Test func onDiskNotLoadedUntilTheHALHasIt() throws {
        let t = try TempDir()
        try FakeDriver.make(in: t.sub("HAL"), sign: false)
        #expect(installation(t, hal: FakeDriverHAL()).check().state == .onDiskNotLoaded(version: "9.9.9"))
        // an older copy still loaded: the new files need a restart too
        #expect(installation(t, hal: FakeDriverHAL(loaded: "0.1.0")).check().state == .onDiskNotLoaded(version: "9.9.9"))
    }

    @Test func loadedOutdatedAndSelfTestFailed() throws {
        let t = try TempDir()
        try FakeDriver.make(in: t.sub("HAL"), sign: false)
        let hal = FakeDriverHAL(loaded: "9.9.9")
        #expect(installation(t, hal: hal).check().state == .loaded(version: "9.9.9"))
        #expect(installation(t, hal: hal, bundled: "10.0.0").check().state == .outdated(installed: "9.9.9", bundled: "10.0.0"))
        let i = installation(t, hal: hal)
        try i.recordSelfTest(.init(version: "9.9.9", passed: false, failed: ["loopback"]))
        #expect(i.check().state == .selfTestFailed(version: "9.9.9", failed: ["loopback"]))
        // a failed result of another version does not count
        try i.recordSelfTest(.init(version: "0.1.0", passed: false, failed: ["gate"]))
        #expect(i.check().state == .loaded(version: "9.9.9"))
    }

    /// review m0-driver [4]: a run that skipped loopback / replay / gate is not a pass and keeps
    /// the earlier driver.json result.
    @Test func incompleteSelfTestKeepsTheEarlierRecord() throws {
        let t = try TempDir()
        try FakeDriver.make(in: t.sub("HAL"), sign: false)
        let i = installation(t, hal: FakeDriverHAL(loaded: "9.9.9"))
        try i.recordSelfTest(.init(version: "9.9.9", passed: false, failed: ["replay"]))

        // no microphone permission: properties ran, the IO checks were skipped
        var skipped = DriverSelfTestReport(version: "9.9.9", checks: [.init(.properties, passed: true)],
                                           skipReason: "没有麦克风授权")
        for n in [DriverSelfTestReport.Check.Name.loopback, .isolation, .replay, .gate] {
            skipped.checks.append(.init(n, passed: nil, detail: "需要麦克风权限"))
        }
        #expect(!skipped.passed && !skipped.isConclusive)
        #expect(skipped.notRun == [.loopback, .replay, .gate])
        #expect(skipped.incompleteText == "跳过：没有麦克风授权")
        #expect(try i.record(skipped) == false)
        #expect(i.check().state == .selfTestFailed(version: "9.9.9", failed: ["replay"]))

        // gate not run (no feedprobe) and nothing failed: not a pass either
        let noGate = DriverSelfTestReport(version: "9.9.9", checks: [
            .init(.properties, passed: true), .init(.loopback, passed: true), .init(.replay, passed: true),
            .init(.gate, passed: nil, detail: "feedprobe is not in this build"),
        ])
        #expect(!noGate.passed && !noGate.isConclusive)
        #expect(noGate.incompleteText == "跳过：门禁没有跑（feedprobe is not in this build）")
        // stored names read as words; one this build does not know stays as stored
        #expect(DriverSelfTestReport.Check.Name.shortTitles(["loopback", "isolation", "later"]) == "回环、隔离、later")
        #expect(try i.record(noGate) == false)

        // isolation and meetingPath may be skipped: a pass, and it replaces the failure
        let full = DriverSelfTestReport(version: "9.9.9", checks: [
            .init(.properties, passed: true), .init(.loopback, passed: true), .init(.isolation, passed: nil),
            .init(.replay, passed: true), .init(.gate, passed: true), .init(.meetingPath, passed: nil),
        ])
        #expect(full.passed && full.isConclusive)
        #expect(try i.record(full))
        #expect(i.check().state == .loaded(version: "9.9.9"))

        // a failure is a verdict even with other checks not run
        let gateFailed = DriverSelfTestReport(version: "9.9.9", checks: [.init(.properties, passed: true),
                                                                          .init(.gate, passed: false)])
        #expect(!gateFailed.passed && gateFailed.isConclusive)
        #expect(try i.record(gateFailed))
        #expect(i.check().state == .selfTestFailed(version: "9.9.9", failed: ["gate"]))
    }

    /// review m0-driver [5]: the sweep into TalkTalk Mic checks §8.4's conditions again right before it.
    @Test func meetingPathChecksAgainBeforeTheSweep() async {
        let hal = FakeDriverHAL(loaded: "9.9.9")
        hal.state.withLock { $0.defaultInput = DriverIdentity.micUID }
        let c = await IORunner(hal: hal, restoreRecordExists: { false }).meetingPath(feed: 10, mic: 12, testMic: 11)
        #expect(c.name == .meetingPath && c.passed == nil && c.detail == "系统默认输入是 TalkTalk Mic")
        hal.state.withLock { $0.defaultInput = "BuiltInMicrophoneDevice" }
        let r = await IORunner(hal: hal, restoreRecordExists: { true }).meetingPath(feed: 10, mic: 12, testMic: 11)
        #expect(r.passed == nil && r.detail == "有默认输入还原记录")
    }

    @Test func damagedCases() throws {
        let t = try TempDir()
        try FakeDriver.make(in: t.sub("HAL"), identifier: "com.example.other", sign: false)
        guard case .damaged(let why) = installation(t, hal: FakeDriverHAL()).check().state else {
            Issue.record("foreign bundle not damaged"); return
        }
        #expect(why.contains("com.example.other"))

        let t2 = try TempDir()
        try FileManager.default.createDirectory(at: t2.sub("HAL"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: t2.sub("HAL/\(DriverIdentity.bundleName)"),
                                                   withDestinationURL: t2.url)
        guard case .damaged = installation(t2, hal: FakeDriverHAL()).check().state else {
            Issue.record("symlink not damaged"); return
        }

        let t3 = try TempDir()
        try FakeDriver.make(in: t3.sub("HAL"), sign: false)
        let hal = FakeDriverHAL(loaded: "9.9.9")
        var feed = FakeDriverHAL.feed()
        feed.isHidden = false
        hal.set(feed, uid: DriverIdentity.feedUID)
        guard case .damaged(let w) = installation(t3, hal: hal).check().state else { Issue.record("visible Feed"); return }
        #expect(w.contains("Feed is not hidden"))

        // removed from disk, still loaded
        let t4 = try TempDir()
        guard case .damaged(let r) = installation(t4, hal: FakeDriverHAL(loaded: "9.9.9")).check().state else {
            Issue.record("loaded without files"); return
        }
        #expect(r.contains("重启音频服务"))
    }

    @Test func recordRoundTripIs0600() throws {
        let t = try TempDir()
        let i = installation(t, hal: FakeDriverHAL())
        let r = DriverInstallation.Record(version: "9.9.9", sha256: "ab", installedAt: Date(timeIntervalSince1970: 1_800_000_000.7))
        try i.writeRecord(r)
        #expect(try i.readRecord() == r)
        let mode = (try FileManager.default.attributesOfItem(atPath: i.paths.record.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        let text = try String(contentsOf: i.paths.record, encoding: .utf8)
        #expect(text.contains("\"installed_at\""))
        i.deleteRecord()
        #expect(try i.readRecord() == nil)
    }
}

@Suite struct DriverScriptTests {
    @Test func argumentsFollowTheContract() {
        let s = URL(fileURLWithPath: "/x/TalkTalkAudio.driver"), m = URL(fileURLWithPath: "/x/driver-manifest.json")
        #expect(DriverScriptOp.install(staged: s, manifest: m).arguments
            == ["--json", "install", "/x/TalkTalkAudio.driver", "--manifest", "/x/driver-manifest.json"])
        #expect(DriverScriptOp.uninstall.arguments == ["--json", "uninstall"])
        #expect(DriverScriptOp.restartAudio.arguments == ["--json", "restart-audio"])
        #expect(!DriverScriptOp.status.needsRoot && DriverScriptOp.uninstall.needsRoot)
    }

    @Test func parsesEventsMarkerAndOtherLines() {
        let text = """
            {"kind":"msg","msg":"manifest ok (5 files)"}
            {"kind":"kv","key":"restart_method","value":"sigterm-pid"}
            install-driver: error: something
            {"kind":"kv","key":"error","value":"checksum mismatch: Contents/Info.plist"}
            {"kind":"kv","key":"result","value":"error"}
            tt-exit=1

            """
        let out = DriverScriptOutput.parse(text, fallbackExit: -1)
        #expect(out.exitCode == 1)
        #expect(out.messages == ["manifest ok (5 files)"])
        #expect(out.values["restart_method"] == "sigterm-pid")
        #expect(out.result == "error")
        #expect(out.error == "checksum mismatch: Contents/Info.plist")
        #expect(out.otherLines == ["install-driver: error: something"])
        #expect(DriverScriptOutcome(out) == .refused("checksum mismatch: Contents/Info.plist"))
        #expect(DriverScriptOutput.parse("garbage", fallbackExit: 7).exitCode == 7)
    }

    @Test func exitCodesMapToOutcomes() {
        #expect(DriverScriptOutcome(.init(exitCode: 0)) == .ok)
        #expect(DriverScriptOutcome(.init(exitCode: 3)) == .changedNotRestarted)
        #expect(DriverScriptOutcome(.init(otherLines: ["usage"], exitCode: 2)) == .usage("usage"))
        #expect(DriverScriptOutcome(.init(exitCode: 9)) == .failed("install-driver.sh exited 9"))
    }

    @Test func shellAndAppleScriptQuoting() {
        let script = URL(fileURLWithPath: "/Applications/Talk \"Talk\".app/Contents/Resources/driver/install-driver.sh")
        let staged = URL(fileURLWithPath: "/Users/o'neil/Library/Caches/TalkTalk/installer-tmp/d/TalkTalkAudio.driver")
        let cmd = AdminScriptRunner.shellCommand(script: script, op: .install(staged: staged,
                                                                              manifest: staged.deletingLastPathComponent()
                                                                                  .appendingPathComponent("driver-manifest.json")))
        #expect(cmd.hasPrefix("/bin/bash '/Applications/Talk \"Talk\".app/"))
        #expect(cmd.contains("'/Users/o'\\''neil/Library/"))
        #expect(cmd.hasSuffix(" 2>&1; echo tt-exit=$?"))
        let src = AdminScriptRunner.appleScriptSource(shellCommand: cmd, prompt: "装 \"驱动\"", admin: true)
        #expect(src.hasPrefix("do shell script \"/bin/bash '/Applications/Talk \\\"Talk\\\".app/"))
        #expect(src.contains("with administrator privileges with prompt \"装 \\\"驱动\\\"\""))
        #expect(src.hasSuffix(" without altering line endings"))
        #expect(!AdminScriptRunner.appleScriptSource(shellCommand: "x", prompt: "p", admin: false).contains("administrator"))
        // The quoted command must survive the shell exactly: run it through bash -c with echo.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "printf '%s\\n' " + AdminScriptRunner.shellQuote("a'b \"c\" $d")]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        #expect(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "a'b \"c\" $d\n")
    }

    @Test func diagnosticsDictionaryParsing() {
        let d: [String: Any] = [
            "version": "0.1.0", "feedAddClientDenied": NSNumber(value: 51), "feedStartIODenied": NSNumber(value: 2),
            "micInList": NSNumber(value: 1), "micMode": NSNumber(value: 0), "feedClients": NSNumber(value: 1),
            "micIO": NSNumber(value: 1),
            "clients": [
                ["device": "mic", "pid": NSNumber(value: 4242), "bundleID": "us.zoom.xos", "allowed": NSNumber(value: 1),
                 "ioRunning": NSNumber(value: 1)],
                ["device": "feed", "pid": NSNumber(value: 99), "bundleID": "", "allowed": NSNumber(value: 0),
                 "ioRunning": NSNumber(value: 0)],
            ],
        ]
        let g = DriverDiagnostics(dictionary: d)
        #expect(g.version == "0.1.0" && g.feedAddClientDenied == 51 && g.feedStartIODenied == 2)
        #expect(g.micInList == true && g.micMode == 0 && g.feedClients == 1 && g.micIO == 1)
        #expect(g.micUsers.map(\.pid) == [4242])
        #expect(g.clients[1].bundleID == nil)
        #expect(g.meetingMode == nil && g.micCanBeDefault == nil && g.ttmmLastPID == nil)

        // M2 driver: the 'ttmm' fields
        let m2 = DriverDiagnostics(dictionary: ["version": "0.2.0", "meetingMode": NSNumber(value: 1),
                                                "micCanBeDefault": NSNumber(value: 1), "ttmmWrites": NSNumber(value: 3),
                                                "ttmmDenied": NSNumber(value: 2), "ttmmLastPID": NSNumber(value: 777)])
        #expect(m2.meetingMode == true && m2.micCanBeDefault == true)
        #expect(m2.ttmmWrites == 3 && m2.ttmmDenied == 2 && m2.ttmmLastPID == 777)
    }
}
