import Testing
@testable import TalkTalkCore

@Suite struct T10AnalysisTests {
    /// One sample per second for `minutes`, lag from `lag(minute)`.
    func samples(minutes: Int, lag: (Int) -> Int) -> [(feedS: Double, lagMs: Int)] {
        (0..<(minutes * 60)).map { s in (Double(s) + 0.5, lag(s / 60)) }
    }

    typealias D = T10Analysis.LagDrift
    /// The 1-minute / p50 / minutes 1–5 rule the bench used before C5 (still selectable).
    func perMinute(_ xs: [(feedS: Double, lagMs: Int)]) -> D { D.evaluate(xs, bucketS: 60, baselineBuckets: 5, stat: .p50) }

    @Test func steadyLagPasses() {
        let r = perMinute(samples(minutes: 60) { $0 == 0 ? 900 : 300 })
        #expect(r.baselineMs == 300)   // minute 0 (warm-up at 900 ms) is not the baseline
        #expect(r.maxDeviationMs == 0)
        #expect(r.pass == true)
        #expect(r.buckets.count == 60)
        #expect(r.buckets.allSatisfy { $0.n == 60 })
    }

    @Test func driftBeyondToleranceFails() {
        // Lag grows 3 ms per minute: minute 59 is 168 ms above the 300 ms baseline (minutes 1–5 pooled).
        let r = perMinute(samples(minutes: 60) { 291 + 3 * $0 })
        #expect(r.baselineMs == 300)
        #expect(r.maxDeviationMs == 168)
        #expect(r.pass == false)
    }

    @Test func driftDownwardCountsToo() {
        let r = perMinute(samples(minutes: 20) { $0 < 10 ? 400 : 250 })
        #expect(r.maxDeviationMs == 150)
        #expect(r.pass == false)
    }

    @Test func withinToleranceAtTheEdgePasses() {
        let r = perMinute(samples(minutes: 10) { $0 < 6 ? 300 : 400 })
        #expect(r.maxDeviationMs == 100)
        #expect(r.pass == true)
    }

    @Test func tooShortToJudge() {
        // A 2-minute smoke run under C5 (10-minute buckets): everything is warm-up.
        let r = D.evaluate(samples(minutes: 2) { _ in 300 })
        #expect(r.baselineMs == nil)
        #expect(r.pass == nil)
        let short = D.evaluate(samples(minutes: 2) { _ in 300 }, bucketS: 20, baselineBuckets: 2)
        #expect(short.pass == true)   // the smoke run can use shorter buckets
        #expect(D.evaluate([]).pass == nil)
    }

    @Test func statisticsPerBucket() {
        let xs: [(feedS: Double, lagMs: Int)] = (1...10).map { (5.0, $0 * 10) }
        #expect(D.evaluate(xs).buckets == [.init(index: 0, n: 10, p50: 50, p90: 90, mean: 55, value: 90)])
        #expect(D.evaluate(xs, stat: .mean).buckets[0].value == 55)
    }

    /// C5: 10-minute buckets, p90, baseline = bucket 1 (10–20 min), buckets 2–5 within ±100 ms.
    func gridLags(minutes: Int, shift: (Double) -> Int = { _ in 0 }) -> [(feedS: Double, lagMs: Int)] {
        // One sentence every 5 s, lag uniform over the 960 ms grid wait (deterministic sweep).
        (0..<(minutes * 12)).map { k in
            let t = Double(k) * 5 + 2
            return (t, (k * 397) % 960 + shift(t))
        }
    }

    @Test func c5PassesAGridWaitWithoutDrift() {
        let r = D.evaluate(gridLags(minutes: 60))
        #expect(r.stat == .p90)
        #expect(r.buckets.count == 6)
        #expect(r.baselineMs != nil)
        #expect(r.pass == true)
        #expect(r.maxDeviationMs! <= 20)
    }

    @Test func c5CatchesASustainedShift() {
        let r = D.evaluate(gridLags(minutes: 60) { $0 >= 1800 ? 130 : 0 })
        #expect(r.pass == false)
        #expect(r.maxDeviationMs! >= 100)
    }

