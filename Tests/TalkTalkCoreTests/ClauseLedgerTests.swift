import Foundation
import Synchronization
import Testing
@testable import TalkTalkCore

// File-private helpers: every suite keeps its own (internal ones would clash across files).
private func ms(_ v: Int) -> HostTime { HostTime(v) * 1_000_000 }

/// Deterministic generator for the property test.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class RecordingSink: ClauseStateSink, @unchecked Sendable {
    struct E: Equatable { var clause: UInt64; var state: ClauseLedger.State; var reason: ClauseLedger.Reason? }
    private let m = Mutex<[E]>([])
    var events: [E] { m.withLock { $0 } }
    func clauseState(clause: UInt64, press: UInt64, state: ClauseLedger.State, reason: ClauseLedger.Reason?,
                     attempts: Int, at: HostTime) {
        m.withLock { $0.append(E(clause: clause, state: state, reason: reason)) }
    }
}


@Suite struct ClauseLedgerTests {
    static let h = VoiceHandle(profileID: UUID(), conditioningKey: "k", mode: .icl,
                               model: EngineID(name: "tts", revision: "r", placement: .engineGPU))

    func ready(_ l: inout ClauseLedger, _ c: UInt64, press: UInt64 = 1, at t: HostTime) {
        l.commit(c, press: press, at: t)
        l.advance(c, to: .asrDone, at: t)
        l.advance(c, to: .mtDone, at: t)
    }

    @Test func mainPathAndSink() {
        let sink = RecordingSink()
        var l = ClauseLedger(sink: sink)
        ready(&l, 1, at: ms(0))
        let v0 = l.requestTTS(1, job: 10, clone: .ready(Self.h), at: ms(10))
        #expect(v0 == .send(.clone(Self.h)))
        #expect(l.accepts(1, job: 10))
        l.firstSampleEnqueued(1, job: 10, at: ms(200))
        l.streamFinished(1, job: 10)
        l.played(1, at: ms(900))
        #expect(sink.events.map(\.state) == [.committed, .asrDone, .mtDone, .ttsRequested, .firstSampleEnqueued, .played])
        let again = l.advance(1, to: .mtDone, at: ms(1000))
        #expect(!again)     // terminal never moves
    }

    /// Invariant 1: a crash after the first sample → incomplete, never resent.
    @Test func noRepeatAfterFirstSample() {
        var l = ClauseLedger()
        ready(&l, 1, at: 0)
        _ = l.requestTTS(1, job: 10, clone: .ready(Self.h), at: ms(0))
        l.firstSampleEnqueued(1, job: 10, at: ms(150))
        l.engineLost(at: ms(400))
        #expect(l.state(1) == .incomplete)
        let v1 = l.engineReady(at: ms(1400))
        #expect(v1 == [])
        let v2 = l.requestTTS(1, job: 11, clone: .ready(Self.h), at: ms(1500))
        #expect(v2 == .refuse(.engineLost))
        #expect(!l.accepts(1, job: 10))
    }

    /// A clause fully rendered before the crash keeps playing and ends `played`.
    @Test func renderedClauseSurvivesCrash() {
        var l = ClauseLedger()
        ready(&l, 1, at: 0)
        _ = l.requestTTS(1, job: 10, clone: .ready(Self.h), at: ms(0))
        l.firstSampleEnqueued(1, job: 10, at: ms(150))
        l.streamFinished(1, job: 10)
        l.engineLost(at: ms(400))
        l.played(1, at: ms(2000))
        #expect(l.state(1) == .played)
    }

    /// Invariant 2: waiting clauses are resent with the same clause ID within the window.
    @Test func resendSameClauseWithinWindow() {
        var l = ClauseLedger()
        ready(&l, 1, at: 0); ready(&l, 2, at: 0)
        _ = l.requestTTS(1, job: 10, clone: .ready(Self.h), at: ms(0))
        l.engineLost(at: ms(100))
        let v3 = l.requestTTS(2, job: 11, clone: .down, at: ms(200))
        #expect(v3 == .wait)
        l.tick(at: ms(4000))
        let v4 = l.engineReady(at: ms(4900))
        #expect(v4 == [1])          // 2 is still mtDone in TTSQueue
        let v5 = l.requestTTS(1, job: 12, clone: .ready(Self.h), at: ms(4900))
        #expect(v5 == .send(.clone(Self.h)))
        let v6 = l.requestTTS(2, job: 13, clone: .ready(Self.h), at: ms(4900))
        #expect(v6 == .send(.clone(Self.h)))
        #expect(!l.accepts(1, job: 10))      // the broken job's late chunks are stale
        #expect(l.accepts(1, job: 12))
        #expect(l.row(1)?.attempts == 2)
    }

