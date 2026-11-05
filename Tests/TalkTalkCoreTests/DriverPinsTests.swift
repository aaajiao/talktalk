import Testing
@testable import TalkTalkCore

/// DriverPins is generated from scripts/lib/versions.sh (gen-pins.sh); these check that the values
/// stay consistent with each other and with MicPolicy's own-device rule.
@Suite struct DriverPinsTests {
    @Test func everyDeviceUIDIsOwn() {
        for uid in [DriverPins.feedUID, DriverPins.micUID, DriverPins.testMicUID, DriverPins.tapUIDPrefix + "42"] {
            #expect(uid.hasPrefix(DriverPins.ownUIDPrefix + "."), "\(uid)")
            #expect(MicPolicy.isOwnUID(uid), "\(uid)")
        }
        #expect(MicPolicy.isOwnUID(DriverPins.ownUIDPrefix))
        #expect(!MicPolicy.isOwnUID(DriverPins.ownUIDPrefix + "foo"))
    }

    @Test func distinctUIDs() {
        let uids = [DriverPins.feedUID, DriverPins.micUID, DriverPins.testMicUID, DriverPins.bundleID]
        #expect(Set(uids).count == uids.count)
        #expect(MicPolicy.talkTalkMicUID == DriverPins.micUID)
    }

    @Test func bundleShape() {
        #expect(DriverPins.bundleName.hasSuffix(".driver"))
        #expect(DriverPins.bundleID.hasPrefix(DriverPins.ownUIDPrefix + "."))
        #expect(DriverPins.tapUIDPrefix.hasSuffix("."))
        #expect(DriverPins.libASPLCommit.count == 40)
    }
}
