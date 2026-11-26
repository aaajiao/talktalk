import CAudioCore
import Foundation
import TalkTalkCore

/// Worker-only libfvad mode 2, fixed 20 ms / 16 kHz frames; no model or audio file.
public final class SpeakVAD {
    public struct Frame: Sendable {
        public let start, end: HostTime
        public let rmsDb: Double
        public let voiced: Bool
        /// libfvad hears voice and rmsDb is in [thresholdDb - faintMarginDb, thresholdDb) and at least
        /// faintMarginDb above the 10th-percentile level of the frames before it since the reset (at most
        /// the last 150); none in the first 10 frames after a reset. Speech too soft for `voiced` (or noise
        /// libfvad takes for voice). Never set with `voiced`; moves no onset, hangover, event or level.
        public let faint: Bool
    }
    /// A libfvad-voiced frame this far under thresholdDb is still faint (half the 12 dB speech margin)
    /// if it is also this far above the 10th-percentile level, so the band [thresholdDb - 6, thresholdDb) is
    /// always at least 6 dB above that level. Once warm, thresholdDb is at least that level + 12; the fixed
    /// -55 dBFS threshold of the first 150 frames gives no such margin.
    public static let faintMarginDb = 6.0
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
            let sorted = levels.sorted()
            // During the first three seconds there is not yet a complete noise window.
            thresholdDb = levels.count == 150 ? max(-55, sorted[14] + 12) : -55
            let voice = classify?(frame) ?? frame.withUnsafeBufferPointer { tt_vad_process_f32(vad, $0.baseAddress!, $0.count) == 1 }
            let speech = voice && rms >= thresholdDb
            // The fixed warm-up threshold has no margin over the noise, so faint also needs one over the
            // 10th-percentile level so far (at 150 levels sorted[14], which thresholdDb clears by 12 dB).
            let faint = voice && !speech && rms >= thresholdDb - Self.faintMarginDb
                && levels.count >= 10 && rms >= sorted[levels.count / 10 - 1] + Self.faintMarginDb
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
            result.frames.append(Frame(start: start, end: end, rmsDb: rms, voiced: speech, faint: faint))
        }
        return result
    }
    public func reset() {
        tt_vad_reset(vad); pending.removeAll(); pendingHost = nil; levels.removeAll()
        onset = 0; quiet = 0; speechActive = false; lastVoiceEnd = nil; thresholdDb = -55
    }
}
