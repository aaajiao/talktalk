import Darwin
import Foundation
import TalkTalkCore
import TalkTalkEngineHost
import TalkTalkVoice

// m1-engine: `--bench engine-restart [--iterations 3] --out <file>` (dev build). Measures how
// long the real engine takes to come back after `kill -9` (§14 T13 / M1: TTS ready ≤4 s, all
// ready ≤8 s, 估). Uses only the synthetic warmup reference, never "my voice". No TCC, so it
// can run from a terminal. GPU: tell the other sessions before running it.
//
// Each iteration uses a fresh EngineProcess (so the 3-crashes-in-2-minutes guard never trips):
// start → ASR ready → voice built and loaded → one warm TTS clause → kill -9 → time to
//   detected   EngineProcess reports .restarting
//   ready      READY again (TTS model loaded)
//   asr        /v1/health says the ASR model is ready
//   voice      the cached conditioning blob is loaded again (what the app does after a restart)
//   tts        first audible sample of a short clause
// The numbers go to --out; audio is never written.

@MainActor func runBenchEngineRestart() -> Never {
    #if TALKTALK_DEV
    let iterations = max(1, Int(argumentValue("--iterations") ?? "") ?? 3)
    let out = argumentValue("--out")
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: [String: Any] = [:]
    Task.detached {
        result = await benchEngineRestart(iterations: iterations)
        done.signal()
    }
    done.wait()
    writeResult(result, to: out)
    exit(result["ok"] as? Bool == true ? 0 : 1)
    #else
    fail("--bench engine-restart exists only in the dev build")
    #endif
}

#if TALKTALK_DEV
private func ms(_ d: Duration) -> Double { (Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) * 1000 }

private func waitHealth(_ engine: EngineProcess, timeout: Duration, _ cond: (EngineHealth) -> Bool) async -> Bool {
    let end = ContinuousClock.now + timeout
    while ContinuousClock.now < end {
        if let c = await engine.client, let h = try? await c.health(timeout: 2), cond(h) { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return false
}

private func benchEngineRestart(iterations: Int) async -> [String: Any] {
    let paths = EnginePaths.standard()
    let installation = EngineInstallation(engineHome: paths.engineHome())
    let (state, record) = installation.check()
    guard state.canStartEngine, let record, let source = paths.engineSource else {
        return ["ok": false, "error": "engine not startable: \(state)"]
    }
    let warm = installation.warmupDir
    guard let data = try? Data(contentsOf: warm.appendingPathComponent("ref-zh.wav")),
          let wav = WAVFile.decodePCM16(data), wav.sampleRate == 24000,
          let refText = (try? String(contentsOf: warm.appendingPathComponent("ref-zh.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
        return ["ok": false, "error": "warmup reference missing"]
    }
    let config = EngineConfig.installed(record: record, installation: installation, paths: paths, source: source,
                                     policy: try? PolicyProfile.loadDefault())
    let hasASR = config.roles.contains("asr")
    var runs: [[String: Double]] = []
    var errors: [String] = []

    for i in 0..<iterations {
        let engine = EngineProcess(config: config)
        do {
            let coldStart = ContinuousClock.now
            _ = try await engine.start()
            let cold = ms(ContinuousClock.now - coldStart)
            if hasASR, !(await waitHealth(engine, timeout: .seconds(180)) { $0.models["asr"]?.state == "ready" }) {
                throw EngineAPIError.badResponse("ASR not ready after cold start")
            }
            guard let c0 = await engine.client else { throw EngineAPIError.invalidated }
            let blob = try await c0.buildVoice(reference24k: wav.samples, refText: refText, model: config.tts).blob
            try await c0.loadVoice(blob: blob, model: config.tts)
            guard await waitHealth(engine, timeout: .seconds(60), { $0.voice.state == "ready" }) else {
                throw EngineAPIError.badResponse("voice not ready")
            }
            _ = try await c0.tts(EngineTTSRequest(text: "Good morning, everyone.", lang: "en", seed: 0)).collect()
            guard let pid = await engine.pid else { throw EngineAPIError.invalidated }

            let updates = await engine.statusUpdates()
            let killed = ContinuousClock.now
            kill(pid, SIGKILL)
            var detected: Double?
            var ready: Double?
            for await s in updates {
                switch s {
                case .restarting where detected == nil: detected = ms(ContinuousClock.now - killed)
                case .ready(let r) where r.pid != pid: ready = ms(ContinuousClock.now - killed)
                case .failed(let f): throw f
                default: break
                }
                if ready != nil { break }
            }
            var asr = ready
            if hasASR {
                guard await waitHealth(engine, timeout: .seconds(60), { $0.models["asr"]?.state == "ready" }) else {
                    throw EngineAPIError.badResponse("ASR not ready after restart")
                }
                asr = ms(ContinuousClock.now - killed)
            }
            guard let c1 = await engine.client else { throw EngineAPIError.invalidated }
            try await c1.loadVoice(blob: blob, model: config.tts)
            guard await waitHealth(engine, timeout: .seconds(60), { $0.voice.state == "ready" }) else {
                throw EngineAPIError.badResponse("voice not ready after restart")
            }
            let voice = ms(ContinuousClock.now - killed)
            let ttsStart = ContinuousClock.now
            let r = try await c1.tts(EngineTTSRequest(text: "Good morning, everyone.", lang: "en", seed: 0)).collect(started: ttsStart)
            let tts = voice + (r.firstAudibleMs ?? r.totalMs)
            var row: [String: Double] = ["cold_start_ms": cold.rounded(), "ready_ms": (ready ?? -1).rounded(),
                                         "asr_ms": (asr ?? -1).rounded(), "voice_ms": voice.rounded(),
                                         "tts_audible_ms": tts.rounded(), "all_ready_ms": max(asr ?? 0, voice).rounded()]
            if let detected { row["detected_ms"] = detected.rounded() }
            runs.append(row)
        } catch {
            errors.append("iteration \(i + 1): \(error)")
        }
        await engine.stop()
    }

    func stat(_ key: String) -> [String: Double] {
        let v = runs.compactMap { $0[key] }.sorted()
        guard !v.isEmpty else { return [:] }
        return ["min": v.first!, "median": v[v.count / 2], "max": v.last!]
    }
    let ttsMax = runs.compactMap { $0["tts_audible_ms"] }.max() ?? .infinity
    let allMax = runs.compactMap { $0["all_ready_ms"] }.max() ?? .infinity
    return ["ok": errors.isEmpty && !runs.isEmpty, "iterations": iterations, "runs": runs, "errors": errors,
            "profile": record.profile, "roles": config.roles,
            "summary": ["ready_ms": stat("ready_ms"), "asr_ms": stat("asr_ms"), "voice_ms": stat("voice_ms"),
                        "tts_audible_ms": stat("tts_audible_ms"), "all_ready_ms": stat("all_ready_ms"),
                        "detected_ms": stat("detected_ms")],
            "targets": ["tts_ready_ms": 4000, "all_ready_ms": 8000],
            "pass": ["tts_ready": ttsMax <= 4000, "all_ready": allMax <= 8000]]
}
#endif
