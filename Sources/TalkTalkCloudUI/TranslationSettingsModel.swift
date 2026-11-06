import Foundation
import Observation
import TalkTalkCloud
import TalkTalkCore

/// State and actions behind Settings › 翻译 (ARCHITECTURE.md §7.7, §11). The key itself is only
/// held transiently: while saving, and inside the client's Authorization header. Existing items
/// show “已保存”; only a newly pasted key supplies a last-4 mask, without another secret read.
@MainActor
@Observable
public final class TranslationSettingsModel {
    public enum KeyState: Equatable {
        case none
        case saved(masked: String)
    }

    public enum Check: Equatable {
        case idle
        case running(String)
        case ok(String)
        case failed(String)
    }

    /// The yellow path (§11) needs an explicit confirmation before switching.
    public struct YellowConfirmation: Equatable, Identifiable {
        public var model: String
        public var id: String { model }
    }

    /// Reasoning budget added to max_output_tokens on the yellow path (§11: e.g. 48 + 64, 估;
    /// M0-T4 ⑦ keeps this margin after the measured zero-reasoning-token responses).
    public static let yellowReasoningBudget = 64

    public private(set) var keyState: KeyState = .none
    /// False until the first metadata query answers (or a save or delete sets the state): until
    /// then `keyState == .none` means "not known yet", not "no key".
    public private(set) var keyStateKnown = false
    public var pasteField = ""
    public private(set) var pasteProblem: String?
    public private(set) var savedHint: String?

    public private(set) var verification: Check = .idle
    public private(set) var listing: Check = .idle
    public private(set) var probe: Check = .idle
    public private(set) var picker = ModelFilter.picker([], current: nil)
    public private(set) var notice: String?
    /// Which retirement `notice` reports: `.fellBackToDefault` (already switched) or
    /// `.defaultRetiring` (still in use, going away). Nil with no notice.
    public private(set) var retirement: ModelFilter.Resolution?
    public var pendingYellow: YellowConfirmation?

    public private(set) var preferences: TranslationPreferences

    private let store: any APIKeyStore
    private let profile: PolicyProfile
    private let prompts: MTPrompts
    private let defaults: UserDefaults
    private let protocolClasses: [Leg: [AnyClass]]
    @ObservationIgnored private var client: OpenAIClient?
    @ObservationIgnored private var listed: [ModelFilter.Listed] = []
    @ObservationIgnored private var keyStateLoad: Task<Bool, Never>?
    @ObservationIgnored private var keyStateRevision: UInt64 = 0

    /// - Parameters:
    ///   - store: the app's key item, normally `KeychainSecret.openAI(bundleID:)`.
    ///   - protocolClasses: tests only (fake server).
    public init(store: any APIKeyStore, profile: PolicyProfile, prompts: MTPrompts,
                defaults: UserDefaults = .standard, protocolClasses: [Leg: [AnyClass]] = [:]) {
        self.store = store
        self.profile = profile
        self.prompts = prompts
        self.defaults = defaults
        self.protocolClasses = protocolClasses
        self.preferences = TranslationPreferences.load(defaults)
        refreshKeyState()
    }

    /// For the running app: the bundle's key item, the bundled PolicyProfile and prompts.
    public static func forCurrentApp(bundleID: String? = Bundle.main.bundleIdentifier) throws -> TranslationSettingsModel {
        guard let id = bundleID, let secret = KeychainSecret.openAI(bundleID: id) else {
            throw CocoaError(.featureUnsupported)
        }
        return TranslationSettingsModel(store: secret, profile: try PolicyProfile.loadDefault(), prompts: try MTPrompts.loadDefault())
    }

    public var cloud: PolicyProfile.Cloud { profile.cloud }
    public var hasKey: Bool { keyState != .none }
    public var isYellow: Bool { preferences.effort != "none" }
    public var costLine: String { TranslationSettingsText.cost(for: preferences.model, yellow: isYellow) }

    // MARK: preferences

    public func update(_ change: (inout TranslationPreferences) -> Void) {
        var p = preferences
        change(&p)
        guard p != preferences else { return }
        preferences = p
        p.save(defaults)
    }

    public func giveConsent() { update { $0.cloudConsentGiven = true } }

    // MARK: key

    private func refreshKeyState() {
        let store = self.store
        let revision = keyStateRevision
        let query = Task.detached(priority: .utility) { store.exists() }
        keyStateLoad = query
        Task { [weak self] in
            let exists = await query.value
            self?.applyKeyState(exists: exists, revision: revision)
        }
    }

    /// Initial callers can use the model immediately; actions await the same metadata-only query.
    func loadKeyState() async {
        guard let query = keyStateLoad else { return }
        let revision = keyStateRevision
        let exists = await query.value
        applyKeyState(exists: exists, revision: revision)
    }

    private func applyKeyState(exists: Bool, revision: UInt64) {
        guard revision == keyStateRevision, keyStateLoad != nil else { return }
        keyStateLoad = nil
        keyState = exists ? .saved(masked: String(localized: "已保存")) : .none
        keyStateKnown = true
    }

    private func invalidateKeyStateLoad() {
        keyStateRevision &+= 1
        keyStateLoad?.cancel()
        keyStateLoad = nil
    }

