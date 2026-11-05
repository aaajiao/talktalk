import CAudioCore
import Foundation
import Testing

/// tt_event_ring: bounded MPSC queue of host-time events (feed and monitor IOProcs produce, the
/// audio worker drains).
@Suite struct EventRingTests {
    @Test func capacityIsAPowerOfTwoOfAtLeastSixtyFour() throws {
        for (asked, want) in [(1, 64), (64, 64), (65, 128), (4096, 4096), (5000, 8192)] {
            let r = try #require(tt_event_ring_create(UInt32(asked)))
            #expect(tt_event_ring_capacity(r) == UInt32(want))
            tt_event_ring_destroy(r)
        }
    }

    @Test func eventsComeOutInPushOrderWithAllFields() throws {
        let r = try #require(tt_event_ring_create(64))
        defer { tt_event_ring_destroy(r) }
        for i in 0..<64 as Range<UInt32> {
            #expect(tt_event_push4(r, UInt16(i + 1), 2, 1000 + UInt64(i), i, 5000 + UInt64(i)))
        }
        var e = tt_event(host_ticks: 9, b: 9, a: 9, type: 9, source: 1)
        let pushedFull = tt_event_push(r, &e)   // full: dropped, never overwrites
        #expect(!pushedFull)
        #expect(tt_event_dropped(r) == 1 && tt_event_pushed(r) == 64)
        var out = [tt_event](repeating: tt_event(), count: 100)
        let n = out.withUnsafeMutableBufferPointer { tt_event_drain(r, $0.baseAddress!, 100) }
        #expect(n == 64)
        for i in 0..<Int(n) {
            let ev = out[i]
            #expect(ev.type == UInt16(i + 1) && ev.source == 2 && ev.a == UInt32(i))
            #expect(ev.host_ticks == 1000 + UInt64(i) && ev.b == 5000 + UInt64(i))
        }
        let pushedAgain = tt_event_push(r, &e)   // room again after the drain
        #expect(pushedAgain)
        let again = out.withUnsafeMutableBufferPointer { tt_event_drain(r, $0.baseAddress!, 100) }
        #expect(again == 1)
    }

    /// Four producer threads push 200k events each into a 1024-slot ring while the consumer
    /// drains: per producer the events come out in order, and pushed + dropped accounts for
    /// every push.
    @Test func fourProducersKeepTheirOrderAndEveryPushIsAccountedFor() throws {
        let ring = try #require(tt_event_ring_create(1024))
        defer { tt_event_ring_destroy(ring) }
        nonisolated(unsafe) let r = ring
        let perProducer: UInt64 = 200_000
        let done = (0..<4).map { _ in ManagedAtomicFlag() }
        let threads = (0..<4).map { id in
            Thread {
                for k in 0..<perProducer { _ = tt_event_push4(r, 9, 1, k, UInt32(id), k) }
                done[id].set()
            }
        }
        threads.forEach { $0.start() }
        var last = [Int64](repeating: -1, count: 4)
        var got: UInt64 = 0
        var bad = 0
        var buf = [tt_event](repeating: tt_event(), count: 1024)
        while true {
            let finished = done.allSatisfy { $0.isSet }
            let n = buf.withUnsafeMutableBufferPointer { tt_event_drain(r, $0.baseAddress!, 1024) }
            for i in 0..<Int(n) {
                let ev = buf[i]
                let id = Int(ev.a)
                if id > 3 || Int64(ev.b) <= last[id] || ev.host_ticks != ev.b { bad += 1 } else { last[id] = Int64(ev.b) }
            }
            got += UInt64(n)
            if finished && n == 0 { break }
        }
        while !threads.allSatisfy({ $0.isFinished }) { usleep(100) }
        #expect(bad == 0)
        #expect(got == tt_event_pushed(r))
        #expect(tt_event_pushed(r) + tt_event_dropped(r) == 4 * perProducer)
    }
}
