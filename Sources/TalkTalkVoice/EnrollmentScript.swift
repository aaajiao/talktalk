import CryptoKit
import Foundation

/// The fixed enrollment script and audition sentences (ARCHITECTURE.md, "引擎、翻译与播放").
/// `ref_text` must match the audio word for word. Each revised script gets its own id;
/// saved profiles keep their original script and conditioning until the user replaces them.
public struct EnrollmentScript: Sendable, Equatable {
    public let id: String
    public let text: String

    public static let zhV1 = EnrollmentScript(
        id: "zh-v1",
        text: "大家好，今天我先简单介绍一下项目的最新进展，然后说说下一步的计划。如果有问题，欢迎随时打断我。")

    public static let zhV2 = EnrollmentScript(
        id: "zh-v2",
        text: "大家好，今天我们一起看看项目的最新进展。先确认已经完成的工作，再讨论接下来的安排。如果你有不同的想法，或者需要补充的细节，请随时告诉我，我们一起把事情说清楚。")

    public static let current = zhV2

    /// Han characters only, for estimating the speaking rate of this script.
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
