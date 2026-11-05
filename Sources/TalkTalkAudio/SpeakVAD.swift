import CAudioCore
import Foundation
import TalkTalkCore

/// Worker-only libfvad mode 2, fixed 20 ms / 16 kHz frames; no model or audio file.
public final class SpeakVAD {
    public struct Frame: Sendable {
        public let start, end: HostTime
        public let rmsDb: Double
        public let voiced: Bool
    }
    public enum Event: Sendable, Equatable { case began(HostTime), ended(HostTime) }
    public struct Result: Sendable { public var frames: [Frame]; public var events: [Event] }
    private let vad: OpaquePointer
    private let classify: (([Float]) -> Bool)?
    private var pending: [Float] = []
    private var pendingHost: HostTime?
    private var levels: [Double] = []
    private var onset = 0, quiet = 0
    public private(set) var speechActive = false
    public private(set) var lastVoiceEnd: HostTime?
    public private(set) var thresholdDb = -55.0

    public init(sampleRate: Int = 16_000) throws {
        guard sampleRate == 16_000, let v = tt_vad_create(2, Int32(sampleRate)) else { throw Failure.sampleRate }
        vad = v; classify = nil
    }
    /// Deterministic classifier injection for smoothing tests; the real entry always uses libfvad.
    init(classify: @escaping ([Float]) -> Bool) {
        vad = tt_vad_create(2, 16_000)!
        self.classify = classify
    }
    public enum Failure: Error { case sampleRate }
    deinit { tt_vad_destroy(vad) }

    public func push(_ samples: [Float], at host: HostTime) -> Result {
        let bufferedNs = UInt64(pending.count) * 62_500
        pendingHost = host >= bufferedNs ? host - bufferedNs : 0
        pending.append(contentsOf: samples)
        var result = Result(frames: [], events: [])
        while pending.count >= 320, let start = pendingHost {
            let frame = Array(pending.prefix(320)); pending.removeFirst(320)
            let end = start + 20_000_000
            pendingHost = end
            let rms = frame.withUnsafeBufferPointer { Double(tt_vad_rms_dbfs($0.baseAddress!, $0.count)) }
            // During the first three seconds there is not yet a complete noise window.
            thresholdDb = levels.count == 150 ? max(-55, levels.sorted()[14] + 12) : -55
            let speech = (classify?(frame) ?? frame.withUnsafeBufferPointer { tt_vad_process_f32(vad, $0.baseAddress!, $0.count) == 1 }) && rms >= thresholdDb
            levels.append(rms); if levels.count > 150 { levels.removeFirst() }
            if speech {
                lastVoiceEnd = end; quiet = 0; onset += 1
                if !speechActive && onset >= 3 { speechActive = true; result.events.append(.began(start - 40_000_000)) }
            } else {
                onset = 0
                if speechActive {
                    quiet += 1
                    if quiet >= 6 { speechActive = false; quiet = 0; result.events.append(.ended(end - 120_000_000)) }
                }
            }
            result.frames.append(Frame(start: start, end: end, rmsDb: rms, voiced: speech))
        }
        return result
    }
    public func reset() {
        tt_vad_reset(vad); pending.removeAll(); pendingHost = nil; levels.removeAll()
        onset = 0; quiet = 0; speechActive = false; lastVoiceEnd = nil; thresholdDb = -55
    }
}
