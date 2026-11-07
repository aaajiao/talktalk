/// The user's LISTEN preference is independent of the installed resource profile. The
/// Apple-recognition profile intentionally has no Qwen ASR role; it is not a failed fallback.
public enum SpeechRecognitionEngine: String, CaseIterable, Sendable, Identifiable {
    case qwen, apple
    public var id: String { rawValue }
    public var title: String { self == .qwen ? "Qwen3-ASR" : "Apple Speech" }
}

public enum EngineRecognitionPolicy {
    public static func listening(preferred: SpeechRecognitionEngine,
                                 installedProfile: EngineProfile?) -> SpeechRecognitionEngine {
        installedProfile?.usesAppleRecognition == true ? .apple : preferred
    }

    /// SPEAK normally tries Qwen final recognition before Apple. In the deliberate Apple
    /// profile it skips that optional primary, keeping the pipeline's Apple-preview pause.
    public static func speaking(installedProfile: EngineProfile?) -> SpeechRecognitionEngine {
        installedProfile?.usesAppleRecognition == true ? .apple : .qwen
    }
}
