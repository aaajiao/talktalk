import Foundation

// Support for the dev-only `--bench record` (ARCHITECTURE.md M0: T5 and T17 test segments).
// Kept here, next to the enrollment code it shares (MicCapture, segmentation, private files),
// so it can be unit tested; only TalkTalk-Dev.app has an entry point that uses it.
// It never touches `voice/`.

/// One sentence table from `tools/bench/corpus/<set>.json` (maintained by the corpus session).
public struct BenchCorpusSet: Decodable, Sendable, Equatable {
    public let set: String
    public let record: Bool
    public let lang: String?
    /// "auto" (stop after `silenceStopSeconds` of silence) or "manual" (press semantics, T17).
    public let stop: String?
    public let silenceStopSeconds: Double?
    public let maxSeconds: Double?
    public let how: String?
    public let items: [Item]

    public struct Item: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let text: String
        /// How to read it aloud when `text` contains digits (T5).
        public let spoken: String?
        /// "press" (default) or "tap" (T17: a short key tap, no recording).
        public let kind: String?
        public let taps: Int?
        public let gapAfterSeconds: Double?
        public let expect: String?

        enum CodingKeys: String, CodingKey {
            case id, text, spoken, kind, taps, gapAfterSeconds = "gap_after_s", expect
        }

        /// What the screen shows: the spoken form when there is one.
        public var prompt: String { spoken ?? text }
        public var needsRecording: Bool { kind != "tap" }
    }

    enum CodingKeys: String, CodingKey {
        case set, record, lang, stop, silenceStopSeconds = "silence_stop_s", maxSeconds = "max_s", how, items
    }

    public var autoStop: Bool { stop != "manual" }
    public var recordedItems: [Item] { items.filter(\.needsRecording) }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notRecordable(String)
        case badID(String)
        case duplicateID(String)

        public var description: String {
            switch self {
            case let .notRecordable(s): "set \(s) is not a recording set (record=false)"
            case let .badID(id): "item id '\(id)' is not a safe file name"
            case let .duplicateID(id): "duplicate item id '\(id)'"
            }
        }
    }

    public static func decode(_ data: Data) throws -> BenchCorpusSet {
        let set = try JSONDecoder().decode(BenchCorpusSet.self, from: data)
        guard set.record else { throw Failure.notRecordable(set.set) }
        var seen = Set<String>()
        for item in set.items {
            guard isSafeName(item.id) else { throw Failure.badID(item.id) }
            guard seen.insert(item.id).inserted else { throw Failure.duplicateID(item.id) }
        }
        return set
    }

    public static func load(_ name: String, corpusDir: URL) throws -> BenchCorpusSet {
        guard isSafeName(name) else { throw Failure.badID(name) }
        return try decode(Data(contentsOf: corpusDir.appendingPathComponent(name + ".json")))
    }

    /// `--corpus <dir>` if given; otherwise `tools/bench/corpus` found by walking up from the
    /// app bundle (build/TalkTalk-Dev.app lives inside the repository).
    public static func locateCorpusDir(explicit: String?, startingAt bundleURL: URL) -> URL? {
        if let explicit { return URL(fileURLWithPath: explicit, isDirectory: true) }
        var dir = bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("tools/bench/corpus", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    static func isSafeName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.first != "." && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }
}

/// Measurements stored next to each bench take (no text, no audio).
public struct BenchTakeMeta: Codable, Sendable, Equatable {
    public var id: String
    public var sampleRate: Int
    public var durationSeconds: Double
    public var speechSeconds: Double
    public var peakDbfs: Double
    public var speechRmsDbfs: Double
    public var noiseFloorDbfs: Double
    public var clipFraction: Double
    public var trimmed: Bool
    public var micUIDHash: String
    public var recordedAt: String

