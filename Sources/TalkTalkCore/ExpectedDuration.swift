import Foundation

/// The one expected-duration estimate of a target-language clause (§5.5). Used for:
/// whole-clause rendering (< `wholeClauseBelowExpectedS`), the backlog Q's unrendered part, the
/// extendToDrain deadline and the runaway/short checks. The engine's `expected_seconds`
/// (engine/talktalk_engine/tts.py) uses the same data file and text-unit count.
///
/// Coefficients are not written here: they come from engine/talktalk_engine/expected_duration.json
/// (M0-T1 lite fit, docs/decisions/m0-results.md) through scripts/gen-expected-duration.sh →
/// Generated/ExpectedDurationTable.swift; check.sh keeps the two in sync and
/// ExpectedDurationTests compares against the JSON itself. English/German numbers are spelled
/// out before TTS. Chinese uses character units and an initial rate; French starts with the
/// German coefficients. Neither is a measured voice fit for that language.
public enum ExpectedDuration {
    public struct Coefficients: Sendable, Equatable {
        public var baseS: Double
        public var perWordS: Double
    }

    /// Languages missing from the file use its `default` (as tts.py does).
    public static func coefficients(_ lang: Lang) -> Coefficients {
        let t = ExpectedDurationTable.languages[lang.rawValue]
            ?? ExpectedDurationTable.languages[ExpectedDurationTable.defaultLanguage]!
        return Coefficients(baseS: t.interceptS, perWordS: t.perWordS)
    }

    /// Python's `max(1, len(text.split()))`: runs of whitespace separate words.
    public static func words(_ text: String) -> Int {
        max(1, text.split(whereSeparator: { $0.isWhitespace }).count)
    }

    /// Chinese has no whitespace between words. Count each Han character and digit plus
    /// other letter runs so long Chinese clauses neither merge as one word nor get cut short.
    /// Keep this in sync with tts.py's duration_units.
    public static func units(_ text: String, _ lang: Lang) -> Int {
        guard lang == .zh else { return words(text) }
        var count = 0, inWord = false
        for scalar in text.unicodeScalars {
            if TextScript.isHan(scalar) || (0x30...0x39).contains(scalar.value) {
                count += 1; inWord = false
            } else if scalar.properties.isAlphabetic {
                if !inWord { count += 1 }; inWord = true
            } else if scalar != "'" && scalar != "-" && scalar != "’" {
                inWord = false
            }
        }
        return max(1, count)
    }

    public static func seconds(_ text: String, _ lang: Lang) -> Double {
        let c = coefficients(lang)
        return c.baseS + c.perWordS * Double(units(text, lang))
    }

    /// Runaway cut threshold, initial value `factor × expected + extraS` (§5.5; PolicyProfile
    /// speak.tts.runaway). The engine applies it; the app uses it for HUD and tests.
    public static func runawayLimitS(_ text: String, _ lang: Lang, factor: Double, extraS: Double) -> Double {
        factor * seconds(text, lang) + extraS
    }
}
