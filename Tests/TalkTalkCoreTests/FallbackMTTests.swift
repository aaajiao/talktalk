import Foundation
import Testing
@testable import TalkTalkCore

struct FallbackMTTests {
    struct English: LanguageIdentifying {
        func identify(_ text: String) -> (Lang, Double)? { (.en, 1) }
    }
    func make(_ cloud: Cloud?, _ apple: Apple, log: EventLog? = nil) throws -> FallbackMT {
        let profile = try TestResources.profile()
        let gate = try TargetTextGate(config: profile.speak.mt.targetGate,
                                     patterns: TestResources.gatePatterns(), identifier: English())
        return FallbackMT(cloud: cloud, apple: apple, profile: profile, gate: gate, log: log)
    }
    let request = SpeakMTRequest(clause: 1, press: 1, job: 1, text: "预算三十万。", target: .en)

    @Test func cloudFailureUsesAppleButBlocksIncorrectNumbersAndMetaText() async throws {
        let log = EventLog(inMemory: HostClock.now)
        for (text, expected) in [
            ("The budget is 300000.", SpeakMTOutcome.text("The budget is 300000.", backend: .apple, numberWarning: nil, hedge: Self.result("", apple: true).hedge)),
            ("The budget is 30000.", .blocked(.numberMismatch)),
            ("Here is the translation: budget.", .blocked(.gateRejected)),
            ("<none>", .text("", backend: .apple, numberWarning: nil, hedge: Self.result("", apple: true).hedge))
        ] {
            let apple = Apple(text)
            let translator = try make(Cloud(.unavailable), apple, log: log)
            #expect(try await translator.translate(request) == expected)
            #expect(await apple.starts == 1)
        }
        let rendered = log.recorded.map { String(describing: $0) }.joined()
        #expect(rendered.contains("mt.fallback"))
        #expect(!rendered.contains(request.text) && !rendered.contains("300000"))
    }

    @Test func cloudWinsWithoutStartingAppleAndKeepsNumberWarning() async throws {
        let apple = Apple("The budget is 300000.")
        let translator = try make(Cloud(.text("The budget is 30000.")), apple)
        guard case let .text(text, backend, warning, _) = try await translator.translate(request) else {
            Issue.record("cloud translation must remain usable with a warning"); return
        }
        #expect(text == "The budget is 30000." && backend == .openAI && warning == "三十万")
        #expect(await apple.starts == 0)
    }

    @Test func conciseAndLateApplePolicyReachTheCloud() async throws {
        let cloud = Cloud(.text("The budget is 300000."))
        let translator = try make(cloud, Apple("unused"))
        var request = request
        request.mode = .concise; request.appleLate = true
        _ = try await translator.translate(request)
        #expect(await cloud.lastMode == .concise)
        #expect(await cloud.lastAppleLate == true)
    }

    @Test func cancellingAfterHedgeStopsBothBackends() async throws {
        let cloud = Cloud(.hedgeThenWait)
        let apple = Apple("", wait: true)
        let translator = try make(cloud, apple)
        let task = Task { try await translator.translate(request) }
        var started = apple.started.makeAsyncIterator()
        _ = await started.next()
        await translator.cancel(request.job)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await cloud.cancels > 0)
        #expect(await apple.cancels > 0)
        #expect(await apple.starts == 1)
    }

    static func result(_ text: String, apple: Bool) -> MTResult {
        MTResult(text: text, tokens: 0, reasoningTokens: 0,
                 engine: EngineID(name: "fake", revision: "1", placement: apple ? .systemService : .network),
                 hedge: .init(fired: false, winner: apple ? .apple : .A, reason: nil, ms: 0),
                 timing: StageTiming(received: 0, started: 0, firstOutput: 0, finished: 0))
    }

    actor Apple: MTEngine {
        nonisolated let id = EngineID(name: "fake-apple", revision: "1", placement: .systemService)
        nonisolated let started: AsyncStream<Void>
        private let signal: AsyncStream<Void>.Continuation
        let text: String
        let wait: Bool
        var starts = 0, cancels = 0
        init(_ text: String, wait: Bool = false) {
            self.text = text; self.wait = wait
            (started, signal) = AsyncStream.makeStream()
        }
        func translate(_ r: MTRequest) async throws -> MTResult {
            starts += 1; signal.yield(())
            if wait { try await Task.sleep(for: .seconds(60)) }
            return FallbackMTTests.result(text, apple: true)
        }
        func cancel(_ job: JobID) { cancels += 1 }
        func setContext(_ session: MTSession, glossary: [GlossaryEntry]) {}
    }

    actor Cloud: SpeakCloudMT {
        enum Mode: Sendable { case unavailable, text(String), hedgeThenWait }
        nonisolated let id = EngineID(name: "fake-cloud", revision: "1", placement: .network)
        let mode: Mode
        var cancels = 0
        var lastMode: MTMode?
        var lastAppleLate: Bool?
        init(_ mode: Mode) { self.mode = mode }
        func translate(_ r: MTRequest, speak: SpeakCloudContext) async throws -> MTResult {
            lastMode = r.mode; lastAppleLate = speak.appleLate
            switch mode {
            case .unavailable: throw MTError.cloudUnavailable("offline")
            case .text(let t): return FallbackMTTests.result(t, apple: false)
            case .hedgeThenWait:
                speak.onStartApple()
                try await Task.sleep(for: .seconds(60))
                throw MTError.cloudUnavailable("deadline")
            }
        }
        func translate(_ r: MTRequest) async throws -> MTResult { throw MTError.cloudUnavailable("unused") }
        func cancel(_ job: JobID) { cancels += 1 }
        func keyDown() {}
        func setContext(_ session: MTSession, glossary: [GlossaryEntry]) {}
    }
}
