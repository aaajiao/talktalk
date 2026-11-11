import Accelerate
import Foundation

/// The numbers behind the driver self-test (ARCHITECTURE.md, "平台与模块"), as pure functions over
/// recorded samples placed by sample time. Same method as the M0-T8 bench (`ttdrv loopback`,
/// `ttdrv replay`): a 1 s, −18 dBFS log sweep 40 Hz → 16 kHz, cross-correlated over lags
/// 0…4800 frames; and a tone keyed by absolute sample time for the anti-replay check.
public enum DriverLoopbackAnalysis {
    public static let rate = 48_000
    public static let sweepFrames = 48_000
    /// Zeros before the sweep (the recorder is surely running by then).
    public static let leadFrames = 12_000
    public static let maxLag = 4_800

    /// §8.4 pass lines.
    public static let minPeak = 0.95
    public static let maxLevelDeltaDB = 0.5
    /// "附加延迟 ≤ 1 个 IO 周期": the driver's fixed lag is 480 frames, the IO period 480 frames.
    public static let maxLagFrames = 480

    /// 1 s exponential sweep 40 Hz → 16 kHz, peak −18 dBFS, 5 ms raised-cosine fades.
    public static func sweep() -> [Float] {
        let T = 1.0, f1 = 40.0, f2 = 16_000.0, amp = pow(10.0, -18.0 / 20.0), fade = 0.005
        let k = log(f2 / f1)
        return (0..<sweepFrames).map { i in
            let t = Double(i) / Double(rate)
            let phase = 2 * Double.pi * f1 * T / k * (exp(t * k / T) - 1)
            var env = 1.0
            if t < fade { env = 0.5 - 0.5 * cos(Double.pi * t / fade) }
            else if t > T - fade { env = 0.5 - 0.5 * cos(Double.pi * (T - t) / fade) }
            return Float(amp * env * sin(phase))
        }
    }

    /// A recording: chunks of contiguous frames, each at an input sample time.
    public struct Recording: Sendable, Equatable {
        public struct Chunk: Sendable, Equatable {
            public var sampleTime: Int64
            public var frames: Int
            public var offset: Int
            public init(sampleTime: Int64, frames: Int, offset: Int) {
                self.sampleTime = sampleTime
                self.frames = frames
                self.offset = offset
            }
        }
        public var chunks: [Chunk]
        public var samples: [Float]

        public init(chunks: [Chunk] = [], samples: [Float] = []) {
            self.chunks = chunks
            self.samples = samples
        }

        public var frameCount: Int { chunks.reduce(0) { $0 + $1.frames } }
        public var nonzeroCount: Int {
            chunks.reduce(0) { acc, c in acc + samples[c.offset..<(c.offset + c.frames)].reduce(0) { $1 != 0 ? $0 + 1 : $0 } }
        }

        /// Dense copy indexed by sample time: (first sample time, values, recorded mask).
        func dense() -> (lo: Int64, values: [Float], have: [Bool])? {
            guard let lo = chunks.map(\.sampleTime).min(),
                  let hi = chunks.map({ $0.sampleTime + Int64($0.frames) }).max(), hi > lo else { return nil }
            var v = [Float](repeating: 0, count: Int(hi - lo))
            var have = [Bool](repeating: false, count: Int(hi - lo))
            for c in chunks {
                for i in 0..<c.frames {
                    let at = Int(c.sampleTime - lo) + i
                    v[at] = samples[c.offset + i]
                    have[at] = true
                }
            }
            return (lo, v, have)
        }
    }

    public struct LoopStats: Sendable, Equatable, Codable {
        /// Frames between the written signal and where it was read (−1: not found).
        public var bestLag: Int
        /// Normalised cross-correlation at bestLag (1.0 = identical shape).
        public var peak: Double
        /// Energy of the recorded sweep vs. the written one, dB (nil: nothing recorded).
        public var levelDeltaDB: Double?
        /// Nonzero recorded samples outside the (lag-shifted) sweep: must be 0 (§8.4 "不播放时全零").
        public var nonzeroOutside: Int
        public var samples: Int
        public var nonzero: Int

