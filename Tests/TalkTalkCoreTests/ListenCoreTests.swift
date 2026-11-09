import Foundation
import Testing
@testable import TalkTalkCore

@Suite struct TimeMapTests {
    let rate = 48_000.0
    let period = 480   // 10 ms
    func ns(_ ms: Double) -> HostTime { HostTime(ms * 1_000_000) }

    @Test func contiguousCallbacksMapLinearly() {
        var m = TimeMap(sampleRate: rate)
        let t0: HostTime = 5_000_000_000
        for i in 0..<100 { #expect(m.observe(host: t0 + ns(Double(i) * 10), frames: period, ioPeriodFrames: period) == .contiguous) }
        #expect(m.framesSoFar == 48_000)
        #expect(m.hostTime(atFrame: 24_000) == t0 + ns(500))
        #expect(m.frame(atHost: t0 + ns(250)) == 12_000)
        #expect(m.segments.count == 1)
    }

    /// §3.1: a 300 ms gap (tap rebuild) is filled with zeros; conversions on both sides stay
    /// within one IO period.
    @Test func gapOf300msIsFilledAndConversionsStayWithinOnePeriod() {
        var m = TimeMap(sampleRate: rate)
        let t0: HostTime = 1_000_000_000
        for i in 0..<50 { _ = m.observe(host: t0 + ns(Double(i) * 10), frames: period, ioPeriodFrames: period) }
        // Next callback expected at t0 + 500 ms; it arrives 300 ms late.
        let obs = m.observe(host: t0 + ns(800), frames: period, ioPeriodFrames: period)
        #expect(obs == .fillZeros(14_400))
        for i in 1..<50 { _ = m.observe(host: t0 + ns(800 + Double(i) * 10), frames: period, ioPeriodFrames: period) }
        // A frame 200 ms after the gap: audio frame index = 500 ms + 300 ms fill + 200 ms.
        let f = Int64(rate * 1.0)
        let h = m.hostTime(atFrame: f)!
        #expect(abs(Int64(bitPattern: h &- (t0 + ns(1000)))) <= Int64(ns(10)))
        #expect(abs(m.frame(atHost: t0 + ns(1000))! - f) <= Int64(period))
        // Before the gap still maps through the first segment.
        #expect(m.hostTime(atFrame: 4_800) == t0 + ns(100))
    }

    @Test func gapLongerThanTwoSecondsAsksForARestart() {
        var m = TimeMap(sampleRate: rate)
        _ = m.observe(host: ns(1000), frames: period, ioPeriodFrames: period)
        #expect(m.observe(host: ns(1010 + 2500), frames: period, ioPeriodFrames: period) == .restart(gapMs: 2500))
        #expect(m.framesSoFar == Int64(2 * period))
        #expect(m.hostTime(atFrame: Int64(period)) == ns(3510))
    }

    @Test func slowDriftReanchorsWithoutFill() {
        var m = TimeMap(sampleRate: rate)
        var host: HostTime = 0
        // The device runs 200 ppm fast relative to the host clock for 60 s.
        for _ in 0..<6000 {
            #expect(m.observe(host: host, frames: period, ioPeriodFrames: period) == .contiguous)
            host += HostTime(10_000_000.0 * 1.0002)
        }
        let h = m.hostTime(atFrame: m.framesSoFar - Int64(period))!
        #expect(abs(Int64(bitPattern: h &- (host - HostTime(10_000_000.0 * 1.0002)))) <= Int64(ns(10)))
        #expect(m.segments.count > 1)
    }

    @Test func machTicksRoundTrip() {
        let t = HostClock.now()
        let ticks = HostClock.machTicks(fromNanos: t)
        #expect(abs(Int64(bitPattern: HostClock.nanos(fromMachTicks: ticks) &- t)) < 100)
    }
}

@Suite struct LCPCommitterTests {
    @Test func commitsTheAgreedPrefixOnly() {
        var c = LCPCommitter(unit: .word)
        #expect(c.update(hypothesis: "we should") == [])
        #expect(c.update(hypothesis: "we should move") == ["we", "should"])
        #expect(c.update(hypothesis: "we should move the meeting") == ["move"])
        #expect(c.committedText == "we should move")
    }

