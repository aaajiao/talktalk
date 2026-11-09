import Testing
@testable import TalkTalkCore

struct RollingSentenceCommitterTests {
    @Test func aPeriodAtTheEndOfAReadingIsNeverAFinishedSentence() {
        var committer = RollingSentenceCommitter(lang: .en)
        for _ in 0..<4 {
            #expect(committer.observe("They come from a three-point.").sentence == nil)
        }
    }

    @Test func aStableInteriorPeriodReleasesTheSentenceAndKeepsTheRest() {
        var committer = RollingSentenceCommitter(lang: .en)
        #expect(committer.observe("Nobody was at fault. The system allowed it.").sentence == nil)
        let reading = committer.observe("Nobody was at fault. The system allowed it to happen.")
        #expect(reading.sentence == "Nobody was at fault.")
        #expect(reading.remainder == "The system allowed it to happen.")
    }

    @Test func needsWordsAfterThePeriodAndTwoAgreeingReadings() {
        var committer = RollingSentenceCommitter(lang: .en)
        #expect(committer.observe("Nobody was at fault. The system.").sentence == nil)
        #expect(committer.observe("Nobody was at fault. The system.").sentence == nil)   // one word short
        var revised = RollingSentenceCommitter(lang: .en)
        #expect(revised.observe("It came from ownership. From rushed decisions now.").sentence == nil)
        #expect(revised.observe("It came from ownership, from rushed decisions now.").sentence == nil)
        #expect(revised.observe("It came from ownership. From rushed decisions now.").sentence == nil)
    }

    @Test func abbreviationsAndGermanOrdinalsDoNotEndASentence() {
        var english = RollingSentenceCommitter(lang: .en)
        for _ in 0..<3 {
            #expect(english.observe("Dr. Chen at the U.S. Naval Academy measured this").sentence == nil)
        }
        var german = RollingSentenceCommitter(lang: .de)
        for _ in 0..<3 {
            #expect(german.observe("Wir treffen uns am 3. Mai in Berlin").sentence == nil)
        }
    }

    @Test func chineseCountsCharactersAndKeepsLatinSpacing() {
        var committer = RollingSentenceCommitter(lang: .zh)
        #expect(committer.observe("我们用 OpenAI 的模型。这件事不能怪任何人").sentence == nil)
        let reading = committer.observe("我们用 OpenAI 的模型。这件事不能怪任何人。")
        #expect(reading.sentence == "我们用 OpenAI 的模型。")
        #expect(reading.remainder == "这件事不能怪任何人。")
        var short = RollingSentenceCommitter(lang: .zh)
        _ = short.observe("今天天气很好。明天呢")
        #expect(short.observe("今天天气很好。明天呢").sentence == nil)   // fewer than six characters follow
    }

    @Test func aClosingQuoteStaysWithItsSentence() {
        var committer = RollingSentenceCommitter(lang: .zh)
        _ = committer.observe("他说“我们走吧。”然后大家都离开了房间")
        let reading = committer.observe("他说“我们走吧。”然后大家都离开了房间。")
        #expect(reading.sentence == "他说“我们走吧。”")
        #expect(reading.remainder == "然后大家都离开了房间。")
    }

    @Test func laterReadingsDropReleasedTextEvenWhenItsEndIsRevised() {
        var committer = RollingSentenceCommitter(lang: .zh)
        _ = committer.observe("今天谈谈可靠的软件。我们遇到的大多数问题")
        #expect(committer.observe("今天谈谈可靠的软件。我们遇到的大多数问题其实").sentence == "今天谈谈可靠的软件。")
        #expect(committer.hasReleased)
        #expect(committer.observe("今天谈谈可靠的软件？我们遇到的大多数问题其实并不是").remainder == "我们遇到的大多数问题其实并不是")
    }

    @Test func aForcedCutDropsTheTailPeriodAndTheSentenceContinues() {
        var committer = RollingSentenceCommitter(lang: .en)
        _ = committer.observe("That number sounds small. But over a decade it")
        let closing = committer.finish("That number sounds small. But over a decade it is a three-point.", forced: true)
        #expect(closing.sentences == ["That number sounds small."])
        #expect(closing.tail == "But over a decade it is a three-point")
        #expect(committer.observe("Five percent drop in defects.").remainder == "five percent drop in defects.")
    }

    @Test func aForcedCutAfterAWordThatLooksLikeAnAbbreviationStillLeavesTheSentenceOpen() {
        for (reading, tail) in [("It turned out to be a.", "It turned out to be a"), ("We asked Dr.", "We asked Dr")] {
            var committer = RollingSentenceCommitter(lang: .en)
            #expect(committer.finish(reading, forced: true).tail == tail)
        }
    }

