import Foundation
import Testing
@testable import TalkTalkVoice

private let goodTranscript = TranscriptComparison.compare(transcript: EnrollmentScript.zhV1.text,
                                                          script: EnrollmentScript.zhV1.text)

@Suite struct ScriptTests {
    @Test func fixedScriptIs42HanCharactersInFiveClauses() {
        let s = EnrollmentScript.zhV1
        #expect(s.id == "zh-v1")
        #expect(s.hanCount == 42)
        #expect(s.clauses == ["大家好", "今天我先简单介绍一下项目的最新进展", "然后说说下一步的计划", "如果有问题", "欢迎随时打断我"])
        #expect(s.sha256.count == 64)
    }
}

@Suite struct TranscriptComparisonTests {
    @Test func identicalAndPunctuationOnlyDifferencesAreZero() {
        let s = EnrollmentScript.zhV1.text
        #expect(TranscriptComparison.compare(transcript: s, script: s).cer == 0)
        let noPunct = s.filter { !"，。".contains($0) }
        let r = TranscriptComparison.compare(transcript: noPunct + " ", script: s)
        #expect(r.cer == 0)
        #expect(r.languageIsZh)
        #expect(r.missingClauses.isEmpty)
    }

    @Test func substitutionsCount() {
        let s = EnrollmentScript.zhV1.text
        let wrong = s.replacingOccurrences(of: "进展", with: "进站").replacingOccurrences(of: "计划", with: "记化")
        let r = TranscriptComparison.compare(transcript: wrong, script: s)
        #expect(abs(r.cer - 3.0 / 42.0) < 1e-9)   // 展→站, 计→记, 划→化
        #expect(r.missingClauses.isEmpty)
    }

    @Test func droppedClauseIsDetected() {
        let s = EnrollmentScript.zhV1.text
        let dropped = s.replacingOccurrences(of: "然后说说下一步的计划。", with: "")
        let r = TranscriptComparison.compare(transcript: dropped, script: s)
        #expect(r.missingClauses == [2])
        #expect(EnrollmentChecks.transcriptCheck(r).status == .reject)
    }

    @Test func nonChineseFailsTheLanguageGate() {
        let r = TranscriptComparison.compare(transcript: "hello everyone today I will", script: EnrollmentScript.zhV1.text)
        #expect(!r.languageIsZh)
        #expect(EnrollmentChecks.transcriptCheck(r).status == .reject)
    }

    @Test func cerAtTheThreshold() {
        // 3 of 42 wrong = 7.1 % passes; 4 of 42 = 9.5 % is rejected.
        let s = EnrollmentScript.zhV1.text
        var chars = Array(s)
        let positions = chars.indices.filter { TranscriptComparison.isHan(chars[$0]) }
        for p in [positions[1], positions[12], positions[30]] { chars[p] = "啊" }   // spread over clauses
        #expect(EnrollmentChecks.transcriptCheck(TranscriptComparison.compare(transcript: String(chars), script: s)).status == .pass)
        chars[positions[20]] = "啊"
        #expect(EnrollmentChecks.transcriptCheck(TranscriptComparison.compare(transcript: String(chars), script: s)).status == .reject)
    }
}

@Suite struct SegmentationTests {
    @Test func trimsAndMeasuresPauses() {
        let take = Synth.take(segments: [3.0, 4.0], pauses: [0.8])
        let seg = SpeechSegmentation(samples: take, sampleRate: Synth.rate, noiseFloorDb: -68)
        #expect(seg.hasSpeech)
        #expect(abs(seg.trimmedSeconds - 7.8) < 0.1)
        #expect(abs(seg.longestPauseSeconds - 0.8) < 0.1)
        // 0.8 s pause compressed to 0.4 s.
        #expect(abs(seg.compressedSeconds - 7.4) < 0.1)
        #expect(abs(Levels.dbfs(seg.speechRMS) - (-22)) < 1.5)
    }

    @Test func clicksAreNotSpeech() {
        var x = Synth.noise(2, db: -70)
        for i in 0..<480 { x[48_000 + i] = 0.5 }   // 10 ms click
        let seg = SpeechSegmentation(samples: x, sampleRate: Synth.rate, noiseFloorDb: -70)
        #expect(!seg.hasSpeech)
    }

