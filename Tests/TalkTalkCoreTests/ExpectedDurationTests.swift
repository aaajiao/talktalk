import Foundation
import Testing
@testable import TalkTalkCore

@Suite struct ExpectedDurationTests {
    /// engine/talktalk_engine/expected_duration.json, the file tts.py's expected_seconds reads.
    static let jsonURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("engine/talktalk_engine/expected_duration.json")

    struct File: Decodable {
        struct C: Decodable { var intercept_s: Double; var per_word_s: Double }
        var version: Int
        var `default`: String
        var languages: [String: C]
    }

    /// Parity with the engine: same coefficients per language, same fallback for unlisted ones.
    @Test func matchesEngineDataFile() throws {
        let f = try JSONDecoder().decode(File.self, from: Data(contentsOf: Self.jsonURL))
        #expect(f.version == 1)
        for lang in Lang.allCases {
            let c = f.languages[lang.rawValue] ?? f.languages[f.default]!
            let words = ["eins", "one two three", "a b c d e f g h i j"]
            for text in words {
                let py = c.intercept_s + c.per_word_s * Double(max(1, text.split(separator: " ").count))
                #expect(abs(ExpectedDuration.seconds(text, lang) - py) < 1e-12, "\(lang) \(text)")
            }
        }
    }

    @Test func wordCountMatchesPythonSplit() {
        #expect(ExpectedDuration.words("") == 1)                       // max(1, 0)
        #expect(ExpectedDuration.words("   ") == 1)
        #expect(ExpectedDuration.words(" a\tb\n c  ") == 3)
        #expect(ExpectedDuration.words("well-known, isn't it?") == 3)
    }

    @Test func chineseCountsCharactersDigitsAndLatinWords() {
        #expect(ExpectedDuration.units("你好，世界！", .zh) == 4)
        #expect(ExpectedDuration.units("我们讨论OpenAI API 2026。", .zh) == 10)
        #expect(ExpectedDuration.units("〇二六 don't stop", .zh) == 5)
        #expect(ExpectedDuration.units("，。！", .zh) == 1)
        let text = "我们明天继续讨论下一步的工作计划。"
        let characters = text.unicodeScalars.filter(TextScript.isHan).count
        let c = ExpectedDuration.coefficients(.zh)
        #expect(ExpectedDuration.seconds(text, .zh) == c.baseS + c.perWordS * Double(characters))
        #expect(ExpectedDuration.seconds(text, .zh) > 3)
        #expect(ExpectedDuration.seconds(text, .zh) > ExpectedDuration.seconds("好。", .zh))
    }

    @Test func runawayLimit() {
        let e = ExpectedDuration.seconds("a b", .en)
        #expect(abs(ExpectedDuration.runawayLimitS("a b", .en, factor: 2.0, extraS: 0.6) - (2 * e + 0.6)) < 1e-12)
    }
}