    @Test func baselineOfTwoBucketsPoolsSamplesNotTheLowerMedian() {
        // Buckets 1 and 2 at 200 and 400 ms: a lower median of bucket values would say 200.
        let xs: [(feedS: Double, lagMs: Int)] = (0..<300).map { i in
            let t = Double(i)
            return (t, t < 100 ? 0 : t < 200 ? 200 : 400)
        }
        let r = D.evaluate(xs, bucketS: 100, baselineBuckets: 2, stat: .p50)
        #expect(r.baselineMs == 200)   // pooled 100 × 200 + 100 × 400, nearest-rank p50
        let p90 = D.evaluate(xs, bucketS: 100, baselineBuckets: 2, stat: .p90)
        #expect(p90.baselineMs == 400)
    }

    @Test func aShortLastBucketIsNotJudged() {
        // 34 minutes: bucket 3 holds 4 minutes of sentences, under half the others' n.
        let r = D.evaluate(gridLags(minutes: 34) { $0 >= 1800 ? 500 : 0 })
        #expect(r.skippedTail == 3)
        #expect(r.pass == true)        // bucket 2 judged only
        #expect(r.buckets.count == 4)  // still listed
    }

    typealias E = T10Analysis.ResultEvent
    typealias C = T10Analysis.ClipTimes

    // Clips of 4 s audio, speech 0.5–2.5 s (last voiced chunk starts at 2.48 s, fed at wall 12.48);
    // chunks of 320 samples at 16 kHz, each handed over at wall = audio + 10 s (plus `late` for the
    // first `lateChunks` of the run).
    func clip(_ k: Int) -> C {
        C(audioStart: Double(k) * 4, onsetAudio: Double(k) * 4 + 0.5, speechEndAudio: Double(k) * 4 + 2.5, identity: k)
    }
    func feeds(seconds: Double = 8, late: Double = 0, lateChunks: Int = 0) -> T10Analysis.FeedTable {
        var f = T10Analysis.FeedTable()
        for k in 0..<Int(seconds * 50) {
            let a = Double(k * 320) / 16_000
            // Late at the start, catching up linearly over lateChunks.
            let l = k < lateChunks ? late * Double(lateChunks - k) / Double(lateChunks) : 0
            f.append(audio: a, wall: a + 10 + l)
        }
        return f
    }
    /// A volatile as SpeechAnalyzer gives it: its range ends at the audio fed at receipt.
    func v(_ t: Double, _ words: [Double], fed: Double, units: Int = 0) -> E {
        E(t: t, isFinal: false, wordEnds: words, fedAtReceipt: fed, rangeEnd: fed, units: units)
    }

    @Test func lagFromTheSpeechEndOnTheWallClock() {
        // The first volatile covering the speech end (fed 2.76 s) arrives at 12.8: 320 ms.
        let events = [v(11.2, [0.9], fed: 1.2), v(12.1, [0.9, 1.6], fed: 2.1),
                      v(12.8, [0.9, 1.6, 2.76], fed: 2.76, units: 3), E(t: 13.3, isFinal: true, wordEnds: [0.9, 1.6, 2.4], units: 3)]
        let r = T10Analysis.clipLags(events: events, clips: [clip(0)], feeds: feeds())
        #expect(r[0].start == 10)
        #expect(r[0].onsetMs == 700)
        #expect(r[0].completionMs == 320)
        #expect(r[0].lastFromFinal == true)
        #expect(r[0].hitIsFinal == false)
        #expect(r[0].hitIndex == 2)
        #expect(r[0].hitUnits == 3)
        #expect(r[0].finalUnits == 3)
        #expect(T10Analysis.negative(r) == 0)
    }

    @Test func aVolatileBeforeTheSpeechEndIsNotAHit() {
        // The fourth smoke's low values: a volatile within 100 ms of the final's last word, but fed
        // only to 2.32 s, before the last voiced chunk. The next batch (fed 3.44 s) is the hit.
        let events = [v(12.33, [1.0, 2.32], fed: 2.32), v(13.44, [1.0, 2.4], fed: 3.44), E(t: 13.6, isFinal: true, wordEnds: [1.0, 2.4])]
        let r = T10Analysis.clipLags(events: events, clips: [clip(0)], feeds: feeds())
        #expect(r[0].completionMs == 960)
        #expect(r[0].hitIndex == 1)
    }

