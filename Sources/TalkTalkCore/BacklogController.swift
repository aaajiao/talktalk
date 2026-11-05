import Foundation

/// §5.5: recommendations for audio/text that has not started playing. The caller owns
/// queue mutations and excludes the announcement from all three duration inputs.
public struct BacklogController: Sendable {
    public enum Level: Int, Sendable, Comparable {
        case normal, faster, concise, summarize, dropOldest
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    public struct Decision: Sendable, Equatable {
        public var backlogS: Double
        public var level: Level
        public var tempo: Double
        public var dropGaps: Bool
        public var mtMode: MTMode
        /// Only applies to waiting clauses; no action may truncate playing audio.
        public var summarizeWaiting: Bool
        public var dropOldestWaiting: Bool
    }
    public let config: PolicyProfile.Speak.Backlog
    public let language: Lang
    public private(set) var level: Level = .normal
    private static let thresholds: [Double] = [0, 3, 5, 8, 12]

    public init(config: PolicyProfile.Speak.Backlog, language: Lang) {
        self.config = config; self.language = language
    }

    /// All durations are remaining playback seconds. renderedS already includes ringO;
    /// unrenderedS includes translated text once, and inFlightSourceS only untranslated clips.
    /// Hysteresis is a Q deadband: the >5 s level exits at ≤(5−hysteresisS), for example.
    public mutating func update(renderedS: Double, unrenderedS: Double, inFlightSourceS: Double) -> Decision {
        let q = [renderedS, unrenderedS, inFlightSourceS].reduce(0) { $0 + ($1.isFinite ? max(0, $1) : 0) }
        let desired = Self.thresholds.indices.last(where: { q > Self.thresholds[$0] }) ?? 0
        if desired > level.rawValue { level = Level(rawValue: desired)! }
        while level != .normal,
              q <= max(0, Self.thresholds[level.rawValue] - max(0, config.hysteresisS)) {
            level = Level(rawValue: level.rawValue - 1)!
        }
        let base = config.baseTempo[language.rawValue] ?? 1
        let tempo = level >= .concise ? config.q5.tempo : (level >= .faster ? base + config.q3.tempoStep : base)
        return Decision(backlogS: q, level: level, tempo: min(config.tempoMax, max(1, tempo)),
                        dropGaps: level >= .faster && config.q3.dropGaps,
                        mtMode: level >= .concise ? .concise : .normal,
                        summarizeWaiting: level == .summarize && config.q8 == "summarize",
                        dropOldestWaiting: level == .dropOldest && config.q12 == "dropOldest")
    }
}

/// Per voice/conditioning and language prediction calibration, not a playback-speed control.
/// Only raw, complete successful TTS durations contribute. The caller applies playback tempo
/// afterwards when estimating Q; engine runaway/short thresholds remain unchanged.
public struct DurationCalibration: Sendable {
    private struct Key: Hashable, Sendable { var voice: VoiceHandle; var language: Lang }
    private var ratios: [Key: [Double]] = [:]
    public init() {}

    public mutating func record(voice: VoiceHandle, language: Lang, text: String,
                                summary: TTSSummary, completed: Bool) {
        guard completed, !summary.runaway, !summary.short, ExpectedDuration.words(text) >= 5,
              summary.audioS.isFinite, summary.audioS > 0 else { return }
        let key = Key(voice: voice, language: language)
        ratios[key, default: []].append(summary.audioS / ExpectedDuration.seconds(text, language))
        if ratios[key]!.count > 20 { ratios[key]!.removeFirst() }
    }

    public func scale(voice: VoiceHandle, language: Lang) -> Double {
        guard let values = ratios[Key(voice: voice, language: language)], !values.isEmpty else { return 1 }
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    public func expectedSeconds(text: String, voice: VoiceHandle, language: Lang) -> Double {
        ExpectedDuration.seconds(text, language) * scale(voice: voice, language: language)
    }
}
