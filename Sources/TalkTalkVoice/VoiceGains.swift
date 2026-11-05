import Foundation

/// Integrated loudness (ITU-R BS.1770-4, mono): K-weighting (high shelf + RLB high-pass, designed
/// for the actual sample rate), 400 ms blocks with 75 % overlap, absolute gate −70 LUFS, relative
/// gate −10 LU. Pure; used to calibrate the PlayoutStage fixed gain from the audition (§3.3).
public enum Loudness {
    public struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0

        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    static func kWeighting(sampleRate fs: Double) -> [Biquad] {
        // Stage 1: high shelf (+4 dB above ~1.7 kHz).
        var k = tan(.pi * 1681.974450955533 / fs)
        var q = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0,
                           b2: (vh - vb * k / q + k * k) / a0, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        // Stage 2: RLB high-pass at ~38 Hz.
        k = tan(.pi * 38.13547087602444 / fs)
        q = 0.5003270373238773
        a0 = 1 + k / q + k * k
        let hp = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        return [shelf, hp]
    }

    /// LUFS of the clips taken together (each filtered on its own, blocks pooled). nil when nothing
    /// passes the absolute gate (silence, or less than one 400 ms block).
    public static func integrated(_ clips: [[Float]], sampleRate: Double) -> Double? {
        let block = Int(0.4 * sampleRate), step = Int(0.1 * sampleRate)
        guard block > 0, step > 0 else { return nil }
        var powers: [Double] = []
        for clip in clips where clip.count >= block {
            var filters = kWeighting(sampleRate: sampleRate)
            var sq = [Double](repeating: 0, count: clip.count)
            for i in clip.indices {
                var y = Double(clip[i])
                for f in filters.indices { y = filters[f].run(y) }
                sq[i] = y * y
            }
            // Prefix sums make each block O(1).
            var prefix = [Double](repeating: 0, count: sq.count + 1)
            for i in sq.indices { prefix[i + 1] = prefix[i] + sq[i] }
            var start = 0
            while start + block <= sq.count {
                powers.append((prefix[start + block] - prefix[start]) / Double(block))
                start += step
            }
        }
        func lufs(_ z: Double) -> Double { -0.691 + 10 * log10(max(z, 1e-20)) }
        let absGated = powers.filter { lufs($0) > -70 }
        guard !absGated.isEmpty else { return nil }
        let relative = lufs(absGated.reduce(0, +) / Double(absGated.count)) - 10
        let gated = absGated.filter { lufs($0) > relative }
        guard !gated.isEmpty else { return nil }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }
}

/// The two fixed gains set when "my voice" is recorded (§9.2 step 6). Pure.
public enum VoiceGains {
    /// Both paths aim at the same level (§3.3, §3.8).
    public static let targetLUFS = -20.0
    /// PlayoutStage: clone TTS output is already near the target; a larger correction means the
    /// measurement is off, so it is bounded (voice-m2, 2026-11-04).
    public static let playoutRange = -12.0...12.0
    /// §3.8: `gainDb = clamp(−20 − RMS_dBFS, −6, +18)`.
    public static let passthroughRange = -6.0...18.0

    /// From the audition clips (24 kHz). nil when they carry no measurable speech.
    public static func playoutGainDb(auditionClips: [[Float]], sampleRate: Double = 24_000) -> Double? {
        guard let l = Loudness.integrated(auditionClips, sampleRate: sampleRate) else { return nil }
        return clamp(targetLUFS - l, playoutRange)
    }

    /// From the raw speech RMS of the accepted take, before normalization
    /// (`EnrollmentMeasurements.speechRmsDbfs`).
    public static func passthroughGainDb(rawSpeechRmsDbfs: Double) -> Double {
        clamp(targetLUFS - rawSpeechRmsDbfs, passthroughRange)
    }

    static func clamp(_ x: Double, _ r: ClosedRange<Double>) -> Double {
        let v = min(max(x, r.lowerBound), r.upperBound)
        return (v * 10).rounded() / 10
    }
}

/// Passthrough gain per microphone (§3.8, §12.1: UserDefaults, one number per mic UID hash,
/// kept until the voice profile is deleted or the mic is recalibrated). The real store belongs to
/// passthrough-audio (PassthroughStage reads it); TalkTalkVoice only writes at enrollment and
/// clears at deletion through this protocol.
public protocol PassthroughGainStore: Sendable {
    func gainDb(micUIDHash: String) -> Double?
    func setGainDb(_ db: Double, micUIDHash: String)
    /// Deleting "my voice" (§9.4) forgets every calibrated microphone.
    func removeAll()
}

/// In-memory store: tests, and the app until passthrough-audio ships the UserDefaults one.
public final class InMemoryPassthroughGainStore: PassthroughGainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Double] = [:]

    public init(_ values: [String: Double] = [:]) {
        self.values = values
    }

    public func gainDb(micUIDHash: String) -> Double? {
        lock.withLock { values[micUIDHash] }
    }

    public func setGainDb(_ db: Double, micUIDHash: String) {
        lock.withLock { values[micUIDHash] = db }
    }

    public func removeAll() {
        lock.withLock { values.removeAll() }
    }

    public var all: [String: Double] { lock.withLock { values } }
}
