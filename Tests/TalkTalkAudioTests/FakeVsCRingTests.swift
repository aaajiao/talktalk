import CAudioCore
import Foundation
import Testing
@testable import TalkTalkAudio
import TalkTalkCore

/// FakePlayoutRing against the C ring (RingO + tt_ring_playout_read): the same producer calls and
/// read calls on both, compared sample by sample and event by event (review E).
@Suite struct FakeVsCRingTests {
    /// The C consumer with the events feedIOProc derives from a report (handle_o_report order).
    final class CReader {
        let ring: RingO
        var resumeFrames = 3840
        init(_ ring: RingO) { self.ring = ring }

        func consume(_ frames: Int, at now: HostTime) -> ([Float], [PlayoutRingEvent]) {
            var out = [Float](repeating: .nan, count: frames)
            var rep = tt_ring_playout_report()
            _ = out.withUnsafeMutableBufferPointer {
                tt_ring_playout_read(ring.raw, $0.baseAddress!, UInt32(frames), UInt32(resumeFrames), &rep)
            }
            return (out, Self.events(rep, at: now))
        }

        /// One cycle in which the feed plays ringP or nothing (tt_ring_playout_suspend).
        func suspend(at now: HostTime) -> [PlayoutRingEvent] {
            var rep = tt_ring_playout_report()
            tt_ring_playout_suspend(ring.raw, &rep)
            return Self.events(rep, at: now)
        }

        /// handle_o_report (tt_ioproc_feed.c): ENDED, CUT, FLUSHED, UNDERRUN (rank 0), PARKED (1),
        /// RESUMED (2), first samples (3), each at its own offset, then C's insertion sort by
        /// (offset, rank). Written separately from FakePlayoutRing.handleOrder, so a wrong order
        /// on the fake side shows here.
        static func events(_ rep: tt_ring_playout_report, at now: HostTime) -> [PlayoutRingEvent] {
            func t(_ offset: UInt32) -> HostTime { now + HostTime(Double(offset) / 48_000 * 1e9) }
            var items: [(offset: Int, rank: Int, event: PlayoutRingEvent)] = []
            let e = rep.events, skipped = Int(rep.cut_dropped)
            if e & TT_RING_EV_ENDED != 0 { items.append((Int(rep.ended_offset), 0, .ended(at: t(rep.ended_offset)))) }
            if e & TT_RING_EV_CUT != 0 {
                items.append((Int(rep.cut_offset), 0, .clauseCut(tag: rep.cut_tag, skipped: skipped, at: t(rep.cut_offset))))
            }
            if e & TT_RING_EV_FLUSHED != 0 {
                items.append((Int(rep.cut_offset), 0, .flushed(tag: rep.cut_tag, skipped: skipped, at: t(rep.cut_offset))))
            }
            if e & TT_RING_EV_UNDERRUN != 0 { items.append((Int(rep.zero_offset), 0, .underrun(at: t(rep.zero_offset)))) }
            if e & TT_RING_EV_PARKED != 0 { items.append((Int(rep.parked_offset), 1, .parked(at: t(rep.parked_offset)))) }
            if e & TT_RING_EV_RESUMED != 0 { items.append((Int(rep.resumed_offset), 2, .resumed(at: t(rep.resumed_offset)))) }
            let tags = withUnsafeBytes(of: rep.start_tag) { Array($0.bindMemory(to: UInt32.self)) }
            let offs = withUnsafeBytes(of: rep.start_offset) { Array($0.bindMemory(to: UInt32.self)) }
            for k in 0..<Int(rep.start_count) { items.append((Int(offs[k]), 3, .firstSample(tag: tags[k], at: t(offs[k])))) }
            // Insertion sort (stable) by offset, then rank, line by line as in handle_o_report.
            var i = 1
            while i < items.count {
                let x = items[i]
                var j = i
                while j > 0 && (items[j - 1].offset > x.offset || (items[j - 1].offset == x.offset && items[j - 1].rank > x.rank)) {
                    items[j] = items[j - 1]
                    j -= 1
                }
                items[j] = x
                i += 1
            }
            return items.map(\.event)
        }
    }

