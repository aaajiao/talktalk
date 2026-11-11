import Foundation

/// Level helpers and an energy-based speech/silence segmentation for enrollment takes
/// (ARCHITECTURE.md). Pure functions on mono Float32 at any sample rate.
public enum Levels {
    public static let floorDb = -120.0

    public static func dbfs(_ linear: Double) -> Double {
        linear <= 1e-6 ? floorDb : max(floorDb, 20 * log10(linear))
    }

    public static func linear(_ db: Double) -> Double { pow(10, db / 20) }

    public static func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        var sum = 0.0
        for v in x { sum += Double(v) * Double(v) }
        return (sum / Double(x.count)).squareRoot()
    }

    public static func rms(_ x: [Float]) -> Double { rms(x[...]) }

    public static func peak(_ x: ArraySlice<Float>) -> Double {
        var p: Float = 0
        for v in x { p = max(p, abs(v)) }
        return Double(p)
    }

    /// True when every sample is exactly zero (what an IOProc reads when TCC denies the mic).
    public static func isDigitalSilence(_ x: [Float]) -> Bool { !x.contains { $0 != 0 } }
}

public struct SpeechSegmentation: Sendable, Equatable {
    public static let frameSeconds = 0.02
    /// A pause longer than this is shortened to it before timing (§9.1).
    public static let pauseCompressionSeconds = 0.4
    /// Speech runs shorter than this many frames are treated as clicks.
    static let minSpeechRunFrames = 3

    public let sampleRate: Double
    public let frameLength: Int
    public let thresholdDb: Double
    /// Per-frame: is speech.
    public let speech: [Bool]
    /// First / last speech frame (inclusive); nil when there is no speech.
    public let firstFrame: Int?
    public let lastFrame: Int?
    /// Internal pauses between speech runs, in frames.
    public let pauses: [Int]
    /// RMS over speech frames only (linear).
    public let speechRMS: Double

    public var hasSpeech: Bool { firstFrame != nil }

    /// First speech sample .. one past the last speech sample.
    public var speechSampleRange: Range<Int>? {
        guard let f = firstFrame, let l = lastFrame else { return nil }
        return (f * frameLength)..<((l + 1) * frameLength)
    }

    /// Duration from the first to the last speech frame, without compression.
    public var trimmedSeconds: Double {
        guard let f = firstFrame, let l = lastFrame else { return 0 }
        return Double(l - f + 1) * Self.frameSeconds
    }

    public var longestPauseSeconds: Double { Double(pauses.max() ?? 0) * Self.frameSeconds }

    /// Trimmed duration with every internal pause > 400 ms shortened to 400 ms (§9.1 timing).
    public var compressedSeconds: Double {
        let cap = Int((Self.pauseCompressionSeconds / Self.frameSeconds).rounded())
        let removed = pauses.reduce(0) { $0 + max(0, $1 - cap) }
        return trimmedSeconds - Double(removed) * Self.frameSeconds
    }

    /// Speech threshold relative to the measured noise floor: 15 dB above it, kept within
    /// −55…−35 dBFS so a digital-silence floor or a noisy room still gives a usable split.
    public static func threshold(noiseFloorDb: Double) -> Double {
        min(max(noiseFloorDb + 15, -55), -35)
    }