    @Test func pressGivesUpAfterWindow() {
        var l = ClauseLedger()
        ready(&l, 1, at: 0)
        l.commit(2, press: 1, at: 0)                       // still in ASR
        _ = l.requestTTS(1, job: 10, clone: .ready(Self.h), at: ms(0))
        l.engineLost(at: ms(100))
        let v7 = l.tick(at: ms(5200))
        #expect(v7 == [1])
        #expect(l.state(1) == .dropped && l.row(1)?.reason == .voiceUnavailable)
        #expect(l.isVoiceless(press: 1))
        l.advance(2, to: .asrDone, at: ms(5300)); l.advance(2, to: .mtDone, at: ms(5400))
        let v8 = l.engineReady(at: ms(6000))
        #expect(v8 == [])
        // Engine is back, but this press stays silent (HUD shows the text).
        let v9 = l.requestTTS(2, job: 11, clone: .ready(Self.h), at: ms(6000))
        #expect(v9 == .refuse(.voiceUnavailable))
        // The next press uses the clone again.
        ready(&l, 3, press: 2, at: ms(7000))
        let v10 = l.requestTTS(3, job: 12, clone: .ready(Self.h), at: ms(7000))
        #expect(v10 == .send(.clone(Self.h)))
    }

    /// Decision 5 = silent: a press after the clone engine has been down past the window says nothing.
    @Test func decision5SilentWhenEngineNeverReturns() {
        var l = ClauseLedger(config: .init(engineDownPolicy: .silent))
        ready(&l, 1, at: 0)
        let v11 = l.requestTTS(1, job: 1, clone: .down, at: ms(0))
        #expect(v11 == .wait)
        for t in stride(from: 100, through: 20_000, by: 100) { l.tick(at: ms(t)) }
        #expect(l.state(1) == .dropped)
        ready(&l, 2, press: 2, at: ms(20_000))
        let v12 = l.requestTTS(2, job: 2, clone: .down, at: ms(20_000))
        #expect(v12 == .refuse(.voiceUnavailable))
        #expect(l.state(2) == .dropped)
    }

    /// Decision 5 = systemVoice: only the next press may use it; the crashed press never does.
    @Test func decision5SystemVoiceOnlyFromNextPress() {
        var l = ClauseLedger(config: .init(engineDownPolicy: .systemVoice))
        ready(&l, 1, at: 0); ready(&l, 2, at: 0)
        _ = l.requestTTS(1, job: 1, clone: .ready(Self.h), at: 0)
        l.engineLost(at: ms(100))
        let v13 = l.requestTTS(2, job: 2, clone: .down, at: ms(200))
        #expect(v13 == .wait)
        l.tick(at: ms(6000))
        #expect(l.state(2) == .dropped)
        ready(&l, 3, press: 2, at: ms(7000))
        let v14 = l.requestTTS(3, job: 3, clone: .down, at: ms(7000))
        #expect(v14 == .send(.system))
        // Clone comes back mid-press 2: press 2 stays on the system voice.
        _ = l.engineReady(at: ms(8000))
        ready(&l, 4, press: 2, at: ms(8000))
        let v15 = l.requestTTS(4, job: 4, clone: .ready(Self.h), at: ms(8000))
        #expect(v15 == .send(.system))
    }

    @Test func noProfileUsesSystemVoiceC8() {
        var l = ClauseLedger()
        ready(&l, 1, at: 0)
        let v16 = l.requestTTS(1, job: 1, clone: .noProfile, at: 0)
        #expect(v16 == .send(.system))
    }