    enum CodingKeys: String, CodingKey {
        case id, sampleRate = "sample_rate", durationSeconds = "duration_s", speechSeconds = "speech_s"
        case peakDbfs = "peak_dbfs", speechRmsDbfs = "speech_rms_dbfs", noiseFloorDbfs = "noise_floor_dbfs"
        case clipFraction = "clip_fraction", trimmed, micUIDHash = "mic_uid_hash", recordedAt = "recorded_at"
    }
}

/// Result of the quick per-take check of `--bench record`.
public struct BenchTakeCheck: Sendable, Equatable {
    public let status: CheckStatus
    public let message: String
    /// The samples to store (trimmed for auto-stop sets) and their measurements.
    public let samples: [Float]
    public let meta: BenchTakeMeta

    /// Auto-stop sets keep 0.3 s around the speech; manual (press) sets keep the take as is,
    /// because sample 0 is the key-down and the last sample the key-up.
    public static let keepAroundSpeechSeconds = 0.3

    public static func evaluate(id: String, take: [Float], sampleRate: Double, noiseFloorDb: Double,
                                trim: Bool, micUID: String, now: Date = Date()) -> BenchTakeCheck {
        let seg = SpeechSegmentation(samples: take, sampleRate: sampleRate, noiseFloorDb: noiseFloorDb)
        var out = take
        if trim, let range = seg.speechSampleRange {
            let keep = Int(keepAroundSpeechSeconds * sampleRate)
            out = Array(take[max(0, range.lowerBound - keep)..<min(take.count, range.upperBound + keep)])
        }
        let span = seg.speechSampleRange.map { take[$0.clamped(to: 0..<take.count)] } ?? take[...]
        let clip = EnrollmentChecks.clipping(span)
        let meta = BenchTakeMeta(
            id: id, sampleRate: Int(sampleRate), durationSeconds: Double(out.count) / sampleRate,
            speechSeconds: seg.trimmedSeconds, peakDbfs: Levels.dbfs(Levels.peak(span)),
            speechRmsDbfs: Levels.dbfs(seg.speechRMS), noiseFloorDbfs: noiseFloorDb, clipFraction: clip.fraction,
            trimmed: trim, micUIDHash: VoiceProfile.micUIDHash(micUID),
            recordedAt: ISO8601DateFormatter().string(from: now))
        let (status, message): (CheckStatus, String)
        if Levels.isDigitalSilence(take) {
            (status, message) = (.reject, "麦克风读到的全是静音：请检查麦克风权限")
        } else if !seg.hasSpeech {
            (status, message) = (.reject, "没有录到说话的声音")
        } else if clip.fraction >= EnrollmentChecks.clipFractionLimit || clip.run3 {
            (status, message) = (.warn, "有削波，声音过大")
        } else if meta.speechRmsDbfs < -35 {
            (status, message) = (.warn, "声音偏轻")
        } else {
            (status, message) = (.pass, "")
        }
        return BenchTakeCheck(status: status, message: message, samples: out, meta: meta)
    }
}

