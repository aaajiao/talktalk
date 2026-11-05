import Foundation
import Testing
@testable import TalkTalkCore

@Suite struct ScopedTempNameTests {
    @Test func devAndReleaseDoNotOwnEachOthersFiles() {
        let release = ScopedTempName(tag: "talktalk-onboarding", bundleID: "com.aaajiao.talktalk")
        let dev = ScopedTempName(tag: "talktalk-onboarding", bundleID: "com.aaajiao.talktalk.dev")
        let r = release.make("A"), d = dev.make("B")
        #expect(r == "talktalk-onboarding+com.aaajiao.talktalk+A")
        #expect(release.owns(r) && !release.owns(d))
        #expect(dev.owns(d) && !dev.owns(r))
        // The earlier unscoped names (and bare prefixes) belong to no one.
        #expect(!release.owns("talktalk-onboarding-1234") && !release.owns(release.prefix))
        #expect(ScopedTempName(tag: "t", bundleID: nil).prefix == "t+unknown+")
    }
}
