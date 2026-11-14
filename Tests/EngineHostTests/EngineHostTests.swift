import Darwin
import Foundation
import Testing
import TalkTalkTestSupport
@testable import TalkTalkCore
@testable import TalkTalkEngineHost

/// EngineHostTests (§13): the real EngineProcess / PosixSpawnLauncher / EngineClient against a
/// stdlib-only fake engine (`Fixtures/fake_engine/talktalk_engine.py`) that speaks the real
/// handshake and API v2 with scripted misbehaviour. Needs 127.0.0.1 binding (run outside the
/// Claude Code sandbox). No MLX, no models, no GPU.
@Suite(.serialized, .temporaryFiles) struct EngineHostTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fake_engine")
    static let ttsRev = String(repeating: "a", count: 40)
    static let ttsOldRev = String(repeating: "b", count: 40)
    static let asrRev = String(repeating: "c", count: 40)

    /// The real interpreter behind `/usr/bin/python3`. That path is an `xcrun` shim which adds
    /// SDKROOT, CPATH, LIBRARY_PATH and MANPATH to the child's environment; the product launches
    /// `engine/venv/bin/python3` directly, so the tests must too for the environment check to be exact.
    static let python: URL = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", "-c", "import sys; print(sys.executable)"]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path.isEmpty ? "/usr/bin/python3" : path)
    }()

    /// A throwaway TalkTalk home/logs/caches plus the fake engine's state dir.
    final class Sandbox: @unchecked Sendable {
        let root: URL
        let paths: EnginePaths
        let state: URL

        init() throws {
            root = try TestTemporaryDirectory.make(prefix: "tt-host")
            paths = EnginePaths(home: root.appendingPathComponent("home"), logs: root.appendingPathComponent("logs"),
                                caches: root.appendingPathComponent("caches"), engineSource: EngineHostTests.fixture,
                                installerScript: nil)
            state = root.appendingPathComponent("state")
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        }

        func record(ttsRev: String = EngineHostTests.ttsRev) throws -> EngineInstallation.Record {
            let json = """
            {"version":1,"profile":"max","engine_api":2,"runtime":"python-mlx","flavour":"main","lock_sha256":"x",
             "roles":{"tts":{"id":"tts-x","rev":"\(ttsRev)"},"asr":{"id":"asr-y","rev":"\(EngineHostTests.asrRev)"}},
             "models":[]}
            """
            return try JSONDecoder().decode(EngineInstallation.Record.self, from: Data(json.utf8))
        }

        func config(_ scenario: String = "ok", extra: [String] = [], recordRev: String = EngineHostTests.ttsRev,
                    timing: ((inout EngineConfig.Timing) -> Void)? = nil) throws -> EngineConfig {
            var t = EngineConfig.Timing()
            t.readyTimeout = .seconds(10)
            t.healthInterval = .milliseconds(150)
            t.healthTimeout = .milliseconds(400)
            t.termGrace = .milliseconds(500)
            t.backoff = [.zero, .milliseconds(200), .milliseconds(200)]
            timing?(&t)
            return EngineConfig(python: EngineHostTests.python, source: EngineHostTests.fixture,
                                modelsDirs: [root.appendingPathComponent("models")], warmupDir: nil, profile: "max",
                                roles: ["tts", "asr"], tts: "tts-x", asr: "asr-y", record: try record(ttsRev: recordRev),
                                paths: paths, extraArguments: ["--scenario", scenario, "--state-dir", state.path] + extra,
                                timing: t)
        }

        var launches: [Int32] {
            let s = (try? String(contentsOf: state.appendingPathComponent("launches.txt"), encoding: .utf8)) ?? ""
            return s.split(separator: "\n").compactMap { Int32($0) }
        }

        func file(_ name: String) -> String {
            (try? String(contentsOf: state.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
    }

    static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    /// Waits until the engine reports a status matching `predicate`.
    @discardableResult
    static func waitFor(_ engine: EngineProcess, timeout: Duration = .seconds(10),
                        _ predicate: @escaping @Sendable (EngineStatus) -> Bool) async throws -> EngineStatus {
        try await withThrowingTaskGroup(of: EngineStatus?.self) { group in
            group.addTask {
                for await s in await engine.statusUpdates() where predicate(s) { return s }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            guard let s = first else {
                throw TimeoutError(last: await engine.status)
            }
            return s
        }
    }

    struct TimeoutError: Error, CustomStringConvertible {
        let last: EngineStatus
        var description: String { "timed out; last status \(last)" }
    }

    static func isReady(_ s: EngineStatus) -> Bool { if case .ready = s { true } else { false } }
    static func isFailed(_ s: EngineStatus) -> Bool { if case .failed = s { true } else { false } }

    // MARK: handshake and READY

    @Test func speakerSimilaritySendsTwoClipsAndMapsErrors() async throws {
        let sb = try Sandbox()
        let engine = EngineProcess(config: try sb.config())
        _ = try await engine.start()
        let client = try #require(await engine.client)
        let ref = (0..<24_000).map { Float(sin(Double($0) * 0.05)) * 0.1 }
        #expect(try await client.speakerSimilarity(reference24k: ref, sample24k: ref) == 1.0)
        #expect(try await client.speakerSimilarity(reference24k: ref, sample24k: ref.map { $0 * 0.5 }) == 0.5)
        do {
            _ = try await client.speakerSimilarity(reference24k: ref, sample24k: Array(ref.prefix(6_000)))
            Issue.record("expected audio_too_short")
        } catch let e as EngineAPIError {
            #expect(e.code == "audio_too_short")
        }
        await engine.stop()
    }

    @Test func readyWithoutVoiceThenLoadAndStream() async throws {
        let sb = try Sandbox()
        let engine = EngineProcess(config: try sb.config())
        let ready = try await engine.start()
        #expect(ready.voice.state == "absent")
        #expect(ready.api == 2)
        let client = try #require(await engine.client)
        let h = try await client.health()
        #expect(h.voice.state == "absent")
        #expect(h.gpu.stepP99?["tts.first"] == 88.5)
        // TTS without a voice: 409 voice_absent (READY does not wait for "my voice", §4.4).
        do {
            for try await _ in client.tts(EngineTTSRequest(text: "Hello there", lang: "en")).events {}
            Issue.record("expected voice_absent")
        } catch let e as EngineAPIError {
            #expect(e.code == "voice_absent")
        }
        let built = try await client.buildVoice(reference24k: [Float](repeating: 0.1, count: 24000), refText: "大家好", model: "tts-x")
        #expect(built.blob.count == 32)
        #expect(built.frames == 120)
        try await client.loadVoice(blob: built.blob, model: "tts-x", key: built.keyMaterial)
        #expect(try await client.health().voice.state == "ready")
        var heads = 0, samples = 0
        var tail: EngineTTSTail?
        for try await ev in client.tts(EngineTTSRequest(text: "Thanks, everyone.", lang: "en")).events {
            switch ev {
            case .head(let sr, _, let seq): heads += 1; #expect(sr == 24000); #expect(seq != nil)
            case .pcm(let p): samples += p.count; #expect(p.first == 0.25)
            case .tail(let t): tail = t
            default: Issue.record("unexpected \(ev)")
            }
        }
        #expect(heads == 1 && samples == 5 * 1920)
        #expect(tail?.audioS == 0.4)
        #expect(tail?.timing["total_ms"] == 100.0)
        let asr = try await client.asr(samples16k: [Float](repeating: 0, count: 16000), hint: "zh")
        #expect(asr.text == "今天十点开会" && asr.language == "zh")
        try await client.unloadVoice()
        #expect(try await client.health().voice.state == "absent")
        await engine.stop()
        #expect(await engine.status == .stopped)
        #expect(!Self.alive(ready.pid))
    }

    @Test func environmentIsRebuiltAndArgumentsAreIsolated() async throws {
        setenv("READREAD_TTS_SERVER_DIR", "/tmp/should-not-leak", 1)
        setenv("PYTHONPATH", "/tmp/should-not-leak", 1)
        defer { unsetenv("READREAD_TTS_SERVER_DIR"); unsetenv("PYTHONPATH") }
        let sb = try Sandbox()
        let engine = EngineProcess(config: try sb.config())
        try await engine.start()
        await engine.stop()
        let env = try JSONSerialization.jsonObject(with: Data(sb.file("env.json").utf8)) as? [String: String] ?? [:]
        let expected: Set = ["HOME", "LANG", "PATH", "TMPDIR", "TALKTALK_TOKEN", "TALKTALK_CACHE_DIR", "HF_HOME",
                             "HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_HUB_DISABLE_TELEMETRY",
                             "PYTHONDONTWRITEBYTECODE", "MLX_METAL_RESIDENCY_REFRESH_INTERVAL_MS"]
        // macOS may add __CF_USER_TEXT_ENCODING to a child's environment; nothing else may appear.
        #expect(Set(env.keys).subtracting(["__CF_USER_TEXT_ENCODING"]) == expected)
        #expect(env["TALKTALK_TOKEN"]?.count == 64)
        #expect(env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(env["HF_HUB_OFFLINE"] == "1")
        #expect(env["TMPDIR"] == sb.paths.engineTmp.path)
        let argv = try JSONSerialization.jsonObject(with: Data(sb.file("argv.json").utf8)) as? [String] ?? []
        #expect(argv.contains("--roles") && argv.contains("tts,asr"))
        #expect(argv.first?.hasSuffix("talktalk_engine.py") == true)
    }

    @Test func tokenIsFreshPerLaunch() {
        let a = EngineProcess.makeToken(), b = EngineProcess.makeToken()
        #expect(a.count == 64 && b.count == 64 && a != b)
        #expect(a.allSatisfy { $0.isHexDigit })
    }

    @Test func fatalBeforeReadyFailsWithoutRestart() async throws {
        let sb = try Sandbox()
        let engine = EngineProcess(config: try sb.config("fatal", extra: ["--bad-launches", "99"]))
        await #expect(throws: EngineFailure.self) { try await engine.start() }
        guard case .failed(.fatal(let m)) = await engine.status else { Issue.record("status"); return }
        #expect(m.contains("not found"))
        try await Task.sleep(for: .milliseconds(600))
        #expect(sb.launches.count == 1)
    }

    @Test func readyApiMismatchIsAProtocolError() async throws {
        let sb = try Sandbox()
        let engine = EngineProcess(config: try sb.config("api1", extra: ["--bad-launches", "99"]))
        await #expect(throws: EngineFailure.self) { try await engine.start() }
        guard case .failed(.readyMismatch(let list)) = await engine.status else { Issue.record("status"); return }
        #expect(list.contains { $0.hasPrefix("api:") })
        let pid = try #require(sb.launches.first)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!Self.alive(pid))
        #expect(sb.launches.count == 1)
    }

    @Test func readyRevisionMustEqualInstallJSON() async throws {
        let sb = try Sandbox()
        let engine = EngineProcess(config: try sb.config(extra: ["--rev-tts", Self.ttsOldRev]))
        await #expect(throws: EngineFailure.self) { try await engine.start() }
        guard case .failed(.readyMismatch(let list)) = await engine.status else { Issue.record("status"); return }
        #expect(list.contains { $0.hasPrefix("tts:") })
    }

    /// "上一版安装 + 新 app" (§7.4): the previous revision runs because READY is compared with
    /// install.json, not with the app's pins.
    @Test func previousInstallWithNewApp() async throws {
        let sb = try Sandbox()
        let engine = EngineProcess(config: try sb.config(extra: ["--rev-tts", Self.ttsOldRev], recordRev: Self.ttsOldRev))
        let r = try await engine.start()
        #expect(r.models["tts"]?.rev == Self.ttsOldRev)
        await engine.stop()
    }

    @Test func garbageOnTheHandshakeFdIsAProtocolError() async throws {
        let sb = try Sandbox()
        let engine = EngineProcess(config: try sb.config("garbage", extra: ["--bad-launches", "99"]))
        await #expect(throws: EngineFailure.self) { try await engine.start() }
        guard case .failed(.handshake) = await engine.status else { Issue.record("status"); return }
    }

    @Test func readyTimeoutKillsTheProcess() async throws {
        let sb = try Sandbox()
        let engine = EngineProcess(config: try sb.config("slow-ready", extra: ["--bad-launches", "99"]) {
            $0.readyTimeout = .seconds(1)
        })
        await #expect(throws: EngineFailure.timeout) { try await engine.start() }
        let pid = try #require(sb.launches.first)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!Self.alive(pid))
    }

    // MARK: crashes

    @Test func crashAfterReadyRestartsImmediately() async throws {
        let sb = try Sandbox()
        let engine = EngineProcess(config: try sb.config("crash-after-ready", extra: ["--bad-launches", "1"]))
        let first = try await engine.start()
        let restarting = try await Self.waitFor(engine) { if case .restarting = $0 { true } else { false } }
        guard case .restarting(let attempt, let delay, let reason) = restarting else { return }
        #expect(attempt == 1 && delay == .zero)
        #expect(reason.contains("exit 9"))
        let t0 = ContinuousClock.now
        let again = try await Self.waitFor(engine, Self.isReady)
        guard case .ready(let second) = again else { return }
        #expect(second.pid != first.pid)
        #expect(ContinuousClock.now - t0 < .seconds(3))
        #expect(sb.launches.count == 2)
        await engine.stop()
    }

    @Test func exitBeforeReadyCountsAsACrash() async throws {
        let sb = try Sandbox()
        let engine = EngineProcess(config: try sb.config("exit-before-ready", extra: ["--bad-launches", "1"]))
        let r = try await engine.start()   // the restart becomes READY; start() waits through it
        #expect(r.pid == sb.launches.last)
        #expect(sb.launches.count == 2)
        await engine.stop()
    }

    @Test func threeCrashesInTheWindowFail() async throws {
        let sb = try Sandbox()
        let engine = EngineProcess(config: try sb.config("crash-after-ready", extra: ["--bad-launches", "99", "--crash-after", "0.1"]))
        try await engine.start()
        let s = try await Self.waitFor(engine, Self.isFailed)
        guard case .failed(.crashedTooOften) = s else { Issue.record("\(s)"); return }
        try await Task.sleep(for: .milliseconds(500))
        #expect(sb.launches.count == 3)
        // The user's "重启引擎" clears the count.
        let again = try await Self.waitFor(engine, timeout: .seconds(1)) { _ in true }
        #expect(Self.isFailed(again))
        _ = try? await engine.userRestart()
        #expect(sb.launches.count == 4)
        await engine.stop()
    }

    // MARK: hang detection (meeting mode)

    @Test func healthTimeoutsMeanHungAndRestart() async throws {
        let sb = try Sandbox()
        let engine = EngineProcess(config: try sb.config("hang-health", extra: ["--bad-launches", "1"]))
        let first = try await engine.start()
        await engine.setMeetingMode(true)
        let s = try await Self.waitFor(engine) { if case .restarting = $0 { true } else { false } }
        guard case .restarting(_, _, let reason) = s else { return }
        #expect(reason.contains("hung"))
        let again = try await Self.waitFor(engine, Self.isReady)
        guard case .ready(let second) = again else { return }
        #expect(second.pid != first.pid && !Self.alive(first.pid))
        await engine.stop()
    }

    @Test func stalePendingStepMeansHung() async throws {
        let sb = try Sandbox()
        let engine = EngineProcess(config: try sb.config("step-age", extra: ["--bad-launches", "1"]))
        try await engine.start()
        await engine.setMeetingMode(true)
        let s = try await Self.waitFor(engine) { if case .restarting = $0 { true } else { false } }
        guard case .restarting(_, _, let reason) = s else { return }
        #expect(reason.contains("pending jobs"))
        await engine.stop()
    }

    @Test func inLongStepIsExempt() async throws {
        let sb = try Sandbox()
        let engine = EngineProcess(config: try sb.config("step-age", extra: ["--bad-launches", "1", "--long-step"]))
        let r = try await engine.start()
        await engine.setMeetingMode(true)
        try await Task.sleep(for: .seconds(1.5))
        #expect(await engine.status == .ready(r))
        #expect(await engine.lastHealth?.gpu.inLongStep == true)
        await engine.stop()
    }

    /// 00f65f3 re-review [low]: the horizon comes from the PolicyProfile (`speak.tts.renderHorizonMs`)
    /// and reaches the engine as --horizon-ms.
    @Test func installedConfigTakesTheHorizonFromThePolicy() throws {
        let box = try Sandbox()
        let base = try box.config()
        var policy = try PolicyProfile.loadDefault()
        policy.speak.tts.renderHorizonMs = 1234
        let inst = EngineInstallation(engineHome: box.state.appendingPathComponent("engine-home"))
        let c = EngineConfig.installed(record: base.record, installation: inst, paths: base.paths, source: base.source,
                                       policy: policy)
        #expect(c.horizonMs == 1234)
        #expect(c.arguments.firstIndex(of: "--horizon-ms").map { c.arguments[$0 + 1] } == "1234")
        let d = EngineConfig.installed(record: base.record, installation: inst, paths: base.paths, source: base.source)
        #expect(d.horizonMs == 1000)                                          // the T2 pick
        #expect(try PolicyProfile.loadDefault().speak.tts.renderHorizonMs == d.horizonMs)
    }

    @Test func recognitionOnlyRecordBuildsAnASROnlyLaunch() throws {
        let box = try Sandbox(), base = try box.config()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(base.record)) as? [String: Any])
        let roles = try #require(json["roles"] as? [String: Any])
        json["roles"] = roles.filter { $0.key == "asr" }
        json["profile"] = "custom"
        let selectedDirectory = "ASR-Y@\(Self.asrRev.prefix(12))"
        json["models"] = [
            ["id": "asr-y", "repo": "org/ASR-Y", "rev": String(repeating: "a", count: 40),
             "role": "asr", "dir": "ASR-Y@aaaaaaaaaaaa"],
            ["id": "asr-y", "repo": "org/ASR-Y", "rev": Self.asrRev,
             "role": "asr", "dir": selectedDirectory],
        ]
        let record = try JSONDecoder().decode(EngineInstallation.Record.self, from: JSONSerialization.data(withJSONObject: json))
        let installation = EngineInstallation(engineHome: box.state.appendingPathComponent("engine-home"))
        let config = EngineConfig.installed(record: record,
            installation: installation,
            paths: base.paths, source: base.source)
        #expect(config.roles == ["asr"] && config.asr == "asr-y" && config.tts == nil)
        #expect(config.arguments.firstIndex(of: "--roles").map { config.arguments[$0 + 1] } == "asr")
        #expect(!config.arguments.contains("--tts"))
        #expect(config.arguments.firstIndex(of: "--asr").map { config.arguments[$0 + 1] } == "asr-y")
        #expect(config.modelsDirs == [installation.modelsDir.appendingPathComponent(selectedDirectory)])
        #expect(!config.arguments.contains(installation.modelsDir.path))
    }

    @Test func hangRuleIsPure() {
        let g = { (age: Double?, pending: Int, long: Bool) in
            EngineHealth.GPU(lastStepAgeMs: age, inLongStep: long, queue: ["p0": pending])
        }
        #expect(EngineProcess.hangReason(g(5000, 1, false), limitMs: 4000) != nil)
        #expect(EngineProcess.hangReason(g(5000, 1, true), limitMs: 4000) == nil)
        #expect(EngineProcess.hangReason(g(5000, 0, false), limitMs: 4000) == nil)
        #expect(EngineProcess.hangReason(g(3000, 2, false), limitMs: 4000) == nil)
        #expect(EngineProcess.hangReason(g(nil, 2, false), limitMs: 4000) == nil)
        // 00f65f3 review [中]: TTS jobs parked at the render horizon (paused) are not a hang.
        let parked = { (n: Int?) in
            EngineHealth.GPU(lastStepAgeMs: 9000, inLongStep: false, queue: ["p0": 2], parked: n)
        }
        #expect(EngineProcess.hangReason(parked(2), limitMs: 4000) == nil)
        #expect(EngineProcess.hangReason(parked(1), limitMs: 4000) != nil)
        #expect(EngineProcess.hangReason(parked(nil), limitMs: 4000) != nil)     // older engine
        #expect(!TTSStall.isHung(parked(2), config: .init()))
    }

    // MARK: stop and signals

    @Test func stopEscalatesToSIGKILL() async throws {
        let sb = try Sandbox()
        let engine = EngineProcess(config: try sb.config("ignore-term", extra: ["--bad-launches", "99"]))
        let r = try await engine.start()
        let t0 = ContinuousClock.now
        await engine.stop()
        let took = ContinuousClock.now - t0
        #expect(!Self.alive(r.pid))
        #expect(took >= .milliseconds(450) && took < .seconds(3))
    }

    @Test func idleExitAfterMeeting() async throws {
        let sb = try Sandbox()
        let engine = EngineProcess(config: try sb.config { $0.idleAfterMeeting = .milliseconds(300) })
        let r = try await engine.start()
        await engine.setMeetingMode(true)
        await engine.setMeetingMode(false)
        try await Self.waitFor(engine, timeout: .seconds(5)) { $0 == .stopped }
        #expect(!Self.alive(r.pid))
    }

    /// Reopening enrollment within the idle window cancels the pending exit; finishing again
    /// schedules it again (voice-m2: the engine was stopped mid-save).
    @Test func enrollmentStartedCancelsTheIdleExit() async throws {
        let sb = try Sandbox()
        let engine = EngineProcess(config: try sb.config { $0.idleAfterEnrollment = .milliseconds(300) })
        let r = try await engine.start()
        await engine.enrollmentFinished()
        await engine.enrollmentStarted()
        try await Task.sleep(for: .milliseconds(900))
        #expect(await engine.status == .ready(r))
        #expect(Self.alive(r.pid))
        await engine.enrollmentFinished()
        try await Self.waitFor(engine, timeout: .seconds(5)) { $0 == .stopped }
        #expect(!Self.alive(r.pid))
    }

    // MARK: two sessions

    /// Long chunked TTS on every data connection must not delay control requests (§7.6).
    @Test func controlSessionIsNotBlockedByData() async throws {
        let sb = try Sandbox()
        let engine = EngineProcess(config: try sb.config(extra: ["--tts-chunks", "20", "--tts-chunk-ms", "200"]))
        try await engine.start()
        let client = try #require(await engine.client)
        let b = try await client.buildVoice(reference24k: [0.1], refText: "x", model: nil)
        try await client.loadVoice(blob: b.blob)
        let streams = (0..<10).map { i in client.tts(EngineTTSRequest(text: "long sentence \(i)", lang: "en")) }
        let consumers = streams.map { s in Task { for try await _ in s.events {} } }
        try await Task.sleep(for: .milliseconds(300))
        let t0 = ContinuousClock.now
        for _ in 0..<5 {
            _ = try await client.health()
            try await client.playout(bufferedMs: 900)
        }
        #expect(ContinuousClock.now - t0 < .seconds(1))
        // Local cancel first, then /v1/cancel on the control session.
        await streams[0].cancel()
        consumers.forEach { $0.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(sb.file("cancels.txt").contains(streams[0].job))
        await engine.stop()
    }

    @Test func ttsErrorFrameIsReported() async throws {
        let sb = try Sandbox()
        let engine = EngineProcess(config: try sb.config(extra: ["--tts-chunks", "1"]))
        try await engine.start()
        let client = try #require(await engine.client)
        try await client.loadVoice(blob: Data("b".utf8))
        var failed: String?
        for try await ev in client.tts(EngineTTSRequest(text: "fail please", lang: "de")).events {
            if case .failed(let code, _) = ev { failed = code }
        }
        #expect(failed == "tts_failed")
        await engine.stop()
    }

    @Test func remoteQwenStartsTheEngineAndCollects() async throws {
        let sb = try Sandbox()
        let engine = EngineProcess(config: try sb.config())
        let tts = RemoteQwenTTS(engine: engine), asr = RemoteQwenASR(engine: engine)
        let r = try await asr.transcribe([Float](repeating: 0, count: 8000), hint: "de", priority: 2)
        #expect(r.language == "de")
        #expect(r.timing["total_ms"] == 12.5)
        let client = try #require(await engine.client)
        try await client.loadVoice(blob: Data("b".utf8))
        let res = try await tts.speak("Guten Morgen zusammen.", lang: "de").collect()
        #expect(res.samples.count == 5 * 1920 && res.failure == nil)
        #expect(res.firstAudibleMs != nil && res.firstByteMs != nil)
        #expect(res.tail?.frames == 10)
        #expect((res.rtf ?? 0) > 0)
        await engine.stop()
        // after stop, the old client refuses new work instead of crashing
        await #expect(throws: EngineAPIError.invalidated) { _ = try await client.health() }
    }

    @Test func wrongTokenIsRejected() async throws {
        let sb = try Sandbox()
        let engine = EngineProcess(config: try sb.config())
        let r = try await engine.start()
        let bad = EngineClient(port: r.port, token: String(repeating: "0", count: 64))
        await #expect(throws: EngineAPIError.self) { _ = try await bad.health() }
        await engine.stop()
    }
}

/// Pure codec and parser checks (no process).
@Suite(.temporaryFiles) struct EngineWireTests {
    @Test func framesRoundTrip() throws {
        var d = Frames.encode(.jsonHead, Data("{\"a\":1}".utf8))
        d.append(Frames.encode(.pcmF32At24k, Frames.pcmF32([0.5, -0.25])))
        let all = try Frames.decodeAll(d)
        #expect(all.count == 2 && all[0].kind == .jsonHead)
        #expect(Frames.floats(fromF32: all[1].payload) == [0.5, -0.25])
        // incremental, byte by byte
        var dec = Frames.StreamDecoder()
        var got: [Frame] = []
        for b in d { got += try dec.feed(Data([b])) }
        #expect(got == all && dec.pending == 0)
        #expect(throws: FrameError.self) { _ = try Frames.decodeAll(d.dropLast()) }
        var bad = Data([0, 0, 0, 2, 9, 0])
        #expect(throws: FrameError.self) { _ = try Frames.decodeAll(bad) }
        bad = Data([0, 0x50, 0, 0, 1])
        #expect(throws: FrameError.self) { _ = try Frames.decodeAll(bad) }
    }

    @Test func pcmS16Clips() {
        let d = Frames.pcmS16([2.0, -2.0, 0.5])
        let v = d.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(v == [32767, -32768, 16384])
    }

    @Test func handshakeLines() {
        #expect(ServerHandshake.parse("PROGRESS {\"step\":\"tts\",\"done\":1,\"count\":4}")
                == .progress(EngineProgress(step: "tts", done: 1, count: 4)))
        #expect(ServerHandshake.parse("FATAL {\"message\":\"boom\"}") == .fatal("boom"))
        if case .unexpected = ServerHandshake.parse("hello") {} else { Issue.record("unexpected") }
        let ready = """
        READY {"port":5,"pid":9,"api":2,"engine":"talktalk-engine","runtime":"python-mlx","versions":{"mlx":"0.3"},\
        "models":{"tts":{"id":"t","rev":"r","state":"ready"}},"voice":{"state":"absent"}}
        """
        guard case .ready(let r) = ServerHandshake.parse(ready) else { Issue.record("ready"); return }
        #expect(r.port == 5 && r.models["tts"]?.rev == "r")
    }

    @Test func environmentIsExactlyTheDocumentedList() {
        let paths = EnginePaths(home: URL(fileURLWithPath: "/h"), logs: URL(fileURLWithPath: "/l"),
                                caches: URL(fileURLWithPath: "/c"), engineSource: nil, installerScript: nil)
        let env = EngineConfig.environment(token: "t", paths: paths, home: "/Users/x", lang: "zh_CN.UTF-8")
        #expect(env == [
            "HOME": "/Users/x", "LANG": "zh_CN.UTF-8", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": "/c/engine-tmp",
            "TALKTALK_TOKEN": "t", "TALKTALK_CACHE_DIR": "/c/engine-cache", "HF_HOME": "/c/hf", "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "PYTHONDONTWRITEBYTECODE": "1",
            "MLX_METAL_RESIDENCY_REFRESH_INTERVAL_MS": "1000",
        ])
    }

    @Test func logRotatesAtLimit() throws {
        let dir = try TestTemporaryDirectory.make(prefix: "tt-log")
        let log = dir.appendingPathComponent("engine.log")
        var fd = try ServerLog.openForAppend(log, rotateAt: 10)
        _ = "0123456789AB".withCString { write(fd, $0, 12) }
        close(fd)
        fd = try ServerLog.openForAppend(log, rotateAt: 10)
        close(fd)
        #expect(FileManager.default.fileExists(atPath: log.appendingPathExtension("1").path))
        let attrs = try FileManager.default.attributesOfItem(atPath: log.path)
        #expect((attrs[.size] as? NSNumber)?.intValue == 0)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
