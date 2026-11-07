import Testing
@testable import TalkTalkCore

@Suite struct EngineProfileTests {
    @Test func resourcePickerOffersOnlyLocalPairsWhileLegacyRemainsReadable() {
        #expect(EngineProfile.selectablePresets == [.max, .standard, .compact24])
        #expect(EngineProfile.selectablePresets.allSatisfy { Set($0.expectedRoles.keys) == ["tts", "asr"] })
        #expect(EngineProfile(rawValue: "compact16") == .compact16)
        #expect(EngineProfile.matching(activeRoles: EngineProfile.compact16.expectedRoles) == .compact16)
    }

    @Test func fourDistinctPresetsDescribeTheirActualModels() {
        #expect(EngineProfile.allCases.map(\.rawValue) == ["max", "standard", "compact24", "compact16"])
        #expect(EngineProfile.max.expectedRoles == ["tts": "tts-qwen3-1.7b-base-8bit", "asr": "asr-qwen3-1.7b-8bit"])
        #expect(EngineProfile.standard.expectedRoles == ["tts": "tts-qwen3-1.7b-base-8bit", "asr": "asr-qwen3-0.6b-8bit"])
        #expect(EngineProfile.compact24.expectedRoles == ["tts": "tts-qwen3-0.6b-base-8bit", "asr": "asr-qwen3-0.6b-8bit"])
        #expect(EngineProfile.compact16.expectedRoles == ["tts": "tts-qwen3-0.6b-base-8bit"])
        #expect(EngineProfile.allCases.map(\.modelBytes) == [5_572_014_780, 4_114_929_511, 3_002_069_861, 1_991_297_619])
        for profile in EngineProfile.allCases {
            #expect(EngineProfile.matching(activeRoles: profile.expectedRoles) == profile)
            #expect(profile.usesAppleRecognition == (profile == .compact16))
        }
    }

    @Test func oldMaxRecordWithDownloadedLargerASRStillMatchesStandard() {
        let standard = EngineProfile.standard
        let record = EngineInstallation.Record(version: 1, profile: "max", engineAPI: EnginePins.engineAPI,
            runtime: "python-mlx", flavour: "main", lockSHA256: EnginePins.lockSHA256,
            roles: standard.expectedRoles.mapValues { id in
                .init(id: id, rev: EnginePins.models.first { $0.key == id }!.revision)
            }, models: EnginePins.models.map {
                .init(id: $0.key, repo: $0.repo, rev: $0.revision, role: $0.role, dir: $0.directoryName)
            }, mlxAudioCommit: nil, installedAt: nil)
        #expect(EngineProfile.matching(record: record) == .standard)
        #expect(record.profile == "max")
    }

    @Test func unmatchedRolesAreCustomRatherThanAppleRecognition() {
        #expect(EngineProfile.matching(activeRoles: ["tts": "tts-qwen3-1.7b-base-8bit"]) == nil)
        #expect(EngineProfile.matching(activeRoles: [:]) == nil)
        #expect(EngineProfile.matching(activeRoles: ["tts": "tts-qwen3-0.6b-base-8bit", "asr": "asr-qwen3-1.7b-8bit"]) == nil)
        #expect(EngineProfile(rawValue: EngineProfile.customID) == nil)
    }
}
