import Testing
@testable import TalkTalkCore

struct FixedLanguage: LanguageIdentifying {
    var result: (Lang, Double)?
    func identify(_ text: String) -> (Lang, Double)? { result }
}

@Suite struct TargetTextGateTests {
    func gate(_ id: any LanguageIdentifying = NLLanguageIdentifier()) throws -> TargetTextGate {
        try TargetTextGate(config: TestResources.profile().speak.mt.targetGate, patterns: TestResources.gatePatterns(), identifier: id)
    }

    @Test func golden() throws {
        let g = try gate()
        #expect(g.check("Beim Budget gibt es vorerst keine Änderung.", target: .de) == .pass("Beim Budget gibt es vorerst keine Änderung."))
        #expect(g.check("Herr Zhang und Herr Li kommen morgen.", target: .de) == .pass("Herr Zhang und Herr Li kommen morgen."))
        #expect(g.check("<none>", target: .en) == .skip)                       // filler-only clause
        #expect(g.check("", target: .en) == .reject(.empty))
        #expect(g.check("…", target: .en) == .reject(.tooFewLatin))
        #expect(g.check("...", target: .de) == .reject(.tooFewLatin))
        #expect(g.check("Uh, um…", target: .en) == .reject(.onlyFillers))
        #expect(g.check("Ähm.", target: .de) == .reject(.onlyFillers))
        #expect(g.check("张总 said yes.", target: .en) == .reject(.containsCJK))
        #expect(g.check("Hello テスト", target: .en) == .reject(.containsCJK))
        #expect(g.check("Here is the translation: hello", target: .en) == .reject(.metaTalk))
        #expect(g.check("Hier ist die Übersetzung: Hallo", target: .de) == .reject(.metaTalk))
        #expect(g.check("(no content)", target: .en) == .reject(.metaTalk))
        #expect(g.check("I cannot translate this.", target: .en) == .reject(.metaTalk))
        #expect(g.check("Yes.", target: .en) == .pass("Yes."))
        #expect(g.check("Ja.", target: .de) == .pass("Ja."))
    }

    @Test func wrongTargetLanguageNeedsThreeWordsAndConfidence() throws {
        let en = try gate(FixedLanguage(result: (.en, 0.95)))
        #expect(en.check("We will fix it next week.", target: .de) == .reject(.wrongLanguage))
        #expect(en.check("OK, gut.", target: .de) == .pass("OK, gut."))             // < 3 words
        let unsure = try gate(FixedLanguage(result: (.en, 0.6)))
        #expect(unsure.check("We will fix it next week.", target: .de) == .pass("We will fix it next week."))
        // The real recognizer on clear sentences.
        let real = try gate()
        #expect(real.check("We are planning to fix this before next Wednesday.", target: .de) == .reject(.wrongLanguage))
        #expect(real.check("Wir planen, das vor nächstem Mittwoch zu beheben.", target: .en) == .reject(.wrongLanguage))
    }

    @Test func transliteratesShortHanRunsOnly() throws {
        let g = try gate()
        #expect(g.transliterateShortHanRuns("Ich habe mit 张总 gesprochen.") == "Ich habe mit Zhang Zong gesprochen.")
        #expect(g.transliterateShortHanRuns("Das ist 一个很长的中文句子") == nil)
    }
}

@Suite struct NumberGuardTests {
    func values(_ s: String) -> [Double] { ChineseNumerals.mentions(in: s).map(\.value) }

    @Test func chineseParserGolden() {
        #expect(values("总共还是三十万欧元。") == [300_000])
        #expect(ChineseNumerals.mentions(in: "延迟大概降低了百分之二十").map { [$0.value, $0.kind == .percent ? 1 : 0] } == [[20, 1]])
        #expect(values("两千零五年") == [2005])
        #expect(values("预算是1.5 亿") == [150_000_000])
        #expect(values("预算是1.5亿") == [150_000_000])
        #expect(ChineseNumerals.mentions(in: "第三季度").map { [$0.value, $0.kind == .ordinal ? 1 : 0] } == [[3, 1]])
        #expect(values("推迟两周") == [2])
        #expect(values("十二") == [12])
        #expect(values("一百五") == [150])
        #expect(values("三万五") == [35_000])
        #expect(values("三千万") == [30_000_000])
        #expect(values("三亿五千万") == [350_000_000])
        #expect(values("二〇二六年") == [2026])
        #expect(values("三点五亿") == [350_000_000])
        #expect(values("百分之三点五") == [3.5])
        #expect(values("300,000 欧元") == [300_000])
        #expect(values("降低了30%") == [30])
        #expect(values("十二月十二号") == [12, 12])
        #expect(values("一百零八") == [108])
    }

