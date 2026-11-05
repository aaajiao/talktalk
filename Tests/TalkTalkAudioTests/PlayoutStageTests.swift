import Foundation
import Testing
@testable import TalkTalkAudio

/// Offline renders of the playout chain (§3.3 unit tests).
@Suite struct PlayoutStageTests {
    /// Speech-like 24 kHz test signal: two partials with a 4 Hz amplitude modulation (or a steady
    /// envelope), no pauses.
    func voiced(_ seconds: Double, amp: Double = 0.2, am: Bool = true) -> [Float] {
        let n = Int(seconds * 24_000)
        return (0..<n).map { i in
            let t = Double(i) / 24_000
            let env = am ? 0.75 + 0.25 * sin(2 * .pi * 4 * t) : 1
            return Float(amp * env * (0.7 * sin(2 * .pi * 180 * t) + 0.3 * sin(2 * .pi * 540 * t)))
        }
    }

    func render(_ x: [Float], tempo: Double, stage: PlayoutStage? = nil) throws -> (out: [Float], stage: PlayoutStage) {
        let s = try stage ?? PlayoutStage()
        try s.begin(tempo: tempo)
        var y: [Float] = []
        var i = 0
        while i < x.count {                       // 0.16 s TTS chunks
            let n = min(3840, x.count - i)
            y += try s.process(Array(x[i..<(i + n)]))
            i += n
        }
        y += try s.finish()
        return (y, s)
    }

    func rmsDb(_ x: ArraySlice<Float>) -> Double {
        20 * log10(max(Double(blockRMS(x)), 1e-12))
    }

    var limiterTail: Int { TruePeakLimiter().latencyFrames }

    @Test(arguments: [1.1, 1.2, 1.25])
    func tempoDurationWithinOnePercent(tempo: Double) throws {
        let x = voiced(3.0)
        let (y, _) = try render(x, tempo: tempo)
        let content = Double(y.count - limiterTail)               // the limiter flush adds its lookahead
        let expected = Double(x.count * 2) / tempo
        #expect(abs(content - expected) / expected <= 0.01, "got \(content) want \(expected)")
    }

    /// The last 50 ms are flushed out of TimePitch: energy within 1 dB of the unstretched render.
    /// Steady envelope: a phase vocoder shifts the phase of a 4 Hz amplitude modulation, which
    /// would make the comparison measure modulation phase instead of the flush.
    @Test(arguments: [1.1, 1.25])
    func tempoTailEnergyMatchesReference(tempo: Double) throws {
        let x = voiced(2.0, am: false)
        let (ref, _) = try render(x, tempo: 1.0)
        let (y, _) = try render(x, tempo: tempo)
        let w = 2400                                              // 50 ms @ 48 kHz; content ends at the end
        let r = ref[(ref.count - w)...]
        let s = y[(y.count - w)...]
        #expect(abs(rmsDb(s) - rmsDb(r)) <= 1.0, "tail \(rmsDb(s)) vs \(rmsDb(r)) dB")
    }

    /// TimePitch adds no offset: a level step near the start and one near the end of the clause
    /// come out at input / tempo (±5 ms), so nothing is cut at the end.
    @Test(arguments: [1.1, 1.25])
    func tempoKeepsStepsInPlace(tempo: Double) throws {
        let quiet = voiced(0.5, amp: 0.03, am: false), loud = voiced(1.0, amp: 0.3, am: false)
        let x = quiet + loud + voiced(0.3, amp: 0.03, am: false)
        let (y0, _) = try render(x, tempo: tempo)
        let y = Array(y0[limiterTail...])                        // the limiter delay is at the front
        func rms(_ j: Int) -> Double { Double(blockRMS(y[j..<(j + 480)])) }
        let mid = (rms(Int(0.25 * 48_000 / tempo)) * rms(Int(1.0 * 48_000 / tempo))).squareRoot()
        var up = Int(0.3 * 48_000 / tempo)
        while rms(up) < mid { up += 48 }
        var down = Int(1.2 * 48_000 / tempo)
        while rms(down) > mid { down += 48 }
        // window centre at the crossing ≈ the step (±1 window bias for the 10:1 level ratio)
        let upMs = Double(up + 240) / 48, downMs = Double(down + 240) / 48
        #expect(abs(upMs - 500 / tempo) <= 5 + 5, "rise at \(upMs) ms, want \(500 / tempo)")
        #expect(abs(downMs - 1500 / tempo) <= 5 + 5, "fall at \(downMs) ms, want \(1500 / tempo)")
    }

