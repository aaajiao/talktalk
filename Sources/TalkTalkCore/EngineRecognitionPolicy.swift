/// LISTEN and SPEAK keep independent recognition preferences. Selecting Apple changes no
/// installed resources; the legacy synthesis-only profile remains compatible without Qwen ASR.
public enum SpeechRecognitionEngine: String, CaseIterable, Sendable, Identifiable {
    case qwen, apple
    public var id: String { rawValue }
    public var title: String { self == .qwen ? "Qwen3-ASR" : "Apple Speech" }
}

public enum EngineRecognitionPolicy {
    /// Recognition compatibility only, not the resource preset displayed in settings.
    /// Selecting another TTS in a synthesis-only installation must retain its Apple path.
    public static func compatibilityProfile(activeRoles: [String: String]) -> EngineProfile? {
        if activeRoles["tts"] != nil && activeRoles["asr"] == nil { return .compact16 }
        return EngineProfile.matching(activeRoles: activeRoles)
    }

    public static func listening(preferred: SpeechRecognitionEngine,
                                 installedProfile: EngineProfile?) -> SpeechRecognitionEngine {
        installedProfile?.usesAppleRecognition == true ? .apple : preferred
    }

    /// Apple skips SPEAK's optional Qwen primary, keeping the pipeline's Apple-preview pause.
    public static func speaking(preferred: SpeechRecognitionEngine,
                                installedProfile: EngineProfile?) -> SpeechRecognitionEngine {
        installedProfile?.usesAppleRecognition == true ? .apple : preferred
    }
}
