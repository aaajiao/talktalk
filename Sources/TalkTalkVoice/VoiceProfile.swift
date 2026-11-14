import CryptoKit
import Foundation
import TalkTalkCore

/// `voice/profile.json` (ARCHITECTURE.md, "引擎、翻译与播放"). Holds hashes, measurements and settings — never
/// audio or text (the script text lives in `script.txt`).
public struct VoiceProfile: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var id: String
    public var createdAt: String
    public var scriptID: String
    public var scriptSHA256: String
    /// Length of `reference.wav`, seconds (including the 0.5 s tail).
    public var durationSeconds: Double
    public var wavSHA256: String
    /// Check statuses by row plus the raw measurements of the accepted take.
    public var checks: Checks
    public var mode: [String: String] = ["en": "icl", "de": "icl", "fr": "icl"]
    public var references: [String: String] = ["zh": VoiceStore.referenceName]
    public var useFor: [String: String] = ["en": "zh", "de": "zh", "fr": "zh"]
    /// Hash of the recording microphone's UID (§3.8 passthrough gain is keyed the same way).
    public var micUIDHash: String
    /// Calibrated speaking rate (script Han characters / compressed speech seconds), for §5.2.
    public var speakingRateCharsPerSecond: Double
    /// Conditioning and audition state: "pending_engine" until the engine builds them (§9.3).
    public var conditioning: String = "pending_engine"
    public var audition: String = "pending_engine"
    /// voice-m2 additions (§9.2 steps 6–7), all optional so M0/M1 profiles still decode.
    /// The conditioning files of this profile: full cache key, model, mode (file = safeKey(key)).
    public var conditioningEntries: [ConditioningEntry]?
    /// Inactive TTS models keep their own conditioning so selecting another model is reversible.
    /// The active entries above retain their legacy meaning for older readers and diagnostics.
    public var archivedConditioningEntries: [ConditioningEntry]?
    /// Audition calibration belongs to the exact conditioning, never to another TTS model.
    public var synthesisStates: [String: SynthesisState]?
    /// Optional original identity for reproducible sampling after editing the reference audio.
    /// Loading still uses each conditioning entry's actual key.
    public var samplingKey: String?
    /// PlayoutStage fixed gain from the audition loudness (§3.3), dB.
    public var playoutGainDb: Double?
    /// The audition's statuses and numbers (no audio, no text).
    public var auditionResult: AuditionResult.Summary?
    /// Who checked the transcript row last ("apple-zh-CN", "qwen3-asr").
    public var transcriptChecker: String?

    public struct ConditioningEntry: Codable, Sendable, Equatable {
        public var key: String
        public var model: String
        public var mode: CloneMode

        public init(key: String, model: String, mode: CloneMode) {
            self.key = key
            self.model = model
            self.mode = mode
        }
    }

    public struct SynthesisState: Codable, Sendable, Equatable {
        public var audition: String
        public var result: AuditionResult.Summary?
        public var gainDb: Double?
        public var status: CheckStatus?
    }

    /// Which recording this is. A change of either while an engine call is in flight means the
    /// user re-recorded or deleted: the result of that call is dropped, never written.
    public struct Identity: Sendable, Equatable {
        public var id: String
        public var wavSHA256: String
    }

    public var identity: Identity { Identity(id: id, wavSHA256: wavSHA256) }

    /// The conditioning entry SPEAK loads (the en mode; ICL output languages share it).
    public var speakEntry: ConditioningEntry? { conditioningEntries?.first { $0.mode == modesByLang[.en] } }

    /// The clone modes this profile needs conditioning for (one build per model × mode).
    public var cloneModes: [CloneMode] {
        var out: [CloneMode] = []
        for lang in ["en", "de", "fr"] {
            let m = CloneMode(rawValue: mode[lang] ?? "icl") ?? .icl
            if !out.contains(m) { out.append(m) }
        }
        return out
    }

    public var modesByLang: [Lang: CloneMode] {
        [.en: CloneMode(rawValue: mode["en"] ?? "icl") ?? .icl,
         .de: CloneMode(rawValue: mode["de"] ?? "icl") ?? .icl,
         .fr: CloneMode(rawValue: mode["fr"] ?? "icl") ?? .icl]
    }

    public struct Checks: Codable, Sendable, Equatable {
        public var status: [String: CheckStatus]
        public var measurements: EnrollmentMeasurements
    }

    enum CodingKeys: String, CodingKey {
        case version, id, createdAt = "created_at", scriptID = "script_id", scriptSHA256 = "script_sha256"
        case durationSeconds = "duration_s", wavSHA256 = "wav_sha256", checks, mode, references
        case useFor = "use_for", micUIDHash = "mic_uid_hash", speakingRateCharsPerSecond = "speaking_rate_cps"
        case conditioning, audition
        case conditioningEntries = "conditioning_keys", playoutGainDb = "playout_gain_db"
        case archivedConditioningEntries = "archived_conditioning_keys", synthesisStates = "synthesis_states"
        case samplingKey = "sampling_key"
        case auditionResult = "audition_result", transcriptChecker = "transcript_checker"
    }

    public init(id: String = UUID().uuidString, createdAt: Date = Date(), script: EnrollmentScript,
                wav: Data, report: EnrollmentReport, micUID: String, durationSeconds: Double) {
        self.id = id
        self.createdAt = ISO8601DateFormatter().string(from: createdAt)
        self.scriptID = script.id
        self.scriptSHA256 = script.sha256
        self.durationSeconds = durationSeconds
        self.wavSHA256 = sha256Hex(wav)
        var status: [String: CheckStatus] = [:]
        for r in report.results { status[r.id.rawValue] = r.status }
        self.checks = Checks(status: status, measurements: report.measurements)
        self.micUIDHash = Self.micUIDHash(micUID)
        self.speakingRateCharsPerSecond = report.measurements.speakingRateCharsPerSecond
    }

    /// First 16 hex digits of SHA-256 of the device UID.
    public static func micUIDHash(_ uid: String) -> String {
        String(sha256Hex(Data(uid.utf8)).prefix(16))
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> VoiceProfile {
        try JSONDecoder().decode(VoiceProfile.self, from: data)
    }
}
