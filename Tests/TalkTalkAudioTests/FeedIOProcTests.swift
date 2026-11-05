import CAudioCore
import CoreAudio
import Foundation
import Testing

/// feedIOProc with its rings, passthrough state, event ring and envelope, driven by
/// tt_feed_process on a 2-channel interleaved buffer (the Feed device layout).
final class FeedRig {
    static let tpf = 500.0
    static let t0: UInt64 = 1_000_000_000
    static let thirtySeconds: UInt64 = 30 * 48000 * 500
    static func tk(_ frame: Int) -> UInt64 { t0 + UInt64(frame) * 500 }

    let ringO: OpaquePointer
    let ringP: OpaquePointer
    let pt: OpaquePointer
    let events: OpaquePointer
    let env: OpaquePointer
    let ctx: OpaquePointer
    var frame: Int
    private let maxFrames = 8192
    private let list: UnsafeMutableAudioBufferListPointer
    private let storage: UnsafeMutablePointer<Float>
    private let eventBuf: UnsafeMutablePointer<tt_event>
    private(set) var ch0: [Float] = []
    private(set) var ch1: [Float] = []

    init(startFrame: Int = 0) {
        ringO = tt_ring_create(96000)!
        tt_ring_set_max_lead(ringO, 24000)
        ringP = tt_ringp_create(Self.tpf)!
        pt = tt_pt_state_create()!
        events = tt_event_ring_create(4096)!
        env = tt_envelope_create(480, Self.tpf)!
        var config = tt_feed_config(host_ticks_per_frame: Self.tpf, mic_latency_frames: TT_FEED_MIC_LATENCY_FRAMES,
                                    max_cycle_frames: TT_FEED_DEFAULT_MAX_CYCLE_FRAMES)
        ctx = tt_feed_ctx_create(ringO, ringP, pt, events, env, &config)!
        frame = startFrame
        list = AudioBufferList.allocate(maximumBuffers: 1)
        storage = UnsafeMutablePointer<Float>.allocate(capacity: 2 * maxFrames)
        storage.initialize(repeating: 0, count: 2 * maxFrames)
        eventBuf = UnsafeMutablePointer<tt_event>.allocate(capacity: 4096)
        eventBuf.initialize(repeating: tt_event(), count: 4096)
    }

    deinit {
        tt_feed_ctx_destroy(ctx)
        tt_envelope_destroy(env)
        tt_event_ring_destroy(events)
        tt_pt_state_destroy(pt)
        tt_ringp_destroy(ringP)
        tt_ring_destroy(ringO)
        free(list.unsafeMutablePointer)
        storage.deallocate()
        eventBuf.deallocate()
    }

    var now: UInt64 { Self.tk(frame) }

    /// One IO cycle of `frames` frames output at `now`; fills ch0 / ch1.
    func cycle(_ frames: Int, collect: Bool = true) {
        precondition(frames <= maxFrames)
        storage.update(repeating: 777, count: 2 * frames)
        list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(2 * frames * 4), mData: storage)
        tt_feed_process(ctx, list.unsafeMutablePointer, UInt32(frames), now)
        if collect {
            ch0 = (0..<frames).map { storage[2 * $0] }
            ch1 = (0..<frames).map { storage[2 * $0 + 1] }
        }
        frame += frames
    }

    /// The interleaved output of the last cycle (valid until the next one).
    func output(_ frames: Int) -> UnsafeBufferPointer<Float> { UnsafeBufferPointer(start: storage, count: 2 * frames) }

    func writeO(_ value: Float, _ frames: Int, _ flags: UInt32, _ tag: UInt32) {
        let buf = [Float](repeating: value, count: frames)
        _ = buf.withUnsafeBufferPointer { tt_ring_write_clause(ringO, $0.baseAddress, UInt32(frames), flags, tag) }
    }

    func writeP(at: Int, _ frames: Int, gen: UInt32, _ value: Float) {
        let buf = [Float](repeating: value, count: frames)
        _ = buf.withUnsafeBufferPointer { tt_ringp_write(ringP, $0.baseAddress!, UInt32(frames), Self.tk(at), gen) }
    }

    func open(_ source: UInt32, at: Int, leaseUntil: Int) -> UInt32 {
        tt_pt_state_open(pt, source, Self.tk(at), Self.tk(leaseUntil), Self.tk(at) + Self.thirtySeconds)
    }

    func drain() -> [tt_event] {
        let n = tt_event_drain(events, eventBuf, 4096)
        return Array(UnsafeBufferPointer(start: eventBuf, count: Int(n)))
    }

    func discardEvents() { _ = tt_event_drain(events, eventBuf, 4096) }

    func points() -> [tt_envelope_point] {
        var cursor: UInt64 = 0
        var buf = [tt_envelope_point](repeating: tt_envelope_point(), count: 512)
        let n = buf.withUnsafeMutableBufferPointer { tt_envelope_read(env, &cursor, $0.baseAddress!, 512) }
        return Array(buf[0..<Int(n)])
    }
}

