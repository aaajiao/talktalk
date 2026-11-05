import CDriverSelfTest
import CoreAudio
import Foundation
import TalkTalkAudio
import TalkTalkCore

/// Self-test-only reader, fixed to Test Mic. Never selects the physical/default/meeting microphone.
public final class DriverTestMicRecorder: @unchecked Sendable {
    public struct Sample: Sendable { public var host: HostTime; public var value: Float }
    public struct Result: Sendable { public var samples: [Sample]; public var callbacks, overflows: UInt64 }
    public enum Failure: Error { case missing, allocation, start(OSStatus) }
    private let context: OpaquePointer
    private var io: IOProc?
    public init() throws {
        guard let context = tt_st_recorder_create(48_000 * 5, 4_000) else { throw Failure.allocation }
        self.context = context
    }
    deinit { io?.stop(); tt_st_recorder_destroy(context) }
    public func start(hal: any DriverHAL = CoreAudioDriverHAL()) throws {
        guard let device = hal.device(uid: DriverIdentity.testMicUID)?.objectID else { throw Failure.missing }
        let io = IOProc(device: device, proc: tt_st_recorder_ioproc, context: UnsafeMutableRawPointer(context))
        self.io = io
        let status = io.start()
        guard status == noErr else { io.stop(); throw Failure.start(status) }
    }
    public func stopAndRead() -> Result {
        io?.stop(); io = nil
        var audio = [Float](repeating: 0, count: Int(tt_st_recorder_sample_count(context)))
        if !audio.isEmpty { _ = audio.withUnsafeMutableBufferPointer { tt_st_recorder_samples(context, $0.baseAddress!, UInt32($0.count)) } }
        var chunks = [tt_st_chunk](repeating: tt_st_chunk(), count: Int(tt_st_recorder_chunk_count(context)))
        if !chunks.isEmpty { _ = chunks.withUnsafeMutableBufferPointer { tt_st_recorder_chunks(context, $0.baseAddress!, UInt32($0.count)) } }
        var samples: [Sample] = []; samples.reserveCapacity(audio.count)
        for chunk in chunks where chunk.host_time != 0 {
            let start = HostClock.nanos(fromMachTicks: chunk.host_time)
            for i in 0..<Int(chunk.frames) where Int(chunk.offset) + i < audio.count {
                samples.append(Sample(host: start + UInt64(Double(i) * 1e9 / 48_000), value: audio[Int(chunk.offset) + i]))
            }
        }
        return Result(samples: samples, callbacks: tt_st_recorder_cycles(context), overflows: tt_st_recorder_overflows(context))
    }
}
