// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation
import TalkTalkCore

/// The audition row of the §9.2 step 4 table ("试听合理性"): the en, de and fr sentences must not run
/// away, must not be too short, and must read back with WER ≤ 15 %. A failing sentence is generated
/// once more with the next seed; if it still fails the user is told to re-record. Pure rules; the
/// engine calls are in `EngineVoiceServices`.
public enum AuditionCheck {
    /// §9.2 step 7.
    public static let sentences: [Lang: String] = [
        .en: "Thanks, everyone. Let me quickly walk you through where the project stands today.",
        .de: "Danke Ihnen allen. Ich gebe Ihnen kurz einen Überblick über den aktuellen Stand des Projekts.",
        .fr: "Merci à tous. Je vais vous présenter rapidement l’état actuel du projet.",
    ]
    public static let languages: [Lang] = [.en, .de, .fr]
    public static func title(for lang: Lang) -> String {
        switch lang {
        case .zh: String(appLocalized: "试听中文")
        case .en: String(appLocalized: "试听英语")
        case .de: String(appLocalized: "试听德语")
        case .fr: String(appLocalized: "试听法语")
        }
    }
    public static let maxWER = 0.15
    /// Independent of the engine's own flags: longer than `runawayFactor × expected + runawaySlack`
    /// is a runaway (the engine's cap is 3 × expected + 2 s, §5.5), shorter than
    /// `shortFactor × expected` is short.
    public static let runawayFactor = 3.0
    public static let runawaySlack = 2.0
    public static let shortFactor = 0.4
    /// One regeneration (§9.2: "自动重生成一次").
    public static let maxAttempts = 2

    public enum Failure: String, Codable, Sendable, Equatable {
        case runaway, short, wer, empty

        public var text: String {
            switch self {
            case .runaway: String(appLocalized: "合成跑飞（比预期长很多）")
            case .short: String(appLocalized: "合成偏短")
            case .wer: String(appLocalized: "回读和原句差得太多")
            case .empty: String(appLocalized: "没有合成出声音")
            }
        }
    }

    /// One synthesis as the check sees it.
    public struct Take: Sendable, Equatable {
        public var audioSeconds: Double
        public var expectedSeconds: Double?
        public var engineRunaway: Bool
        public var engineShort: Bool
        public var readback: String?

        public init(audioSeconds: Double, expectedSeconds: Double?, engineRunaway: Bool = false,
                    engineShort: Bool = false, readback: String?) {
            self.audioSeconds = audioSeconds
            self.expectedSeconds = expectedSeconds
            self.engineRunaway = engineRunaway
            self.engineShort = engineShort
            self.readback = readback
        }
    }

    /// nil = passes. Order: empty, runaway, short, read-back. `readback == nil` means WER was not
    /// measured (no ASR role): it never rejects; only a measured WER above 15 % does.
    public static func evaluate(_ t: Take, text: String) -> (failure: Failure?, wer: Double?) {
        if t.audioSeconds <= 0 { return (.empty, nil) }
        if t.engineRunaway { return (.runaway, nil) }
        if let e = t.expectedSeconds, e > 0 {
            if t.audioSeconds > runawayFactor * e + runawaySlack { return (.runaway, nil) }
            if t.audioSeconds < shortFactor * e { return (.short, nil) }
        }
        if t.engineShort { return (.short, nil) }
        guard let rb = t.readback else { return (nil, nil) }
        let w = WordErrorRate.compute(hypothesis: rb, reference: text)
        return (w > maxWER ? .wer : nil, w)
    }
}

/// Word error rate for Latin-language read-back (edits / reference words). Lowercased,
/// punctuation dropped, accented letters kept; straight and curly apostrophes agree. Pure.
public enum WordErrorRate {
    public static func words(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for scalar in s.replacingOccurrences(of: "’", with: "'").precomposedStringWithCanonicalMapping.unicodeScalars {
            let p = scalar.properties
            if p.isAlphabetic || p.numericType != nil || scalar == "'" {
                cur.unicodeScalars.append(scalar)
            } else if !cur.isEmpty {
                out.append(cur.lowercased())
                cur = ""
            }
        }
        if !cur.isEmpty { out.append(cur.lowercased()) }
        return out.map { $0.replacingOccurrences(of: "'", with: "") }.filter { !$0.isEmpty }
    }

    public static func compute(hypothesis: String, reference: String) -> Double {
        let r = words(reference), h = words(hypothesis)
        if r.isEmpty { return h.isEmpty ? 0 : 1 }
        var prev = Array(0...h.count)
        for i in 1...r.count {
            var cur = [i] + Array(repeating: 0, count: h.count)
            for j in stride(from: 1, through: h.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return Double(prev[h.count]) / Double(r.count)
    }
}
