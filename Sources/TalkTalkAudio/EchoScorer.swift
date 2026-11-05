import Foundation
import TalkTalkCore

/// Acoustic echo evidence, independent of recognized text (§3.5). Compares the most recent
/// three seconds of 10 ms RMS envelopes with a positive Feed → tap delay of 50–1500 ms.
/// Observed silent Feed is no echo (0); missing/stale observations remain unknown (nil).
public struct EchoScorer: Sendable {
    public struct Estimate: Sendable, Equatable {
        public let score: Double
        public let lagMs: Int
        public let pairedPoints: Int
    }
    public var lagMs: ClosedRange<Int>
    public var windowMs: Int
    public var minimumPoints: Int

    public init(lagMs: ClosedRange<Int> = 50...1500, windowMs: Int = 3000, minimumPoints: Int = 50) {
        self.lagMs = lagMs; self.windowMs = max(10, windowMs); self.minimumPoints = max(3, minimumPoints)
    }
    public init(profile: PolicyProfile.Speak.Floor) {
        let limits = profile.echoLagMs
        let lo = max(0, limits.first ?? 50), hi = max(lo, limits.last ?? 1500)
        self.init(lagMs: lo...hi)
    }

    public func estimate(feed: EnvelopeHistory, tap: EnvelopeHistory, through: HostTime = HostClock.now()) -> Estimate? {
        estimate(feed: feed.recent(), tap: tap.recent(), through: through)
    }

    /// Pure form for recorded envelope points and deterministic tests. No audio is retained.
    public func estimate(feed: [EnvelopePoint], tap: [EnvelopePoint], through: HostTime) -> Estimate? {
        let window = UInt64(windowMs) * 1_000_000
        let start = through > window ? through - window : 0
        let remote = tap.filter { $0.at >= start && $0.at <= through && $0.rms.isFinite }
        let local = feed.filter { $0.at <= through && $0.rms.isFinite }
        guard remote.count >= minimumPoints, local.count >= minimumPoints else { return nil }
        // Reject stale histories rather than applying an old correlation to a new utterance.
        guard let last = remote.last, through >= last.at, through - last.at <= 50_000_000 else { return nil }
        // A quiet Feed across every possible acoustic delay establishes absence of our echo.
        // Require continuous coverage: a detached Feed or a hole is not evidence of silence.
        let silenceStart = through > UInt64(lagMs.upperBound + 500) * 1_000_000
            ? through - UInt64(lagMs.upperBound + 500) * 1_000_000 : 0
        let silence = local.filter { $0.at >= silenceStart }
        if let first = silence.first, let last = silence.last,
           first.at <= silenceStart + 10_000_000, through - last.at <= 50_000_000,
           silence.allSatisfy({ $0.rms >= 0 && $0.rms <= 0.000001 }),
           zip(silence, silence.dropFirst()).allSatisfy({ $1.at >= $0.at && $1.at - $0.at <= 15_000_000 }) {
            return Estimate(score: 0, lagMs: 0, pairedPoints: silence.count)
        }
        var best: Estimate?
        for lag in stride(from: max(0, lagMs.lowerBound), through: lagMs.upperBound, by: 10) {
            let delay = UInt64(lag) * 1_000_000
            var i = 0, n = 0
            var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
            for point in remote where point.at >= delay {
                let wanted = point.at - delay
                while i + 1 < local.count && local[i + 1].at <= wanted { i += 1 }
                var nearest = i
                if i + 1 < local.count && distance(local[i + 1].at, wanted) < distance(local[i].at, wanted) { nearest += 1 }
                guard distance(local[nearest].at, wanted) <= 5_000_000 else { continue }
                let x = Double(local[nearest].rms), y = Double(point.rms)
                n += 1; sx += x; sy += y; sxx += x * x; syy += y * y; sxy += x * y
            }
            guard n >= minimumPoints else { continue }
            let count = Double(n), vx = sxx - sx * sx / count, vy = syy - sy * sy / count
            guard vx > 1e-10 * count, vy > 1e-10 * count else { continue }
            let correlation = (sxy - sx * sy / count) / sqrt(vx * vy)
            let score = max(0, min(1, correlation))
            if best == nil || score > best!.score { best = Estimate(score: score, lagMs: lag, pairedPoints: n) }
        }
        return best
    }

    private func distance(_ a: UInt64, _ b: UInt64) -> UInt64 { a >= b ? a - b : b - a }
}
