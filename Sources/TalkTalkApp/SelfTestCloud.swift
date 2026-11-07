import Foundation
import TalkTalkCloud
import TalkTalkCloudUI
import TalkTalkCore
import TalkTalkEngineHost

/// Explicit --cloud only. Tiny synthetic requests for every direction; no microphone, user text or key in the report.
func cloudSelfTest() async -> SelfTestReport {
    var report = SelfTestReport(suite: "cloud")
    let preferences = TranslationPreferences.load(.standard)
    guard preferences.cloudConsentGiven, preferences.anyCloud,
          let id = Bundle.main.bundleIdentifier, let secret = KeychainSecret.openAI(bundleID: id), secret.exists() else {
        report.checks.append(.init("cloud.consent_and_key", ok: nil, detail: "skipped: cloud consent, enabled cloud direction and app key are required"))
        return report
    }
    do {
        let profile = try PolicyProfile.loadDefault()
        let reasoningBudget = await TranslationSettingsModel.yellowReasoningBudget
        let ports = CloudSelfTestPorts()
        let client = OpenAIClient(cloud: profile.cloud, keyProvider: { String(decoding: try secret.read(), as: UTF8.self) }, sink: { ports.observe($0) })
        let builder = OpenAIRequestBuilder(cloud: profile.cloud, prompts: try MTPrompts.loadDefault())
        let gate = try TargetTextGate(config: profile.speak.mt.targetGate, patterns: GatePatterns.loadDefault())
        let cases: [(MTSession, String)] = [(.speakZhEn, "预算是三百欧元。"), (.speakZhDe, "周一开会。"),
                                           (.speakEnZh, "The budget is three hundred euros."), (.speakEnDe, "We meet on Monday."),
                                           (.listenEnZh, "The budget is three hundred euros."), (.listenDeZh, "Wir treffen uns am Montag."),
                                           (.listenZhEn, "预算是三百欧元。"), (.listenZhDe, "预算是三百欧元。"),
                                           (.listenEnDe, "The budget is three hundred euros."), (.listenDeEn, "Das Budget beträgt dreihundert Euro.")]
        var responseID: String?
        for (index, sample) in (cases + [cases[0]]).enumerated() {
            let leg: Leg = index == cases.count ? .B : .A
            let request = MTRequest(job: UInt64(index + 1), session: sample.0, text: sample.1, isFinalChunk: true,
                                    priority: .p3Background, maxOutputTokens: 64)
            let body = try builder.body(for: request, glossary: [], options: .init(model: preferences.model, effort: preferences.effort,
                reasoningBudget: preferences.effort == "none" ? 0 : reasoningBudget, contextTokensSoft: 150, contextTokensHard: 400))
            var result = ResponseAccumulator(), first: HostTime?
            let start = HostClock.now()
            for try await item in client.stream(leg: leg, body: body) {
                if case .sse(let event) = item {
                    for signal in result.consume(event) { if case .delta = signal, first == nil { first = HostClock.now() } }
                }
            }
            let (_, validation) = result.terminalResult(sentEffort: preferences.effort, cloud: profile.cloud)
            let echo = result.final
            let valid = validation?.isUsable == true && echo?.reasoningTokens == 0 && echo?.status == "completed"
            report.checks.append(.init("cloud.\(sample.0.rawValue).\(leg.rawValue)", ok: valid,
                detail: validation?.rejectReason,
                values: ["roundTripMs": Double(HostClock.ms(start, to: HostClock.now())),
                         "firstTokenMs": first.map { Double(HostClock.ms(start, to: $0)) } ?? -1,
                         "reasoningTokens": Double(echo?.reasoningTokens ?? -1),
                         "storeEchoMissing": validation?.storeEchoMissing == true ? 1 : 0]))
            do {
                let direction = sample.0.direction, text = result.firstLine.text
                let accepted: Bool
                if case .pass = gate.check(text, target: direction.target) { accepted = true } else { accepted = false }
                let numbers = NumberGuard.check(source: sample.1, sourceLang: direction.source,
                                                target: text, targetLang: direction.target)
                report.checks.append(.init("cloud.\(sample.0.rawValue).\(leg.rawValue).content",
                                           ok: accepted && numbers.numbersMatch))
            }
            responseID = responseID ?? echo?.id
        }
        if let responseID {
            let reply = try await client.get(leg: .A, path: profile.cloud.responsesPath + "/" + responseID)
            report.checks.append(.init("cloud.notStored", ok: reply.headers.status == 404, values: ["status": Double(reply.headers.status)]))
        } else { report.checks.append(.init("cloud.notStored", ok: false, detail: "no response id")) }
        try? await Task.sleep(for: .milliseconds(100)) // URLSession delivers metrics after the body finishes.
        let pair = ports.snapshot
        report.checks.append(.init("cloud.separateConnections", ok: pair.0 != nil && pair.1 != nil && pair.0 != pair.1,
                                  values: ["aPort": Double(pair.0 ?? -1), "bPort": Double(pair.1 ?? -1)]))
    } catch {
        report.checks.append(.init("cloud.request", ok: false, detail: String(describing: type(of: error))))
    }
    return report
}

private final class CloudSelfTestPorts: @unchecked Sendable {
    private let lock = NSLock()
    private var ports: [Leg: Int] = [:]
    func observe(_ event: CloudEvent) {
        if case .metrics(let metrics) = event, let port = metrics.localPort { lock.withLock { ports[metrics.leg] = port } }
    }
    var snapshot: (Int?, Int?) { lock.withLock { (ports[.A], ports[.B]) } }
}
