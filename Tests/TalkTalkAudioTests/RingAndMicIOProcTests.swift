import CAudioCore
import CoreAudio
import Foundation
import Testing
@testable import TalkTalkAudio

@Suite struct RingTests {
    @Test func capacityRoundsUpToPowerOfTwo() throws {
        let r = try #require(tt_ring_create(3000))
        defer { tt_ring_destroy(r) }
        #expect(tt_ring_capacity(r) == 4096)
    }

    @Test func writeReadPreservesOrder() throws {
        let r = try #require(tt_ring_create(1024))
        defer { tt_ring_destroy(r) }
        let input = (0..<700).map(Float.init)
        #expect(input.withUnsafeBufferPointer { tt_ring_write_strided(r, $0.baseAddress!, 700, 1) } == 700)
        #expect(tt_ring_available(r) == 700)
        var out = [Float](repeating: -1, count: 1000)
        let n = out.withUnsafeMutableBufferPointer { tt_ring_read(r, $0.baseAddress!, 1000) }
        #expect(n == 700)
        #expect(Array(out[0..<700]) == input)
        #expect(tt_ring_available(r) == 0)
    }

    @Test func overflowDropsTheExcessAndCountsIt() throws {
        let r = try #require(tt_ring_create(1024))
        defer { tt_ring_destroy(r) }
        let input = [Float](repeating: 1, count: 1500)
        let stored = input.withUnsafeBufferPointer { tt_ring_write_strided(r, $0.baseAddress!, 1500, 1) }
        #expect(stored == 1024)
        #expect(tt_ring_overrun_frames(r) == 476)
        #expect(tt_ring_written_frames(r) == 1024)
        // Unread data was not overwritten.
        var out = [Float](repeating: 0, count: 1024)
        _ = out.withUnsafeMutableBufferPointer { tt_ring_read(r, $0.baseAddress!, 1024) }
        #expect(out.allSatisfy { $0 == 1 })
    }

    @Test func stridedWriteTakesOneChannel() throws {
        let r = try #require(tt_ring_create(1024))
        defer { tt_ring_destroy(r) }
        // Interleaved stereo: L = i, R = -i. Start at sample 1 to take R.
        var inter = [Float]()
        for i in 0..<10 { inter += [Float(i), -Float(i)] }
        _ = inter.withUnsafeBufferPointer { tt_ring_write_strided(r, $0.baseAddress! + 1, 10, 2) }
        var out = [Float](repeating: 0, count: 10)
        _ = out.withUnsafeMutableBufferPointer { tt_ring_read(r, $0.baseAddress!, 10) }
        #expect(out == (0..<10).map { -Float($0) })
    }

    @Test func resetDropsUnread() throws {
        let r = try #require(tt_ring_create(1024))
        defer { tt_ring_destroy(r) }
        _ = tt_ring_write_zeros(r, 100)
        tt_ring_reset(r)
        #expect(tt_ring_available(r) == 0)
    }

    /// SPSC stress: a producer thread writes a counting sequence in odd chunk sizes, the consumer
    /// reads in other sizes; every value must arrive exactly once, in order, with no overruns
    /// while the consumer keeps up.
    @Test func spscStressKeepsSequence() throws {
        let ring = try #require(tt_ring_create(4096))
        defer { tt_ring_destroy(ring) }
        let total = 2_000_000
        nonisolated(unsafe) let r = ring
        let producer = Thread {
            var next = 0
            var chunk = [Float](repeating: 0, count: 257)
            while next < total {
                let n = min(chunk.count - (next % 50), total - next)
                for i in 0..<n { chunk[i] = Float(next + i) }
                var written = 0
                while written < n {
                    written += Int(chunk.withUnsafeBufferPointer {
                        tt_ring_write_strided(r, $0.baseAddress! + written, UInt32(min(n - written, Int(tt_ring_capacity(r)) - Int(tt_ring_available(r)))), 1)
                    })
                }
                next += n
            }
        }
        producer.start()
        var expected = 0
        var buf = [Float](repeating: 0, count: 333)
        var ok = true
        let deadline = Date().addingTimeInterval(20)
        while expected < total && Date() < deadline {
            let n = Int(buf.withUnsafeMutableBufferPointer { tt_ring_read(r, $0.baseAddress!, 333) })
            for i in 0..<n where buf[i] != Float(expected + i) { ok = false }
            expected += n
        }
        #expect(ok)
        #expect(expected == total)
        #expect(tt_ring_overrun_frames(r) == 0)
    }
}

@Suite struct MicIOProcTests {
    @Test func stampsTrackStoredPrefixesAcrossOverflow() throws {
        let ring = try #require(tt_ring_create(1024)), ctx = try #require(tt_mic_ctx_create(ring, 0))
        defer { tt_mic_ctx_destroy(ctx); tt_ring_destroy(ring) }
        withBufferList([(1, Array(repeating: 0.5, count: 1500))]) { tt_mic_process(ctx, $0, 1500, 100) }
        var stamp = tt_mic_stamp()
        #expect(tt_mic_read_stamps(ctx, &stamp, 1) == 1)
        #expect(stamp.host_time == 100 && stamp.frame_index == 0 && stamp.frames == 1024)
        #expect(drain(ring, 1024).count == 1024)
        withBufferList([(1, [0.2, 0.3])]) { tt_mic_process(ctx, $0, 2, 200) }
        #expect(tt_mic_read_stamps(ctx, &stamp, 1) == 1)
        #expect(stamp.host_time == 200 && stamp.frame_index == 1500 && stamp.frames == 2)
        #expect(drain(ring, 2) == [0.2, 0.3])
        #expect(tt_mic_dropped_frames(ctx) == 476)
    }

