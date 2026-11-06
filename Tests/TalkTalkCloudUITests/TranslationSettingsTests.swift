import Foundation
import Synchronization
import Testing
import TalkTalkCloud
import TalkTalkCore
@testable import TalkTalkCloudUI

// Settings › 翻译 (§11, §7.7): text mapping, preferences, and the model's key / list flow against an
// in-memory key store and a URLProtocol fake. Nothing touches the Keychain or the network.

enum UIRes {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func profile() throws -> PolicyProfile { try PolicyProfile.load(from: root.appendingPathComponent("Resources/PolicyProfile.default.json")) }
    static func prompts() throws -> MTPrompts { try MTPrompts.load(from: root.appendingPathComponent("Resources/prompts/mt.json")) }
    static func defaults() -> UserDefaults {
        let name = "talktalk.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }
}

final class MemoryKeyStore: APIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    private var readCount = 0
    private var queryOnMain = false
    private(set) var writes = 0
    var reads: Int { lock.withLock { readCount } }
    var queriedOnMain: Bool { lock.withLock { queryOnMain } }
    init(_ initial: String? = nil) { value = initial.map { Data($0.utf8) } }
    func exists() -> Bool {
        lock.withLock { queryOnMain = queryOnMain || Thread.isMainThread; return value != nil }
    }
    func read() throws -> Data {
        try lock.withLock {
            readCount += 1
            guard let value else { throw CocoaError(.fileNoSuchFile) }
            return value
        }
    }
    func store(_ secret: Data) throws { lock.withLock { value = secret; writes += 1 } }
    func delete() throws { lock.withLock { value = nil } }
}

/// Holds only the initial metadata query, as a Keychain authorization wait might do.
final class DelayedKeyStore: APIKeyStore, Sendable {
    let backing = MemoryKeyStore(fakeKey)
    let started = AsyncStream<Void>.makeStream()
    let resume = DispatchSemaphore(value: 0)

    func exists() -> Bool {
        let result = backing.exists()
        started.continuation.yield(())
        _ = resume.wait(timeout: .now() + 2)
        return result
    }
    func read() throws -> Data { try backing.read() }
    func store(_ secret: Data) throws { try backing.store(secret) }
    func delete() throws { try backing.delete() }
}

/// Answers every request with the current (status, body); records paths and whether a Bearer header was sent.
final class FakeOpenAI: URLProtocol {
    struct State { var status = 200; var body = #"{"data":[]}"#; var paths: [String] = [] }
    static let state = Mutex(State())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.state.withLock { s -> (Int, String) in
            s.paths.append(request.url?.path ?? "")
            return (s.status, s.body)
        }
        let r = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func set(_ status: Int, _ body: String) { state.withLock { $0 = State(status: status, body: body, paths: []) } }
}

let fakeKey = "sk-proj-" + String(repeating: "a", count: 152) + "WXYZ"   // 164 chars, not a real key

@Suite struct TranslationSettingsTextTests {
    @Test func errorMapping() throws {
        let cloud = try UIRes.profile().cloud
        #expect(TranslationSettingsText.failure(status: 401, error: .init(code: "invalid_api_key"), cloud: cloud).contains("key 无效"))
        #expect(TranslationSettingsText.failure(status: 403, error: nil, cloud: cloud).contains("国家或地区"))
        #expect(TranslationSettingsText.failure(status: 429, error: .init(type: "insufficient_quota"), cloud: cloud).contains("额度用完"))
        #expect(TranslationSettingsText.failure(status: 429, error: .init(code: "project_spend_limit_exceeded"), cloud: cloud).contains("额度用完"))
        #expect(TranslationSettingsText.failure(status: 429, error: .init(code: "slow_down", type: "rate_limit_error"), cloud: cloud).contains("太频繁"))
        #expect(TranslationSettingsText.failure(status: 429, error: nil, cloud: cloud).contains("太频繁"))
        #expect(TranslationSettingsText.failure(status: 503, error: nil, cloud: cloud).contains("暂时出错"))
        #expect(TranslationSettingsText.failure(status: 404, error: nil, cloud: cloud).contains("下线"))
    }

    @Test func costLine() {
        #expect(TranslationSettingsText.cost(for: "gpt-6-luna", yellow: false) == "约 $0.06 / 会议小时（估，含对冲）")
        #expect(TranslationSettingsText.cost(for: "gpt-6.1-sol", yellow: true) == "见 OpenAI 定价（推理 token 另计）")
        #expect(TranslationSettingsText.cost(for: "gpt-6-sol", yellow: true).hasSuffix("+ 推理 token"))
        #expect(TranslationSettingsText.cost(for: "gpt-7-nova", yellow: false) == "见 OpenAI 定价")
    }

    @Test func preferencesRoundTrip() {
        let d = UIRes.defaults()
        var p = TranslationPreferences.load(d)
        #expect(p == TranslationPreferences())
        #expect(p.speakCloudEnabled && p.listenCloudEnabled && !p.cloudConsentGiven && p.model == "gpt-6-luna")
        p.model = "gpt-6.1-sol"; p.effort = "low"; p.listenCloudEnabled = false; p.cloudConsentGiven = true
        p.save(d)
        #expect(TranslationPreferences.load(d) == p)
    }
}

@Suite(.serialized) @MainActor struct TranslationSettingsModelTests {
    func make(_ store: any APIKeyStore, consent: Bool = true, defaults d: UserDefaults = UIRes.defaults()) throws -> TranslationSettingsModel {
        if consent { var p = TranslationPreferences.load(d); p.cloudConsentGiven = true; p.save(d) }
        return TranslationSettingsModel(store: store, profile: try UIRes.profile(), prompts: try UIRes.prompts(), defaults: d,
                                        protocolClasses: [.A: [FakeOpenAI.self], .B: [FakeOpenAI.self]])
    }

