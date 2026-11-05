import Foundation
import TalkTalkAudio
import TalkTalkDriverSupport
import TalkTalkEngineHost

// m2 driver: `TalkTalk --self-test --driver --out <file>` (ARCHITECTURE.md §8.4 校验, §12.3).
// Reads Test Mic (and TalkTalk Mic for the isolation check), which is microphone access: run it
// through LaunchServices so the TCC grant is the app's:
//   open -W -n -a build/TalkTalk-Dev.app --args --self-test --driver --out <file>
// The channel 1 → TalkTalk Mic path (a sweep into the meeting microphone) runs only on the install
// path (`--bench driver install`, onboarding), never from `--self-test`, and only while §8.4's
// conditions hold right before it starts.

/// `--self-test --driver` (selfTestRunners): never sends anything into TalkTalk Mic.
func driverSelfTest() async -> SelfTestReport { await driverSelfTest(includeMeetingPath: false) }

func driverSelfTest(includeMeetingPath: Bool) async -> SelfTestReport {
    var r = SelfTestReport(suite: "driver")
    let resources = DriverResources.inBundle()
    let bundled = try? resources?.manifest().version
    let installation = DriverInstallation(paths: .standard(), bundledVersion: bundled)
    let (state, _) = installation.check()
    let usable: Bool
    switch state {
    case .loaded, .selfTestFailed, .outdated: usable = true
    default: usable = false
    }
    r.checks.append(SelfTestCheck("driver.install", ok: usable, detail: "\(state)"))
    guard usable else { return r }

    let hal = CoreAudioDriverHAL()
    let restoreRecordExists: @Sendable () -> Bool = { SysInputRecordStore(paths: .standard()).exists }
    let blocker = includeMeetingPath
        ? DriverSelfTest.meetingPathBlocker(hal: hal, restoreRecordExists: restoreRecordExists())
        : "只在安装和引导时跑（会往 TalkTalk Mic 送扫频）"
    // No permission prompt from the CLI: `--self-test` without part flags runs every part, also
    // from a terminal, where a prompt would be the terminal's. Without the grant the IO checks are
    // skipped with the reason, and the run counts as not done (ok: false, driver.json untouched).
    let options = DriverSelfTest.Options(includeMeetingPath: blocker == nil, feedProbe: resources?.feedProbe,
                                         requestPermission: false)
    let report = await DriverSelfTest(hal: hal, expectedVersion: bundled, restoreRecordExists: restoreRecordExists)
        .run(options)
    for c in report.checks {
        r.checks.append(SelfTestCheck("driver.\(c.name.rawValue)", ok: c.passed, detail: c.detail.isEmpty ? nil : c.detail,
                                      values: c.metrics))
    }
    if let blocker { r.checks.append(SelfTestCheck("driver.meetingPath", ok: nil, detail: blocker)) }
    if report.isConclusive {
        try? installation.record(report)
    } else {
        // loopback / replay / gate did not all run: not a pass, and the earlier driver.json result stays
        r.checks.append(SelfTestCheck("driver.selfTest", ok: false, detail: report.incompleteText))
    }
    return r
}
