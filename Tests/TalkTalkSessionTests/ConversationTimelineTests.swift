import Testing
import TalkTalkCore
@testable import TalkTalkSession

@Suite struct ConversationTimelineTests {
    private static let s: HostTime = 1_000_000_000

    private func line(_ id: UInt64, _ text: String, _ source: String, approx: Bool = false) -> SubtitleBoard.Line {
        .init(sentence: id, text: text, source: source, approx: approx, numberWarning: false)
    }

    @Test func remotePairsAndMyTurnsMergeByArrival() {
        var timeline = ConversationTimeline()
        timeline.noteRemote(.source("Let's start"), at: 1 * Self.s)
        timeline.noteRemote(.draft(sentence: 1, text: "我们开始", source: "Let's start"), at: 2 * Self.s)
        timeline.syncRemote(finals: [], draft: line(1, "我们开始", "Let's start"), liveSource: "Let's start", at: 2 * Self.s)
        // The open remote pair shows the live text with the same-epoch draft, as one row.
        #expect(timeline.rows.map(\.id) == [.remote(1)])
        #expect(timeline.rows[0].sourceIsLive && !timeline.rows[0].translationIsFinal)

        // My turn started after the remote utterance; it is committed later.
        let turn = ConversationTimeline.Turn(press: 7, source: "好的", translation: "OK", isFinal: true,
                                             startedAt: 3 * Self.s, delivery: .sent)
        let committed = timeline.commit(turn, at: 10 * Self.s)
        #expect(committed)
        timeline.noteRemote(.source(""), at: 11 * Self.s)
        timeline.noteRemote(.final(sentence: 1, text: "我们开始吧。", source: "Let's start.", approx: true, numberWarning: false),
                            at: 12 * Self.s)
        timeline.syncRemote(finals: [line(1, "我们开始吧。", "Let's start.", approx: true)], draft: nil, liveSource: "", at: 12 * Self.s)
        // The final keeps its utterance's arrival, so it stays above my later turn.
        #expect(timeline.rows.map(\.id) == [.remote(1), .me(7)])
        #expect(timeline.rows[0].translationIsFinal && timeline.rows[0].isSettled)
        #expect(timeline.rows[1].delivery == .sent)

        // Remote speech after my turn arrives below it.
        timeline.noteRemote(.source("Next point"), at: 15 * Self.s)
        timeline.syncRemote(finals: [line(1, "我们开始吧。", "Let's start.", approx: true)], draft: nil,
                            liveSource: "Next point", at: 15 * Self.s)
        #expect(timeline.rows.map(\.id) == [.remote(1), .me(7), .remoteLive(1)])
        #expect(timeline.rows.last?.translation == "")
    }

    @Test func liveTextNeverPairsWithAnotherSentencesDraft() {
        var timeline = ConversationTimeline()
        timeline.noteRemote(.source("First sentence"), at: 1 * Self.s)
        timeline.noteRemote(.draft(sentence: 1, text: "第一句", source: "First sentence"), at: 2 * Self.s)
        // The sentence closes and the next one starts before the first final arrives.
        timeline.noteRemote(.source(""), at: 3 * Self.s)
        timeline.noteRemote(.source("Second"), at: 4 * Self.s)
        timeline.syncRemote(finals: [], draft: line(1, "第一句", "First sentence"), liveSource: "Second", at: 4 * Self.s)
        #expect(timeline.rows.map(\.id) == [.remote(1), .remoteLive(1)])
        #expect(timeline.rows[0].source == "First sentence" && !timeline.rows[0].sourceIsLive)
        #expect(timeline.rows[1].source == "Second" && timeline.rows[1].sourceIsLive)
        // A final without its own draft takes the oldest closed utterance's arrival.
        timeline.noteRemote(.source(""), at: 7 * Self.s)
        timeline.noteRemote(.final(sentence: 2, text: "第二句。", source: "Second.", approx: false, numberWarning: false),
                            at: 9 * Self.s)
        timeline.noteRemote(.final(sentence: 1, text: "第一句。", source: "First sentence.", approx: false, numberWarning: false),
                            at: 8 * Self.s)
        timeline.syncRemote(finals: [line(1, "第一句。", "First sentence."), line(2, "第二句。", "Second.")],
                            draft: nil, liveSource: "", at: 9 * Self.s)
        #expect(timeline.rows.map(\.id) == [.remote(1), .remote(2)])
        #expect(timeline.rows.map(\.arrivedAt) == [1 * Self.s, 4 * Self.s])
    }

