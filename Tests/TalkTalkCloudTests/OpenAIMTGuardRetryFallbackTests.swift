import Foundation
import Synchronization
import Testing
import TalkTalkCore
@testable import TalkTalkCloud

extension FakeServerCloudTests {
    private func retryFallback(_ p: PolicyProfile, apple: RetryApple,
                               log: TalkTalkCore.EventLog? = nil,
                               glossary: [GlossaryEntry] = []) throws -> FallbackMT {
        let patterns = try GatePatterns.load(from: CloudTestResources.repoRoot.appendingPathComponent("Resources/prompts/gate.json"))
        let gate = try TargetTextGate(config: p.speak.mt.targetGate, patterns: patterns,
                                     identifier: RetryEnglish())
        return FallbackMT(cloud: try speakMT(p), apple: apple, profile: p, gate: gate,
                          glossary: { glossary }, log: log)
    }

    private var retryRequest: SpeakMTRequest {
        SpeakMTRequest(clause: 1, press: 1, job: 301, text: "预算三十万。", target: .en)
    }

    @Test func speakGuardRetryPreparesAppleOnceAndStillPrefersSuccessfulCloud() async throws {
        // Also cover a normal hedge that already started this job's Apple attempt.
        for alreadyHedged in [false, true] {
            FakeServer.reset()
            var p = profile
            p.speak.mt.hedge.afterMs = alreadyHedged ? 20 : 1000
            p.speak.mt.guardRetry.floorMs = 600
            p.speak.mt.guardRetry.maxMs = 600
            FakeServer.enqueue(.A, FakeServer.good("Here is the translation: budget.", at: 80),
                               FakeServer.good("The budget is 300000.", at: 120))
            if alreadyHedged { FakeServer.enqueue(.B, .hang()) }
            FakeServer.enqueue(.B, .hang())
            let apple = RetryApple("The amount is 300000.")
            let translator = try retryFallback(p, apple: apple)
            let result = try await translator.translate(retryRequest)
            guard case let .text(text, backend, warning, hedge) = result else {
                Issue.record("valid cloud retry must win"); continue
            }
            #expect(text == "The budget is 300000." && backend == .openAI && warning == nil)
            #expect(hedge?.reason == .guardRetry)
            #expect(apple.snapshot.starts == 1 && apple.snapshot.completions == 1)
            #expect(FakeServer.requests(.A).count == 2)
            #expect(FakeServer.requests(.B).count == (alreadyHedged ? 2 : 1))
        }
    }

    @Test func speakGuardRetryPreparedAppleStillPassesTextNumberAndTermChecks() async throws {
        let outputs: [(String, String?)] = [
            ("The budget is 300000.", nil),
            ("The budget is 30000.", "number"),
            ("The amount is 300000.", "number"),
            ("Here is the translation: budget.", "gate")
        ]
        for (output, blocked) in outputs {
            FakeServer.reset()
            var p = profile
            p.speak.mt.guardRetry.floorMs = 600
            p.speak.mt.guardRetry.maxMs = 600
            FakeServer.enqueue(.A, FakeServer.good("Here is the translation: budget."),
                               FakeServer.good("Here is the translation: budget.", at: 120))
            FakeServer.enqueue(.B, .hang())
            let events = TalkTalkCore.EventLog(inMemory: HostClock.now)
            let apple = RetryApple(output, log: events)
            let translator = try retryFallback(p, apple: apple, log: events,
                glossary: [.init(zh: "预算", en: "budget", de: "Budget")])
            let result = try await translator.translate(retryRequest)
            switch blocked {
            case "number": #expect(result == .blocked(.numberMismatch))
            case "gate": #expect(result == .blocked(.gateRejected))
            default:
                guard case let .text(text, backend, warning, _) = result else {
                    Issue.record("valid prepared fallback must remain usable"); continue
                }
                #expect(text == output && backend == .apple && warning == nil)
            }
            #expect(apple.snapshot.starts == 1)
            // A causal check: Apple completed before cloud rejection invoked fallback,
            // rather than a wall-time assertion about how fast this machine should be.
            let completed = try #require(events.recorded.first { $0["ev"] as? String == "test.apple_completed" }?["t"] as? HostTime)
            let fallback = try #require(events.recorded.first { $0["ev"] as? String == "mt.fallback" }?["t"] as? HostTime)
            #expect(completed < fallback)
        }
    }