    @Test func caseAndEdgePunctuationDoNotBreakAgreement() {
        var c = LCPCommitter(unit: .word)
        c.update(hypothesis: "hello everyone")
        #expect(c.update(hypothesis: "Hello, everyone.") == ["Hello,", "everyone."])
    }

    @Test func revisionsOfCommittedTokensAreCountedNotApplied() {
        var c = LCPCommitter(unit: .word)
        c.update(hypothesis: "the bass is")
        c.update(hypothesis: "the bass is loud")
        #expect(c.committedText == "the bass is")
        c.update(hypothesis: "the base is loud")
        #expect(c.revisions == 1)
        #expect(c.committedText == "the bass is")
    }

    @Test func listenAdoptsALongerAgreedPrefixAfterARevision() {
        var c = LCPCommitter(unit: .word, adoptsRevisedPrefix: true)
        c.update(hypothesis: "I want to wreck")
        c.update(hypothesis: "I want to wreck a")
        #expect(c.committedText == "I want to wreck")
        c.update(hypothesis: "I want to recognize speech")
        #expect(c.committedText == "I want to wreck")   // a shorter agreement keeps the commit
        c.update(hypothesis: "I want to recognize speech now")
        #expect(c.committedText == "I want to recognize speech")
        #expect(c.revisions == 2)
    }

    @Test func listenContinuesAfterAChinesePausePunctuationIsRevised() {
        var c = LCPCommitter(unit: .character, adoptsRevisedPrefix: true)
        c.update(hypothesis: "我们用 GPT。")
        c.update(hypothesis: "我们用 GPT。")
        #expect(c.committedText == "我们用 GPT。")
        c.update(hypothesis: "我们用 GPT 模型")
        c.update(hypothesis: "我们用 GPT 模型翻译")
        #expect(c.committedText == "我们用 GPT 模型")
    }

    @Test func chineseCommitsByCharacter() {
        var c = LCPCommitter(unit: .for(.zh))
        c.update(hypothesis: "我们明天")
        #expect(c.update(hypothesis: "我们明天开会") == ["我", "们", "明", "天"])
        #expect(c.committedText == "我们明天")
    }

    @Test func characterAgreementPreservesTermSpacesAndNeverRewritesCommittedSurface() {
        var c = LCPCommitter(unit: .character)
        c.update(hypothesis: "我们用 OpenAI GPT")
        c.update(hypothesis: "我们用 OpenAI GPT 模型")
        #expect(c.committedText == "我们用 OpenAI GPT")
        c.update(hypothesis: "我们用 OpenAI GPT 模型翻译")
        #expect(c.committedText == "我们用 OpenAI GPT 模型")
        c.update(hypothesis: "我们用 OpenAI XYZ 模型翻译")
        #expect(c.committedText == "我们用 OpenAI GPT 模型")
        c.reset()
        c.commitFinal("API key 已更新")
        #expect(c.committedText == "API key 已更新")
    }

    @Test func finalCommitsEverything() {
        var c = LCPCommitter(unit: .word)
        c.update(hypothesis: "see you")
        #expect(c.commitFinal("see you tomorrow.") == ["see", "you", "tomorrow."])
    }
}

@Suite struct ListenSegmenterTests {
    func seg(_ lang: Lang = .en) throws -> ListenSegmenter {
        ListenSegmenter(lang: lang, profile: try TestResources.profile().listen)
    }

    func finals(_ a: [ListenSegmenter.Action]) -> [ListenSegmenter.SentenceFinal] {
        a.compactMap { if case let .sentenceFinal(f) = $0 { f } else { nil } }
    }

    func drafts(_ a: [ListenSegmenter.Action]) -> [String] {
        a.compactMap { if case let .draft(_, t) = $0 { t } else { nil } }
    }