    @Test func aPeriodAfterAnUnfinishedWordIsNotBelieved() {
        var committer = RollingSentenceCommitter(lang: .en)
        _ = committer.observe("I kind of. Agree with the notion that")
        let reading = committer.observe("I kind of. Agree with the notion that it")
        #expect(reading == .init(sentence: nil, remainder: "I kind of agree with the notion that it"))
        let closing = committer.finish("I kind of. Agree with the notion that it is.", forced: false)
        #expect(closing == .init(sentences: [], tail: "I kind of agree with the notion that it is."))
    }

    @Test func unfinishedEndings() {
        #expect(UnfinishedEnding.matches("I kind of.", lang: .en))
        #expect(UnfinishedEnding.matches("I think the", lang: .en))
        #expect(!UnfinishedEnding.matches("What is it of?", lang: .en))
        #expect(!UnfinishedEnding.matches("You don't have to.", lang: .en))
        #expect(!UnfinishedEnding.matches("We closed our Series A.", lang: .en))
        #expect(!UnfinishedEnding.matches("Um.", lang: .en))
        #expect(!UnfinishedEnding.matches("Um, um.", lang: .en))
        #expect(UnfinishedEnding.matches("Ich weiß, dass.", lang: .de))
        #expect(!UnfinishedEnding.matches("Ich steige ein.", lang: .de))
        #expect(!UnfinishedEnding.matches("Ja, ich habe einen.", lang: .de))
        #expect(UnfinishedEnding.matches("我觉得因为。", lang: .zh))
        #expect(UnfinishedEnding.matches("这个方案，嗯。", lang: .zh))
        #expect(!UnfinishedEnding.matches("嗯。", lang: .zh))
        #expect(!UnfinishedEnding.matches("嗯嗯。", lang: .zh))
        #expect(!UnfinishedEnding.matches("我们要参与。", lang: .zh))
    }

    @Test func aLongSentenceIsCutAtSentenceEndsThenCommas() {
        let committer = RollingSentenceCommitter(lang: .en)
        let words = (1...14).map { "W\($0)" }.joined(separator: " ")
        let long = "It is done here. \(words), \(words), \(words)"
        let cut = committer.splitLong(long, fromWords: 30, minHeadWords: 12)
        #expect(cut?.head == "It is done here.")
        #expect(cut?.rest == "\(words), \(words), \(words)")
        let commas = "\(words), \(words), \(words)"
        #expect(committer.splitLong(commas, fromWords: 30, minHeadWords: 12)?.head == "\(words), \(words),")
        let farEnd = "\(words), \(words) \(words) \(words) \(words) end. Next one goes here."
        #expect(committer.splitLong(farEnd, fromWords: 30, minHeadWords: 12)?.head == "\(words),")
        let tag = (1...29).map { "w\($0)" }.joined(separator: " ") + ", right."
        #expect(committer.splitLong(tag, fromWords: 30, minHeadWords: 12) == nil)
        let plain = (1...40).map { "w\($0)" }.joined(separator: " ")
        #expect(committer.splitLong(plain, fromWords: 30, minHeadWords: 12) == nil)
    }

    @Test func chineseIsCutAtFullWidthMarksOnly() {
        let committer = RollingSentenceCommitter(lang: .zh)
        let run = String(repeating: "字", count: 30)
        let cut = committer.splitLong("\(run)1,000\(run)，\(run)", fromWords: 30, minHeadWords: 12)
        #expect(cut?.head == "\(run)1,000\(run)，")
        #expect(cut?.rest == run)
        let ratio = committer.splitLong("\(run)3：1\(run)，\(run)", fromWords: 30, minHeadWords: 12)
        #expect(ratio?.head == "\(run)3：1\(run)，")
    }

    @Test func aPeriodNoReadingAgreedOnDoesNotSplitTheFinal() {
        var committer = RollingSentenceCommitter(lang: .en)
        let closing = committer.finish("Here's the trouble with rain. Here's what about. We were walking to.", forced: false)
        #expect(closing == .init(sentences: [], tail: "Here's the trouble with rain. Here's what about. We were walking to."))
    }

    @Test func theTailAfterASplitGoesOnEvenWhenLISTENAskedForTheFinal() {
        var committer = RollingSentenceCommitter(lang: .en)
        _ = committer.observe("It really was the weather. You recall the way that")
        let closing = committer.finish("It really was the weather. You recall the way that the.", forced: false)
        #expect(closing == .init(sentences: ["It really was the weather."], tail: "You recall the way that the"))
        #expect(committer.observe("Harvest went badly.").remainder == "harvest went badly.")
    }

