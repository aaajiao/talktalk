import CAudioCore
import Foundation
import Testing

/// tt_envelope: 10 ms RMS / peak history for the echo score (feedIOProc produces, the audio
/// worker reads with a cursor).
@Suite struct EnvelopeTests {
    private static let window: UInt32 = 480
    private static let ticksPerWindow: UInt64 = 480 * 500

    private func push(_ env: OpaquePointer, _ samples: [Float], stride: UInt32 = 1, at host: UInt64) {
        samples.withUnsafeBufferPointer {
            tt_envelope_push(env, $0.baseAddress, UInt32(samples.count) / stride, stride, host)
        }
    }

    private func read(_ env: OpaquePointer, _ cursor: inout UInt64, max: Int = 600) -> [tt_envelope_point] {
        var buf = [tt_envelope_point](repeating: tt_envelope_point(), count: max)
        let n = buf.withUnsafeMutableBufferPointer { tt_envelope_read(env, &cursor, $0.baseAddress!, UInt32(max)) }
        return Array(buf[0..<Int(n)])
    }

    private func db(_ x: Double) -> Double { 20 * log10(x) }

    @Test func badArgumentsAreRefused() {
        #expect(tt_envelope_create(0, 500) == nil)
        #expect(tt_envelope_create(480, 0) == nil)
        #expect(tt_envelope_create(480, .nan) == nil)
    }

    @Test func constantSignalGivesItsLevelAndWindowTimes() throws {
        let env = try #require(tt_envelope_create(Self.window, 500))
        defer { tt_envelope_destroy(env) }
        push(env, [Float](repeating: 0.5, count: 4800), at: 2_000_000)
        var cursor: UInt64 = 0
        let pts = read(env, &cursor)
        #expect(pts.count == 10 && cursor == 10 && tt_envelope_count(env) == 10)
        for (i, p) in pts.enumerated() {
            #expect(p.seq == UInt64(i))
            #expect(p.rms == 0.5 && p.peak == 0.5)
            #expect(p.host_ticks == 2_000_000 + UInt64(i) * Self.ticksPerWindow)
        }
    }

    @Test func sineRmsIsWithinATenthOfADecibel() throws {
        let env = try #require(tt_envelope_create(Self.window, 500))
        defer { tt_envelope_destroy(env) }
        let samples = (0..<4800).map { Float(0.8 * sin(2 * Double.pi * 997 * Double($0) / 48000)) }
        push(env, samples, at: 0)
        var cursor: UInt64 = 0
        let pts = read(env, &cursor)
        #expect(pts.count == 10)
        for p in pts {
            #expect(abs(db(Double(p.rms)) - db(0.8 / 2.0.squareRoot())) < 0.1)
            #expect(p.peak <= 0.8 && p.peak > 0.79)
        }
    }

    @Test func strideSelectsOneChannelAndNullSourceIsSilence() throws {
        let env = try #require(tt_envelope_create(Self.window, 500))
        defer { tt_envelope_destroy(env) }
        var interleaved = [Float](repeating: 0, count: 2 * 960)
        for i in 0..<960 { interleaved[2 * i] = 0.5; interleaved[2 * i + 1] = 1 }
        push(env, interleaved, stride: 2, at: 0)
        tt_envelope_push(env, nil, 480, 1, 960 * 500)
        var cursor: UInt64 = 0
        let pts = read(env, &cursor)
        #expect(pts.count == 3)
        #expect(pts[0].rms == 0.5 && pts[1].rms == 0.5)
        #expect(pts[2].rms == 0 && pts[2].peak == 0 && pts[2].host_ticks == 960 * 500)
    }