    @Test func thresholdIsClamped() {
        #expect(SpeechSegmentation.threshold(noiseFloorDb: -120) == -55)
        #expect(SpeechSegmentation.threshold(noiseFloorDb: -60) == -45)
        #expect(SpeechSegmentation.threshold(noiseFloorDb: -30) == -35)
    }
}

@Suite struct AutoStopTests {
    private func run(_ x: [Float], _ d: inout AutoStopDetector) -> (AutoStopDetector.Decision, Double) {
        var i = 0
        while i < x.count {
            let chunk = Array(x[i..<min(x.count, i + 480)])
            let r = d.feed(chunk)
            i += 480
            if r != .keepGoing { return (r, Double(i) / Synth.rate) }
        }
        return (.keepGoing, Double(i) / Synth.rate)
    }

    @Test func stopsAfterTrailingSilence() {
        let x = Synth.take(segments: [3.0], pauses: [], lead: 0.5, tail: 3.0)
        var d = AutoStopDetector(sampleRate: Synth.rate, noiseFloorDb: -68)
        let (decision, at) = run(x, &d)
        #expect(decision == .speechEnded)
        #expect(abs(at - (0.5 + 3.0 + 1.2)) < 0.1)
    }

    @Test func shortPauseDoesNotStop() {
        let x = Synth.take(segments: [2.0, 2.0], pauses: [1.0], lead: 0.5, tail: 3.0)
        var d = AutoStopDetector(sampleRate: Synth.rate, noiseFloorDb: -68)
        let (decision, at) = run(x, &d)
        #expect(decision == .speechEnded)
        #expect(at > 5.4)
    }

    @Test func silenceRunsToTheCap() {
        let x = Synth.noise(16, db: -68)
        var d = AutoStopDetector(sampleRate: Synth.rate, noiseFloorDb: -68)
        let (decision, at) = run(x, &d)
        #expect(decision == .reachedMax)
        #expect(abs(at - 15) < 0.05)
        #expect(!d.heardSpeech)
    }
}

@Suite struct EnrollmentChecksTests {
    let noise = Synth.noise(1.5, db: -68, seed: 3)

    private func evaluate(_ take: [Float], noise: [Float]? = nil,
                          transcript: TranscriptComparison.Result? = goodTranscript) -> EnrollmentReport {
        EnrollmentChecks.evaluate(take: take, noise: noise ?? self.noise, sampleRate: Synth.rate, transcript: transcript)
    }

