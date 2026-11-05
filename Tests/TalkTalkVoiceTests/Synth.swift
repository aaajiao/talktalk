import Foundation
@testable import TalkTalkVoice

/// Deterministic synthetic audio for the enrollment tests: "speech" is a harmonic tone with a
/// 4 Hz syllable envelope, "room" is white noise. Levels are exact RMS in dBFS.
enum Synth {
    static let rate = 48_000.0

    struct LCG {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max)
        }
    }

    static func noise(_ seconds: Double, db: Double, seed: UInt64 = 1) -> [Float] {
        var g = LCG(state: seed)
        var x = (0..<Int(seconds * rate)).map { _ in g.next() }
        scale(&x, toRmsDb: db)
        return x
    }

    static func speech(_ seconds: Double, db: Double) -> [Float] {
        let n = Int(seconds * rate)
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / rate
            let env = 0.55 + 0.45 * sin(2 * .pi * 4 * t)
            let tone = sin(2 * .pi * 180 * t) + 0.5 * sin(2 * .pi * 360 * t) + 0.25 * sin(2 * .pi * 720 * t)
            x[i] = Float(env * tone)
        }
        scale(&x, toRmsDb: db)
        return x
    }

    static func scale(_ x: inout [Float], toRmsDb db: Double) {
        let rms = Levels.rms(x)
        guard rms > 0 else { return }
        let g = Float(Levels.linear(db) / rms)
        for i in x.indices { x[i] *= g }
    }

    static func mix(_ a: [Float], _ b: [Float]) -> [Float] {
        (0..<max(a.count, b.count)).map { (($0 < a.count) ? a[$0] : 0) + (($0 < b.count) ? b[$0] : 0) }
    }

    /// silence(lead) + speech segments separated by pauses + silence(tail), over a room tone.
    static func take(segments: [Double], pauses: [Double], lead: Double = 0.5, tail: Double = 0.6,
                     speechDb: Double = -22, roomDb: Double = -68) -> [Float] {
        var dry = [Float](repeating: 0, count: Int(lead * rate))
        for (i, s) in segments.enumerated() {
            dry += speech(s, db: speechDb)
            if i < pauses.count { dry += [Float](repeating: 0, count: Int(pauses[i] * rate)) }
        }
        dry += [Float](repeating: 0, count: Int(tail * rate))
        return mix(dry, noise(Double(dry.count) / rate, db: roomDb, seed: 7))
    }
}
