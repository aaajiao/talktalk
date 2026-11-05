import Foundation
import Testing
@testable import TalkTalkAudio
import TalkTalkCore

private func ms(_ v: Int) -> HostTime { HostTime(v) * 1_000_000 }
private func words(_ n: Int) -> String { (0..<n).map { _ in "word" }.joined(separator: " ") }

/// 24 kHz test "speech": a 220 Hz tone at about −20 dBFS, loud enough for the trims to keep.
func tone24k(_ n: Int, amp: Float = 0.14, offset: Int = 0) -> [Float] {
    (0..<n).map { amp * Float(sin(2 * Double.pi * 220 * Double($0 + offset) / 24_000)) }
}

/// Scripted fake TTS on the virtual clock: one job at a time, a 0.16 s chunk every
/// 0.16 × `rtf` s, and it only renders while bufferedAhead < the render horizon (§3.3).
final class ScriptedTTS {
    struct Job { var clause: UInt64; var job: JobID; var samples: Int; var text: String; var whole: Bool; var sent = 0; var seq = 0 }
    var jobs: [Job] = []
    var rtf = 0.25
    var horizonMs = Double(ClauseQueue.Config().renderHorizonMs)
    var epoch: UInt32 = 0
    private var nextAt: HostTime = 0
    static let chunk = 3840

    func add(clause: UInt64, job: JobID, seconds: Double, text: String, whole: Bool = false, q: ClauseQueue) {
        jobs.append(Job(clause: clause, job: job, samples: Int(seconds * 24_000), text: text, whole: whole))
        q.open(clause: clause, job: job, epoch: epoch, text: text, lang: .en, wholeClause: whole)
    }

    func tick(_ now: HostTime, _ q: ClauseQueue) {
        // The engine's horizon reads the PlayoutReport's bufferedMs (playable audio only).
        guard var j = jobs.first, now >= nextAt, Double(q.report(at: now).bufferedMs) < horizonMs else { return }
        let n = min(Self.chunk, j.samples - j.sent)
        let last = j.sent + n >= j.samples
        q.ingest(TTSChunk(job: j.job, seq: j.seq, samples24k: tone24k(n, offset: j.sent), isLast: last, producedAt: now,
                          summary: last ? TTSSummary(audioS: Double(j.samples) / 24_000, frames: 0,
                                                     timing: StageTiming(received: 0, started: 0, firstOutput: nil, finished: now)) : nil),
                 at: now)
        j.sent += n; j.seq += 1
        nextAt = now + HostTime(0.16 * rtf * 1e9)
        if last { jobs.removeFirst() } else { jobs[0] = j }
    }
}

final class Harness {
    let ring: FakePlayoutRing
    let q: ClauseQueue
    let tts = ScriptedTTS()
    var now: HostTime = 0
    var events: [(HostTime, ClauseQueue.Event)] = []
    var maxBuffered = 0.0
    var ringEvents: [PlayoutRingEvent] = []
    var feedReadsRing = true
    /// false: feedIOProc is not running at all (device stopped): ringO is neither read nor
    /// suspended, so a requested jump stays pending.
    var feedRuns = true
    var delayRingEvents = false
    private var heldRingEvents: [PlayoutRingEvent] = []

    let monitor: FakePlayoutRing?
    /// false: MonitorOutput is detached (no monitorIOProc): ringO2 is neither read nor suspended.
    var monitorRuns = true

    init(config: ClauseQueue.Config = ClauseQueue.Config(), withMonitor: Bool = false) throws {
        let r = FakePlayoutRing()
        let m = withMonitor ? FakePlayoutRing() : nil
        ring = r
        monitor = m
        q = ClauseQueue(config: config, ring: r, monitor: m, stage: try PlayoutStage())
    }

    /// Advances in 5 ms IO periods (240 frames @ 48 kHz).
    func run(untilMs end: Int, _ during: ((Harness) -> Void)? = nil) throws {
        while now < ms(end) {
            now += ms(5)
            tts.tick(now, q)
            // false: passthrough owns the feed, which suspends ringO every cycle (tt_ring_playout_suspend)
            if feedRuns { if feedReadsRing { ring.consume(240, at: now) } else { ring.suspend(at: now) } }
            if let m = monitor, monitorRuns { m.consume(240, at: now); _ = m.drainEvents() }
            var re = ring.drainEvents()
            ringEvents += re
            if delayRingEvents { swap(&re, &heldRingEvents) }  // the C reader publishes read_index first
            for e in try q.pump(at: now, ringEvents: re) {
                events.append((now, e))
                if case .cancelJob(let j) = e { tts.jobs.removeAll { $0.job == j } }   // engine stops it
            }
            maxBuffered = max(maxBuffered, q.bufferedAheadMs)
            during?(self)
        }
    }

    func times(_ match: (ClauseQueue.Event) -> Bool) -> [HostTime] { events.filter { match($0.1) }.map(\.0) }
    var played: [ClauseQueue.PlayedClause] {
        events.compactMap { if case .played(let p) = $0.1 { p } else { nil } }
    }
    func started(_ c: UInt64) -> (HostTime, Double)? {
        for (t, e) in events { if case .clauseStarted(c, let tempo, _) = e { return (t, tempo) } }
        return nil
    }
}

