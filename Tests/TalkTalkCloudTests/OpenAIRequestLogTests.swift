import Foundation
import Testing
import TalkTalkCore
@testable import TalkTalkCloud

// Per-request timing and Fast mode. An extension of FakeServerCloudTests so it runs
// serialized with the other fake-server tests (the script queue is global).

extension FakeServerCloudTests {
    private func fastEngine(_ log: TalkTalkCore.EventLog) -> OpenAIMT {
        let c = OpenAIClient(cloud: profile.cloud, keyProvider: { fakeKey },
                             protocolClasses: [.A: [FakeA.self], .B: [FakeB.self]], sink: OpenAIMT.eventSink(log))
        return OpenAIMT(client: c, profile: profile, prompts: try! CloudTestResources.prompts(),
                        configuration: .init(model: "gpt-6-luna", effort: "none", fastMode: true), log: log)
    }

    private func openingEngine(_ log: TalkTalkCore.EventLog, seconds: Int) -> OpenAIMT {
        var p = profile
        p.listen.finalMT.openingDoubleSendS = seconds
        let c = OpenAIClient(cloud: p.cloud, keyProvider: { fakeKey },
                             protocolClasses: [.A: [FakeA.self], .B: [FakeB.self]], sink: OpenAIMT.eventSink(log))
        return OpenAIMT(client: c, profile: p, prompts: try! CloudTestResources.prompts(),
                        configuration: .init(model: "gpt-6-luna", effort: "none"), log: log)
    }

    @Test func theOpeningSendsOnBothLegsAndAStalledLegDoesNotRebuild() async throws {
        FakeServer.enqueue(.A, .hang(headersAtMs: nil), .hang(headersAtMs: nil), .hang(headersAtMs: nil))
        FakeServer.enqueue(.B, FakeServer.good("一。"), FakeServer.good("二。"), FakeServer.good("三。"))
        let log = TalkTalkCore.EventLog(inMemory: HostClock.now)
        let engine = openingEngine(log, seconds: 45)
        for (job, text) in ["一。", "二。", "三。"].enumerated() {
            #expect(try await engine.translate(listenRequest(JobID(job + 1))).text == text)
        }
        #expect(FakeServer.requests(.B).count == 3)
        #expect(requestRows(log).filter { $0["leg"] as? String == "B" && $0["won"] as? Bool == true }.count == 3)
        #expect(!names(log).contains("cloud.session_reset"))
    }

    @Test func afterTheOpeningOnlyTheFirstLegIsUsed() async throws {
        FakeServer.enqueue(.A, FakeServer.good("一。"), FakeServer.good("二。"))
        FakeServer.enqueue(.B, .hang(headersAtMs: nil))
        let engine = openingEngine(TalkTalkCore.EventLog(inMemory: HostClock.now), seconds: 1)
        _ = try await engine.translate(listenRequest(1))
        #expect(FakeServer.requests(.B).count == 1)
        try await Task.sleep(for: .milliseconds(1100))
        _ = try await engine.translate(listenRequest(2))
        #expect(FakeServer.requests(.B).count == 1 && FakeServer.requests(.A).count == 2)
    }