    @Test func retentionCountsMyTurnsAndEvictsWholePairsForGood() {
        var timeline = ConversationTimeline(retention: .init(windowNs: 60 * Self.s, maxSegments: 3, maxCharacters: 6_000))
        var finals: [SubtitleBoard.Line] = []
        for id in 1...2 as ClosedRange<UInt64> {
            finals.append(line(id, "译文\(id)", "source \(id)"))
            timeline.syncRemote(finals: finals, draft: nil, liveSource: "", at: HostTime(id) * Self.s)
        }
        timeline.commit(.init(press: 1, source: "我说", translation: "I said", isFinal: true, startedAt: 3 * Self.s), at: 3 * Self.s)
        timeline.commit(.init(press: 2, source: "再说", translation: "Again", isFinal: true, startedAt: 4 * Self.s), at: 4 * Self.s)
        #expect(timeline.rows.map(\.id) == [.remote(2), .me(1), .me(2)])
        // The board still holds sentence 1, but an evicted pair never comes back.
        timeline.syncRemote(finals: finals, draft: line(3, "草稿", "draft"), liveSource: "", at: 5 * Self.s)
        #expect(timeline.rows.map(\.id) == [.remote(2), .me(1), .me(2), .remote(3)])
        // An open pair is never evicted and does not push out settled rows by itself.
        #expect(timeline.rows.last?.isSettled == false)
    }

    @Test func windowRunsFromSettlingAndTheNewestPairAlwaysStays() {
        var timeline = ConversationTimeline()
        // A long turn started 50 s before it was committed is not evicted at once.
        timeline.commit(.init(press: 1, source: "长发言", translation: "A long turn", isFinal: true, startedAt: 50 * Self.s),
                        at: 100 * Self.s)
        timeline.syncRemote(finals: [line(1, "回复", "Reply")], draft: nil, liveSource: "", at: 150 * Self.s)
        #expect(timeline.rows.map(\.id) == [.me(1), .remote(1)])
        timeline.syncRemote(finals: [line(1, "回复", "Reply"), line(2, "再回复", "Reply again")], draft: nil, liveSource: "",
                            at: 170 * Self.s)
        #expect(timeline.rows.map(\.id) == [.remote(1), .remote(2)])
        // A single pair over the character budget remains as the newest pair.
        var small = ConversationTimeline(retention: .init(windowNs: 60 * Self.s, maxSegments: 24, maxCharacters: 10))
        small.commit(.init(press: 1, source: String(repeating: "长", count: 40), translation: "x", isFinal: true,
                           startedAt: 1), at: 1)
        #expect(small.rows.count == 1)
        small.commit(.init(press: 2, source: "短", translation: "y", isFinal: true, startedAt: 2), at: 2)
        #expect(small.rows.map(\.id) == [.me(2)])
        // Re-committing an evicted press is ignored; clearing starts over.
        let revived = small.commit(.init(press: 1, source: "旧", translation: "old", isFinal: true, startedAt: 3), at: 3)
        #expect(!revived)
        // A subtitle reset keeps my turns, and restarted sentence numbers show again.
        timeline.commit(.init(press: 5, source: "我", translation: "me", isFinal: true, startedAt: 175 * Self.s), at: 215 * Self.s)
        #expect(timeline.rows.map(\.id) == [.remote(2), .me(5)])
        timeline.clearRemote()
        #expect(timeline.rows.map(\.id) == [.me(5)])
        timeline.syncRemote(finals: [line(1, "新的", "New")], draft: nil, liveSource: "", at: 216 * Self.s)
        #expect(timeline.rows.map(\.id) == [.me(5), .remote(1)])
        small.clear()
        #expect(small.isEmpty)
        let fresh = small.commit(.init(press: 1, source: "旧", translation: "old", isFinal: true, startedAt: 4), at: 4)
        #expect(fresh)
    }

    @Test func liveTurnIsShownOnlyAsAnUnretainedLastRow() {
        var timeline = ConversationTimeline()
        timeline.syncRemote(finals: [line(1, "你好", "Hello")], draft: nil, liveSource: "", at: 1 * Self.s)
        let live = ConversationTimeline.Turn(press: 3, source: "我在说", translation: "I am", isFinal: false, startedAt: 2 * Self.s)
        let shown = timeline.rows(including: live)
        #expect(shown.map(\.id) == [.remote(1), .me(3)])
        #expect(shown.last?.isSettled == false && shown.last?.sourceIsLive == true)
        #expect(timeline.rows.count == 1)
        #expect(timeline.rows(including: nil) == timeline.rows)
    }

