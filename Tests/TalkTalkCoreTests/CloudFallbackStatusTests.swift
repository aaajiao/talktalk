import Testing
@testable import TalkTalkCore

/// §11 menu lines 字幕翻译／我说话翻译：Apple 备用 (CloudFallbackStatus, MTError.cloudRefused).
@Suite struct CloudFallbackStatusTests {
    @Test func aLoneFallbackDoesNotShowARunOrRefusalDoes() {
        var s = CloudFallbackStatus()
        s.fallback(refused: false)
        #expect(!s.showing)                 // one sentence missed its deadline
        s.openAI()
        s.fallback(refused: false)
        #expect(!s.showing)                 // an OpenAI result in between: still alone
        s.fallback(refused: false)
        #expect(s.showing)                  // the second in a row
        s.fallback(refused: false)
        #expect(s.showing)
        s.openAI()
        #expect(!s.showing)
        s.fallback(refused: true)
        #expect(s.showing)                  // refused before sending: at once
        s.openAI()
        #expect(!s.showing)
        #expect(CloudFallbackStatus.fallbacksInARow == 2)
    }

    @Test func onlyRefusalsBeforeSendingAndPausesCountAsRefused() {
        for reason in ["offline", "breakerOpen", "timeoutBreakerOpen", "paused:http401", "paused:insufficient_quota"] {
            #expect(MTError.cloudRefused(reason), "\(reason)")
        }
        let perSentence = ["deadline", "allFailed", "failAfterDeltaNoTime", "noReply", "late", "body", "noResult",
                           "empty", "gate:containsCJK", "appleUnavailable"]
        for reason in perSentence { #expect(!MTError.cloudRefused(reason), "\(reason)") }
        #expect(FallbackReason.deadline.rawValue == "deadline" && !MTError.cloudRefused(FallbackReason.allFailed.rawValue))
    }
}
