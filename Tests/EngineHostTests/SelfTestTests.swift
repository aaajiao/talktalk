import Darwin
import Foundation
import Testing
import TalkTalkTestSupport
@testable import TalkTalkCore
@testable import TalkTalkEngineHost

/// `--self-test --engine` logic (§12.3): metrics, the lsof audit, and a whole run against the
/// fake engine (real lsof on its pid).
@Suite(.temporaryFiles) struct SelfTestTests {
    @Test func cerIgnoresPunctuationAndWidth() {
        #expect(TextMetrics.cer(reference: "今天十点开会。", hypothesis: "今天，十点开会") == 0)
        #expect(TextMetrics.cer(reference: "今天十点开会", hypothesis: "今天十点开") == 1.0 / 6)
        #expect(TextMetrics.cer(reference: "ＡＢＣ", hypothesis: "ABC") == 0)   // NFKC
        #expect(TextMetrics.cer(reference: "", hypothesis: "") == 0)
    }

    @Test func werNormalizesCaseAndPunctuation() {
        let ref = "Thanks, everyone. Let me quickly walk you through where the project stands today."
        #expect(TextMetrics.wer(reference: ref, hypothesis: "thanks everyone let me quickly walk you through where the project stands today") == 0)
        #expect(TextMetrics.wer(reference: "Let me walk you", hypothesis: "let me talk you") == 0.25)
        #expect(TextMetrics.werUnits("Don't stop — well-known, Überblick.") == ["don't", "stop", "well-known", "überblick"])
        #expect(TextMetrics.wer(reference: "a b", hypothesis: "") == 1)
        #expect(TextMetrics.wer(reference: "L’état du projet.", hypothesis: "L'état du projet") == 0)
    }