    @Test func passthroughCutIsIncomplete() {
        let sink = RecordingSink()
        var l = ClauseLedger(sink: sink)
        ready(&l, 1, at: 0)
        _ = l.requestTTS(1, job: 1, clone: .ready(Self.h), at: 0)
        l.firstSampleEnqueued(1, job: 1, at: ms(100))
        l.cut(1, reason: .passthroughCut, at: ms(1600))
        #expect(l.state(1) == .incomplete && l.row(1)?.reason == .passthroughCut)
        #expect(sink.events.last == .init(clause: 1, state: .incomplete, reason: .passthroughCut))
        let v17 = l.requestTTS(1, job: 2, clone: .ready(Self.h), at: ms(2000))
        #expect(v17 == .refuse(.passthroughCut))
    }

    /// Review H: the engine gave up (zero-audio tail, runaway or echo on the last attempt) →
    /// dropped with that reason, never resent.
    @Test func renderFailedIsDroppedNotResent() {
        let sink = RecordingSink()
        var l = ClauseLedger(sink: sink)
        ready(&l, 1, at: 0)
        _ = l.requestTTS(1, job: 10, clone: .ready(Self.h), at: ms(0))
        l.renderFailed(1, job: 9, reason: .runaway, at: ms(400))          // another job: ignored
        #expect(l.state(1) == .ttsRequested)
        l.renderFailed(1, job: 10, reason: .echo, at: ms(500))
        #expect(l.state(1) == .dropped && l.row(1)?.reason == .echo)
        #expect(sink.events.last == .init(clause: 1, state: .dropped, reason: .echo))
        #expect(l.engineReady(at: ms(600)) == [])
        let again = l.requestTTS(1, job: 11, clone: .ready(Self.h), at: ms(700))
        #expect(again == .refuse(.echo))
        #expect(!l.accepts(1, job: 10))
    }

    @Test func gateAndCancel() {
        var l = ClauseLedger()
        ready(&l, 1, at: 0); ready(&l, 2, at: 0); l.commit(3, press: 1, at: 0)
        l.gate(1, at: ms(1))
        #expect(l.state(1) == .gated)
        let v18 = l.cancelAll(at: ms(2))
        #expect(v18 == [2, 3])
        #expect(l.state(2) == .cancelled)
    }

    // MARK: property test