    @Test func nonNumbersAreIgnored() {
        #expect(values("我先简单介绍一下") == [])
        #expect(values("测试结果比预期好一些。") == [])
        #expect(values("我们计划下周三之前修好。") == [])
        #expect(values("这个十分重要，千万别忘了") == [])
        #expect(values("我们一起去，一个问题") == [])
        #expect(values("请稍微快一点") == [])
        #expect(ChineseNumerals.mentions(in: "第一个是德语").map(\.value) == [1])
    }

    @Test func targetReaderReadsDigitsAndWords() {
        func t(_ s: String, _ l: Lang) -> [Double] { TargetNumerals.mentions(in: s, lang: l).map(\.value) }
        #expect(t("It is still 300,000 euros in total.", .en) == [300_000])
        #expect(t("Insgesamt sind es weiterhin 300.000 Euro.", .de) == [300_000])
        #expect(t("Wir haben dreihunderttausend Euro eingeplant.", .de) == [300_000])
        #expect(t("three hundred thousand euros", .en) == [300_000])
        #expect(t("Latency dropped by about 30%.", .en) == [30])
        #expect(t("um etwa 30 Prozent", .de) == [30])
        #expect(t("1.5 billion", .en) == [1.5e9])
        #expect(t("150 million", .en) == [150e6])
        #expect(t("1,5 Milliarden", .de) == [1.5e9])
        #expect(t("in the third quarter", .en) == [3])
        #expect(t("im dritten Quartal", .de) == [3])
        #expect(t("on the twelfth of December", .en) == [12, 12])
        #expect(t("am zwölften Dezember", .de) == [12, 12])
        #expect(t("two weeks", .en) == [2])
        #expect(t("zwei Wochen", .de) == [2])
        #expect(t("twenty-six people and a hundred chairs", .en) == [26, 100])
        #expect(t("one problem, ein Problem", .en) == [])
        #expect(t("in 2005", .en) == [2005])
        #expect(t("Q3", .en) == [3])
    }

    @Test func checkGolden() {
        #expect(NumberGuard.check(source: "总共还是三十万欧元。", target: "It is still 300,000 euros.", targetLang: .en).isOK)
        let bad = NumberGuard.check(source: "总共还是三十万欧元。", target: "Insgesamt dreißigtausend Euro.", targetLang: .de)
        #expect(!bad.isOK && bad.hardMismatch)
        #expect(bad.missing == [300_000] && bad.extra == [30_000])
        #expect(bad.sourceTexts == ["三十万"])
        let soft = NumberGuard.check(source: "延迟降低了百分之二十", target: "Latency dropped a lot.", targetLang: .en)
        #expect(!soft.isOK && !soft.hardMismatch)
        #expect(NumberGuard.check(source: "两千零五年", target: "in 2005", targetLang: .en).isOK)
        #expect(NumberGuard.check(source: "1.5 亿", target: "150 million", targetLang: .en).isOK)
        #expect(NumberGuard.check(source: "第三季度", target: "third quarter", targetLang: .en).isOK)
        #expect(NumberGuard.check(source: "我们能不能把发布推迟两周？", target: "Can we postpone the release by two weeks?", targetLang: .en).isOK)
        #expect(NumberGuard.check(source: "我们能不能把发布推迟两周？", target: "Können wir das Release um zwei Wochen verschieben?", targetLang: .de).isOK)
        #expect(NumberGuard.check(source: "我先简单介绍一下项目进展。", target: "Let me give a quick update.", targetLang: .en).isOK)
    }

    @Test func mixedEnglishNumberWordsKeepChineseUnitCounts() {
        let source = "需要two个worker和twenty台server，预算20万，追加1.5 亿。"
        #expect(NumberGuard.sourceMentions(in: source).map(\.value).sorted() == [2, 20, 200_000, 150_000_000])
        #expect(Set(NumberGuard.sourceMentions(in: source).map(\.text)) == ["two", "twenty", "20万", "1.5 亿"])
        let correct = NumberGuard.check(source: source,
            target: "We need two workers and twenty servers, with 200,000 plus 150 million.", targetLang: .en)
        #expect(correct.isOK)
        let wrong = NumberGuard.check(source: source,
            target: "We need three workers and twenty servers, with 200,000 plus 150 million.", targetLang: .en)
        #expect(wrong.missing == [2] && wrong.extra == [3] && wrong.hardMismatch)
    }