        public var passes: Bool {
            bestLag >= 0 && bestLag <= DriverLoopbackAnalysis.maxLagFrames && peak >= DriverLoopbackAnalysis.minPeak
                && abs(levelDeltaDB ?? .infinity) <= DriverLoopbackAnalysis.maxLevelDeltaDB && nonzeroOutside == 0
        }
    }

    /// Cross-correlates `rec` against `signal`, which was written starting at sample time `signalStart`.
    public static func analyze(_ rec: Recording, signal: [Float], signalStart: Int64?) -> LoopStats {
        var st = LoopStats(bestLag: -1, peak: 0, levelDeltaDB: nil, nonzeroOutside: 0,
                           samples: rec.frameCount, nonzero: rec.nonzeroCount)
        guard let signalStart, !signal.isEmpty, let (lo, R, have) = rec.dense() else { return st }
        let n = signal.count
        var eRef: Float = 0
        vDSP_svesq(signal, 1, &eRef, vDSP_Length(n))
        guard eRef > 0 else { return st }
        var bestNum = -Double.greatestFiniteMagnitude
        var bestNorm = 0.0
        var best = -1
        R.withUnsafeBufferPointer { rp in
            signal.withUnsafeBufferPointer { wp in
                for lag in 0...maxLag {
                    // Recording index of signal frame 0 at this lag, clipped to the recording.
                    let start = Int(signalStart - lo) + lag
                    let a = max(0, start), b = min(R.count, start + n)
                    guard b > a else { continue }
                    var num: Float = 0, eRec: Float = 0
                    vDSP_dotpr(rp.baseAddress! + a, 1, wp.baseAddress! + (a - start), 1, &num, vDSP_Length(b - a))
                    vDSP_svesq(rp.baseAddress! + a, 1, &eRec, vDSP_Length(b - a))
                    if Double(num) > bestNum {
                        bestNum = Double(num)
                        best = lag
                        bestNorm = eRec > 0 ? Double(num) / (Double(eRec) * Double(eRef)).squareRoot() : 0
                    }
                }
            }
        }
        st.bestLag = best
        st.peak = bestNorm
        var eIn = 0.0
        for at in 0..<R.count where have[at] {
            let src = Int64(at) + lo - Int64(best)
            if src >= signalStart && src < signalStart + Int64(n) {
                eIn += Double(R[at]) * Double(R[at])
            } else if R[at] != 0 {
                st.nonzeroOutside += 1
            }
        }
        st.levelDeltaDB = eIn > 0 ? 10 * log10(eIn / Double(eRef)) : nil
        return st
    }

    public struct ReplayStats: Sendable, Equatable, Codable {
        public var checked: Int
        public var playedOK: Int
        public var playedBad: Int
        public var silentOK: Int
        /// Nonzero samples read where nothing was being written: a replay (must be 0).
        public var silentNonzero: Int
        public var ranges: Int

        public func passes(cycles: Int) -> Bool { playedBad == 0 && silentNonzero == 0 && playedOK > 0 && ranges >= cycles }
    }

    /// Every recorded sample at S must equal tone(S − lag) when S − lag lies in a written range,
    /// and be exactly 0 otherwise.
    public static func replay(_ rec: Recording, ranges: [ClosedRange<Int64>], lag: Int64 = 480,
                              tone: (Int64) -> Float) -> ReplayStats {
        var r = ReplayStats(checked: 0, playedOK: 0, playedBad: 0, silentOK: 0, silentNonzero: 0, ranges: ranges.count)
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        func written(_ s: Int64) -> Bool {
            // ranges are few (one per cycle): linear is fine
            sorted.contains { $0.contains(s) }
        }
        for c in rec.chunks {
            for i in 0..<c.frames {
                let s = c.sampleTime + Int64(i)
                let x = rec.samples[c.offset + i]
                r.checked += 1
                if written(s - lag) {
                    if abs(x - tone(s - lag)) <= 1e-6 { r.playedOK += 1 } else { r.playedBad += 1 }
                } else if x == 0 {
                    r.silentOK += 1
                } else {
                    r.silentNonzero += 1
                }
            }
        }
        return r
    }
}
