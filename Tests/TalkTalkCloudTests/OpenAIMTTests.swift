import Foundation
import Testing
import TalkTalkCore
@testable import TalkTalkCloud

// OpenAIMT (§4.1) against the URLProtocol fake. An extension of FakeServerCloudTests so it runs
// serialized with the other fake-server tests (the script queue is global).

extension FakeServerCloudTests {
    func mt(_ c: OpenAIClient, log: TalkTalkCore.EventLog) -> OpenAIMT {
        OpenAIMT(client: c, profile: profile, prompts: try! CloudTestResources.prompts(),
                 configuration: .init(model: "gpt-6-luna", effort: "none"), log: log)
    }

    func listenRequest(_ job: JobID, deadlineMs: Int = 1500) -> MTRequest {
        MTRequest(job: job, session: .listenEnZh, text: "We will ship it next Wednesday.", isFinalChunk: true,
                  priority: .p2Listen, deadline: HostClock.now() + UInt64(deadlineMs) * 1_000_000, maxOutputTokens: 256)
    }

    func names(_ log: TalkTalkCore.EventLog) -> [String] { log.recorded.compactMap { $0["ev"] as? String } }

    func reason(_ e: any Error) -> String? {
        if case let .cloudUnavailable(r)? = e as? MTError { return r }
        return nil
    }

    @Test func listenUsesAOnlyAndReturnsNetworkResult() async throws {
        FakeServer.enqueue(.A, FakeServer.good("我们下周三发布。"))
        let log = TalkTalkCore.EventLog(inMemory: HostClock.now)
        let r = try await mt(client(), log: log).translate(listenRequest(1))
        #expect(r.text == "我们下周三发布。")
        #expect(r.engine.placement == .network && r.engine.name == "openai" && r.engine.revision == "gpt-6-luna")
        #expect(r.hedge.winner == .A && !r.hedge.fired)
        #expect(FakeServer.requests(.A).count == 1)
        #expect(FakeServer.requests(.B).isEmpty)             // listen.finalMT.hedge is off
    }

    @Test func cancelBeforeDeadlineStopsTheStream() async {
        FakeServer.enqueue(.A, .hang())
        let log = TalkTalkCore.EventLog(inMemory: HostClock.now)
        let engine = mt(client(), log: log)
        let req = listenRequest(7, deadlineMs: 1500)
        let task = Task { try await engine.translate(req) }
        try? await Task.sleep(for: .milliseconds(80))
        await engine.cancel(7)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await eventually { FakeServer.stopped(.A) == 1 })
        #expect(FakeServer.requests(.B).isEmpty)
        #expect(names(log).contains("mt.cancelled"))
    }

    @Test func taskCancellationAlsoStopsTheStream() async {
        FakeServer.enqueue(.A, .hang())
        let engine = mt(client(), log: TalkTalkCore.EventLog(inMemory: HostClock.now))
        let req = listenRequest(8)
        let task = Task { try await engine.translate(req) }
        try? await Task.sleep(for: .milliseconds(80))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await eventually { FakeServer.stopped(.A) == 1 })
    }

    @Test func lateResultIsNotReturnedOnlyLogged() async {
        // The answer would arrive at ~400 ms; the caller's deadline is 150 ms.
        FakeServer.enqueue(.A, FakeServer.good("太晚了。", at: 300, dt: 50))
        let log = TalkTalkCore.EventLog(inMemory: HostClock.now)
        let engine = mt(client(), log: log)
        do {
            _ = try await engine.translate(listenRequest(2, deadlineMs: 150))
            Issue.record("a late result must not be returned")
        } catch {
            #expect(reason(error) == "deadline")
        }
        #expect(names(log).contains("mt.late"))
        #expect(await eventually { FakeServer.stopped(.A) == 1 })   // the stream is cancelled, not left running
        // Already past the deadline: nothing is sent at all.
        let before = FakeServer.requests().count
        await #expect(throws: MTError.self) { try await engine.translate(listenRequest(3, deadlineMs: 0)) }
        #expect(FakeServer.requests().count == before)
    }

    @Test func rateLimitFallsBackAndOpensTheBreaker() async {
        FakeServer.enqueue(.A, .json(429, #"{"error":{"code":null,"type":"requests","message":"Rate limit reached"}}"#,
                                     headers: ["Retry-After": "20"]))
        let log = TalkTalkCore.EventLog(inMemory: HostClock.now)
        let engine = mt(client(), log: log)
        do { _ = try await engine.translate(listenRequest(4)); Issue.record("429 must fall back") } catch {
            #expect(reason(error) == "allFailed")
        }
        // The primary's 429 opened the shared breaker: the next sentence goes to Apple without a request.
        let before = FakeServer.requests().count
        do { _ = try await engine.translate(listenRequest(5)); Issue.record("breaker must be open") } catch {
            #expect(reason(error) == "breakerOpen")
        }
        #expect(FakeServer.requests().count == before)
        #expect(FakeServer.requests(.B).isEmpty)
    }

    @Test func offlineFallsBackWithoutWaiting() async {
        FakeServer.enqueue(.A, FakeServer.Script(steps: [.init(atMs: 0, kind: .fail(.notConnectedToInternet))]))
        let engine = mt(client(), log: TalkTalkCore.EventLog(inMemory: HostClock.now))
        let t0 = ContinuousClock.now
        await #expect(throws: MTError.self) { try await engine.translate(listenRequest(6)) }
        #expect(ContinuousClock.now - t0 < .milliseconds(500))
        // NetworkHealth said offline: Apple directly, no request.
        await engine.network(.offline)
        let before = FakeServer.requests().count
        do { _ = try await engine.translate(listenRequest(9)); Issue.record("offline must fall back") } catch {
            #expect(reason(error) == "offline")
        }
        #expect(FakeServer.requests().count == before)
        await engine.network(.online)
        FakeServer.enqueue(.A, FakeServer.good("恢复了。"))
        #expect(try! await engine.translate(listenRequest(10)).text == "恢复了。")
    }

    @Test func pausedAfter401AndKeyNeverLogged() async {
        // The 401 body carries the (fake) key in `message`, as community reports describe.
        FakeServer.enqueue(.A, .json(401, #"{"error":{"code":"invalid_api_key","type":"invalid_request_error","message":"Incorrect API key provided: \#(fakeKey)"}}"#))
        let log = TalkTalkCore.EventLog(inMemory: HostClock.now)
        let c = OpenAIClient(cloud: profile.cloud, keyProvider: { fakeKey },
                             protocolClasses: [.A: [FakeA.self], .B: [FakeB.self]], sink: OpenAIMT.eventSink(log))
        let engine = OpenAIMT(client: c, profile: profile, prompts: try! CloudTestResources.prompts(),
                              configuration: .init(model: "gpt-6-luna", effort: "none"), log: log)
        do { _ = try await engine.translate(listenRequest(11)); Issue.record("401 must fall back") } catch {
            #expect(reason(error)?.hasPrefix("paused:") == true)
        }
        do { _ = try await engine.translate(listenRequest(12)); Issue.record("paused must stick") } catch {
            #expect(reason(error)?.hasPrefix("paused:") == true)
        }
        #expect(FakeServer.requests().count == 1)
        let rendered = log.recorded.map { String(describing: $0) }.joined(separator: "\n")
        #expect(!rendered.isEmpty)
        #expect(!rendered.contains(fakeKey))
        #expect(!rendered.contains(String(fakeKey.suffix(8))))
        #expect(!rendered.contains("Incorrect API key"))
        #expect(!rendered.contains("We will ship"))          // no source text
        #expect(rendered.contains("invalid_api_key"))
    }
}