    /// Both rings driven in lockstep; every call's result is compared.
    struct Pair {
        let fake: FakePlayoutRing
        let c: CReader
        var now: HostTime = 0
        var counter = 0
        var events: [PlayoutRingEvent] = []

        init(capacity: Int = 8192, lead: Int = 4000, resume: Int = 3840) throws {
            fake = FakePlayoutRing(capacityFrames: capacity, maxLeadFrames: lead, resumeFrames: resume)
            c = CReader(try #require(RingO(minCapacityFrames: capacity, maxLeadFrames: lead)))
            c.resumeFrames = resume
            #expect(fake.capacityFrames == c.ring.capacityFrames)
        }

        /// Distinct nonzero sample values so a misplaced frame shows.
        mutating func write(_ frames: Int, _ marks: PlayoutMarks, tag: UInt32, _ note: Comment = "") {
            let a = (0..<frames).map { i in Float((counter + i) % 997 + 1) / 1000 }
            let nf = fake.write(a[...], marks: marks, tag: tag)
            let nc = c.ring.write(a[...], marks: marks, tag: tag)
            counter += max(nf, 0)
            #expect(nf == nc, "write \(frames) \(marks.rawValue) \(note)")
            compareState(note)
        }

        mutating func consume(_ frames: Int, _ note: Comment = "") {
            let fo = fake.consume(frames, at: now)
            let fe = fake.drainEvents()
            let (co, ce) = c.consume(frames, at: now)
            now += HostTime(Double(frames) / 48_000 * 1e9)
            if let i = fo.indices.first(where: { fo[$0] != co[$0] }) {
                Issue.record("sample \(i) of \(frames): fake \(fo[i]) C \(co[i]) \(note)")
            }
            #expect(fe == ce, "events \(note)")
            events += fe
            compareState(note)
        }

        /// A cycle in which the feed does not read the ring (passthrough), 5 ms of time.
        mutating func suspend(_ note: Comment = "") {
            fake.suspend(at: now)
            let fe = fake.drainEvents()
            let ce = c.suspend(at: now)
            now += HostTime(Double(240) / 48_000 * 1e9)
            #expect(fe == ce, "suspend events \(note)")
            events += fe
            compareState(note)
        }

        mutating func pause(_ p: Bool) { fake.setPause(p); c.ring.setPause(p) }

        mutating func jump(_ k: PlayoutJump, _ note: Comment = "") {
            let a = fake.requestJump(k), b = c.ring.requestJump(k)
            #expect(a == b, "requestJump \(note)")
            compareState(note)
        }

        mutating func reset() { fake.reset(); c.ring.reset(); compareState("reset") }

        func compareState(_ note: Comment) {
            #expect(fake.availableFrames == c.ring.availableFrames, "available \(note)")
            #expect(fake.writtenFrames == c.ring.writtenFrames, "written \(note)")
            #expect(fake.leadRoom == c.ring.leadRoom, "leadRoom \(note)")
            #expect(fake.isParked == c.ring.isParked, "parked \(note)")
            #expect(fake.jumpPending == c.ring.jumpPending, "jumpPending \(note)")
            #expect(fake.underruns == c.ring.underruns, "underruns \(note)")
        }
    }

    /// The case review E names: a START inside the hold-back when the hold-back fades out as an
    /// underrun is reported and retired, not left behind as a stale mark.
    @Test func startInsideTheUnderrunFadeIsReported() throws {
        var p = try Pair()
        p.write(1000, [.start, .end], tag: 1)
        p.write(100, [.start], tag: 2)              // clause 2 starts 100 frames before the write index
        p.consume(512)
        p.consume(512)
        p.consume(128)                               // through the hold-back fade (860..<1100): underrun
        #expect(p.fake.state == .underrun)
        p.write(4000, [.end], tag: 2)
        p.consume(512); p.consume(512); p.consume(4096)
        #expect(p.fake.state == .idle)
        // Clause 2's first sample was reported inside the fade; no second one, no stale mark.
        let firsts = p.events.compactMap { if case .firstSample(let t, _) = $0 { t } else { nil } }
        #expect(firsts == [1, 2])
        #expect(p.events.filter { if case .underrun = $0 { true } else { false } }.count == 1)
    }