@Suite struct ClauseQueueTests {
    @Test func configFromPolicyProfile() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/PolicyProfile.default.json")
        let c = ClauseQueue.Config(try PolicyProfile.load(from: url))
        #expect(c.ringOAheadMs == 500 && c.interClauseGapMs == 120 && c.fastPrerollMs == 160 && c.elsePrerollMs == 320)
        #expect(c.finishClauseMaxMs == 1500 && c.clauseCutFadeMs == 30 && c.resumeAfterCloseMs == 700)
        #expect(c.slowTempo == 1.25 && c.tempoMax == 1.25)
    }

    /// §3.3: Q = 10 s, floor pause for 3 s → 0 overflows, 0 overwrites; the next clause after
    /// the resume uses the new tempo.
    @Test func q10PauseThreeSecondsNoOverflow() throws {
        let h = try Harness()
        for c in UInt64(1)...5 { h.tts.add(clause: c, job: 100 + c, seconds: 2.0, text: words(6), q: h.q) }
        try h.run(untilMs: 1000)
        h.q.setFloorPaused(true)
        h.q.nextTempo = 1.2
        let pausedAt = h.now
        try h.run(untilMs: 4000)
        let resumeAt = h.now
        h.q.setFloorPaused(false)
        try h.run(untilMs: 20_000)

        #expect(h.ring.refusedFrames == 0)                          // never overwrote unread data
        #expect(h.ring.emptyStartMarks == 0)                        // START rides on audio (review C)
        #expect(h.ring.maxAvailable <= 24_000)                      // ≤ 0.5 s ahead, far below 2 s
        #expect(h.maxBuffered <= 1500 + 160 + 500 + 50)             // horizon + 1 chunk + ringO
        #expect(h.played.map(\.clause) == [1, 2, 3, 4, 5])
        #expect(h.played.allSatisfy { !$0.incomplete })
        // Nothing starts while paused; the first clause started after the resume runs at 1.2.
        let startsDuringPause = (1...5).compactMap { h.started(UInt64($0)) }.filter { $0.0 > pausedAt && $0.0 < resumeAt }
        #expect(startsDuringPause.isEmpty)
        let after = (1...5).compactMap { h.started(UInt64($0)) }.filter { $0.0 >= resumeAt }
        #expect(!after.isEmpty && after.allSatisfy { $0.1 == 1.2 })
        #expect(h.started(1)?.1 == 1.0)
    }

    @Test func staleEpochAndCancelledJobsAreDropped() throws {
        let h = try Harness()
        h.tts.add(clause: 1, job: 1, seconds: 3, text: words(10), q: h.q)
        try h.run(untilMs: 600)
        let dropped = h.q.hardInterrupt(newEpoch: 1, at: h.now)
        #expect(dropped == [1])
        let ev = try h.q.pump(at: h.now)
        #expect(ev.contains(.cancelJob(1)))
        // A late chunk of the old job, and an open() for the old epoch, are both ignored.
        #expect(!h.q.ingest(TTSChunk(job: 1, seq: 99, samples24k: tone24k(3840), isLast: false, producedAt: h.now), at: h.now))
        h.q.open(clause: 2, job: 2, epoch: 0, text: "x y", lang: .en, wholeClause: false)
        #expect(!h.q.ingest(TTSChunk(job: 2, seq: 0, samples24k: tone24k(3840), isLast: true, producedAt: h.now), at: h.now))
        #expect(h.q.staleChunks == 2)
        #expect(h.q.currentEpoch == 1)
        h.tts.jobs.removeAll()
        let before = h.ring.output.count
        try h.run(untilMs: 700)
        // After the 30 ms fade, ringO plays silence.
        let tail = h.ring.output[(before + 1440)...]
        #expect(tail.allSatisfy { $0 == 0 })
        // The current epoch's clauses work.
        h.tts.epoch = 1
        h.tts.add(clause: 3, job: 3, seconds: 1, text: words(2), q: h.q)
        try h.run(untilMs: 3000)
        #expect(h.played.map(\.clause) == [3])
        // No START left behind by the flush: the only first_sample after it is clause 3's.
        #expect(h.ring.emptyStartMarks == 0)
        let tags = h.ringEvents.compactMap { if case .firstSample(let t, _) = $0 { t } else { nil } }
        #expect(tags == [1, 3])
    }

    /// §3.8: yield pauses at the boundary; a long clause is cut at 1.5 s with a 30 ms fade, marked
    /// incomplete; playback resumes 700 ms after the passthrough closes.
    @Test func passthroughYieldCutsAt1500AndResumesAfter700() throws {
        let h = try Harness()
        h.tts.add(clause: 1, job: 1, seconds: 6, text: words(20), q: h.q)
        h.tts.add(clause: 2, job: 2, seconds: 1, text: words(2), q: h.q)
        try h.run(untilMs: 1000)
        let req = h.now
        h.q.requestYield(at: req)
        #expect(h.q.report(at: h.now).paused)
        var cutOutputIndex = 0
        try h.run(untilMs: 3000) { hh in
            if cutOutputIndex == 0, hh.events.contains(where: { if case .cut = $0.1 { true } else { false } }) {
                cutOutputIndex = hh.ring.output.count - 240
            }
        }
        let cuts = h.times { if case .cut(1, .passthroughCut, _) = $0 { true } else { false } }
        #expect(cuts.count == 1)
        #expect(cuts[0] - req >= ms(1500) && cuts[0] - req <= ms(1505))
        // .yielded only once the 30 ms cut fade is done and ringO is parked (silent).
        let yielded = h.times { if case .yielded = $0 { true } else { false } }
        #expect(yielded.count == 1)
        #expect(yielded[0] - cuts[0] >= ms(30) && yielded[0] - cuts[0] <= ms(40), "yielded \((yielded[0] - cuts[0]) / 1_000_000) ms after the cut")
        let yIdx = Int(yielded[0] / 1_000_000) * 48                 // 48 output frames per ms
        #expect(h.ring.output[yIdx..<min(yIdx + 4800, 3000 * 48)].allSatisfy { $0 == 0 })   // nothing leaks after .yielded
        #expect(h.events.contains { $0.1 == .cancelJob(1) })
        #expect(h.played.first?.clause == 1 && h.played.first?.incomplete == true)
        // 30 ms fade: decays to zero within 1440 frames, then silence while parked.
        let fade = Array(h.ring.output[cutOutputIndex..<(cutOutputIndex + 240 + 1440)])
        let peakEarly = fade[0..<480].map(abs).max()!
        let peakLate = fade[1200..<1680].map(abs).max()!
        #expect(peakEarly > 0.05 && peakLate < peakEarly * 0.4)
        #expect(h.ring.output[(cutOutputIndex + 240 + 1440)...].allSatisfy { $0 == 0 })
        // Clause 2 is kept and waits.
        #expect(h.started(2) == nil || h.played.count == 1)
        let closeAt = h.now
        h.q.passthroughClosed(at: closeAt)
        try h.run(untilMs: 3600)
        #expect(h.times { if case .resumed = $0 { true } else { false } }.isEmpty)
        try h.run(untilMs: 6000)
        let resumed = h.times { if case .resumed = $0 { true } else { false } }
        #expect(resumed.count == 1 && resumed[0] - closeAt >= ms(700) && resumed[0] - closeAt <= ms(705))
        #expect(h.played.map(\.clause) == [1, 2])
        #expect(h.played[1].start >= resumed[0])
        #expect(!h.q.report(at: h.now).paused)
    }

    @Test func yieldAtBoundaryNeedsNoCut() throws {
        let h = try Harness()
        h.tts.add(clause: 1, job: 1, seconds: 0.8, text: words(2), q: h.q)
        h.tts.add(clause: 2, job: 2, seconds: 1, text: words(2), q: h.q)
        try h.run(untilMs: 500)
        h.q.requestYield(at: h.now)
        try h.run(untilMs: 2500)
        #expect(h.times { if case .cut = $0 { true } else { false } }.isEmpty)
        #expect(h.times { if case .yielded = $0 { true } else { false } }.count == 1)
        #expect(h.played.map(\.clause) == [1])
        h.q.resumeNow(at: h.now)                                   // new right-⌥ press
        try h.run(untilMs: 4500)
        #expect(h.played.map(\.clause) == [1, 2])
    }

    /// §3.6: after a coreaudiod restart ringO is empty, the playing clause is incomplete and only
    /// audio produced ≤ 1 s before the restart is kept; older rendered clauses are re-rendered,
    /// and so is every clause after one (review 3: C must not play before the re-rendered B).
    @Test func coreaudiodRestartKeepsAtMostOneSecond() throws {
        let h = try Harness()
        h.tts.horizonMs = 100_000                                  // let B render early
        h.tts.rtf = 0.05
        h.tts.add(clause: 1, job: 1, seconds: 6, text: words(20), q: h.q)
        h.tts.add(clause: 2, job: 2, seconds: 1, text: words(2), q: h.q)
        try h.run(untilMs: 2500)                                    // A and B rendered by ≈ 0.4 s
        h.tts.add(clause: 3, job: 3, seconds: 0.5, text: words(1), q: h.q)
        try h.run(untilMs: 3000)                                    // C rendered at ≈ 2.5 s
        let t = h.now
        h.q.audioServiceRestarted(at: t)
        #expect(h.ring.availableFrames == 0)                        // ringO emptied at the restart
        let ev = try h.q.pump(at: t)
        #expect(ev.contains(.cut(clause: 1, reason: .audioRestart, at: t)))
        let rer = ev.compactMap { if case .rerender(let c, _) = $0 { c } else { nil } }
        #expect(rer == [2, 3])                                      // C's audio is recent but follows B
        #expect(h.q.clauseCount == 0)
        try h.run(untilMs: 5000)
        #expect(h.played.isEmpty)
        #expect(h.ring.availableFrames == 0)                        // nothing refilled

        // Only recent audio and nothing re-rendered before it: kept.
        let g = try Harness()
        g.tts.horizonMs = 100_000
        g.tts.rtf = 0.05
        g.tts.add(clause: 1, job: 1, seconds: 6, text: words(20), q: g.q)
        try g.run(untilMs: 2500)
        g.tts.add(clause: 3, job: 3, seconds: 0.5, text: words(1), q: g.q)
        try g.run(untilMs: 3000)
        g.q.audioServiceRestarted(at: g.now)
        let ev2 = try g.q.pump(at: g.now)
        #expect(!ev2.contains { if case .rerender = $0 { true } else { false } })
        #expect(g.q.clauseCount == 1)
        #expect(g.q.heldProducedAt.allSatisfy { $0 >= g.now - ms(1000) })
        try g.run(untilMs: 5000)
        #expect(g.played.map(\.clause) == [3])
    }

    /// played.start is the arrival of the clause's first sample (out.first_sample), and the
    /// clause tags in ringO are the 32-bit truncation of the clause ID.
    @Test func playStartComesFromFirstSampleEvent() throws {
        let h = try Harness()
        let big: UInt64 = (7 << 32) | 5
        h.tts.add(clause: big, job: 1, seconds: 0.6, text: words(2), q: h.q)
        try h.run(untilMs: 2000)
        let first = h.ringEvents.compactMap { if case .firstSample(let tag, let at) = $0 { (tag, at) } else { nil } }
        #expect(first.count == 1 && first[0].0 == 5)
        #expect(h.played.map(\.clause) == [big])
        #expect(h.played.first?.start == first.first?.1)
    }

    /// The read index moves one pump before out.first_sample arrives: played.start is still the
    /// event's time, not the read-position estimate (review D).
    @Test func playStartPrefersTheLateFirstSampleEvent() throws {
        let h = try Harness()
        h.delayRingEvents = true
        h.tts.add(clause: 1, job: 1, seconds: 0.6, text: words(2), q: h.q)
        h.tts.add(clause: 2, job: 2, seconds: 0.6, text: words(2), q: h.q)
        try h.run(untilMs: 3000)
        let first = h.ringEvents.compactMap { if case .firstSample(let tag, let at) = $0 { (UInt64(tag), at) } else { nil } }
        #expect(h.played.map(\.clause) == [1, 2])
        for p in h.played { #expect(p.start == first.first { $0.0 == p.clause }?.1, "clause \(p.clause)") }
    }

    /// A batch whose cut (earlier) comes after the next clause's first sample: ClauseQueue
    /// applies events in time order (review E). feedIOProc now pushes them in output order
    /// (rt-core b3b74f9), so this only guards against an out-of-order batch.
    @Test func cutBeforeNextFirstSampleInOneBatch() throws {
        let h = try Harness()
        h.feedReadsRing = false
        h.tts.add(clause: 1, job: 1, seconds: 0.1, text: words(1), q: h.q)
        h.tts.add(clause: 2, job: 2, seconds: 0.1, text: words(1), q: h.q)
        try h.run(untilMs: 1500)
        _ = try h.q.pump(at: h.now, ringEvents: [.firstSample(tag: 1, at: h.now)])
        #expect(h.q.playingClause == 1)
        h.now += ms(5)
        _ = try h.q.pump(at: h.now, ringEvents: [.firstSample(tag: 2, at: h.now + ms(2)),
                                                 .clauseCut(tag: 1, skipped: 100, at: h.now)])
        #expect(h.q.playingClause == 2)
    }

    /// drainable (review F): what preroll or whole-clause mode holds back is not drainable;
    /// bufferedAhead still counts it.
    @Test func drainableExcludesPrerollHold() throws {
        let h = try Harness()
        h.feedReadsRing = false
        h.q.open(clause: 1, job: 1, epoch: 0, text: words(4), lang: .en, wholeClause: false)
        func chunk(_ seq: Int, _ n: Int, last: Bool = false) {
            h.q.ingest(TTSChunk(job: 1, seq: seq, samples24k: tone24k(n, offset: seq * 2400), isLast: last, producedAt: h.now),
                       at: h.now)
        }
        chunk(0, 2400)                                           // 100 ms < the 320 ms preroll
        _ = try h.q.pump(at: h.now)
        #expect(h.q.bufferedAheadMs > 90)
        #expect(h.q.drainableMs == 0)
        chunk(1, 2400); chunk(2, 2400); chunk(3, 2400)           // 400 ms: starts
        _ = try h.q.pump(at: h.now)
        #expect(h.q.drainableMs > 350)
        #expect(abs(Double(h.q.drainableMs) - h.q.bufferedAheadMs) <= 1)
    }

    @Test func drainableExcludesWholeClauseHoldAndLaterClauses() throws {
        let h = try Harness()
        h.feedReadsRing = false
        h.tts.rtf = 1.0
        h.tts.add(clause: 1, job: 1, seconds: 1, text: words(3), whole: true, q: h.q)   // < 1.5 s: whole
        try h.run(untilMs: 600)                                  // streaming, not done
        #expect(h.q.bufferedAheadMs > 300)
        #expect(h.q.drainableMs == 0)
        try h.run(untilMs: 1600)                                 // done: starts, everything moves
        #expect(h.q.drainableMs > 900)
        #expect(abs(Double(h.q.drainableMs) - h.q.bufferedAheadMs) <= 1)

        // A clause still streaming blocks the one after it, even when that one is complete.
        let g = try Harness()
        g.feedReadsRing = false
        g.q.open(clause: 1, job: 1, epoch: 0, text: words(4), lang: .en, wholeClause: false)
        g.q.open(clause: 2, job: 2, epoch: 0, text: words(1), lang: .en, wholeClause: false)
        g.q.ingest(TTSChunk(job: 2, seq: 0, samples24k: tone24k(4800), isLast: true, producedAt: 0), at: 0)
        g.q.ingest(TTSChunk(job: 1, seq: 0, samples24k: tone24k(12_000), isLast: false, producedAt: 0), at: 0)
        _ = try g.q.pump(at: 0)
        let all = g.q.bufferedAheadMs
        #expect(all > 650)
        #expect(Double(g.q.drainableMs) < all - 190)             // clause 2's 200 ms is not drainable
        #expect(g.q.drainableMs > 400)
    }

    /// Review G: a stream that fails before anything reached ringO is discarded, so the resend
    /// with the same clauseID opens it again and it plays once, whole.
    @Test func streamFailedBeforeRingODiscardsForResend() throws {
        let h = try Harness()
        h.q.open(clause: 1, job: 1, epoch: 0, text: words(4), lang: .en, wholeClause: false)
        h.q.ingest(TTSChunk(job: 1, seq: 0, samples24k: tone24k(2400), isLast: false, producedAt: 0), at: 0)  // < preroll
        try h.run(untilMs: 100)
        #expect(h.q.streamFailed(job: 1, at: h.now) == .discarded(clauses: [1]))
        #expect(h.q.clauseCount == 0 && h.q.bufferedAheadMs == 0)
        #expect(h.q.streamFailed(job: 1, at: h.now) == .unknown)
        h.tts.add(clause: 1, job: 2, seconds: 0.6, text: words(4), q: h.q)       // the resend
        try h.run(untilMs: 2000)
        #expect(h.played.map(\.clause) == [1])
        #expect(h.played.first?.incomplete == false)
        let firsts = h.events.filter { if case .firstSampleEnqueued = $0.1 { true } else { false } }
        #expect(firsts.count == 1)
    }

    /// A stream that fails after its first sample is in ringO: what arrived plays out, the clause
    /// ends there and `.played` says incomplete; the queue moves on to the next clause.
    @Test func streamFailedAfterFirstSamplePlaysOut() throws {
        let h = try Harness()
        h.tts.rtf = 1.0
        h.tts.add(clause: 1, job: 1, seconds: 3, text: words(10), q: h.q)
        h.tts.add(clause: 2, job: 2, seconds: 0.5, text: words(2), q: h.q)
        var r: ClauseQueue.StreamFailure?
        try h.run(untilMs: 4000) { hh in
            if r == nil, hh.now >= ms(800) {
                r = hh.q.streamFailed(job: 1, at: hh.now)
                hh.tts.jobs.removeAll { $0.job == 1 }                              // the stream is gone
            }
        }
        #expect(r == .playsOut(clause: 1))
        #expect(h.played.map(\.clause) == [1, 2])
        #expect(h.played.first?.incomplete == true)
        #expect(h.played.last?.incomplete == false)
        #expect(h.q.clauseCount == 0)
    }

    /// Review H: a tail with no samples whose summary says runaway or echo (the engine's last
    /// attempt failed before release) is a failure: no START, no gap, no firstSampleEnqueued; the
    /// next clause plays as if it were not there.
    @Test(arguments: [(true, 0, ClauseLedger.Reason.runaway), (false, 2, .echo)])
    func zeroAudioTailIsRenderFailed(runaway: Bool, echo: Int, reason: ClauseLedger.Reason) throws {
        let h = try Harness()
        h.q.open(clause: 1, job: 1, epoch: 0, text: words(2), lang: .en, wholeClause: true)
        h.q.ingest(TTSChunk(job: 1, seq: 0, samples24k: [], isLast: true, producedAt: 0,
                            summary: TTSSummary(audioS: 0, frames: 0, runaway: runaway, echoAborts: echo, attempts: 3,
                                                timing: StageTiming(received: 0, started: 0, firstOutput: nil, finished: 0))),
                   at: 0)
        try h.run(untilMs: 200)
        #expect(h.events.map(\.1) == [.renderFailed(clause: 1, job: 1, reason: reason)])
        #expect(h.ring.writtenFrames == 0)
        #expect(h.q.clauseCount == 0)
        h.tts.add(clause: 2, job: 2, seconds: 0.5, text: words(2), q: h.q)
        try h.run(untilMs: 2000)
        #expect(h.played.map(\.clause) == [2])
        let firsts = h.events.compactMap { if case .firstSampleEnqueued(let c, _, _) = $0.1 { c } else { nil } }
        #expect(firsts == [2])
    }

    /// Review 3: a stream that fails before anything reached ringO takes every later clause with
    /// it, so the resends go out oldest first and play in order.
    @Test func discardTakesLaterClausesAlong() throws {
        let h = try Harness()
        h.feedReadsRing = false
        for c in UInt64(1)...3 { h.q.open(clause: c, job: JobID(c), epoch: 0, text: words(2), lang: .en, wholeClause: false) }
        h.q.ingest(TTSChunk(job: 1, seq: 0, samples24k: tone24k(2400), isLast: false, producedAt: 0), at: 0)   // < preroll
        h.q.ingest(TTSChunk(job: 2, seq: 0, samples24k: tone24k(4800), isLast: true, producedAt: 0), at: 0)
        h.q.ingest(TTSChunk(job: 3, seq: 0, samples24k: tone24k(2400), isLast: false, producedAt: 0), at: 0)
        try h.run(untilMs: 50)
        #expect(h.q.streamFailed(job: 1, at: h.now) == .discarded(clauses: [1, 2, 3]))
        let ev = try h.q.pump(at: h.now)
        #expect(ev == [.cancelJob(3)])                              // 2 was complete, 1 is the failed one
        #expect(h.q.clauseCount == 0 && h.ring.writtenFrames == 0)
    }

    /// Review 1: the 1.5 s cut while the feed is in underrun with ringO empty: the reader never
    /// parks there, but ringO is silent, so .yielded comes once the jump is done.
    @Test func cutDuringEmptyUnderrunYields() throws {
        let h = try Harness()
        h.q.open(clause: 1, job: 1, epoch: 0, text: words(8), lang: .en, wholeClause: false)
        h.q.ingest(TTSChunk(job: 1, seq: 0, samples24k: tone24k(9600), isLast: false, producedAt: 0), at: 0)
        try h.run(untilMs: 1000)                                    // 400 ms played, then starved
        #expect(h.ring.playoutState == .underrun && h.ring.availableFrames == 0)
        h.q.requestYield(at: h.now)
        try h.run(untilMs: 2700)
        let cut = h.times { if case .cut = $0 { true } else { false } }
        let yielded = h.times { if case .yielded = $0 { true } else { false } }
        #expect(cut.count == 1 && yielded.count == 1)
        if let c = cut.first, let y = yielded.first { #expect(y >= c && y - c <= ms(20)) }
    }

    /// Review 5: a new open inside the 700 ms resume window goes back to waiting and sends
    /// .yielded again (the gate waits for it), still without playing anything in between.
    @Test func reopenDuringResumeWindowYieldsAgain() throws {
        let h = try Harness()
        h.tts.add(clause: 1, job: 1, seconds: 0.4, text: words(2), q: h.q)
        h.tts.add(clause: 2, job: 2, seconds: 1, text: words(3), q: h.q)
        try h.run(untilMs: 300)
        h.q.requestYield(at: h.now)
        try h.run(untilMs: 1200)
        #expect(h.times { if case .yielded = $0 { true } else { false } }.count == 1)
        h.q.passthroughClosed(at: h.now)
        try h.run(untilMs: 1500)                                    // inside the 700 ms window
        let written = h.ring.writtenFrames
        h.q.requestYield(at: h.now)
        try h.run(untilMs: 1600)
        #expect(h.times { if case .yielded = $0 { true } else { false } }.count == 2)
        #expect(h.times { if case .resumed = $0 { true } else { false } }.isEmpty)
        #expect(h.ring.writtenFrames == written)                    // clause 2 has not started
    }

    /// Review 2: after an underrun the feed holds what ringO has until its rebuffer threshold;
    /// that audio is neither drainable nor in the reported bufferedMs (the engine's horizon).
    @Test func audioHeldByTheFeedAfterUnderrunIsNotPlayable() throws {
        let h = try Harness()
        h.q.open(clause: 1, job: 1, epoch: 0, text: words(8), lang: .en, wholeClause: false)
        h.q.ingest(TTSChunk(job: 1, seq: 0, samples24k: tone24k(9600), isLast: false, producedAt: 0), at: 0)
        try h.run(untilMs: 1000)
        #expect(h.ring.playoutState == .underrun)
        h.q.ingest(TTSChunk(job: 1, seq: 1, samples24k: tone24k(1920, offset: 9600), isLast: false, producedAt: h.now), at: h.now)
        try h.run(untilMs: 1100)                                    // 80 ms in, below the 80 ms + 5 ms threshold
        #expect(h.ring.playoutState == .underrun && h.ring.availableFrames > 1000)
        #expect(h.q.bufferedAheadMs > 20)
        #expect(h.q.drainableMs == 0)
        #expect(h.q.report(at: h.now).bufferedMs == 0)
        h.q.setFeedResumeFrames(480)                                // what the feed would use now
        #expect(h.q.drainableMs > 20)
    }

    /// A hard interrupt supersedes the pending 1.5 s NEXT_START cut with WRITE_INDEX. Its
    /// target is the write index at the interrupt, so new-epoch audio may be written while the
    /// feed is stopped and must survive when the consumer eventually applies the flush.
    @Test func hardInterruptDuringPendingCutKeepsNewEpochAudio() throws {
        let h = try Harness()
        h.tts.rtf = 1.05                                          // ringO stays short: room while pending
        h.tts.add(clause: 1, job: 1, seconds: 6, text: words(20), q: h.q)
        try h.run(untilMs: 1000)
        h.q.requestYield(at: h.now)
        var interrupted = false
        var heldAt: UInt64?
        var heldTicks = 0
        try h.run(untilMs: 3200) { hh in
            if !interrupted, hh.events.contains(where: { if case .cut = $0.1 { true } else { false } }) {
                interrupted = true
                hh.feedRuns = false                               // the cut stays pending
                #expect(hh.ring.jumpPending)
                hh.q.hardInterrupt(newEpoch: 1, at: hh.now)       // flush replaces the pending cut
                hh.q.resumeNow(at: hh.now)
                hh.tts.epoch = 1
                hh.tts.rtf = 0.1
                hh.tts.add(clause: 3, job: 3, seconds: 1, text: words(2), q: hh.q)
                heldAt = hh.ring.writtenFrames
            } else if let w = heldAt {
                // The accepted flush keeps its target even as the producer adds new audio.
                #expect(hh.ring.jumpPending && hh.ring.writtenFrames >= w)
                heldTicks += 1
            }
        }
        #expect(interrupted)
        #expect(heldTicks > 20 && h.q.bufferedAheadMs > 300)
        #expect(h.ring.writtenFrames > (heldAt ?? 0))             // new audio is already behind the flush target
        #expect(h.started(3) != nil)
        h.feedRuns = true
        let resumedAt = h.ring.output.count
        try h.run(untilMs: 5000)
        #expect(h.played.last?.clause == 3 && h.played.last?.incomplete == false)
        // The flush removes only the old epoch; clause 3 is heard in full (1 s = 48 000 frames).
        let audible = h.ring.output[resumedAt...].filter { abs($0) > 1e-4 }.count
        #expect(audible >= 46_000, "clause 3 audible frames \(audible)")
    }

    /// ringO2 (self-listen) mirrors the pause and the 1.5 s cut (tt_ioproc_monitor.h).
    @Test func monitorMirrorsPauseAndCut() throws {
        let h = try Harness(withMonitor: true)
        h.q.setMonitorEnabled(true)
        h.tts.add(clause: 1, job: 1, seconds: 6, text: words(20), q: h.q)
        h.tts.add(clause: 2, job: 2, seconds: 1, text: words(2), q: h.q)
        try h.run(untilMs: 1000)
        let m = try #require(h.monitor)
        #expect(m.output.contains { abs($0) > 0.01 })               // self-listen is playing
        h.q.requestYield(at: h.now)
        try h.run(untilMs: 2600)                                    // cut at 2.5 s + fade
        #expect(m.isParked)
        let from = 2560 * 48
        #expect(m.output[from...].allSatisfy { $0 == 0 })
        // A floor pause set while self-listen is off reaches ringO2 when it is turned on.
        let g = try Harness(withMonitor: true)
        g.q.setFloorPaused(true)
        g.q.setMonitorEnabled(true)
        try g.run(untilMs: 50)
        #expect(g.monitor!.isParked && g.ring.isParked)
    }

    /// Self-listen off mid-clause while MonitorOutput detaches: ringO2's unread tail (up to
    /// ringOAheadMs) is flushed, so it does not play first at the next attachment. Monitor audio
    /// written after the re-enable waits for the flush and is all kept.
    @Test func monitorDisableFlushesTheUnreadTail() throws {
        let h = try Harness(withMonitor: true)
        let m = try #require(h.monitor)
        h.q.setMonitorEnabled(true)
        h.tts.add(clause: 1, job: 1, seconds: 4, text: words(12), q: h.q)
        try h.run(untilMs: 1000)
        #expect(m.availableFrames > 12_000)                         // a tail is waiting in ringO2
        h.monitorRuns = false                                       // route change: detached first
        h.q.setMonitorEnabled(false)
        let w0 = m.writtenFrames
        #expect(m.jumpPending)                                      // flush accepted, reader stopped
        try h.run(untilMs: 1300)
        #expect(m.writtenFrames == w0)
        h.q.setMonitorEnabled(true)
        let r1 = h.ring.writtenFrames
        try h.run(untilMs: 1350)                                    // still detached: writes wait
        #expect(m.writtenFrames == w0 && m.jumpPending)
        m.suspend(at: h.now)                                        // new monitor ctx's first cycle
        _ = m.drainEvents()
        #expect(!m.jumpPending)
        #expect(m.writtenFrames - UInt64(m.availableFrames) >= w0)  // read index past the old tail
        h.monitorRuns = true
        try h.run(untilMs: 1355)                                    // the next pump writes the backlog
        #expect(m.writtenFrames - UInt64(m.availableFrames) >= w0)
        try h.run(untilMs: 2000)
        #expect(m.writtenFrames - w0 == h.ring.writtenFrames - r1)  // nothing dropped after re-enable
        #expect(m.output.suffix(240 * 20).contains { abs($0) > 0.01 })   // self-listen plays again
    }

    /// Disabling self-listen supersedes a pending NEXT_START with WRITE_INDEX. New monitor
    /// audio waits in the queue backlog until the consumer applies that flush, then survives.
    @Test func refusedMonitorFlushIsRetriedWithoutTakingNewAudio() throws {
        let h = try Harness(withMonitor: true)
        let m = try #require(h.monitor)
        h.q.setMonitorEnabled(true)
        h.tts.add(clause: 1, job: 1, seconds: 1.2, text: words(4), q: h.q)
        h.tts.add(clause: 2, job: 2, seconds: 3, text: words(9), q: h.q)
        try h.run(untilMs: 1300)                                    // ringO2 holds clause 2's START
        h.monitorRuns = false
        #expect(m.requestJump(.nextStart))                          // an earlier cut, left pending
        h.q.setMonitorEnabled(false)
        let w0 = m.writtenFrames
        #expect(m.jumpPending)                                      // WRITE_INDEX has superseded the cut
        try h.run(untilMs: 1400)
        h.q.setMonitorEnabled(true)
        let r1 = h.ring.writtenFrames
        try h.run(untilMs: 1450)
        #expect(m.writtenFrames == w0)                              // accepted flush pending: mirror writes wait
        m.suspend(at: h.now)                                        // attach applies WRITE_INDEX directly
        _ = m.drainEvents()
        #expect(!m.jumpPending && m.availableFrames == 0)           // no pre-disable tail remains
        try h.run(untilMs: 1455)                                    // pump releases the new-audio backlog
        #expect(!m.jumpPending && m.writtenFrames > w0)
        #expect(m.writtenFrames - UInt64(m.availableFrames) == w0) // only post-enable audio is readable
        h.monitorRuns = true
        try h.run(untilMs: 1460)                                    // new audio may play immediately
        #expect(m.writtenFrames - UInt64(m.availableFrames) >= w0)
        try h.run(untilMs: 2500)
        #expect(m.writtenFrames - w0 == h.ring.writtenFrames - r1)  // nothing dropped after re-enable
        #expect(m.output.suffix(240 * 20).contains { abs($0) > 0.01 })
    }

    @Test func disablingAgainDiscardsAudioQueuedBehindAnUnfinishedMonitorFlush() throws {
        let h = try Harness(withMonitor: true)
        let m = try #require(h.monitor)
        h.q.setMonitorEnabled(true)
        h.tts.add(clause: 1, job: 1, seconds: 4, text: words(12), q: h.q)
        try h.run(untilMs: 1000)
        h.monitorRuns = false
        h.q.setMonitorEnabled(false)
        h.q.setMonitorEnabled(true)
        try h.run(untilMs: 1100) // new mirror samples wait behind the unfinished flush
        let written = m.writtenFrames
        h.q.setMonitorEnabled(false)
        m.suspend(at: h.now)
        try h.run(untilMs: 1200)
        #expect(m.writtenFrames == written)
        #expect(m.availableFrames == 0)
    }

    /// Teardown flushes app-scoped ringO2 even when NEXT_START is pending. The next queue's
    /// first turn-on can flush again without leaving any audio from the previous meeting.
    @Test func teardownFlushAndTheNextQueueOnTheSameMonitor() throws {
        let h = try Harness(withMonitor: true)
        let m = try #require(h.monitor)
        h.q.setMonitorEnabled(true)
        h.tts.add(clause: 1, job: 1, seconds: 4, text: words(12), q: h.q)
        try h.run(untilMs: 1000)
        h.monitorRuns = false
        h.q.teardown()
        #expect(m.jumpPending)
        m.suspend(at: h.now); _ = m.drainEvents()
        #expect(m.availableFrames == 0)

        let g = try Harness(withMonitor: true)
        let m2 = try #require(g.monitor)
        g.q.setMonitorEnabled(true)
        g.tts.add(clause: 1, job: 1, seconds: 1.2, text: words(4), q: g.q)
        g.tts.add(clause: 2, job: 2, seconds: 3, text: words(9), q: g.q)
        try g.run(untilMs: 1300)                                    // ringO2 holds clause 2's START
        g.monitorRuns = false
        #expect(m2.requestJump(.nextStart))
        let w0 = m2.writtenFrames
        g.q.teardown()                                              // WRITE_INDEX supersedes the cut
        m2.suspend(at: g.now); _ = m2.drainEvents()
        #expect(!m2.jumpPending && m2.availableFrames == 0)          // old tail was flushed at teardown
        let q2 = ClauseQueue(ring: FakePlayoutRing(), monitor: m2, stage: try PlayoutStage())
        q2.setMonitorEnabled(true)
        #expect(m2.jumpPending)
        m2.suspend(at: g.now)
        #expect(m2.writtenFrames - UInt64(m2.availableFrames) >= w0 && m2.availableFrames == 0)
    }

    @Test func prerollAdaptsToRTF() throws {
        let fast = try Harness()
        fast.tts.rtf = 0.25
        fast.tts.add(clause: 1, job: 1, seconds: 2, text: words(6), q: fast.q)
        fast.tts.add(clause: 2, job: 2, seconds: 2, text: words(6), q: fast.q)
        try fast.run(untilMs: 6000)
        #expect(fast.q.currentPrerollMs == 160)
        let slow = try Harness()
        slow.tts.rtf = 0.8
        slow.tts.add(clause: 1, job: 1, seconds: 2, text: words(6), q: slow.q)
        try slow.run(untilMs: 400)
        #expect(slow.q.currentPrerollMs == 320)
        // First clause of a session (no RTF history) waits for 320 ms of audio.
        let firstStart = slow.started(1)!.0
        #expect(firstStart >= ms(Int(0.16 * 0.8 * 1000)))
        var floors = ClauseQueue.PrerollFloors(); floors.degraded = true
        fast.q.prerollFloors = floors
        #expect(fast.q.currentPrerollMs == 640)
    }

    @Test func wholeClauseWaitsForIsLast() throws {
        let h = try Harness()
        h.tts.rtf = 1.0
        h.tts.add(clause: 1, job: 1, seconds: 0.9, text: words(2), whole: true, q: h.q)
        try h.run(untilMs: 800)
        #expect(h.started(1) == nil)                                // 6 chunks at 160 ms: last at 0.8+
        try h.run(untilMs: 2500)
        #expect(h.started(1) != nil && h.played.map(\.clause) == [1])
    }

    @Test func slowRenderRaisesTempoForTheRest() throws {
        let h = try Harness()
        // expected(1 word) ≈ 0.77 s; 3 s of audio → slow while streaming.
        h.tts.add(clause: 1, job: 1, seconds: 3, text: words(1), q: h.q)
        try h.run(untilMs: 5000)
        #expect(h.played.map(\.clause) == [1])
        #expect(h.started(1)?.1 == 1.0)                             // not slow yet when it started
        let p = h.played[0]
        #expect(p.end - p.start < ms(2900))                         // the rest ran at 1.25
        #expect(h.q.report(at: h.now).tempo == 1.0)                 // the next clause is back to base
    }

    @Test func reportAndDrainEstimate() throws {
        let h = try Harness()
        h.tts.add(clause: 1, job: 1, seconds: 1, text: words(2), q: h.q)
        h.q.setFloorPaused(true)                                     // keep it from starting
        try h.run(untilMs: 400)
        let r = h.q.report(at: h.now)
        #expect(abs(Double(r.bufferedMs) - 1000) <= 1)
        #expect(r.paused && r.tempo == 1 && r.epoch == 0 && r.job == 1)
        let d = h.q.drainEstimate()
        #expect(abs(d.renderedMs - 1000) <= 1 && d.unrenderedExpectedMs == 0)
    }

    @Test func playedEventsCarryTextAndTimes() throws {
        let h = try Harness()
        h.tts.add(clause: 1, job: 1, seconds: 1, text: "one two", q: h.q)
        h.tts.add(clause: 2, job: 2, seconds: 1, text: "three four", q: h.q)
        try h.run(untilMs: 4000)
        let p = h.played
        #expect(p.map(\.text) == ["one two", "three four"])
        // ≈ 1 s each (plus the 120 ms gap, the limiter flush and the 60 ms tail keep at most)
        for x in p { #expect(x.end > x.start && x.end - x.start >= ms(950) && x.end - x.start <= ms(1250)) }
        #expect(p[1].start >= p[0].end)
        let first = h.times { if case .firstSampleEnqueued(1, _, _) = $0 { true } else { false } }
        #expect(first.count == 1)
    }

    /// The fake TTS can also be an AsyncThrowingStream (the TTSEngine.speak shape).
    @Test func asyncStreamFakeTTS() async throws {
        let h = try Harness()
        let stream = AsyncThrowingStream<TTSChunk, any Error> { c in
            for i in 0..<5 {
                c.yield(TTSChunk(job: 9, seq: i, samples24k: tone24k(3840, offset: i * 3840), isLast: i == 4,
                                 producedAt: ms(40 * (i + 1))))
            }
            c.finish()
        }
        h.q.open(clause: 9, job: 9, epoch: 0, text: words(3), lang: .en, wholeClause: false)
        var chunks: [TTSChunk] = []
        for try await c in stream { chunks.append(c) }
        try h.run(untilMs: 0)
        for c in chunks {
            while h.now < c.producedAt { try h.run(untilMs: Int(h.now / 1_000_000) + 5) }
            #expect(h.q.ingest(c, at: c.producedAt))
        }
        try h.run(untilMs: 2000)
        #expect(h.played.map(\.clause) == [9])
    }
}