    /// Seeded simulation of a SPEAK session with engine crashes/hangs and reconnects on a virtual
    /// clock (10 ms steps). The pipeline asks the ledger before sending, accepts only the chunks
    /// the ledger accepts, resends what `engineReady` returns and drops what `tick` drops.
    @Test(arguments: Array(UInt64(1)...UInt64(300)))
    func propertyCrashesAndReconnects(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let policy: ClauseLedger.EngineDownPolicy = seed % 3 == 0 ? .systemVoice : .silent
        var l = ClauseLedger(config: .init(engineRetryS: 5, engineDownPolicy: policy))

        struct Clause { var id: UInt64; var press: UInt64; var mtAt: Int; var chunks: Int }
        struct Stream { var clause: UInt64; var job: JobID; var left: Int; var nextAt: Int }
        var clauses: [Clause] = []
        var t = 0
        for p in UInt64(1)...6 {
            let n = Int.random(in: 1...5, using: &rng)
            for _ in 0..<n {
                t += 10 * Int.random(in: 10...150, using: &rng)   // 10 ms grid
                clauses.append(Clause(id: UInt64(clauses.count + 1), press: p, mtAt: t, chunks: Int.random(in: 1...20, using: &rng)))
            }
            t += 10 * Int.random(in: 50...800, using: &rng)
        }
        // Outages: (start, duration ms)
        var outages: [(Int, Int)] = []
        var o = Int.random(in: 0...3000, using: &rng)
        while o < t {
            // Every 4th seed only has outages inside the retry window: then nothing may be lost.
            let d = Int.random(in: 300...(seed % 4 == 1 ? 4_800 : 12_000), using: &rng)
            outages.append((o, d))
            o += d + Int.random(in: 1000...10_000, using: &rng)
        }
        func engineUp(_ at: Int) -> Bool { !outages.contains { at >= $0.0 && at < $0.0 + $0.1 } }

        var pending: [UInt64] = []
        var streams: [Stream] = []
        var playAt: [UInt64: Int] = [:]
        var voicedJobs: [UInt64: Set<JobID>] = [:]
        var pressVoices: [UInt64: Set<String>] = [:]
        var sentAt: [UInt64: [Int]] = [:]
        var nextJob: JobID = 100
        var wasUp = true
        let end = t + 30_000
        for now in stride(from: 0, through: end, by: 10) {
            let T = ms(now)
            let up = engineUp(now)
            if wasUp && !up { l.engineLost(at: T); streams.removeAll() }
            if !wasUp && up {
                for c in l.engineReady(at: T) where !pending.contains(c) { pending.append(c) }
            }
            wasUp = up
            for c in clauses where c.mtAt == now {
                l.commit(c.id, press: c.press, at: T); l.advance(c.id, to: .asrDone, at: T); l.advance(c.id, to: .mtDone, at: T)
                pending.append(c.id)
            }
            if now % 100 == 0 {
                let dropped = Set(l.tick(at: T))
                pending.removeAll { dropped.contains($0) }
            }
            // The engine runs one TTS job at a time.
            if streams.isEmpty, let c = pending.first {
                let job = nextJob; nextJob += 1
                switch l.requestTTS(c, job: job, clone: up ? .ready(Self.h) : .down, at: T) {
                case .send(let v):
                    pending.removeFirst()
                    sentAt[c, default: []].append(now)
                    let press = clauses[Int(c) - 1].press
                    pressVoices[press, default: []].insert(v == .system ? "system" : "clone")
                    if v == .system {
                        playAt[c] = now + 300           // system voice: rendered whole, plays
                        voicedJobs[c, default: []].insert(job)
                        l.firstSampleEnqueued(c, job: job, at: T); l.streamFinished(c, job: job)
                    } else {
                        streams.append(Stream(clause: c, job: job, left: clauses[Int(c) - 1].chunks, nextAt: now + 150))
                    }
                case .wait: break
                case .refuse: pending.removeFirst()
                }
            }
            if up, var s = streams.first, s.nextAt <= now {
                if l.accepts(s.clause, job: s.job) {
                    voicedJobs[s.clause, default: []].insert(s.job)
                    l.firstSampleEnqueued(s.clause, job: s.job, at: T)
                }
                s.left -= 1; s.nextAt = now + 40
                if s.left == 0 {
                    l.streamFinished(s.clause, job: s.job)
                    playAt[s.clause] = now + 160
                    streams.removeFirst()
                } else { streams[0] = s }
            }
            for (c, at) in playAt where at == now { l.played(c, at: T); playAt[c] = nil }
        }

        for c in clauses {
            let r = l.row(c.id)!
            // 0 repeats after the first sample.
            #expect((voicedJobs[c.id]?.count ?? 0) <= 1, "seed \(seed) clause \(c.id) voiced twice")
            #expect(r.state.isTerminal, "seed \(seed) clause \(c.id) stuck in \(r.state)")
            if r.state == .played || r.state == .incomplete { #expect(voicedJobs[c.id]?.count == 1) }
            // A resend (same clause ID) only follows an outage that ended inside the retry window.
            if let sends = sentAt[c.id], sends.count > 1 {
                for s in sends.dropFirst() {
                    let outage = outages.last(where: { $0.0 <= s })!
                    #expect(outage.1 <= 5_000 + 100, "seed \(seed) clause \(c.id) resent after a \(outage.1) ms outage")
                    #expect(s >= outage.0 + outage.1)
                }
            }
            if seed % 4 == 1 {
                #expect(r.reason != .voiceUnavailable, "seed \(seed) clause \(c.id) lost in a short outage")
            }
        }
        // One voice per press.
        for (p, v) in pressVoices { #expect(v.count == 1, "seed \(seed) press \(p) voices \(v)") }
        if policy == .silent { #expect(pressVoices.values.allSatisfy { $0 == ["clone"] }) }
    }

    /// 00f65f3 review [低] §5.7: every SPEAK `.stalled` goes to `streamFailed(.stall)`, whatever the
    /// chunk count. Chunks yielded but held back (preroll, whole clause) never reached ringO: the
    /// clause is resent with the same id, not dropped (which `cut` would do). Once a sample was
    /// enqueued the same call makes it `incomplete`.
    @Test func stallBeforeTheFirstSampleIsResentNotDropped() {
        var l = ClauseLedger()
        ready(&l, 1, at: 0); ready(&l, 2, at: 0)
        _ = l.requestTTS(1, job: 10, clone: .ready(Self.h), at: ms(0))
        _ = l.requestTTS(2, job: 11, clone: .ready(Self.h), at: ms(0))
        l.streamFailed(1, job: 10, reason: .stall, at: ms(1200))           // 3 chunks, all in preroll
        #expect(l.state(1) == .ttsRequested && l.row(1)?.needsResend == true)
        let again = l.requestTTS(1, job: 12, clone: .ready(Self.h), at: ms(1210))
        #expect(again == .send(.clone(Self.h)))
        l.firstSampleEnqueued(2, job: 11, at: ms(300))
        l.firstSampleEnqueued(2, job: 11, at: ms(300))                     // repeat: no-op (ClauseQueue.streamFailed)
        l.streamFailed(2, job: 11, reason: .stall, at: ms(1500))
        #expect(l.state(2) == .incomplete && l.row(2)?.reason == .stall)
        let refused = l.requestTTS(2, job: 13, clone: .ready(Self.h), at: ms(1510))
        #expect(refused == .refuse(.stall))
    }

    /// Review 4: after engineLost the old job's held audio can still reach ringO. Its first
    /// sample is accepted by job (the clause is being voiced: no resend); another job's is not.
    @Test func firstSampleAfterEngineLostIsMatchedByJob() {
        var l = ClauseLedger()
        ready(&l, 1, at: 0); ready(&l, 2, at: 0)
        _ = l.requestTTS(1, job: 10, clone: .ready(Self.h), at: 0)
        _ = l.requestTTS(2, job: 20, clone: .ready(Self.h), at: 0)
        l.engineLost(at: ms(100))
        #expect(l.row(1)?.needsResend == true)
        l.firstSampleEnqueued(1, job: 10, at: ms(120))
        #expect(l.state(1) == .firstSampleEnqueued && l.row(1)?.needsResend == false)
        l.firstSampleEnqueued(2, job: 99, at: ms(130))                     // not its job
        #expect(l.state(2) == .ttsRequested)
        #expect(l.engineReady(at: ms(1000)) == [2])
    }

    /// Review 3: clauses after a resent one are discarded by ClauseQueue and go back for a resend
    /// too, even when fully rendered; a playing or unsent clause is left alone.
    @Test func resendPutsLaterClausesBack() {
        var l = ClauseLedger()
        for c in UInt64(1)...4 { ready(&l, c, at: 0) }
        _ = l.requestTTS(1, job: 10, clone: .ready(Self.h), at: 0)
        _ = l.requestTTS(2, job: 20, clone: .ready(Self.h), at: 0)
        _ = l.requestTTS(3, job: 30, clone: .ready(Self.h), at: 0)
        l.firstSampleEnqueued(1, job: 10, at: ms(100))
        l.streamFinished(3, job: 30)
        l.streamFailed(2, job: 20, reason: .stall, at: ms(1200))
        let r3 = l.resend(3, at: ms(1200)), r1 = l.resend(1, at: ms(1200)), r4 = l.resend(4, at: ms(1200))
        #expect(r3 && !r1 && !r4)
        #expect(l.row(3)?.needsResend == true && l.row(3)?.rendered == false && !l.accepts(3, job: 30))
        let a = l.requestTTS(2, job: 21, clone: .ready(Self.h), at: ms(1210))
        let b = l.requestTTS(3, job: 31, clone: .ready(Self.h), at: ms(1210))
        #expect(a == .send(.clone(Self.h)) && b == .send(.clone(Self.h)))
    }

    /// Short outage (< window) → every clause is eventually voiced exactly once (nothing lost).
    @Test func shortOutageLosesNothingNotYetPlaying() {
        var l = ClauseLedger()
        for c in UInt64(1)...3 { ready(&l, c, at: 0) }
        let v19 = l.requestTTS(1, job: 1, clone: .ready(Self.h), at: 0)
        #expect(v19 == .send(.clone(Self.h)))
        l.engineLost(at: ms(50))
        let v20 = l.requestTTS(2, job: 2, clone: .down, at: ms(60))
        #expect(v20 == .wait)
        let back = l.engineReady(at: ms(2000))
        #expect(back == [1])
        for (i, c) in (back + [2, 3]).enumerated() {
            let v21 = l.requestTTS(c, job: JobID(10 + i), clone: .ready(Self.h), at: ms(2000))
            #expect(v21 == .send(.clone(Self.h)))
        }
    }
}
