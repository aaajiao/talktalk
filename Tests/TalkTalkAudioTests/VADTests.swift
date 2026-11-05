import CAudioCore
import Foundation
import Testing

/// tt_vad: the vendored libfvad (WebRTC VAD) behind a thin wrapper, plus the frame level.
/// §3.2 runs it on the 16 kHz mic stream in 20 ms frames (320 samples).
@Suite struct VADTests {
    static let rate = 16000
    static let frame = 320

    /// Sample at time t of a synthetic voiced signal: a 140 Hz harmonic series shaped by three
    /// crude formants (700 / 1200 / 2500 Hz), amplitude-modulated at 4 Hz.
    static func voicedSample(_ t: Double, gain: Double = 1) -> Float {
        var s = 0.0
        for h in 1...25 {
            let fh = 140.0 * Double(h)
            let w = exp(-pow((fh - 700) / 250, 2)) + 0.6 * exp(-pow((fh - 1200) / 300, 2)) +
                0.3 * exp(-pow((fh - 2500) / 400, 2))
            s += w * sin(2 * Double.pi * fh * t)
        }
        return Float(gain * 0.15 * s * (0.6 + 0.4 * sin(2 * Double.pi * 4 * t)))
    }

    /// Frame k (of `length` samples) of the continuous voiced signal; samples outside `voiced`
    /// are silent.
    static func voiced(frame k: Int, length: Int = frame, gain: Double = 1, voiced: Range<Int>? = nil) -> [Float] {
        (0..<length).map { i in
            if let r = voiced, !r.contains(i) { return 0 }
            return voicedSample(Double(k * length + i) / Double(rate), gain: gain)
        }
    }

    /// Uniform white noise in [-amplitude, amplitude) from a seeded generator, reproducible in C
    /// (53-bit mantissa of xorshift64).
    static func noise(frames: Int, amplitude: Float, seed: UInt64) -> [[Float]] {
        var rng = RTRandom(seed: seed)
        return (0..<frames).map { _ in
            (0..<frame).map { _ in Float(Double(rng.next() >> 11) * 0x1p-53 * 2 - 1) * amplitude }
        }
    }

    private func decide(_ vad: OpaquePointer, _ frame: [Float]) -> Int32 {
        frame.withUnsafeBufferPointer { tt_vad_process_f32(vad, $0.baseAddress!, $0.count) }
    }