/// `~/Library/Application Support/TalkTalk-bench/recordings/<set>/<id>.wav` plus `manifest.json`.
/// Same protection as `voice/` (0700 / 0600, no backup, no Spotlight): the takes are personal.
public struct BenchRecordingStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var product: BenchRecordingStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return BenchRecordingStore(root: base.appendingPathComponent("TalkTalk-bench/recordings", isDirectory: true))
    }

    public func setDir(_ set: String) -> URL { root.appendingPathComponent(set, isDirectory: true) }
    public func takeURL(set: String, id: String) -> URL { setDir(set).appendingPathComponent(id + ".wav") }

    public func manifest(set: String) -> [String: BenchTakeMeta] {
        guard let data = try? Data(contentsOf: setDir(set).appendingPathComponent("manifest.json")),
              let m = try? JSONDecoder().decode([String: BenchTakeMeta].self, from: data) else { return [:] }
        return m
    }

    public func hasTake(set: String, id: String) -> Bool {
        FileManager.default.fileExists(atPath: takeURL(set: set, id: id).path)
    }

    public func save(_ check: BenchTakeCheck, set: String) throws {
        try PrivateFiles.makeDirectory(root)
        try PrivateFiles.makeDirectory(setDir(set))
        let wav = WAVFile.encodePCM16(check.samples, sampleRate: check.meta.sampleRate)
        try PrivateFiles.write(wav, to: takeURL(set: set, id: check.meta.id))
        var m = manifest(set: set)
        m[check.meta.id] = check.meta
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PrivateFiles.write(try e.encode(m), to: setDir(set).appendingPathComponent("manifest.json"))
    }

    public func load(set: String, id: String) -> WAVFile.Decoded? {
        (try? Data(contentsOf: takeURL(set: set, id: id))).flatMap(WAVFile.decodePCM16)
    }

    /// Writes an assembled file (T17 `zh.wav` and its events) into the set directory.
    public func writeAssembly(_ assembly: T17Assembly, set: String) throws {
        try PrivateFiles.makeDirectory(setDir(set))
        try PrivateFiles.write(WAVFile.encodePCM16(assembly.samples, sampleRate: assembly.sampleRate),
                               to: setDir(set).appendingPathComponent("zh.wav"))
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PrivateFiles.write(try e.encode(assembly.events), to: setDir(set).appendingPathComponent("zh.events.json"))
    }
}

/// T17's `zh.wav`: the press takes in table order, `gap_after_s` of silence after each item, with
/// the key-down / key-up time of every press and tap (§14 T17; the corpus says the bench does the
/// concatenation). Taps are 80 ms (< 150 ms) and contribute only silence.
public struct T17Assembly: Sendable, Equatable {
    public struct Event: Codable, Sendable, Equatable {
        public let id: String
        public let kind: String
        public let pressSeconds: Double
        public let releaseSeconds: Double

        enum CodingKeys: String, CodingKey {
            case id, kind, pressSeconds = "press_s", releaseSeconds = "release_s"
        }
    }

    public let samples: [Float]
    public let sampleRate: Int
    public let events: [Event]

    public static let leadSeconds = 1.0
    public static let tapSeconds = 0.08
    public static let tapSpacingSeconds = 0.4
    public static let defaultGapSeconds = 3.0

    public enum Failure: Error, Equatable { case missingTake(String) }

    /// `takes` maps item id → decoded take. Takes at another rate are resampled to the first's.
    public static func assemble(set: BenchCorpusSet, takes: [String: WAVFile.Decoded]) throws -> T17Assembly {
        guard let first = set.recordedItems.first.flatMap({ takes[$0.id] }) else {
            throw Failure.missingTake(set.recordedItems.first?.id ?? "")
        }
        let rate = first.sampleRate
        var out = [Float](repeating: 0, count: Int(leadSeconds * Double(rate)))
        var events: [Event] = []
        func now() -> Double { Double(out.count) / Double(rate) }
        func silence(_ s: Double) { out.append(contentsOf: [Float](repeating: 0, count: Int((s * Double(rate)).rounded()))) }
        for item in set.items {
            if item.needsRecording {
                guard let take = takes[item.id] else { throw Failure.missingTake(item.id) }
                let samples = take.sampleRate == rate
                    ? take.samples
                    : try Resampler.resample(take.samples, from: Double(take.sampleRate), to: Double(rate))
                let press = now()
                out.append(contentsOf: samples)
                events.append(Event(id: item.id, kind: "press", pressSeconds: press, releaseSeconds: now()))
            } else {
                for t in 0..<max(1, item.taps ?? 1) {
                    if t > 0 { silence(tapSpacingSeconds) }
                    let press = now()
                    silence(tapSeconds)
                    events.append(Event(id: item.id, kind: "tap", pressSeconds: press, releaseSeconds: now()))
                }
            }
            silence(item.gapAfterSeconds ?? defaultGapSeconds)
        }
        return T17Assembly(samples: out, sampleRate: rate, events: events)
    }
}
