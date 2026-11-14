import Testing
@testable import TalkTalkCore

@Suite struct FrenchNumberGuardTests {
    @Test(arguments: [
        ("soixante-dix", 70.0), ("soixante et onze", 71.0), ("soixante-dix-neuf", 79.0),
        ("quatre-vingts", 80.0), ("quatre-vingt-un", 81.0), ("quatre-vingt-dix", 90.0),
        ("quatre-vingt-dix-neuf", 99.0), ("deux cents", 200.0), ("trois cent vingt et un", 321.0),
        ("mille neuf cent quatre-vingt-dix-neuf", 1999.0), ("deux mille vingt-six", 2026.0),
        ("dix-neuf cent quatre-vingt-dix-neuf", 1999.0), ("onze cents", 1100.0),
        ("deux millions trois cent mille", 2_300_000.0), ("1,5 million", 1_500_000.0),
        ("un virgule cinq million d’euros", 1_500_000.0), ("deux virgule zéro cinq milliards", 2_050_000_000.0),
        ("septante-deux", 72.0), ("nonante-neuf", 99.0), ("quatre virgule vingt-cinq", 4.25),
        ("deux virgule zéro cinq", 2.05), ("1 234,56 €", 1234.56), ("1\u{A0}234,56 €", 1234.56),
        ("1\u{202F}234,56 €", 1234.56), ("1,234", 1.234), ("1.5", 1.5),
    ])
    func parsesCompleteNumbers(_ input: (String, Double)) {
        let values = TargetNumerals.mentions(in: input.0, lang: .fr).map(\.value)
        #expect(values.count == 1)
        if let value = values.first { #expect(abs(value - input.1) <= max(1e-9, abs(input.1) * 1e-12)) }
    }

    @Test func datesPercentagesAndOrdinals() {
        let mentions = TargetNumerals.mentions(in: "Le 1er février 2026, vingt pour cent au troisième trimestre.", lang: .fr)
        #expect(mentions.map(\.value) == [1, 2, 2026, 20, 3])
        #expect(mentions.map(\.kind) == [.ordinal, .month, .cardinal, .percent, .ordinal])
        #expect(TargetNumerals.mentions(in: "1re, 2e, 5ème, vingt-et-unième, quatre-vingt-dix-neuvième", lang: .fr).map(\.value) == [1, 2, 5, 21, 99])
        #expect(TargetNumerals.mentions(in: "un pour cent, 30 %", lang: .fr).map(\.value) == [1, 30])
        #expect(TargetNumerals.mentions(in: "août et décembre", lang: .fr).map(\.value) == [8, 12])
    }

    @Test func keepsListsSeparateAndDoesNotCountArticles() {
        #expect(TargetNumerals.mentions(in: "un projet et une équipe", lang: .fr).isEmpty)
        #expect(TargetNumerals.mentions(in: "deux, trois et quatre", lang: .fr).map(\.value) == [2, 3, 4])
        #expect(TargetNumerals.mentions(in: "deux trois", lang: .fr).map(\.value) == [2, 3])
        #expect(TargetNumerals.mentions(in: "une seconde et deux secondes", lang: .fr).map(\.value) == [2])
        #expect(FrenchNumerals.parseDigits("1 2") == nil)
        #expect(FrenchNumerals.parseDigits("1\u{202F}234\u{202F}567,89") == 1_234_567.89)
    }

    @Test func secondsStayTimeUnitsAfterSpokenQuantities() {
        for (text, value) in [("trente secondes", 30.0), ("cent secondes", 100.0), ("quatre-vingts secondes", 80.0),
                              ("quatre-vingt-dix secondes", 90.0), ("deux cent trente secondes", 230.0)] {
            #expect(TargetNumerals.mentions(in: text, lang: .fr).map(\.value) == [value])
        }
        #expect(TargetNumerals.mentions(in: "La seconde tentative.", lang: .fr).map(\.value) == [2])
        #expect(NumberGuard.check(source: "It takes thirty seconds.", sourceLang: .en,
                                 target: "Il faut trente secondes.", targetLang: .fr).isOK)
    }

    @Test func spokenEuroCentsAndHalvesKeepTheirMagnitude() {
        for (text, value) in [("deux euros cinquante", 2.5), ("un euro cinquante", 1.5), ("2 euros 50", 2.5),
                              ("deux euros et vingt-cinq centimes", 2.25), ("deux millions et demi", 2_500_000.0),
                              ("2 millions et demi", 2_500_000.0), ("un et demi million", 1_500_000.0),
                              ("un et demi pour cent", 1.5)] {
            #expect(TargetNumerals.mentions(in: text, lang: .fr).map(\.value) == [value])
        }
        #expect(TargetNumerals.mentions(in: "un et demi pour cent", lang: .fr).map(\.kind) == [.percent])
        #expect(NumberGuard.check(source: "It costs 2.50 euros.", sourceLang: .en,
                                 target: "Cela coûte deux euros cinquante.", targetLang: .fr).isOK)
    }

    @Test func crossLanguageChecksFindRealMismatchAndPreserveFrenchTerms() {
        #expect(NumberGuard.check(source: "预算是三十万欧元，二月减少百分之二十。", target: "Le budget est de 300\u{202F}000 euros, une baisse de vingt pour cent en février.", targetLang: .fr).isOK)
        #expect(NumberGuard.check(source: "Le budget est de quatre-vingt-dix mille euros.", sourceLang: .fr,
                                 target: "The budget is 90,000 euros.", targetLang: .en).isOK)
        #expect(NumberGuard.check(source: "Le budget est de quatre-vingt-dix mille euros.", sourceLang: .fr,
                                 target: "The budget is 9,000 euros.", targetLang: .en).hardMismatch)
        let glossary = [GlossaryEntry(zh: "延迟", en: "latency", de: "Latenz", fr: "latence")]
        #expect(NumberGuard.check(source: "La latence est élevée.", sourceLang: .fr,
                                 target: "Latency is high.", targetLang: .en, glossary: glossary).isOK)
        #expect(NumberGuard.check(source: "La latence est élevée.", sourceLang: .fr,
                                 target: "The delay is high.", targetLang: .en, glossary: glossary).missingTerms == ["latency"])
        let legacy = [GlossaryEntry(zh: "延迟", en: "latency", de: "Latenz")]
        #expect(NumberGuard.check(source: "Bonjour.", sourceLang: .fr, target: "Hello.", targetLang: .en, glossary: legacy).isOK)
    }
}

