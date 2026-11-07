import Foundation

/// Source-content and speaker-echo checks (§5.2). A PTT press may contain Chinese and English,
/// including entirely Latin segments. Qwen's zh language hint is not independent language evidence.
/// `minHanRatio` remains in the profile for compatibility; it no longer rejects SPEAK segments.
public struct SpeakLanguageGate: Sendable {
    public enum Rejection: String, Sendable { case unsupportedText, remoteOverlap, remoteText }
    public let config: PolicyProfile.Speak.Gate
    public let fillers: [String]
    public init(_ profile: PolicyProfile.Speak) { config = profile.gate; fillers = profile.fillers }

    public func isFiller(_ text: String) -> Bool {
        var rest = String(text.filter { $0.isLetter || $0.isNumber })
        guard !rest.isEmpty else { return true }
        let ordered = fillers.sorted { $0.count > $1.count }
        while let filler = ordered.first(where: { !$0.isEmpty && rest.hasPrefix($0) }) {
            rest.removeFirst(filler.count)
        }
        return rest.isEmpty
    }

    public func check(_ text: String, speakerMode: Bool, remoteOverlap: Double?,
                      recentRemoteText: [String]) -> Rejection? {
        guard text.unicodeScalars.contains(where: { TextScript.isHan($0) || TextScript.isLatinLetter($0) })
        else { return .unsupportedText }
        guard speakerMode else { return nil }
        if let remoteOverlap, remoteOverlap >= config.speakerMode.remoteOverlapMax { return .remoteOverlap }
        let tokens = EchoFilter.tokens(text)
        let latin = tokens.filter { $0.unicodeScalars.contains(where: TextScript.isLatinLetter) }
        if !latin.isEmpty, recentRemoteText.contains(where: {
            EchoFilter.overlap(segment: latin, played: EchoFilter.tokens($0)) >= 0.6
        }) { return .remoteText }
        let han = tokens.filter { $0.unicodeScalars.allSatisfy(TextScript.isHan) }
        if !han.isEmpty, recentRemoteText.contains(where: {
            let remote = EchoFilter.tokens($0)
            return EchoFilter.overlap(segment: han, played: remote) >= 0.6
                && EchoFilter.hasTextEvidence(segment: han, played: remote)
        }) { return .remoteText }
        return nil
    }
}
