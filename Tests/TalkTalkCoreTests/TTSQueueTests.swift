import Foundation
import Testing
@testable import TalkTalkCore

/// File-private like the other suites' helpers (an internal one would clash with theirs).
private func ms(_ v: Int) -> HostTime { HostTime(v) * 1_000_000 }

@Suite struct TTSQueueTests {
    static let voice = VoiceHandle(profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                   conditioningKey: "k", mode: .icl,
                                   model: EngineID(name: "tts", revision: "r", placement: .engineGPU))
    let cfg = TTSQueue.Config(mergeWindowMs: 300, mergeMaxWords: 8, wholeClauseBelowExpectedS: 1.5)

    @Test func configFromPolicyProfile() throws {
        let p = try TestResources.profile()
        #expect(TTSQueue.Config(p.speak.tts) == cfg)
    }

    @Test func mergesOnlyWithinWindowAndUnderEightWords() {
        var q = TTSQueue(config: cfg)
        let v0 = q.enqueue(clause: 1, text: "Yes,", lang: .en, at: ms(0))
        #expect(!v0)
        let v1 = q.enqueue(clause: 2, text: "exactly.", lang: .en, at: ms(300))
        #expect(v1)            // 300 ms: inside
        #expect(q.count == 1 && q.items[0].text == "Yes, exactly." && q.items[0].clauses == [1, 2])
        let v2 = q.enqueue(clause: 3, text: "Next one.", lang: .en, at: ms(601))
        #expect(!v2)         // 301 ms after 2
        #expect(q.count == 2)
    }

    @Test func noMergeWhenEitherHasEightWords() {
        var q = TTSQueue(config: cfg)
        q.enqueue(clause: 1, text: "one two three four five six seven eight", lang: .en, at: 0)
        let v3 = q.enqueue(clause: 2, text: "nine", lang: .en, at: ms(10))
        #expect(!v3)
        var r = TTSQueue(config: cfg)
        r.enqueue(clause: 1, text: "short", lang: .en, at: 0)
        let v4 = r.enqueue(clause: 2, text: "one two three four five six seven eight", lang: .en, at: ms(10))
        #expect(!v4)
        var s = TTSQueue(config: cfg)
        s.enqueue(clause: 1, text: "one two three four five six seven", lang: .en, at: 0)
        let v5 = s.enqueue(clause: 2, text: "one two three four five six seven", lang: .en, at: ms(10))
        #expect(v5)
    }

    @Test func noMergeIntoStartedItemOrAcrossLanguages() {
        var q = TTSQueue(config: cfg)
        q.enqueue(clause: 1, text: "Hello.", lang: .en, at: 0)
        _ = q.next(job: 1, voice: Self.voice)                       // started
        let v6 = q.enqueue(clause: 2, text: "Again.", lang: .en, at: ms(50))
        #expect(!v6)
        let v7 = q.enqueue(clause: 3, text: "Hallo.", lang: .de, at: ms(60))
        #expect(!v7)
        #expect(q.items.map(\.clauses) == [[2], [3]])
    }

    @Test func requestHasExplicitLanguageStableSeedAndWholeClause() {
        var q = TTSQueue(config: cfg)
        q.enqueue(clause: 7, text: "Okay.", lang: .de, at: 0)
        q.enqueue(clause: 8, text: "Thanks everyone, let me walk you through the plan for today.", lang: .en, at: ms(1000))
        let (a, ra) = q.next(job: 1, voice: Self.voice)!
        let (_, rb) = q.next(job: 2, voice: Self.voice)!
        #expect(a.clause == 7 && ra.clause == 7 && ra.language == .de && ra.job == 1)
        #expect(ra.seed == TTSSeed.make(voice: Self.voice, language: .de))
        #expect(ra.wholeClause)                              // de, 1 word: well under 1.5 s
        #expect(!rb.wholeClause)                             // en 11 words ≈ 3.5 s
        // Seed is stable across queues (and processes: FNV-1a).
        var q2 = TTSQueue(config: cfg)
        q2.enqueue(clause: 99, text: "Jetzt besprechen wir die nächsten Schritte.", lang: .de, at: 0)
        let v8 = q2.next(job: 5, voice: Self.voice)
        #expect(v8!.request.seed == ra.seed)
        #expect(rb.seed != ra.seed) // Each output language keeps its own fixed sequence.
        let v9 = q.next(job: 3, voice: Self.voice)
        #expect(v9 == nil)
    }

    @Test func wholeClauseThresholdIsExpectedDuration() {
        // For each language, the last word count still under the threshold renders whole and the
        // next one streams (coefficients from expected_duration.json via ExpectedDuration).
        func text(_ n: Int) -> String { (0..<n).map { _ in "w" }.joined(separator: " ") }
        var q = TTSQueue(config: cfg)
        var want: [Bool] = []
        var i = 0
        for l in [Lang.en, .de] {
            var n = 1
            while ExpectedDuration.seconds(text(n + 1), l) < cfg.wholeClauseBelowExpectedS { n += 1 }
            #expect(ExpectedDuration.seconds(text(n), l) < cfg.wholeClauseBelowExpectedS)
            for (w, whole) in [(n, true), (n + 1, false)] {
                q.enqueue(clause: UInt64(i), text: text(w), lang: l, at: ms(i * 1000)); i += 1
                want.append(whole)
            }
        }
        let got = (0..<want.count).map { q.next(job: JobID($0), voice: Self.voice)!.request.wholeClause }
        #expect(got == want)
    }

    @Test func chineseClausesUseCharacterBudgetsAndExplicitLanguage() {
        var q = TTSQueue(config: cfg)
        q.enqueue(clause: 1, text: "我们明天继续讨论下一步的工作计划。", lang: .zh, at: 0)
        let mergedAfterLongClause = q.enqueue(clause: 2, text: "好的。", lang: .zh, at: ms(10))
        #expect(!mergedAfterLongClause)
        let first = q.next(job: 1, voice: Self.voice)!
        #expect(first.request.language == .zh && !first.request.wholeClause)
        #expect(first.item.expectedS > 3)
        let mergedShortClauses = q.enqueue(clause: 3, text: "谢谢。", lang: .zh, at: ms(20))
        #expect(mergedShortClauses)
        #expect(q.items.first?.text == "好的。谢谢。")
        #expect(q.items.first?.words == 4)
    }

    @Test func pendingRemoveAndDrop() {
        var q = TTSQueue(config: cfg)
        q.enqueue(clause: 1, text: "a", lang: .en, at: 0)
        q.enqueue(clause: 2, text: "b c d e f g h i j", lang: .en, at: ms(1000))
        q.enqueue(clause: 3, text: "k", lang: .en, at: ms(2000))
        let pend = ["a", "b c d e f g h i j", "k"].map { ExpectedDuration.seconds($0, .en) }.reduce(0, +)
        #expect(abs(q.pendingExpectedS - pend) < 1e-9)
        let v10 = q.remove(clauses: [2])
        #expect(v10 == [2])
        let v11 = q.dropOldest()
        #expect(v11?.clause == 1)
        let v12 = q.removeAll()
        #expect(v12 == [3])
        #expect(q.isEmpty)
    }
}
