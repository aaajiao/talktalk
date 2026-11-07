import Foundation
import Testing
@testable import TalkTalkCore

@Suite struct AppVersionTests {
    @Test func bundleMetadataWinsOverCompiledFallback() throws {
        try withBundle(["CFBundleDisplayName": "TalkTalk Preview", "CFBundleShortVersionString": "3.2.1",
                        "CFBundleVersion": "42"]) { bundle in
            let version = AppVersion(bundle: bundle)
            #expect(version.name == "TalkTalk Preview")
            #expect(version.displayString == "3.2.1 (42)")
        }
    }

    @Test func missingBundleMetadataStillIdentifiesTheCompiledBuild() throws {
        try withBundle([:]) { bundle in
            let version = AppVersion(bundle: bundle)
            #expect(version.version == EnginePins.appVersion)
            #expect(version.build == EnginePins.appBuild)
            #expect(version.displayString == "\(EnginePins.appVersion) (\(EnginePins.appBuild))")
        }
    }

    private func withBundle(_ metadata: [String: String], check: (Bundle) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var info = metadata
        info["CFBundleIdentifier"] = "com.aaajiao.talktalk.version-test.\(UUID().uuidString)"
        info["CFBundlePackageType"] = "BNDL"
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: root))
        try check(bundle)
    }
}