    @Test func lsofFieldOutputParsesAndAudits() {
        let out = """
        p4242
        f5
        PTCP
        n127.0.0.1:50123
        TST=LISTEN
        TQR=0
        f9
        PTCP
        n127.0.0.1:50123->127.0.0.1:61000
        TST=ESTABLISHED
        """
        let s = SocketAudit.parse(out)
        #expect(s == [SocketAudit.Socket(name: "127.0.0.1:50123", state: "LISTEN", proto: "TCP"),
                      SocketAudit.Socket(name: "127.0.0.1:50123->127.0.0.1:61000", state: "ESTABLISHED", proto: "TCP")])
        #expect(SocketAudit.problems(s, port: 50123).isEmpty)
        #expect(SocketAudit.problems(s, port: 1) == ["listening: 127.0.0.1:50123"])
        #expect(SocketAudit.problems([], port: 1) == ["listening: none"])

        let leaky = s + [SocketAudit.Socket(name: "192.168.1.5:50000->1.2.3.4:443", state: "ESTABLISHED", proto: "TCP"),
                         SocketAudit.Socket(name: "*:5353", state: nil, proto: "UDP"),
                         SocketAudit.Socket(name: "*:50124", state: "LISTEN", proto: "TCP")]
        let bad = SocketAudit.problems(leaky, port: 50123)
        #expect(bad.count == 3)
        #expect(bad[0] == "listening: 127.0.0.1:50123 *:50124")
    }

    @Test func reportIsOneJSONLine() throws {
        var r = SelfTestReport(suite: "engine")
        r.checks = [SelfTestCheck("install", ok: true), SelfTestCheck("asr", ok: nil, detail: "skipped"),
                    SelfTestCheck("tts_en", ok: true, values: ["rtf": 0.4])]
        let line = r.jsonLine()
        #expect(!line.contains("\n"))
        let back = try JSONDecoder().decode(SelfTestReport.self, from: Data(line.utf8))
        #expect(back == r && back.ok)
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        #expect(obj?["ok"] as? Bool == true)
        r.checks.append(SelfTestCheck("sockets", ok: false))
        #expect(!r.ok)
        #expect(!SelfTestReport(suite: "engine").ok)   // nothing ran is not a pass
        #expect(!SelfTestReport(suite: "corun", checks: [.init("corun", ok: nil, detail: "skipped")]).ok)
    }

    @Test func notStartableInstallStopsAtTheFirstCheck() async throws {
        let box = try EngineHostTests.Sandbox()
        let engine = EngineProcess(config: try box.config())
        let t = EngineSelfTest(install: .notInstalled, engine: engine, asrSample: nil, reference: nil,
                               referenceSource: "synthetic", isAudioProcess: { _ in false }, to16k: { $0 })
        let r = await t.run()
        #expect(r.checks.map(\.name) == ["install"])
        #expect(!r.ok)
        #expect(box.launches.isEmpty)
    }

    /// The fake engine's ASR always answers 今天十点开会 and its TTS is 0.08 s per chunk with
    /// expected_s 0.4: the zh sample passes, the duration checks pass, the en/de read-backs fail.
    @Test func fullRunAgainstFakeEngine() async throws {
        let box = try EngineHostTests.Sandbox()
        let engine = EngineProcess(config: try box.config(extra: ["--tts-chunks", "5", "--tts-chunk-ms", "5"]))
        let t = EngineSelfTest(install: .installed(profile: "max", models: ["tts-x", "asr-y"]), engine: engine,
                               asrSample: .init(samples: [Float](repeating: 0, count: 16000), text: "今天十点开会。"),
                               reference: .init(samples: [Float](repeating: 0.1, count: 24000), text: "参考"),
                               referenceSource: "synthetic", isAudioProcess: { _ in false },
                               to16k: { Array($0.enumerated().filter { $0.offset % 3 != 2 }.map(\.element)) })
        let r = await t.run()
        let byName = Dictionary(uniqueKeysWithValues: r.checks.map { ($0.name, $0) })
        #expect(r.checks.map(\.name) == ["install", "ready", "not_audio_process", "sockets", "asr", "voice",
                                         "tts_en", "readback_en", "tts_de", "readback_de", "tts_fr", "readback_fr", "stop"])
        for name in ["install", "ready", "not_audio_process", "sockets", "asr", "voice", "tts_en", "tts_de", "tts_fr", "stop"] {
            #expect(byName[name]?.ok == true, "\(name): \(byName[name]?.detail ?? "")")
        }
        #expect(byName["asr"]?.values["cer"] == 0)
        #expect(byName["tts_en"]?.values["ratio"] == 1.0)
        #expect(byName["readback_en"]?.ok == false)
        #expect(byName["readback_de"]?.values["wer"] == 1.0)
        #expect(!r.ok)
        #expect(await engine.status == .stopped)
        #expect(!r.jsonLine().contains("今天"))   // no transcript text in the report
    }

    @Test func audioProcessAndMissingReferenceFail() async throws {
        let box = try EngineHostTests.Sandbox()
        let engine = EngineProcess(config: try box.config())
        let t = EngineSelfTest(install: .installed(profile: "max", models: []), engine: engine, asrSample: nil,
                               reference: nil, referenceSource: "synthetic", isAudioProcess: { _ in true },
                               sockets: { _ in nil }, to16k: { $0 })
        let r = await t.run()
        let byName = Dictionary(uniqueKeysWithValues: r.checks.map { ($0.name, $0) })
        #expect(byName["not_audio_process"]?.ok == false)
        #expect(byName["sockets"]?.detail == "lsof could not be run")
        #expect(byName["asr"]?.detail == "warmup sample missing")
        #expect(byName["voice"]?.ok == false)
        #expect(await engine.status == .stopped)
    }

    @Test func recognitionOnlySelfTestRequiresASRButSkipsVoiceAndSynthesis() async throws {
        let box = try EngineHostTests.Sandbox()
        var config = try box.config()
        config.roles = ["asr"]; config.tts = nil
        let engine = EngineProcess(config: config)
        let test = EngineSelfTest(install: .installed(profile: "custom", models: ["asr-y"]), engine: engine,
                                 asrSample: .init(samples: [Float](repeating: 0, count: 16000), text: "今天十点开会。"),
                                 reference: nil, referenceSource: "synthetic", isAudioProcess: { _ in false },
                                 to16k: { $0 })
        let report = await test.run()
        #expect(report.ok)
        #expect(report.checks.first { $0.name == "asr" }?.ok == true)
        let voice = try #require(report.checks.first { $0.name == "voice" })
        #expect(voice.ok == nil && voice.detail == "no TTS role in this installation")
        #expect(!report.checks.contains { $0.name.hasPrefix("tts_") })
        let requests = box.file("requests.jsonl")
        #expect(!requests.contains("/v1/voice/") && !requests.contains("/v1/tts"))
        #expect(await engine.status == .stopped)
    }
}