    @Test func bypassAtTempoOneIsExactlyTwiceTheLength() throws {
        let x = voiced(1.0)
        let (y, _) = try render(x, tempo: 1.0)
        #expect(y.count - limiterTail == x.count * 2)
    }

    /// isLast: TailTrim keeps ≈ 60 ms of the trailing quiet run.
    @Test func tailTrimKeeps60msOnIsLast() throws {
        let x = voiced(0.5) + [Float](repeating: 0, count: Int(0.3 * 24_000))
        var t = TailTrim(.init(), rate: 24_000)
        var y: [Float] = []
        var i = 0
        while i < x.count { let n = min(1000, x.count - i); y += t.process(Array(x[i..<(i + n)])); i += n }
        y += t.finish()
        #expect(y.count == 12_000 + 1440)                         // 0.5 s + 60 ms at 24 kHz
        // Through the whole stage: the quiet tail after the last audible sample ≈ 60 ms (+ flush).
        let (out, _) = try render(x, tempo: 1.0)
        let lastLoud = out.lastIndex { abs($0) > 0.005 }!
        let quietMs = Double(out.count - 1 - lastLoud) / 48      // limiter delay is at the front
        #expect(quietMs >= 55 && quietMs <= 70, "quiet tail \(quietMs) ms")
    }

    @Test func tailTrimReleasesQuietRunBeforeMoreAudio() {
        var t = TailTrim(.init(), rate: 24_000)
        let a = voiced(0.2), gap = [Float](repeating: 0, count: 4800), b = voiced(0.2)
        var y = t.process(a + gap)
        #expect(y.count == a.count)                               // the 200 ms gap is held
        y += t.process(b)
        y += t.finish()
        #expect(y.count == a.count + gap.count + b.count)         // released unchanged
    }

    @Test func leadTrimDropsQuietStartUpTo400ms() {
        var l = LeadTrim(.init(), rate: 24_000)
        let y = l.process([Float](repeating: 0, count: 4800) + voiced(0.2)) + l.finish()
        #expect(y.count == 4800 && l.trimmedMs == 200)
        var m = LeadTrim(.init(), rate: 24_000)
        let z = m.process([Float](repeating: 0, count: 14_400) + voiced(0.1)) + m.finish()
        #expect(m.trimmedMs == 400 && z.count == 14_400 - 9600 + 2400)
    }

    @Test func fixedGainAndLimiterCeiling() throws {
        // +18 dB on a −6 dBFS signal: the limiter holds −1 dBTP.
        let stage = try PlayoutStage(config: .init(gainDb: 18))
        let (y, _) = try render(voiced(1.0, amp: 0.5), tempo: 1.0, stage: stage)
        #expect(truePeakDbtp(Array(y[0..<min(y.count, 24_000)])) <= -1.0)
        // 0 dB default leaves a signal under the ceiling at its level.
        let x = voiced(1.0)
        let (z, _) = try render(x, tempo: 1.0)
        let pin = x.map(abs).max()!, pout = z.map(abs).max()!
        #expect(abs(pout - pin) / pin < 0.03)
    }

    @Test func midClauseTempoChangeLosesNothing() throws {
        let x = voiced(2.0)
        let s = try PlayoutStage()
        try s.begin(tempo: 1.0)
        var y = try s.process(Array(x[0..<24_000]))
        y += try s.setTempo(1.25)
        y += try s.process(Array(x[24_000...]))
        y += try s.finish()
        let expected = Double(24_000 * 2) + Double(24_000 * 2) / 1.25
        #expect(abs(Double(y.count - limiterTail) - expected) / expected <= 0.01)
    }
}