    @Test func speakGuardRetryLateAppleStillWaitsUntilFallback() async throws {
        var p = profile
        p.speak.mt.guardRetry.floorMs = 600
        p.speak.mt.guardRetry.maxMs = 600
        FakeServer.enqueue(.A, FakeServer.good("Here is the translation: budget."),
                           FakeServer.good("Here is the translation: budget.", at: 120))
        FakeServer.enqueue(.B, .hang())
        let events = TalkTalkCore.EventLog(inMemory: HostClock.now)
        let apple = RetryApple("The budget is 300000.", log: events)
        let translator = try retryFallback(p, apple: apple, log: events)
        var request = retryRequest
        request.appleLate = true
        guard case let .text(_, backend, _, _) = try await translator.translate(request) else {
            Issue.record("late fallback must remain usable"); return
        }
        #expect(backend == .apple && apple.snapshot.starts == 1)
        let started = try #require(events.recorded.first { $0["ev"] as? String == "test.apple_started" }?["t"] as? HostTime)
        let fallback = try #require(events.recorded.first { $0["ev"] as? String == "mt.fallback" }?["t"] as? HostTime)
        #expect(started >= fallback)
    }

    @Test func speakGuardRetryPreparedAppleDoesNotReplaceRetainedNumberWarning() async throws {
        var p = profile
        p.speak.mt.guardRetry.floorMs = 100
        p.speak.mt.guardRetry.maxMs = 100
        FakeServer.enqueue(.A, FakeServer.good("The budget is 30000."), .hang())
        FakeServer.enqueue(.B, .hang())
        let apple = RetryApple("The budget is 300000.")
        let translator = try retryFallback(p, apple: apple)
        guard case let .text(text, backend, warning, _) = try await translator.translate(retryRequest) else {
            Issue.record("failed number retry must retain the original cloud result"); return
        }
        #expect(text == "The budget is 30000." && backend == .openAI && warning == "三十万")
        #expect(apple.snapshot.starts == 1 && apple.snapshot.completions == 1)
    }

    @Test func cancellingGuardRetryStopsPreparedAppleAndDoesNotLeakIntoNextJob() async throws {
        var p = profile
        p.speak.mt.guardRetry.floorMs = 5000
        p.speak.mt.guardRetry.maxMs = 5000
        FakeServer.enqueue(.A, FakeServer.good("Here is the translation: budget."), .hang())
        FakeServer.enqueue(.B, .hang())
        let apple = RetryApple("unused", waits: true)
        let translator = try retryFallback(p, apple: apple)
        let request = retryRequest
        let task = Task { try await translator.translate(request) }
        let started = await eventually {
            apple.snapshot.starts == 1 && FakeServer.requests(.A).count == 2 && FakeServer.requests(.B).count == 1
        }
        #expect(started)
        await translator.cancel(request.job)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(apple.snapshot.starts == 1 && apple.snapshot.completions == 0)
        #expect(apple.snapshot.cancelledJobs.contains(request.job))
        let retryA = try #require(FakeServer.requests(.A).last?.clientRequestID)
        let retryB = try #require(FakeServer.requests(.B).last?.clientRequestID)
        #expect(await eventually { FakeServer.wasStopped(retryA) && FakeServer.wasStopped(retryB) })

        FakeServer.enqueue(.A, FakeServer.good("The budget is 300000."))
        let next = SpeakMTRequest(clause: 2, press: 2, job: 302, text: request.text, target: .en)
        guard case let .text(text, backend, _, _) = try await translator.translate(next) else {
            Issue.record("next job must be independent of the cancelled retry"); return
        }
        #expect(text == "The budget is 300000." && backend == .openAI)
        #expect(apple.snapshot.starts == 1 && apple.snapshot.completions == 0)
    }
}

private struct RetryEnglish: LanguageIdentifying {
    func identify(_ text: String) -> (Lang, Double)? { (.en, 1) }
}

private final class RetryApple: MTEngine, Sendable {
    struct State: Sendable {
        var starts = 0, completions = 0
        var cancelledJobs: [JobID] = []
    }
    let id = EngineID(name: "retry-test-apple", revision: "1", placement: .systemService)
    private let state = Mutex(State())
    private let text: String
    private let waits: Bool
    private let log: TalkTalkCore.EventLog?
    var snapshot: State { state.withLock { $0 } }

    init(_ text: String, waits: Bool = false, log: TalkTalkCore.EventLog? = nil) {
        self.text = text; self.waits = waits; self.log = log
    }

    func translate(_ request: MTRequest) async throws -> MTResult {
        state.withLock { $0.starts += 1 }
        log?.event("test.apple_started")
        if waits { try await Task.sleep(for: .seconds(60)) }
        try Task.checkCancellation()
        state.withLock { $0.completions += 1 }
        log?.event("test.apple_completed")
        let now = HostClock.now()
        return MTResult(text: text, tokens: 0, reasoningTokens: 0, engine: id,
                        hedge: .init(fired: false, winner: .apple, reason: nil, ms: 0),
                        timing: .init(received: now, started: now, firstOutput: now, finished: now))
    }

    func cancel(_ job: JobID) async { state.withLock { $0.cancelledJobs.append(job) } }
    func setContext(_ session: MTSession, glossary: [GlossaryEntry]) async throws {}
}
