import Foundation
import Synchronization
import Testing
import TalkTalkTestSupport
@testable import TalkTalkCore
@testable import TalkTalkEngineHost

private final class ReadinessFallbackASR: StreamingASREngine, ASRStream, Sendable {
    let id = EngineID(name: "readiness-apple-asr", revision: "1", placement: .cpu)
    let opens = Mutex(0)
    let volatileEvents: AsyncStream<ASREvent>
    let finalEvents: AsyncStream<ASREvent>
    private let volatile: AsyncStream<ASREvent>.Continuation
    private let final: AsyncStream<ASREvent>.Continuation
    init() {
        (volatileEvents, volatile) = AsyncStream.makeStream()
        (finalEvents, final) = AsyncStream.makeStream()
    }
    func open(_ lang: Lang, highPriority: Bool) async throws -> any ASRStream {
        opens.withLock { $0 += 1 }
        return self
    }
    func feed(_ frames: UnsafeBufferPointer<Int16>, at: HostTime) {}
    func finalize(through: HostTime) async {}
    func close() async { volatile.finish(); final.finish() }
}

/// Real host/client against a stdlib-only child. Files release warmup explicitly: no GPU,
/// models, network service, or timing-dependent assumption that TTS has finished loading.
@Suite(.serialized, .temporaryFiles) struct EngineTTSReadinessTests {
    private struct WireCall: Decodable {
        let method: String
        let path: String
        let pid: Int32
        let tts_state: String?
        let request: TTSBody?
    }

    private struct TTSBody: Decodable {
        let text: String
        let lang: String
        let job: String
        let seed: Int?
        let whole_clause: Bool?
        let voice_key: String?
        let context_id: String?
        let previous_job: String?
    }

    private func calls(_ box: EngineHostTests.Sandbox) -> [WireCall] {
        box.file("requests.jsonl").split(separator: "\n").compactMap {
            try? JSONDecoder().decode(WireCall.self, from: Data($0.utf8))
        }
    }