    @Test func deliveryLabelsFollowWhatActuallyPlayed() {
        var meeting = TurnDelivery()
        // Audio before this turn has text is not credited.
        meeting.observe(voice: .playingTranslation, playing: true, hasTranslation: false, live: true)
        #expect(meeting.label(scene: .meeting, hasTranslation: true) == .notSent)
        // Another press's playback is reported as not this turn's (playing: false).
        meeting.observe(voice: .translating, playing: false, hasTranslation: true, live: true)
        #expect(meeting.label(scene: .meeting, hasTranslation: true) == .notSent)
        meeting.observe(voice: .translating, playing: true, hasTranslation: true, live: true)
        #expect(meeting.label(scene: .meeting, hasTranslation: true) == .sent)
        #expect(TurnDelivery().label(scene: .meeting, hasTranslation: false) == nil)
        // Risk or unavailable audio never counts as sent.
        var risky = TurnDelivery()
        risky.observe(voice: .remoteHearsOriginal, playing: true, hasTranslation: true, live: true)
        #expect(risky.label(scene: .meeting, hasTranslation: true) == .notSent)

        var phone = TurnDelivery()
        #expect(phone.label(scene: .phone, hasTranslation: true) == nil)
        phone.observe(voice: .playingTranslation, playing: true, hasTranslation: true, live: true)
        #expect(phone.label(scene: .phone, hasTranslation: true) == .phoneSent)
        phone.observe(voice: .phoneLocalOnly, playing: true, hasTranslation: true, live: true)
        #expect(phone.label(scene: .phone, hasTranslation: true) == .phoneLocalOnly)
        phone.observe(voice: .phoneReconnecting, playing: false, hasTranslation: true, live: true)
        #expect(phone.label(scene: .phone, hasTranslation: true) == .aborted)
        #expect(phone.label(scene: .video, hasTranslation: true) == nil)
        #expect(ConversationTimeline.Delivery.phoneSent.title == "已送入 Phone")
        #expect(ConversationTimeline.Delivery.notSent.symbol == ConversationTextRules.unsentSymbol)
        #expect(ConversationTimeline.Delivery.phoneSent.symbol == SubtitleTokens.VoiceIcon.sentToPhone)
        #expect(ConversationTimeline.Delivery.phoneLocalOnly.symbol == SubtitleTokens.VoiceIcon.thisMac)
        #expect(ConversationTimeline.Delivery.aborted.symbol == SubtitleTokens.VoiceIcon.aborted)
        #expect(ConversationTimeline.Delivery.sent.symbol == SubtitleTokens.ConversationIcon.delivered)
        // Meeting success is glyph-only; Phone and problem labels keep their (safety) words.
        #expect(!ConversationTimeline.Delivery.sent.drawsTitle)
        let worded: [ConversationTimeline.Delivery] = [.notSent, .phoneSent, .phoneLocalOnly, .aborted]
        for delivery in worded { #expect(delivery.drawsTitle, "\(delivery)") }
        // Help starts with the visible word (VoiceOver reads help) and never claims the other
        // side heard it.
        let all: [ConversationTimeline.Delivery] = [.sent, .notSent, .phoneSent, .phoneLocalOnly, .aborted]
        for delivery in all {
            let word = delivery == .phoneLocalOnly ? "仅本机" : delivery.title
            #expect(delivery.help.hasPrefix(word + "："))
            #expect(!delivery.help.contains("对方已听到") || delivery.help.contains("不代表对方已听到"))
        }
    }

    @Test func finishedTurnsAreNotRelabelledAndDemoTurnsAreNeverSent() {
        // Delivered, then the call ends: a reader change after the turn finished is no abort.
        var delivered = TurnDelivery()
        delivered.observe(voice: .playingTranslation, playing: true, hasTranslation: true, live: true)
        delivered.observe(voice: .phoneReconnecting, playing: false, hasTranslation: true, live: false)
        #expect(delivered.label(scene: .phone, hasTranslation: true) == .phoneSent)
        var trial = TurnDelivery()
        trial.observe(voice: .phoneLocalOnly, playing: true, hasTranslation: true, live: true)
        trial.observe(voice: .phoneReconnecting, playing: false, hasTranslation: true, live: false)
        #expect(trial.label(scene: .phone, hasTranslation: true) == .phoneLocalOnly)
        // Isolated demo: playback is local, never 已送出.
        var demo = TurnDelivery()
        demo.observe(voice: .translating, playing: true, hasTranslation: true, live: true, isolated: true)
        demo.observe(voice: .localPlayback, playing: true, hasTranslation: true, live: true)
        #expect(demo.label(scene: .meeting, hasTranslation: true) == nil)
        #expect(!demo.sent)
    }

    @Test func freezeKeepsOneLatestSnapshotAndCountsNewFinals() {
        var timeline = ConversationTimeline()
        var follow = TimelineFollow()
        timeline.syncRemote(finals: [line(1, "一", "one")], draft: line(2, "二", "two"), liveSource: "", at: 1 * Self.s)
        follow.update(timeline.rows)
        follow.freeze()
        let frozen = follow.displayed
        timeline.syncRemote(finals: [line(1, "一", "one"), line(2, "二。", "two.")], draft: line(3, "三", "three"),
                            liveSource: "", at: 2 * Self.s)
        follow.update(timeline.rows)
        timeline.commit(.init(press: 1, source: "我", translation: "me", isFinal: true, startedAt: 3 * Self.s), at: 3 * Self.s)
        follow.update(timeline.rows)
        #expect(follow.isFrozen && follow.displayed == frozen)
        // Sentence 2 became final and my turn was committed; the open draft 3 does not count.
        #expect(follow.newFinalCount == 2)
        follow.follow()
        #expect(!follow.isFrozen && follow.displayed == timeline.rows && follow.newFinalCount == 0)
    }
}
