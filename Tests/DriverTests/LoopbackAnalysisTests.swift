import CDriverSelfTest
import Foundation
import Testing
@testable import TalkTalkDriverSupport

/// The self-test's numbers (§8.4 校验 2, 4) on synthetic recordings, and the C writer / recorder
/// cycles without Core Audio.
@Suite struct LoopbackAnalysisTests {
    /// What the driver does: the input at sample time S is the output at S − lag.
    func loopRecording(signal: [Float], start: Int64, lag: Int64, gain: Float = 1, from: Int64, frames: Int,
                       chunk: Int = 480, noiseAt: Int64? = nil) -> DriverLoopbackAnalysis.Recording {
        var chunks: [DriverLoopbackAnalysis.Recording.Chunk] = []
        var samples: [Float] = []
        var s = from
        while s < from + Int64(frames) {
            chunks.append(.init(sampleTime: s, frames: chunk, offset: samples.count))
            for i in 0..<chunk {
                let src = s + Int64(i) - lag - start
                var v: Float = (src >= 0 && src < Int64(signal.count)) ? signal[Int(src)] * gain : 0
                if let n = noiseAt, s + Int64(i) == n { v = 0.01 }
                samples.append(v)
            }
            s += Int64(chunk)
        }
        return .init(chunks: chunks, samples: samples)
    }

    @Test func sweepIsMinus18dBFSAndOneSecond() {
        let w = DriverLoopbackAnalysis.sweep()
        #expect(w.count == 48_000)
        let peak = w.map(abs).max() ?? 0
        #expect(abs(20 * log10(Double(peak)) - -18) < 0.05)
        #expect(w.first == 0)
    }

    @Test func exactLoopbackPassesWithLag480() {
        let w = DriverLoopbackAnalysis.sweep()
        let start: Int64 = 1_000_000
        let rec = loopRecording(signal: w, start: start, lag: 480, from: start - 12_000, frames: 48_000 * 2)
        let st = DriverLoopbackAnalysis.analyze(rec, signal: w, signalStart: start)
        #expect(st.bestLag == 480)
        #expect(st.peak > 0.999)
        #expect(abs(st.levelDeltaDB ?? 99) < 0.01)
        #expect(st.nonzeroOutside == 0)
        #expect(st.passes)
    }

    @Test func failsOnLevelLagNoiseAndSilence() {
        let w = DriverLoopbackAnalysis.sweep()
        let start: Int64 = 500_000
        let quiet = DriverLoopbackAnalysis.analyze(loopRecording(signal: w, start: start, lag: 480, gain: 0.8,
                                                                 from: start - 12_000, frames: 96_000),
                                                   signal: w, signalStart: start)
        #expect(abs((quiet.levelDeltaDB ?? 0) - 20 * log10(0.8)) < 0.05)
        #expect(!quiet.passes)

        let late = DriverLoopbackAnalysis.analyze(loopRecording(signal: w, start: start, lag: 1_440, from: start - 12_000,
                                                                frames: 96_000), signal: w, signalStart: start)
        #expect(late.bestLag == 1_440)
        #expect(!late.passes)

        let noisy = DriverLoopbackAnalysis.analyze(loopRecording(signal: w, start: start, lag: 480, from: start - 12_000,
                                                                 frames: 96_000, noiseAt: start - 6_000),
                                                   signal: w, signalStart: start)
        #expect(noisy.nonzeroOutside == 1)
        #expect(!noisy.passes)

        let silent = DriverLoopbackAnalysis.analyze(loopRecording(signal: w, start: start, lag: 480, gain: 0,
                                                                  from: start - 12_000, frames: 96_000),
                                                    signal: w, signalStart: start)
        #expect(silent.levelDeltaDB == nil && !silent.passes)
        #expect(!DriverLoopbackAnalysis.analyze(.init(), signal: w, signalStart: start).passes)
    }

    @Test func replayCheckFindsStaleSamples() {
        let tone: (Int64) -> Float = { Float(sin(Double($0) * 0.01)) * 0.25 }
        let ranges: [ClosedRange<Int64>] = [10_000...10_959, 20_000...20_959]
        var samples: [Float] = []
        var chunks: [DriverLoopbackAnalysis.Recording.Chunk] = []
        var s: Int64 = 9_600
        while s < 22_000 {
            chunks.append(.init(sampleTime: s, frames: 480, offset: samples.count))
            for i in 0..<480 {
                let src = s + Int64(i) - 480
                samples.append(ranges.contains { $0.contains(src) } ? tone(src) : 0)
            }
            s += 480
        }
        let good = DriverLoopbackAnalysis.Recording(chunks: chunks, samples: samples)
        let ok = DriverLoopbackAnalysis.replay(good, ranges: ranges, tone: tone)
        #expect(ok.playedOK == 1_920 && ok.playedBad == 0 && ok.silentNonzero == 0)
        #expect(ok.passes(cycles: 2))
        var stale = good
        stale.samples[stale.samples.count - 100] = 0.2   // something read back while nothing was written
        let bad = DriverLoopbackAnalysis.replay(stale, ranges: ranges, tone: tone)
        #expect(bad.silentNonzero == 1 && !bad.passes(cycles: 2))
        #expect(!ok.passes(cycles: 3))
    }