    @Test func glossaryTermsMustAppear() {
        let g = [GlossaryEntry(zh: "延迟", en: "latency", de: "Latenz")]
        #expect(NumberGuard.check(source: "延迟很高", target: "Latency is high.", targetLang: .en, glossary: g).isOK)
        #expect(NumberGuard.check(source: "延迟很高", target: "The delay is high.", targetLang: .en, glossary: g).missingTerms == ["latency"])
    }

    @Test func actions() throws {
        let p = try TestResources.profile().speakHedgePolicy
        let hard = NumberGuard.check(source: "三十万", target: "30,000", targetLang: .en)
        let soft = NumberGuard.check(source: "三十万", target: "a lot", targetLang: .en)
        #expect(NumberGuard.action(hard, backend: .apple, maskedMs: 3000, alreadyRetried: false, policy: p) == .block)
        #expect(NumberGuard.action(hard, backend: .openAI, maskedMs: 0, alreadyRetried: false, policy: p) == .retry)
        #expect(NumberGuard.action(soft, backend: .openAI, maskedMs: 0, alreadyRetried: false, policy: p) == .playWithWarning)
        #expect(NumberGuard.action(soft, backend: .openAI, maskedMs: 1500, alreadyRetried: false, policy: p) == .retry)
        #expect(NumberGuard.action(hard, backend: .openAI, maskedMs: 0, alreadyRetried: true, policy: p) == .playWithWarning)
    }
}

@Suite struct TextNormalizerTests {
    @Test func spellsOutNumbers() {
        #expect(TextNormalizer.normalize("It is still €300,000.", lang: .en) == "It is still three hundred thousand euros.")
        #expect(TextNormalizer.normalize("Insgesamt 300.000 €", lang: .de) == "Insgesamt dreihunderttausend Euro.")
        #expect(TextNormalizer.normalize("Latency dropped by 30%", lang: .en) == "Latency dropped by thirty percent.")
        #expect(TextNormalizer.normalize("um 30 % gesenkt", lang: .de) == "um dreißig Prozent gesenkt.")
        #expect(TextNormalizer.normalize("about 300 ms", lang: .en) == "about three hundred milliseconds.")
        #expect(TextNormalizer.normalize("It grew 1.5 times", lang: .en) == "It grew one point five times.")
        #expect(TextNormalizer.normalize("um 1,5 Prozent", lang: .de) == "um eins Komma fünf Prozent.")
        #expect(TextNormalizer.normalize("on the 12th", lang: .en) == "on the twelfth.")
        #expect(TextNormalizer.normalize("since 2026", lang: .en) == "since twenty twenty-six.")
        #expect(TextNormalizer.normalize("since 2005", lang: .en) == "since two thousand five.")
        #expect(TextNormalizer.normalize("seit 1999", lang: .de) == "seit neunzehnhundertneunundneunzig.")
        #expect(TextNormalizer.normalize("seit 2026", lang: .de) == "seit zweitausendsechsundzwanzig.")
        #expect(TextNormalizer.normalize("1 euro", lang: .en) == "one euro.")
    }

    @Test func terminalStop() {
        #expect(TextNormalizer.terminalStop("Thank you") == "Thank you.")
        #expect(TextNormalizer.terminalStop("Thank you,") == "Thank you.")
        #expect(TextNormalizer.terminalStop("Really?") == "Really?")
        #expect(TextNormalizer.terminalStop("He said \"yes\"") == "He said \"yes.\"")
        #expect(TextNormalizer.terminalStop("Wait…") == "Wait…")
        #expect(TextNormalizer.terminalStop("") == "")
    }

    @Test func englishOrdinals() {
        #expect(TextNormalizer.englishOrdinal(1) == "first")
        #expect(TextNormalizer.englishOrdinal(21) == "twenty-first")
        #expect(TextNormalizer.englishOrdinal(30) == "thirtieth")
        #expect(TextNormalizer.englishOrdinal(100) == "one hundredth")
    }
}