    @Test func goodTakePassesEveryRowButAudition() {
        // −18 dBFS: the synthetic tone's crest factor is only ~11 dB, so this puts the peak in −12…−1.
        let r = evaluate(Synth.take(segments: [4.0, 4.5], pauses: [0.6], speechDb: -18))
        for row in r.results where row.id != .audition { #expect(row.status == .pass, "\(row.id) \(row)") }
        #expect(r.result(.audition)?.status == .pending)
        #expect(r.canSave)
        #expect(r.headline == nil)
        #expect(abs(r.measurements.speechSeconds - 8.9) < 0.1)
        #expect(abs(r.measurements.speakingRateCharsPerSecond - 42 / 8.9) < 0.1)
    }

    @Test func durationWindow() {
        let short = evaluate(Synth.take(segments: [4.0], pauses: []))
        #expect(short.result(.duration)?.status == .reject)
        #expect(short.headline == "请稍慢一点，再读一遍")
        let long = evaluate(Synth.take(segments: [6.5, 6.5], pauses: [0.3]))
        #expect(long.result(.duration)?.message == "请稍快一点，再读一遍")
        // Long pauses are compressed before timing: 5 + 2×(1.0 → 0.4) + 5 = 10.8 s → pass.
        let paused = evaluate(Synth.take(segments: [3.0, 3.0, 4.0], pauses: [1.0, 1.0]))
        #expect(paused.result(.duration)?.status == .pass)
        #expect(EnrollmentChecks.durationCheck(5.0, hasSpeech: true).status == .pass)
        #expect(EnrollmentChecks.durationCheck(12.0, hasSpeech: true).status == .pass)
        #expect(EnrollmentChecks.durationCheck(4.99, hasSpeech: true).status == .reject)
        #expect(EnrollmentChecks.durationCheck(12.01, hasSpeech: true).status == .reject)
    }

    @Test func clippingRule() {
        #expect(EnrollmentChecks.clippingCheck(fraction: 0.00009, run3: false).status == .pass)
        #expect(EnrollmentChecks.clippingCheck(fraction: 0.0001, run3: false).status == .reject)
        #expect(EnrollmentChecks.clippingCheck(fraction: 0, run3: true).message == "声音过大，请离远一点")
        var take = Synth.take(segments: [4.0, 4.0], pauses: [0.5])
        for i in 100_000..<100_003 { take[i] = 1.0 }
        let r = evaluate(take)
        #expect(r.measurements.clipRun3)
        #expect(r.result(.clipping)?.status == .reject)
        #expect(!r.canSave)
        let (fraction, run3) = EnrollmentChecks.clipping([0.99, 0.5, 0.999, 0.999, 0.5][...])
        #expect(abs(fraction - 0.6) < 1e-9)
        #expect(!run3)
    }

    @Test func levelRule() {
        #expect(EnrollmentChecks.levelCheck(peakDbfs: -6, speechRmsDbfs: -20).status == .pass)
        #expect(EnrollmentChecks.levelCheck(peakDbfs: -6, speechRmsDbfs: -31).status == .warn)
        #expect(EnrollmentChecks.levelCheck(peakDbfs: -14, speechRmsDbfs: -25).status == .warn)
        #expect(EnrollmentChecks.levelCheck(peakDbfs: -10, speechRmsDbfs: -33).message == "请靠近麦克风")
        #expect(EnrollmentChecks.levelCheck(peakDbfs: -0.5, speechRmsDbfs: -14).status == .warn)
        let quiet = evaluate(Synth.take(segments: [4.0, 4.0], pauses: [0.5], speechDb: -34, roomDb: -80),
                             noise: Synth.noise(1.5, db: -80))
        #expect(quiet.result(.level)?.status == .reject)
    }

    @Test func noiseFloorRule() {
        #expect(EnrollmentChecks.noiseFloorCheck(-60).status == .pass)
        #expect(EnrollmentChecks.noiseFloorCheck(-55).status == .pass)
        #expect(EnrollmentChecks.noiseFloorCheck(-50).status == .warn)
        #expect(EnrollmentChecks.noiseFloorCheck(-45).status == .warn)
        #expect(EnrollmentChecks.noiseFloorCheck(-44).message == "环境太吵")
        let noisy = evaluate(Synth.take(segments: [4.0, 4.0], pauses: [0.5], speechDb: -15, roomDb: -40),
                             noise: Synth.noise(1.5, db: -40))
        #expect(noisy.result(.noiseFloor)?.status == .reject)
        #expect(abs(noisy.measurements.noiseFloorDbfs - (-40)) < 0.5)
    }

    @Test func snrRule() {
        #expect(EnrollmentChecks.snrCheck(30).status == .pass)
        #expect(EnrollmentChecks.snrCheck(27).status == .warn)
        #expect(EnrollmentChecks.snrCheck(24.9).status == .reject)
        // −22 dBFS speech over a −50 dBFS room: SNR ≈ 28 dB → warning, still savable.
        let r = evaluate(Synth.take(segments: [4.0, 4.0], pauses: [0.5], roomDb: -50), noise: Synth.noise(1.5, db: -50))
        #expect(r.result(.snr)?.status == .warn)
        #expect(r.canSave)
    }

    @Test func pauseRule() {
        #expect(EnrollmentChecks.pauseCheck(1.2).status == .pass)
        #expect(EnrollmentChecks.pauseCheck(1.5).status == .warn)
        #expect(EnrollmentChecks.pauseCheck(2.1).status == .reject)
        let r = evaluate(Synth.take(segments: [4.0, 4.0], pauses: [2.5]))
        #expect(r.result(.pause)?.status == .reject)
        #expect(abs(r.measurements.longestPauseSeconds - 2.5) < 0.05)
    }

    @Test func digitalSilenceMeansNoPermission() {
        let zeros = [Float](repeating: 0, count: Int(10 * Synth.rate))
        let r = evaluate(zeros, noise: [Float](repeating: 0, count: Int(1.5 * Synth.rate)))
        #expect(r.measurements.digitalSilence)
        #expect(!r.canSave)
        #expect(r.headline?.contains("麦克风") == true)
    }

    @Test func missingRecognizerIsPendingNotFatal() {
        let r = evaluate(Synth.take(segments: [4.0, 4.5], pauses: [0.6]), transcript: nil)
        #expect(r.result(.transcript)?.status == .pending)
        #expect(r.canSave)
    }

    @Test func worstAndHeadlineOrder() {
        let r = EnrollmentReport(measurements: evaluate(Synth.take(segments: [4.0, 4.5], pauses: [0.6])).measurements,
                                 results: [.init(id: .noiseFloor, status: .warn, value: -50, message: "w"),
                                           .init(id: .duration, status: .reject, value: 3, message: "r")])
        #expect(r.worst == .reject)
        #expect(r.headline == "r")
    }
}

@Suite struct ReferenceAudioTests {
    @Test func postProcessing() throws {
        let take = Synth.take(segments: [4.0, 4.0], pauses: [0.5], lead: 1.0, tail: 1.5, speechDb: -27)
        let seg = SpeechSegmentation(samples: take, sampleRate: Synth.rate, noiseFloorDb: -68)
        let out = try ReferenceAudio.make(take: take, sampleRate: Synth.rate, segmentation: seg)
        let rate = ReferenceAudio.outputSampleRate
        // 0.15 lead + 8.5 speech + 0.1 release + 0.5 tail.
        #expect(abs(out.durationSeconds - 9.25) < 0.05)
        // Tail is 0.5 s of exact zeros.
        let tail = out.samples.suffix(Int(0.5 * rate))
        #expect(tail.allSatisfy { $0 == 0 })
        // Speech RMS is −20 dBFS (±0.5), peak ≤ −1 dBFS.
        let seg2 = SpeechSegmentation(samples: out.samples, sampleRate: rate, noiseFloorDb: -68 + out.gainDb)
        #expect(abs(Levels.dbfs(seg2.speechRMS) - (-20)) < 0.5)
        #expect(Levels.dbfs(Levels.peak(out.samples[...])) <= -0.99)
        // Leading silence ≈ 150 ms.
        let firstSpeech = Double(seg2.firstFrame ?? 0) * SpeechSegmentation.frameSeconds
        #expect(abs(firstSpeech - 0.15) < 0.03)
        #expect(abs(out.gainDb - 7) < 0.5)
    }

