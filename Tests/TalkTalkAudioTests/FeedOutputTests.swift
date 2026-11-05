import CAudioCore
import CoreAudio
import Foundation
import Testing
import TalkTalkCore
@testable import TalkTalkAudio

/// FeedOutput's own wiring, offline (no device): the context built from its rings and states,
/// driven one IO cycle at a time through `processOffline` exactly as feedIOProc runs.
/// The C IOProc itself is covered by FeedIOProcTests.
private final class OfflineFeed {
    let feed: FeedOutput
    let baseNs: HostTime = 1_000_000_000_000          // 1000 s of uptime
    var frame = 0
    private let maxFrames = 4096
    private let list = AudioBufferList.allocate(maximumBuffers: 1)
    private let storage: UnsafeMutablePointer<Float>
    private(set) var ch1: [Float] = []
    private(set) var ch2: [Float] = []
    private(set) var events: [tt_event] = []

    init() throws {
        feed = try FeedOutput(ringO: try #require(RingO()), events: try #require(EventRing(minCapacity: 4096)))
        storage = .allocate(capacity: 2 * maxFrames)
        storage.initialize(repeating: 0, count: 2 * maxFrames)
    }

    deinit {
        free(list.unsafeMutablePointer)
        storage.deallocate()
    }

    var baseTicks: UInt64 { HostClock.machTicks(fromNanos: baseNs) }
    func ticks(_ frame: Int) -> UInt64 { baseTicks + UInt64((Double(frame) * FeedOutput.hostTicksPerFrame).rounded()) }
    func ns(ms: Int) -> HostTime { baseNs + HostTime(ms) * 1_000_000 }

    /// One cycle of `frames` at the current frame; appends both channels and drains events.
    @discardableResult
    func cycle(_ frames: Int = 480) -> Bool {
        storage.update(repeating: 777, count: 2 * frames)
        list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(2 * frames * 4), mData: storage)
        let ran = feed.processOffline(list.unsafeMutablePointer, frames: UInt32(frames), outHostTicks: ticks(frame))
        if ran {
            ch1 += (0..<frames).map { storage[2 * $0] }
            ch2 += (0..<frames).map { storage[2 * $0 + 1] }
            events += feed.events.drain(max: 4096)
        }
        frame += frames
        return ran
    }

    func writeClause(_ value: Float, frames: Int, tag: UInt32) {
        let buf = [Float](repeating: value, count: frames)
        _ = buf.withUnsafeBufferPointer { feed.ringO.writeClause($0, frames: frames, marks: [.start, .end], tag: tag) }
    }

    /// One ringP block (what PassthroughStage writes) captured at `frame`.
    func writeP(at frame: Int, _ frames: Int, generation: UInt32, _ value: Float) {
        let buf = [Float](repeating: value, count: frames)
        _ = buf.withUnsafeBufferPointer { tt_ringp_write(feed.ringP.raw, $0.baseAddress!, UInt32(frames), ticks(frame), generation) }
    }
}

@Suite struct FeedOutputTests {
    @Test func ttsGoesToChannelOneWithEventsAndEnvelope() throws {
        let o = try OfflineFeed()
        try o.feed.attachOffline()
        #expect(o.feed.isAttached && o.feed.attachedAt != nil)
        #expect(!o.feed.isChannel1Busy)                       // attached, nothing queued
        o.writeClause(0.25, frames: 4800, tag: 7)
        #expect(o.feed.isChannel1Busy)
        for _ in 0..<15 { o.cycle() }

        let firstAudio = try #require(o.ch1.firstIndex { $0 != 0 })
        #expect(o.ch1.contains(0.25))
        #expect(o.ch2.allSatisfy { $0 == 0 })                 // ringO never reaches channel 2
        #expect(o.ch1.count == o.frame)

        let ringEvents = o.events.compactMap(PlayoutRingEvent.init)
        guard case let .firstSample(tag, at)? = ringEvents.first else {
            Issue.record("first event \(String(describing: ringEvents.first))"); return
        }
        #expect(tag == 7)
        // Arrival at TalkTalk Mic: output time + the driver's 480-frame lag, within a frame of the first audio.
        let expected = HostClock.nanos(fromMachTicks: o.ticks(firstAudio + Int(TT_FEED_MIC_LATENCY_FRAMES)))
        let slack = 2 * 1_000_000_000 / HostTime(FeedOutput.sampleRate)
        #expect(at + slack >= expected && at <= expected + slack)
        #expect(ringEvents.contains { if case .ended = $0 { true } else { false } })

        let points = o.feed.envelope.recent(max: 512)
        #expect(points.count == o.frame / 480)
        #expect(points.contains { $0.rms > 0.2 && $0.peak <= 0.25 + 1e-6 })
        #expect(points.first?.at == HostClock.nanos(fromMachTicks: o.ticks(Int(TT_FEED_MIC_LATENCY_FRAMES))))

        let s = o.feed.stats
        #expect(s.attached && s.callbacks == 15 && s.frames == UInt64(o.frame))
        #expect(s.ringOAudioFrames > 4000 && s.ringPAudioFrames == 0 && s.mixedCycles == 0 && s.mode == .ringO)
        #expect(!o.feed.isChannel1Busy)                       // played out: the ring is empty and idle
    }

