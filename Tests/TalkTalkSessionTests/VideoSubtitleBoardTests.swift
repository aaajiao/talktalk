import Testing
@testable import TalkTalkSession

@Suite struct VideoSubtitleBoardTests {
    @Test func translatedDraftKeepsItsExactOriginalWhenRawSourceAdvances() throws {
        var board = VideoSubtitleBoard()
        let changed1 = board.apply(.source("Words without a translation yet"))
        #expect(!changed1)
        #expect(board.current == nil)
        let changed2 = board.apply(.draft(sentence: 1, text: "我们需要决定", source: "We need to decide"))
        #expect(changed2)
        let draft = try #require(board.current)
        #expect(!draft.isFinal)
        #expect(draft.line.source == "We need to decide")
        let changed3 = board.apply(.source("A completely different next sentence"))
        #expect(!changed3)
        #expect(board.current == draft)
    }

    @Test func sameSentenceFinalReplacesDraftInPlaceAndCannotBecomeDraftAgain() throws {
        var board = VideoSubtitleBoard()
        board.apply(.draft(sentence: 4, text: "先看计划", source: "Review the plan"))
        board.apply(.draft(sentence: 5, text: "下一句", source: "The next sentence"))
        let changed4 = board.apply(.final(sentence: 4, text: "先看新的计划。", source: "Review the new plan.",
                                   approx: true, numberWarning: true))
        #expect(changed4)
        let final = try #require(board.current)
        #expect(final.isFinal && final.line.sentence == 4)
        #expect(final.line.source == "Review the new plan.")
        #expect(final.line.approx && final.line.numberWarning)
        #expect(board.pendingSentenceIDs == [5])
        let changed5 = board.apply(.draft(sentence: 4, text: "迟到草稿", source: "Old draft"))
        #expect(!changed5)
        #expect(board.current == final)
        let changed6 = board.apply(.final(sentence: 4, text: "已修订的计划。", source: "The corrected plan.",
                                   approx: false, numberWarning: false))
        #expect(changed6)
        #expect(board.current?.line.text == "已修订的计划。")
    }

    @Test func newerPairWaitsForExplicitAdvanceAndOldResultsNeverRewind() throws {
        var board = VideoSubtitleBoard()
        board.apply(.final(sentence: 1, text: "第一句。", source: "First.", approx: false, numberWarning: false))
        let first = try #require(board.current)
        let changed7 = board.apply(.draft(sentence: 3, text: "第三句", source: "Third"))
        #expect(!changed7)
        let changed8 = board.apply(.final(sentence: 2, text: "第二句。", source: "Second.", approx: false, numberWarning: false))
        #expect(!changed8)
        #expect(board.current == first)
        #expect(board.pendingSentenceIDs == [2, 3])
        let changed9 = board.advance()
        #expect(changed9)
        #expect(board.current?.line.source == "Second.")
        let changed10 = board.advance()
        #expect(changed10)
        let third = try #require(board.current)
        #expect(third.line.source == "Third" && !third.isFinal)
        let changed11 = board.apply(.final(sentence: 2, text: "迟到第二句。", source: "Late second.", approx: false, numberWarning: false))
        #expect(!changed11)
        let changed12 = board.apply(.draft(sentence: 1, text: "迟到第一句", source: "Late first"))
        #expect(!changed12)
        #expect(board.current == third && board.pendingSentenceIDs.isEmpty)
        let changed13 = board.advance()
        #expect(!changed13)
    }

    @Test func pendingKeepsOnlyLatestTwoPairsAndFinalizedPendingCannotRegress() {
        var board = VideoSubtitleBoard()
        board.apply(.draft(sentence: 1, text: "当前句", source: "Current"))
        board.apply(.final(sentence: 2, text: "第二句。", source: "Second.", approx: false, numberWarning: false))
        board.apply(.draft(sentence: 3, text: "第三句", source: "Third"))
        board.apply(.draft(sentence: 4, text: "第四句", source: "Fourth"))
        #expect(board.current?.line.sentence == 1)
        #expect(board.pendingSentenceIDs == [3, 4])
        board.apply(.final(sentence: 3, text: "第三句定稿。", source: "Third finalized.", approx: false, numberWarning: false))
        board.apply(.draft(sentence: 3, text: "旧草稿", source: "Old draft"))
        #expect(board.pendingFinalSentenceIDs == [3])
        #expect(board.pendingDraftSentenceIDs == [4])
        let changed14 = board.advance()
        #expect(changed14)
        #expect(board.current?.isFinal == true && board.current?.line.source == "Third finalized.")
    }

