import AppKit
import Foundation
import Speech
import TalkTalkApple
import TalkTalkAudio
import TalkTalkCloud
import TalkTalkSession
import TalkTalkCloudUI
import TalkTalkCore
import TalkTalkEngineHost

/// An owned synthetic afplay process → include tap → Apple ASR → MT. No meeting process is tapped.
func loopSelfTest() async -> SelfTestReport {
    var report = SelfTestReport(suite: "loop")
    guard Bundle.main.bundleIdentifier != nil, SFSpeechRecognizer.authorizationStatus() == .authorized,
          await AppleSpeechASR.assetsInstalled(.en) else {
        report.checks.append(.init("loop.permissions", ok: nil, detail: "skipped: launch the app with Speech permission and installed English assets"))
        return report
    }
    // The golden translation samples run only for an explicit --loop request, never during
    // ordinary project checks or the default collection of local self-tests.
    if arguments.contains("--loop") { report.checks += await appleTranslationGoldenChecks() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("talktalk-loop-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var process: Process?, tap: MeetingTap?, speech: (any ASRStream)?
    defer { tap?.stop(); if let process, process.isRunning { process.terminate() } }
    do {
        try FileSystem.ensurePrivateDirectory(directory)
        let wav = directory.appendingPathComponent("fixture-en.wav")
        try ListenDemo.render("Hello. Hello. The budget for Monday is three hundred euros. The budget for Monday is three hundred euros.", to: wav)
        let stream = try await AppleSpeechASR().open(.en, highPriority: false)
        speech = stream
        let finalTask = Task { () -> String in
            var text: [String] = []
            for await event in stream.finalEvents { if case .final(let words, _) = event { text.append(words) } }
            return text.joined(separator: " ")
        }
        let player = Process(); player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); player.arguments = [wav.path]
        player.standardOutput = FileHandle.nullDevice; player.standardError = FileHandle.nullDevice
        try player.run(); process = player
        var ids: [UInt32] = []
        for _ in 0..<100 {
            ids = (try? AudioProcessList.current().filter { $0.pid == player.processIdentifier }.map(\.objectID)) ?? []
            if !ids.isEmpty { break }; try await Task.sleep(for: .milliseconds(20))
        }
        guard !ids.isEmpty else { throw LoopFailure.noAudioProcess }
        let source = MeetingTap(processes: ids, muteBehavior: .unmuted)
        let ingest = AudioIngest(); ingest.attach(stream)
        try source.start(onChunk: { ingest.push($0.samples, host: $0.hostTime) }, onEvent: { _ in })
        tap = source
        let deadline = ContinuousClock.now + .seconds(20)
        while player.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        if player.isRunning { player.terminate(); throw LoopFailure.timeout }
        try await Task.sleep(for: .milliseconds(200))
        source.stop(); tap = nil; ingest.detach()
        await stream.close(); speech = nil
        let text = await finalTask.value.lowercased()
        let heard = text.contains("budget") && text.contains("monday")
        report.checks.append(.init("loop.asrKeywords", ok: heard, values: ["chunks": Double(ingest.chunks), "characters": Double(text.count)]))
        if heard {
            let translation: String
            if arguments.contains("--cloud") {
                let preferences = TranslationPreferences.load(.standard)
                guard preferences.cloudConsentGiven, preferences.anyCloud else { throw LoopFailure.cloudDisabled }
                guard let cloud = try OpenAIMT.forCurrentApp(model: preferences.model, effort: preferences.effort, log: nil) else { throw LoopFailure.cloudDisabled }
                translation = try await cloud.translate(.init(job: 1, session: .listenEnZh, text: text, isFinalChunk: true,
                                                              priority: .p3Background, maxOutputTokens: 128)).text
            } else if #available(macOS 26.4, *) {
                let apple = AppleTranslationMT(); try await apple.prepare(.listenEnZh)
                translation = try await apple.translate(.init(job: 1, session: .listenEnZh, text: text, isFinalChunk: true,
                                                              priority: .p3Background, maxOutputTokens: 128)).text
            } else { throw LoopFailure.translationUnavailable }
            report.checks.append(.init("loop.mtKeywords", ok: translation.contains("预算") && (translation.contains("周一") || translation.contains("星期一"))))
        }
    } catch {
        if let speech { await speech.close() }
        report.checks.append(.init("loop.run", ok: false, detail: String(describing: type(of: error))))
    }
    return report
}
private enum LoopFailure: Error { case noAudioProcess, timeout, cloudDisabled, translationUnavailable }

