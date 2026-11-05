import Foundation
import Testing
import TalkTalkCore
@testable import TalkTalkCloud

extension FakeServerCloudTests {
    func speakMT(_ profile: PolicyProfile) throws -> OpenAIMT {
        let patterns = try GatePatterns.load(from: CloudTestResources.repoRoot.appendingPathComponent("Resources/prompts/gate.json"))
        return OpenAIMT(client: client(), profile: profile, prompts: try CloudTestResources.prompts(),
                        configuration: .init(model: "gpt-6-luna", effort: "none"),
                        gate: try TargetTextGate(config: profile.speak.mt.targetGate, patterns: patterns))
    }

    func speakRequest(_ job: JobID = 100) -> MTRequest {
        MTRequest(job: job, session: .speakZhEn, text: "预算三十万。", isFinalChunk: true,
                  priority: .p1Speak, maxOutputTokens: 48)
    }

    @Test func speakKeyDownSchedulesBothWarmConnectionsAndStopCancelsThem() async throws {
        FakeServer.enqueue(.A, .hang())
        FakeServer.enqueue(.B, .hang())
        let engine = try speakMT(profile)
        await engine.startKeepWarm(isEnabled: { true }, warmB: { true })
        await engine.keyDown() // returns while GETs are still pending
        #expect(await eventually { FakeServer.requests(.A).count == 1 && FakeServer.requests(.B).count == 1 })
        await engine.stopKeepWarm()
        #expect(await eventually { FakeServer.stopped(.A) == 1 && FakeServer.stopped(.B) == 1 })
    }

    @Test func speakHedgeStartsAppleBeforeDeadline() async throws {
        var p = profile
        p.speak.mt.hedge.afterMs = 80
        p.speak.mt.totalDeadlineMs = 500
        FakeServer.enqueue(.A, .hang())
        FakeServer.enqueue(.B, FakeServer.good("The budget is 300000."))
        let appleStarts = Counter()
        let result = try await speakMT(p).translate(speakRequest(), speak: .init(
            precedingAudioMs: 0, maskedMs: 0, ttsFirstChunkP95Ms: 400,
            onStartApple: { appleStarts.bump() }))
        #expect(result.hedge.winner == .B && result.hedge.fired)
        #expect(appleStarts.value == 1)
        #expect(FakeServer.requests(.B).count == 1)
        #expect(await eventually { FakeServer.stopped(.A) == 1 })
    }

    @Test func speakDrainExtendsDeadlineAndMaskedNumberCheckUsesRetryBudget() async throws {
        var p = profile
        p.speak.mt.totalDeadlineMs = 80
        p.speak.mt.extendToDrain.marginMs = 0
        p.speak.mt.extendToDrain.maxDeadlineMs = 400
        p.speak.mt.hedge.enabled = false
        // Without drain extension this arrives after the 80 ms deadline.
        FakeServer.enqueue(.A, FakeServer.good("The budget is 300000.", at: 130))
        let engine = try speakMT(p)
        let context = SpeakCloudContext(precedingAudioMs: 900, maskedMs: 1600,
                                        ttsFirstChunkP95Ms: 100, onStartApple: {})
        #expect(try await engine.translate(speakRequest(), speak: context).text == "The budget is 300000.")

        p.speak.mt.guardRetry.floorMs = 60
        p.speak.mt.guardRetry.maxMs = 400
        // Missing a number is not a hard mismatch. maskedMs must cause the retry; drain
        // gives that retry enough time for this response, independently of the first deadline.
        FakeServer.enqueue(.A, FakeServer.good("The budget is ready."), FakeServer.good("The budget is 300000.", at: 130))
        FakeServer.enqueue(.B, .hang())
        let retried = try await speakMT(p).translate(speakRequest(101), speak: context)
        #expect(retried.text == "The budget is 300000.")
        #expect(retried.hedge.reason == .guardRetry)
        #expect(FakeServer.requests(.A).count == 3)
    }

    @Test func speakFailedNumberRetryRetainsTheFirstTranslation() async throws {
        var p = profile
        p.speak.mt.guardRetry.floorMs = 70
        p.speak.mt.guardRetry.maxMs = 70
        // Receiving response.completed cancels this successful stream too. Keep HTTP EOF
        // pending so that cleanup is deterministic instead of racing the default 1 ms EOF.
        FakeServer.enqueue(.A, .sse([(5, FakeServer.created()), (15, FakeServer.delta("The budget is 30000.")),
                                    (25, FakeServer.completed())], finishAtMs: 5000), .hang())
        FakeServer.enqueue(.B, .hang())
        let result = try await speakMT(p).translate(speakRequest(), speak: .init(
            precedingAudioMs: 0, maskedMs: 0, ttsFirstChunkP95Ms: 400, onStartApple: {}))
        #expect(result.text == "The budget is 30000.")
        let a = FakeServer.requests(.A), b = FakeServer.requests(.B)
        #expect(a.count == 2 && b.count == 1)
        let completedA = try #require(a.first?.clientRequestID)
        let retryA = try #require(a.last?.clientRequestID)
        let retryB = try #require(b.first?.clientRequestID)
        #expect(await eventually { FakeServer.wasStopped(retryA) && FakeServer.wasStopped(retryB) })
        #expect(await eventually { FakeServer.wasStopped(completedA) })
    }
}