private func fadeIn(_ i: Int, _ len: UInt32) -> Float { tt_fade_in_gain(UInt32(i), len) }
private func fadeOut(_ i: Int, _ len: UInt32) -> Float { tt_fade_out_gain(UInt32(i), len) }
private func evType(_ t: UInt32) -> UInt16 { UInt16(t) }
private func live(_ s: tt_pt_snapshot, _ now: UInt64) -> Bool { var c = s; return tt_pt_snapshot_live(&c, now) }
private func validUntil(_ s: tt_pt_snapshot) -> UInt64 { var c = s; return tt_pt_snapshot_valid_until(&c) }

@Suite struct PassthroughStateTests {
    @Test func newStateIsClosed() throws {
        let s = try #require(tt_pt_state_create())
        defer { tt_pt_state_destroy(s) }
        let snap = tt_pt_state_read(s)
        #expect(snap.valid == 1 && snap.open == 0 && snap.generation == 0)
        #expect(!live(snap, 1))
    }

    @Test func openRenewCloseFollowTheLeaseRules() throws {
        let s = try #require(tt_pt_state_create())
        defer { tt_pt_state_destroy(s) }
        let g = tt_pt_state_open(s, TT_PT_SOURCE_MIC, 1000, 5000, 30000)
        #expect(g == 1)
        var snap = tt_pt_state_read(s)
        #expect(snap.open == 1 && snap.generation == 1 && snap.source == TT_PT_SOURCE_MIC)
        #expect(snap.open_ticks == 1000 && snap.lease_until_ticks == 5000 && snap.deadline_ticks == 30000)
        #expect(live(snap, 4999))
        #expect(!live(snap, 5000))
        #expect(tt_pt_state_renew(s, g, 8000))
        #expect(tt_pt_state_renew(s, g, 6000))          // never shortens
        #expect(tt_pt_state_read(s).lease_until_ticks == 8000)
        #expect(tt_pt_state_renew(s, g, 99999))         // clamped to the deadline
        #expect(tt_pt_state_read(s).lease_until_ticks == 30000)
        #expect(!tt_pt_state_renew(s, g + 1, 9000))     // not the open generation
        #expect(!tt_pt_state_close(s, g + 1, 9000))
        #expect(tt_pt_state_close(s, g, 9000))
        #expect(!tt_pt_state_close(s, g, 8500))         // already closed: nothing changes
        snap = tt_pt_state_read(s)
        #expect(snap.open == 0 && snap.lease_until_ticks == 9000)
        #expect(validUntil(snap) == 9000)
        #expect(!tt_pt_state_renew(s, g, 20000))        // closed: no renewal
        // Lease beyond the deadline at open is clamped; a switch of source is a new generation.
        let g2 = tt_pt_state_open(s, TT_PT_SOURCE_SELF_TEST, 40000, 999_999, 70000)
        #expect(g2 == 2)
        snap = tt_pt_state_read(s)
        #expect(snap.lease_until_ticks == 70000 && snap.source == TT_PT_SOURCE_SELF_TEST)
        _ = tt_pt_state_open(s, 7, 80000, 90000, 100000)   // unknown source: .mic
        #expect(tt_pt_state_read(s).source == TT_PT_SOURCE_MIC)
    }

    @Test func sourceAndChannelAreOneValue() {
        #expect(tt_pt_source_channel(TT_PT_SOURCE_MIC) == 0)
        #expect(tt_pt_source_channel(TT_PT_SOURCE_SELF_TEST) == 1)
        #expect(tt_pt_source_channel(5) == 0)
    }