    @Test func droppedRemovesDraftsButNeverAcceptedFinals() throws {
        var board = VideoSubtitleBoard()
        board.apply(.draft(sentence: 1, text: "当前草稿", source: "Current draft"))
        board.apply(.draft(sentence: 2, text: "待显草稿", source: "Queued draft"))
        board.apply(.final(sentence: 3, text: "待显定稿。", source: "Queued final.", approx: false, numberWarning: false))
        let changed15 = board.apply(.dropped(sentence: 2))
        #expect(!changed15)
        #expect(board.pendingSentenceIDs == [3])
        let changed16 = board.apply(.dropped(sentence: 3))
        #expect(!changed16)
        #expect(board.pendingFinalSentenceIDs == [3])
        let changed17 = board.apply(.dropped(sentence: 1))
        #expect(changed17)
        #expect(board.current == nil)
        let changed18 = board.apply(.draft(sentence: 1, text: "迟到当前草稿", source: "Late draft"))
        #expect(!changed18)
        let changed19 = board.advance()
        #expect(changed19)
        let changed20 = board.apply(.final(sentence: 1, text: "迟到当前定稿。", source: "Late final.", approx: false, numberWarning: false))
        #expect(!changed20)
        let final = try #require(board.current)
        #expect(final.isFinal && final.line.sentence == 3)
        let changed21 = board.apply(.dropped(sentence: 3))
        #expect(!changed21)
        #expect(board.current == final)
    }

    @Test func droppedPendingDraftCannotReappearButItsFinalCanStillArrive() {
        var board = VideoSubtitleBoard()
        board.apply(.draft(sentence: 1, text: "当前句", source: "Current"))
        board.apply(.draft(sentence: 2, text: "旧草稿", source: "Old draft"))
        board.apply(.dropped(sentence: 2))
        #expect(board.pendingSentenceIDs.isEmpty)
        board.apply(.draft(sentence: 2, text: "迟到草稿", source: "Late draft"))
        #expect(board.pendingSentenceIDs.isEmpty)
        // Dropping a future draft does not freeze updates to the currently visible cue.
        let changed22 = board.apply(.draft(sentence: 1, text: "当前句更新", source: "Current updated"))
        #expect(changed22)
        board.apply(.final(sentence: 2, text: "合法定稿。", source: "Accepted final.", approx: false, numberWarning: false))
        #expect(board.pendingFinalSentenceIDs == [2])
        let changed23 = board.advance()
        #expect(changed23)
        #expect(board.current?.line.source == "Accepted final.")
        #expect(board.current?.isFinal == true)

        board.apply(.draft(sentence: 3, text: "第三句", source: "Third"))
        let changed24 = board.advance()
        #expect(changed24)
        board.apply(.dropped(sentence: 3))
        #expect(board.current == nil)
        let changed25 = board.apply(.final(sentence: 3, text: "第三句定稿。", source: "Third finalized.", approx: false, numberWarning: false))
        #expect(changed25)
        #expect(board.current?.isFinal == true)
    }

    @Test func clearResetsPairPendingAndSentenceEpoch() {
        var board = VideoSubtitleBoard()
        board.apply(.final(sentence: 90, text: "旧定稿。", source: "Old.", approx: false, numberWarning: false))
        board.apply(.draft(sentence: 91, text: "旧草稿", source: "Old draft"))
        board.clear()
        #expect(board.current == nil && board.pendingSentenceIDs.isEmpty)
        let changed26 = board.advance()
        #expect(!changed26)
        let changed27 = board.apply(.draft(sentence: 1, text: "新会话", source: "New session"))
        #expect(changed27)
        #expect(board.current?.line.sentence == 1)
    }
}

@Suite struct VideoSubtitleBoardLagTests {
    @Test func overflowCountsSkippedCuesAndLagFollowsTheOldestPendingCue() {
        var board = VideoSubtitleBoard()
        let second: UInt64 = 1_000_000_000
        board.apply(.final(sentence: 1, text: "第一句。", source: "First.", approx: false, numberWarning: false), at: 1 * second)
        #expect(board.lag(at: 20 * second) == nil)
        board.apply(.final(sentence: 2, text: "第二句。", source: "Second.", approx: false, numberWarning: false), at: 2 * second)
        board.apply(.final(sentence: 3, text: "第三句。", source: "Third.", approx: false, numberWarning: false), at: 3 * second)
        #expect(board.skippedCount == 0)
        #expect(board.lag(at: 6 * second) == nil)
        #expect(board.lag(at: 8 * second) == 6)
        board.apply(.final(sentence: 4, text: "第四句。", source: "Fourth.", approx: false, numberWarning: false), at: 4 * second)
        #expect(board.skippedCount == 1)
        #expect(board.pendingSentenceIDs == [3, 4])
        // Sentence 2 left the queue; the lag is now measured from sentence 3.
        #expect(abs(board.lagSeconds(at: 9 * second) - 6) < 1e-9)
        board.advance(); board.advance()
        #expect(board.lag(at: 30 * second) == nil)
        board.clear()
        #expect(board.skippedCount == 0)
    }
}
