import Foundation
import Testing
@testable import TalkTalkAudio

/// Independent 4× true-peak meter: zero-stuffing + a 256-tap Blackman-windowed sinc (64 taps per
/// phase), deliberately different from the limiter's 16-tap Kaiser interpolator.
func truePeakDbtp(_ y: [Float]) -> Double {
    let L = 256
    var h = [Double](repeating: 0, count: L)
    for i in 0..<L {
        let t = (Double(i) - Double(L) / 2) / 4
        let sinc = t == 0 ? 1 : sin(.pi * t) / (.pi * t)
        let w = 0.42 - 0.5 * cos(2 * .pi * Double(i) / Double(L - 1)) + 0.08 * cos(4 * .pi * Double(i) / Double(L - 1))
        h[i] = sinc * w
    }
    let s = h.reduce(0, +)
    h = h.map { $0 / s * 4 }
    var peak = 0.0
    for n in 0..<(y.count * 4) {
        var acc = 0.0
        // up[m] = y[m/4] when m % 4 == 0
        var m = n - L / 2 + ((4 - (n - L / 2) % 4) % 4)
        while m <= n + L / 2 - 1 {
            if m >= 0, m / 4 < y.count { acc += Double(y[m / 4]) * h[m - (n - L / 2)] }
            m += 4
        }
        peak = max(peak, abs(acc))
    }
    return 20 * log10(max(peak, 1e-12))
}

struct LCG {
    var s: UInt64
    mutating func next() -> Double {
        s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(s >> 11) / Double(1 << 53)
    }
    mutating func gauss() -> Double { (-2 * log(max(next(), 1e-12))).squareRoot() * cos(2 * .pi * next()) }
}

@Suite struct TruePeakLimiterTests {
    func run(_ x: [Float]) -> [Float] {
        var l = TruePeakLimiter()
        var y: [Float] = []
        // In blocks, as the worker does.
        var i = 0
        while i < x.count { let n = min(960, x.count - i); l.process(Array(x[i..<(i + n)]), into: &y); i += n }
        l.flush(into: &y)
        return Array(y[l.latencyFrames...])
    }

    @Test func neverExceedsMinusOneDbtp() {
        var rng = LCG(s: 42)
        let sr = 48_000.0
        let n = 12_000
        var signals: [[Float]] = []
        for k in 0..<4 {
            // near-Nyquist-for-TTS sines (≤ 12 kHz after 24k→48k) with random phase, +3…+12 dB over
            let f = 5_000 + 6_900 * rng.next(), ph = 6.28 * rng.next(), a = 1.4 + 2.6 * rng.next()
            signals.append((0..<n).map { Float(a * sin(2 * .pi * f * Double($0) / sr + ph)) })
            _ = k
        }
        for _ in 0..<3 {   // band-limited noise
            var w = (0..<n).map { _ in rng.gauss() * (0.5 + 2.5 * rng.next()) }
            for _ in 0..<2 { w = (0..<n).map { i in 0.25 * w[max(i - 1, 0)] + 0.5 * w[i] + 0.25 * w[min(i + 1, n - 1)] } }
            signals.append(w.map(Float.init))
        }
        // impulses and a quiet/loud gate (attack test)
        var imp = [Float](repeating: 0, count: n)
        for _ in 0..<30 { imp[Int(rng.next() * Double(n - 1))] = Float(6 * rng.next() - 3) }
        signals.append(imp)
        signals.append((0..<n).map { i in Float(sin(2 * .pi * 200 * Double(i) / sr)) * ((i / 2400) % 2 == 0 ? 0.05 : 3) })
        for x in signals {
            let y = run(x)
            #expect(y.count == x.count)
            #expect(truePeakDbtp(y) <= -1.0, "true peak \(truePeakDbtp(y)) dBTP")
        }
    }

    @Test func quietSignalPassesUnchangedWithFixedLatency() {
        let x = (0..<4800).map { Float(0.1 * sin(2 * .pi * 440 * Double($0) / 48_000)) }
        let y = run(x)
        #expect(zip(x, y).allSatisfy { abs($0 - $1) < 1e-7 })
        #expect(TruePeakLimiter().latencyFrames == 240 + 8)       // 5 ms + interpolator look-ahead
    }

    @Test func resetClearsState() {
        var l = TruePeakLimiter()
        var y: [Float] = []
        l.process([Float](repeating: 3, count: 1000), into: &y)
        l.reset()
        y = []
        l.process([Float](repeating: 0.1, count: 2000), into: &y)
        #expect(abs(y[1999] - 0.1) < 1e-6)
    }
}
