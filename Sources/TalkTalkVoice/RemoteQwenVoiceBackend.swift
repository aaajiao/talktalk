import Foundation
import TalkTalkCore
import TalkTalkEngineHost

/// `VoiceEngineBackend` on the real engine (§4.4): `/v1/voice/build` and `/v1/voice/load` through
/// `EngineClient`, the wait-for-ready of `RemoteQwenTTS.load`, the audition through `/v1/tts`, the
/// read-back through `/v1/asr` (Qwen3-ASR). The engine gets bytes only, never a path (§9.3).
public struct RemoteQwenVoiceBackend: VoiceEngineBackend {
    public let engine: EngineProcess

    public init(engine: EngineProcess) {
        self.engine = engine
    }

    private func client() async throws -> EngineClient {
        _ = try await engine.start()
        guard let c = await engine.client else { throw EngineAPIError.invalidated }
        return c
    }

    /// From READY: runtime, `versions["mlx_audio"]`, and the TTS model's id and revision (the parts
    /// of the §9.3 cache key that say which engine a blob was built by). One TTS model per tier:
    /// the max profile keeps no 0.6B hot spare (m0-results, scope change).
    public func identity() async throws -> ConditioningIdentity {
        let ready = try await engine.start()
        guard let key = await engine.config.tts else { throw VoiceEngineError.noTTSModel }
        let installed = await engine.config.record.roles["tts"]?.rev
        let rev = ready.models["tts"]?.rev ?? installed ?? ""
        return ConditioningIdentity(runtime: ready.runtime, mlxAudio: ready.versions["mlx_audio"], models: [(key, rev)])
    }

    /// READY or not, and the ASR state: no ASR role in the install → `.absent`; role configured but
    /// engine not READY → `.loading`; READY → the staged state from `/v1/health`.
    public func readiness() async -> EngineReadiness {
        let hasASR = await engine.config.roles.contains("asr")
        guard case .ready = await engine.status, let c = await engine.client else {
            return EngineReadiness(running: false, asr: hasASR ? .loading : .absent)
        }
        guard hasASR else { return EngineReadiness(running: true, asr: .absent) }
        let state = (try? await c.health(timeout: 2))?.models["asr"]?.state
        return EngineReadiness(running: true, asr: state == "ready" ? .ready : .loading)
    }

    public func enrollmentFinished() async {
        await engine.enrollmentFinished()
    }

    /// Cancels the idle exit an earlier enrollment scheduled (m1-engine 48f1961). If that exit is
    /// already stopping the engine, the next `start()` cold-starts it.
    public func enrollmentStarted() async {
        await engine.enrollmentStarted()
    }

    public func build(reference24k: [Float], refText: String, model: String, mode: CloneMode) async throws -> (key: String, blob: Data) {
        // EngineClient.buildVoice sends mode "icl"; T7 lite kept ICL (accent 5.0), so no other mode
        // is needed. x-vector would need the engine route first (talktalk-m0).
        guard mode == .icl else { throw VoiceEngineError.unsupportedMode(mode) }
        let r = try await client().buildVoice(reference24k: reference24k, refText: refText, model: model)
        return (r.keyMaterial, r.blob)
    }

    public func load(blob: Data, model: String, key: String, mode: CloneMode, profileID: UUID) async throws {
        _ = try await engine.start()
        let handle = VoiceHandle(profileID: profileID, conditioningKey: key, mode: mode,
                                 model: EngineID(name: model, revision: "", placement: .engineGPU))
        try await RemoteQwenTTS(engine: engine).load(handle, blob: blob)
    }

    /// Does not start a stopped engine: a stopped engine has no voice loaded. A `/v1/voice/load`
    /// the client gave up on can still land on the engine after the unload, so the voice state is
    /// read back and the unload repeated until it says "absent" (§9.4 deletion: unload is last).
    public func unload() async throws -> Bool {
        guard let c = await engine.client else { return false }
        try await c.unloadVoice()
        for _ in 0..<Self.unloadRechecks {
            guard let h = try? await c.health(timeout: 2), h.voice.state != "absent" else { break }
            try await Task.sleep(for: .milliseconds(200))
            try await c.unloadVoice()
        }
        return true
    }

    static let unloadRechecks = 5

    public func synthesize(text: String, lang: Lang, seed: Int) async throws -> VoiceSynthesis {
        let stream = try await client().tts(EngineTTSRequest(text: text, lang: lang.rawValue,
                                                             job: EngineJobID.make(prefix: "audition"), seed: seed))
        let r = try await stream.collect()
        if let f = r.failure { throw RemoteEngineError.tts(code: f, message: "") }
        return VoiceSynthesis(samples: r.samples, runaway: r.tail?.runaway ?? false, short: r.tail?.short ?? false,
                              expectedSeconds: r.tail?.expectedS)
    }

    public func transcribe(samples16k: [Float], hint: Lang) async throws -> String {
        try await client().asr(samples16k: samples16k, hint: hint.rawValue, priority: 1, job: EngineJobID.make(prefix: "readback")).text
    }

    /// `/v1/voice/similarity` (the TTS model's own speaker encoder, a P3 step). A clip shorter than
    /// 0.5 s (`audio_too_short`) gives nil, shown as "—"; other engine errors are thrown (the
    /// audition keeps the clip and leaves the similarity empty).
    public func speakerSimilarity(reference24k: [Float], sample24k: [Float]) async throws -> Double? {
        let c = try await client()
        return try await Self.similarityOrNil { try await c.speakerSimilarity(reference24k: reference24k, sample24k: sample24k) }
    }

    static func similarityOrNil(_ call: () async throws -> Double) async throws -> Double? {
        do {
            return try await call()
        } catch EngineAPIError.http(_, "audio_too_short", _) {
            return nil
        }
    }
}