    public init(samples: [Float], sampleRate: Double, noiseFloorDb: Double) {
        self.sampleRate = sampleRate
        let frameLength = max(1, Int((sampleRate * Self.frameSeconds).rounded()))
        self.frameLength = frameLength
        let thresholdDb = Self.threshold(noiseFloorDb: noiseFloorDb)
        self.thresholdDb = thresholdDb
        let frameCount = samples.count / frameLength
        var speech = [Bool](repeating: false, count: frameCount)
        for i in 0..<frameCount {
            let frame = samples[(i * frameLength)..<((i + 1) * frameLength)]
            speech[i] = Levels.dbfs(Levels.rms(frame)) > thresholdDb
        }
        // Drop short runs (clicks, a bumped table).
        var i = 0
        while i < frameCount {
            guard speech[i] else { i += 1; continue }
            var j = i
            while j < frameCount && speech[j] { j += 1 }
            if j - i < Self.minSpeechRunFrames { for k in i..<j { speech[k] = false } }
            i = j
        }
        self.speech = speech
        let first = speech.firstIndex(of: true)
        let last = speech.lastIndex(of: true)
        self.firstFrame = first
        self.lastFrame = last

        var pauses: [Int] = []
        var energy = 0.0
        var count = 0
        if let first, let last {
            var gap = 0
            for k in first...last {
                if speech[k] {
                    if gap > 0 { pauses.append(gap); gap = 0 }
                    for v in samples[(k * frameLength)..<((k + 1) * frameLength)] { energy += Double(v) * Double(v) }
                    count += frameLength
                } else {
                    gap += 1
                }
            }
        }
        self.pauses = pauses
        self.speechRMS = count > 0 ? (energy / Double(count)).squareRoot() : 0
    }
}

/// Streaming end-of-speech detector for the recorder (§9.2 step 3: stop 1.2 s after speech ends,
/// or at the recording cap). Feed it 20 ms frame levels as they arrive.
public struct AutoStopDetector: Sendable {
    public let thresholdDb: Double
    public let trailingSilenceSeconds: Double
    public let maxSeconds: Double
    /// Speech must have lasted this long before trailing silence can stop the take.
    public let minSpeechSeconds: Double

    private var pending: [Float] = []
    private var frameLength: Int
    private var frames = 0
    private var speechFrames = 0
    private var runFrames = 0
    private var silenceFrames = 0

    public private(set) var heardSpeech = false

    public init(sampleRate: Double, noiseFloorDb: Double, trailingSilenceSeconds: Double = 1.2,
                maxSeconds: Double = VoiceEnrollment.maxRecordingSeconds, minSpeechSeconds: Double = 0.3) {
        self.thresholdDb = SpeechSegmentation.threshold(noiseFloorDb: noiseFloorDb)
        self.trailingSilenceSeconds = trailingSilenceSeconds
        self.maxSeconds = maxSeconds
        self.minSpeechSeconds = minSpeechSeconds
        self.frameLength = max(1, Int((sampleRate * SpeechSegmentation.frameSeconds).rounded()))
    }

    public enum Decision: Equatable, Sendable { case keepGoing, speechEnded, reachedMax }

    public var elapsedSeconds: Double { Double(frames) * SpeechSegmentation.frameSeconds }

    public mutating func feed(_ samples: [Float]) -> Decision {
        pending.append(contentsOf: samples)
        var offset = 0
        var decision = Decision.keepGoing
        while pending.count - offset >= frameLength {
            let frame = pending[offset..<(offset + frameLength)]
            offset += frameLength
            frames += 1
            if Levels.dbfs(Levels.rms(frame)) > thresholdDb {
                runFrames += 1
                // A run counts once it is longer than a click (same rule as SpeechSegmentation).
                if runFrames >= SpeechSegmentation.minSpeechRunFrames {
                    if runFrames == SpeechSegmentation.minSpeechRunFrames { speechFrames += runFrames } else { speechFrames += 1 }
                    silenceFrames = 0
                } else {
                    silenceFrames += 1
                }
            } else {
                runFrames = 0
                silenceFrames += 1
            }
            if Double(speechFrames) * SpeechSegmentation.frameSeconds >= minSpeechSeconds { heardSpeech = true }
            if heardSpeech && Double(silenceFrames) * SpeechSegmentation.frameSeconds >= trailingSilenceSeconds {
                decision = .speechEnded
                break
            }
            if elapsedSeconds >= maxSeconds {
                decision = .reachedMax
                break
            }
        }
        pending.removeFirst(offset)
        return decision
    }
}
