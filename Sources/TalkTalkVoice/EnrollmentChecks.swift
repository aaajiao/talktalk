// l10n: zh-Hans (scripts/check-strings.sh)
import TalkTalkCore
import Foundation

/// The automatic checks of ARCHITECTURE.md §9.2 step 4, one pure function per table row.
/// Thresholds are the table's; the user-facing messages are the table's wording where it gives one.
public enum CheckStatus: String, Codable, Sendable, Comparable {
    case pass, warn, reject
    /// Could not run yet (transcript recognizer unavailable, audition needs the engine).
    case pending

    var rank: Int {
        switch self {
        case .pass: 0
        case .pending: 1
        case .warn: 2
        case .reject: 3
        }
    }

    public static func < (a: CheckStatus, b: CheckStatus) -> Bool { a.rank < b.rank }
}

public enum CheckID: String, Codable, Sendable, CaseIterable {
    case duration, clipping, level, noiseFloor = "noise_floor", snr, pause, transcript, audition

    public var title: String {
        switch self {
        case .duration: String(appLocalized: "语音时长")
        case .clipping: String(appLocalized: "削波")
        case .level: String(appLocalized: "峰值 / 语音段音量")
        case .noiseFloor: String(appLocalized: "环境噪声")
        case .snr: String(appLocalized: "信噪比")
        case .pause: String(appLocalized: "最长停顿")
        case .transcript: String(appLocalized: "与稿子比对")
        case .audition: String(appLocalized: "en / de 试听")
        }
    }
}

public struct CheckResult: Codable, Sendable, Equatable {
    public let id: CheckID
    public let status: CheckStatus
    /// The measured value in the row's unit (s, dBFS, dB, fraction); nil when not measured.
    public let value: Double?
    /// Short Chinese text for the UI; empty on a plain pass.
    public let message: String

    public init(id: CheckID, status: CheckStatus, value: Double?, message: String = "") {
        self.id = id
        self.status = status
        self.value = value
        self.message = message
    }
}

/// Everything measured on one take. No audio, no text: safe for `profile.json` and bench output.
public struct EnrollmentMeasurements: Codable, Sendable, Equatable {
    public var speechSeconds: Double          // trimmed, pauses > 400 ms compressed (§9.1)
    public var trimmedSeconds: Double
    public var longestPauseSeconds: Double    // before compression
    public var clipFraction: Double
    public var clipRun3: Bool                 // 3 consecutive |x| ≥ 0.999
    public var peakDbfs: Double
    public var speechRmsDbfs: Double          // raw, before normalization (§9.2 step 6 passthrough gain)
    public var noiseFloorDbfs: Double
    public var snrDb: Double
    public var speakingRateCharsPerSecond: Double
    public var cer: Double?
    public var hanShare: Double?
    public var missingClauses: [Int]?
    public var digitalSilence: Bool

    enum CodingKeys: String, CodingKey {
        case speechSeconds = "speech_s", trimmedSeconds = "trimmed_s", longestPauseSeconds = "longest_pause_s"
        case clipFraction = "clip_fraction", clipRun3 = "clip_run3", peakDbfs = "peak_dbfs"
        case speechRmsDbfs = "speech_rms_dbfs", noiseFloorDbfs = "noise_floor_dbfs", snrDb = "snr_db"
        case speakingRateCharsPerSecond = "speaking_rate_cps", cer, hanShare = "han_share"
        case missingClauses = "missing_clauses", digitalSilence = "digital_silence"
    }
}

public struct EnrollmentReport: Codable, Sendable, Equatable {
    public var measurements: EnrollmentMeasurements
    public var results: [CheckResult]

    /// Saving is allowed when nothing is rejected. `pending` rows (no on-device recognizer,
    /// engine not installed) do not block: the profile records them and the engine re-checks.
    public var canSave: Bool { !results.contains { $0.status == .reject } }

    public var worst: CheckStatus { results.map(\.status).max() ?? .pass }

    /// The message to show first: the first rejection, else the first warning.
    public var headline: String? {
        (results.first { $0.status == .reject } ?? results.first { $0.status == .warn })?.message
    }

    public func result(_ id: CheckID) -> CheckResult? { results.first { $0.id == id } }
}

