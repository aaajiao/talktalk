import Foundation
import TalkTalkApple
import TalkTalkCore
import TalkTalkEngineHost
import TalkTalkVoice

#if TALKTALK_DEV
/// T10's MLX load (ARCHITECTURE.md): the installed engine, TTS role only,
/// synthesizing clause after clause with nothing played, so the render horizon never parks it.
/// Voice: the engine's synthetic warm-up reference (as BenchEngineRestart), never "my voice".
actor EngineTTSLoad: BenchLoad {
    private let engine: EngineProcess
    nonisolated let config: EngineConfig
    private let client: EngineClient
    private let sentences: [(text: String, lang: String)]
    private var active = false
    private var loop: Task<Void, Never>?
    private var clauses = 0, errors = 0
    private var audioS = 0.0, busyS = 0.0
    private var next = 0

    private init(engine: EngineProcess, config: EngineConfig, client: EngineClient, sentences: [(String, String)]) {
        self.engine = engine; self.config = config; self.client = client; self.sentences = sentences.map { (text: $0.0, lang: $0.1) }
    }

    static func start(sentences: [(String, String)]) async throws -> EngineTTSLoad {
        let paths = EnginePaths.standard()
        let installation = EngineInstallation(engineHome: paths.engineHome())
        let (state, record) = installation.check()
        guard state.canStartEngine, let record, let source = paths.engineSource, !sentences.isEmpty else {
            throw EngineAPIError.badResponse("engine not startable: \(state)")
        }
        let warm = installation.warmupDir
        guard let data = try? Data(contentsOf: warm.appendingPathComponent("ref-zh.wav")),
              let wav = WAVFile.decodePCM16(data), wav.sampleRate == 24000,
              let refText = (try? String(contentsOf: warm.appendingPathComponent("ref-zh.txt"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw EngineAPIError.badResponse("warmup reference missing")
        }
        let config = EngineConfig.installed(record: record, installation: installation, paths: paths, source: source,
                                            roles: ["tts"], policy: try? PolicyProfile.loadDefault())
        let engine = EngineProcess(config: config)
        _ = try await engine.start()
        guard let c = await engine.client else { throw EngineAPIError.invalidated }
        let blob = try await c.buildVoice(reference24k: wav.samples, refText: refText, model: config.tts).blob
        try await c.loadVoice(blob: blob, model: config.tts)
        let until = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < until {
            if let h = try? await c.health(timeout: 2), h.voice.state == "ready" { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return EngineTTSLoad(engine: engine, config: config, client: c, sentences: sentences)
    }

    func setActive(_ on: Bool) async {
        active = on
        if on {
            if loop == nil { loop = Task { await self.run() } }
        } else if let l = loop {
            await l.value   // the clause in flight finishes: the idle half is really idle
            loop = nil
        }
    }

    private func run() async {
        while active, !Task.isCancelled {
            let s = sentences[next % sentences.count]
            next += 1
            do {
                let r = try await client.tts(EngineTTSRequest(text: s.text, lang: s.lang, seed: next)).collect()
                if r.failure == nil { clauses += 1 } else { errors += 1 }
                audioS += r.audioSeconds
                busyS += r.totalMs / 1000
            } catch {
                errors += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func summary() async -> [String: Double] {
        ["clauses": Double(clauses), "errors": Double(errors), "audio_s": audioS.rounded(), "busy_s": busyS.rounded(),
         "rtf": audioS > 0 ? (busyS / audioS * 1000).rounded() / 1000 : 0]
    }

    nonisolated func describe() -> [String: Any] {
        ["profile": config.profile, "roles": config.roles, "horizon_ms": config.horizonMs]
    }

    func stop() async {
        await setActive(false)
        await engine.stop()
    }
}
#endif