    private func argv(_ box: EngineHostTests.Sandbox, launch: Int) throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(box.file("argv-\(launch).json").utf8))
    }

    private func signal(_ box: EngineHostTests.Sandbox, _ name: String) throws {
        try Data().write(to: box.state.appendingPathComponent(name), options: .atomic)
    }

    private func wait(_ condition: () async -> Bool, timeout: Duration = .seconds(3)) async throws {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await condition())
    }

    private func loadingConfig(_ box: EngineHostTests.Sandbox, extra: [String] = []) throws -> EngineConfig {
        try box.config(extra: ["--tts-loading", "--initial-voice-ready", "--tts-chunks", "1", "--tts-chunk-ms", "1"] + extra)
    }

    @Test(arguments: [false, true])
    func coldStartOwnsTheFlagAndReadyCallsNeverRestart(prioritize: Bool) async throws {
        let box = try EngineHostTests.Sandbox(), engine = EngineProcess(config: try box.config())
        defer { Task { await engine.stop() } }
        let first = try await engine.start(prioritizingASR: prioritize)
        let same = try await engine.start(prioritizingASR: !prioritize)
        #expect(first.pid == same.pid && box.launches.count == 1)
        #expect(try argv(box, launch: 1).contains("--asr-first") == prioritize)
        #expect(await !engine.config.arguments.contains("--asr-first"))
        await engine.stop()
    }

    @Test(arguments: [false, true])
    func anotherWaiterCannotChangeAnInFlightLaunch(firstPrioritizesASR: Bool) async throws {
        let box = try EngineHostTests.Sandbox()
        let engine = EngineProcess(config: try box.config(extra: ["--ready-delay", "0.2"]))
        defer { Task { await engine.stop() } }
        let first = Task { try await engine.start(prioritizingASR: firstPrioritizesASR) }
        defer { first.cancel() }
        try await EngineHostTests.waitFor(engine) { if case .starting = $0 { true } else { false } }
        let second = try await engine.start(prioritizingASR: !firstPrioritizesASR)
        #expect(try await first.value.pid == second.pid)
        #expect(try argv(box, launch: 1).contains("--asr-first") == firstPrioritizesASR)
        #expect(box.launches.count == 1)
        await engine.stop()
    }

    @Test func automaticRestartKeepsTheLaunchIntentButANewDefaultStartDoesNot() async throws {
        let box = try EngineHostTests.Sandbox()
        let engine = EngineProcess(config: try box.config("controlled-crash"))
        defer { Task { await engine.stop() } }
        let first = try await engine.start(prioritizingASR: true)
        try signal(box, "crash_now")
        _ = try await EngineHostTests.waitFor(engine) {
            if case let .ready(info) = $0 { info.pid != first.pid } else { false }
        }
        #expect(box.launches.count == 2)
        #expect(try argv(box, launch: 2).contains("--asr-first"))
        await engine.stop()
        _ = try await engine.start()
        #expect(box.launches.count == 3)
        #expect(try !argv(box, launch: 3).contains("--asr-first"))
        await engine.stop()
    }

    @Test func ASRCanRunWhileTTSReadinessWaitsOnTheSameProcess() async throws {
        let box = try EngineHostTests.Sandbox(), engine = EngineProcess(config: try loadingConfig(box))
        defer { Task { await engine.stop() } }
        let ready = try await engine.start(prioritizingASR: true)
        #expect(ready.models["asr"]?.state == "ready" && ready.models["tts"]?.state == "loading")
        let completed = Mutex(false)
        let waiter = Task {
            defer { completed.withLock { $0 = true } }
            return try await engine.readyTTSClient()
        }
        defer { waiter.cancel() }
        try await wait { calls(box).contains { $0.path == "/v1/health" } }
        let asr = try await RemoteQwenASR(engine: engine).transcribe([Float](repeating: 0, count: 1600),
                                                                  hint: "de", priority: 2, job: "asr-during-warmup")
        #expect(asr.language == "de" && asr.text == "今天十点开会")
        #expect(!completed.withLock { $0 })
        #expect(box.launches.count == 1)
        try signal(box, "tts_ready")
        let client = try await waiter.value
        #expect(try await client.health().pid == ready.pid)
        let identity = try await engine.readyTTSInfo()
        #expect(identity.pid == ready.pid && identity.models["tts"]?.id == "tts-x")
        #expect(identity.models["tts"]?.state == "ready")
        await engine.stop()
    }

    @Test(arguments: [false, true])
    func streamingASRWaitsThroughLoadingAndOpensFallbackOnlyOnFailure(fail: Bool) async throws {
        let box = try EngineHostTests.Sandbox()
        let engine = EngineProcess(config: try loadingConfig(box, extra: ["--asr-loading"]))
        defer { Task { await engine.stop() } }
        _ = try await engine.start(prioritizingASR: true)
        let fallback = ReadinessFallbackASR(), completed = Mutex(false), selected = Mutex<[String]>([])
        let asr = QwenStreamingASR(engine: engine, fallback: fallback,
                                  onEngine: { id in selected.withLock { $0.append(id.name) } })
        let opening = Task {
            defer { completed.withLock { $0 = true } }
            return try await asr.open(.de, highPriority: false)
        }
        defer { opening.cancel() }
        try await wait { calls(box).contains { $0.path == "/v1/health" } }
        #expect(!completed.withLock { $0 } && fallback.opens.withLock { $0 } == 0)
        try signal(box, fail ? "asr_failed" : "asr_ready")
        try await wait { completed.withLock { $0 } }
        let stream = try await opening.value
        #expect(fallback.opens.withLock { $0 } == (fail ? 1 : 0))
        #expect(selected.withLock { $0 } == [fail ? fallback.id.name : "asr-y"])
        #expect(calls(box).allSatisfy { $0.path != "/v1/tts" && !$0.path.hasPrefix("/v1/voice/") })
        await stream.cancel()
        await engine.stop()
    }

    @Test(arguments: [false, true])
    func missingOrUnstartableQwenReportsAppleAsTheActualEngine(missing: Bool) async throws {
        let box = try EngineHostTests.Sandbox()
        let engine = missing ? nil : EngineProcess(config: try box.config("fatal"))
        let fallback = ReadinessFallbackASR(), selected = Mutex<[String]>([])
        let asr = QwenStreamingASR(engine: engine, fallback: fallback,
                                  onEngine: { id in selected.withLock { $0.append(id.name) } })
        let stream = try await asr.open(.en, highPriority: false)
        #expect(fallback.opens.withLock { $0 } == 1)
        #expect(selected.withLock { $0 } == [fallback.id.name])
        #expect(calls(box).allSatisfy { $0.path != "/v1/asr" })
        await stream.cancel()
        await engine?.stop()
    }

    @Test(arguments: ["build", "load", "simpleSpeak"])
    func everyTTSConvenienceEntryWaitsBeforeSendingAnHTTPJob(entry: String) async throws {
        let box = try EngineHostTests.Sandbox(), engine = EngineProcess(config: try loadingConfig(box))
        defer { Task { await engine.stop() } }
        _ = try await engine.start(prioritizingASR: true)
        let tts = RemoteQwenTTS(engine: engine), completed = Mutex(false)
        let operation = Task {
            defer { completed.withLock { $0 = true } }
            switch entry {
            case "build":
                _ = try await tts.buildConditioning(.init(pcm24k: Data(repeating: 0, count: 9600), text: "参考。", lang: .zh),
                                                    model: RemoteQwenCoreTests.handle().model, mode: .icl)
            case "load":
                try await tts.load(RemoteQwenCoreTests.handle(), blob: Data([1, 2, 3]))
            default:
                _ = try await tts.speak("The simple API waits too.", lang: "en", job: "simple-readiness", seed: 7).collect()
            }
        }
        defer { operation.cancel() }
        try await wait { calls(box).contains { $0.path == "/v1/health" } }
        #expect(!completed.withLock { $0 })
        #expect(calls(box).allSatisfy { $0.method != "POST" })
        try signal(box, "tts_ready")
        try await operation.value
        let expected = entry == "build" ? "/v1/voice/build" : entry == "load" ? "/v1/voice/load" : "/v1/tts"
        let sent = calls(box).filter { $0.path == expected }
        #expect(sent.count == 1 && sent[0].tts_state == "ready")
        await engine.stop()
    }

    @Test func warmupWaitingIsNotATTSWireStallAndDoesNotChangeSynthesisParameters() async throws {
        let box = try EngineHostTests.Sandbox(), engine = EngineProcess(config: try loadingConfig(box))
        defer { Task { await engine.stop() } }
        _ = try await engine.start(prioritizingASR: true)
        var limits = TTSStall.Config()
        limits.stallAfter = .milliseconds(100)
        limits.hangAfter = .seconds(2)
        limits.tick = .milliseconds(10)
        let tts = RemoteQwenTTS(engine: engine, stall: limits), completed = Mutex(false)
        let request = TTSRequest(job: 91, clause: 4, text: "The exact synthesis request stays unchanged.", language: .de,
                                 voice: RemoteQwenCoreTests.handle(), seed: 12345, wholeClause: true,
                                 contextID: "same-turn", previousJob: 90)
        let synthesis = Task {
            defer { completed.withLock { $0 = true } }
            var chunks: [TTSChunk] = []
            for try await chunk in tts.speak(request) { chunks.append(chunk) }
            return chunks
        }
        defer { synthesis.cancel() }
        try await wait { calls(box).contains { $0.path == "/v1/health" } }
        // Deliberately exceed the wire-stall threshold while no wire job exists yet.
        try await Task.sleep(for: .milliseconds(350))
        #expect(!completed.withLock { $0 })
        #expect(calls(box).allSatisfy { $0.path != "/v1/tts" && $0.path != "/v1/cancel" })
        try signal(box, "tts_ready")
        let chunks = try await synthesis.value
        #expect(chunks.last?.isLast == true && chunks.first?.samples24k.count == 1920)
        let wire = try #require(calls(box).first { $0.path == "/v1/tts" }?.request)
        #expect(wire.text == request.text && wire.lang == "de" && wire.job == "tts-91")
        #expect(wire.seed == 12345 && wire.whole_clause == true && wire.voice_key == "k")
        #expect(wire.context_id == "same-turn" && wire.previous_job == "tts-90")
        #expect(box.launches.count == 1)
        await engine.stop()
    }

    @Test(arguments: ["failed", "absent", "timeout"])
    func unavailableTTSHasAnExplicitFailureAndNeverSendsVoiceWork(kind: String) async throws {
        let box = try EngineHostTests.Sandbox()
        var config = try loadingConfig(box)
        config.timing.readyTimeout = .seconds(2)
        if kind == "absent" { config.roles = ["asr"]; config.tts = nil }
        if kind == "failed" { try signal(box, "tts_failed") }
        let engine = EngineProcess(config: config)
        defer { Task { await engine.stop() } }
        _ = try await engine.start(prioritizingASR: true)
        let code = kind == "failed" ? "tts_warmup_failed" : kind == "absent" ? "tts_not_loaded" : "tts_not_ready"
        if kind == "timeout" {
            // The launch-wide fuse may invalidate this client before the caller's wait ends.
            do { _ = try await engine.readyTTSClient(); Issue.record("unready TTS unexpectedly accepted") }
            catch { }
        } else {
            await #expect(throws: RemoteEngineError.tts(code: code, message: "")) {
                try await engine.readyTTSClient()
            }
        }
        #expect(calls(box).allSatisfy { $0.method != "POST" })
        await engine.stop()
    }

    @Test func recognitionOnlyInstallationDoesNotStartForAnAccidentalVoiceRequest() async throws {
        let box = try EngineHostTests.Sandbox()
        var config = try box.config()
        config.roles = ["asr"]; config.tts = nil
        let engine = EngineProcess(config: config)
        await #expect(throws: RemoteEngineError.tts(code: "tts_not_loaded", message: "")) {
            try await engine.readyTTSClient()
        }
        #expect(box.launches.isEmpty)
        #expect(await engine.status == .stopped)

        // The same installation remains usable by the listening path.
        let ready = try await engine.start(prioritizingASR: true)
        #expect(ready.models["asr"]?.state == "ready" && ready.models["tts"] == nil)
        let result = try await RemoteQwenASR(engine: engine).transcribe([Float](repeating: 0, count: 1600),
                                                                      hint: "en", priority: 2, job: "recognition-only")
        #expect(result.text == "今天十点开会")
        #expect(calls(box).allSatisfy { $0.path != "/v1/tts" && !$0.path.hasPrefix("/v1/voice/") })
        await engine.stop()
    }

    @Test func cancellingAReadinessWaitDoesNotCancelTheEngineOrSubmitLateVoiceWork() async throws {
        let box = try EngineHostTests.Sandbox(), engine = EngineProcess(config: try loadingConfig(box))
        defer { Task { await engine.stop() } }
        let initial = try await engine.start(prioritizingASR: true)
        let completed = Mutex(false)
        let building = Task {
            defer { completed.withLock { $0 = true } }
            return try await RemoteQwenTTS(engine: engine).buildConditioning(
                .init(pcm24k: Data(repeating: 0, count: 9600), text: "参考。", lang: .zh),
                model: RemoteQwenCoreTests.handle().model, mode: .icl)
        }
        defer { building.cancel() }
        try await wait { calls(box).contains { $0.path == "/v1/health" } }
        building.cancel()
        try await wait({ completed.withLock { $0 } }, timeout: .seconds(1))
        await #expect(throws: CancellationError.self) { try await building.value }
        try signal(box, "tts_ready")
        _ = try await engine.readyTTSClient()
        #expect(await engine.pid == initial.pid && box.launches.count == 1)
        #expect(calls(box).allSatisfy { $0.path != "/v1/voice/build" })
        await engine.stop()
    }

    @Test func restartCannotMoveAnOldReadinessWaitOntoTheNewClient() async throws {
        let box = try EngineHostTests.Sandbox(), engine = EngineProcess(config: try loadingConfig(box))
        defer { Task { await engine.stop() } }
        let first = try await engine.start(prioritizingASR: true)
        let completed = Mutex(false)
        let building = Task {
            defer { completed.withLock { $0 = true } }
            return try await RemoteQwenTTS(engine: engine).buildConditioning(
                .init(pcm24k: Data(repeating: 0, count: 9600), text: "Old reference.", lang: .en),
                model: RemoteQwenCoreTests.handle().model, mode: .icl)
        }
        defer { building.cancel() }
        try await wait { calls(box).contains { $0.path == "/v1/health" } }
        await engine.stop()
        try signal(box, "tts_ready")
        let second = try await engine.start()
        try await wait { completed.withLock { $0 } }
        await #expect(throws: EngineAPIError.invalidated) { try await building.value }
        #expect(first.pid != second.pid && box.launches.count == 2)
        #expect(calls(box).allSatisfy { $0.path != "/v1/voice/build" })
        _ = try await RemoteQwenTTS(engine: engine).buildConditioning(
            .init(pcm24k: Data(repeating: 0, count: 9600), text: "New reference.", lang: .en),
            model: RemoteQwenCoreTests.handle().model, mode: .icl)
        let sent = calls(box).filter { $0.path == "/v1/voice/build" }
        #expect(sent.count == 1 && sent[0].pid == second.pid)
        await engine.stop()
    }

    @Test(arguments: [false, true])
    func preparationDeadlineRecoversWithoutCallersAndIncludesTimeBeforeREADY(healthHangs: Bool) async throws {
        let box = try EngineHostTests.Sandbox()
        var config = try loadingConfig(box, extra: ["--long-step", "--ready-delay", "0.6"])
        config.timing.readyTimeout = .milliseconds(1600)
        config.timing.healthTimeout = .milliseconds(100)
        let engine = EngineProcess(config: config)
        defer { Task { await engine.stop() } }
        let first = try await engine.start(prioritizingASR: true)
        let becameReady = ContinuousClock.now
        if healthHangs { try signal(box, "health_hang") }
        // No meeting monitor and no TTS waiter: the process itself owns this deadline.
        let status = try await EngineHostTests.waitFor(engine, timeout: .seconds(3)) {
            if case .restarting = $0 { true } else { false }
        }
        guard case let .restarting(_, _, reason) = status else { return }
        #expect(reason.contains("TTS preparation exceeded"))
        #expect(ContinuousClock.now - becameReady < .milliseconds(1450))
        if healthHangs { try FileManager.default.removeItem(at: box.state.appendingPathComponent("health_hang")) }
        try signal(box, "tts_ready")
        _ = try await EngineHostTests.waitFor(engine) {
            if case let .ready(info) = $0 { info.pid != first.pid } else { false }
        }
        _ = try await engine.readyTTSClient()
        #expect(box.launches.count == 2)
        #expect(calls(box).allSatisfy { $0.method != "POST" })
        await engine.stop()
    }

    @Test(arguments: ["ready", "failed"])
    func observedTerminalPreparationCancelsTheFuseBeforeLaterHealthFailure(state: String) async throws {
        let box = try EngineHostTests.Sandbox()
        var config = try loadingConfig(box)
        config.timing.readyTimeout = .milliseconds(700)
        config.timing.healthTimeout = .milliseconds(100)
        let engine = EngineProcess(config: config)
        defer { Task { await engine.stop() } }
        let first = try await engine.start(prioritizingASR: true)
        try signal(box, "tts_" + state)
        if state == "ready" { _ = try await engine.readyTTSClient() }
        else {
            await #expect(throws: RemoteEngineError.tts(code: "tts_warmup_failed", message: "")) {
                try await engine.readyTTSClient()
            }
        }
        try signal(box, "health_hang")
        // Beyond the original deadline plus its final health allowance: a completed warmup
        // must not acquire a permanent new watchdog for later transient HTTP failures.
        try await Task.sleep(for: .milliseconds(950))
        #expect(await engine.pid == first.pid && box.launches.count == 1)
        #expect(EngineHostTests.isReady(await engine.status))
        await engine.stop()
    }

    @Test func oldPreparationDeadlineHealthWaitCannotKillAReplacementProcess() async throws {
        let box = try EngineHostTests.Sandbox()
        var config = try loadingConfig(box)
        config.timing.readyTimeout = .milliseconds(600)
        config.timing.healthTimeout = .seconds(1)
        let engine = EngineProcess(config: config)
        defer { Task { await engine.stop() } }
        let first = try await engine.start(prioritizingASR: true)
        try signal(box, "health_hang")
        // The old deadline is inside its health await when stop replaces the generation.
        try await wait { calls(box).contains { $0.path == "/v1/health" && $0.pid == first.pid } }
        await engine.stop()
        try FileManager.default.removeItem(at: box.state.appendingPathComponent("health_hang"))
        try signal(box, "tts_ready")
        let replacement = try await engine.start()
        _ = try await engine.readyTTSClient()
        try await Task.sleep(for: .milliseconds(1200))
        #expect(replacement.pid != first.pid)
        #expect(await engine.pid == replacement.pid && box.launches.count == 2)
        #expect(EngineHostTests.isReady(await engine.status))
        await engine.stop()
    }
}
