import Foundation
import TalkTalkAudio
import TalkTalkCore
import TalkTalkEngineHost
import TalkTalkVoice

// m1-engine: `TalkTalk --self-test [--engine] [--voice] … --out <file>` (ARCHITECTURE.md §12.3).
// Headless (no NSApplication). One JSON line per part to --out (0600), in the order of
// `selfTestParts`, each a SelfTestReport with its own `suite`; exit 0 when every part passes, 1 when
// any fails or all its checks are skipped, 2 usage. No part flag = implemented local parts; cloud
// needs explicit --cloud, and --corun is an explicit skip. Parts that are not implemented yet are
// refused with exit 2. The engine part touches no TCC-protected resource, so it can run straight
// from a terminal. The driver part (m2, DriverSelfTestMain.swift) reads Test Mic and TalkTalk Mic,
// which is microphone access: without the grant it skips those checks instead of prompting, so
// run it through LaunchServices to use the app's grant:
//   open -W -n -a build/TalkTalk-Dev.app --args --self-test --driver --out <file>
//
// Adding a part: write `func <name>SelfTest() async -> SelfTestReport` in its own file
// (SelfTestVoice.swift and so on) and add one entry to `selfTestRunners`. Nothing else here changes.

let selfTestParts = ["--engine", "--driver", "--voice", "--loop", "--passthrough", "--corun", "--cloud"]
let selfTestRunners: [String: @Sendable () async -> SelfTestReport] = [
    "--engine": engineSelfTest,
    "--driver": driverSelfTest,   // m2 driver
    "--voice": { await voiceSelfTest() },
    "--loop": loopSelfTest,
    "--passthrough": passthroughSelfTest,
    "--cloud": cloudSelfTest,
    "--corun": { SelfTestReport(suite: "corun", checks: [.init("corun", ok: nil, detail: "skipped: load testing is disabled by the user's decision")]) },
]

func runSelfTest() -> Never {
    let out = argumentValue("--out")
    let flags = Set(arguments.dropFirst().filter { $0.hasPrefix("--") && $0 != "--out" })
    let unknown = flags.subtracting(selfTestParts)
    guard out != nil else { fail("--self-test needs --out <file>") }
    guard unknown.isEmpty else { fail("unknown --self-test option(s): \(unknown.sorted().joined(separator: " "))") }
    let implemented = Set(selfTestRunners.keys)
    let missing = flags.subtracting(implemented)
    guard missing.isEmpty else {
        fail("--self-test \(missing.sorted().joined(separator: " ")) is not implemented yet "
            + "(implemented: \(selfTestParts.filter(implemented.contains).joined(separator: " ")))")
    }
    let parts = selfTestParts.filter { flags.isEmpty ? implemented.contains($0) && $0 != "--cloud" && $0 != "--corun" : flags.contains($0) }

    Task.detached {
        var reports: [SelfTestReport] = []
        for p in parts { if let run = selfTestRunners[p] { reports.append(await run()) } }
        let text = reports.map { $0.jsonLine() + "\n" }.joined()
        do { try FileSystem.writeAtomically(Data(text.utf8), to: URL(fileURLWithPath: out!)) }
        catch { fail("could not write self-test report", code: 1) }
        exit(!reports.isEmpty && reports.allSatisfy(\.ok) ? 0 : 1)
    }
    // Apple speech/translation callbacks can need the main queue; never block it on a semaphore.
    dispatchMain()
}

func engineSelfTest() async -> SelfTestReport {
    let paths = EnginePaths.standard()
    let installation = EngineInstallation(engineHome: paths.engineHome())
    let (state, record) = installation.check()
    guard let record, let source = paths.engineSource else {
        var r = SelfTestReport(suite: "engine")
        r.checks.append(SelfTestCheck("install", ok: false,
                                      detail: paths.engineSource == nil ? "engine source not found in the bundle" : String(describing: state)))
        return r
    }
    let config = EngineConfig.installed(record: record, installation: installation, paths: paths, source: source,
                                     policy: try? PolicyProfile.loadDefault())
    let engine = EngineProcess(config: config)

    let warm = installation.warmupDir
    func wav(_ url: URL, rate: Int) -> [Float]? {
        guard let data = try? Data(contentsOf: url), let d = WAVFile.decodePCM16(data) else { return nil }
        if d.sampleRate == rate { return d.samples }
        return try? Resampler.resample(d.samples, from: Double(d.sampleRate), to: Double(rate))
    }
    func text(_ url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var asrSample: EngineSelfTest.Sample?
    if let s = wav(warm.appendingPathComponent("sample-zh.wav"), rate: 16000),
       let t = text(warm.appendingPathComponent("sample-zh.txt")) {
        asrSample = .init(samples: s, text: t)
    }
    // "My voice" first (§9.3: 24 kHz reference.wav + script.txt), else the synthetic `say` reference.
    var reference: EngineSelfTest.Sample?
    var source_ = "synthetic"
    let voice = VoiceStore(root: paths.home).voiceURL
    if let s = wav(voice.appendingPathComponent(VoiceStore.referenceName), rate: 24000),
       let t = text(voice.appendingPathComponent(VoiceStore.scriptName)) {
        reference = .init(samples: s, text: t)
        source_ = "my_voice"
    } else if let s = wav(warm.appendingPathComponent("ref-zh.wav"), rate: 24000),
              let t = text(warm.appendingPathComponent("ref-zh.txt")) {
        reference = .init(samples: s, text: t)
    }

    let test = EngineSelfTest(
        install: state, engine: engine, asrSample: asrSample, reference: reference, referenceSource: source_,
        isAudioProcess: { pid in (try? AudioProcessList.current()).map { $0.contains { $0.pid == pid } } },
        to16k: { (try? Resampler.resample($0, from: 24000, to: 16000)) ?? [] })
    return await test.run()
}
