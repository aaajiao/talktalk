import CAudioCore
import CoreAudio
import Foundation
import Testing

/// monitorIOProc: ringO2 at the monitor gain (default -10 dB, ramped over one cycle) plus cue
/// tones at unity, the same mono signal on every output channel.
@Suite struct MonitorIOProcTests {
    final class Rig {
        let ring: OpaquePointer
        let cues: OpaquePointer?
        let events: OpaquePointer
        let ctx: OpaquePointer
        private let list = AudioBufferList.allocate(maximumBuffers: 1)
        private let storage = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 8192)
        private(set) var ch0: [Float] = []
        private(set) var ch1: [Float] = []

        init(withCues: Bool = false, maxCycle: UInt32 = 0) {
            ring = tt_ring_create(96000)!
            cues = withCues ? tt_ring_create(4096)! : nil
            events = tt_event_ring_create(64)!
            ctx = tt_monitor_ctx_create(ring, cues, events, maxCycle)!
            storage.initialize(repeating: 0, count: 2 * 8192)
        }

        deinit {
            tt_monitor_ctx_destroy(ctx)
            tt_event_ring_destroy(events)
            tt_ring_destroy(cues)
            tt_ring_destroy(ring)
            free(list.unsafeMutablePointer)
            storage.deallocate()
        }

        func write(_ value: Float, _ frames: Int, _ flags: UInt32) {
            let buf = [Float](repeating: value, count: frames)
            _ = buf.withUnsafeBufferPointer { tt_ring_write_clause(ring, $0.baseAddress, UInt32(frames), flags, 1) }
        }

        func cue(_ value: Float, _ frames: Int) {
            let buf = [Float](repeating: value, count: frames)
            _ = buf.withUnsafeBufferPointer { tt_ring_write_strided(cues!, $0.baseAddress!, UInt32(frames), 1) }
        }

