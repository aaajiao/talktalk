import Foundation
import Synchronization
import TalkTalkApple
import TalkTalkCore
import TalkTalkEngineHost
import TalkTalkSession
import TalkTalkVoice

/// Explicit, silent synthetic video-caption test: system TTS buffers → real streaming
/// Apple/Qwen ASR → production LISTEN segmentation → Apple MT → finals, in six directions.
/// No microphone, speaker, private recording, cloud request or resource download is used.
func subtitleLanguagesSelfTest() async -> SelfTestReport {
    var report = SelfTestReport(suite: "subtitle-languages")
    var qwen: EngineProcess?
    guard #available(macOS 26.4, *), AppleSpeechASR.currentAuthorization() == "authorized" else {
        report.checks.append(.init("resources", ok: nil, detail: "requires macOS 26.4 and the signed app's Speech grant"))
        return report
    }
    do {
        let profile = try PolicyProfile.loadDefault(), system = SystemVoiceTTS()
        let paths = EnginePaths.standard(), installation = EngineInstallation(engineHome: EnginePaths.standard().engineHome())
        if let record = installation.check().1, record.roles["asr"] != nil, let source = paths.engineSource {
            qwen = EngineProcess(config: .installed(record: record, installation: installation, paths: paths,
                                                    source: source, roles: ["asr"], policy: profile))
        }
        let gate = try TargetTextGate(config: profile.speak.mt.targetGate, patterns: GatePatterns.loadDefault())
        let voice = VoiceHandle(profileID: UUID(), conditioningKey: "system", mode: .system, model: system.id)
        let fixtures: [(Lang, String)] = [(.zh, "项目的预算是三百欧元。"),
                                         (.en, "The project budget is three hundred euros."),
                                         (.de, "Das Projektbudget beträgt dreihundert Euro.")]
        var audio: [Lang: [Float]] = [:]
        for (language, text) in fixtures {
            guard await AppleSpeechASR.assetsInstalled(language) else {
                report.checks.append(.init("asr.\(language.rawValue)", ok: nil, detail: "speech assets not installed")); continue
            }
            var pcm: [Float] = []
            for try await chunk in system.speak(.init(job: UInt64(audio.count + 1), clause: 1, text: text,
                    language: language, voice: voice, seed: TTSSeed.make(voice: voice, text: text), wholeClause: true)) {
                pcm.append(contentsOf: chunk.samples24k)
            }
            audio[language] = try Resampler.resample(pcm, from: 24_000, to: 16_000) + [Float](repeating: 0, count: 24_000)
        }
        for backend in ["apple", "qwen"] {
          for session in MTSession.allCases where !session.isSpeak {
            let direction = session.direction
            let name = backend + "." + session.rawValue
            guard let pcm = audio[direction.source], backend == "apple" || qwen != nil,
                  await AppleTranslationMT.availability(session) == "installed" else {
                report.checks.append(.init(name, ok: nil, detail: "source audio, ASR model or translation pack unavailable")); continue
            }
            let apple = AppleTranslationMT(), ingest = AudioIngest()
            let finals = Mutex<[UInt64: (String, String)]>([:])
            let usedQwen = Mutex(false), fellBack = Mutex(false)
            let asr: any StreamingASREngine = backend == "apple" ? AppleSpeechASR() : QwenStreamingASR(
                engine: qwen, fallback: AppleSpeechASR(), onEngine: { engine in
                    if engine.placement == .engineGPU { usedQwen.withLock { $0 = true } }
                    else { fellBack.withLock { $0 = true } }
                })
            var engines = ListenPipeline.Engines(asr: asr, apple: apple, primary: nil)
            engines.prepareTranslation = { try? await apple.prepare(session) }
            let pipeline = ListenPipeline(lang: direction.source, target: direction.target, profile: profile.listen,
                engines: engines, log: EventLog(inMemory: HostClock.now), ingest: ingest, onUpdate: { update in
                    if case let .final(sentence, text, source, _, _) = update {
                        finals.withLock { $0[sentence] = (source, text) }
                    }
                })
            do {
                try await pipeline.start()
                for offset in stride(from: 0, to: pcm.count, by: 3200) {
                    try Task.checkCancellation()
                    let end = min(pcm.count, offset + 3200)
                    ingest.push(Array(pcm[offset..<end]), host: HostClock.now())
                    try await Task.sleep(for: .milliseconds(200))
                }
                let deadline = ContinuousClock.now + .seconds(8)
                while finals.withLock({ $0.isEmpty }), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                await pipeline.stop()
            } catch {
                await pipeline.stop()
                throw error
            }
            let pairs = finals.withLock { rows in rows.keys.sorted().compactMap { rows[$0] } }
            let source = pairs.map(\.0).joined(separator: " "), target = pairs.map(\.1).joined(separator: " ")
            let numbers = NumberGuard.check(source: source, sourceLang: direction.source, target: target, targetLang: direction.target)
            let validTarget: Bool
            if case .pass = gate.check(target, target: direction.target) { validTarget = true } else { validTarget = false }
            let sourceKeyword = direction.source == .zh ? source.contains("预算") : source.lowercased().contains("budget")
            let backendOK = backend == "apple" || (usedQwen.withLock { $0 } && !fellBack.withLock { $0 })
            report.checks.append(.init(name, ok: backendOK && sourceKeyword && validTarget && numbers.numbersMatch
                && numbers.source.contains { $0.value == 300 }, values: ["finals": Double(pairs.count)]))
          }
        }
        report.checks.append(.init("complete", ok: report.checks.count == 12 && report.checks.allSatisfy { $0.ok == true }))
    } catch {
        report.checks.append(.init("run", ok: false, detail: String(describing: type(of: error))))
    }
    await qwen?.stop()
    return report
}
