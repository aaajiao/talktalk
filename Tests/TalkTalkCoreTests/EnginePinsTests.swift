import Testing
@testable import TalkTalkCore

@Suite struct EnginePinsTests {
    @Test func everyModelIsPinnedToAFullCommit() {
        for m in EnginePins.models {
            #expect(m.revision.count == 40, "\(m.key)")
            #expect(m.revision.allSatisfy { $0.isHexDigit }, "\(m.key)")
            #expect(["Apache-2.0", "MIT"].contains(m.license), "\(m.key)")
            #expect(!m.repo.hasPrefix("tencent/HY-MT"), "\(m.key)")
            #expect(m.bytes > 0 && m.fileCount > 0, "\(m.key)")
        }
    }

    @Test func profilesOnlyReferenceKnownModels() {
        let keys = Set(EnginePins.models.map(\.key))
        for (name, list) in EnginePins.profiles {
            #expect(!list.isEmpty, "\(name)")
            for k in list { #expect(keys.contains(k), "\(name): \(k)") }
        }
        // No MT in any profile (§16 decision 12).
        #expect(EnginePins.models.allSatisfy { $0.role == "tts" || $0.role == "asr" })
    }

    @Test func lockIsCompatibleWithItself() {
        #expect(EnginePins.lockCompat.contains(EnginePins.lockSHA256))
        #expect(EnginePins.engineAPI == 2)
    }

    @Test func directoryNameUsesRev12() {
        let m = EnginePins.models[0]
        #expect(m.directoryName.hasSuffix("@" + m.revision.prefix(12)))
    }
}
