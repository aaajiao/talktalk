import Foundation
import Testing
@testable import TalkTalkDriverSupport

/// On-device checks against the INSTALLED driver (§13 DriverTests): only with TALKTALK_TEST_DRIVER=1.
/// They read HAL properties and the driver's diagnostics, write nothing and start no IO, so they
/// need no TCC grant. The loopback / gate / anti-replay checks read Test Mic (microphone access):
/// run those through the app so the grant is the app's:
///   open -W -n -a build/TalkTalk-Dev.app --args --self-test --driver --out <file>
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TALKTALK_TEST_DRIVER"] == "1"))
struct DeviceDriverTests {
    @Test func installedDriverHasTheDesignedDevices() throws {
        let hal = CoreAudioDriverHAL()
        let feed = try #require(hal.device(uid: DriverIdentity.feedUID), "TalkTalk Feed not found: driver not installed?")
        #expect(DriverInstallation.deviceProblems(feed: feed, testMic: hal.device(uid: DriverIdentity.testMicUID)) == [])
        #expect(!feed.inDeviceList)
        #expect(!feed.canBeDefault)
        // this test process is a HAL client, so TalkTalk Mic is listed (§8.3: every CoreAudio process
        // is an AddDeviceClient on every device), but only for allowed bundle ids: xctest is not one
        let diag = try #require(hal.diagnostics())
        #expect(diag.version?.isEmpty == false)
        #expect(hal.loadedVersion() == diag.version)
        #expect(diag.feedAddClientDenied > 0)
    }

    @Test func installationStateIsLoadedOrSelfTestFailed() {
        let state = DriverInstallation(paths: .standard(), bundledVersion: nil).check().state
        switch state {
        case .loaded, .selfTestFailed: break
        default: Issue.record("state \(state)")
        }
    }
}