    @Test func aFinalArrivingInTheNextWindowStaysWithItsSentence() {
        // The zh-CN smoke case: sentence 0's only final arrives during sentence 1 (wall 15.2 s) and
        // sentence 1's words come later; arrival windows would have given sentence 1 a negative lag.
        let events = [v(11.5, [1.0], fed: 1.4),
                      E(t: 15.2, isFinal: true, wordEnds: [1.0, 1.8, 2.3]),
                      v(15.6, [4.9], fed: 5.6),
                      E(t: 17.0, isFinal: true, wordEnds: [4.9, 5.7, 6.4])]
        let r = T10Analysis.clipLags(events: events, clips: [clip(0), clip(1)], feeds: feeds())
        #expect(r[0].completionMs == 2720)   // speech end chunk fed at 12.48, first covered at 15.2
        #expect(r[1].onsetMs == 1100)        // first word of sentence 1 at 15.6 vs onset fed at 14.5
        #expect(r[1].completionMs == 520)    // the volatile at 15.6 was fed only to 5.6 s
        #expect(r[1].identity == 1)
        #expect(T10Analysis.negative(r) == 0)
    }

    @Test func oneFinalCoveringTwoSentencesCountsForBoth() {
        let events = [E(t: 17.2, isFinal: true, wordEnds: [1.2, 2.4, 5.1, 6.3])]
        let r = T10Analysis.clipLags(events: events, clips: [clip(0), clip(1)], feeds: feeds())
        #expect(r[0].completionMs == 4720)
        #expect(r[1].completionMs == 720)
    }

    @Test func aFinalWithoutTheLastWordIsNotAHit() {
        // zh-CN splits a sentence into two finals: the first does not hold the last final word.
        let events = [E(t: 12.9, isFinal: true, wordEnds: [1.0, 1.6], units: 4), E(t: 13.5, isFinal: true, wordEnds: [2.3], units: 2)]
        let r = T10Analysis.clipLags(events: events, clips: [clip(0)], feeds: feeds())
        #expect(r[0].completionMs == 1020)
        #expect(r[0].hitIsFinal == true)
        #expect(r[0].finalUnits == 6)
    }

    @Test func aLateStartThatCatchesUpDoesNotBiasTheLag() {
        // The feeder starts 150 ms late and catches up over the first second; the speech end was
        // fed on time, so its lag is unchanged (a per-clip offset taken at the start said +150).
        let events = [E(t: 12.8, isFinal: true, wordEnds: [1.0, 2.4])]
        let r = T10Analysis.clipLags(events: events, clips: [clip(0)], feeds: feeds(late: 0.15, lateChunks: 50))
        #expect(r[0].completionMs == 320)
        #expect(abs(r[0].start - 10.15) < 1e-9)
    }

    @Test func clipWithoutFinalIsMarked() {
        let r = T10Analysis.clipLags(events: [v(17.2, [5.0, 6.2], fed: 7.2)], clips: [clip(0), clip(1)], feeds: feeds())
        #expect(r[0].completionMs == nil)
        #expect(r[0].onsetMs == nil)
        #expect(r[0].lastFromFinal == nil)
        #expect(r[1].completionMs == 720)
        #expect(r[1].lastFromFinal == false)   // left out of the ① rule
        #expect(r[1].finalUnits == nil)
    }

    @Test func aResultBeforeItsAudioIsAFault() {
        // A final "recognized" 380 ms before the speech end was fed: the clock or the attribution is wrong.
        let r = T10Analysis.clipLags(events: [E(t: 12.1, isFinal: true, wordEnds: [1.0, 2.4])], clips: [clip(0)], feeds: feeds())
        #expect(r[0].completionMs == -380)
        #expect(T10Analysis.negative(r) == 1)
    }

