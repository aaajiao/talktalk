import Foundation
import TalkTalkApple
import TalkTalkCore
import TalkTalkEngineHost
import TalkTalkVoice

/// Explicit synthetic fixture test. No microphone, playback, user voice, cloud call or download.
/// Run the signed app with --self-test --speak-languages --out <file> to use its Speech grant.
func speakLanguagesSelfTest() async -> SelfTestReport {
    var report = SelfTestReport(suite: "speak-languages")
    guard #available(macOS 26.4, *) else {
        report.checks.append(.init("resources", ok: nil, detail: "requires macOS 26.4")); return report
    }
    guard AppleSpeechASR.currentAuthorization() == "authorized" else {
        report.checks.append(.init("speech.permission", ok: nil, detail: "launch the signed app with its existing Speech grant")); return report
    }
    do {
        let profile = try PolicyProfile.loadDefault()
        let gate = try TargetTextGate(config: profile.speak.mt.targetGate, patterns: GatePatterns.loadDefault())
        let system = SystemVoiceTTS(), apple = AppleTranslationMT(), asr = AppleFinalizeASR()
        let handle = VoiceHandle(profileID: UUID(), conditioningKey: "system", mode: .system, model: system.id)
        var job: JobID = 1
        func render(_ text: String, language: Lang, job: JobID) async throws -> [Float] {
            var samples: [Float] = []
            for try await chunk in system.speak(.init(job: job, clause: job, text: text, language: language,
                    voice: handle, seed: TTSSeed.make(voice: handle, text: text), wholeClause: true)) {
                samples.append(contentsOf: chunk.samples24k)
            }
            return samples
        }
        let fixtures: [(Lang, String)] = [(.zh, "项目的预算是三百欧元，我们下周讨论。"),
                                         (.en, "The project budget is three hundred euros. We will discuss it next week."),
                                         (.fr, "Le budget du projet est de trois cents euros. Nous en parlerons la semaine prochaine.")]
        for (source, text) in fixtures {
            guard await AppleSpeechASR.assetsInstalled(source) else {
                report.checks.append(.init("asr.\(source.rawValue)", ok: nil, detail: "speech assets not installed")); continue
            }
            let pcm = try await render(text, language: source, job: job); job += 1
            let clip = PCMClip16k(samples: try Resampler.resample(pcm, from: 24_000, to: 16_000),
                                  start: 0, end: UInt64(Double(pcm.count) / 24_000 * 1e9))
            let recognized = try await asr.transcribe(clip, hint: source, context: nil, job: job,
                                                      priority: .p1Speak, deadline: HostClock.now() + 30_000_000_000)
            job += 1
            let numbers = NumberGuard.check(source: text, sourceLang: source, target: recognized.text, targetLang: source)
            let keyword = source == .zh ? recognized.text.contains("预算") : recognized.text.lowercased().contains("budget")
            report.checks.append(.init("asr.\(source.rawValue)", ok: keyword && numbers.numbersMatch))
            for target in Lang.allCases where MTSession.speak(source: source, target: target) != nil {
                let session = MTSession.speak(source: source, target: target)!
                guard await AppleTranslationMT.availability(session) == "installed" else {
                    report.checks.append(.init(session.rawValue, ok: nil, detail: "translation pack not installed")); continue
                }
                let result = try await apple.translate(.init(job: job, session: session, text: recognized.text,
                    isFinalChunk: true, priority: .p3Background, maxOutputTokens: 128)); job += 1
                let accepted: Bool
                if case .pass = gate.check(result.text, target: target) { accepted = true } else { accepted = false }
                let check = NumberGuard.check(source: recognized.text, sourceLang: source, target: result.text, targetLang: target)
                report.checks.append(.init(session.rawValue + ".translation", ok: accepted && check.numbersMatch))
                let audio = try await render(result.text, language: target, job: job); job += 1
                report.checks.append(.init(session.rawValue + ".systemVoice", ok: audio.contains { abs($0) > 0.01 },
                                           values: ["audioS": Double(audio.count) / 24_000]))
            }
        }
        let expected = fixtures.count + MTSession.allCases.filter(\.isSpeak).count * 2
        report.checks.append(.init("complete", ok: report.checks.count == expected && report.checks.allSatisfy { $0.ok == true }))
    } catch {
        report.checks.append(.init("run", ok: false, detail: String(describing: error)))
    }
    return report
}