    @Test func detachKeepsTheRingsAndTheLastStats() throws {
        let o = try OfflineFeed()
        try o.feed.attachOffline()
        o.writeClause(0.5, frames: 960, tag: 1)
        for _ in 0..<4 { o.cycle() }
        let before = o.feed.stats
        o.feed.detach()
        o.feed.detach()                                        // twice is fine
        #expect(!o.feed.isAttached && o.feed.attachedAt == nil && !o.feed.isChannel1Busy)
        #expect(!o.cycle())                                    // no context, nothing runs
        var after = o.feed.stats
        #expect(!after.attached)
        after.attached = true
        #expect(after == before)

        // A new attachment plays what is written next from the same ring with fresh counters.
        try o.feed.attachOffline()
        o.writeClause(0.5, frames: 960, tag: 2)
        for _ in 0..<4 { o.cycle() }
        #expect(o.feed.stats.callbacks == 4)
        #expect(o.events.compactMap(PlayoutRingEvent.init).contains { if case .firstSample(2, _) = $0 { true } else { false } })
    }

    @Test func chunkIntervalP95SetsTheResumeThresholdAndSurvivesReattach() throws {
        let o = try OfflineFeed()
        #expect(o.feed.resumeFrames == TT_FEED_RESUME_MIN_FRAMES)
        o.feed.setChunkIntervalP95(ms: 100)                    // before any attachment: kept
        try o.feed.attachOffline()
        o.cycle()
        #expect(o.feed.stats.resumeFrames == 9600)             // max(80 ms, 2 × 100 ms) at 48 kHz
        o.feed.detach()
        #expect(o.feed.resumeFrames == 9600)                   // the last attachment's
        try o.feed.attachOffline()
        o.cycle()
        #expect(o.feed.stats.resumeFrames == 9600 && o.feed.resumeFrames == 9600)
        o.feed.setChunkIntervalP95(ms: 10)                     // while attached: applies at once
        o.cycle()
        #expect(o.feed.stats.resumeFrames == TT_FEED_RESUME_MIN_FRAMES)
        o.feed.setChunkIntervalP95(ms: .nan)
        o.cycle()
        #expect(o.feed.stats.resumeFrames == TT_FEED_RESUME_MIN_FRAMES)
    }

    /// The sink converts ns to the IOProc's mach ticks: a lease of 100 ms ends after 100 ms of
    /// output time. Were ns passed through as ticks (125/3 ns per tick on Apple silicon), the open
    /// time would lie far after the output clock and nothing would play at all.
    @Test func passthroughLeaseEndsOnTimeThroughTheSwiftSink() throws {
        let o = try OfflineFeed()
        try o.feed.attachOffline()
        let g = o.feed.passthroughState.open(source: .mic, openAt: o.baseNs, leaseUntil: o.ns(ms: 100),
                                             deadline: o.ns(ms: 30_000))
        #expect(g == 1)
        o.writeP(at: 0, 480, generation: g, 0.5)
        o.writeP(at: 480, 480, generation: g, 0.5)
        var modes: [FeedOutput.Mode] = []
        for k in 0..<20 {
            o.writeP(at: (k + 2) * 480, 480, generation: g, 0.5)
            o.cycle()
            modes.append(o.feed.stats.mode)
        }
        #expect(modes.contains(.passthrough))
        #expect(o.ch1.contains(0.5))
        #expect(o.ch2.allSatisfy { $0 == 0 })                 // .mic never reaches channel 2
        // Lease end = 100 ms = frame 4800. The cycle at 4800 fades out; everything after it is zero.
        #expect(o.ch1[(4800 + 480)...].allSatisfy { $0 == 0 })
        #expect(o.events.contains { $0.type == UInt16(TT_EV_PT_LEASE_EXPIRED) && $0.a == g })
        #expect(o.feed.stats.mode == .ringO && o.feed.stats.mixedCycles == 0)
        #expect(!o.feed.isChannel1Busy)
    }

