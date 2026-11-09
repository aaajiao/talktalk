import Foundation
import Synchronization
import Testing
import TalkTalkCore
@testable import TalkTalkCloud

let fakeKey = "sk-proj-" + String(repeating: "Q", count: 150) + "fAkE"
private let sourceText = "我们下周三之前修好。"

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

@Suite struct SSEParserTests {
    @Test func parsesFieldsCommentsAndLineEndings() {
        var p = SSEParser()
        let raw = ": keep-alive\r\nevent: a\r\ndata: one\r\ndata: two\r\n\r\nevent: b\ndata:x\n\ndata: tail"
        var events = p.feed(Array(raw.utf8))
        if let last = p.finish() { events.append(last) }
        #expect(events == [SSEEvent(event: "a", data: "one\ntwo"), SSEEvent(event: "b", data: "x"), SSEEvent(event: nil, data: "tail")])
    }

    @Test func byteAtATimeEqualsWhole() {
        let raw = FakeServer.created() + FakeServer.delta("Hi.\n") + FakeServer.completed()
        var a = SSEParser(), b = SSEParser()
        let whole = a.feed(Array(raw.utf8))
        var single: [SSEEvent] = []
        for byte in raw.utf8 { if let e = b.feed(byte: byte) { single.append(e) } }
        #expect(whole == single)
        #expect(whole.count == 3)
    }

    @Test func accumulatorValidatesAndCutsFirstLine() throws {
        let cloud = try CloudTestResources.profile().cloud
        var acc = ResponseAccumulator()
        var p = SSEParser()
        var signals: [ResponseAccumulator.Signal] = []
        for e in p.feed(Array((FakeServer.created() + FakeServer.delta("We fix it.\nNote: x") + FakeServer.completed()).utf8)) {
            signals += acc.consume(e)
        }
        #expect(signals == [.progress, .delta, .firstLineComplete, .terminal])
        #expect(acc.firstLine.trimmed == "We fix it.")
        let (r, v) = acc.terminalResult(sentEffort: "none", cloud: cloud)
        #expect(r == .valid)
        #expect(v?.storeEchoMissing == false)
        // store echo missing: still valid, only flagged.
        var acc2 = ResponseAccumulator()
        for e in p.feed(Array((FakeServer.delta("Ok.") + FakeServer.completed(store: nil)).utf8)) { _ = acc2.consume(e) }
        let (r2, v2) = acc2.terminalResult(sentEffort: "none", cloud: cloud)
        #expect(r2 == .valid)
        #expect(v2?.storeEchoMissing == true)
        // store:true echoed: rejected.
        var acc3 = ResponseAccumulator()
        for e in p.feed(Array((FakeServer.delta("Ok.") + FakeServer.completed(store: true)).utf8)) { _ = acc3.consume(e) }
        #expect(acc3.terminalResult(sentEffort: "none", cloud: cloud).0 == .failed(.validationReject("store:true")))
    }
}

/// Everything that talks to the URLProtocol fake. Serialized: the fake's script queue is global.
@Suite(.serialized) struct FakeServerCloudTests {
    let profile: PolicyProfile
    let policy: HedgePolicy
    let log = EventLog()
    let body: Data

    init() throws {
        FakeServer.reset()
        profile = try CloudTestResources.profile()
        // The §5.3 numbers scaled down so a run takes well under a second.
        var p = profile.speakHedgePolicy
        p.hedge.afterMs = 150
        p.hedge.stallAfterDeltaMs = 150
        p.hedge.failAfterDeltaMinRemainMs = 200
        p.totalDeadlineMs = 700
        policy = p
        let builder = OpenAIRequestBuilder(cloud: profile.cloud, prompts: try CloudTestResources.prompts())
        body = try builder.body(for: MTRequest(job: 1, session: .speakZhEn, text: sourceText, isFinalChunk: true,
                                               priority: .p1Speak, maxOutputTokens: 48),
                                glossary: [], options: .init(model: "gpt-6-luna", effort: "none", contextTokensSoft: 300, contextTokensHard: 800))
    }