    func video(_ lang: Lang = .en) throws -> ListenSegmenter {
        ListenSegmenter(lang: lang, profile: try TestResources.profile().listen.forVideoCaptions)
    }

    func closes(_ a: [ListenSegmenter.Action]) -> [FinalizeTrigger.Kind] {
        a.compactMap { if case let .finalize(_, kind, _) = $0 { kind } else { nil } }
    }

    private static let longRun = "one two three four five six seven eight nine ten eleven twelve thirteen, "
        + "fourteen fifteen sixteen seventeen eighteen nineteen twenty twentyone twentytwo twentythree twentyfour twentyfive, "
        + "twentysix twentyseven twentyeight twentynine thirty thirtyone thirtytwo"

    @Test func videoWaitsOutAPauseAfterAnUnfinishedWordUntilTheGuard() throws {
        var s = try video()
        _ = s.volatile("I kind of.", nowMs: 0)
        #expect(closes(s.tick(nowMs: 2900, silenceMs: 2900)).isEmpty)
        #expect(closes(s.tick(nowMs: 3000, silenceMs: 3000)) == [.stall])
    }

    @Test func videoStillClosesAFinishedSentenceOnSilence() throws {
        var s = try video()
        _ = s.volatile("I agree with you.", nowMs: 0)
        #expect(closes(s.tick(nowMs: 800, silenceMs: 800)) == [.silence])
    }

    @Test func meetingsDoNotHoldAndDoNotSplit() throws {
        var s = try seg()
        _ = s.volatile("I kind of", nowMs: 0)
        #expect(closes(s.tick(nowMs: 800, silenceMs: 800)) == [.silence])
        var long = try seg()
        let f = finals(long.final(Self.longRun + ".", nowMs: 100))
        #expect(f.count == 1 && f[0].trigger == .asrFinal)
    }

    @Test func aLongRunningSentenceLeavesAsAPieceAndTheRestGoesOn() throws {
        var s = try video()
        let pieces = finals(s.final(Self.longRun, nowMs: 100))
        #expect(pieces.map(\.trigger) == [.longSentence])
        #expect(pieces[0].text.hasSuffix("thirteen,"))
        #expect(s.sentence == 2)
        #expect(s.stableText.hasPrefix("fourteen") && s.stableText.hasSuffix("thirtytwo"))
        let closed = finals(s.final("and that is all.", nowMs: 900))
        #expect(closed.count == 1 && closed[0].text.hasSuffix("and that is all.") && closed[0].trigger == .asrFinal)
    }

    @Test func aLongClosingSentenceIsCutAndTheLastPieceKeepsTheTrigger() throws {
        var s = try video()
        let pieces = finals(s.final(Self.longRun + ".", nowMs: 100))
        #expect(pieces.map(\.trigger) == [.longSentence, .asrFinal])
        #expect(pieces.map(\.sentence) == [1, 2])
        #expect(s.sentence == 3)
    }

    @Test func spontaneousAsrFinalClosesTheSentenceAtOnce() throws {
        var s = try seg()
        _ = s.volatile("good morning", nowMs: 0)
        let a = s.final("Good morning everyone.", nowMs: 900)
        let f = finals(a)
        #expect(f.count == 1)
        #expect(f[0].text == "Good morning everyone.")
        #expect(f[0].trigger == .asrFinal)
        #expect(f[0].triggerAtMs == 900)
        #expect(s.sentence == 2)
    }

    /// M0-T10: en-US `.fastResults` sends a final in the middle of a sentence.
    @Test func midSentenceFinalWithoutPunctuationKeepsTheSentenceOpen() throws {
        var s = try seg()
        _ = s.volatile("so the plan", nowMs: 0)
        #expect(finals(s.final("So the plan for", nowMs: 400)).isEmpty)
        #expect(s.sentence == 1)
        #expect(s.stableText == "So the plan for")
        _ = s.volatile("next week", nowMs: 600)
        #expect(s.sourceLine == "So the plan for next week")
        let f = finals(s.final("next week is ready.", nowMs: 900))
        #expect(f.first?.text == "So the plan for next week is ready.")
        #expect(f.first?.trigger == .asrFinal)
    }

