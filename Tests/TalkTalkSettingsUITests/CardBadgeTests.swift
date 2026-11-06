import Testing
@testable import TalkTalkSettingsUI

/// Settings visual system §3.1: a card has one corner, so the most severe state wins, and no
/// badge means ready.
@Suite struct CardBadgeTests {
    @Test func theMostSevereCandidateWinsAndReadyShowsNothing() {
        let pending = CardBadge.status(.pending, "未安装")
        let warn = CardBadge.status(.warn, "可更新")
        let risk = CardBadge.status(.risk, "对方能听到原声")
        let failed = CardBadge.status(.failed, "记录损坏")
        let cloud = CardBadge.cloud("已启用 OpenAI")
        #expect(CardBadge.mostSevere([cloud, pending, warn, nil]) == warn)
        #expect(CardBadge.mostSevere([warn, risk, pending]) == risk)
        #expect(CardBadge.mostSevere([risk, failed]) == failed)
        #expect(CardBadge.mostSevere([cloud, .status(.recording, "诊断录音中"), warn])?.glyph == .status(.recording))
        // Ties keep the earlier candidate.
        #expect(CardBadge.mostSevere([.status(.warn, "a"), .status(.warn, "b")])?.reason == "a")
        #expect(CardBadge.mostSevere([.status(.ok, "已就绪"), nil]) == nil)
        #expect(CardBadge.mostSevere([]) == nil)
    }

    @Test func voiceOverSaysWhatNeedsHandling() {
        #expect(CardBadge.status(.warn, "可更新").spoken == "需要处理：可更新")
        #expect(CardBadge.status(.pending, "未安装").spoken == "需要处理：未安装")
        #expect(CardBadge.status(.recording, "诊断录音中").spoken == "诊断录音中")
        #expect(CardBadge.cloud("已启用 OpenAI").spoken == "已启用 OpenAI")
    }
}