    @Test func gainIsCappedByPeak() throws {
        // A spiky take: normalizing RMS to −20 would push the peak over −1 dBFS.
        var take = Synth.take(segments: [4.0, 4.0], pauses: [0.5], speechDb: -30)
        take[100_000] = 0.9
        let seg = SpeechSegmentation(samples: take, sampleRate: Synth.rate, noiseFloorDb: -68)
        let out = try ReferenceAudio.make(take: take, sampleRate: Synth.rate, segmentation: seg)
        #expect(Levels.dbfs(Levels.peak(out.samples[...])) <= -0.9)
        #expect(out.gainDb < 10)
    }

    @Test func noSpeechThrows() {
        let x = Synth.noise(3, db: -70)
        let seg = SpeechSegmentation(samples: x, sampleRate: Synth.rate, noiseFloorDb: -70)
        #expect(throws: ReferenceAudio.Failure.noSpeech) { try ReferenceAudio.make(take: x, sampleRate: Synth.rate, segmentation: seg) }
    }

    @Test func resamplerKeepsLengthAndPitch() throws {
        let x = (0..<48_000).map { Float(sin(2 * Double.pi * 1000 * Double($0) / 48_000)) * 0.5 }
        let y = try Resampler.resample(x, from: 48_000, to: 24_000)
        #expect(abs(y.count - 24_000) < 64)
        // Zero crossings ≈ 2 per cycle → ~2000 in one second.
        var crossings = 0
        for i in 1000..<min(y.count, 23_000) where (y[i - 1] < 0) != (y[i] < 0) { crossings += 1 }
        #expect(abs(Double(crossings) / (22_000.0 / 24_000.0) - 2000) < 20)
        let z = try Resampler.resample(x, from: 44_100, to: 24_000)
        #expect(abs(Double(z.count) - 48_000 * 24_000 / 44_100) < 64)
    }

    @Test func wavRoundTrip() throws {
        let x: [Float] = [0, 0.5, -0.5, 1, -1, 0.25]
        let data = WAVFile.encodePCM16(x, sampleRate: 24_000)
        #expect(data.count == 44 + 12)
        let d = try #require(WAVFile.decodePCM16(data))
        #expect(d.sampleRate == 24_000)
        for (a, b) in zip(x, d.samples) { #expect(abs(a - b) < 1.0 / 32_000) }
        #expect(WAVFile.decodePCM16(Data("nope".utf8)) == nil)
    }
}
