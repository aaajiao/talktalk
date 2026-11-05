import CryptoKit
import Foundation

/// The fixed enrollment script and audition sentences (ARCHITECTURE.md §9.1, §9.2 step 7).
/// `ref_text` must match the audio word for word, so the script is never trimmed or edited;
/// a new script gets a new `id` and invalidates every saved profile's `script_id`.
public struct EnrollmentScript: Sendable, Equatable {
    public let id: String
    public let text: String

    public static let zhV1 = EnrollmentScript(
        id: "zh-v1",
        text: "大家好，今天我先简单介绍一下项目的最新进展，然后说说下一步的计划。如果有问题，欢迎随时打断我。")

    /// Han characters only (the script's character count for speaking rate, §9.1: 42).
    public var hanCount: Int { TranscriptComparison.normalize(text).count }

    /// Clauses split at punctuation; the CER check rejects a take that drops any one of them.
    public var clauses: [String] {
        TranscriptComparison.clauses(of: text)
    }

    public var sha256: String { sha256Hex(Data(text.utf8)) }
}

public enum AuditionSentences {
    public static let en = "Thanks, everyone. Let me quickly walk you through where the project stands today."
    public static let de = "Danke Ihnen allen. Ich gebe Ihnen kurz einen Überblick über den aktuellen Stand des Projekts."
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