    @Test func fullStampQueueDropsAudioWithItsTimestamp() throws {
        let ring = try #require(tt_ring_create(2048)), ctx = try #require(tt_mic_ctx_create(ring, 0))
        defer { tt_mic_ctx_destroy(ctx); tt_ring_destroy(ring) }
        for i in 0..<Int(TT_MIC_STAMPS) { tt_mic_process(ctx, nil, 1, UInt64(i + 1)) }
        #expect(tt_ring_available(ring) == TT_MIC_STAMPS)
        tt_mic_process(ctx, nil, 10, 2000)
        #expect(tt_ring_available(ring) == TT_MIC_STAMPS)
        #expect(tt_mic_dropped_stamps(ctx) == 1 && tt_mic_dropped_frames(ctx) == 10)
    }
    /// Builds an AudioBufferList with the given buffers (each: channels, interleaved samples).
    private func withBufferList(_ buffers: [(UInt32, [Float])], _ body: (UnsafePointer<AudioBufferList>) -> Void) {
        let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        defer { free(list.unsafeMutablePointer) }
        var storages: [UnsafeMutablePointer<Float>] = []
        for (i, (ch, samples)) in buffers.enumerated() {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
            p.initialize(from: samples, count: samples.count)
            storages.append(p)
            list[i] = AudioBuffer(mNumberChannels: ch, mDataByteSize: UInt32(samples.count * 4), mData: p)
        }
        body(UnsafePointer(list.unsafePointer))
        storages.forEach { $0.deallocate() }
    }

    private func drain(_ r: OpaquePointer, _ n: Int) -> [Float] {
        var out = [Float](repeating: .nan, count: n)
        let got = out.withUnsafeMutableBufferPointer { tt_ring_read(r, $0.baseAddress!, UInt32(n)) }
        return Array(out[0..<Int(got)])
    }

    @Test func interleavedPicksTheChannel() throws {
        let r = try #require(tt_ring_create(1024))
        let ctx = try #require(tt_mic_ctx_create(r, 1))
        defer { tt_mic_ctx_destroy(ctx); tt_ring_destroy(r) }
        var inter = [Float]()
        for i in 0..<8 { inter += [Float(i), Float(100 + i)] }
        withBufferList([(2, inter)]) { tt_mic_process(ctx, $0, 8, 12345) }
        #expect(drain(r, 16) == (0..<8).map { Float(100 + $0) })
        #expect(tt_mic_frames(ctx) == 8)
        #expect(tt_mic_first_host_time(ctx) == 12345)
        #expect(tt_mic_missing_buffers(ctx) == 0)
    }

    @Test func nonInterleavedPicksTheBuffer() throws {
        let r = try #require(tt_ring_create(1024))
        let ctx = try #require(tt_mic_ctx_create(r, 1))
        defer { tt_mic_ctx_destroy(ctx); tt_ring_destroy(r) }
        withBufferList([(1, [1, 2, 3]), (1, [7, 8, 9])]) { tt_mic_process(ctx, $0, 3, 1) }
        #expect(drain(r, 3) == [7, 8, 9])
    }

    @Test func missingChannelWritesZerosAndCounts() throws {
        let r = try #require(tt_ring_create(1024))
        let ctx = try #require(tt_mic_ctx_create(r, 3))
        defer { tt_mic_ctx_destroy(ctx); tt_ring_destroy(r) }
        withBufferList([(2, [1, 1, 1, 1])]) { tt_mic_process(ctx, $0, 2, 1) }
        #expect(drain(r, 4) == [0, 0])
        #expect(tt_mic_missing_buffers(ctx) == 1)
    }

    @Test func ioprocUsesHostTimeAndFrameCount() throws {
        let r = try #require(tt_ring_create(1024))
        let ctx = try #require(tt_mic_ctx_create(r, 0))
        defer { tt_mic_ctx_destroy(ctx); tt_ring_destroy(r) }
        var now = AudioTimeStamp()
        var inTime = AudioTimeStamp()
        inTime.mHostTime = 999
        inTime.mFlags = .hostTimeValid
        var outList = AudioBufferList()
        withBufferList([(1, [0.5, 0.25, 0.125, 0])]) { list in
            _ = tt_mic_ioproc(1, &now, list, &inTime, &outList, &now, UnsafeMutableRawPointer(ctx))
        }
        #expect(drain(r, 8) == [0.5, 0.25, 0.125, 0])
        #expect(tt_mic_last_host_time(ctx) == 999)
        #expect(tt_mic_callbacks(ctx) == 1)
    }
}

@Suite struct InputDeviceCatalogTests {
    @Test func fourCCRendersTransportCodes() {
        #expect(InputDeviceCatalog.fourCC(kAudioDeviceTransportTypeBuiltIn) == "bltn")
        #expect(InputDeviceCatalog.fourCC(kAudioDeviceTransportTypeUSB) == "usb ")
        #expect(InputDeviceCatalog.fourCC(kAudioDeviceTransportTypeBluetooth) == "blue")
        #expect(InputDeviceCatalog.fourCC(kAudioDeviceTransportTypeVirtual) == "virt")
        #expect(InputDeviceCatalog.fourCC(kAudioDeviceTransportTypeAggregate) == "grup")
        #expect(InputDeviceCatalog.fourCC(0) == "0x00000000")
    }
}