/// Fixed synthetic text only. Apple does not accept a glossary, so these checks measure
/// preservation of required terms instead of pretending setContext can enforce them.
private func appleTranslationGoldenChecks() async -> [SelfTestCheck] {
    guard #available(macOS 26.4, *) else {
        return [.init("loop.appleMT.resources", ok: nil, detail: "skipped: high-fidelity Apple Translation requires macOS 26.4"),
                .init("loop.appleMT.complete", ok: false, detail: "incomplete: required Apple MT checks were skipped")]
    }
    let fixtures: [(text: GlossaryEntry, term: String)] = [
        (.init(zh: "项目 Atlas 的预算是三十万欧元。",
               en: "The budget for project Atlas is three hundred thousand euros.",
               de: "Das Budget für das Projekt Atlas beträgt dreihunderttausend Euro."), "Atlas"),
        (.init(zh: "API 的折扣是百分之二十，交付日期在十二月。",
               en: "The API discount is twenty percent, with delivery in December.",
               de: "Der API-Rabatt beträgt zwanzig Prozent, die Lieferung erfolgt im Dezember."), "API"),
    ]
    let apple = AppleTranslationMT()
    var checks: [SelfTestCheck] = [], job: JobID = 100
    for session in MTSession.allCases {
        let name = "loop.appleMT." + session.rawValue
        let availability = await AppleTranslationMT.availability(session)
        guard availability == "installed" else {
            checks.append(.init(name + ".resources", ok: nil,
                detail: "skipped: Apple Translation resources " + availability))
            continue
        }
        do {
            try await apple.prepare(session) // installed-only API; never requests a download
            for (index, fixture) in fixtures.enumerated() {
                job += 1
                let direction = session.direction, source = fixture.text.rendering(for: direction.source)
                let start = HostClock.now()
                let output = try await apple.translate(.init(job: job, session: session, text: source,
                    isFinalChunk: true, priority: .p3Background, maxOutputTokens: 128)).text
                // NumberGuard's source parser is Chinese; reverse LISTEN's pair for that check.
                let numbers = direction.target == .zh
                    ? NumberGuard.check(source: output, target: source, targetLang: direction.source)
                    : NumberGuard.check(source: source, target: output, targetLang: direction.target)
                let sample = name + "." + String(index + 1)
                checks.append(.init(sample + ".numbers", ok: numbers.numbersMatch,
                    values: ["missing": Double(numbers.missing.count), "extra": Double(numbers.extra.count),
                             "milliseconds": Double(HostClock.ms(start, to: HostClock.now()))]))
                checks.append(.init(sample + ".term", ok: output.localizedCaseInsensitiveContains(fixture.term)))
            }
        } catch AppleTranslationMT.Failure.notInstalled(_) {
            checks.append(.init(name + ".resources", ok: nil, detail: "skipped: Apple Translation resources became unavailable"))
        } catch {
            checks.append(.init(name + ".translate", ok: false, detail: String(describing: type(of: error))))
        }
    }
    let complete = checks.count == MTSession.allCases.count * fixtures.count * 2 && checks.allSatisfy { $0.ok == true }
    // A partial pass must not make the enclosing loop report claim four-direction acceptance.
    checks.append(.init("loop.appleMT.complete", ok: complete,
        detail: complete ? nil : "incomplete: at least one required golden check failed or was skipped"))
    return checks
}