    @Test func triggerAfterOnlyFinalsClosesWithoutWaiting() throws {
        var s = try seg()
        _ = s.volatile("thank you", nowMs: 0)
        _ = s.final("Thank you all", nowMs: 300)
        var t = 300, out: [ListenSegmenter.Action] = []
        while out.isEmpty, t < 3000 {
            t += 50
            out = s.tick(nowMs: t, silenceMs: t - 300)
        }
        #expect(!out.contains { if case .finalize = $0 { true } else { false } })
        let f = finals(out)
        #expect(f.first?.text == "Thank you all")
        #expect(f.first?.finalTimeout == false)
        #expect(f.first?.finalAtMs == f.first?.triggerAtMs)
        #expect(!s.awaitingFinal)
    }

    @Test func silenceTriggersFinalizeThenTheFinalClosesWithTheTriggerTime() throws {
        var s = try seg()
        var actions: [ListenSegmenter.Action] = []
        actions += s.volatile("let us", nowMs: 0)
        actions += s.volatile("let us start", nowMs: 300)
        actions += s.volatile("let us start now", nowMs: 600)
        var t = 600
        var fin: ListenSegmenter.Action?
        while fin == nil, t < 3000 {
            t += 50
            let a = s.tick(nowMs: t, silenceMs: t - 600)
            fin = a.first { if case .finalize = $0 { true } else { false } }
        }
        guard case let .finalize(id, trigger, through) = fin else { Issue.record("no finalize"); return }
        #expect(id == 1)
        #expect(trigger == .silence)
        #expect(through == 1400)       // 800 ms of silence (en)
        #expect(s.awaitingFinal)
        // Volatiles while waiting are ignored.
        #expect(s.volatile("let us start now please", nowMs: 1500).isEmpty)
        let f = finals(s.final("Let us start now.", nowMs: 1650))
        #expect(f.first?.triggerAtMs == 1400)
        #expect(f.first?.finalAtMs == 1650)
        #expect(f.first?.finalTimeout == false)
        #expect(!s.awaitingFinal)
    }

    @Test func missingFinalTimesOutWithTheHypothesis() throws {
        var s = try seg()
        _ = s.volatile("this is", nowMs: 0)
        _ = s.volatile("this is it", nowMs: 100)
        var t = 100, out: [ListenSegmenter.SentenceFinal] = []
        while out.isEmpty, t < 6000 {
            t += 50
            out = finals(s.tick(nowMs: t, silenceMs: t - 100))
        }
        #expect(out.first?.text == "this is it")
        #expect(out.first?.finalTimeout == true)
        #expect(out.first!.finalAtMs - out.first!.triggerAtMs == 1500)
    }

    @Test func draftsEveryTwoNewStableWordsAtMostTwicePerSecond() throws {
        var s = try seg()
        var d: [String] = []
        let words = "we need to decide on the budget for next year today".split(separator: " ").map(String.init)
        for i in 1...words.count {
            d += drafts(s.volatile(words.prefix(i).joined(separator: " "), nowMs: i * 200))
        }
        // Stable = LCP-2, i.e. one word behind the hypothesis. ≥2 new words, ≥500 ms apart.
        #expect(!d.isEmpty)
        #expect(d.first == "we need")
        for (a, b) in zip(d, d.dropFirst()) {
            #expect(FinalizeTrigger.wordCount(b) - FinalizeTrigger.wordCount(a) >= 2)
        }
        #expect(d.count <= (words.count * 200) / 500 + 1)
    }

    @Test func intervalDraftAfterOneSecondEvenForOneNewWord() throws {
        var s = try seg()
        _ = s.volatile("okay", nowMs: 0)
        _ = s.volatile("okay so", nowMs: 100)       // stable "okay"
        var d: [String] = []
        for t in stride(from: 150, through: 1100, by: 50) { d += drafts(s.tick(nowMs: t, silenceMs: 0)) }
        #expect(d == ["okay"])
    }

