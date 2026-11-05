import Foundation

/// Qwen3-TTS in the engine (§4.1 `RemoteQwenTTS`). M1 has the protocol side only: playback
/// (PlayoutStage, ClauseQueue) arrives in M2. Conformance to the §4.1 protocols in
/// TalkTalkCore/Engines.swift is added when that file lands.
public struct RemoteQwenTTS: Sendable {
    public let engine: EngineProcess
    /// Last PlayoutReport (bufferedAhead for the stall rule); shared by copies of this value.
    public let playout: PlayoutBox
    public let stall: TTSStall.Config
    /// Open SPEAK streams in submission order (only the oldest can stall) and the engine-wide
    /// unresolved stall; shared by copies of this value.
    public let board: TTSStallBoard

    /// `stall.horizonMs` is taken from the engine's config (the `--horizon-ms` it was started with).
    public init(engine: EngineProcess, stall: TTSStall.Config = .init()) {
        self.engine = engine
        self.playout = PlayoutBox()
        var s = stall
        s.horizonMs = engine.config.horizonMs
        self.stall = s
        self.board = TTSStallBoard()
    }

    /// Starts one clause. The engine must be READY with a voice loaded (`voice.state == ready`),
    /// otherwise the stream fails with `voice_absent`.
    public func speak(_ text: String, lang: String, job: String = EngineJobID.make(prefix: "tts"),
                      seed: Int? = nil) async throws -> EngineTTSStream {
        try await readyClient(engine).tts(EngineTTSRequest(text: text, lang: lang, job: job, seed: seed))
    }
}

/// Qwen3-ASR in the engine (§4.1 `RemoteQwenASR`): the second-pass ASR seam for LISTEN and the
/// SPEAK recogniser. LISTEN's first pass never goes through the engine (Apple ASR), so an engine
/// restart only pauses this (§7.6).
public struct RemoteQwenASR: Sendable {
    public let engine: EngineProcess

    public init(engine: EngineProcess) {
        self.engine = engine
    }

    /// 16 kHz mono samples; `priority` 1 = SPEAK (P1), 2 = LISTEN second pass (P2).
    public func transcribe(_ samples16k: [Float], hint: String?, priority: Int, job: String? = nil,
                           context: String? = nil) async throws -> ASRResult {
        try await readyClient(engine).asr(samples16k: samples16k, hint: hint, priority: priority, job: job, context: context)
    }
}

func readyClient(_ engine: EngineProcess) async throws -> EngineClient {
    try await engine.start()
    guard let c = await engine.client else { throw EngineAPIError.invalidated }
    return c
}

/// A whole clause collected from a stream, with client-side timing (§14 T1 method: TTFA is the
/// arrival of the first sample above −40 dBFS).
public struct EngineTTSResult: Sendable {
    public let samples: [Float]
    public let tail: EngineTTSTail?
    public let failure: String?
    /// Request start → first PCM byte / first sample above −40 dBFS / end, in ms.
    public let firstByteMs: Double?
    public let firstAudibleMs: Double?
    public let totalMs: Double

    public var audioSeconds: Double { Double(samples.count) / 24000 }
    /// Client-side RTF (wall time over audio time).
    public var rtf: Double? { audioSeconds > 0 ? totalMs / 1000 / audioSeconds : nil }
}

extension EngineTTSStream {
    public static let audibleThreshold: Float = 0.01   // −40 dBFS

    /// Reads the stream to the end. `started` is when the request was sent.
    public func collect(started: ContinuousClock.Instant = .now) async throws -> EngineTTSResult {
        var samples: [Float] = []
        var tail: EngineTTSTail?
        var failure: String?
        var firstByte: Double?
        var firstAudible: Double?
        func ms() -> Double { (ContinuousClock.now - started).seconds * 1000 }
        for try await ev in events {
            switch ev {
            case .pcm(let p):
                if firstByte == nil { firstByte = ms() }
                if firstAudible == nil, p.contains(where: { abs($0) > Self.audibleThreshold }) { firstAudible = ms() }
                samples += p
            case .tail(let t): tail = t
            case .failed(let code, let message): failure = message.isEmpty ? code : "\(code): \(message)"
            case .head, .progress, .unknown: break
            }
        }
        return EngineTTSResult(samples: samples, tail: tail, failure: failure, firstByteMs: firstByte,
                         firstAudibleMs: firstAudible, totalMs: ms())
    }
}