    @Test func twoOpeningSentencesWithNoHeadersOnEitherLegStillRebuild() async throws {
        FakeServer.enqueue(.A, .hang(headersAtMs: nil), .hang(headersAtMs: nil))
        FakeServer.enqueue(.B, .hang(headersAtMs: nil), .hang(headersAtMs: nil))
        let log = TalkTalkCore.EventLog(inMemory: HostClock.now)
        let engine = openingEngine(log, seconds: 45)
        for job in 1...2 {
            await #expect(throws: MTError.cloudUnavailable("deadline")) {
                try await engine.translate(listenRequest(JobID(job), deadlineMs: 60))
            }
        }
        #expect(names(log).contains("cloud.session_reset"))
    }

    @Test func anOpeningSentenceAnsweredPromptlyBreaksTheNoHeadersStreak() async throws {
        FakeServer.enqueue(.A, .hang(headersAtMs: nil), FakeServer.good("中。"), .hang(headersAtMs: nil))
        FakeServer.enqueue(.B, .hang(headersAtMs: nil), .hang(headersAtMs: nil), .hang(headersAtMs: nil))
        let log = TalkTalkCore.EventLog(inMemory: HostClock.now)
        let engine = openingEngine(log, seconds: 45)
        await #expect(throws: MTError.cloudUnavailable("deadline")) { try await engine.translate(listenRequest(1, deadlineMs: 60)) }
        #expect(try await engine.translate(listenRequest(2, deadlineMs: 1500)).text == "中。")
        await #expect(throws: MTError.cloudUnavailable("deadline")) { try await engine.translate(listenRequest(3, deadlineMs: 60)) }
        #expect(!names(log).contains("cloud.session_reset"))
    }

    private func replyRequest(_ job: Int, replyInMs: Int) -> MTRequest {
        var request = listenRequest(JobID(job), deadlineMs: 2000)
        request.replyBy = HostClock.now() + UInt64(replyInMs) * 1_000_000
        return request
    }

    @Test func requestsNobodyAnswersStopAtTheReplyTimeAndAreNotBookedAsTimeouts() async throws {
        for _ in 1...6 { FakeServer.enqueue(.A, .hang(headersAtMs: nil)) }
        let log = TalkTalkCore.EventLog(inMemory: HostClock.now)
        let engine = mt(client(), log: log)
        for job in 1...6 {
            await #expect(throws: MTError.cloudUnavailable("deadline")) { try await engine.translate(replyRequest(job, replyInMs: 30)) }
        }
        #expect(!names(log).contains("cloud.breaker") && !names(log).contains("cloud.session_reset"))
    }

    @Test func aRequestThatIsAnsweringOutlivesTheReplyTime() async throws {
        FakeServer.enqueue(.A, .sse([(5, FakeServer.created(tier: "default")), (150, FakeServer.delta("等等就到。")),
                                     (170, FakeServer.completed(tier: "default"))]))
        let engine = mt(client(), log: TalkTalkCore.EventLog(inMemory: HostClock.now))
        #expect(try await engine.translate(replyRequest(1, replyInMs: 60)).text == "等等就到。")
    }

    private func requestRows(_ log: TalkTalkCore.EventLog) -> [[String: Any]] {
        log.recorded.filter { $0["ev"] as? String == "mt.request" }
    }

    private func reply(_ text: String, tier: String) -> FakeServer.Script {
        .sse([(5, FakeServer.created(tier: tier)), (15, FakeServer.delta(text)), (25, FakeServer.completed(tier: tier))])
    }

    @Test func aFinishedRequestLogsItsTimingAsNumbersOnly() async throws {
        FakeServer.enqueue(.A, FakeServer.good("我们下周三发布。"))
        let log = TalkTalkCore.EventLog(inMemory: HostClock.now)
        let c = OpenAIClient(cloud: profile.cloud, keyProvider: { fakeKey },
                             protocolClasses: [.A: [FakeA.self], .B: [FakeB.self]], sink: OpenAIMT.eventSink(log))
        _ = try await mt(c, log: log).translate(listenRequest(1))

        let row = try #require(requestRows(log).first)
        #expect(row["leg"] as? String == "A" && row["tier"] as? String == "default" && row["tier_echo"] as? String == "default")
        #expect(row["won"] as? Bool == true && row["cancelled"] as? Bool == false)
        for name in ["sent_ms", "headers_ms", "first_delta_ms", "end_ms", "elapsed_ms", "output_tokens"] { #expect(row[name] is Int, "\(name)") }

        let sent = try #require(log.recorded.first { $0["ev"] as? String == "cloud.request" })
        #expect(sent["kind"] as? String == "responses" && sent["key_read_ms"] is Double && sent["req"] as? String == row["req"] as? String)

        let rendered = log.recorded.map { String(describing: $0) }.joined(separator: "\n")
        #expect(!rendered.contains(fakeKey) && !rendered.contains("我们下周三发布") && !rendered.contains("next Wednesday"))
    }

    @Test func aRequestAbandonedAtTheDeadlineStillLogsHowFarItGot() async throws {
        FakeServer.enqueue(.A, .hang())
        let log = TalkTalkCore.EventLog(inMemory: HostClock.now)
        let engine = mt(client(), log: log)
        let task = Task { try await engine.translate(listenRequest(7)) }
        try? await Task.sleep(for: .milliseconds(80))
        await engine.cancel(7)
        await #expect(throws: CancellationError.self) { try await task.value }

        let row = try #require(requestRows(log).first)
        #expect(row["job"] as? Int == 7 && row["cancelled"] as? Bool == true && row["won"] as? Bool == false)
        #expect(row["headers_ms"] is Int && row["first_delta_ms"] == nil && row["end_ms"] == nil)
    }

    @Test func anAbandonedFastRequestStillLogsTheTierTheServerNamed() async throws {
        FakeServer.enqueue(.A, .sse([(5, FakeServer.created(tier: "fast"))], finishAtMs: 60_000))
        let log = TalkTalkCore.EventLog(inMemory: HostClock.now)
        let engine = fastEngine(log)
        let task = Task { try await engine.translate(listenRequest(7)) }
        try? await Task.sleep(for: .milliseconds(80))
        await engine.cancel(7)
        await #expect(throws: CancellationError.self) { try await task.value }

        let row = try #require(requestRows(log).first)
        #expect(row["cancelled"] as? Bool == true && row["tier"] as? String == "fast" && row["tier_echo"] as? String == "fast")
    }

    @Test func connectionMetricsAreLoggedWithSafeTags() throws {
        let log = TalkTalkCore.EventLog(inMemory: HostClock.now)
        var metrics = RequestMetrics(leg: .B, protocolName: "http/1.1", reusedConnection: false, connectMs: 33.5, fetchToRequestMs: 70)
        metrics.clientRequestID = "abc-123"
        OpenAIMT.eventSink(log)(.metrics(metrics))
        let row = try #require(log.recorded.first)
        #expect(row["ev"] as? String == "cloud.metrics" && row["req"] as? String == "abc-123")
        #expect(row["protocol"] as? String == "http_1.1" && row["reused"] as? Bool == false)
        #expect(row["connect_ms"] as? Double == 33.5 && row["fetch_to_request_ms"] as? Double == 70)
        #expect(row["tls_ms"] == nil)
    }

    @Test func fastModeAsksEverySentenceAndLogsEachEchoedTier() async throws {
        FakeServer.enqueue(.A, reply("一。", tier: "fast"), reply("二。", tier: "priority"), reply("三。", tier: "default"))
        let log = TalkTalkCore.EventLog(inMemory: HostClock.now)
        let engine = fastEngine(log)
        for job in 1...3 { _ = try await engine.translate(listenRequest(JobID(job))) }
        #expect(requestRows(log).map { $0["tier"] as? String } == ["fast", "fast", "fast"])
        #expect(requestRows(log).map { $0["tier_echo"] as? String } == ["fast", "priority", "default"])
    }

    @Test func aDowngradedFastRequestIsStillAGoodTranslation() async throws {
        FakeServer.enqueue(.A, reply("降级了也能用。", tier: "default"))
        let log = TalkTalkCore.EventLog(inMemory: HostClock.now)
        let result = try await fastEngine(log).translate(listenRequest(1))
        #expect(result.text == "降级了也能用。")
    }

    @Test func aRefusedFastRequestCostsOneSentenceAndDoesNotPauseTheCloud() async throws {
        FakeServer.enqueue(.A, .json(403, #"{"error":{"code":"tier_not_allowed","type":"invalid_request_error","message":"no"}}"#),
                           reply("普通档还能用。", tier: "default"), reply("还是普通档。", tier: "default"))
        let log = TalkTalkCore.EventLog(inMemory: HostClock.now)
        let engine = fastEngine(log)
        await #expect(throws: MTError.cloudUnavailable("allFailed")) { try await engine.translate(listenRequest(1)) }
        #expect(try await engine.translate(listenRequest(2)).text == "普通档还能用。")
        #expect(try await engine.translate(listenRequest(3)).text == "还是普通档。")
        #expect(requestRows(log).map { $0["tier"] as? String } == ["fast", "default", "default"])
        #expect(names(log).filter { $0 == "mt.fast_off" }.count == 1)
    }

    @Test func aBadKeyOnAFastRequestStillPausesTheCloud() async throws {
        FakeServer.enqueue(.A, .json(401, #"{"error":{"code":"invalid_api_key","type":"invalid_request_error","message":"no"}}"#))
        let log = TalkTalkCore.EventLog(inMemory: HostClock.now)
        let engine = fastEngine(log)
        await #expect(throws: MTError.cloudUnavailable("paused:http401")) { try await engine.translate(listenRequest(1)) }
        #expect(!names(log).contains("mt.fast_off"))
    }

    @Test func anUnexpectedEchoTurnsFastModeOffWithoutTrippingTheBreaker() async throws {
        FakeServer.enqueue(.A, reply("奇怪的档位。", tier: "flex"), reply("正常。", tier: "default"))
        let log = TalkTalkCore.EventLog(inMemory: HostClock.now)
        let engine = fastEngine(log)
        await #expect(throws: (any Error).self) { try await engine.translate(listenRequest(1)) }
        #expect(try await engine.translate(listenRequest(2)).text == "正常。")
        #expect(names(log).contains("mt.fast_off"))
    }

    @Test func withFastModeOffEveryRequestUsesTheProfileTier() async throws {
        FakeServer.enqueue(.A, FakeServer.good("一。"), FakeServer.good("二。"))
        let log = TalkTalkCore.EventLog(inMemory: HostClock.now)
        let engine = mt(client(), log: log)
        for job in 1...2 { _ = try await engine.translate(listenRequest(JobID(job))) }
        #expect(requestRows(log).map { $0["tier"] as? String } == ["default", "default"])
    }
}
