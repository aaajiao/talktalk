import Testing
@testable import TalkTalkCore

struct TextNormalizerChineseTests {
    @Test func keepsChineseSentenceMarksAndAddsOnlyTheMissingStop() {
        for text in ["我们明天继续讨论。", "可以吗？", "当然！", "他说“好的。”", "他说「好的。」"] {
            #expect(TextNormalizer.normalize(text, lang: .zh) == text)
        }
        #expect(TextNormalizer.normalize("请在2026年完成，", lang: .zh) == "请在2026年完成。")
        #expect(TextNormalizer.normalize("他说“好的”", lang: .zh) == "他说“好的。”")
        #expect(TextNormalizer.normalize("明天见", lang: .zh) == "明天见。")
    }
}
