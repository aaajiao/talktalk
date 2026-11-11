import Foundation

// Protocol sketch, TTS subset (M2 SPEAK). Shapes as written in ARCHITECTURE.md; the
// shared types (Lang, Priority, EngineID, StageTiming, HostTime, JobID) are in Engines.swift.
//
// These are the app-side (Core) types. The engine wire format (`lang`, snake_case tail
// keys, ms timings) is mapped by RemoteQwenTTS in TalkTalkEngineHost, whose wire structs are
// named EngineTTS*. Two additions to the sketch, both needed to implement it as written:
// - `TTSChunk.summary`: the stream "ends with a TTSSummary" (§4.1); it rides on the isLast chunk.
// - `TTSChunk.clause` / `epoch` are not here: the app maps job → {clauseID, epoch} (§3.3).

public enum CloneMode: String, Codable, Sendable, CaseIterable { case icl, xvector, system }

/// Reference audio for `buildConditioning`: bytes, never a path (§4.1, §9.2 step 6).
public struct VoiceReference: Codable, Sendable, Equatable {
    public var pcm24k: Data
    public var text: String
    public var lang: Lang
    public init(pcm24k: Data, text: String, lang: Lang) {
        self.pcm24k = pcm24k; self.text = text; self.lang = lang
    }
}

public struct VoiceHandle: Codable, Sendable, Hashable {
    public var profileID: UUID
    public var conditioningKey: String
    /// Stable sampling identity when an accepted reference is edited; never used for voice loading.
    public var samplingKey: String?
    public var mode: CloneMode
    public var model: EngineID
    public init(profileID: UUID, conditioningKey: String, mode: CloneMode, model: EngineID, samplingKey: String? = nil) {
        self.profileID = profileID; self.conditioningKey = conditioningKey; self.mode = mode; self.model = model
        self.samplingKey = samplingKey
    }

    private enum CodingKeys: String, CodingKey {
        case profileID, conditioningKey, mode, model
        case samplingKey = "sampling_key"
    }
}

public struct TTSRequest: Codable, Sendable, Equatable {
    public var job: JobID
    public var clause: UInt64
    /// Already through TargetTextGate and TextNormalizer.
    public var text: String
    /// Always explicit (§5.5); never `zh` for a clone voice (TargetTextGate).
    public var language: Lang
    public var voice: VoiceHandle
    /// Fixed for a voice and output language, so sentence boundaries do not change the seed.
    public var seed: UInt32
    public var priority: Priority
    /// Short clause: render whole, pass runaway/short/echo checks, then return (§3.3).
    public var wholeClause: Bool
    /// Ephemeral continuity within one recording turn. Nil for auditions and announcements.
    public var contextID: String?
    public var previousJob: JobID?

    public init(job: JobID, clause: UInt64, text: String, language: Lang, voice: VoiceHandle,
                seed: UInt32, priority: Priority = .p0TTS, wholeClause: Bool,
                contextID: String? = nil, previousJob: JobID? = nil) {
        self.job = job; self.clause = clause; self.text = text; self.language = language
        self.voice = voice; self.seed = seed; self.priority = priority; self.wholeClause = wholeClause
        self.contextID = contextID; self.previousJob = previousJob
    }
}

/// End-of-stream summary (§4.4 `/v1/tts` tail). Coding keys are the wire keys of the tail.
public struct TTSSummary: Codable, Sendable, Equatable {
    public var audioS: Double
    public var frames: Int
    public var runaway, short, slow: Bool
    public var echoAborts: Int
    public var attempts: Int
    public var leadTrimMs: Int
    public var timing: StageTiming
    /// Actual compute/audio ratio from the engine, excluding legal horizon parking and HTTP.
    public var computeRTF: Double?
    public var contextUsed: Bool?

    public init(audioS: Double, frames: Int, runaway: Bool = false, short: Bool = false, slow: Bool = false,
                echoAborts: Int = 0, attempts: Int = 1, leadTrimMs: Int = 0, timing: StageTiming,
                computeRTF: Double? = nil, contextUsed: Bool? = nil) {
        self.audioS = audioS; self.frames = frames; self.runaway = runaway; self.short = short; self.slow = slow
        self.echoAborts = echoAborts; self.attempts = attempts; self.leadTrimMs = leadTrimMs; self.timing = timing; self.computeRTF = computeRTF
        self.contextUsed = contextUsed
    }

    private enum CodingKeys: String, CodingKey {
        case audioS = "audio_s", frames, runaway, short, slow, echoAborts = "echo_aborts", attempts
        case leadTrimMs = "lead_trim_ms", timing, computeRTF
        case contextUsed = "context_used"
    }
}

extension TTSSummary {
    // StageTiming (Engines.swift) is not Equatable; compare it field by field here rather than
    // adding a conformance to a type owned by another file.
    public static func == (a: TTSSummary, b: TTSSummary) -> Bool {
        a.audioS == b.audioS && a.frames == b.frames && a.runaway == b.runaway && a.short == b.short
            && a.slow == b.slow && a.echoAborts == b.echoAborts && a.attempts == b.attempts
            && a.leadTrimMs == b.leadTrimMs && a.computeRTF == b.computeRTF && a.timing.received == b.timing.received
            && a.contextUsed == b.contextUsed
            && a.timing.started == b.timing.started && a.timing.firstOutput == b.timing.firstOutput
            && a.timing.finished == b.timing.finished
    }
}

