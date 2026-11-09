import Foundation

/// Display the actual installed combination until a preset has been explicitly requested.
public enum EnginePresetSelection {
    public static func pickerID(activeRoles: [String: String]?, pendingID: String?) -> String {
        if let pendingID { return pendingID }
        guard let activeRoles else { return EngineProfile.standard.rawValue }
        return EngineProfile.matching(activeRoles: activeRoles)?.rawValue ?? EngineProfile.customID
    }
}

/// The synthesis picker changes one installed role. A missing model is a pending download,
/// while an already downloaded model can be activated directly once the engine is idle.
public enum EngineSynthesisSelection {
    public enum Action: Equatable, Sendable {
        case current, activate, downloadAndActivate, unavailable
    }

    public static func models(in pins: [EnginePins.Model] = EnginePins.models) -> [EnginePins.Model] {
        pins.filter { $0.role == "tts" }
    }

    /// Switching uses models already present on this Mac. Keep the active model visible
    /// even if its files need repair, so its current selection and repair action remain clear.
    public static func availableModels(readyModelIDs: Set<String>, activeID: String?,
                                       in pins: [EnginePins.Model] = EnginePins.models) -> [EnginePins.Model] {
        models(in: pins).filter { readyModelIDs.contains($0.key) || $0.key == activeID }
    }

    /// An installed ASR model does not imply a selected synthesis model.
    public static func pickerID(activeRoles: [String: String], pendingID: String?) -> String {
        pendingID ?? activeRoles["tts"] ?? ""
    }

    /// EngineInstallation.check reaches .incomplete only after validating the runtime,
    /// active role metadata and revisions. A missing TTS alone can be repaired by selectTTS;
    /// other missing roles, damaged records and incompatible runtimes need installation repair.
    public static func canSelect(state: EngineInstallation.State, activeRoles: [String: String]) -> Bool {
        if state.canStartEngine { return true }
        guard case let .incomplete(missing, _) = state, let tts = activeRoles["tts"],
              !missing.isEmpty, missing.allSatisfy({ $0 == tts }) else { return false }
        return models().contains { $0.key == tts }
    }

    public static func title(for model: EnginePins.Model) -> String {
        switch model.key {
        case "tts-qwen3-1.7b-base-8bit": "Qwen3-TTS · 1.7B"
        case "tts-qwen3-0.6b-base-8bit": "Qwen3-TTS · 0.6B"
        case "tts-ming3-0.5b-bf16": "Ming-3.0-TTS · 0.5B"
        default: model.repo.split(separator: "/").last.map(String.init) ?? model.key
        }
    }

    /// A node chip fits about 97 pt: its short name. The menu and help keep `title(for:)`.
    public static func compactTitle(for model: EnginePins.Model) -> String {
        switch model.key {
        case "tts-qwen3-1.7b-base-8bit": "Qwen 1.7B"
        case "tts-qwen3-0.6b-base-8bit": "Qwen 0.6B"
        case "tts-ming3-0.5b-bf16": "Ming 0.5B"
        default: title(for: model)
        }
    }

    public static func action(for id: String, activeRoles: [String: String], readyModelIDs: Set<String>,
                              installationReady: Bool, busy: Bool, sessionActive: Bool,
                              pins: [EnginePins.Model] = EnginePins.models) -> Action {
        guard models(in: pins).contains(where: { $0.key == id }) else { return .unavailable }
        if activeRoles["tts"] == id && readyModelIDs.contains(id) { return .current }
        guard installationReady, !busy, !sessionActive else { return .unavailable }
        return readyModelIDs.contains(id) ? .activate : .downloadAndActivate
    }
}
