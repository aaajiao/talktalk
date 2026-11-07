import Testing
import TalkTalkCore
@testable import TalkTalkSession

@Suite struct VideoCaptionPagerTests {
    /// One unit per CJK character, half a unit for Latin letters and spaces.
    private func advances(_ text: String) -> [Double] {
        text.map { $0.isASCII ? 0.5 : 1 }
    }

    private func pages(_ text: String, width: Double = 20, maxLines: Int = 2) -> [[String]] {
        let characters = Array(text)
        return VideoCaptionPager.paginate(characters, advances: advances(text), lineWidth: width, maxLines: maxLines)
            .map { page in page.lines.map { String(characters[$0]) } }
    }

    @Test func shortTextIsOneLineAndTwoLinePagesAreBalanced() {
        #expect(pages("我们确认一下安排。") == [["我们确认一下安排。"]])
        let thirty = String(repeating: "字", count: 30)
        #expect(pages(thirty) == [[String(repeating: "字", count: 15), String(repeating: "字", count: 15)]])
    }

    @Test func pageBreakPrefersPunctuationWithinHalfALine() {
        // 50 characters; a comma at offset 35 is 4 characters before the 40-character limit.
        let text = String(repeating: "甲", count: 35) + "，" + String(repeating: "乙", count: 14)
        let result = pages(text)
        #expect(result.count == 2)
        #expect(result[0].joined().hasSuffix("，"))
        #expect(result[0].joined().count == 36)
        // A comma further back than half a line (10) is ignored.
        let far = String(repeating: "甲", count: 25) + "，" + String(repeating: "乙", count: 24)
        let farPages = pages(far)
        #expect(farPages[0].joined().count == 40)
    }

    @Test func noLineStartsWithClosingPunctuationAndTinyRemaindersMoveBack() {
        // The 21st character is "。": the first line must not end before it.
        let text = String(repeating: "丙", count: 20) + "。" + String(repeating: "丁", count: 10)
        for page in pages(text) {
            for line in page { #expect(line.first != "。") }
        }
        // 41 characters must not leave a single character on the last page.
        let longer = String(repeating: "戊", count: 41)
        let result = pages(longer)
        #expect(result.count == 2)
        #expect(result[1].joined().count >= 3)
        // The second line of a page never holds only one or two characters.
        for page in pages(String(repeating: "己", count: 22)) where page.count == 2 {
            #expect(page[1].count >= 3)
        }
    }

    @Test func latinWordsStayWholeAndBreakAfterPunctuation() {
        let text = "We need to decide, before Friday, whether the budget for next year can grow."
        let result = pages(text, width: 12)
        let lines = result.flatMap { $0 }
        let words = Set(text.split(separator: " ").map(String.init))
        for line in lines {
            for word in line.split(separator: " ") { #expect(words.contains(String(word))) }
            #expect(line.first != " " && line.last != " ")
        }
        #expect(lines.joined(separator: " ") == text)
        // The first page ends after a comma when one is within half a line of the limit.
        #expect(result[0].joined(separator: " ") == "We need to decide, before Friday,")
        // A single-line budget still pages without splitting words.
        #expect(pages(text, width: 12, maxLines: 1).allSatisfy { $0.count == 1 })
    }

    @Test func readingBudgetFollowsEachLanguageWhenDirectionsSwap() {
        #expect(VideoCaptionPacing.readingTime(sourceCharacters: 27, translationCharacters: 18,
                                               sourceLanguage: .zh, targetLanguage: .en) == 3)
        #expect(VideoCaptionPacing.readingTime(sourceCharacters: 18, translationCharacters: 27,
                                               sourceLanguage: .de, targetLanguage: .zh) == 3)
        #expect(VideoCaptionPacing.readingTime(sourceCharacters: 18, translationCharacters: 54,
                                               sourceLanguage: .en, targetLanguage: .de) == 3)
        #expect(VideoCaptionPacing.readingTime(sourceCharacters: 18, translationCharacters: 54,
                                               sourceLanguage: .de, targetLanguage: .en) == 3)
        for source in Lang.allCases {
            for target in Lang.allCases where target != source {
                let time = VideoCaptionPacing.readingTime(sourceCharacters: 27, translationCharacters: 45,
                                                          sourceLanguage: source, targetLanguage: target)
                let reversed = VideoCaptionPacing.readingTime(sourceCharacters: 45, translationCharacters: 27,
                                                              sourceLanguage: target, targetLanguage: source)
                #expect(time == reversed)
                #expect(time >= 1 && time <= 6)
                let sample = SubtitleListeningSample(scene: .video, languages: .init(source: source, target: target)).pairs[0]
                for (text, language) in [(sample.source, source), (sample.translation, target)] {
                    let width = VideoCaptionLayout.textBlockWidth(windowWidth: 960, fontSize: 1, language: language)
                    let output = pages(text, width: width).flatMap { $0 }.joined()
                    #expect(output.filter { !$0.isWhitespace } == text.filter { !$0.isWhitespace })
                }
            }
        }
    }

    @Test func pacingCatchUpAndDraftTail() {
        #expect(VideoCaptionPacing.readingTime(sourceCharacters: 0, translationCharacters: 3) == 1)
        #expect(VideoCaptionPacing.readingTime(sourceCharacters: 36, translationCharacters: 9) == 2)
        #expect(VideoCaptionPacing.readingTime(sourceCharacters: 0, translationCharacters: 90) == 6)
        #expect(abs(VideoCaptionPacing.effectiveDuration(4, catchingUp: true) - 2.8) < 1e-9)
        #expect(VideoCaptionPacing.effectiveDuration(1.2, catchingUp: true) == 1)
        #expect(VideoCaptionPacing.effectiveDuration(0.5, catchingUp: true) == 0.5)
        #expect(VideoCaptionPacing.effectiveDuration(4, catchingUp: false) == 4)
        #expect(VideoCaptionPacing.stablePrefixLength(previous: "我们需要决定", current: "我们需要先决定") == 4)
        #expect(VideoCaptionPacing.stablePrefixLength(previous: "", current: "新句") == 0)
        // The changed tail stays dimmed across re-renders of the same draft.
        var tail = VideoDraftTail()
        #expect(tail.stablePrefix(sentence: 1, text: "你好世界", previous: nil) == 0)
        #expect(tail.stablePrefix(sentence: 1, text: "你好世界今天", previous: "你好世界") == 4)
        #expect(tail.stablePrefix(sentence: 1, text: "你好世界今天", previous: "你好世界今天") == 4)
        #expect(tail.stablePrefix(sentence: 2, text: "新句", previous: nil) == 0)
        tail.reset()
        #expect(tail.stablePrefix(sentence: 1, text: "你好世界今天", previous: "你好世界今天") == 6)
    }
}