    /// Paste box → shape check → Keychain → verify (§7.7). The field is cleared in every case.
    public func saveAndVerify() async {
        var key = APIKeyShape.normalized(pasteField)
        pasteField = ""
        pasteProblem = nil
        savedHint = nil
        guard preferences.cloudConsentGiven else { pasteProblem = "请先点“同意”。"; return }
        if let p = APIKeyShape.problem(key) {
            key = ""
            pasteProblem = "这不像 OpenAI key：\(p)。"
            return
        }
        do {
            try store.store(Data(key.utf8))
        } catch let f as KeychainSecret.Failure {
            key = ""
            pasteProblem = "写入钥匙串失败（OSStatus \(f.status)）。"
            return
        } catch {
            key = ""
            pasteProblem = "写入钥匙串失败。"
            return
        }
        let masked = APIKeyShape.masked(key)
        key = ""
        savedHint = TranslationSettingsText.clearClipboard
        client = nil        // the next request reads the new key
        invalidateKeyStateLoad()
        keyState = .saved(masked: masked)
        keyStateKnown = true
        await verify()
    }

    /// 验证: `GET /v1/models`, then the probe on the selected model. Green only when both pass.
    public func verify() async {
        await loadKeyState()
        guard hasKey else { verification = .failed("还没有 key。"); return }
        verification = .running("正在验证…")
        await loadModels()
        guard case .ok = listing else {
            if case .failed(let why) = listing { verification = .failed(why) }
            return
        }
        await runProbe(model: preferences.model, effort: preferences.effort)
        switch probe {
        case .ok: verification = .ok("key 可用，模型 \(preferences.model) 探针通过。")
        case .failed(let why): verification = .failed(why)
        default: break
        }
    }

    public func deleteKey() {
        do {
            try store.delete()
        } catch let f as KeychainSecret.Failure {
            pasteProblem = "删除失败（OSStatus \(f.status)）。"
            return
        } catch {
            pasteProblem = "删除失败。"
            return
        }
        invalidateKeyStateLoad()
        client = nil
        keyState = .none
        keyStateKnown = true
        verification = .idle
        listing = .idle
        probe = .idle
        picker = ModelFilter.picker([], current: nil)
        listed = []
        savedHint = nil
    }

    // MARK: models

    /// The live list (§11), with the retirement fallback checked once per load.
    public func loadModels() async {
        await loadKeyState()
        guard hasKey else { listing = .idle; return }
        listing = .running("正在读取…")
        do {
            let rows = try await catalog().list()
            listed = rows
            applyResolution(ModelFilter.resolve(selection: preferences.model, listed: rows))
            picker = ModelFilter.picker(rows, current: preferences.model)
            listing = .ok("\(picker.models.count) 个可选模型")
        } catch let OpenAIModelCatalog.CatalogError.http(status, info) {
            listing = .failed(TranslationSettingsText.failure(status: status, error: info, cloud: cloud))
        } catch OpenAIModelCatalog.CatalogError.malformed {
            listing = .failed("模型列表的格式看不懂。")
        } catch {
            listing = .failed(TranslationSettingsText.transportFailure(error))
        }
    }

    private func applyResolution(_ r: ModelFilter.Resolution) {
        switch r {
        case .keep: break
        case .fellBackToDefault(let from):
            if preferences.notifiedRetiredFrom != from { notice = TranslationSettingsText.retirementNotice(r); retirement = r }
            update { $0.model = ModelFilter.defaultModel; $0.effort = "none"; $0.notifiedRetiredFrom = from }
        case .defaultRetiring:
            if !preferences.notifiedDefaultRetiring { notice = TranslationSettingsText.retirementNotice(r); retirement = r }
            update { $0.notifiedDefaultRetiring = true }
        }
    }

    public func dismissNotice() {
        notice = nil
        retirement = nil
    }

    /// Picking a model: probe with effort none; a model that rejects none (or is known not to
    /// support it) asks for the yellow-path confirmation instead of switching.
    public func select(model: String) async {
        guard model != preferences.model || probe == .idle else { return }
        if ModelFilter.known[model]?.supportsEffortNone == false {
            pendingYellow = YellowConfirmation(model: model)
            return
        }
        let r = await runProbe(model: model, effort: "none")
        if let r, r.accepted {
            update { $0.model = model; $0.effort = "none" }
        } else if let r, r.needsLowEffort {
            pendingYellow = YellowConfirmation(model: model)
        }
    }

    /// The user confirmed the yellow path for `pendingYellow`.
    public func confirmYellow() async {
        guard let y = pendingYellow else { return }
        pendingYellow = nil
        let r = await runProbe(model: y.model, effort: "low")
        if let r, r.accepted { update { $0.model = y.model; $0.effort = "low" } }
    }

    public func cancelYellow() { pendingYellow = nil }

    public func reprobe() async { await runProbe(model: preferences.model, effort: preferences.effort) }

    @discardableResult
    private func runProbe(model: String, effort: String) async -> OpenAIModelCatalog.ProbeResult? {
        await loadKeyState()
        guard hasKey else { probe = .idle; return nil }
        probe = .running("正在测 \(model)…")
        let r = await catalog().probe(model: model, effort: effort,
                                      reasoningBudget: effort == "none" ? 0 : Self.yellowReasoningBudget,
                                      basePolicy: profile.speakHedgePolicy)
        if r.accepted {
            probe = .ok("\(model)（effort \(effort)）· " + TranslationSettingsText.timing(r))
        } else if r.needsLowEffort {
            probe = .failed("\(model) 不支持 effort none，只能走黄色路径（会明显变慢）。")
        } else {
            probe = .failed(TranslationSettingsText.probeFailure(r, cloud: cloud))
        }
        return r
    }

    private func catalog() -> OpenAIModelCatalog {
        let c: OpenAIClient
        if let client { c = client } else {
            let store = self.store
            c = OpenAIClient(cloud: profile.cloud, keyProvider: {
                String(decoding: try store.read(), as: UTF8.self)
            }, protocolClasses: protocolClasses)
            client = c
        }
        return OpenAIModelCatalog(client: c, builder: OpenAIRequestBuilder(cloud: profile.cloud, prompts: prompts))
    }
}