    @Test func causalCheckAllowsOneChunkOfRace() {
        let ok = E(t: 1, isFinal: false, wordEnds: [2.0, 2.415], fedAtReceipt: 2.4)        // ≤ fed + 20 ms
        let bad = E(t: 1, isFinal: false, wordEnds: [2.5], fedAtReceipt: 2.4)              // 100 ms ahead
        #expect(T10Analysis.causalFaults([ok]) == 0)
        #expect(T10Analysis.causalFaults([ok, bad]) == 1)
        #expect(T10Analysis.causalFaults([E(t: 1, isFinal: true, wordEnds: [9])]) == 0)    // fed unknown
    }

    @Test func theCompleteResultIsTheBatchMemberWithAllUnits() {
        // One batch (fed 2.76 s) arrives over 12 ms with growing units: the hit is its first, the
        // sentence is complete with its last.
        let events = [v(12.80, [2.76], fed: 2.76, units: 2), v(12.806, [2.76], fed: 2.76, units: 4),
                      v(12.812, [2.76], fed: 2.76, units: 5), E(t: 13.3, isFinal: true, wordEnds: [1.0, 2.4], units: 5)]
        let r = T10Analysis.clipLags(events: events, clips: [clip(0)], feeds: feeds())
        #expect(r[0].hitIndex == 0)
        #expect(r[0].completionMs == 320)
        #expect(r[0].completeIndex == 2)
        #expect(r[0].completeMs == 332)
        #expect(r[0].lateBatch == false)
    }

    @Test func aLastWordOneBatchLateIsMarked() {
        // The batch at fed 2.76 s lacks the last word; the next (fed 3.72 s) has it.
        let events = [v(12.80, [2.76], fed: 2.76, units: 3), v(13.76, [3.72], fed: 3.72, units: 4),
                      E(t: 14.0, isFinal: true, wordEnds: [1.0, 2.4], units: 4)]
        let r = T10Analysis.clipLags(events: events, clips: [clip(0), clip(1)], feeds: feeds())
        #expect(r[0].completionMs == 320)
        #expect(r[0].completeMs == 1280)
        #expect(r[0].lateBatch == true)
    }

    @Test func volatilesAfterTheNextOnsetAreNotThisSentence() {
        // Fed 4.6 s is past sentence 1's onset (4.5 s): its units belong to sentence 1.
        let events = [v(12.80, [2.76], fed: 2.76, units: 3), v(14.70, [4.6], fed: 4.6, units: 9),
                      E(t: 13.0, isFinal: true, wordEnds: [1.0, 2.4], units: 3)]
        let r = T10Analysis.clipLags(events: events, clips: [clip(0), clip(1)], feeds: feeds())
        #expect(r[0].completeIndex == 0)
        #expect(r[0].lateBatch == false)
    }

    @Test func c6InputsFromALane() {
        // Batches at fed 0.96, 1.92, 3.84 (a grid point skipped in silence); one read 20 ms late.
        let events = [v(10.97, [0.96], fed: 0.96), v(10.975, [0.96], fed: 0.96),
                      E(t: 11.93, isFinal: false, wordEnds: [1.92], fedAtReceipt: 1.94, rangeEnd: 1.92),
                      v(13.85, [3.84], fed: 3.84), E(t: 13.9, isFinal: true, wordEnds: [3.8])]
        let inp = T10Analysis.C6.inputs(events: events, lags: [], feeds: feeds(), feedStart: 10)
        // Delivery: receipt − wall of the chunk ending at the range end (wall = audio − 0.02 + 10).
        #expect(inp.delivery.map(\.ms) == [30, 35, 30, 30])
        #expect(inp.backlog.map(\.ms) == [0, 0, 20, 0])
        #expect(inp.batchGaps.map(\.ms) == [960, 1920])
    }

