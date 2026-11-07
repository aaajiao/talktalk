import Foundation
import Synchronization
import Testing
import TalkTalkCloud
import TalkTalkCore
@testable import TalkTalkCloudUI

/// A model-list server that does not answer until the test releases a specific request.
/// No key values are recorded and no request can reach the network.
private final class HeldModelList: URLProtocol, @unchecked Sendable {
    private struct State { var requests: [HeldModelList] = [] }
    private static let state = Mutex(State())
    private let stopped = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.state.withLock { $0.requests.append(self) } }
    override func stopLoading() { stopped.withLock { $0 = true } }

    static var count: Int { state.withLock { $0.requests.count } }
    static func reset() { state.withLock { $0 = State() } }
    static func wasStopped(_ index: Int) -> Bool {
        let request = state.withLock { $0.requests[index] }
        return request.stopped.withLock { $0 }
    }

    static func complete(_ index: Int, status: Int = 200, body: String) {
        let request = state.withLock { $0.requests[index] }
        guard !request.stopped.withLock({ $0 }) else { return }
        let response = HTTPURLResponse(url: request.request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
        request.client?.urlProtocol(request, didLoad: Data(body.utf8))
        request.client?.urlProtocolDidFinishLoading(request)
    }
}

@Suite(.serialized) @MainActor struct SessionModelPreparationTests {
    private let models = #"{"data":[{"id":"gpt-6-luna","created":2,"object":"model"}]}"#
    private let rejectedKey = #"{"error":{"type":"invalid_request_error","code":"invalid_api_key"}}"#

    private func make(_ store: any APIKeyStore = MemoryKeyStore(fakeKey), consent: Bool = true,
                      now: @escaping () -> Date = Date.init) throws -> TranslationSettingsModel {
        HeldModelList.reset()
        let defaults = UIRes.defaults()
        var preferences = TranslationPreferences.load(defaults)
        preferences.cloudConsentGiven = consent
        preferences.save(defaults)
        return TranslationSettingsModel(store: store, profile: try UIRes.profile(), prompts: try UIRes.prompts(),
                                        defaults: defaults, protocolClasses: [.A: [HeldModelList.self], .B: [HeldModelList.self]],
                                        now: now)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    @Test func preparationReturnsBeforeHeldNetworkAndDeduplicatesForFiveMinutes() async throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let model = try make(now: { now })
        defer { model.deleteKey() }
        await model.loadKeyState()
        // This call has returned while the fake server is still unable to answer anything.
        #expect(!model.prepareForSession())
        try #require(await eventually { HeldModelList.count == 1 })
        guard case .running = model.listing else { Issue.record("expected held list request"); return }
        for _ in 0..<10 { #expect(!model.prepareForSession()) }
        #expect(HeldModelList.count == 1)

        HeldModelList.complete(0, body: models)
        #expect(await eventually { if case .ok = model.listing { true } else { false } })
        now.addTimeInterval(299)
        model.prepareForSession()
        #expect(HeldModelList.count == 1)
        now.addTimeInterval(1)
        model.prepareForSession()
        try #require(await eventually { HeldModelList.count == 2 })
        HeldModelList.complete(1, body: models)
        #expect(await eventually { if case .ok = model.listing { true } else { false } })
    }

    @Test func cachedRetirementIsResolvedSynchronouslyWithoutAnotherRequest() async throws {
        let model = try make()
        defer { model.deleteKey() }
        let initial = Task { await model.loadModels() }
        try #require(await eventually { HeldModelList.count == 1 })
        HeldModelList.complete(0, body: models)
        await initial.value
        model.update { $0.model = "gpt-6-oldtier"; $0.effort = "low" }

        #expect(model.prepareForSession())
        #expect(model.preferences.model == "gpt-6-luna" && model.preferences.effort == "none")
        #expect(model.retirement == .fellBackToDefault(from: "gpt-6-oldtier"))
        #expect(model.notice?.contains("gpt-6-oldtier") == true)
        #expect(HeldModelList.count == 1)
    }

    @Test func backgroundRetirementKeepsTheRunningSessionBaseline() async throws {
        let model = try make()
        defer { model.deleteKey() }
        model.update { $0.model = "gpt-6-oldtier" }
        model.trackSession(Date(timeIntervalSince1970: 123))
        #expect(!model.prepareForSession())
        try #require(await eventually { HeldModelList.count == 1 })
        HeldModelList.complete(0, body: models)
        #expect(await eventually { if case .ok = model.listing { true } else { false } })
        #expect(model.preferences.model == "gpt-6-luna")
        #expect(model.sessionBaseline?.model == "gpt-6-oldtier")
        #expect(model.flowFacts.modelWaits)
    }

    @Test func manualRefreshReplacesPendingBackgroundAndIgnoresCooldown() async throws {
        let model = try make()
        defer { model.deleteKey() }
        model.prepareForSession()
        try #require(await eventually { HeldModelList.count == 1 })
        let manual = Task { await model.loadModels() }
        try #require(await eventually { HeldModelList.count == 2 })
        #expect(await eventually { HeldModelList.wasStopped(0) })
        HeldModelList.complete(1, body: models)
        await manual.value
        let again = Task { await model.loadModels() }
        try #require(await eventually { HeldModelList.count == 3 })
        HeldModelList.complete(2, body: models)
        await again.value
        #expect(model.picker.models.map(\.id) == ["gpt-6-luna"])
    }

    @Test func deletingKeyRejectsAnAlreadyDeliveredBackgroundResponse() async throws {
        let model = try make()
        defer { model.deleteKey() }
        model.update { $0.model = "gpt-6-oldtier" }
        model.prepareForSession()
        try #require(await eventually { HeldModelList.count == 1 })
        // Enqueue delivery, then invalidate before the main actor can apply its result.
        HeldModelList.complete(0, body: models)
        model.deleteKey()
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.keyState == .none && model.listing == .idle)
        #expect(model.preferences.model == "gpt-6-oldtier")
        #expect(model.notice == nil && model.retirement == nil)
        #expect(!model.prepareForSession())
        try await Task.sleep(for: .milliseconds(20))
        #expect(HeldModelList.count == 1)
    }