    @Test func selfTestPassthroughGoesToChannelTwo() throws {
        let o = try OfflineFeed()
        try o.feed.attachOffline()
        let g = o.feed.passthroughState.open(source: .selfTest, openAt: o.baseNs, leaseUntil: o.ns(ms: 1000),
                                             deadline: o.ns(ms: 30_000))
        for k in 0..<3 { o.writeP(at: k * 480, 480, generation: g, 0.5) }
        for k in 0..<6 { o.writeP(at: (k + 3) * 480, 480, generation: g, 0.5); o.cycle() }
        #expect(o.ch2.contains(0.5))
        #expect(o.ch1.allSatisfy { $0 == 0 })
        #expect(o.feed.isChannel1Busy)                         // the Feed is passthrough's: no isolation check
        #expect(o.feed.passthroughState.close(generation: g, at: o.ns(ms: 130)))
        for _ in 0..<3 { o.cycle() }
        #expect(o.feed.stats.mode == .ringO)
    }

    /// §3.6: after any detach or interruption passthrough needs a new open. A generation that was
    /// live before the detach and is renewed afterwards never plays on the new context; a
    /// generation opened while detached does not either; a new open after the attach does.
    @Test func aRenewedGenerationNeverPlaysAfterReattach() throws {
        let o = try OfflineFeed()
        try o.feed.attachOffline()
        let g = o.feed.passthroughState.open(source: .mic, openAt: o.baseNs, leaseUntil: o.ns(ms: 200),
                                             deadline: o.ns(ms: 30_000))
        func feedP(_ cycles: Int, _ gen: UInt32) {
            for _ in 0..<cycles { o.writeP(at: o.frame + 960, 480, generation: gen, 0.5); o.cycle() }
        }
        o.writeP(at: 0, 480, generation: g, 0.5)
        o.writeP(at: 480, 480, generation: g, 0.5)
        feedP(5, g)
        #expect(o.ch1.contains(0.5))                          // live and playing
        o.feed.detach()
        #expect(o.feed.passthroughState.renew(generation: g, leaseUntil: o.ns(ms: 1000)))
        try o.feed.attachOffline()
        var start = o.ch1.count
        feedP(10, g)
        #expect(o.ch1[start...].allSatisfy { $0 == 0 })
        #expect(o.feed.stats.ringPAudioFrames == 0 && o.feed.stats.mode == .ringO)

        o.feed.detach()                                        // opened while detached: not played either
        #expect(o.feed.passthroughState.close(generation: g, at: o.ns(ms: o.frame / 48)))
        let g2 = o.feed.passthroughState.open(source: .mic, openAt: o.ns(ms: o.frame / 48),
                                              leaseUntil: o.ns(ms: o.frame / 48 + 500), deadline: o.ns(ms: 30_000))
        try o.feed.attachOffline()
        start = o.ch1.count
        feedP(10, g2)
        #expect(o.ch1[start...].allSatisfy { $0 == 0 })

        #expect(o.feed.passthroughState.close(generation: g2, at: o.ns(ms: o.frame / 48)))
        let g3 = o.feed.passthroughState.open(source: .mic, openAt: o.ns(ms: o.frame / 48),
                                              leaseUntil: o.ns(ms: o.frame / 48 + 500), deadline: o.ns(ms: 30_000))
        start = o.ch1.count
        feedP(10, g3)                                          // a new open on this context plays
        #expect(o.ch1[start...].contains(0.5))
        #expect(o.feed.stats.mixedCycles == 0)
    }