    // MARK: C contexts

    @Test func writerPutsTheSignalOnOneChannelAfterTheLead() throws {
        let sig: [Float] = [0.5, -0.5, 0.25]
        let w = try #require(sig.withUnsafeBufferPointer { tt_st_writer_create($0.baseAddress, 3, 1, 4, 8) })
        defer { tt_st_writer_destroy(w) }
        tt_st_writer_set_mode(w, TT_ST_MODE_SIGNAL)
        var out = [Float](repeating: 9, count: 10 * 2)
        out.withUnsafeMutableBufferPointer { b in
            tt_st_writer_render(w, b.baseAddress!, 5, 2, 100)
            tt_st_writer_render(w, b.baseAddress! + 10, 5, 2, 105)
        }
        // channel 0 (→ TalkTalk Mic) always zero; channel 1 gets the signal at 104, 105, 106
        #expect(stride(from: 0, to: 20, by: 2).allSatisfy { out[$0] == 0 })
        #expect(stride(from: 1, to: 20, by: 2).map { out[$0] } == [0, 0, 0, 0, 0.5, -0.5, 0.25, 0, 0, 0])
        #expect(tt_st_writer_first_sample(w) == 100)
        #expect(tt_st_writer_signal_start(w) == 104)
        #expect(tt_st_writer_end_sample(w) == 110)
        var r = [tt_st_range](repeating: .init(), count: 4)
        #expect(tt_st_writer_ranges(w, &r, 4) == 1)
        #expect(r[0].begin == 100 && r[0].end == 110)
        // a gap opens a new range
        tt_st_writer_render(w, &out, 5, 2, 200)
        #expect(tt_st_writer_ranges(w, &r, 4) == 2)
        #expect(tt_st_writer_discontinuities(w) == 1)
    }

    @Test func toneModeIsKeyedBySampleTime() throws {
        let w = try #require(tt_st_writer_create(nil, 0, 1, 0, 4))
        defer { tt_st_writer_destroy(w) }
        tt_st_writer_set_mode(w, TT_ST_MODE_TONE)
        var a = [Float](repeating: 0, count: 8), b = [Float](repeating: 0, count: 8)
        tt_st_writer_render(w, &a, 4, 2, 48_123)
        tt_st_writer_reset(w)
        tt_st_writer_render(w, &b, 4, 2, 48_123)
        #expect(a == b)
        #expect(a[1] == tt_st_tone(w, 48_123))
        #expect(abs(tt_st_tone(w, 1) - Float(0.25 * sin(2 * Double.pi * 997 / 48_000))) < 1e-6)
        #expect(tt_st_tone(w, 0) == 0)
    }

    @Test func recorderPlacesChunksAndCountsNonzero() throws {
        let r = try #require(tt_st_recorder_create(8, 4))
        defer { tt_st_recorder_destroy(r) }
        let a: [Float] = [0, 1, 0, 2]   // stride 2: takes 0, 0
        let b: [Float] = [3, 0, 4, 0]   // stride 2: takes 3, 4
        tt_st_recorder_append(r, a, 2, 2, 1_000, 1)
        tt_st_recorder_append(r, b, 2, 2, 1_002, 2)
        tt_st_recorder_append(r, nil, 2, 1, 1_010, 3)   // gap; no buffer = zeros
        #expect(tt_st_recorder_frames(r) == 6 && tt_st_recorder_nonzero(r) == 2)
        #expect(tt_st_recorder_discontinuities(r) == 1)
        let rec = recording(r)
        #expect(rec.chunks.map(\.sampleTime) == [1_000, 1_002, 1_010])
        #expect(rec.samples == [0, 0, 3, 4, 0, 0])
        // full: further chunks are counted as overflows, not written past the buffer
        tt_st_recorder_append(r, b, 4, 1, 1_012, 4)
        #expect(tt_st_recorder_overflows(r) == 1)
        #expect(tt_st_recorder_sample_count(r) == 6)
    }

    func recording(_ r: OpaquePointer) -> DriverLoopbackAnalysis.Recording {
        let nc = Int(tt_st_recorder_chunk_count(r))
        var chunks = [tt_st_chunk](repeating: .init(), count: nc)
        _ = tt_st_recorder_chunks(r, &chunks, UInt32(nc))
        var samples = [Float](repeating: 0, count: Int(tt_st_recorder_sample_count(r)))
        _ = tt_st_recorder_samples(r, &samples, UInt32(samples.count))
        return .init(chunks: chunks.map { .init(sampleTime: $0.sample_time, frames: Int($0.frames), offset: Int($0.offset)) },
                     samples: samples)
    }
}