    @Test func replacingKeyInvalidatesHeldListAndStartsFreshVerification() async throws {
        let store = MemoryKeyStore(fakeKey)
        let model = try make(store)
        defer { model.deleteKey() }
        model.update { $0.model = "gpt-6-oldtier" }
        model.prepareForSession()
        try #require(await eventually { HeldModelList.count == 1 })
        model.pasteField = "sk-proj-" + String(repeating: "b", count: 152) + "ABCD"
        let save = Task { await model.saveAndVerify() }
        try #require(await eventually { HeldModelList.count == 2 })
        #expect(await eventually { HeldModelList.wasStopped(0) })
        HeldModelList.complete(0, body: models) // A cancelled old account cannot supply a fallback.
        HeldModelList.complete(1, status: 401, body: rejectedKey)
        await save.value
        #expect(model.keyState == .saved(masked: "sk-…ABCD"))
        #expect(model.preferences.model == "gpt-6-oldtier")
        #expect(model.notice == nil && model.retirement == nil)
        guard case .failed = model.verification else { Issue.record("new key verification must still run"); return }
        #expect(HeldModelList.count == 2) // A rejected list must not start a translation probe.
    }

    @Test func revokingConsentDropsOldResultsAndStopsAutomaticRequestsButKeepsManualRefresh() async throws {
        let model = try make()
        defer { model.deleteKey() }
        model.update { $0.model = "gpt-6-oldtier" }
        model.prepareForSession()
        try #require(await eventually { HeldModelList.count == 1 })
        HeldModelList.complete(0, body: models)
        model.update { $0.cloudConsentGiven = false }
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.listing == .idle && model.preferences.model == "gpt-6-oldtier")
        #expect(!model.prepareForSession())
        #expect(HeldModelList.count == 1)

        // An explicit model-list refresh retains its existing authorization semantics.
        let manual = Task { await model.loadModels() }
        try #require(await eventually { HeldModelList.count == 2 })
        HeldModelList.complete(1, body: models)
        await manual.value
        #expect(model.preferences.model == "gpt-6-luna")
        #expect(model.retirement == .fellBackToDefault(from: "gpt-6-oldtier"))
    }
}