    @Test func aTimeJumpRestartsTheWindowAndSmallJitterDoesNot() throws {
        let env = try #require(tt_envelope_create(Self.window, 500))
        defer { tt_envelope_destroy(env) }
        let ones = [Float](repeating: 1, count: 480)
        var cursor: UInt64 = 0
        push(env, Array(ones[0..<240]), at: 0)
        push(env, ones, at: 10_000 * 500)          // jump: the partial window is dropped
        var pts = read(env, &cursor)
        #expect(pts.count == 1 && pts.first?.host_ticks == 10_000 * 500)
        // Next push 100 frames late (< half a window): same window continues.
        push(env, Array(ones[0..<240]), at: (10_480 + 100) * 500)
        push(env, Array(ones[0..<240]), at: (10_480 + 340 + 150) * 500)
        pts = read(env, &cursor)
        #expect(pts.count == 1 && pts.first?.host_ticks == 10_580 * 500)
        // A window built from pieces carries the host time of its first frame.
        push(env, Array(ones[0..<100]), at: 20_000 * 500)
        push(env, Array(ones[0..<380]), at: 20_100 * 500)
        pts = read(env, &cursor)
        #expect(pts.count == 1 && pts.first?.host_ticks == 20_000 * 500 && pts.first?.seq == 2)
    }

    @Test func aSlowReaderSkipsOverwrittenPointsAndCountsThem() throws {
        let env = try #require(tt_envelope_create(Self.window, 500))
        defer { tt_envelope_destroy(env) }
        for s in 0..<600 {
            push(env, [Float](repeating: Float(s) / 1000, count: 480), at: UInt64(s) * Self.ticksPerWindow)
        }
        #expect(tt_envelope_count(env) == 600)
        var cursor: UInt64 = 0
        let pts = read(env, &cursor)
        #expect(pts.count == Int(TT_ENVELOPE_POINTS) - 1)
        #expect(pts.first?.seq == 89 && cursor == 600)
        #expect(tt_envelope_lost_points(env) == 89)
        #expect(abs((pts.first?.rms ?? 0) - 0.089) < 1e-6)
        var recent = [tt_envelope_point](repeating: tt_envelope_point(), count: 300)
        let n = recent.withUnsafeMutableBufferPointer { tt_envelope_read_recent(env, $0.baseAddress!, 300) }
        #expect(n == 300 && recent[0].seq == 300 && recent[299].seq == 599)
    }

    /// A producer thread pushes 100k windows whose level encodes their sequence number while
    /// the reader follows with a cursor: no torn point, no reordering, and read + lost covers
    /// every point.
    @Test func producerAndReaderOnTwoThreads() throws {
        let envelope = try #require(tt_envelope_create(Self.window, 500))
        defer { tt_envelope_destroy(envelope) }
        nonisolated(unsafe) let env = envelope
        let total: UInt64 = 100_000
        let done = ManagedAtomicFlag()
        let producer = Thread {
            let w = UnsafeMutablePointer<Float>.allocate(capacity: 480)
            w.initialize(repeating: 0, count: 480)
            defer { w.deallocate() }
            for s in 0..<total {
                w.update(repeating: Float(s % 1000) / 1000, count: 480)
                tt_envelope_push(env, w, 480, 1, 1000 + s * 480 * 500)
            }
            done.set()
        }
        producer.start()
        var cursor: UInt64 = 0
        var got: UInt64 = 0
        var bad = 0
        var last: UInt64?
        var buf = [tt_envelope_point](repeating: tt_envelope_point(), count: 64)
        while true {
            let finished = done.isSet
            let n = buf.withUnsafeMutableBufferPointer { tt_envelope_read(env, &cursor, $0.baseAddress!, 64) }
            for p in buf[0..<Int(n)] {
                let want = Float(p.seq % 1000) / 1000
                if abs(p.rms - want) > 1e-6 || p.peak != want || p.host_ticks != 1000 + p.seq * 480 * 500 ||
                    (last.map { p.seq <= $0 } ?? false) {
                    bad += 1
                }
                last = p.seq
            }
            got += UInt64(n)
            if finished && cursor == tt_envelope_count(env) { break }
        }
        while !producer.isFinished { usleep(100) }
        #expect(bad == 0)
        #expect(got + tt_envelope_lost_points(env) == total)
    }
}