    @Test func createChecksModeAndRate() {
        for mode: Int32 in 0...3 {
            for rate: Int32 in [8000, 16000, 32000] {
                let v = tt_vad_create(mode, rate)
                #expect(v != nil)
                if let v { #expect(tt_vad_sample_rate(v) == rate) }
                tt_vad_destroy(v)
            }
            // libfvad's 48 kHz path judges a 20 / 30 ms frame by its first 10 ms (VENDOR.md).
            #expect(tt_vad_create(mode, 48000) == nil)
        }
        #expect(tt_vad_create(4, 16000) == nil)
        #expect(tt_vad_create(-1, 16000) == nil)
        #expect(tt_vad_create(2, 44100) == nil)
        let v = tt_vad_create(2, 16000)!
        defer { tt_vad_destroy(v) }
        #expect(tt_vad_set_mode(v, 5) == -1)
        #expect(tt_vad_set_mode(v, 3) == 0)
    }

    @Test func voicedSignalIsSpeechAndSilenceIsNot() throws {
        for mode: Int32 in 0...3 {
            let v = try #require(tt_vad_create(mode, 16000))
            defer { tt_vad_destroy(v) }
            let speech = (0..<100).filter { decide(v, Self.voiced(frame: $0)) == 1 }.count
            #expect(speech >= 95, "mode \(mode): \(speech)/100")
            tt_vad_reset(v)
            let silence = [Float](repeating: 0, count: Self.frame)
            let falseSpeech = (0..<100).filter { _ in decide(v, silence) == 1 }.count
            #expect(falseSpeech == 0, "mode \(mode)")
        }
    }

    /// The whole frame is judged, not its first 10 ms: speech only in the second half of each
    /// 20 ms frame (or the last third of a 30 ms one) is still speech. At 48 kHz libfvad would
    /// see 0 of these (checked against the vendored source, 2026-11-05).
    @Test func speechOnlyLateInTheFrameIsStillDetected() throws {
        for mode: Int32 in 0...3 {
            let v = try #require(tt_vad_create(mode, 16000))
            defer { tt_vad_destroy(v) }
            let half = (0..<100).filter { decide(v, Self.voiced(frame: $0, voiced: 160..<320)) == 1 }.count
            #expect(half >= 95, "mode \(mode): second half \(half)/100")
            tt_vad_reset(v)
            let third = (0..<100).filter {
                decide(v, Self.voiced(frame: $0, length: 480, voiced: 320..<480)) == 1
            }.count
            #expect(third >= 95, "mode \(mode): last third \(third)/100")
        }
    }

    @Test func onlyTenTwentyAndThirtyMillisecondFramesAreAccepted() throws {
        let v = try #require(tt_vad_create(2, 16000))
        defer { tt_vad_destroy(v) }
        for n in [160, 320, 480] {
            let r = decide(v, [Float](repeating: 0, count: n))
            #expect(r == 0 || r == 1, "\(n)")
        }
        for n in [100, 500, 481, 640, 960, 961, 2000] {
            #expect(decide(v, [Float](repeating: 0, count: n)) == -1, "\(n)")
        }
    }

    @Test func floatInputMatchesTheSameAudioAsInt16() throws {
        let a = try #require(tt_vad_create(2, 16000))
        let b = try #require(tt_vad_create(2, 16000))
        defer { tt_vad_destroy(a); tt_vad_destroy(b) }
        for k in 0..<200 {
            // Louder than full scale on some frames to exercise the clamp; quiet stretches too.
            let frame = Self.voiced(frame: k, gain: k % 50 < 10 ? 12 : (k % 50 < 25 ? 0.02 : 1))
            let ints = frame.map { Int16((min(max($0, -1), 1) * 32767).rounded(.toNearestOrEven)) }
            let fromFloat = decide(a, frame)
            let fromInt = ints.withUnsafeBufferPointer { tt_vad_process_i16(b, $0.baseAddress!, $0.count) }
            #expect(fromFloat == fromInt, "frame \(k)")
        }
    }

    /// White noise is where the modes differ (measured 150 / 26 / 4 / 4 speech frames of 200 for
    /// modes 0-3 with this seed), so it shows whether a reset kept the mode: libfvad's own
    /// fvad_reset sets it back to 0.
    @Test func modesDifferOnNoiseAndResetKeepsTheMode() throws {
        let frames = Self.noise(frames: 200, amplitude: 0.05, seed: 2026)
        func decisions(_ v: OpaquePointer) -> [Int32] { frames.map { decide(v, $0) } }
        var counts: [Int] = []
        for mode: Int32 in 0...3 {
            let v = try #require(tt_vad_create(mode, 16000))
            defer { tt_vad_destroy(v) }
            counts.append(decisions(v).filter { $0 == 1 }.count)
        }
        #expect(zip(counts, counts.dropFirst()).allSatisfy { $0 >= $1 }, "\(counts)")
        #expect(counts[0] - counts[3] >= 100, "\(counts)")

        let fresh3 = try #require(tt_vad_create(3, 16000))
        let fresh0 = try #require(tt_vad_create(0, 16000))
        let v = try #require(tt_vad_create(3, 16000))
        let switched = try #require(tt_vad_create(0, 16000))
        defer { tt_vad_destroy(fresh3); tt_vad_destroy(fresh0); tt_vad_destroy(v); tt_vad_destroy(switched) }
        let want3 = decisions(fresh3)
        let want0 = decisions(fresh0)
        #expect(want3 != want0)
        for k in 0..<60 { _ = decide(v, Self.voiced(frame: k, gain: k % 20 < 10 ? 1 : 0.01)) }
        tt_vad_reset(v)
        #expect(tt_vad_sample_rate(v) == 16000)
        let afterReset = decisions(v)
        #expect(afterReset == want3)
        #expect(afterReset != want0)
        #expect(tt_vad_set_mode(switched, 3) == 0)
        _ = decisions(switched)
        tt_vad_reset(switched)
        #expect(decisions(switched) == want3)
    }

    @Test func resetReturnsToTheInitialStateKeepingModeAndRate() throws {
        let v = try #require(tt_vad_create(3, 16000))
        let fresh = try #require(tt_vad_create(3, 16000))
        defer { tt_vad_destroy(v); tt_vad_destroy(fresh) }
        let frames = (0..<60).map { Self.voiced(frame: $0, gain: $0 % 20 < 10 ? 1 : 0.01) }
        for f in frames { _ = decide(v, f) }
        tt_vad_reset(v)
        #expect(tt_vad_sample_rate(v) == 16000)
        #expect(frames.map { decide(v, $0) } == frames.map { decide(fresh, $0) })
    }

    @Test func frameLevelInDecibelsFullScale() {
        let sine = (0..<320).map { Float(sin(2 * Double.pi * 1000 * Double($0) / 16000)) }
        #expect(abs(tt_vad_rms_dbfs(sine, 320) - (-3.0103)) < 0.01)
        #expect(abs(tt_vad_rms_dbfs([Float](repeating: 0.5, count: 320), 320) - (-6.0206)) < 0.01)
        #expect(tt_vad_rms_dbfs([Float](repeating: 0, count: 320), 320) == -120)
        #expect(tt_vad_rms_dbfs([Float](repeating: 1e-9, count: 320), 320) == -120)
        #expect(tt_vad_rms_dbfs(sine, 0) == -120)
    }
}