public enum EnrollmentChecks {
    // MARK: thresholds (§9.1, §9.2 step 4)
    public static let durationRange = 10.0...20.0
    public static let clipLevel: Float = 0.98
    public static let clipFractionLimit = 0.0001     // < 0.01 %
    public static let clipHardLevel: Float = 0.999
    public static let peakPassRange = -12.0 ... -1.0
    public static let rmsPassRange = -30.0 ... -12.0
    public static let rmsRejectBelow = -32.0
    public static let noisePassMax = -55.0
    public static let noiseRejectAbove = -45.0
    public static let snrPassMin = 30.0
    public static let snrRejectBelow = 25.0
    public static let pausePassMax = 1.2
    public static let pauseRejectAbove = 2.0
    public static let cerPassMax = 0.08

    /// Fraction of samples with |x| ≥ 0.98, and whether 3 consecutive samples reach 0.999.
    public static func clipping(_ x: ArraySlice<Float>) -> (fraction: Double, run3: Bool) {
        guard !x.isEmpty else { return (0, false) }
        var hits = 0, run = 0
        var run3 = false
        for v in x {
            let a = abs(v)
            if a >= clipLevel { hits += 1 }
            if a >= clipHardLevel { run += 1; if run >= 3 { run3 = true } } else { run = 0 }
        }
        return (Double(hits) / Double(x.count), run3)
    }

    public static func durationCheck(_ seconds: Double, hasSpeech: Bool) -> CheckResult {
        if !hasSpeech {
            return CheckResult(id: .duration, status: .reject, value: 0, message: String(appLocalized: "没有录到说话的声音，请再读一遍"))
        }
        if seconds < durationRange.lowerBound {
            return CheckResult(id: .duration, status: .reject, value: seconds, message: String(appLocalized: "录音偏短，请完整读完这段文字，保持自然语速"))
        }
        if seconds > durationRange.upperBound {
            return CheckResult(id: .duration, status: .reject, value: seconds, message: String(appLocalized: "录音偏长，请自然连贯地读完，减少句间长停顿"))
        }
        return CheckResult(id: .duration, status: .pass, value: seconds)
    }

    public static func clippingCheck(fraction: Double, run3: Bool) -> CheckResult {
        if fraction < clipFractionLimit && !run3 {
            return CheckResult(id: .clipping, status: .pass, value: fraction)
        }
        return CheckResult(id: .clipping, status: .reject, value: fraction, message: String(appLocalized: "声音过大，请离远一点"))
    }

    /// Peak and speech RMS in one row, as in the table. A peak above −1 dBFS that did not clip
    /// is only a warning (the table has no reject for it; the clipping row covers real clipping).
    public static func levelCheck(peakDbfs: Double, speechRmsDbfs: Double) -> CheckResult {
        if speechRmsDbfs < rmsRejectBelow {
            return CheckResult(id: .level, status: .reject, value: speechRmsDbfs, message: String(appLocalized: "请靠近麦克风"))
        }
        if speechRmsDbfs < rmsPassRange.lowerBound || peakDbfs < peakPassRange.lowerBound {
            return CheckResult(id: .level, status: .warn, value: speechRmsDbfs, message: String(appLocalized: "声音偏低，可以再靠近一点"))
        }
        if speechRmsDbfs > rmsPassRange.upperBound || peakDbfs > peakPassRange.upperBound {
            return CheckResult(id: .level, status: .warn, value: speechRmsDbfs, message: String(appLocalized: "声音偏高，可以离远一点"))
        }
        return CheckResult(id: .level, status: .pass, value: speechRmsDbfs)
    }

    public static func noiseFloorCheck(_ db: Double) -> CheckResult {
        if db <= noisePassMax { return CheckResult(id: .noiseFloor, status: .pass, value: db) }
        if db <= noiseRejectAbove {
            return CheckResult(id: .noiseFloor, status: .warn, value: db, message: String(appLocalized: "环境有点吵，安静一些效果更好"))
        }
        return CheckResult(id: .noiseFloor, status: .reject, value: db, message: String(appLocalized: "环境太吵"))
    }

    public static func snrCheck(_ db: Double) -> CheckResult {
        if db >= snrPassMin { return CheckResult(id: .snr, status: .pass, value: db) }
        if db >= snrRejectBelow {
            return CheckResult(id: .snr, status: .warn, value: db, message: String(appLocalized: "人声和背景噪声差得不够多"))
        }
        return CheckResult(id: .snr, status: .reject, value: db, message: String(appLocalized: "背景噪声太大，请换个安静的地方或靠近麦克风"))
    }