    /// Readers never see a torn state: a writer thread keeps opening, renewing and closing with
    /// fields tied to the generation, the reader checks the ties on 10^6 snapshots.
    @Test func snapshotsAreNeverTorn() throws {
        let state = try #require(tt_pt_state_create())
        defer { tt_pt_state_destroy(state) }
        nonisolated(unsafe) let s = state
        let stop = ManagedAtomicFlag()
        let writer = Thread {
            var g: UInt32 = 0
            while !stop.isSet {
                let next = UInt64(g + 1)
                g = tt_pt_state_open(s, (g & 1) == 0 ? TT_PT_SOURCE_MIC : TT_PT_SOURCE_SELF_TEST,
                                     next * 1000, next * 1000 + 100, next * 1000 + 500)
                for k in 1...4 { _ = tt_pt_state_renew(s, g, next * 1000 + 100 * UInt64(k + 1)) }
                _ = tt_pt_state_close(s, g, next * 1000 + 300)
            }
        }
        writer.start()
        var torn = 0
        var valid = 0
        for _ in 0..<1_000_000 {
            let snap = tt_pt_state_read(s)
            guard snap.valid == 1, snap.generation > 0 else { continue }
            valid += 1
            let g = UInt64(snap.generation)
            let expectedSource = (snap.generation & 1) == 1 ? TT_PT_SOURCE_MIC : TT_PT_SOURCE_SELF_TEST
            if snap.open_ticks != g * 1000 || snap.deadline_ticks != g * 1000 + 500 ||
                snap.lease_until_ticks < g * 1000 + 100 || snap.lease_until_ticks > snap.deadline_ticks ||
                snap.source != expectedSource || (snap.open == 0 && snap.lease_until_ticks > g * 1000 + 300) {
                torn += 1
            }
        }
        stop.set()
        while !writer.isFinished { usleep(100) }
        #expect(torn == 0)
        #expect(valid > 0)
    }
}

