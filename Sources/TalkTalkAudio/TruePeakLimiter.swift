import Foundation

/// −1 dBTP true-peak limiter with 5 ms lookahead (§3.3). One implementation, two instances:
/// PlayoutStage (TTS → ringO) and PassthroughStage (mic → ringP, §3.8).
///
/// - Detection: 4× oversampled peak. For every input interval [n, n+1] the samples at n and the
///   three fractional positions n+¼, n+½, n+¾ are interpolated with a 16-tap Kaiser-windowed
///   sinc; the interval's peak is assigned to both of its end samples.
/// - Gain: required g[n] = min(1, ceiling / peak[n]); a sliding minimum over W = D samples, then a
///   box average of length L = D + 1. With the signal delayed by D samples (plus the
///   interpolator's look-ahead) every gain applied to sample n is ≤ g[n]: each box term is a
///   minimum over a window that contains n. A one-pole release (50 ms) only slows the rise.
/// - The detection ceiling sits `marginDb` (0.3 dB) under the target so an independent 4× check
///   (the tests use a different, longer interpolator) never sees more than −1 dBTP.
///
/// Not real-time code: runs on the audio worker. No allocation per sample; `process` appends.
public struct TruePeakLimiter: Sendable {
    public let sampleRate: Double
    public let ceilingDbtp: Double
    public let lookaheadFrames: Int
    public let marginDb: Double
    public let releaseMs: Double
    /// Total delay from input to output in frames (lookahead + interpolator look-ahead).
    public var latencyFrames: Int { lookaheadFrames + Self.future }

    static let taps = 16
    static let past = 7          // taps at n-7 … n+8
    static let future = 8
    static let phases: [[Float]] = makePhases()

    private let detectCeiling: Float
    private let releaseCoef: Float
    // detection history (last taps input samples)
    private var hist: [Float]
    private var histPos = 0
    private var histFilled = 0
    private var prevIntervalPeak: Float = 0
    // gain path
    private var minQueue: [(idx: Int, g: Float)] = []    // monotonic deque (head at minHead)
    private var minHead = 0
    private var box: [Float]
    private var boxPos = 0
    private var boxSum: Double
    private var gain: Float = 1
    private var n = 0                                     // index of the sample whose gain is computed
    // signal delay line
    private var delay: [Float]
    private var delayPos = 0

    public init(sampleRate: Double = 48_000, ceilingDbtp: Double = -1, lookaheadMs: Double = 5, marginDb: Double = 0.3,
                releaseMs: Double = 50) {
        self.sampleRate = sampleRate
        self.ceilingDbtp = ceilingDbtp
        self.marginDb = marginDb
        self.releaseMs = releaseMs
        lookaheadFrames = max(1, Int((lookaheadMs * sampleRate / 1000).rounded()))
        detectCeiling = Float(pow(10, (ceilingDbtp - marginDb) / 20))
        releaseCoef = Float(exp(-1 / (releaseMs / 1000 * sampleRate)))
        hist = [Float](repeating: 0, count: Self.taps)
        box = [Float](repeating: 1, count: lookaheadFrames + 1)
        boxSum = Double(lookaheadFrames + 1)
        // c0 already lags the input by `future`; hold it `lookaheadFrames` more (see step 4).
        delay = [Float](repeating: 0, count: lookaheadFrames + 1)
        minQueue.reserveCapacity(lookaheadFrames + 2)
    }

    public mutating func reset() {
        self = TruePeakLimiter(sampleRate: sampleRate, ceilingDbtp: ceilingDbtp,
                               lookaheadMs: Double(lookaheadFrames) * 1000 / sampleRate, marginDb: marginDb,
                               releaseMs: releaseMs)
    }

    /// Processes `input`, appending the same number of (delayed) frames to `output`.
    public mutating func process(_ input: UnsafeBufferPointer<Float>, into output: inout [Float]) {
        output.reserveCapacity(output.count + input.count)
        for x in input { output.append(step(x)) }
    }