    public static func pauseCheck(_ seconds: Double) -> CheckResult {
        if seconds <= pausePassMax { return CheckResult(id: .pause, status: .pass, value: seconds) }
        if seconds <= pauseRejectAbove {
            return CheckResult(id: .pause, status: .warn, value: seconds, message: String(appLocalized: "中间停顿有点长"))
        }
        return CheckResult(id: .pause, status: .reject, value: seconds, message: String(appLocalized: "中间停顿太长，请一口气读完"))
    }

    /// nil comparison = recognizer unavailable → pending.
    public static func transcriptCheck(_ comparison: TranscriptComparison.Result?) -> CheckResult {
        guard let c = comparison else {
            return CheckResult(id: .transcript, status: .pending, value: nil,
                               message: String(appLocalized: "本机语音识别不可用，暂未核对逐字稿（引擎就绪后再核对）"))
        }
        if c.cer <= cerPassMax && c.languageIsZh && c.missingClauses.isEmpty {
            return CheckResult(id: .transcript, status: .pass, value: c.cer)
        }
        return CheckResult(id: .transcript, status: .reject, value: c.cer, message: String(appLocalized: "有几个字和稿子不一样，请再读一遍"))
    }

    /// The audition row needs the engine (§9.2 steps 6–7); until then it is pending.
    public static func auditionPending() -> CheckResult {
        CheckResult(id: .audition, status: .pending, value: nil, message: String(appLocalized: "待引擎：试听在引擎就绪后进行"))
    }

    /// Runs every row on a take. `noise` is the 1.5 s quiet segment recorded before the take
    /// (its first 100 ms, the IO start-up, is skipped). `transcript` is nil when unavailable.
    public static func evaluate(take: [Float], noise: [Float], sampleRate: Double,
                                script: EnrollmentScript = .current,
                                transcript: TranscriptComparison.Result?) -> EnrollmentReport {
        let skip = min(noise.count, Int(sampleRate * 0.1))
        let noiseDb = Levels.dbfs(Levels.rms(noise[skip...]))
        let seg = SpeechSegmentation(samples: take, sampleRate: sampleRate, noiseFloorDb: noiseDb)
        let span = seg.speechSampleRange.map { take[$0.clamped(to: 0..<take.count)] } ?? take[...]
        let clip = clipping(span)
        let peakDb = Levels.dbfs(Levels.peak(span))
        let rmsDb = Levels.dbfs(seg.speechRMS)
        let snr = seg.hasSpeech ? rmsDb - noiseDb : 0
        let rate = seg.compressedSeconds > 0 ? Double(script.hanCount) / seg.compressedSeconds : 0
        let silent = Levels.isDigitalSilence(take) && Levels.isDigitalSilence(noise)

        let m = EnrollmentMeasurements(
            speechSeconds: seg.compressedSeconds, trimmedSeconds: seg.trimmedSeconds,
            longestPauseSeconds: seg.longestPauseSeconds, clipFraction: clip.fraction, clipRun3: clip.run3,
            peakDbfs: peakDb, speechRmsDbfs: rmsDb, noiseFloorDbfs: noiseDb, snrDb: snr,
            speakingRateCharsPerSecond: rate, cer: transcript?.cer, hanShare: transcript?.hanShare,
            missingClauses: transcript?.missingClauses, digitalSilence: silent)

        if silent {
            // TCC denial reads exact zeros (§2.2); every other row would be meaningless.
            let r = CheckResult(id: .duration, status: .reject, value: 0,
                                message: String(appLocalized: "麦克风读到的全是静音：请在“系统设置 › 隐私与安全性 › 麦克风”里允许 TalkTalk"))
            return EnrollmentReport(measurements: m, results: [r])
        }
        var results = [
            durationCheck(seg.compressedSeconds, hasSpeech: seg.hasSpeech),
            clippingCheck(fraction: clip.fraction, run3: clip.run3),
            levelCheck(peakDbfs: peakDb, speechRmsDbfs: rmsDb),
            noiseFloorCheck(noiseDb),
        ]
        if seg.hasSpeech {
            results.append(snrCheck(snr))
            results.append(pauseCheck(seg.longestPauseSeconds))
            results.append(transcriptCheck(transcript))
        }
        results.append(auditionPending())
        return EnrollmentReport(measurements: m, results: results)
    }
}