    @Test func aFinalTheSpeakerCausedKeepsItsPeriod() {
        var committer = RollingSentenceCommitter(lang: .en)
        let closing = committer.finish("It takes about a minute.", forced: false)
        #expect(closing == .init(sentences: [], tail: "It takes about a minute."))
        #expect(committer.observe("The next one starts.").remainder == "The next one starts.")
    }

    @Test func aForcedCutSkipsReleasedTextAndAFewWordsAfterADoNotSplit() {
        var committer = RollingSentenceCommitter(lang: .en)
        _ = committer.observe("Nobody was at fault. The system allowed it.")
        _ = committer.observe("Nobody was at fault. The system allowed it to.")
        let closing = committer.finish("Nobody was at fault. The system allowed it. To happen.", forced: true)
        #expect(closing == .init(sentences: [], tail: "The system allowed it. To happen"))
        #expect(!committer.hasReleased)
    }

    @Test func onlyOrdinaryEnglishWordsLoseTheirCapital() {
        func continued(_ head: String, lang: Lang = .en) -> String {
            var committer = RollingSentenceCommitter(lang: lang)
            _ = committer.finish("We finally traced it back and.", forced: true)
            return committer.observe(head).remainder
        }
        #expect(continued("Which means that") == "which means that")
        #expect(continued("I think that") == "I think that")
        #expect(continued("I'm sure that") == "I'm sure that")
        #expect(continued("OpenAI said that") == "OpenAI said that")
        #expect(continued("USA said that") == "USA said that")
        #expect(continued("Ergebnis der Wahl", lang: .de) == "Ergebnis der Wahl")
    }

    @Test func aPeriodSeenOnlyAtTheEndOfTheLastReadingIsNotYetAgreed() {
        var committer = RollingSentenceCommitter(lang: .en)
        #expect(committer.observe("We finally traced it back.").sentence == nil)
        #expect(committer.observe("We finally traced it back. To the same three.").sentence == nil)
        #expect(committer.observe("We finally traced it back. To the same three people.").sentence == "We finally traced it back.")
    }

    @Test func aDotInsideANumberOrLatinWordIsNotAChineseSentenceEnd() {
        for reading in ["增长了3.5个百分点，这是非常好的结果呢", "我们用的是Node.js这个工具来做服务端的开发"] {
            var committer = RollingSentenceCommitter(lang: .zh)
            _ = committer.observe(reading)
            #expect(committer.observe(reading + "好").sentence == nil)
            var cut = RollingSentenceCommitter(lang: .zh)
            #expect(cut.finish(reading, forced: true).sentences.isEmpty)
        }
    }

    @Test func aWordThatContinuesInLowercaseMeansThePeriodWasNotAnEnd() {
        var committer = RollingSentenceCommitter(lang: .en)
        for _ in 0..<3 {
            #expect(committer.observe("She has a Ph.D. from Stanford in biology").sentence == nil)
        }
    }

    @Test func trailingMarksStayWithTheirSentence() {
        var committer = RollingSentenceCommitter(lang: .zh)
        _ = committer.observe("他说……然后我们就走了回家去")
        let reading = committer.observe("他说……然后我们就走了回家去吧")
        #expect(reading.sentence == "他说……")
        #expect(reading.remainder == "然后我们就走了回家去吧")
    }

    private func released(_ lang: Lang, _ first: String) -> RollingSentenceCommitter {
        var committer = RollingSentenceCommitter(lang: lang)
        _ = committer.observe(first)
        let reading = committer.observe(first)
        #expect(reading.sentence != nil)
        return committer
    }

    @Test func releasedReadingGrowsVerbatimAndClearsWhenTheWindowMoves() {
        var committer = released(.en, "Nobody was at fault. The system allowed it to.")
        #expect(committer.releasedReading == "Nobody was at fault.")
        let next = "Nobody was at fault. The system allowed it. Then we all left."
        _ = committer.observe(next)
        #expect(committer.observe(next).sentence == "The system allowed it.")
        #expect(committer.releasedReading == "Nobody was at fault. The system allowed it.")
        committer.windowMoved()
        #expect(committer.releasedReading.isEmpty)
    }

    @Test func aLongBacklogIsCutNearItsMiddle() throws {
        let clause = "one two three four five six seven eight,"
        let text = Array(repeating: clause, count: 5).joined(separator: " ") + " one two three four"
        let committer = RollingSentenceCommitter(lang: .en)
        let cut = try #require(committer.splitLong(text, fromWords: 30, minHeadWords: 12))
        #expect(cut.head.split(separator: " ").count == 24)
        #expect(cut.rest.split(separator: " ").count == 20)
    }

