import Testing
@testable import TalkTalkCore

@Suite struct FinalizeTriggerTests {
    func trigger(_ lang: Lang = .en) throws -> FinalizeTrigger {
        FinalizeTrigger(config: try TestResources.profile().listen.finalize, lang: lang)
    }

    /// Feeds (time, words, punct, silence, final) and returns the first trigger and its time.
    func run(_ t: inout FinalizeTrigger, _ steps: [(Int, Int, Bool, Int, Bool)]) -> (FinalizeTrigger.Kind, Int)? {
        for (now, w, p, s, f) in steps {
            if let k = t.observe(nowMs: now, words: w, stableEndsWithSentencePunct: p, silenceMs: s, asrFinal: f) { return (k, now) }
        }
        return nil
    }

    @Test func nothingFiresBeforeTheFirstWord() throws {
        var t = try trigger()
        #expect(run(&t, [(0, 0, false, 5000, false), (25_000, 0, false, 25_000, true)]) == nil)
    }

    @Test func asrFinalWins() throws {
        var t = try trigger()
        #expect(run(&t, [(0, 3, false, 0, false), (100, 3, true, 900, true)])! == (.asrFinal, 100))
    }

    @Test func punctuationAndAPauseOf400() throws {
        var t = try trigger()
        let r = run(&t, [(0, 4, false, 0, false), (500, 5, true, 0, false), (850, 5, true, 300, false), (900, 5, true, 350, false)])
        #expect(r! == (.punctPause, 900))
    }

    @Test func videoIgnoresTextThatMerelyStopsGrowing() throws {
        let config = try TestResources.profile().listen.forVideoCaptions.finalize
        var punctuated = FinalizeTrigger(config: config, lang: .en)
        #expect(run(&punctuated, [(0, 12, true, 0, false), (2400, 12, true, 0, false)]) == nil)
        #expect(run(&punctuated, [(2500, 12, true, 0, false)])! == (.force, 2500))
        var silent = FinalizeTrigger(config: config, lang: .en)
        #expect(run(&silent, [(0, 3, true, 0, false), (800, 3, true, 800, false)])! == (.silence, 800))
    }

    @Test func tenWordsAndAPauseOf300Then150After8s() throws {
        var t = try trigger()
        #expect(run(&t, [(0, 1, false, 0, false), (1000, 10, false, 0, false), (1299, 10, false, 0, false), (1300, 10, false, 0, false)])! == (.force, 1300))
        var u = try trigger()
        #expect(run(&u, [(0, 1, false, 0, false), (8500, 12, false, 0, false), (8650, 12, false, 0, false)])! == (.force, 8650))
    }

    @Test func silenceThresholdDependsOnLanguage() throws {
        var en = try trigger(.en), de = try trigger(.de)
        let steps = [(0, 3, false, 0, false), (800, 3, false, 800, false), (1000, 3, false, 1000, false)]
        #expect(run(&en, steps)! == (.silence, 800))
        #expect(run(&de, steps)! == (.silence, 1000))
    }

    @Test func stallWithoutNewWords() throws {
        var t = try trigger()
        #expect(run(&t, [(0, 3, false, 0, false), (1199, 3, false, 0, false), (1200, 3, false, 0, false)])! == (.stall, 1200))
        var u = try trigger()
        #expect(run(&u, [(0, 1, false, 0, false), (8000, 4, false, 0, false), (8600, 4, false, 0, false)])! == (.stall, 8600))
    }

    @Test func hardCapAt20s() throws {
        var t = try trigger()
        var steps: [(Int, Int, Bool, Int, Bool)] = []
        for i in 0...200 { steps.append((i * 100, i % 9 + 1, false, 0, false)) }   // a new word count every 100 ms
        #expect(run(&t, steps)! == (.hardCap, 20_000))
    }

    @Test func helpers() {
        #expect(FinalizeTrigger.stablePrefix("we will fix it", "we will fix this") == "we will fix")
        #expect(FinalizeTrigger.endsWithSentencePunct("Let's go. "))
        #expect(!FinalizeTrigger.endsWithSentencePunct("Let's go,"))
        #expect(FinalizeTrigger.wordCount("  a b\tc ") == 3)
        #expect(FinalizeTrigger.wordCount("我们明天开会", lang: .zh) == 6)
        #expect(FinalizeTrigger.wordCount("OpenAI API 延迟 20%", lang: .zh) == 6)
        #expect(FinalizeTrigger.wordCount("。！？", lang: .zh) == 0)
    }
}