    public mutating func process(_ input: [Float], into output: inout [Float]) {
        input.withUnsafeBufferPointer { process($0, into: &output) }
    }

    /// Pushes `latencyFrames` zeros through so every real input sample has come out.
    public mutating func flush(into output: inout [Float]) {
        for _ in 0..<latencyFrames { output.append(step(0)) }
    }

    private mutating func step(_ x: Float) -> Float {
        // 1. detection: x is sample k = n + future; the interval [k-future, k-future+1] = [c, c+1]
        //    with c = n has all 16 taps once x is in.
        hist[histPos] = x
        histPos = (histPos + 1) % Self.taps
        histFilled = min(histFilled + 1, Self.taps)
        // oldest-first view: hist[(histPos + i) % taps] is sample k - (taps-1) + i, so tap index
        // i = 0 … 15 ↔ c - 7 … c + 8 where c = k - 8.
        let c0 = hist[(histPos + Self.past) % Self.taps]
        var peak = abs(c0)
        for ph in Self.phases {
            var acc: Float = 0
            for i in 0..<Self.taps { acc += ph[i] * hist[(histPos + i) % Self.taps] }
            peak = max(peak, abs(acc))
        }
        let c1 = abs(hist[(histPos + Self.past + 1) % Self.taps])
        let intervalPeak = max(peak, c1)
        // Sample c gets max(previous interval, this interval).
        let p = max(prevIntervalPeak, intervalPeak)
        prevIntervalPeak = intervalPeak
        let g = p > detectCeiling ? detectCeiling / p : 1

        // 2. sliding minimum over the last W = lookaheadFrames + 1 required gains.
        let idx = n
        while minQueue.count > minHead, minQueue[minQueue.count - 1].g >= g { minQueue.removeLast() }
        minQueue.append((idx, g))
        while minQueue[minHead].idx <= idx - (lookaheadFrames + 1) { minHead += 1 }
        if minHead > 4096 { minQueue.removeFirst(minHead); minHead = 0 }
        let m = minQueue[minHead].g

        // 3. box average of length L = lookaheadFrames + 1, then release.
        boxSum += Double(m) - Double(box[boxPos])
        box[boxPos] = m
        boxPos = (boxPos + 1) % box.count
        let target = Float(boxSum / Double(box.count))
        gain = min(target, 1 - (1 - gain) * releaseCoef)
        n += 1

        // 4. output. g for sample c enters at this step; the box at step n averages minima over
        //    steps n-L+1 … n, each covering the L steps before it, so only the sample whose g
        //    entered at step n-L+1 = n-lookahead is covered by every term. Output that one: c0
        //    written `lookaheadFrames` steps ago (buffer of lookahead+1 slots, read after write).
        delay[delayPos] = c0
        delayPos = (delayPos + 1) % delay.count
        let out = delay[delayPos]
        return out * gain
    }

    private static func makePhases() -> [[Float]] {
        // Kaiser β = 6, 16 taps spanning c-7 … c+8, fractional positions ¼, ½, ¾ after c.
        func bessel0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0, k = 1.0
            while term > 1e-12 * sum { term *= (x / (2 * k)) * (x / (2 * k)); sum += term; k += 1 }
            return sum
        }
        let beta = 6.0
        return [0.25, 0.5, 0.75].map { f in
            var h = (0..<taps).map { i -> Double in
                let t = Double(i - past) - f                 // distance from the interpolated point
                let sinc = t == 0 ? 1 : sin(.pi * t) / (.pi * t)
                let r = (Double(i) - (Double(past) + f)) / (Double(taps) / 2)
                let w = abs(r) >= 1 ? 0 : bessel0(beta * (1 - r * r).squareRoot()) / bessel0(beta)
                return sinc * w
            }
            let s = h.reduce(0, +)
            h = h.map { $0 / s }
            return h.map(Float.init)
        }
    }
}