    /// A listener block the HAL queued for an attachment that has ended must not tear down the next.
    @Test func aStaleListenerBlockLeavesANewAttachmentAlone() throws {
        let o = try OfflineFeed()
        let got = InterruptionLog()
        try o.feed.attachOffline(onInterruption: { got.add($0) })
        let stale = o.feed.listenerEpoch
        o.feed.detach()
        try o.feed.attachOffline(onInterruption: { got.add($0) })
        o.feed.deliverPropertyChange(kAudioHardwarePropertyServiceRestarted, epoch: stale)
        #expect(o.feed.isAttached)
        o.feed.deliverPropertyChange(kAudioHardwarePropertyServiceRestarted, epoch: o.feed.listenerEpoch)
        #expect(!o.feed.isAttached)
        #expect(got.wait(count: 1) == [.serviceRestarted])
        // Once detached, even the current epoch does nothing.
        o.feed.deliverPropertyChange(kAudioHardwarePropertyServiceRestarted, epoch: o.feed.listenerEpoch)
        #expect(got.wait(count: 2, timeout: 0.2) == [.serviceRestarted])
    }

    @Test func eventRingDrainsInOrderAndCountsDrops() throws {
        let ring = try #require(EventRing(minCapacity: 4))
        let cap = ring.capacity                                // the C floor is 64
        #expect(cap == 64)
        for i in 0..<(cap + 2) {
            _ = tt_event_push4(ring.raw, UInt16(TT_EV_OUT_UNDERRUN), UInt16(TT_EV_SRC_FEED), UInt64(i), 0, 0)
        }
        #expect(ring.pushed == UInt64(cap) && ring.dropped == 2)
        #expect(ring.drain(max: 0).isEmpty)
        #expect(ring.drain(max: 3).map(\.host_ticks) == [0, 1, 2])
        #expect(ring.drain(max: 4096).map(\.host_ticks) == (3..<UInt64(cap)).map { $0 })
        #expect(ring.drain().isEmpty)
    }
}

/// CPassthroughState against InMemoryPassthroughStateSink, the semantics the gate was written to.
/// Compared in mach ticks: the conversion floors, and min / max commute with a monotone map.
@Suite struct CPassthroughStateTests {
    @Test func matchesTheInMemorySinkOnRandomOperations() throws {
        var rng = SplitMix(seed: 0x7474_7074)
        for _ in 0..<200 {
            let c = try #require(CPassthroughState())
            let m = InMemoryPassthroughStateSink()
            var t: HostTime = 5_000_000_000 + rng.next() % 1_000_000
            for _ in 0..<40 {
                t += rng.next() % 50_000_000
                let gen = m.current.generation &+ UInt32(rng.next() % 3) &- 1
                switch rng.next() % 4 {
                case 0:
                    let src: PassthroughSource = rng.next() % 4 == 0 ? .selfTest : .mic
                    let lease = t + rng.next() % 200_000_000, deadline = t + rng.next() % 300_000_000
                    #expect(c.open(source: src, openAt: t, leaseUntil: lease, deadline: deadline) ==
                            m.open(source: src, openAt: t, leaseUntil: lease, deadline: deadline))
                case 1, 2:
                    let lease = t + rng.next() % 200_000_000
                    #expect(c.renew(generation: gen, leaseUntil: lease) == m.renew(generation: gen, leaseUntil: lease))
                default:
                    #expect(c.close(generation: gen, at: t) == m.close(generation: gen, at: t))
                }
                let s = tt_pt_state_read(c.raw), e = m.current
                let tk = HostClock.machTicks(fromNanos:)
                #expect(s.valid == 1 && (s.open != 0) == e.open && s.generation == e.generation)
                #expect(s.source == CPassthroughState.cSource(e.source))
                #expect(s.open_ticks == tk(e.openAt) && s.lease_until_ticks == tk(e.leaseUntil) &&
                        s.deadline_ticks == tk(e.deadline))
                #expect(c.current?.open == e.open && c.current?.generation == e.generation && c.current?.source == e.source)
            }
            #expect(c.failedReads == 0)
        }
    }
}

private final class InterruptionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [FeedOutput.Interruption] = []
    func add(_ i: FeedOutput.Interruption) { lock.withLock { items.append(i) } }
    /// What arrived once `count` items are there or `timeout` seconds passed (handlers run async).
    func wait(count: Int, timeout: Double = 2) -> [FeedOutput.Interruption] {
        let end = Date().addingTimeInterval(timeout)
        while lock.withLock({ items.count }) < count && Date() < end { usleep(1_000) }
        return lock.withLock { items }
    }
}

private struct SplitMix {
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