    @Test func chineseDraftsContinueGrowingWithoutWhitespaceOrFalseStalls() throws {
        var s = try seg(.zh)
        let chars = Array("我们明天上午一起讨论预算安排")
        var translated: [String] = []
        for count in 2...chars.count {
            let time = (count - 2) * 200
            let actions = s.volatile(String(chars.prefix(count)), nowMs: time)
            translated += drafts(actions)
            #expect(!actions.contains { if case .finalize = $0 { true } else { false } })
            let tickActions = s.tick(nowMs: time + 199, silenceMs: 0)
            translated += drafts(tickActions)
            #expect(!tickActions.contains { if case .finalize = $0 { true } else { false } })
        }
        #expect(translated.count >= 3)
        #expect(translated.first == "我们")
        #expect(translated.last!.count > translated.first!.count)
    }

    @Test func chineseFinalSpansJoinWithoutInsertedSpaces() throws {
        var s = try seg(.zh)
        _ = s.final("我们明天", nowMs: 0)
        _ = s.volatile("讨论预算", nowMs: 100)
        #expect(s.sourceLine == "我们明天讨论预算")
        let output = finals(s.final("讨论预算。", nowMs: 200))
        #expect(output.first?.text == "我们明天讨论预算。")
    }

    @Test func chineseDraftGrowthKeepsEnglishTermBoundaries() throws {
        var s = try seg(.zh), output: [String] = []
        for (index, phrase) in ["我们用 OpenAI GPT", "我们用 OpenAI GPT 模型", "我们用 OpenAI GPT 模型翻译",
                                 "我们用 OpenAI GPT 模型翻译视频"].enumerated() {
            output += drafts(s.volatile(phrase, nowMs: index * 500))
        }
        #expect(output.count >= 2)
        #expect(output.allSatisfy { $0.contains("OpenAI GPT") && !$0.contains("OpenAIGPT") })
        #expect(s.stableText == "我们用 OpenAI GPT 模型翻译")
        var spans = try seg(.zh)
        _ = spans.final("我们使用 OpenAI", nowMs: 0)
        let result = finals(spans.final("GPT 模型。", nowMs: 200))
        #expect(result.first?.text == "我们使用 OpenAI GPT 模型。")
    }

    @Test func germanWaitsLongerForSilence() throws {
        var s = try seg(.de)
        _ = s.volatile("wir müssen", nowMs: 0)
        _ = s.volatile("wir müssen das", nowMs: 100)
        var kind: FinalizeTrigger.Kind?, at = 0
        for t in stride(from: 150, through: 2000, by: 50) {
            for case let .finalize(_, k, through) in s.tick(nowMs: t, silenceMs: t - 100) { kind = k; at = through }
            if kind != nil { break }
        }
        #expect(kind == .silence)
        #expect(at == 1100)
    }
}

@Suite struct EchoFilterTests {
    @Test func textOverlapAloneNeverDrops() {
        var f = EchoFilter()
        f.recordPlayed(text: "So that's 300,000 euros for next year.", startMs: 0, endMs: 3000)
        #expect(f.decide(text: "So, 300,000 euros, right?", startMs: 10_000, echoScore: 0.1) == .keep)
    }

    @Test func overlapWithAcousticEchoDrops() {
        var f = EchoFilter()
        f.recordPlayed(text: "So that's 300,000 euros for next year.", startMs: 0, endMs: 3000)
        guard case let .drop(reason, o) = f.decide(text: "that's 300,000 euros for next year", startMs: 10_000, echoScore: 0.7) else {
            Issue.record("expected drop"); return
        }
        #expect(reason == .ttsEcho)
        #expect(o >= 0.99)
    }

    @Test func overlapDuringPlaybackDropsWithoutAcousticScore() {
        var f = EchoFilter()
        f.recordPlayed(text: "Let me walk you through the plan", startMs: 1000, endMs: 3000)
        #expect(f.decide(text: "walk you through the plan", startMs: 4500, echoScore: nil) != .keep)
        #expect(f.decide(text: "walk you through the plan", startMs: 5500, echoScore: nil) == .keep)
    }

