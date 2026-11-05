@preconcurrency import AVFoundation
import CAudioCore
import Foundation
import TalkTalkCore

/// Audio-worker-only mic → gate.admit → SRC → fixed gain → limiter → ringP. No other output
/// accepts these frames. Each generation has fresh SRC/limiter state and a fixed gain snapshot.
public final class PassthroughStage {
    public enum Failure: Error { case format, conversion }
    private let ring: PassthroughRing
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    private var limiter: TruePeakLimiter
    private var generation: UInt32?
    private var sourceRate = 0.0
    private var captureStart: HostTime = 0
    private var nextInputAt: HostTime = 0
    private var outputFrames: UInt64 = 0
    private var discardDelay = 0
    private var gain: Float = 1
    public private(set) var rms: Float = 0

    public convenience init(feed: FeedOutput, ceilingDbtp: Double = -1) {
        self.init(ring: feed.ringP, ceilingDbtp: ceilingDbtp)
    }
    init(ring: PassthroughRing, ceilingDbtp: Double = -1) {
        self.ring = ring; limiter = TruePeakLimiter(ceilingDbtp: ceilingDbtp)
    }
    public func reset() {
        converter = nil; inputFormat = nil; generation = nil; sourceRate = 0
        outputFrames = 0; limiter.reset(); discardDelay = limiter.latencyFrames; rms = 0
    }

    @discardableResult
    public func offer(_ block: MicBlock, gate: PassthroughGate, now: HostTime, gainDb: Double) throws -> Int {
        guard block.sampleRate.isFinite, block.sampleRate > 0,
              let admitted = gate.admit(block, now: now), !admitted.samples.isEmpty else { rms = 0; return 0 }
        let gap = abs(Double(admitted.firstSampleHostTime) - Double(nextInputAt))
        if generation != admitted.generation || sourceRate != admitted.sampleRate || gap > 1e9 / admitted.sampleRate {
            reset()
            generation = admitted.generation; sourceRate = admitted.sampleRate
            captureStart = admitted.firstSampleHostTime
            gain = Float(pow(10, (gainDb.isFinite ? min(30, max(-60, gainDb)) : 0) / 20))
            if sourceRate != 48_000 {
                guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false),
                      let src = AVAudioConverter(from: format, to: outputFormat) else { throw Failure.format }
                src.primeMethod = .none
                src.sampleRateConverterQuality = AVAudioQuality.high.rawValue
                inputFormat = format; converter = src
            }
        }
        nextInputAt = admitted.firstSampleHostTime &+ HostTime((Double(admitted.samples.count) * 1e9 / sourceRate).rounded())
        let input = admitted.samples.map { $0.isFinite ? $0 : 0 }
        var converted = try resample(input)
        for i in converted.indices { converted[i] *= gain }
        var limited: [Float] = []
        limiter.process(converted, into: &limited)
        // Limiter emits leading delay zeros. Drop those, so the first retained sample is tagged
        // with its original capture time, never with a later worker or output timestamp.
        let drop = min(discardDelay, limited.count)
        discardDelay -= drop
        let samples = limited.dropFirst(drop)
        guard !samples.isEmpty else { return 0 }
        rms = Float(sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)))
        let time = captureStart &+ HostTime(Double(outputFrames) * 1e9 / 48_000)
        outputFrames += UInt64(samples.count)
        return samples.withContiguousStorageIfAvailable { buffer in
            Int(tt_ringp_write(ring.raw, buffer.baseAddress!, UInt32(buffer.count),
                               HostClock.machTicks(fromNanos: time), admitted.generation))
        } ?? 0
    }

    private func resample(_ samples: [Float]) throws -> [Float] {
        guard let converter, let inputFormat else { return samples }
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: UInt32(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                  frameCapacity: UInt32(ceil(Double(samples.count) * 48_000 / sourceRate)) + 512) else { throw Failure.format }
        input.frameLength = UInt32(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let feed = Input(input)
        var result: [Float] = []
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if let buffer = feed.take() { state.pointee = .haveData; return buffer }
                state.pointee = .noDataNow; return nil
            }
            if error != nil || status == .error { throw Failure.conversion }
            result.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            if status != .haveData { return result }
        }
    }
    private final class Input: @unchecked Sendable {
        var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? { defer { buffer = nil }; return buffer }
    }
}
