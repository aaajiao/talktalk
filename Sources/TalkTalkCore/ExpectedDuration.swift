import Foundation

/// The one expected-duration estimate of a target-language clause (§5.5). Used for:
/// whole-clause rendering (< `wholeClauseBelowExpectedS`), the backlog Q's unrendered part, the
/// extendToDrain deadline and the runaway/short checks. The engine's `expected_seconds`
/// (engine/talktalk_engine/tts.py) uses the same data file and the same word count.
///
/// Coefficients are not written here: they come from engine/talktalk_engine/expected_duration.json
/// (M0-T1 lite fit, docs/decisions/m0-results.md) through scripts/gen-expected-duration.sh →
/// Generated/ExpectedDurationTable.swift; check.sh keeps the two in sync and
/// ExpectedDurationTests compares against the JSON itself. Digits are not counted separately
/// because TextNormalizer spells numbers out before TTS (the fit was made on spelled-out text).
public enum ExpectedDuration {
    public struct Coefficients: Sendable, Equatable {
        public var baseS: Double
        public var perWordS: Double
    }

    /// Languages missing from the file use its `default` (as tts.py does). zh never reaches the
    /// clone voice (TargetTextGate), so it normally takes that fallback.
    public static func coefficients(_ lang: Lang) -> Coefficients {
        let t = ExpectedDurationTable.languages[lang.rawValue]
            ?? ExpectedDurationTable.languages[ExpectedDurationTable.defaultLanguage]!
        return Coefficients(baseS: t.interceptS, perWordS: t.perWordS)
    }

    /// Python's `max(1, len(text.split()))`: runs of whitespace separate words.
    public static func words(_ text: String) -> Int {
        max(1, text.split(whereSeparator: { $0.isWhitespace }).count)
    }

    public static func seconds(_ text: String, _ lang: Lang) -> Double {
        let c = coefficients(lang)
        return c.baseS + c.perWordS * Double(words(text))
    }

    /// Runaway cut threshold, initial value `factor × expected + extraS` (§5.5; PolicyProfile
    /// speak.tts.runaway). The engine applies it; the app uses it for HUD and tests.
    public static func runawayLimitS(_ text: String, _ lang: Lang, factor: Double, extraS: Double) -> Double {
        factor * seconds(text, lang) + extraS
    }
}
