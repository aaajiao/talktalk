import CAudioCore
import Foundation
import Testing

/// ringP: the passthrough ring (generation and capture-time checks, start buffer, 2 ms underrun
/// fade, 60 ms latency bound, flush).
@Suite struct RingPTests {
    static let tpf = 500.0          // mach ticks per 48 kHz frame on Apple silicon
    static let host0: UInt64 = 1_000_000

    private func ticks(_ frame: Int) -> UInt64 { Self.host0 + UInt64(Double(frame) * Self.tpf) }

    /// Writes `frames` frames whose values are first+1, first+2, ... (or `value`), captured from
    /// frame index `at` on.
    @discardableResult
    private func write(_ rp: OpaquePointer, at: Int, frames: Int, gen: UInt32, value: Float? = nil) -> UInt32 {
        let buf = (0..<frames).map { value ?? Float(at + $0 + 1) }
        return buf.withUnsafeBufferPointer { tt_ringp_write(rp, $0.baseAddress!, UInt32(frames), ticks(at), gen) }
    }

    private func read(_ rp: OpaquePointer, _ frames: Int, gen: UInt32 = 1, from: UInt64 = 0,
                      until: UInt64 = .max) -> ([Float], tt_ringp_report) {
        var out = [Float](repeating: .nan, count: frames)
        var rep = tt_ringp_report()
        let n = out.withUnsafeMutableBufferPointer { tt_ringp_read(rp, $0.baseAddress!, UInt32(frames), gen, from, until, &rep) }
        #expect(n == UInt32(frames))
        return (out, rep)
    }

    @Test func generationComparisonWraps() {
        #expect(tt_ringp_gen_before(1, 2))
        #expect(!tt_ringp_gen_before(2, 2))
        #expect(tt_ringp_gen_before(0xFFFF_FFFF, 0))
        #expect(!tt_ringp_gen_before(0, 0xFFFF_FFFF))
    }