        func cycle(_ frames: Int, host: UInt64 = 0) {
            storage.update(repeating: 777, count: 2 * frames)
            list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(2 * frames * 4), mData: storage)
            tt_monitor_process(ctx, list.unsafeMutablePointer, UInt32(frames), host)
            ch0 = (0..<frames).map { storage[2 * $0] }
            ch1 = (0..<frames).map { storage[2 * $0 + 1] }
        }
    }

    private func fadeIn(_ i: Int) -> Float { tt_fade_in_gain(UInt32(min(i, 240)), 240) }

    @Test func defaultGainIsMinusTenDecibelsOnEveryChannel() {
        let rig = Rig()
        let g = tt_monitor_gain(rig.ctx)
        #expect(abs(Double(g) - pow(10, -0.5)) < 1e-7)
        rig.write(0.5, 2000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END)
        rig.cycle(480)
        for i in 0..<480 {
            let want = (0.5 * fadeIn(i)) * g
            #expect(rig.ch0[i] == want)
            #expect(rig.ch1[i] == want)
        }
        #expect(tt_monitor_audio_frames(rig.ctx) == 480)
        #expect(tt_monitor_underruns(rig.ctx) == 0)
    }

    @Test func gainChangeRampsLinearlyOverOneCycle() {
        let rig = Rig()
        let g0 = tt_monitor_gain(rig.ctx)
        rig.write(0.5, 2000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END)
        rig.cycle(480)
        tt_monitor_set_gain(rig.ctx, 1)
        rig.cycle(480)
        for i in 0..<480 {
            let g = g0 + (1 - g0) * (Float(i + 1) / 480)
            #expect(abs(rig.ch0[i] - 0.5 * g) < 1e-6)
            #expect(rig.ch1[i] == rig.ch0[i])
        }
        rig.cycle(480)
        #expect(rig.ch0.allSatisfy { $0 == 0.5 } && rig.ch1.allSatisfy { $0 == 0.5 })
    }

    /// The initial gain is where the first cycle starts, so a context made muted never plays a
    /// ramp down from the -10 dB default (MonitorOutput sets it before AudioDeviceStart).
    @Test func initialGainSetsTheStartingPointWithoutARamp() {
        for (g, want) in [(Float(0), Float(0)), (1, 1), (9, 4)] {
            let rig = Rig()
            tt_monitor_set_gain_initial(rig.ctx, g)
            #expect(tt_monitor_gain(rig.ctx) == want)
            rig.write(0.5, 2000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END)
            rig.cycle(480)
            for i in 0..<480 { #expect(rig.ch0[i] == (0.5 * fadeIn(i)) * want) }
        }
    }

    /// Cue gain 0: the cue ring is still read (nothing stays queued for later) but nothing plays;
    /// a change ramps over one cycle like the ringO2 gain.
    @Test func cueGainZeroDropsQueuedCuesAndChangesRamp() {
        let rig = Rig(withCues: true)
        tt_monitor_set_cue_gain_initial(rig.ctx, 0)
        rig.cue(0.25, 480)
        rig.cycle(480)
        #expect(rig.ch0.allSatisfy { $0 == 0 } && rig.ch1.allSatisfy { $0 == 0 })
        #expect(tt_ring_available(rig.cues!) == 0 && tt_monitor_cue_frames(rig.ctx) == 480)
        tt_monitor_set_cue_gain(rig.ctx, 1)
        rig.cue(0.25, 480)
        rig.cycle(480)
        for i in 0..<480 { #expect(abs(rig.ch0[i] - 0.25 * Float(i + 1) / 480) < 1e-6) }
        rig.cue(0.25, 480)
        rig.cycle(480)
        #expect(rig.ch0.allSatisfy { $0 == 0.25 })
        tt_monitor_set_cue_gain(rig.ctx, 7)
        #expect(tt_monitor_cue_gain(rig.ctx) == 1)
        tt_monitor_set_cue_gain(rig.ctx, .nan)
        #expect(tt_monitor_cue_gain(rig.ctx) == 0)
    }

    /// With a channel pair set, only those two (buffer, channel) slots carry the signal.
    @Test func aChannelPairWritesOnlyThoseSlots() {
        func run(buffers: [UInt32], pair: (UInt32, UInt32, UInt32, UInt32)) -> [[[Float]]] {
            let ring = tt_ring_create(96000)!
            let ctx = tt_monitor_ctx_create(ring, nil, nil, 0)!
            defer { tt_monitor_ctx_destroy(ctx); tt_ring_destroy(ring) }
            tt_monitor_set_gain_initial(ctx, 1)
            tt_monitor_set_channels(ctx, pair.0, pair.1, pair.2, pair.3)
            let x = [Float](repeating: 0.5, count: 4800)
            _ = x.withUnsafeBufferPointer { tt_ring_write_clause(ring, $0.baseAddress, 4800, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 1) }
            let frames = 480
            let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
            defer { free(list.unsafeMutablePointer) }
            let stores = buffers.map { UnsafeMutablePointer<Float>.allocate(capacity: Int($0) * frames) }
            defer { stores.forEach { $0.deallocate() } }
            for (b, nch) in buffers.enumerated() {
                stores[b].initialize(repeating: 777, count: Int(nch) * frames)
                list[b] = AudioBuffer(mNumberChannels: nch, mDataByteSize: nch * UInt32(frames) * 4, mData: stores[b])
            }
            tt_monitor_process(ctx, list.unsafeMutablePointer, UInt32(frames), 0)
            return buffers.enumerated().map { b, nch in
                (0..<Int(nch)).map { ch in (0..<frames).map { stores[b][$0 * Int(nch) + ch] } }
            }
        }
        let want = (0..<480).map { 0.5 * fadeIn($0) }
        let four = run(buffers: [4], pair: (0, 2, 0, 3))
        #expect(four[0][0].allSatisfy { $0 == 0 } && four[0][1].allSatisfy { $0 == 0 })
        #expect(four[0][2] == want && four[0][3] == want)
        let split = run(buffers: [2, 2], pair: (0, 1, 1, 0))
        #expect(split[0][0].allSatisfy { $0 == 0 } && split[0][1] == want)
        #expect(split[1][0] == want && split[1][1].allSatisfy { $0 == 0 })
        let mono = run(buffers: [2], pair: (0, 0, 0, 0))
        #expect(mono[0][0] == want && mono[0][1].allSatisfy { $0 == 0 })
        let missing = run(buffers: [2], pair: (3, 0, 0, 9))          // slots the list does not have
        #expect(missing[0][0].allSatisfy { $0 == 0 } && missing[0][1].allSatisfy { $0 == 0 })
    }

    /// A new context starts with tt_ring_playout_suspend: a flush the producer asked for while no
    /// monitor ran completes at once, so the old clause's tail is not played (or faded) again.
    @Test(arguments: [false, true]) func aNewContextCompletesAPendingFlushWithoutReplay(cutInProgress: Bool) {
        let ring = tt_ring_create(96000)!
        defer { tt_ring_destroy(ring) }
        let x = [Float](repeating: 0.5, count: 4800)
        _ = x.withUnsafeBufferPointer { tt_ring_write_clause(ring, $0.baseAddress, 4800, TT_RING_CLAUSE_START, 1) }
        _ = x.withUnsafeBufferPointer { tt_ring_write_clause(ring, $0.baseAddress, 4800, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 2) }
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 960)
        defer { free(list.unsafeMutablePointer); out.deallocate() }
        func cycle(_ ctx: OpaquePointer) -> [Float] {
            out.initialize(repeating: 777, count: 960)
            list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 960 * 4, mData: out)
            tt_monitor_process(ctx, list.unsafeMutablePointer, 480, 0)
            return (0..<480).map { out[2 * $0] }
        }
        let first = tt_monitor_ctx_create(ring, nil, nil, 0)!
        tt_monitor_set_gain_initial(first, 1)
        _ = cycle(first); _ = cycle(first)                          // the old attachment, mid-clause
        #expect(tt_ring_request_jump(ring, TT_RING_JUMP_NEXT_START))
        if cutInProgress { _ = cycle(first) }
        tt_monitor_ctx_destroy(first)
        #expect(tt_ring_request_jump(ring, TT_RING_JUMP_WRITE_INDEX))
        let next = tt_monitor_ctx_create(ring, nil, nil, 0)!
        defer { tt_monitor_ctx_destroy(next) }
        tt_monitor_set_gain_initial(next, 1)
        #expect(cycle(next).allSatisfy { $0 == 0 })
        #expect(!tt_ring_jump_pending(ring) && tt_ring_available(ring) == 0)
    }

    @Test func gainIsClampedAndLowDecibelsMute() {
        let rig = Rig()
        let cases: [(Float, Float)] = [(-60, 0), (-.infinity, 0), (.nan, 0), (0, 1), (-10, Float(pow(10, -0.5))),
                                       (20, Float(pow(10, 0.6))), (-59, Float(pow(10, -59.0 / 20)))]
        for (db, want) in cases {
            tt_monitor_set_gain_db(rig.ctx, db)
            #expect(abs(tt_monitor_gain(rig.ctx) - want) <= want * 1e-5, "\(db) dB")
        }
        tt_monitor_set_gain(rig.ctx, 5)
        #expect(tt_monitor_gain(rig.ctx) == 4)
        tt_monitor_set_gain(rig.ctx, -1)
        #expect(tt_monitor_gain(rig.ctx) == 0)
        tt_monitor_set_gain(rig.ctx, .nan)
        #expect(tt_monitor_gain(rig.ctx) == 0)
    }

    @Test func cuesAreAddedAtUnityGain() {
        let rig = Rig(withCues: true)
        let g = tt_monitor_gain(rig.ctx)
        rig.cue(0.25, 480)
        rig.cycle(480)
        #expect(rig.ch0.allSatisfy { $0 == 0.25 } && rig.ch1.allSatisfy { $0 == 0.25 })
        #expect(tt_monitor_cue_frames(rig.ctx) == 480)
        #expect(tt_monitor_audio_frames(rig.ctx) == 0)
        rig.write(0.5, 2000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END)
        rig.cue(0.25, 100)
        rig.cycle(480)
        for i in 0..<480 {
            let tts = (0.5 * fadeIn(i)) * g
            #expect(rig.ch0[i] == (i < 100 ? tts + 0.25 : tts))
        }
    }

    @Test func cyclesLongerThanTheScratchGiveTheSameOutput() {
        let whole = Rig(), split = Rig(maxCycle: 256)
        for rig in [whole, split] {
            rig.write(0.5, 3000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END)
            tt_monitor_set_gain(rig.ctx, 2)
            rig.cycle(1000)
        }
        #expect(whole.ch0 == split.ch0)
        #expect(whole.ch1 == split.ch1)
    }

    @Test func underrunIsCountedAndReportedWithTheCycleHostTime() {
        let rig = Rig()
        rig.write(0.5, 1000, TT_RING_CLAUSE_START)   // no END: the clause runs dry
        var host: UInt64 = 0
        var k = 0
        while tt_monitor_underruns(rig.ctx) == 0 && k < 5 {
            host = 7_000_000 + UInt64(k) * 240_000
            rig.cycle(480, host: host)
            k += 1
        }
        #expect(tt_monitor_underruns(rig.ctx) == 1)
        var ev = [tt_event](repeating: tt_event(), count: 8)
        let n = ev.withUnsafeMutableBufferPointer { tt_event_drain(rig.events, $0.baseAddress!, 8) }
        #expect(n == 1)
        #expect(ev[0].type == UInt16(TT_EV_MON_UNDERRUN) && ev[0].source == UInt16(TT_EV_SRC_MONITOR))
        #expect(ev[0].host_ticks == host)
    }

    @Test func ioprocFillsSeparateChannelBuffers() {
        let rig = Rig()
        let g = tt_monitor_gain(rig.ctx)
        rig.write(0.5, 2000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END)
        let two = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(two.unsafeMutablePointer) }
        let a = UnsafeMutablePointer<Float>.allocate(capacity: 480)
        let b = UnsafeMutablePointer<Float>.allocate(capacity: 480)
        defer { a.deallocate(); b.deallocate() }
        a.initialize(repeating: 9, count: 480)
        b.initialize(repeating: 9, count: 480)
        two[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 480 * 4, mData: a)
        two[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 480 * 4, mData: b)
        var now = AudioTimeStamp(), inTime = AudioTimeStamp(), outTime = AudioTimeStamp()
        var input = AudioBufferList()
        let status = tt_monitor_ioproc(1, &now, &input, &inTime, two.unsafeMutablePointer, &outTime,
                                       UnsafeMutableRawPointer(rig.ctx))
        #expect(status == noErr)
        #expect(tt_monitor_frames(rig.ctx) == 480)
        for i in 0..<480 {
            let want = (0.5 * fadeIn(i)) * g
            #expect(a[i] == want && b[i] == want)
        }
    }
}