@Suite struct FeedIOProcTests {
    @Test func ringOPlaysOnChannelOneWithFadeInAndReportsFirstSampleAndEnvelope() {
        let rig = FeedRig()
        rig.writeO(0.5, 2000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 1)
        rig.cycle(480)
        for i in 0..<240 { #expect(rig.ch0[i] == 0.5 * fadeIn(i, 240)) }
        #expect(rig.ch0[240..<480].allSatisfy { $0 == 0.5 })
        #expect(rig.ch1.allSatisfy { $0 == 0 })
        let first = rig.drain().first { $0.type == evType(TT_EV_OUT_FIRST_SAMPLE) }
        #expect(first?.a == 1)
        #expect(first?.host_ticks == FeedRig.tk(480))   // output time + the driver's 480-frame lag
        rig.cycle(480)
        rig.cycle(480)
        let pts = rig.points()
        #expect(pts.count == 3)
        var acc = 0.0
        for i in 0..<240 { let v = Double(0.5 * fadeIn(i, 240)); acc += v * v }
        acc += 0.25 * 240
        #expect(abs(Double(pts[0].rms) - (acc / 480).squareRoot()) < 1e-6)
        #expect(pts[0].host_ticks == FeedRig.tk(480))
        #expect(abs(pts[1].rms - 0.5) < 1e-6)
        #expect(pts[1].host_ticks == FeedRig.tk(960))
    }

    @Test func micPassthroughFadesInOnChannelOneAndClosesWithTenMillisecondFade() {
        let rig = FeedRig(startFrame: 2000)
        let g = rig.open(TT_PT_SOURCE_MIC, at: 0, leaseUntil: 10000)
        rig.writeP(at: 0, 2000, gen: g, 1)
        rig.cycle(480)
        for i in 0..<240 { #expect(rig.ch0[i] == fadeIn(i, 240)) }
        #expect(rig.ch0[240..<480].allSatisfy { $0 == 1 })
        #expect(rig.ch1.allSatisfy { $0 == 0 })
        let lc = tt_feed_last_cycle(rig.ctx)
        #expect(lc.mode == TT_FEED_MODE_PT && lc.ring_p_audio == 480 && lc.ring_p_channel == 0 && lc.generation == g)
        let ev = rig.drain()
        #expect(ev.contains { $0.type == evType(TT_EV_PT_OPEN_SEEN) && $0.a == g })
        let first = ev.first { $0.type == evType(TT_EV_PT_FIRST_SAMPLE) }
        #expect(first?.a == g)
        #expect(first?.host_ticks == FeedRig.tk(2480))
        #expect(first?.b == FeedRig.tk(0))   // capture time of that sample
        #expect(tt_pt_state_close(rig.pt, g, rig.now))
        rig.cycle(480)
        for i in 0..<480 { #expect(rig.ch0[i] == fadeOut(i, 480)) }
        #expect(tt_ringp_fill(rig.ringP) == 0)   // read pointer jumped to the write pointer
        #expect(tt_feed_mode(rig.ctx) == TT_FEED_MODE_RING_O)
        let zero = rig.drain().first { $0.type == evType(TT_EV_PT_ZERO) }
        #expect(zero?.host_ticks == FeedRig.tk(2480 + 960))
        #expect(tt_feed_pt_lease_expiries(rig.ctx) == 0)
        rig.cycle(480)
        #expect(rig.ch0.allSatisfy { $0 == 0 })
    }

    @Test func expiredLeaseClosesLikeACloseAndALateRenewalNeverReplays() {
        let rig = FeedRig(startFrame: 2000)
        let g = rig.open(TT_PT_SOURCE_MIC, at: 0, leaseUntil: 2600)
        rig.writeP(at: 0, 2600, gen: g, 1)
        rig.writeP(at: 2600, 1400, gen: g, .nan)   // captured after the lease end
        rig.cycle(480)
        rig.cycle(480)
        rig.cycle(480)   // output time 2960 ≥ lease end 2600
        #expect(tt_feed_pt_lease_expiries(rig.ctx) == 1)
        for i in 0..<480 { #expect(rig.ch0[i] == fadeOut(i, 480)) }
        #expect(tt_ringp_fill(rig.ringP) == 0)
        #expect(rig.drain().contains { $0.type == evType(TT_EV_PT_LEASE_EXPIRED) && $0.a == g })
        // The key-tap thread wakes up late and renews: the generation stays finished.
        #expect(tt_pt_state_renew(rig.pt, g, rig.now + 48000 * 500))
        rig.writeP(at: 4000, 2000, gen: g, .nan)
        for _ in 0..<5 {
            rig.cycle(480)
            #expect(rig.ch0.allSatisfy { $0 == 0 })
            #expect(rig.ch1.allSatisfy { $0 == 0 })
        }
        #expect(tt_feed_mode(rig.ctx) == TT_FEED_MODE_RING_O)
        #expect(tt_ringp_fill(rig.ringP) == 0)
    }

    @Test func selfTestPassthroughUsesChannelTwoOnly() {
        let rig = FeedRig(startFrame: 2000)
        let g = rig.open(TT_PT_SOURCE_SELF_TEST, at: 0, leaseUntil: 10000)
        rig.writeP(at: 0, 2000, gen: g, 1)
        rig.cycle(480)
        for i in 0..<240 { #expect(rig.ch1[i] == fadeIn(i, 240)) }
        #expect(rig.ch0.allSatisfy { $0 == 0 })
        #expect(tt_feed_last_cycle(rig.ctx).ring_p_channel == 1)
        let pts = rig.points()   // channel 2 never enters the meeting envelope
        #expect(pts.count == 1 && pts[0].rms == 0)
    }

    @Test func playingRingOFadesOutForOneCycleThenRingPTakesOverAndRingOResumesAfter() {
        let rig = FeedRig(startFrame: 2000)
        rig.writeO(0.5, 10000, TT_RING_CLAUSE_START, 1)
        rig.cycle(480)
        let g = rig.open(TT_PT_SOURCE_MIC, at: 1000, leaseUntil: 20000)
        rig.writeP(at: 1000, 2000, gen: g, 1)
        let availO = tt_ring_available(rig.ringO)
        rig.cycle(480)
        for i in 0..<480 { #expect(rig.ch0[i] == 0.5 * fadeOut(i, 480)) }
        let lc = tt_feed_last_cycle(rig.ctx)
        #expect(lc.mode == TT_FEED_MODE_O_TO_P && lc.ring_p_audio == 0)
        let availO2 = tt_ring_available(rig.ringO)
        #expect(availO2 == availO - 480)
        rig.cycle(480)
        for i in 0..<240 { #expect(rig.ch0[i] == fadeIn(i, 240)) }
        #expect(tt_ring_available(rig.ringO) == availO2)   // ringO is not read during passthrough
        #expect(tt_pt_state_close(rig.pt, g, rig.now))
        rig.cycle(480)
        for i in 0..<480 { #expect(rig.ch0[i] == fadeOut(i, 480)) }
        rig.cycle(480)
        for i in 0..<240 { #expect(rig.ch0[i] == 0.5 * fadeIn(i, 240)) }
        #expect(tt_feed_mixed_cycles(rig.ctx) == 0)
    }

    /// A jump and a passthrough open in the same cycle: ringO's 10 ms hand-over fade ends inside
    /// the 30 ms cut fade. The cut completes there (reported in that cycle, at its end), so when
    /// passthrough closes nothing of the cut clause plays; with pause requested ringO is parked.
    @Test func cutInProgressWhenRingPTakesOverCompletesBeforeTheHandOver() {
        for pause in [true, false] {
            let rig = FeedRig(startFrame: 2000)
            rig.writeO(0.5, 20000, TT_RING_CLAUSE_START, 7)
            rig.cycle(480)
            rig.discardEvents()
            if pause { tt_ring_set_pause(rig.ringO, true) }
            #expect(tt_ring_request_jump(rig.ringO, TT_RING_JUMP_NEXT_START))   // no later START
            let g = rig.open(TT_PT_SOURCE_MIC, at: 2000, leaseUntil: 40000)
            rig.writeP(at: 2000, 4000, gen: g, 1)
            rig.cycle(480)
            #expect(tt_feed_last_cycle(rig.ctx).mode == TT_FEED_MODE_O_TO_P)
            for i in 0..<480 { #expect(rig.ch0[i] == 0.5 * fadeOut(i, 1440) * fadeOut(i, 480)) }
            let ev = rig.drain()
            let cut = ev.first { $0.type == evType(TT_EV_OUT_CLAUSE_CUT) }
            #expect(cut?.a == 7 && cut?.b == 20000 - 960)
            #expect(cut?.host_ticks == FeedRig.tk(2480 + 480 + 480))
            #expect(ev.contains { $0.type == evType(TT_EV_OUT_PARKED) } == pause)
            #expect(!tt_ring_jump_pending(rig.ringO))
            rig.cycle(480)
            rig.cycle(480)
            #expect(tt_feed_mode(rig.ctx) == TT_FEED_MODE_PT)
            #expect(tt_pt_state_close(rig.pt, g, rig.now))
            rig.cycle(480)
            #expect(tt_feed_mode(rig.ctx) == TT_FEED_MODE_RING_O)
            for _ in 0..<4 {
                rig.cycle(480)
                #expect(rig.ch0.allSatisfy { $0 == 0 } && rig.ch1.allSatisfy { $0 == 0 }, "pause \(pause)")
            }
            #expect(tt_ring_is_parked(rig.ringO) == pause)
            if !pause { #expect(tt_ring_playout_state(rig.ringO) == TT_RING_STATE_IDLE) }
            #expect(tt_ring_available(rig.ringO) == 0)
        }
    }

    /// O_TO_P ends inside clause 1's hold-back fade, which holds clause 2's START: the suspend
    /// stops on it (clause 1 ended, no underrun), so after the passthrough closes clause 2 plays
    /// from its first frame and its first sample is reported (review 2026-11-05).
    @Test func handOverInsideAHoldBackFadeKeepsTheNextClauseStart() {
        let rig = FeedRig(startFrame: 2000)
        rig.writeO(0.5, 1000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 1)
        rig.writeO(0.25, 100, TT_RING_CLAUSE_START, 2)   // START at 1000; hold-back fade 860..<1100
        rig.cycle(480)
        rig.discardEvents()
        let g = rig.open(TT_PT_SOURCE_MIC, at: 2000, leaseUntil: 40000)
        rig.writeP(at: 2000, 4000, gen: g, 1)
        rig.cycle(480)   // O_TO_P: ringO 480..<960 under the 10 ms hand-over fade, then suspend
        #expect(tt_feed_last_cycle(rig.ctx).mode == TT_FEED_MODE_O_TO_P)
        var ev = rig.drain()
        #expect(ev.contains { $0.type == evType(TT_EV_OUT_ENDED) })
        #expect(tt_ring_available(rig.ringO) == 100)
        rig.cycle(480)
        rig.cycle(480)
        #expect(tt_feed_mode(rig.ctx) == TT_FEED_MODE_PT)
        #expect(tt_pt_state_close(rig.pt, g, rig.now))
        rig.cycle(480)   // PT_CLOSING
        ev += rig.drain()
        let zero = ev.lastIndex { $0.type == evType(TT_EV_PT_ZERO) }
        #expect(zero != nil)
        rig.writeO(0.25, 2000, TT_RING_CLAUSE_END, 2)
        let start = rig.frame
        rig.cycle(480)
        #expect(tt_feed_last_cycle(rig.ctx).mode == TT_FEED_MODE_RING_O)
        let after = rig.drain()
        let firsts = after.filter { $0.type == evType(TT_EV_OUT_FIRST_SAMPLE) }
        #expect(firsts.map(\.a) == [2] && firsts.first?.host_ticks == FeedRig.tk(start + 480))
        for i in 0..<240 { #expect(rig.ch0[i] == 0.25 * fadeIn(i, 240)) }
        #expect(rig.ch0[240...].allSatisfy { $0 == 0.25 })
        #expect(!(ev + after).contains { $0.type == evType(TT_EV_OUT_UNDERRUN) })
        #expect(tt_ring_playout_underruns(rig.ringO) == 0)
    }

    /// The events of one ringO read come out in output order, each timestamped at its own
    /// offset: the cut completes at 1440, the next clause's first sample is at the same offset,
    /// and its end falls in the cycle's second chunk.
    @Test func ringOEventsComeOutInOutputOrderWithTheirOwnTimes() {
        let rig = FeedRig()
        rig.writeO(1, 3000, TT_RING_CLAUSE_START, 1)
        rig.writeO(0.5, 3000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 2)
        rig.cycle(480)
        rig.discardEvents()
        #expect(tt_ring_request_jump(rig.ringO, TT_RING_JUMP_NEXT_START))
        rig.cycle(4800)   // chunks of 4096 + 704
        let got = rig.drain().map { [UInt64($0.type), UInt64($0.a), $0.b, $0.host_ticks] }
        let want: [[UInt64]] = [
            [UInt64(TT_EV_OUT_CLAUSE_CUT), 1, 1080, FeedRig.tk(480 + 1440 + 480)],
            [UInt64(TT_EV_OUT_FIRST_SAMPLE), 2, 0, FeedRig.tk(480 + 1440 + 480)],
            [UInt64(TT_EV_OUT_ENDED), 0, 0, FeedRig.tk(480 + 4440 + 480)],
        ]
        #expect(got == want)
        #expect(rig.ch0[1438] == fadeOut(1438, 1440) && rig.ch0[1441] == 0.5 * fadeIn(1, 240))
    }

    @Test func generationChangeStopsAtOnceAndOldBlocksNeverPlay() {
        let rig = FeedRig(startFrame: 2000)
        let g1 = rig.open(TT_PT_SOURCE_MIC, at: 0, leaseUntil: 20000)
        rig.writeP(at: 0, 2000, gen: g1, 1)
        rig.cycle(480)
        let g2 = rig.open(TT_PT_SOURCE_SELF_TEST, at: 2480, leaseUntil: 20000)
        #expect(g2 == g1 + 1)
        rig.cycle(480)
        #expect(rig.ch0.allSatisfy { $0 == 0 } && rig.ch1.allSatisfy { $0 == 0 })
        #expect(tt_ringp_fill(rig.ringP) == 0)
        rig.writeP(at: 2480, 300, gen: g1, .nan)   // late block of the old open
        rig.writeP(at: 2780, 1500, gen: g2, 2)
        rig.cycle(480)
        #expect(rig.ch0.allSatisfy { $0 == 0 })
        #expect(!rig.ch1.contains { $0.isNaN })
        for i in 0..<240 { #expect(rig.ch1[i] == 2 * fadeIn(i, 240)) }
        #expect(tt_ringp_stale_frames(rig.ringP) >= 300)
    }

    @Test func micFramesCapturedBeforeTheOpenAreDroppedAndCounted() {
        let rig = FeedRig(startFrame: 2000)
        let g = rig.open(TT_PT_SOURCE_MIC, at: 100, leaseUntil: 20000)
        rig.writeP(at: 0, 100, gen: g, .nan)
        rig.writeP(at: 100, 2000, gen: g, 1)
        rig.cycle(480)
        #expect(!rig.ch0.contains { $0.isNaN })
        #expect(tt_feed_pt_out_of_interval_frames(rig.ctx) == 100)
        #expect(rig.drain().contains { $0.type == evType(TT_EV_PT_DISCARDED) && $0.b == 100 })
    }

    @Test func rebufferThresholdAdaptsDoublesAndDecays() {
        let rig = FeedRig()
        #expect(tt_feed_resume_frames(rig.ctx) == 3840)
        tt_feed_set_chunk_interval_p95_frames(rig.ctx, 3000)
        rig.cycle(480)
        #expect(tt_feed_resume_frames(rig.ctx) == 6000)   // 2 × p95
        tt_feed_set_chunk_interval_p95_frames(rig.ctx, 0)
        rig.cycle(480)
        rig.writeO(1, 100, TT_RING_CLAUSE_START, 1)
        for want: UInt32 in [3840, 7680, 15360, 30720, 30720] {
            let before = tt_feed_out_underruns(rig.ctx)
            rig.writeO(1, Int(tt_feed_resume_frames(rig.ctx)) + 1000, 0, 0)
            var k = 0
            while tt_feed_out_underruns(rig.ctx) == before && k < 200 { rig.cycle(480, collect: false); k += 1 }
            #expect(tt_feed_out_underruns(rig.ctx) == before + 1)
            #expect(tt_feed_resume_frames(rig.ctx) == want)
        }
        for _ in 0..<360 { rig.cycle(4096, collect: false) }   // > 30 s without an underrun
        #expect(tt_feed_resume_frames(rig.ctx) == 15360)
        for _ in 0..<360 { rig.cycle(4096, collect: false) }
        #expect(tt_feed_resume_frames(rig.ctx) == 7680)
    }

    @Test func missingChannelOneIsCountedAndSeparateBuffersWork() throws {
        let rig = FeedRig(startFrame: 2000)
        let empty = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(empty.unsafeMutablePointer) }
        empty.unsafeMutablePointer.pointee.mNumberBuffers = 0
        tt_feed_process(rig.ctx, empty.unsafeMutablePointer, 480, rig.now)
        #expect(tt_feed_missing_buffers(rig.ctx) == 1)

        let g = rig.open(TT_PT_SOURCE_SELF_TEST, at: 0, leaseUntil: 20000)
        rig.writeP(at: 0, 2000, gen: g, 1)
        let two = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(two.unsafeMutablePointer) }
        let a = UnsafeMutablePointer<Float>.allocate(capacity: 480)
        let b = UnsafeMutablePointer<Float>.allocate(capacity: 480)
        defer { a.deallocate(); b.deallocate() }
        a.initialize(repeating: 9, count: 480)
        b.initialize(repeating: 9, count: 480)
        two[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 480 * 4, mData: a)
        two[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 480 * 4, mData: b)
        tt_feed_process(rig.ctx, two.unsafeMutablePointer, 480, rig.now)
        for i in 0..<240 {
            #expect(b[i] == fadeIn(i, 240))
            #expect(a[i] == 0)
        }
    }

    @Test func ioprocTakesTheOutputHostTime() throws {
        let rig = FeedRig()
        rig.writeO(0.5, 2000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 3)
        let out = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(out.unsafeMutablePointer) }
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 960)
        defer { p.deallocate() }
        out[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 960 * 4, mData: p)
        var now = AudioTimeStamp()
        var inTime = AudioTimeStamp()
        var input = AudioBufferList()
        var outTime = AudioTimeStamp()
        outTime.mHostTime = 5_000_000
        outTime.mFlags = .hostTimeValid
        let status = tt_feed_ioproc(1, &now, &input, &inTime, out.unsafeMutablePointer, &outTime, UnsafeMutableRawPointer(rig.ctx))
        #expect(status == noErr)
        #expect(tt_feed_last_cycle(rig.ctx).out_host_ticks == 5_000_000)
        #expect(tt_feed_last_cycle(rig.ctx).frames == 480)
        let first = rig.drain().first { $0.type == evType(TT_EV_OUT_FIRST_SAMPLE) }
        #expect(first?.host_ticks == 5_000_000 + 480 * 500)
    }

    /// ≥100k random IO cycles: random opens (mic or self-test), switches with and without a
    /// close, lease renewals, lapses, late renewals, hard deadlines, stale and pre-open blocks,
    /// random TTS clauses with pauses and jumps, random cycle sizes and capture jitter.
    /// Samples are typed by value: ringO 0.5 (in (0, 1] after fades), mic -1 (negative), self-test
    /// 1e12 (> 1 after any fade), and NaN for every frame that must never be played (captured
    /// before the open, at or after the end of its window, or tagged with an older generation).
    @Test func fuzzOneHundredThousandCyclesKeepsThePrivacyInvariants() {
        let rig = FeedRig()
        var rng = RTRandom(seed: 2026_11_04)
        let micValue: Float = -1, selfTestValue: Float = 1e12, oValue: Float = 0.5
        struct Plan { var gen: UInt32 = 0; var source: UInt32 = 0; var open: UInt64 = 0; var validEnd: UInt64 = 0
                      var deadline: UInt64 = 0; var close = false; var ended = false; var lateRenewed = false }
        var cur = Plan()
        var haveGen = false
        var capFrames = 0
        var tag: UInt32 = 1
        var block = [Float](repeating: 0, count: 4096)
        var nanCycles = 0, wrongChannel = 0, mixed = 0, notEmpty = 0
        var micCycles = 0, selfTestCycles = 0, oCycles = 0
        for _ in 0..<100_000 {
            let n = rng.chance(8) ? rng.int(16...2048) : 480
            let now = rig.now
            // Passthrough schedule.
            if haveGen && !cur.ended && now >= cur.validEnd {
                if cur.close { _ = tt_pt_state_close(rig.pt, cur.gen, cur.validEnd) }
                cur.ended = true
            } else if haveGen && cur.ended && !cur.lateRenewed && rng.chance(50) {
                _ = tt_pt_state_renew(rig.pt, cur.gen, now + 48000 * 500)
                cur.lateRenewed = true
            }
            if haveGen && !cur.ended {
                _ = tt_pt_state_renew(rig.pt, cur.gen, min(now + UInt64(rng.int(4800...9600)) * 500, cur.validEnd))
            }
            if (!haveGen || cur.ended) ? rng.chance(40) : rng.chance(400) {
                if haveGen && !cur.ended {
                    if rng.chance(2) { _ = tt_pt_state_close(rig.pt, cur.gen, now) }
                    cur.validEnd = now
                }
                var p = Plan()
                p.source = rng.chance(4) ? TT_PT_SOURCE_SELF_TEST : TT_PT_SOURCE_MIC
                p.open = now - UInt64(rng.int(0...960)) * 500
                p.deadline = p.open + FeedRig.thirtySeconds
                p.validEnd = p.open + UInt64(rng.int(240...96000)) * 500
                if rng.chance(20) { p.validEnd = p.deadline + 48000 * 500 }
                p.validEnd = min(p.validEnd, p.deadline)
                p.close = rng.chance(2)
                p.gen = tt_pt_state_open(rig.pt, p.source, p.open, min(now + 4800 * 500, p.validEnd), p.deadline)
                cur = p
                haveGen = true
            }
            // Microphone capture up to now minus a jittering delay.
            let delay = rng.int(0...720)
            let capTarget = max(rig.frame - delay, 0)
            while capFrames < capTarget {
                let m = min(rng.int(1...960), capTarget - capFrames)
                let h = FeedRig.tk(capFrames)
                let stale = haveGen && cur.gen > 1 && rng.chance(30)
                let g: UInt32 = haveGen ? (stale ? cur.gen - 1 : cur.gen) : 0
                for i in 0..<m {
                    let t = h + UInt64(i) * 500
                    let legit = haveGen && !stale && t >= cur.open && t < cur.validEnd
                    block[i] = legit ? (cur.source == TT_PT_SOURCE_SELF_TEST ? selfTestValue : micValue) : .nan
                }
                _ = block.withUnsafeBufferPointer { tt_ringp_write(rig.ringP, $0.baseAddress!, UInt32(m), h, g) }
                capFrames += m
            }
            // TTS producer and controls.
            if rng.chance(6) {
                let m = rng.int(100...4000)
                var flags: UInt32 = 0
                if rng.chance(3) { flags |= TT_RING_CLAUSE_START }
                if rng.chance(3) { flags |= TT_RING_CLAUSE_END }
                rig.writeO(oValue, m, flags, tag)
                tag += 1
            }
            if rng.chance(200) { tt_ring_set_pause(rig.ringO, rng.chance(2)) }
            if rng.chance(300) { _ = tt_ring_request_jump(rig.ringO, rng.chance(2) ? TT_RING_JUMP_NEXT_START : TT_RING_JUMP_WRITE_INDEX) }

            rig.cycle(n, collect: false)
            let out = rig.output(n)
            var c0O = false, c0Mic = false, c1SelfTest = false, nan = false, wrong = false
            for i in 0..<n {
                let a = out[2 * i], b = out[2 * i + 1]
                if a.isNaN || b.isNaN { nan = true; continue }
                if a > 0 && a <= 1 { c0O = true } else if a < 0 { c0Mic = true } else if a > 1 { wrong = true }   // self-test on ch1
                if b > 1 { c1SelfTest = true } else if b != 0 { wrong = true }                                    // mic or TTS on ch2
            }
            if nan { nanCycles += 1 }
            if wrong { wrongChannel += 1 }
            if c0O && (c0Mic || c1SelfTest) { mixed += 1 }
            if tt_feed_last_cycle(rig.ctx).mode == TT_FEED_MODE_RING_O && tt_ringp_fill(rig.ringP) != 0 { notEmpty += 1 }
            if c0Mic { micCycles += 1 }
            if c1SelfTest { selfTestCycles += 1 }
            if c0O { oCycles += 1 }
            rig.discardEvents()
        }
        #expect(nanCycles == 0)        // nothing outside its passthrough interval, no stale generation
        #expect(wrongChannel == 0)     // .mic never on channel 2, .selfTest never on channel 1
        #expect(mixed == 0)            // ringO and ringP never in the same cycle
        #expect(notEmpty == 0)         // ringP is empty whenever ringO is the source
        #expect(tt_feed_mixed_cycles(rig.ctx) == 0)
        #expect(micCycles > 1000 && selfTestCycles > 100 && oCycles > 1000)   // the fuzz reached every mode
        #expect(tt_feed_pt_out_of_interval_frames(rig.ctx) > 0 && tt_ringp_stale_frames(rig.ringP) > 0)
    }
}