    @Test func oldClausesFallOutOfTheWindow() {
        var f = EchoFilter()
        f.recordPlayed(text: "budget approved", startMs: 0, endMs: 1000)
        #expect(f.decide(text: "budget approved", startMs: 22_000, echoScore: 0.9) == .keep)
    }

    @Test func passthroughEchoNeedsTheAcousticScore() {
        var f = EchoFilter()
        f.recordPassthrough(startMs: 0, endMs: 4000)
        #expect(f.decide(text: "anything", startMs: 5000, echoScore: 0.6) == .drop(reason: .passthroughEcho, overlap: 0))
        #expect(f.decide(text: "anything", startMs: 5000, echoScore: 0.2) == .keep)
    }

    @Test func chinesePartialEchoNeedsSubstantiveTextAndPlaybackOrAcousticEvidence() {
        var filter = EchoFilter()
        filter.recordPlayed(text: "我们明天讨论合同细节。", startMs: 1000, endMs: 3000)
        let partial = "明天讨论合同"
        #expect(filter.decide(text: partial, startMs: 2000, echoScore: nil) != .keep)
        #expect(filter.decide(text: partial, startMs: 10_000, echoScore: 0.9) != .keep)
        #expect(filter.decide(text: partial, startMs: 10_000, echoScore: 0.1) == .keep)
        #expect(filter.decide(text: "明天我们去公园", startMs: 2000, echoScore: 0.9) == .keep)
    }

    @Test func commonShortChineseRepliesDoNotBecomeTextEchoEvidence() {
        for text in ["好", "好的", "明天见", "好的好的", "哈哈哈哈", "好，好，好"] {
            var filter = EchoFilter()
            filter.recordPlayed(text: text, startMs: 1000, endMs: 3000)
            #expect(filter.decide(text: text, startMs: 2000, echoScore: nil) == .keep)
            #expect(filter.decide(text: text, startMs: 2000, echoScore: 0.9) == .keep)
        }
        #expect(EchoFilter.tokens("明天讨论合同") == ["明天", "天讨", "讨论", "论合", "合同"])
        #expect(EchoFilter.tokens("中文 API 300,000") == ["中文", "api", "300000"])
    }

    @Test func numbersStayWholeTokens() {
        #expect(EchoFilter.tokens("So, 300,000 euros, right?") == ["so", "300000", "euros", "right"])
    }
}

@Suite struct EventLogTests {
    @Test func freeTextCannotBeLoggedAsATag() {
        let log = EventLog(inMemory: { 42 })
        log.event("listen.final", ["chars": 12, "trigger": .tag("silence"), "oops": .tag("Hello world, secret text")])
        let e = log.recorded
        #expect(e.count == 1)
        #expect(e[0]["ev"] as? String == "listen.final")
        #expect(e[0]["trigger"] as? String == "silence")
        #expect(e[0]["oops"] as? String == "?")
        #expect(e[0]["t"] as? UInt64 == 42)
    }

    @Test func writesJSONLinesWithPrivatePermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-eventlog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = try EventLog(sessionID: "test", directory: dir)
        log.event("sys.wake")
        log.event("mt.end", ["ms": 812, "late": false])
        log.close()
        let text = try String(contentsOf: log.url!, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
        let attrs = try FileManager.default.attributesOfItem(atPath: log.url!.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }

    @Test func pruneKeepsTheNewestSessions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-eventlog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<25 {
            let u = dir.appendingPathComponent("s\(i).jsonl")
            FileManager.default.createFile(atPath: u.path, contents: Data("{}\n".utf8))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(-i * 60))], ofItemAtPath: u.path)
        }
        EventLog.prune(dir)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left.count == EventLog.maxSessions - 1)
        #expect(left.contains("s0.jsonl"))
        #expect(!left.contains("s24.jsonl"))
    }
}
