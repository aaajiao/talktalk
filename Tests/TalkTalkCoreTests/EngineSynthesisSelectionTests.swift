import Testing
@testable import TalkTalkCore

struct EngineSynthesisSelectionTests {
    private let qwen = "tts-qwen3-1.7b-base-8bit"
    private let smallQwen = "tts-qwen3-0.6b-base-8bit"
    private let ming = "tts-ming3-0.5b-bf16"
    private let asr = "asr-qwen3-0.6b-8bit"

    @Test func pickerOffersOnlyLocallyAvailableSynthesisModels() {
        let choices = EngineSynthesisSelection.availableModels(readyModelIDs: [qwen, ming, asr], activeID: qwen)
        #expect(choices.map(\.key) == [qwen, ming])
        #expect(choices.map { EngineSynthesisSelection.title(for: $0) } == [
            "Qwen3-TTS · 1.7B", "Ming-3.0-TTS · 0.5B"
        ])
        #expect(EngineSynthesisSelection.availableModels(readyModelIDs: [], activeID: nil).isEmpty)
    }

    @Test func activeRoleWinsOverOtherDownloadedModels() {
        #expect(action(qwen, ready: [qwen, ming]) == .current)
        #expect(action(ming, ready: [qwen, ming]) == .activate)
        #expect(action(ming, ready: [qwen]) == .downloadAndActivate)
        #expect(action(smallQwen, ready: [qwen]) == .downloadAndActivate)
    }

    @Test func choiceWaitsForSessionsMaintenanceAndInstalledRuntime() {
        #expect(action(ming, ready: [ming], busy: true) == .unavailable)
        #expect(action(ming, ready: [ming], session: true) == .unavailable)
        #expect(action(ming, ready: [], session: true) == .unavailable)
        #expect(action(ming, ready: [ming], installed: false) == .unavailable)
    }

    @Test func recognitionModelsAndUnknownIDsCannotBeSelectedForSynthesis() {
        #expect(action(asr, ready: [asr]) == .unavailable)
        #expect(action("unknown-tts", ready: ["unknown-tts"]) == .unavailable)
    }

    @Test func absentSynthesisRoleKeepsPickerEmptyAndFirstModelSelectable() {
        let roles = ["asr": asr]
        #expect(EngineSynthesisSelection.pickerID(activeRoles: roles, pendingID: nil) == "")
        #expect(EngineSynthesisSelection.pickerID(activeRoles: roles, pendingID: qwen) == qwen)
        #expect(EngineSynthesisSelection.action(for: qwen, activeRoles: roles, readyModelIDs: [qwen],
                                                 installationReady: true, busy: false, sessionActive: false) == .activate)
        #expect(EngineSynthesisSelection.action(for: "", activeRoles: roles, readyModelIDs: [qwen],
                                                 installationReady: true, busy: false, sessionActive: false) == .unavailable)
        #expect(EngineSynthesisSelection.pickerID(activeRoles: ["tts": ming, "asr": asr], pendingID: nil) == ming)
    }

    @Test func customInstallHasNoImplicitPendingStandardPreset() {
        let roles = ["tts": ming, "asr": asr]
        #expect(EnginePresetSelection.pickerID(activeRoles: roles, pendingID: nil) == EngineProfile.customID)
        #expect(EnginePresetSelection.pickerID(activeRoles: roles, pendingID: "standard") == "standard")
        #expect(EnginePresetSelection.pickerID(activeRoles: roles, pendingID: "max") == "max")
        #expect(EnginePresetSelection.pickerID(activeRoles: ["tts": qwen, "asr": asr], pendingID: nil) == "standard")
        #expect(EnginePresetSelection.pickerID(activeRoles: nil, pendingID: nil) == "standard")
    }

    @Test func missingActiveSynthesisCanBeRepairedWithoutChangingOtherRoles() {
        let roles = ["tts": ming, "asr": asr]
        #expect(EngineSynthesisSelection.availableModels(readyModelIDs: [qwen, asr], activeID: ming).map(\.key) == [qwen, ming])
        let repairable = EngineSynthesisSelection.canSelect(state: .incomplete(missing: [ming], bytes: 1024),
                                                             activeRoles: roles)
        #expect(repairable)
        #expect(EngineSynthesisSelection.action(for: ming, activeRoles: roles, readyModelIDs: [asr],
                                                 installationReady: repairable, busy: false, sessionActive: false) == .downloadAndActivate)
        #expect(EngineSynthesisSelection.action(for: qwen, activeRoles: roles, readyModelIDs: [asr, qwen],
                                                 installationReady: repairable, busy: false, sessionActive: false) == .activate)
    }

    @Test func synthesisRepairCannotBypassOtherMissingRolesOrRuntimeFailures() {
        let roles = ["tts": ming, "asr": asr]
        let states: [EngineInstallation.State] = [
            .incomplete(missing: [asr], bytes: 1024),
            .incomplete(missing: [ming, asr], bytes: 2048),
            .damaged(reason: "venv/bin/python3 is not executable"),
            .incompatible(reason: "runtime lock mismatch"), .unfinished, .notInstalled
        ]
        for state in states {
            #expect(!EngineSynthesisSelection.canSelect(state: state, activeRoles: roles))
        }
    }

    @Test func choiceIsIndependentOfRecognitionSizeOrAbsence() {
        for roles in [["tts": qwen, "asr": asr],
                      ["tts": qwen, "asr": "asr-qwen3-1.7b-8bit"],
                      ["tts": smallQwen]] {
            #expect(EngineSynthesisSelection.action(for: ming, activeRoles: roles,
                                                     readyModelIDs: [ming], installationReady: true,
                                                     busy: false, sessionActive: false) == .activate)
        }
    }

    private func action(_ id: String, ready: Set<String>, busy: Bool = false,
                        session: Bool = false, installed: Bool = true) -> EngineSynthesisSelection.Action {
        EngineSynthesisSelection.action(for: id, activeRoles: ["tts": qwen, "asr": asr],
                                         readyModelIDs: ready, installationReady: installed,
                                         busy: busy, sessionActive: session)
    }
}
