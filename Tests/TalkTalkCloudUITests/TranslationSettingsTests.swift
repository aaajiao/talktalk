import Foundation
import Synchronization
import Testing
import TalkTalkCloud
import TalkTalkCore
import TalkTalkSettingsUI
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
    private var queryCount = 0
    private var queryOnMain = false
    private(set) var writes = 0
    var reads: Int { lock.withLock { readCount } }
    var queries: Int { lock.withLock { queryCount } }
    var queriedOnMain: Bool { lock.withLock { queryOnMain } }
    init(_ initial: String? = nil) { value = initial.map { Data($0.utf8) } }
    func exists() -> Bool {
        lock.withLock { queryCount += 1; queryOnMain = queryOnMain || Thread.isMainThread; return value != nil }
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
    /// The shortest words show (§7.9); the sentence is the help.
    @Test func errorMapping() throws {
        let cloud = try UIRes.profile().cloud
        func failure(_ status: Int, _ error: OpenAIErrorInfo?) -> TranslationSettingsText.Message {
            TranslationSettingsText.failure(status: status, error: error, cloud: cloud)
        }
        let invalid = failure(401, .init(code: "invalid_api_key"))
        #expect(invalid.text == "key 无效 · 401" && invalid.detail?.contains("已撤销") == true)
        #expect(failure(403, nil).text == "被拒绝 · 403" && failure(403, nil).detail?.contains("国家或地区") == true)
        #expect(failure(429, .init(type: "insufficient_quota")).text == "额度用完 → Apple")
        #expect(failure(429, .init(code: "project_spend_limit_exceeded")).detail?.contains("project_spend_limit_exceeded") == true)
        #expect(failure(429, .init(code: "slow_down", type: "rate_limit_error")).text == "请求太频繁")
        #expect(failure(429, nil).text == "请求太频繁")
        #expect(failure(503, nil).text == "OpenAI 出错 · 503" && failure(503, nil).detail?.contains("暂时出错") == true)
        #expect(failure(404, nil).text == "模型不存在 · 404" && failure(404, nil).detail?.contains("下线") == true)
        #expect(TranslationSettingsText.transportFailure(URLError(.notConnectedToInternet)).text == "连不上")
    }

    @Test func costLine() {
        #expect(TranslationSettingsText.cost(for: "gpt-6-luna", yellow: false) == "≈ $0.06/小时（估）")
        #expect(TranslationSettingsText.cost(for: "gpt-6.1-sol", yellow: true) == "见 OpenAI 定价")
        #expect(TranslationSettingsText.cost(for: "gpt-6-sol", yellow: true).hasSuffix("+ 推理"))
        #expect(TranslationSettingsText.cost(for: "gpt-7-nova", yellow: false) == "见 OpenAI 定价")
    }

    @Test func retirementNoticeIsShort() {
        #expect(TranslationSettingsText.retirementNotice(.fellBackToDefault(from: "gpt-6-oldtier")) == "gpt-6-oldtier 已下线 → gpt-6-luna")
        #expect(TranslationSettingsText.retirementNotice(.defaultRetiring) == "gpt-6-luna 即将下线")
        #expect(TranslationSettingsText.retirementNotice(.keep("gpt-6-luna")) == nil)
    }

    /// After a save the clipboard reminder always shows (§5.4); a passed check joins its help.
    @Test func keyResultsKeepTheClipboardReminder() {
        let reminder = TranslationSettingsText.clearClipboard
        let passed = TranslationSettingsText.keyResults(pasteProblem: nil, verification: .ok("key 可用", detail: "模型 x 探针通过"),
                                                        saved: true)
        #expect(passed.map(\.text) == [reminder] && passed.first?.help?.contains("探针通过") == true)
        let failed = TranslationSettingsText.keyResults(pasteProblem: nil, verification: .failed("key 无效 · 401"), saved: true)
        #expect(failed.map(\.status) == [.failed, .ok] && failed.last?.text == reminder)
        let refused = SettingsProblem(.failed, "不像 OpenAI key")
        #expect(TranslationSettingsText.keyResults(pasteProblem: refused, verification: .idle, saved: false) == [refused])
        #expect(TranslationSettingsText.keyResults(pasteProblem: nil, verification: .idle, saved: false).isEmpty)
    }

    /// §9.1 4d: the OpenAI switches wait for consent and a key; no key is a warning only once
    /// known; a switch changed during a session waits for the next start.
    @Test func flowFactsGateTheSwitchesAndSayWhatWaits() {
        var p = TranslationPreferences()
        let noConsent = TranslationFlowFacts(preferences: p, hasKey: true, keyStateKnown: true)
        #expect(!noConsent.switchesEnabled && !noConsent.choosesOpenAI(.speak) && !noConsent.cloudConnected)
        #expect(noConsent.problem == nil)
        #expect(!TranslationFlowFacts(preferences: p, hasKey: false, keyStateKnown: true).showsOpenAISection)
        p.cloudConsentGiven = true
        let noKey = TranslationFlowFacts(preferences: p, hasKey: false, keyStateKnown: true)
        #expect(!noKey.switchesEnabled && noKey.choosesOpenAI(.listen) && !noKey.cloudConnected)
        #expect(noKey.badge(.listen)?.status == .warn && noKey.problem?.text == "无 key → Apple")
        #expect(TranslationFlowFacts(preferences: p, hasKey: false, keyStateKnown: false).problem == nil)
        let ready = TranslationFlowFacts(preferences: p, hasKey: true, keyStateKnown: true)
        #expect(ready.switchesEnabled && ready.cloudConnected && ready.problem == nil)
        var changed = p
        changed.speakCloudEnabled = false
        let waiting = TranslationFlowFacts(preferences: changed, hasKey: true, keyStateKnown: true, baseline: p)
        #expect(waiting.badge(.speak)?.status == .waiting && waiting.badge(.listen) == nil)
        #expect(waiting.problem?.text == "下次开始生效" && !waiting.choosesOpenAI(.speak))
        changed.listenCloudEnabled = false
        #expect(!TranslationFlowFacts(preferences: changed, hasKey: true, keyStateKnown: true).cloudConnected)
        // The running session still sends what it started with: DataBoundary stays connected.
        #expect(TranslationFlowFacts(preferences: changed, hasKey: true, keyStateKnown: true, baseline: p).cloudConnected)
        // Before the key item is known, a direction set to OpenAI never reads as "未连接".
        #expect(TranslationFlowFacts(preferences: p, hasKey: false, keyStateKnown: false).cloudConnected)
    }

    /// §7.8: the 文本翻译 card says what the page draws.
    @Test func theCardBadgeReadsThePageFacts() {
        var p = TranslationPreferences()
        #expect(TranslationFlowFacts(preferences: p, hasKey: true, keyStateKnown: true).cardBadge(warning: nil) == nil)
        p.cloudConsentGiven = true
        #expect(TranslationFlowFacts(preferences: p, hasKey: false, keyStateKnown: false).cardBadge(warning: nil) == nil)
        #expect(TranslationFlowFacts(preferences: p, hasKey: false, keyStateKnown: true).cardBadge(warning: "x")
            == .status(.warn, "无 key → Apple"))
        let ready = TranslationFlowFacts(preferences: p, hasKey: true, keyStateKnown: true)
        #expect(ready.cardBadge(warning: nil) == .cloud("已启用 OpenAI"))
        #expect(ready.cardBadge(warning: "模型即将下线") == .status(.warn, "模型即将下线 · 已启用 OpenAI"))
        var off = p
        off.speakCloudEnabled = false
        off.listenCloudEnabled = false
        #expect(TranslationFlowFacts(preferences: off, hasKey: true, keyStateKnown: true).cardBadge(warning: "x") == nil)
        // Switched off during a session that still sends text: OpenAI stays shown, no waiting badge.
        #expect(TranslationFlowFacts(preferences: off, hasKey: true, keyStateKnown: true, baseline: p).cardBadge(warning: nil)
            == .cloud("已启用 OpenAI"))
    }

    /// An OpenAI switch that is on can be turned off without a key; one that is off waits.
    @Test func aSwitchThatIsOnCanAlwaysBeTurnedOff() {
        var p = TranslationPreferences()
        p.cloudConsentGiven = true
        let on = TranslationFlowFacts(preferences: p, hasKey: false, keyStateKnown: true)
        #expect(on.switchEnabled(.listen) && on.switchHelp(.listen) == "用 OpenAI 翻译听到的话")
        p.listenCloudEnabled = false
        let off = TranslationFlowFacts(preferences: p, hasKey: false, keyStateKnown: true)
        #expect(!off.switchEnabled(.listen) && off.switchHelp(.listen) == "先保存 key" && off.badge(.listen) == nil)
        #expect(off.switchEnabled(.speak))
        p.cloudConsentGiven = false
        let noConsent = TranslationFlowFacts(preferences: p, hasKey: true, keyStateKnown: true)
        #expect(!noConsent.switchEnabled(.speak) && noConsent.switchHelp(.speak) == "先同意发送文字")
    }

    /// A model picked during a session waits for the next start, like the switches.
    @Test func aModelPickedDuringASessionWaits() {
        let p = TranslationPreferences()
        var q = p
        #expect(!TranslationFlowFacts(preferences: q, hasKey: true, keyStateKnown: true, baseline: p).modelWaits)
        q.effort = "low"
        #expect(TranslationFlowFacts(preferences: q, hasKey: true, keyStateKnown: true, baseline: p).modelWaits)
        q.model = "gpt-6.1-sol"
        #expect(!TranslationFlowFacts(preferences: q, hasKey: true, keyStateKnown: true).modelWaits)
    }

    @Test func fastModeChangedDuringASessionWaitsAndDoublesTheEstimate() {
        let p = TranslationPreferences()
        var q = p
        q.fastMode = true
        #expect(TranslationFlowFacts(preferences: q, hasKey: true, keyStateKnown: true, baseline: p).fastModeWaits)
        #expect(!TranslationFlowFacts(preferences: q, hasKey: true, keyStateKnown: true).fastModeWaits)
        #expect(TranslationSettingsText.cost(for: "gpt-6-luna", yellow: false, fastMode: true).contains("0.12"))
    }

    /// The menu's glyphs are spoken (the visible suffixes are gone).
    @Test func modelChoicesSayWhatTheirGlyphMeans() {
        let picker = ModelFilter.picker([
            .init(id: "gpt-6-luna", created: 2, shutdown_date: "2027-01-01"),
            .init(id: "gpt-6.1-sol", created: 3),
            .init(id: "gpt-6.1-terra", created: 4)
        ], current: "gpt-6-luna")
        let spoken = Dictionary(uniqueKeysWithValues: picker.models.map { ($0.id, TranslationSettingsText.choiceSpoken($0)) })
        #expect(spoken["gpt-6-luna"] == "gpt-6-luna · 默认，即将下线")
        #expect(spoken["gpt-6.1-sol"] == "gpt-6.1-sol，会明显变慢")
        #expect(spoken["gpt-6.1-terra"] == "gpt-6.1-terra")
    }

    @Test func preferencesRoundTrip() {
        let d = UIRes.defaults()
        var p = TranslationPreferences.load(d)
        #expect(p == TranslationPreferences())
        #expect(p.speakCloudEnabled && p.listenCloudEnabled && !p.cloudConsentGiven && p.model == "gpt-6-luna")
        #expect(!p.fastMode)
        p.model = "gpt-6.1-sol"; p.effort = "low"; p.listenCloudEnabled = false; p.cloudConsentGiven = true; p.fastMode = true
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
        #expect(m.keyState == .saved(masked: "sk-…•••"))
        #expect(store.reads == 0)
        #expect(!store.queriedOnMain)
        await m.loadKeyState()
        await m.loadKeyState()
        #expect(store.queries == 1) // Session preparation reuses the initial metadata result.
        #expect(store.reads == 0)
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
        #expect(m.keyStateKnown && !m.hasKey)
        await m.loadKeyState()
        #expect(m.keyStateKnown && !m.hasKey) // A later session must not revive the old query.
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
        #expect(m.pasteProblem?.text == "请先同意发送文字")
        #expect(m.keyState == .none)
    }

    @Test func badShapeRejected() async throws {
        let store = MemoryKeyStore()
        let m = try make(store)
        m.pasteField = "  not-a-key  "
        await m.saveAndVerify()
        #expect(store.writes == 0)
        #expect(m.pasteField.isEmpty)
        #expect(m.pasteProblem?.help?.contains("sk-") == true)
        #expect(m.pasteProblem?.help?.contains("not-a-key") == false && m.pasteProblem?.text.contains("not-a-key") == false)
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
        guard case let .failed(why, detail) = m.verification else { Issue.record("expected failure"); return }
        #expect(why == "key 无效 · 401")
        #expect(!why.contains("Incorrect") && detail?.contains("Incorrect") == false)   // error.message never surfaces
        #expect(m.savedHint == TranslationSettingsText.clearClipboard)
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

    /// 实时可用 measures the selected model: a candidate that is not taken leaves it as it was,
    /// and its own failure is the model row's status.
    @Test func aCandidateThatIsNotTakenLeavesTheProbeRow() async throws {
        FakeOpenAI.set(404, #"{"error":{"type":"invalid_request_error","code":"model_not_found"}}"#)
        let m = try make(MemoryKeyStore(fakeKey))
        await m.select(model: "gpt-6.1-terra")
        #expect(m.preferences.model == "gpt-6-luna")
        #expect(m.probe == .idle)
        #expect(m.candidate.line?.text == "模型不存在 · 404")

        FakeOpenAI.set(400, #"{"error":{"type":"invalid_request_error","param":"reasoning.effort"}}"#)
        await m.select(model: "gpt-6.1-terra")
        #expect(m.pendingYellow?.model == "gpt-6.1-terra")
        #expect(m.candidate == .idle)
        m.cancelYellow()
        #expect(m.probe == .idle)
        #expect(m.preferences.model == "gpt-6-luna")
    }

    /// The card warns only about the key or the model itself; a passing failure stays on the page.
    @Test func onlyKeyOrModelFailuresRejectTheKey() async throws {
        FakeOpenAI.set(401, #"{"error":{"type":"invalid_request_error","code":"invalid_api_key"}}"#)
        let m = try make(MemoryKeyStore(fakeKey))
        await m.verify()
        #expect(m.verificationRejectsKeyOrModel)
        FakeOpenAI.set(429, #"{"error":{"type":"rate_limit_error"}}"#)
        await m.verify()
        #expect(m.verification.line?.text == "请求太频繁")
        #expect(!m.verificationRejectsKeyOrModel)
    }

    @Test func deleteClears() async throws {
        let store = MemoryKeyStore(fakeKey)
        let m = try make(store)
        m.pasteField = "not-a-key"
        await m.saveAndVerify()
        #expect(m.pasteProblem != nil)
        m.deleteKey()
        #expect(!store.exists())
        #expect(m.keyState == .none)
        #expect(m.keyStateKnown)
        #expect(!m.hasKey)
        #expect(m.pasteProblem == nil)
    }

    /// 验证 after a refused paste shows its own result, not the stale refusal.
    @Test func verifyReplacesAStalePasteProblem() async throws {
        FakeOpenAI.set(401, #"{"error":{"type":"invalid_request_error","code":"invalid_api_key"}}"#)
        let m = try make(MemoryKeyStore(fakeKey))
        m.pasteField = "not-a-key"
        await m.saveAndVerify()
        #expect(m.pasteProblem?.text == "不像 OpenAI key")
        await m.verify()
        let results = TranslationSettingsText.keyResults(pasteProblem: m.pasteProblem, verification: m.verification,
                                                         saved: m.savedHint != nil)
        #expect(results.map(\.text) == ["key 无效 · 401"])
    }

    @Test func aSessionKeepsThePreferencesItStartedWith() throws {
        let m = try make(MemoryKeyStore())
        let start = Date(timeIntervalSince1970: 1_000)
        m.trackSession(start)
        let before = m.preferences
        m.update { $0.speakCloudEnabled = false }
        m.trackSession(start)                                   // the same session: unchanged
        #expect(m.sessionBaseline == before)
        m.trackSession(nil)
        #expect(m.sessionBaseline == nil)
        m.trackSession(start.addingTimeInterval(60))            // a new session starts from now
        #expect(m.sessionBaseline == m.preferences)
    }

    @Test func toggles() throws {
        let d = UIRes.defaults()
        let m = try make(MemoryKeyStore(), defaults: d)
        m.update { $0.speakCloudEnabled = false; $0.listenCloudEnabled = false }
        #expect(!m.preferences.anyCloud)
        #expect(!TranslationPreferences.load(d).anyCloud)
    }
}