    func client(key: String? = fakeKey) -> OpenAIClient {
        OpenAIClient(cloud: profile.cloud,
                     keyProvider: { guard let key else { throw KeychainLike.missing }; return key },
                     protocolClasses: [.A: [FakeA.self], .B: [FakeB.self]], sink: log.sink)
    }
    enum KeychainLike: Error { case missing }

    func hedger(_ c: OpenAIClient) -> HedgedRequest {
        HedgedRequest(client: c, policy: policy, afterNewlineGraceMs: 100, sink: log.sink)
    }

    func run(_ c: OpenAIClient, appleStarts: Counter? = nil) async -> HedgedRequest.Outcome {
        await hedger(c).run(body: body, sentEffort: "none", deadlineMs: policy.totalDeadlineMs,
                            onStartApple: { appleStarts?.bump() })
    }

    func eventually(_ ms: Int = 1000, _ cond: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + .milliseconds(ms)
        while ContinuousClock.now < end { if cond() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return cond()
    }

    // MARK: hedging

    @Test func fastPrimaryWinsAndBIsNeverSent() async {
        FakeServer.enqueue(.A, FakeServer.good("We will fix it by next Wednesday."))
        let out = await run(client())
        #expect(out.decision.outcome.winner == .A)
        #expect(out.decision.outcome.fired == false)
        #expect(out.text == "We will fix it by next Wednesday.")
        #expect(FakeServer.requests(.A).count == 1)
        #expect(FakeServer.requests(.B).isEmpty)
        let r = FakeServer.requests(.A)[0]
        #expect(r.method == "POST" && r.path == "/v1/responses")
        #expect(r.authorization == "Bearer " + fakeKey)
        #expect(r.clientRequestID?.isEmpty == false)
        #expect(out.legs[.A]?.firstDeltaMs != nil)
    }

    @Test func noDeltaHedgeBWinsAndLateAIsIgnored() async {
        // A only answers at 400 ms (after hedge time 150 ms); B answers fast.
        FakeServer.enqueue(.A, FakeServer.good("late", at: 400))
        FakeServer.enqueue(.B, FakeServer.good("We will fix it."))
        let apple = Counter()
        let out = await run(client(), appleStarts: apple)
        #expect(out.decision.outcome.fired)
        #expect(out.decision.outcome.reason == .noDelta)
        #expect(out.decision.outcome.winner == .B)
        #expect(out.text == "We will fix it.")
        #expect(out.legs[.A]?.cancelled == true)
        #expect(out.legs[.B]?.sentMs.map { $0 >= 140 } == true)
        #expect(apple.value == 1)   // startAppleAtHedge
        #expect(await eventually { FakeServer.stopped(.A) == 1 })
        // Each attempt had its own X-Client-Request-Id.
        let ids = FakeServer.requests().compactMap(\.clientRequestID)
        #expect(Set(ids).count == 2)
    }

    @Test func stallAfterDeltaHedges() async {
        FakeServer.enqueue(.A, .sse([(5, FakeServer.created()), (20, FakeServer.delta("We "))], finishAtMs: 5000))
        FakeServer.enqueue(.B, FakeServer.good("We will."))
        let out = await run(client())
        #expect(out.decision.outcome.reason == .stall)
        #expect(out.decision.outcome.winner == .B)
    }

    @Test func invalidPrimaryFastFailsToB() async {
        // Effort echo mismatch, no delta → reject before any text → fast-fail hedge.
        FakeServer.enqueue(.A, .sse([(5, FakeServer.created(effort: "low")), (15, FakeServer.completed(effort: "low"))]))
        FakeServer.enqueue(.B, FakeServer.good("We will fix it."))
        let out = await run(client())
        #expect(out.decision.outcome.reason == .fastFail)
        #expect(out.decision.outcome.winner == .B)
        #expect(out.legs[.A]?.validation?.rejectReason == "effort:low")
        #expect(out.decision.breakerFailure == false)
    }

    @Test func failureAfterDeltaHedgesAndStartsApple() async {
        FakeServer.enqueue(.A, FakeServer.good("x", effort: "low"))   // a delta, then a reject
        FakeServer.enqueue(.B, FakeServer.good("We will fix it."))
        let apple = Counter()
        let out = await run(client(), appleStarts: apple)
        #expect(out.decision.outcome.reason == .failAfterDelta)
        #expect(out.decision.outcome.winner == .B)
        #expect(apple.value == 1)
    }

    @Test func rateLimitOnBPausesHedgingButLeavesBreakerClosed() async {
        FakeServer.enqueue(.A, FakeServer.good("We will fix it.", at: 300))
        FakeServer.enqueue(.B, .json(429, #"{"error":{"code":null,"type":"requests","message":"secret text"}}"#, headers: ["Retry-After": "45"]))
        let out = await run(client())
        #expect(out.decision.outcome.winner == .A)
        #expect(out.hedgePauseS == 45)
        #expect(out.decision.primaryRateLimited == false)
        var health = CloudHealth(cloud: profile.cloud)
        _ = health.gate(.speak, now: 0)
        health.record(.speak, decision: out.decision, hedgePauseS: out.hedgePauseS, now: 0)
        #expect(health.shared.state == .closed)
        #expect(health.hedgingPaused(now: 44_000))
        #expect(!health.hedgingPaused(now: 45_000))
        #expect(health.gate(.speak, now: 1000) == .cloud(probe: false))
    }

    @Test func primaryRateLimitOpensBreakerHonouringRetryAfter() async {
        FakeServer.enqueue(.A, .json(429, #"{"error":{"code":null,"type":"tokens"}}"#, headers: ["Retry-After": "120"]))
        let out = await run(client())
        #expect(out.decision.outcome.winner == .apple)
        #expect(out.decision.fallback == .allFailed)
        #expect(out.decision.primaryRateLimited)
        #expect(out.decision.retryAfterS == 120)
        #expect(FakeServer.requests(.B).isEmpty)   // a 429 never triggers B
        var health = CloudHealth(cloud: profile.cloud)
        _ = health.gate(.speak, now: 0)
        health.record(.speak, decision: out.decision, hedgePauseS: nil, now: 0)
        #expect(health.gate(.speak, now: 60_000) == .apple("breakerOpen"))
        #expect(health.gate(.listen, now: 60_000) == .apple("breakerOpen"))
        #expect(health.gate(.speak, now: 120_000) == .cloud(probe: true))
    }

    @Test func bothPastDeadlineFallBackToAppleAndCountAsTimeout() async {
        FakeServer.enqueue(.A, .hang())
        FakeServer.enqueue(.B, .hang())
        let apple = Counter()
        let start = ContinuousClock.now
        let out = await run(client(), appleStarts: apple)
        let elapsed = (ContinuousClock.now - start) / .milliseconds(1)
        #expect(out.decision.outcome.winner == .apple)
        #expect(out.decision.fallback == .deadline)
        #expect(out.decision.timedOut)
        #expect(!out.decision.breakerFailure)
        #expect(elapsed >= 690 && elapsed < 1200)
        #expect(apple.value == 1)
        #expect(await eventually { FakeServer.stopped(.A) == 1 && FakeServer.stopped(.B) == 1 })
        // Timeouts go to the per-direction timeout breaker, never the shared one.
        var health = CloudHealth(cloud: profile.cloud)
        for i in 0..<profile.cloud.timeoutBreaker.timeoutsToOpen {
            #expect(health.gate(.speak, now: i) == .cloud(probe: false))
            health.record(.speak, decision: out.decision, hedgePauseS: nil, now: i)
        }
        #expect(health.shared.state == .closed)
        #expect(health.gate(.speak, now: 100) == .apple("timeoutBreakerOpen"))
        #expect(health.gate(.listen, now: 100) == .cloud(probe: false))
    }

    @Test func both5xxCountOnceTowardTheBreaker() async {
        var health = CloudHealth(cloud: profile.cloud)
        for i in 0..<profile.cloud.breaker.failuresToOpen {
            FakeServer.enqueue(.A, .json(503, #"{"error":{"type":"server_error"}}"#))
            FakeServer.enqueue(.B, .json(502, "bad gateway"))
            let out = await run(client())
            #expect(out.decision.outcome.reason == .fastFail)
            #expect(out.decision.fallback == .allFailed)
            #expect(out.decision.breakerFailure)
            #expect(health.gate(.speak, now: i * 1000) == .cloud(probe: false))
            health.record(.speak, decision: out.decision, hedgePauseS: nil, now: i * 1000)
        }
        #expect(FakeServer.requests(.A).count == 3 && FakeServer.requests(.B).count == 3)
        #expect(health.gate(.speak, now: 5000) == .apple("breakerOpen"))
        // After openS one probe goes through; success closes.
        let probeAt = 2000 + profile.cloud.breaker.openS * 1000
        #expect(health.gate(.speak, now: probeAt) == .cloud(probe: true))
        #expect(health.gate(.listen, now: probeAt) == .apple("breakerOpen"))   // only one probe
        FakeServer.enqueue(.A, FakeServer.good("Fine."))
        let ok = await run(client())
        health.record(.speak, decision: ok.decision, hedgePauseS: nil, now: probeAt + 10)
        #expect(health.shared.state == .closed)
    }

    @Test func authAndQuotaErrorsPauseCloud() async {
        FakeServer.enqueue(.A, .json(401, #"{"error":{"code":"invalid_api_key","type":"invalid_request_error","message":"Incorrect API key provided: sk-proj-QQQ"}}"#))
        let out = await run(client())
        #expect(out.decision.pauseReason == "http401")
        #expect(FakeServer.requests(.B).isEmpty)
        var health = CloudHealth(cloud: profile.cloud)
        _ = health.gate(.speak, now: 0)
        health.record(.speak, decision: out.decision, hedgePauseS: nil, now: 0)
        #expect(health.gate(.listen, now: 999_999) == .apple("paused:http401"))
        health.clearPause()
        #expect(health.gate(.listen, now: 999_999) == .cloud(probe: false))

        FakeServer.enqueue(.A, .json(429, #"{"error":{"code":"insufficient_quota","type":"insufficient_quota"}}"#))
        let quota = await run(client())
        #expect(quota.decision.pauseReason == "insufficient_quota")
        #expect(quota.decision.primaryRateLimited == false)
        // The error message never reaches the log.
        #expect(!log.rendered.contains("Incorrect API key"))
    }

    @Test func newlineGraceCutsAndValidatesOnCreatedEcho() async {
        FakeServer.enqueue(.A, .sse([(5, FakeServer.created()), (15, FakeServer.delta("Line one.\nNote: extra"))], finishAtMs: 5000))
        let out = await run(client())
        #expect(out.decision.outcome.winner == .A)
        #expect(out.text == "Line one.")
        #expect(out.legs[.A]?.partialValidation == true)
        #expect(out.legs[.A]?.newlineToEndMs.map { $0 >= 90 && $0 < 400 } == true)
        #expect(await eventually { FakeServer.stopped(.A) == 1 })
    }

    @Test func callerCancelStopsBothLegs() async {
        FakeServer.enqueue(.A, .hang())
        let c = client()
        let h = hedger(c)
        let body = self.body
        let task = Task { await h.run(body: body, sentEffort: "none", deadlineMs: 700) }
        try? await Task.sleep(for: .milliseconds(80))
        task.cancel()
        let out = await task.value
        #expect(out.cancelledByCaller)
        #expect(out.decision.outcome.winner == .apple)
        #expect(await eventually { FakeServer.stopped(.A) == 1 })
        #expect(FakeServer.requests(.B).isEmpty)
    }

    // MARK: key handling

    @Test func noKeyMeansZeroRequests() async {
        let c = client(key: nil)
        let out = await run(c)
        #expect(out.decision.outcome.winner == .apple)
        let kw = KeepWarm(client: c, cloud: profile.cloud, model: "gpt-6-luna", isEnabled: { true }, warmB: { true })
        #expect(await kw.warm(.A) == false)
        await kw.onKeyDown()
        let off = KeepWarm(client: client(), cloud: profile.cloud, model: "gpt-6-luna", isEnabled: { false }, warmB: { true })
        await off.onKeyDown()
        #expect(await off.warm(.B) == false)
        #expect(FakeServer.requests().isEmpty)
        await #expect(throws: OpenAIClient.ClientError.noKey) { try await c.get(leg: .A, path: "/v1/models") }
        #expect(FakeServer.requests().isEmpty)
    }

    @Test func keyAndTextNeverAppearInTheEventLog() async {
        FakeServer.enqueue(.A, FakeServer.good("We will fix it by next Wednesday.", at: 200))
        FakeServer.enqueue(.B, .json(500, #"{"error":{"type":"server_error","message":"echo \#(sourceText)"}}"#))
        _ = await run(client())
        let text = log.rendered
        #expect(!text.isEmpty)
        #expect(!text.contains(fakeKey))
        #expect(!text.contains("Bearer"))
        #expect(!text.contains("fAkE"))
        #expect(!text.contains(sourceText))
        #expect(!text.contains("next Wednesday"))
        #expect(log.events.contains { if case .request(.A, "/v1/responses", _, _) = $0 { true } else { false } })
        #expect(log.events.contains { if case .hedge = $0 { true } else { false } })
    }

    // MARK: sessions, keep-warm, model list

    @Test func rebuildGivesAWorkingFreshSession() async throws {
        let c = client()
        FakeServer.enqueue(.A, .json(200, #"{"id":"gpt-6-luna","object":"model","created":1}"#))
        #expect(try await c.get(leg: .A, path: "/v1/models/gpt-6-luna").headers.status == 200)
        c.rebuild(.A)
        FakeServer.enqueue(.A, .json(200, #"{"id":"gpt-6-luna","object":"model","created":1}"#))
        #expect(try await c.get(leg: .A, path: "/v1/models/gpt-6-luna").headers.status == 200)
        #expect(FakeServer.requests(.A).count == 2)
    }

    @Test func rebuildCancelsInFlightStream() async {
        FakeServer.enqueue(.A, .hang())
        let c = client()
        let h = hedger(c)
        let body = self.body
        let task = Task { await h.run(body: body, sentEffort: "none", deadlineMs: 700) }
        try? await Task.sleep(for: .milliseconds(60))
        c.rebuild(.A)
        let out = await task.value
        // A's stream was cancelled by the rebuild → connection error → fast-fail hedge to B
        // (unscripted → 404) → fall back well before the deadline.
        #expect(out.legs[.A]?.result == .failed(.connectionError))
        #expect(out.decision.outcome.reason == .fastFail)
        #expect(out.decision.outcome.winner == .apple)
        #expect(out.decision.fallback == .allFailed)
    }

    @Test func keepWarmFollowsTheRules() async {
        let warmB = Mutex(false)
        let c = client()
        let kw = KeepWarm(client: c, cloud: profile.cloud, model: "gpt-6-luna", isEnabled: { true },
                          warmB: { warmB.withLock { $0 } }, sink: log.sink)
        let model = #"{"id":"gpt-6-luna","object":"model","created":1}"#
        FakeServer.enqueue(.A, .json(200, model))
        await kw.onKeyDown()                       // never warmed → warm A only
        #expect(FakeServer.requests(.A).map(\.path) == ["/v1/models/gpt-6-luna"])
        #expect(FakeServer.requests(.A).map(\.method) == ["GET"])
        #expect(FakeServer.requests(.B).isEmpty)
        await kw.onKeyDown()                       // fresh and OK → nothing
        #expect(FakeServer.requests().count == 1)
        warmB.withLock { $0 = true }
        FakeServer.enqueue(.B, .json(500, #"{"error":{"type":"server_error"}}"#))
        await kw.onKeyDown()                       // B never warmed → warm B (fails)
        #expect(FakeServer.requests(.B).count == 1)
        #expect(await kw.state(.B).lastWarmOK == false)
        FakeServer.enqueue(.B, .json(200, model))
        await kw.onKeyDown()                       // last B warm failed → again
        #expect(FakeServer.requests(.B).count == 2)
        #expect(await kw.state(.B).lastWarmOK == true)
        await kw.noteReused(.A, false)
        FakeServer.enqueue(.A, .json(200, model))
        await kw.onKeyDown()                       // A's connection was not reused → re-warm A
        #expect(FakeServer.requests(.A).count == 2)
        #expect(log.events.filter { if case .keepWarm = $0 { true } else { false } }.count == 4)
    }

    @Test func modelListGoesThroughTheFilter() async throws {
        let c = client()
        let catalog = OpenAIModelCatalog(client: c, builder: OpenAIRequestBuilder(cloud: profile.cloud, prompts: try CloudTestResources.prompts()))
        FakeServer.enqueue(.A, .json(200, #"{"object":"list","data":[{"id":"gpt-6-luna","object":"model","created":1790000000,"owned_by":"system"},{"id":"gpt-5.5","object":"model","created":1700000000,"owned_by":"system"},{"id":"gpt-6-terra","object":"model","created":1790000001,"owned_by":"system"}]}"#))
        let rows = try await catalog.list()
        #expect(rows.map(\.id) == ["gpt-6-luna", "gpt-5.5", "gpt-6-terra"])
        #expect(FakeServer.requests(.A).last?.path == "/v1/models")
        FakeServer.enqueue(.A, .json(401, #"{"error":{"code":"invalid_api_key","type":"invalid_request_error"}}"#))
        await #expect(throws: OpenAIModelCatalog.CatalogError.self) { try await catalog.list() }
    }

    @Test func probeReportsEchoesWithoutHedging() async throws {
        let c = client()
        let catalog = OpenAIModelCatalog(client: c, builder: OpenAIRequestBuilder(cloud: profile.cloud, prompts: try CloudTestResources.prompts()))
        FakeServer.enqueue(.A, .json(200, #"{"id":"gpt-6-luna","object":"model","created":1}"#))
        FakeServer.enqueue(.A, .sse([(5, FakeServer.created(store: nil)), (15, FakeServer.delta("We fix it by Wednesday.")),
                                     (25, FakeServer.completed(store: nil))]))
        let r = await catalog.probe(model: "gpt-6-luna", basePolicy: profile.speakHedgePolicy)
        #expect(r.accepted)
        #expect(r.storeEchoMissing)
        #expect(r.reasoningTokens == 0)
        #expect(FakeServer.requests(.B).isEmpty)
        FakeServer.enqueue(.A, .json(200, "{}"))
        FakeServer.enqueue(.A, .json(400, #"{"error":{"code":"unsupported_value","type":"invalid_request_error","param":"reasoning.effort"}}"#))
        let bad = await catalog.probe(model: "gpt-6-sol", basePolicy: profile.speakHedgePolicy)
        #expect(!bad.accepted)
        #expect(bad.needsLowEffort)
        #expect(bad.error?.param == "reasoning.effort")
    }
}
