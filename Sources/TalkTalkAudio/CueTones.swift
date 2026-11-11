import Foundation

/// The cue tones (ARCHITECTURE.md): short, quiet, rendered at the monitor
/// device's rate and played only through MonitorOutput (`playCue`), never the Feed.
///  - `.passthroughOpen`: a rising sweep, requested before the gate opens (device output latency is not awaited);
///  - `.passthroughClose`: the same sweep falling, played after the close;
///  - `.meetingMicAlert`: two short beeps, MeetingMicGuard's "the meeting reads a physical mic"
///    (§8.6), distinct from the passthrough pair.
/// `dbfs` is the peak level (default −30 dBFS, settings range −45…−15); every tone has a 5 ms
/// raised-cosine fade at both ends, so it starts and ends at 0 (no click).
public enum CueTones {
    public enum Kind: Sendable, Hashable { case passthroughOpen, passthroughClose, meetingMicAlert }

    public static let defaultDbfs = -30.0
    /// The sweep: a fifth, 660 → 990 Hz (falling: the reverse).
    static let sweepLowHz = 660.0, sweepHighHz = 990.0
    static let beepHz = 880.0, beepMs = 40, beepGapMs = 60
    static let fadeMs = 5.0

    /// `ms`: the sweep length (PolicyProfile `speak.passthrough.cues.ms`, 30); the alert has its own
    /// fixed shape. `dbfs` is clamped to [−60, −6].
    public static func render(_ kind: Kind, sampleRate: Double, dbfs: Double = defaultDbfs, ms: Int = 30) -> [Float] {
        guard sampleRate > 0, sampleRate.isFinite else { return [] }
        let peak = pow(10, min(max(dbfs.isFinite ? dbfs : defaultDbfs, -60), -6) / 20)
        switch kind {
        case .passthroughOpen: return sweep(from: sweepLowHz, to: sweepHighHz, ms: ms, rate: sampleRate, peak: peak)
        case .passthroughClose: return sweep(from: sweepHighHz, to: sweepLowHz, ms: ms, rate: sampleRate, peak: peak)
        case .meetingMicAlert:
            let beep = sweep(from: beepHz, to: beepHz, ms: beepMs, rate: sampleRate, peak: peak)
            return beep + [Float](repeating: 0, count: frames(beepGapMs - beepMs, rate: sampleRate)) + beep
        }
    }

    static func frames(_ ms: Int, rate: Double) -> Int { max(0, Int((Double(ms) * rate / 1000).rounded())) }

    /// A linear chirp (phase accumulated per sample) under the fade envelope.
    static func sweep(from f0: Double, to f1: Double, ms: Int, rate: Double, peak: Double) -> [Float] {
        let n = frames(max(ms, 12), rate: rate)
        let fade = min(Int(fadeMs * rate / 1000), n / 2)
        var phase = 0.0
        var y = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = n > 1 ? Double(i) / Double(n - 1) : 0
            let f = f0 + (f1 - f0) * t
            let edge = min(i, n - 1 - i)
            let env = edge >= fade ? 1 : 0.5 - 0.5 * cos(Double.pi * Double(edge) / Double(fade))
            y[i] = Float(peak * env * sin(phase))
            phase += 2 * Double.pi * f / rate
        }
        return y
    }
}

extension MonitorOutput {
    /// `CueTones.render(kind, …)` at the device rate through `playCue` (same rules: `.cues` use on
    /// and the default output classified as headphones). Returns at once; `completion` (on a
    /// global queue) says whether it was queued (MeetingMicGuard's "alert owed" flag needs that).
    public func playCue(_ kind: CueTones.Kind, dbfs: Double = CueTones.defaultDbfs, ms: Int = 30,
                        completion: @escaping @Sendable (Bool) -> Void) {
        playCue({ CueTones.render(kind, sampleRate: $0, dbfs: dbfs, ms: ms) }, completion: completion)
    }

    /// `playCue(_:dbfs:ms:completion:)`, awaited: whether it was queued.
    public func playCue(_ kind: CueTones.Kind, dbfs: Double = CueTones.defaultDbfs, ms: Int = 30) async -> Bool {
        await playCue { CueTones.render(kind, sampleRate: $0, dbfs: dbfs, ms: ms) }
    }
}