    @Test func longRunsCountWordsAndTwiceAsManyChineseCharacters() {
        let english = RollingSentenceCommitter(lang: .en), chinese = RollingSentenceCommitter(lang: .zh)
        #expect(english.isLong(Array(repeating: "word", count: 30).joined(separator: " "), fromWords: 30))
        #expect(!english.isLong(Array(repeating: "word", count: 29).joined(separator: " "), fromWords: 30))
        #expect(chinese.isLong(String(repeating: "字", count: 60), fromWords: 30))
        #expect(!chinese.isLong(String(repeating: "字", count: 59) + "。", fromWords: 30))
    }

    @Test func aRepeatedPhraseLaterInTheReadingIsNotMistakenForReleasedText() {
        var committer = released(.zh, "这是一个很重要的问题。我们今天来谈一谈吧")
        #expect(committer.observe("这是一个很重要的问题，我们今天要讨论这个问题。").remainder == "我们今天要讨论这个问题。")
    }

    @Test func addedOrDroppedWordsDoNotDuplicateOrLoseTheNextOnes() {
        var inserted = released(.en, "We went to store. And then we left.")
        #expect(inserted.observe("We went to the store. And then we left the shop.").remainder == "And then we left the shop.")
        var dropped = released(.en, "We went to the store. And then we left.")
        #expect(dropped.observe("We went to store. And then we left.").remainder == "And then we left.")
        var noPeriod = released(.zh, "今天谈谈可靠的软件。我们遇到的问题很多")
        #expect(noPeriod.observe("今天谈谈可靠的软件我们遇到的问题很多呢").remainder == "我们遇到的问题很多呢")
    }

    @Test func aRevisedLastWordIsStillCountedAsReleased() {
        var committer = released(.en, "We looked at the back. And then we left.")
        #expect(committer.observe("We looked at the bark. And then we left it.").remainder == "And then we left it.")
    }

    @Test func aNumberRewrittenAtTheSentenceEndDoesNotEatTheNextWords() {
        var english = released(.en, "It grew by five percent. And then we left.")
        #expect(english.observe("It grew by 5%. And then we left the shop.").remainder == "And then we left the shop.")
        var chinese = released(.zh, "增长了百分之五。然后我们离开了这里吧")
        #expect(chinese.observe("增长了5%。然后我们离开了这里吧").remainder == "然后我们离开了这里吧")
        var later = released(.en, "We looked at the back. And then we left.")
        #expect(later.observe("We looked at the bark. Back then we left it.").remainder == "Back then we left it.")
    }

    @Test func anOpeningQuoteAfterReleasedTextIsKept() {
        var committer = released(.zh, "这本书我读过了。《三体》的作者是刘慈欣先生")
        #expect(committer.observe("这本书我读过了。《三体》的作者是刘慈欣先生吧").remainder == "《三体》的作者是刘慈欣先生吧")
    }

    @Test func aReadingSharingNoWordsWithReleasedTextIsKeptWhole() {
        var committer = released(.en, "Okay. We can start the meeting now.")
        #expect(committer.observe("Let us begin today with this.").remainder == "Let us begin today with this.")
    }

    @Test func aCutFollowedBySilenceDoesNotLowercaseTheNextSentence() {
        var empty = RollingSentenceCommitter(lang: .en)
        _ = empty.finish("It took a.", forced: true)
        _ = empty.observe("")
        #expect(empty.observe("The next thing is").remainder == "The next thing is")
        var silent = RollingSentenceCommitter(lang: .en)
        _ = silent.finish("It took a.", forced: true)
        silent.speechStopped()
        #expect(silent.observe("The next thing is").remainder == "The next thing is")
        var nothing = RollingSentenceCommitter(lang: .en)
        _ = nothing.finish("It took a.", forced: true)
        _ = nothing.finish("", forced: true)
        #expect(nothing.observe("The next thing is").remainder == "The next thing is")
    }

    @Test func aFinalWithNothingNewReturnsNothing() {
        var committer = RollingSentenceCommitter(lang: .en)
        _ = committer.observe("Nobody was at fault. The system allowed it.")
        _ = committer.observe("Nobody was at fault. The system allowed it.")
        #expect(committer.finish("Nobody was at fault.", forced: true) == .init(sentences: [], tail: ""))
        #expect(committer.finish("", forced: true) == .init(sentences: [], tail: ""))
    }
}
