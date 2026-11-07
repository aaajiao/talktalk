import Foundation
import Testing
import TalkTalkAudio
import TalkTalkCore
import TalkTalkTestSupport

/// On-device acceptance (§13 SysInputTests, §14 M2). These write the REAL system default input,
/// so they only run with TALKTALK_TEST_AUDIO=1 and each run needs the user's OK. They record the
/// default input and output first and put the input back at the end; the default output is never
/// written and must not change. TalkTalk Mic exists only while a talktalk process is attached
/// (M0-T8), so start TalkTalk-Dev.app first. The guard here is a fake: the real-guard kill -9 /
/// SIGTERM / two-build / coreaudiod-restart cases are scheduled with the user (§14 M2).
///
/// Driver ≥ 0.2.0 only lets an accepted Feed client (TalkTalk.app / TalkTalk-Dev.app by bundle id)
/// write 'ttmm', and the test runner is not one: entry would end in `.micNotSelectable`. So this
/// suite runs only on a driver without 'ttmm'; on 0.2.0 the same acceptance runs through the app
/// (a dev `--bench` entry started with `open -W -n -a build/TalkTalk-Dev.app`, scheduled with M2).
@MainActor @Suite(.serialized, .temporaryFiles, .enabled(if: DeviceGate.enabled,
                                        "needs TALKTALK_TEST_AUDIO=1 and a driver without 'ttmm' (0.1.0)"))
struct DeviceSysInputTests {

    @Test func switchAndRestoreOnRealHAL() throws {
        let hal = CoreAudioSysInputHAL()
        let before = hal.snapshot()
        let outputBefore = AudioDeviceCatalog.defaultOutput()?.uid
        let inputBefore = try #require(before.defaultInput, "no default input")
        try #require(before.micPresent, "TalkTalk Mic is not in the device list: start TalkTalk-Dev.app first")
        defer {
            // Whatever happened, put the original back.
            if hal.defaultInputUID() != inputBefore.uid { _ = hal.writeAndConfirm(uid: inputBefore.uid) }
        }
        let paths = try tempPaths()
        let sw = SystemInputSwitcher(.init(hal: hal, processes: FakeProcesses([]), paths: paths,
                                           launcher: FakeLauncher(), autoRefresh: false))
        sw.start()
        #expect(sw.enterMeetingMode(meetingApps: []) == .switched)
        #expect(hal.defaultInputUID() == MicPolicy.talkTalkMicUID)
        #expect(AudioDeviceCatalog.defaultOutput()?.uid == outputBefore)
        sw.refresh()
        let expected = SystemInputPlan.restoreTarget(original: .init(inputBefore), devices: before.devices)?.device.uid
        #expect(sw.endMeetingMode(decision: .whenCallEnds) != .deferred)
        #expect(hal.defaultInputUID() == expected)
        #expect(AudioDeviceCatalog.defaultOutput()?.uid == outputBefore)
        #expect(!SysInputRecordStore(paths: paths).exists)
    }
}

private enum DeviceGate {
    /// Short-circuits: without TALKTALK_TEST_AUDIO=1 nothing touches Core Audio.
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["TALKTALK_TEST_AUDIO"] == "1"
            && CoreAudioMeetingModeSwitch().meetingMode() == nil
    }
}