    /// Pause requested with a START inside the hold-back: park on it (fade before it), no underrun.
    @Test func pauseWinsOverTheHoldBackFade() throws {
        var p = try Pair()
        p.write(1000, [.start, .end], tag: 1)
        p.write(100, [.start], tag: 2)
        p.pause(true)
        p.consume(512)
        p.consume(512)
        #expect(p.fake.isParked)
        #expect(p.fake.underruns == 0)
        p.pause(false)
        p.write(4000, [.end], tag: 2)
        p.consume(1024); p.consume(4096)
        let firsts = p.events.compactMap { if case .firstSample(let t, _) = $0 { t } else { nil } }
        #expect(firsts == [1, 2])
    }

    @Test func cutThenNextClauseInOneRead() throws {
        var p = try Pair(lead: 8000)
        p.write(3000, [.start, .end], tag: 1)
        p.write(3000, [.start, .end], tag: 2)
        p.consume(512)
        p.jump(.nextStart)
        p.consume(4096)                              // 30 ms fade, cut, clause 2 starts in the same read
        p.jump(.writeIndex)
        p.consume(512)
        p.consume(512)
        let kinds = p.events.map { e -> String in
            switch e {
            case .firstSample(let t, _): "first\(t)"
            case .clauseCut(let t, _, _): "cut\(t)"
            default: "\(e)".components(separatedBy: "(").first!
            }
        }
        #expect(kinds.starts(with: ["first1", "cut1", "first2"]))   // output order (811be22)
    }

    /// A flush drops the marks pushed before the request, a zero-frame START at the request's
    /// write index included: clause 2 never reports a first sample, clause 3 (written after the
    /// flush at the same position) does (review [6]; a fake that kept those marks diverged on
    /// none of the random seeds).
    @Test func flushDropsAZeroFrameStartAtTheRequestWriteIndex() throws {
        var p = try Pair()
        p.write(1000, [.start, .end], tag: 1)
        p.write(0, [.start], tag: 2)                 // START at 1000 with no frames yet
        p.jump(.writeIndex)
        p.consume(512)
        p.write(1000, [.start, .end], tag: 3)        // START at 1000 again, after the flush
        p.consume(512)
        let firsts = p.events.compactMap { if case .firstSample(let t, _) = $0 { t } else { nil } }
        #expect(!firsts.contains(2))
        #expect(firsts.filter { $0 != 1 } == [3])
    }

    /// Random producer/consumer scripts, including pause, both jumps, suspend (passthrough
    /// cycles), zero-frame writes (marks only), lead limit, mark overflow and reset.
    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64])
    func randomScriptsAgree(seed: UInt64) throws {
        var rng = SplitMix(seed: seed)
        let resume = [1, 240, 960, 3840][Int(rng.next() % 4)]
        var p = try Pair(capacity: 8192, lead: [1500, 4000, 8192][Int(rng.next() % 3)], resume: resume)
        var tag: UInt32 = 1
        for step in 0..<1500 {
            let note: Comment = "seed \(seed) step \(step)"
            switch rng.next() % 100 {
            case 0..<38:
                var m: PlayoutMarks = []
                if rng.next() % 4 == 0 { m.insert(.start); tag &+= 1 }
                if rng.next() % 5 == 0 { m.insert(.end) }
                p.write(rng.next() % 20 == 0 ? 0 : Int(rng.next() % 700), m, tag: tag, note)   // 5 % zero-frame
            case 38..<46: p.pause(rng.next() % 3 == 0)
            case 46..<52: p.jump(rng.next() % 2 == 0 ? .nextStart : .writeIndex, note)
            case 52..<53: p.reset()
            case 53..<58: p.suspend(note)
            default: p.consume([1, 64, 240, 256, 512, 512, 1024, 2048][Int(rng.next() % 8)], note)
            }
        }
    }

    private struct SplitMix: RandomNumberGenerator {
        var s: UInt64
        init(seed: UInt64) { s = seed }
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