/// 24 kHz f32 mono, 0.16 s per chunk (§1.3). `TTSChunk(` appears only in RemoteQwenTTS,
/// SystemVoiceTTS and tests (§3.8 static rule).
public struct TTSChunk: Codable, Sendable, Equatable {
    public var job: JobID
    public var seq: Int
    public var samples24k: [Float]
    public var isLast: Bool
    public var producedAt: HostTime
    /// Set on the isLast chunk only (§4.1 "结束时附带 TTSSummary").
    public var summary: TTSSummary?

    public init(job: JobID, seq: Int, samples24k: [Float], isLast: Bool, producedAt: HostTime, summary: TTSSummary? = nil) {
        self.job = job; self.seq = seq; self.samples24k = samples24k; self.isLast = isLast
        self.producedAt = producedAt; self.summary = summary
    }
}

/// `/v1/playout` body (§4.4): every 100 ms during SPEAK, immediately on pause, underrun or tempo
/// change. `bufferedMs` = bufferedAhead = rendered-not-played in ClauseQueue + ringO fill (§3.3).
public struct PlayoutReport: Codable, Sendable, Equatable {
    public var job: JobID?
    public var bufferedMs: Int
    public var underruns: Int
    public var paused: Bool
    public var tempo: Double
    public var epoch: UInt32
    public var at: HostTime

    public init(job: JobID?, bufferedMs: Int, underruns: Int, paused: Bool, tempo: Double, epoch: UInt32, at: HostTime) {
        self.job = job; self.bufferedMs = bufferedMs; self.underruns = underruns; self.paused = paused
        self.tempo = tempo; self.epoch = epoch; self.at = at
    }
}

public protocol TTSEngine: Sendable {                                // RemoteQwenTTS; SystemVoiceTTS
    var id: EngineID { get }
    /// 24_000 for Qwen3-TTS.
    var outputRate: Double { get }
    /// Returns the conditioning blob; the app writes it to disk.
    func buildConditioning(_ ref: VoiceReference, model: EngineID, mode: CloneMode) async throws -> Data
    func load(_ voice: VoiceHandle, blob: Data) async throws
    /// Ends with a TTSSummary on the isLast chunk. Length is bounded by the render horizon;
    /// buffer cap = horizon + 1 chunk.
    func speak(_ r: TTSRequest) -> AsyncThrowingStream<TTSChunk, any Error>
    /// Feeds the engine scheduler's deadlines (§6.1).
    func report(_ p: PlayoutReport) async
    func cancel(_ job: JobID) async
}

/// Stable across launches and processes: FNV-1a over UTF-8, not Swift's randomized `Hasher`.
public enum TTSSeed {
    /// Production initial seed: one per voice/language, independent of the current sentence.
    /// These v1 salts preserve the exact seeds selected in the 2026-11-05 segmented C listening
    /// comparison. They are hash input only, never model prompts. Freeze their bytes; translating,
    /// normalizing or prefixing them would change the accepted voice's sampling sequence.
    public static func make(voice: VoiceHandle, language: Lang) -> UInt32 {
        // The Ming local audition accepted on 2026-11-07 used this fixed sampling seed
        // with the human reference and CAMPPlus embedding. Preserve it across clauses;
        // the existing Qwen per-voice/language seeds below are unchanged.
        if voice.model.name == "tts-ming3-0.5b-bf16" { return 20_261_107 }
        let anchor: String
        switch language {
        case .en:
            anchor = "After reviewing the latest project updates, we can confirm the budget and plan our next steps together."
        case .de:
            anchor = "Nachdem wir die aktuellen Ergebnisse gemeinsam geprüft haben, können wir das Budget bestätigen und die nächsten Schritte besprechen."
        case .zh:
            anchor = "talktalk-voice-seed-v1:zh" // Reserved; meeting SPEAK targets English/German.
        }
        return make(voice: voice, text: anchor)
    }

    /// Explicit text-derived seed retained for low-level comparisons and reproducibility.
    /// Product speech, announcements and auditions use the language overload above.
    public static func make(voice: VoiceHandle, text: String) -> UInt32 {
        var h: UInt32 = 0x811C_9DC5
        func mix(_ bytes: some Sequence<UInt8>) {
            for b in bytes { h ^= UInt32(b); h &*= 0x0100_0193 }
        }
        mix(voice.profileID.uuidString.utf8)
        mix([UInt8(0)])
        mix((voice.samplingKey ?? voice.conditioningKey).utf8)
        mix([UInt8(0)])
        mix(voice.mode.rawValue.utf8)
        mix([UInt8(0)])
        mix(text.utf8)
        return h
    }

    /// Retry seed (readread `next_seed`): deterministic successor for attempt n ≥ 1.
    public static func next(_ seed: UInt32, attempt: Int) -> UInt32 {
        var h = seed ^ 0x9E37_79B9 &* UInt32(truncatingIfNeeded: attempt)
        h ^= h >> 16; h &*= 0x85EB_CA6B; h ^= h >> 13
        return h
    }
}
