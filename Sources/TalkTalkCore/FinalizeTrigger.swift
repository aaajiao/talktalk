import Foundation

/// LISTEN finalize trigger (§5.1, `listen.finalize`). Pure: fed once per audio tick with the
/// current hypothesis and the audio silence so far; returns the first rule that fires.
///
/// Rules, checked in this order (any one fires):
///   asrFinal    the recognizer delivered a final for this sentence;
///   punctPause  the stable prefix ends with sentence punctuation and no new word for punctPauseMs;
///   force       ≥ force.minWords words and no new word for force.pauseMs (pauseMsAfter8s after 8 s);
///   silence     audio silence ≥ silenceMs[lang];
///   stall       no new word for stallMs (stallMsAfter8s after 8 s);
///   hardCap     the sentence has run hardCapS.
/// "Pause" is time since the word count last changed; the sentence starts at its first word.
public struct FinalizeTrigger: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case asrFinal, punctPause, force, silence, stall, hardCap
    }

    public let config: PolicyProfile.Listen.Finalize
    public let silenceThresholdMs: Int
    public private(set) var startMs: Int?
    public private(set) var lastWordChangeMs: Int?
    public private(set) var words = 0

    static let longAfterMs = 8000

    public init(config: PolicyProfile.Listen.Finalize, lang: Lang) {
        self.config = config
        self.silenceThresholdMs = config.silenceMs(for: lang) ?? 800
    }

    /// Next sentence.
    public mutating func reset() { startMs = nil; lastWordChangeMs = nil; words = 0 }

    public mutating func observe(nowMs: Int, words n: Int, stableEndsWithSentencePunct: Bool,
                                 silenceMs: Int, asrFinal: Bool) -> Kind? {
        if n != words {
            if startMs == nil, n > 0 { startMs = nowMs }
            lastWordChangeMs = nowMs
            words = n
        }
        guard words > 0, let start = startMs, let last = lastWordChangeMs else { return nil }
        if asrFinal { return .asrFinal }
        let long = nowMs - start >= Self.longAfterMs
        let pause = nowMs - last
        if stableEndsWithSentencePunct, pause >= config.punctPauseMs { return .punctPause }
        if words >= config.force.minWords, pause >= (long ? config.force.pauseMsAfter8s : config.force.pauseMs) { return .force }
        if silenceMs >= silenceThresholdMs { return .silence }
        if pause >= (long ? config.stallMsAfter8s : config.stallMs) { return .stall }
        if nowMs - start >= config.hardCapS * 1000 { return .hardCap }
        return nil
    }

    /// Sentence punctuation that ends a stable prefix (en/de; also the CJK forms).
    public static func endsWithSentencePunct(_ s: String) -> Bool {
        guard let c = s.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return ".?!…。？！".contains(c)
    }

    /// The stable prefix: the word-level longest common prefix of the last two hypotheses.
    public static func stablePrefix(_ a: String, _ b: String) -> String {
        let x = a.split(whereSeparator: \.isWhitespace), y = b.split(whereSeparator: \.isWhitespace)
        var n = 0
        while n < x.count, n < y.count, x[n] == y[n] { n += 1 }
        return x.prefix(n).joined(separator: " ")
    }

    /// Source progress units. Chinese has no separating spaces, so every Han character/digit
    /// advances the clock; embedded Latin names count as runs. en/de keep whitespace words.
    public static func wordCount(_ s: String, lang: Lang = .en) -> Int {
        guard lang == .zh else { return s.split(whereSeparator: \.isWhitespace).count }
        var count = 0, inWord = false
        for scalar in s.unicodeScalars {
            if TextScript.isHan(scalar) || scalar.properties.numericType != nil {
                count += 1; inWord = false
            } else if scalar.properties.isAlphabetic {
                if !inWord { count += 1 }; inWord = true
            } else if scalar != "'" && scalar != "-" && scalar != "’" { inWord = false }
        }
        return count
    }
}