    /// A clean hour: delivery ~10 ms, no backlog, 960 ms batches, complete lag uniform over the
    /// grid wait, no late batches; `change` alters what starts at 30 minutes.
    func c6Hour(change: (inout (delivery: Int, backlog: Int, gap: Int, complete: Int, late: Bool), Int) -> Void = { _, _ in })
        -> T10Analysis.C6.Inputs {
        var inp = T10Analysis.C6.Inputs()
        for k in 0..<(60 * 60) {   // one batch a second
            let t = Double(k) + 0.5
            // Each 10-minute bucket holds the same 120 complete lags, 10…962 ms.
            var x = (delivery: 8 + k % 7, backlog: 0, gap: 960, complete: (k / 5 % 120) * 8 + 10, late: false)
            if t >= 1800 { change(&x, k) }
            inp.delivery.append((t, x.delivery))
            inp.backlog.append((t, x.backlog))
            inp.batchGaps.append((t, x.gap))
            if k % 5 == 0 { inp.clips.append((t, x.complete, x.late)) }
        }
        return inp
    }

    @Test func c6PassesACleanHour() {
        let r = T10Analysis.C6.evaluate(c6Hour())
        #expect(r.pass == true)
        #expect(r.failedChecks.isEmpty)
        #expect(r.buckets.count == 6)
        #expect(r.baseline?.medianBatchGap == 960)
    }

    @Test func c6CatchesEachKindOfDrift() {
        #expect(T10Analysis.C6.evaluate(c6Hour { x, _ in x.delivery += 120 }).failedChecks == ["a"])
        #expect(T10Analysis.C6.evaluate(c6Hour { x, k in if k % 100 == 0 { x.backlog = 150 } }).failedChecks == ["b"])
        #expect(T10Analysis.C6.evaluate(c6Hour { x, _ in x.gap = 1100 }).failedChecks == ["c"])
        // 15 % of sentences a batch late: d fails (and the wide guard e with it).
        let late = T10Analysis.C6.evaluate(c6Hour { x, k in if (k / 5) % 20 < 3 { x.late = true; x.complete += 960 } })
        #expect(late.failedChecks.contains("d"))
        #expect(T10Analysis.C6.evaluate(c6Hour { x, _ in x.complete += 160 }).failedChecks == ["e"])
        #expect(T10Analysis.C6.evaluate(c6Hour { x, _ in x.complete += 140 }).pass == true)
    }

    @Test func c6TooShortToJudge() {
        var inp = T10Analysis.C6.Inputs()
        for k in 0..<120 { inp.delivery.append((Double(k), 10)); inp.clips.append((Double(k), 400, false)) }
        #expect(T10Analysis.C6.evaluate(inp).pass == nil)               // 2 minutes: all warm-up
        #expect(T10Analysis.C6.evaluate(inp, bucketS: 30).pass == true) // smoke buckets
    }

    @Test func feedTableLookups() {
        let f = feeds(seconds: 1)
        #expect(f.wallForWordEnd(0.0) == nil)
        #expect(abs(f.wallForWordEnd(0.04)! - 10.02) < 1e-9)   // ends exactly at a chunk boundary: the chunk before
        #expect(abs(f.wallForOnset(0.04)! - 10.04) < 1e-9)     // starts exactly there: that chunk
        #expect(f.wallForOnset(5) == f.wall.last)
        #expect(T10Analysis.isWord("。") == false)
        #expect(T10Analysis.isWord("ok.") == true)
    }

    @Test func textUnitsCountsHanziAndWords() {
        #expect(T10Analysis.textUnits("明年的预算。") == 5)
        #expect(T10Analysis.textUnits("We measured 300 ms, roughly.") == 5)
        #expect(T10Analysis.textUnits("Q4 预算 is 30%") == 5)
        #expect(T10Analysis.textUnits("") == 0)
    }

    @Test func loadAlternatesInBlocksIdleFirst() {
        let s = (0..<40).map { T10Analysis.loaded(item: $0, block: 10) }
        #expect(s.filter { $0 }.count == 20)
        #expect(Array(s[0..<10]) == Array(repeating: false, count: 10))
        #expect(Array(s[10..<20]) == Array(repeating: true, count: 10))
        #expect(s[39] == true)
        #expect(T10Analysis.loaded(item: 5, block: 0) == false)
    }
}