@Suite struct FrenchTextNormalizerTests {
    @Test func usesFrenchNumbersUnitsAndYears() {
        #expect(TextNormalizer.normalize("Le budget est de 300\u{202F}000 €", lang: .fr) == "Le budget est de trois cent mille euros.")
        #expect(TextNormalizer.normalize("Baisse de 20 %", lang: .fr) == "Baisse de vingt pour cent.")
        #expect(TextNormalizer.normalize("En 2026", lang: .fr) == "En deux mille vingt-six.")
        #expect(TextNormalizer.normalize("En 1999", lang: .fr) == "En mille neuf cent quatre-vingt-dix-neuf.")
        #expect(TextNormalizer.normalize("1,5 kg et 2 Go", lang: .fr) == "un virgule cinq kilogramme et deux gigaoctets.")
        #expect(TextNormalizer.normalize("300 ms", lang: .fr) == "trois cents millisecondes.")
    }

    @Test func ordinalsAndFrenchPunctuation() {
        #expect(TextNormalizer.normalize("Le 1er et la 1re", lang: .fr) == "Le premier et la première.")
        #expect(TextNormalizer.normalize("Le 5e, le 9e et le 80e", lang: .fr) == "Le cinquième, le neuvième et le quatre-vingtième.")
        #expect(TextNormalizer.normalize("Il dit « oui »", lang: .fr) == "Il dit « oui. »")
        #expect(TextNormalizer.normalize("C’est l’idée !", lang: .fr) == "C’est l’idée !")
    }
}

@Suite struct FrenchTargetTextTests {
    @Test func recognizesFrenchWithoutAcceptingEnglishOrMetaTalk() throws {
        let gate = try TargetTextGate(config: TestResources.profile().speak.mt.targetGate, patterns: TestResources.gatePatterns())
        let french = "Nous allons terminer ce projet avant la fin de la semaine prochaine."
        #expect(gate.check(french, target: .fr) == .pass(french))
        #expect(gate.check("We are planning to finish this project before next Wednesday.", target: .fr) == .reject(.wrongLanguage))
        #expect(gate.check("Voici la traduction : Bonjour.", target: .fr) == .reject(.metaTalk))
        #expect(gate.check("Euh, hum…", target: .fr) == .reject(.onlyFillers))
        #expect(gate.check("Oui.", target: .fr) == .pass("Oui."))
        #expect(gate.check("L’idée 中文", target: .fr) == .reject(.containsCJK))
        #expect(TargetTextGate.words("C’est l’idée d’aujourd’hui.") == ["C’est", "l’idée", "d’aujourd’hui"])
    }
}

@Suite struct FrenchSentenceTests {
    @Test func incompleteElisionsAndConjunctionsWaitButRepliesDoNot() {
        #expect(UnfinishedEnding.matches("Je pense que.", lang: .fr))
        #expect(UnfinishedEnding.matches("Je crois qu’", lang: .fr))
        #expect(UnfinishedEnding.matches("C’est l'", lang: .fr))
        #expect(!UnfinishedEnding.matches("J’en prends un.", lang: .fr))
        #expect(!UnfinishedEnding.matches("Je suis pour.", lang: .fr))
        #expect(!UnfinishedEnding.matches("Euh.", lang: .fr))
        #expect(!UnfinishedEnding.matches("Mais ?", lang: .fr))
    }

    @Test func keepsTitlesAndFrenchClosingQuotesWithTheirSentence() {
        var titles = RollingSentenceCommitter(lang: .fr)
        for _ in 0..<3 { #expect(titles.observe("Mme. Dupont et M. Martin arrivent demain").sentence == nil) }
        var quoted = RollingSentenceCommitter(lang: .fr)
        _ = quoted.observe("Il répond « Oui. » Nous partons tous demain.")
        #expect(quoted.observe("Il répond « Oui. » Nous partons tous demain matin.").sentence == "Il répond « Oui. »")
    }

    @Test func joinsRecognitionPeriodAfterUnfinishedFrenchWord() {
        var committer = RollingSentenceCommitter(lang: .fr)
        _ = committer.observe("Je pense que. Nous pouvons finir demain matin")
        let reading = committer.observe("Je pense que. Nous pouvons finir demain matin ensemble")
        #expect(reading.sentence == nil)
        #expect(reading.remainder == "Je pense que nous pouvons finir demain matin ensemble")
        var elision = RollingSentenceCommitter(lang: .fr)
        _ = elision.observe("Je crois qu’. Il pourra venir demain matin")
        #expect(elision.observe("Je crois qu’. Il pourra venir demain matin ensemble").remainder == "Je crois qu’il pourra venir demain matin ensemble")
    }
}