    @Test func waitsForTheStartBufferThenFadesInOverFiveMilliseconds() throws {
        let rp = try #require(tt_ringp_create(Self.tpf))
        defer { tt_ringp_destroy(rp) }
        write(rp, at: 0, frames: 700, gen: 1, value: 1)
        let (z, rz) = read(rp, 480)
        #expect(z.allSatisfy { $0 == 0 })
        #expect(rz.audio_frames == 0 && rz.underrun == 0)
        write(rp, at: 700, frames: 300, gen: 1, value: 1)
        let (a, ra) = read(rp, 480)
        #expect(ra.first_audio == 1)
        #expect(ra.first_offset == 0)
        #expect(ra.first_src_ticks == ticks(0))
        for i in 0..<240 { #expect(a[i] == tt_fade_in_gain(UInt32(i), 240)) }
        #expect(a[240..<480].allSatisfy { $0 == 1 })
    }

    @Test func runningDryFadesOutOverTwoMillisecondsAndCountsAnUnderrun() throws {
        let rp = try #require(tt_ringp_create(Self.tpf))
        defer { tt_ringp_destroy(rp) }
        write(rp, at: 0, frames: 1000, gen: 1, value: 1)
        _ = read(rp, 480)
        let (b, rb) = read(rp, 600)
        #expect(b[0..<424].allSatisfy { $0 == 1 })
        for i in 0..<96 { #expect(b[424 + i] == tt_fade_out_gain(UInt32(i), 96)) }
        #expect(b[520..<600].allSatisfy { $0 == 0 })
        #expect(rb.underrun == 1)
        #expect(rb.audio_frames == 520)
        #expect(tt_ringp_underruns(rp) == 1)
        #expect(tt_ringp_fill(rp) == 0)
        // Resume: the start buffer again, then a 2 ms fade-in (not the 5 ms one of an open).
        write(rp, at: 1000, frames: 719, gen: 1, value: 1)
        #expect(read(rp, 480).1.audio_frames == 0)
        write(rp, at: 1719, frames: 100, gen: 1, value: 1)
        let (c, rc) = read(rp, 480)
        #expect(rc.first_audio == 0)
        for i in 0..<96 { #expect(c[i] == tt_fade_in_gain(UInt32(i), 96)) }
        #expect(c[96..<480].allSatisfy { $0 == 1 })
    }

    @Test func olderGenerationsAreDiscardedAndNewerOnesWait() throws {
        let rp = try #require(tt_ringp_create(Self.tpf))
        defer { tt_ringp_destroy(rp) }
        write(rp, at: 0, frames: 500, gen: 1, value: .nan)   // leftovers of an earlier open
        write(rp, at: 500, frames: 1000, gen: 2, value: 1)
        // Reading generation 1 sees only its own blocks: generation 2 is neither read nor dropped.
        let (_, r1) = read(rp, 100, gen: 1)
        #expect(r1.stale == 0)
        #expect(tt_ringp_fill(rp) == 1500)
        let (out, rep) = read(rp, 480, gen: 2)
        #expect(rep.stale == 500)
        #expect(tt_ringp_stale_frames(rp) == 500)
        #expect(!out.contains { $0.isNaN })
        #expect(rep.first_src_ticks == ticks(500))
        #expect(out[240..<480].allSatisfy { $0 == 1 })
    }

    @Test func framesCapturedBeforeTheOpenAreNeverPlayed() throws {
        let rp = try #require(tt_ringp_create(Self.tpf))
        defer { tt_ringp_destroy(rp) }
        write(rp, at: 0, frames: 2000, gen: 1)   // values 1, 2, ... = frame index + 1
        let (out, rep) = read(rp, 480, from: ticks(100))
        #expect(rep.out_of_interval == 100)        // frames 0..99; frame 100 is at the open time
        #expect(rep.first_src_ticks == ticks(100))
        #expect(out[0] == 0)                       // 101 × fade-in gain 0
        #expect(out[1] == 102 * tt_fade_in_gain(1, 240))
        #expect(out[240] == 341)
        #expect(tt_ringp_out_of_interval_frames(rp) == 100)
    }

    @Test func framesCapturedAtOrAfterTheLeaseEndAreNeverPlayed() throws {
        let rp = try #require(tt_ringp_create(Self.tpf))
        defer { tt_ringp_destroy(rp) }
        write(rp, at: 0, frames: 2000, gen: 1)
        var played: [Float] = []
        var expired: UInt32 = 0
        for _ in 0..<6 {
            let (out, rep) = read(rp, 480, until: ticks(1500))
            played += out[0..<Int(rep.audio_frames)]
            expired += rep.expired
        }
        #expect(played.count == 1500)
        #expect(played.allSatisfy { $0 <= 1500 })   // frame 1499 has value 1500
        #expect(expired == 500)
        #expect(tt_ringp_expired_frames(rp) == 500)
        #expect(tt_ringp_fill(rp) == 0)
    }

    @Test func latencyIsBoundedAtSixtyMillisecondsWithACrossfade() throws {
        let rp = try #require(tt_ringp_create(Self.tpf))
        defer { tt_ringp_destroy(rp) }
        write(rp, at: 0, frames: 5000, gen: 1)
        _ = read(rp, 480)   // the 5 ms fade-in runs first; no drop meanwhile
        let (out, rep) = read(rp, 480)
        // keep = need (480) + start buffer (720) = 1200 frames: jump from 480 to 3800.
        #expect(rep.dropped_old == 3320)
        for i in 0..<96 {
            let g = tt_fade_in_gain(UInt32(i), 96)
            let expected = Float(481 + i) * (1 - g) + Float(3801 + i) * g
            #expect(abs(out[i] - expected) <= 0.01)
        }
        for j in 0..<384 { #expect(out[96 + j] == Float(3897 + j)) }
        #expect(tt_ringp_dropped_old_frames(rp) == 3320)
    }

    @Test func flushEmptiesTheRingAndTheNextOpenFadesInAgain() throws {
        let rp = try #require(tt_ringp_create(Self.tpf))
        defer { tt_ringp_destroy(rp) }
        write(rp, at: 0, frames: 2000, gen: 1, value: 1)
        _ = read(rp, 480)
        tt_ringp_flush(rp)
        #expect(tt_ringp_fill(rp) == 0)
        #expect(tt_ringp_flushed_frames(rp) == 1520)
        #expect(read(rp, 480).0.allSatisfy { $0 == 0 })
        write(rp, at: 2000, frames: 1000, gen: 2, value: 1)
        let (out, rep) = read(rp, 480, gen: 2)
        #expect(rep.first_audio == 1)
        for i in 0..<240 { #expect(out[i] == tt_fade_in_gain(UInt32(i), 240)) }
    }

    @Test func discardThroughKeepsOnlyNewerGenerations() throws {
        let rp = try #require(tt_ringp_create(Self.tpf))
        defer { tt_ringp_destroy(rp) }
        write(rp, at: 0, frames: 300, gen: 1, value: .nan)
        write(rp, at: 300, frames: 300, gen: 2, value: .nan)
        write(rp, at: 600, frames: 1000, gen: 3, value: 1)
        tt_ringp_discard_through(rp, 2)
        #expect(tt_ringp_fill(rp) == 1000)
        #expect(tt_ringp_stale_frames(rp) == 600)
        let (out, rep) = read(rp, 480, gen: 3)
        #expect(rep.first_audio == 1)
        #expect(!out.contains { $0.isNaN })
    }

    @Test func overflowIsRefusedAndCounted() throws {
        let rp = try #require(tt_ringp_create(Self.tpf))
        defer { tt_ringp_destroy(rp) }
        #expect(write(rp, at: 0, frames: 9000, gen: 1, value: 1) == 9000)
        #expect(write(rp, at: 9000, frames: 1000, gen: 1, value: 1) == 600)   // 200 ms
        #expect(tt_ringp_overrun_frames(rp) == 400)
        #expect(tt_ringp_written_frames(rp) == 9600)
        let rq = try #require(tt_ringp_create(Self.tpf))
        defer { tt_ringp_destroy(rq) }
        for k in 0..<Int(TT_RINGP_MAX_BLOCKS) { #expect(write(rq, at: k, frames: 1, gen: 1, value: 1) == 1) }
        #expect(write(rq, at: 256, frames: 1, gen: 1, value: 1) == 0)   // block queue full
        #expect(tt_ringp_overrun_frames(rq) == 1)
    }

    /// Whether o[at ..< at + 95] are frames 1...95 of the 2 ms crossfade from the ring frames
    /// valued old, old + 1, ... to the frames `dropped` later, exactly as tt_ringp_read computes
    /// them (with or without a fused multiply-add).
    private static func isCrossfade(_ o: UnsafeBufferPointer<Float>, at: Int, old: Float, dropped: Float) -> Bool {
        for j in 1..<96 {
            let g = tt_fade_in_gain(UInt32(j), 96)
            let a = old + Float(j - 1)
            let b = a + dropped
            let v = o[at + j - 1]
            if v != a * (1 - g) + b * g && v != (a * (1 - g)).addingProduct(b, g) && v != (b * g).addingProduct(a, 1 - g) {
                return false
            }
        }
        return true
    }

    /// SPSC stress: 10^7 frames in random blocks from a producer thread, random reads on the
    /// consumer. Ring frame k carries the value k + 1 (the producer numbers what was stored), so
    /// the consumer knows the value of every frame it takes and checks each one exactly: a copy
    /// equals it, a fade frame is below it (fades: 5 ms at the open, 2 ms before and after each
    /// underrun), and a crossfade over a latency drop mixes exactly the frames the report says
    /// were dropped. Frames are lost only where the design says (overflow and the 60 ms bound,
    /// both counted): written = played + dropped_old + left, exactly.
    @Test func spscStressAccountsForEveryFrame() throws {
        let ring = try #require(tt_ringp_create(Self.tpf))
        defer { tt_ringp_destroy(ring) }
        let total = 10_000_000
        nonisolated(unsafe) let rp = ring
        let done = ManagedAtomicFlag()
        let producer = Thread {
            var prng = RTRandom(seed: 3)
            var buf = [Float](repeating: 0, count: 1000)
            var pos = 0      // source frames offered
            var stored = 0   // ring frames stored
            while pos < total {
                let m = min(prng.int(1...1000), total - pos)
                for i in 0..<m { buf[i] = Float(stored + i + 1) }
                let n = buf.withUnsafeBufferPointer {
                    tt_ringp_write(rp, $0.baseAddress!, UInt32(m), RingPTests.host0 + UInt64(pos) * 500, 1)
                }
                stored += Int(n)
                pos += m
                if prng.chance(3) { usleep(10) }
            }
            done.set()
        }
        producer.start()
        var rng = RTRandom(seed: 11)
        var out = [Float](repeating: 0, count: 1024)
        var next: Float = 1   // value of the next ring frame the reader takes
        var audio = 0
        var dropped = 0
        var fadeFrames = 0
        var crossfades = 0
        var flagMismatch = 0
        var bad = 0
        let deadline = Date().addingTimeInterval(120)
        var readsAfterDone = 0
        while Date() < deadline {
            let n = rng.int(1...1024)
            var rep = tt_ringp_report()
            let before = tt_ringp_underruns(rp)   // only reads count underruns: exact per call
            _ = out.withUnsafeMutableBufferPointer { tt_ringp_read(rp, $0.baseAddress!, UInt32(n), 1, 0, .max, &rep) }
            if done.isSet { readsAfterDone += 1 }
            audio += Int(rep.audio_frames)
            dropped += Int(rep.dropped_old)
            // The flag says whether any began; a read longer than the start buffer can hold two.
            if (tt_ringp_underruns(rp) > before) != (rep.underrun != 0) { flagMismatch += 1 }
            let d = Float(rep.dropped_old)
            out.withUnsafeBufferPointer { o in
                let count = Int(rep.audio_frames)
                var sawCrossfade = false
                var i = 0
                while i < count {
                    // Crossfade frame 0 has gain 0: it is the exact old frame, taken as a copy.
                    // At most one crossfade per call: a read of <= 1024 frames ends within the bound.
                    if d > 0 && !sawCrossfade && i + 95 <= count && Self.isCrossfade(o, at: i, old: next, dropped: d) {
                        sawCrossfade = true
                        next += d + 95
                        i += 95
                        continue
                    }
                    let v = o[i]
                    if v == next {
                    } else if v >= 0 && v < next {
                        fadeFrames += 1
                    } else {
                        bad += 1
                    }
                    next += 1
                    i += 1
                }
                if (d > 0) != sawCrossfade { bad += 1 }
                if sawCrossfade { crossfades += 1 }
                for k in count..<n where o[k] != 0 { bad += 1 }
            }
            // A tail shorter than the start buffer never plays; it stays counted in the fill.
            if done.isSet && (tt_ringp_fill(rp) == 0 || readsAfterDone > 64) { break }
        }
        #expect(bad == 0)
        #expect(Int(next) - 1 == audio + dropped)   // every frame taken was checked
        #expect(Int(tt_ringp_written_frames(rp) + tt_ringp_overrun_frames(rp)) == total)
        #expect(audio + dropped + Int(tt_ringp_fill(rp)) == Int(tt_ringp_written_frames(rp)))
        #expect(flagMismatch == 0)
        let underruns = Int(tt_ringp_underruns(rp))
        #expect(fadeFrames <= 240 + 2 * 96 * underruns,
                "fade frames \(fadeFrames), underruns \(underruns), crossfades \(crossfades)")
        #expect(tt_ringp_stale_frames(rp) == 0 && tt_ringp_out_of_interval_frames(rp) == 0)
    }

    /// SPSC stress across generations, like PassthroughStage and feedIOProc: the producer opens a
    /// new generation after every lease (tt_pt_state, random gap and length) and writes blocks
    /// in capture time with the current generation, for a random while past the lease end too;
    /// right after an open, first a few late ones with the previous (a writer's tags never go
    /// back). Every frame that must never play (an older generation, captured before the open or
    /// at or after the lease end) is NaN. The consumer acts like feedIOProc: it reads with the
    /// pt_state it sees, learns of a lease end up to 600 frames late (its clock is the capture time
    /// written so far), then makes one closing read and flushes, and never plays that generation
    /// again; it also flushes or discards older generations at random. No NaN is ever played, and
    /// every frame written is accounted for exactly once.
    @Test func generationStressNeverPlaysAForbiddenFrame() throws {
        let ring = try #require(tt_ringp_create(Self.tpf))
        let state = try #require(tt_pt_state_create())
        defer { tt_ringp_destroy(ring); tt_pt_state_destroy(state) }
        nonisolated(unsafe) let rp = ring
        nonisolated(unsafe) let pt = state
        let total = 3_000_000
        final class Totals: @unchecked Sendable { var legit = 0; var opens = 0 }
        let totals = Totals()
        final class Clock: @unchecked Sendable {   // capture time written so far
            private let lock = NSLock()
            private var value = RingPTests.host0
            func set(_ t: UInt64) { lock.lock(); value = t; lock.unlock() }
            var ticks: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
        }
        let clock = Clock()
        let done = ManagedAtomicFlag()
        let stop = ManagedAtomicFlag()   // the consumer gave up: never leave the producer waiting
        let producer = Thread {
            var prng = RTRandom(seed: 21)
            var buf = [Float](repeating: 0, count: 600)
            var t = RingPTests.host0   // capture time of the next frame
            var seq: Float = 0
            var gen: UInt32 = 0
            var open: UInt64 = 0
            var close: UInt64 = 0
            var reopen: UInt64 = 0   // the writer learns of the lease end only a little later
            var offered = 0
            var late = 0   // blocks still to tag with the previous generation
            while offered < total && !stop.isSet {
                if gen == 0 || t >= reopen {
                    open = t + UInt64(prng.int(0...300)) * 500
                    close = open + UInt64(prng.int(240...20000)) * 500
                    reopen = close + UInt64(prng.int(0...3000)) * 500
                    gen = tt_pt_state_open(pt, TT_PT_SOURCE_MIC, open, close, open + 30 * 48000 * 500)
                    totals.opens += 1
                    late = gen > 1 ? prng.int(0...2) : 0
                }
                // A consumer that keeps up, with an occasional burst past the 60 ms bound.
                let limit: UInt32 = prng.chance(20) ? 6000 : 1500
                while tt_ringp_fill(rp) > limit && !stop.isSet { usleep(20) }
                let m = min(prng.int(1...600), total - offered)
                // Late blocks of the previous open come first (a writer's tags never go back).
                let tag = late > 0 ? gen - 1 : gen
                if late > 0 { late -= 1 }
                for i in 0..<m {
                    let ti = t + UInt64(i) * 500
                    if tag == gen && ti >= open && ti < close {
                        seq += 1
                        buf[i] = seq
                        totals.legit += 1
                    } else {
                        buf[i] = .nan
                    }
                }
                _ = buf.withUnsafeBufferPointer { tt_ringp_write(rp, $0.baseAddress!, UInt32(m), t, tag) }
                t += UInt64(m) * 500
                clock.set(t)
                offered += m
            }
            done.set()
        }
        producer.start()
        var rng = RTRandom(seed: 22)
        var out = [Float](repeating: 0, count: 1024)
        var audio = 0
        var dropped = 0
        var played = 0
        var nanFrames = 0
        var bad = 0
        var flushes = 0
        var discards = 0
        var controlAt = rng.int(10_000...100_000)   // audio frames until the next random flush / discard
        var doneGen: UInt32 = 0   // seen not live: never played again (feedIOProc's done_gen)
        var closing = false       // the closing read of doneGen is still to make
        var readStale = 0, readEarly = 0, readExpired = 0   // what the reads themselves discarded
        var readsAfterDone = 0
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            var snap = tt_pt_state_read(pt)
            let lag = UInt64(rng.int(0...600)) * 500
            let c = clock.ticks
            let now = c > lag ? c - lag : 0
            if snap.valid != 0 && snap.generation != 0 && snap.generation != doneGen && !tt_pt_snapshot_live(&snap, now) {
                doneGen = snap.generation
                closing = true
            }
            if snap.valid == 0 || snap.generation == 0 {
                tt_ringp_flush(rp)   // what feedIOProc does without a consistent open state
            } else if snap.generation == doneGen && !closing {
                tt_ringp_flush(rp)   // finished: feedIOProc is back on ringO and plays none of it
            } else if audio >= controlAt && !closing {
                controlAt = audio + rng.int(10_000...100_000)
                if rng.chance(2) {
                    tt_ringp_flush(rp)
                    flushes += 1
                } else {
                    tt_ringp_discard_through(rp, snap.generation &- 1)
                    discards += 1
                }
            } else {
                let n = rng.int(1...1024)
                var rep = tt_ringp_report()
                let until = tt_pt_snapshot_valid_until(&snap)
                _ = out.withUnsafeMutableBufferPointer {
                    tt_ringp_read(rp, $0.baseAddress!, UInt32(n), snap.generation, snap.open_ticks, until, &rep)
                }
                audio += Int(rep.audio_frames)
                dropped += Int(rep.dropped_old)
                readStale += Int(rep.stale)
                readEarly += Int(rep.out_of_interval)
                readExpired += Int(rep.expired)
                out.withUnsafeBufferPointer { o in
                    for i in 0..<Int(rep.audio_frames) {
                        if o[i].isNaN { nanFrames += 1 } else if !(o[i] >= 0) { bad += 1 } else if o[i] > 0 { played += 1 }
                    }
                    for i in Int(rep.audio_frames)..<n where o[i] != 0 { bad += 1 }   // NaN != 0 too
                }
                if closing {   // PT_CLOSING: one last read up to the lease end, then an empty ringP
                    closing = false
                    tt_ringp_flush(rp)
                }
            }
            if done.isSet {
                readsAfterDone += 1
                if tt_ringp_fill(rp) == 0 || readsAfterDone > 64 { break }
            }
        }
        let finished = done.isSet
        stop.set()
        while !producer.isFinished { usleep(100) }
        #expect(finished, "the consumer stalled")
        #expect(nanFrames == 0)
        #expect(bad == 0)
        let written = Int(tt_ringp_written_frames(rp))
        #expect(written + Int(tt_ringp_overrun_frames(rp)) == total)
        let discarded = Int(tt_ringp_stale_frames(rp) + tt_ringp_out_of_interval_frames(rp) +
                            tt_ringp_expired_frames(rp) + tt_ringp_flushed_frames(rp))
        #expect(written == audio + dropped + discarded + Int(tt_ringp_fill(rp)))
        // The paths this is about were all taken.
        #expect(totals.opens > 100 && played > totals.legit / 4, "opens \(totals.opens), played \(played) of \(totals.legit)")
        #expect(readStale > 0 && readEarly > 0 && readExpired > 0,
                "stale \(readStale), out of interval \(readEarly), expired \(readExpired)")
        #expect(flushes > 0 && discards > 0)
    }
}