    @Test func existingKeyStateDoesNotReadSecretOrBlockMainThread() async throws {
        let store = MemoryKeyStore(fakeKey)
        let m = try make(store)
        #expect(!m.keyStateKnown)                               // .none means "not known yet"
        await m.loadKeyState()
        #expect(m.keyStateKnown)
        #expect(m.keyState == .saved(masked: "已保存"))
        #expect(store.reads == 0)
        #expect(!store.queriedOnMain)
    }

    @Test func lateInitialQueryCannotRestoreDeletedKey() async throws {
        let store = DelayedKeyStore()
        let m = try make(store)
        let deletion = Task { @MainActor in
            for await _ in store.started.stream { break }
            m.deleteKey()
            store.resume.signal()
        }
        await m.loadKeyState()
        await deletion.value
        #expect(m.keyState == .none)
        #expect(!store.backing.exists())
        #expect(store.backing.reads == 0)
    }

    @Test func noConsentNoWrite() async throws {
        let store = MemoryKeyStore()
        let m = try make(store, consent: false)
        m.pasteField = fakeKey
        await m.saveAndVerify()
        #expect(store.writes == 0)
        #expect(m.pasteField.isEmpty)
        #expect(m.pasteProblem != nil)
        #expect(m.keyState == .none)
    }

    @Test func badShapeRejected() async throws {
        let store = MemoryKeyStore()
        let m = try make(store)
        m.pasteField = "  not-a-key  "
        await m.saveAndVerify()
        #expect(store.writes == 0)
        #expect(m.pasteField.isEmpty)
        #expect(m.pasteProblem?.contains("sk-") == true)
        #expect(m.pasteProblem?.contains("not-a-key") == false)
    }

    @Test func save401ShowsInvalidKeyAndNoProbe() async throws {
        FakeOpenAI.set(401, #"{"error":{"message":"Incorrect API key provided: sk-proj-****WXYZ","type":"invalid_request_error","code":"invalid_api_key"}}"#)
        let store = MemoryKeyStore()
        let m = try make(store)
        m.pasteField = "\n" + fakeKey + " \n"
        await m.saveAndVerify()
        #expect(store.writes == 1)
        #expect(try store.read() == Data(fakeKey.utf8))       // trimmed
        #expect(m.keyState == .saved(masked: "sk-…WXYZ"))
        guard case .failed(let why) = m.verification else { Issue.record("expected failure"); return }
        #expect(why.contains("key 无效"))
        #expect(!why.contains("Incorrect"))                     // error.message never surfaces
        #expect(FakeOpenAI.state.withLock { $0.paths } == ["/v1/models"])   // no probe after a failed list
    }

    @Test func listFiltersAndFallsBack() async throws {
        let d = UIRes.defaults()
        var p = TranslationPreferences.load(d); p.model = "gpt-6-oldtier"; p.save(d)
        FakeOpenAI.set(200, #"""
            {"data":[{"id":"gpt-6-luna","created":2,"object":"model"},{"id":"gpt-6.1-terra","created":3,"object":"model"},
                     {"id":"gpt-6-realtime","created":4,"object":"model"},{"id":"gpt-5-mini","created":5,"object":"model"},
                     {"id":"gpt-6-luna-2026-10-01","created":1,"object":"model"}]}
            """#)
        let m = try make(MemoryKeyStore(fakeKey), defaults: d)
        await m.loadModels()
        #expect(m.picker.models.map(\.id) == ["gpt-6.1-terra", "gpt-6-luna"])
        #expect(m.picker.snapshots.map(\.id) == ["gpt-6-luna-2026-10-01"])
        #expect(m.preferences.model == "gpt-6-luna")
        #expect(m.notice?.contains("gpt-6-oldtier") == true)
        #expect(m.retirement == .fellBackToDefault(from: "gpt-6-oldtier"))
        #expect(TranslationPreferences.load(d).model == "gpt-6-luna")
        // Shown once: a second load does not notify again.
        m.dismissNotice()
        #expect(m.retirement == nil)
        var q = TranslationPreferences.load(d); q.model = "gpt-6-oldtier"; q.save(d)
        let m2 = try make(MemoryKeyStore(fakeKey), defaults: d)
        await m2.loadModels()
        #expect(m2.notice == nil)
    }

    @Test func knownYellowAsksFirst() async throws {
        #expect(TranslationSettingsModel.yellowReasoningBudget == 64)
        FakeOpenAI.set(200, #"{"data":[]}"#)
        let m = try make(MemoryKeyStore(fakeKey))
        await m.select(model: "gpt-6.1-sol")
        #expect(m.pendingYellow?.model == "gpt-6.1-sol")
        #expect(m.preferences.model == "gpt-6-luna")           // not switched before confirmation
        #expect(FakeOpenAI.state.withLock { $0.paths }.isEmpty) // and nothing sent
        m.cancelYellow()
        #expect(m.pendingYellow == nil)
    }

    @Test func deleteClears() throws {
        let store = MemoryKeyStore(fakeKey)
        let m = try make(store)
        m.deleteKey()
        #expect(!store.exists())
        #expect(m.keyState == .none)
        #expect(m.keyStateKnown)
        #expect(!m.hasKey)
    }

    @Test func toggles() throws {
        let d = UIRes.defaults()
        let m = try make(MemoryKeyStore(), defaults: d)
        m.update { $0.speakCloudEnabled = false; $0.listenCloudEnabled = false }
        #expect(!m.preferences.anyCloud)
        #expect(!TranslationPreferences.load(d).anyCloud)
    }
}
