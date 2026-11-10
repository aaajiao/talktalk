import Foundation
import Observation
import TalkTalkCloud
import TalkTalkCore
import TalkTalkSettingsUI

/// State and actions behind Settings › 翻译 (ARCHITECTURE.md §7.7, §11). The key itself is only
/// held transiently: while saving, and inside the client's Authorization header. Existing items
/// show “sk-…•••”; only a newly pasted key supplies a last-4 mask, without another secret read.
/// Its words come from `TranslationSettingsText`: the shortest form to show, the sentence as help.
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
        case ok(String, detail: String? = nil)
        case failed(String, detail: String? = nil)

        init(failed m: TranslationSettingsText.Message) { self = .failed(m.text, detail: m.detail) }
        init(ok m: TranslationSettingsText.Message) { self = .ok(m.text, detail: m.detail) }

        /// The check as a status line: the shortest words, the full sentence as help.
        public var line: SettingsProblem? {
            switch self {
            case .idle: nil
            case let .running(text): SettingsProblem(.busy, text)
            case let .ok(text, detail): SettingsProblem(.ok, text, help: detail)
            case let .failed(text, detail): SettingsProblem(.failed, text, help: detail)
            }
        }
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
    // Retain facts, not translated snapshots: switching UI language only renders these again.
    private var pasteIssue: TranslationSettingsText.PasteIssue?
    private var hasSavedHint = false
    public var pasteProblem: SettingsProblem? { pasteIssue?.problem }
    public var savedHint: String? { hasSavedHint ? TranslationSettingsText.clearClipboard : nil }
    /// Which `OpenAIKeySection` asked to delete the key. Settings › 识别与翻译 and onboarding
    /// step 5 share this model, so only the asking window shows the alert; nil while none asks.
    public enum KeySectionHost: Sendable { case settings, onboarding }
    public var keyDeletionAskedBy: KeySectionHost?

    private var verificationResult: TranslationSettingsText.CheckResult = .idle
    private var listingResult: TranslationSettingsText.CheckResult = .idle
    private var probeResult: TranslationSettingsText.CheckResult = .idle
    public var verification: Check { verificationResult.presentation(cloud: cloud) }
    public var listing: Check { listingResult.presentation(cloud: cloud) }
    public var probe: Check { probeResult.presentation(cloud: cloud) }
    /// Why the last model picked in the menu was not taken (the model row's status); idle once
    /// a model is taken or measured again.
    private var candidateResult: TranslationSettingsText.CheckResult = .idle
    @ObservationIgnored private var probeBeforeCandidate: TranslationSettingsText.CheckResult?
    public var candidate: Check { candidateResult.presentation(cloud: cloud) }
    public private(set) var picker = ModelFilter.picker([], current: nil)
    public var notice: String? { retirement.flatMap(TranslationSettingsText.retirementNotice) }
    /// Which retirement `notice` reports: `.fellBackToDefault` (already switched) or
    /// `.defaultRetiring` (still in use, going away). Nil with no notice.
    public private(set) var retirement: ModelFilter.Resolution?
    public var pendingYellow: YellowConfirmation?

    public private(set) var preferences: TranslationPreferences
    /// The preferences the running session started with (§7.9: a switch changed during a
    /// session waits for the next start); nil while none runs. See `trackSession(_:)`.
    public private(set) var sessionBaseline: TranslationPreferences?
    @ObservationIgnored private var sessionStart: Date?

    private let store: any APIKeyStore
    private let profile: PolicyProfile
    private let prompts: MTPrompts
    private let defaults: UserDefaults
    private let protocolClasses: [Leg: [AnyClass]]
    @ObservationIgnored private var client: OpenAIClient?
    @ObservationIgnored private var listed: [ModelFilter.Listed] = []
    @ObservationIgnored private var keyStateLoad: Task<Bool, Never>?
    @ObservationIgnored private var keyStateRevision: UInt64 = 0
    @ObservationIgnored private var modelListTask: Task<Void, Never>?
    @ObservationIgnored private var modelListRevision: UInt64 = 0
    @ObservationIgnored private var hasModelList = false
    @ObservationIgnored private var lastModelListAttempt: Date?
    @ObservationIgnored private let now: () -> Date
    private static let modelListCooldown: TimeInterval = 5 * 60

    /// - Parameters:
    ///   - store: the app's key item, normally `KeychainSecret.openAI(bundleID:)`.
    ///   - protocolClasses: tests only (fake server).
    public init(store: any APIKeyStore, profile: PolicyProfile, prompts: MTPrompts,
                defaults: UserDefaults = .standard, protocolClasses: [Leg: [AnyClass]] = [:],
                now: @escaping () -> Date = Date.init) {
        self.store = store
        self.profile = profile
        self.prompts = prompts
        self.defaults = defaults
        self.protocolClasses = protocolClasses
        self.now = now
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
    public var costLine: String {
        TranslationSettingsText.cost(for: preferences.model, yellow: isYellow, fastMode: preferences.fastMode)
    }

    /// What the 文本翻译 diagram draws now.
    public var flowFacts: TranslationFlowFacts {
        TranslationFlowFacts(preferences: preferences, hasKey: hasKey, keyStateKnown: keyStateKnown,
                             baseline: sessionBaseline)
    }

    /// `start`: when the running session started, nil while none runs. The first sight of a
    /// session keeps the current preferences as its own: only this model writes them, so they
    /// match what that session read unless changed during its few seconds of startup.
    public func trackSession(_ start: Date?) {
        guard start != sessionStart else { return }
        sessionStart = start
        sessionBaseline = start == nil ? nil : preferences
    }

    // MARK: preferences

    public func update(_ change: (inout TranslationPreferences) -> Void) {
        var p = preferences
        change(&p)
        guard p != preferences else { return }
        let revokedConsent = preferences.cloudConsentGiven && !p.cloudConsentGiven
        preferences = p
        p.save(defaults)
        if revokedConsent { invalidateModelList() }
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
    public func loadKeyState() async {
        guard let query = keyStateLoad else { return }
        let revision = keyStateRevision
        let exists = await query.value
        applyKeyState(exists: exists, revision: revision)
    }

    private func applyKeyState(exists: Bool, revision: UInt64) {
        guard revision == keyStateRevision, keyStateLoad != nil else { return }
        keyStateLoad = nil
        keyState = exists ? .saved(masked: TranslationSettingsText.savedKeyMask) : .none
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
        pasteIssue = nil
        hasSavedHint = false
        guard preferences.cloudConsentGiven else { pasteIssue = .consentFirst; return }
        if let p = APIKeyShape.problem(key) {
            key = ""
            pasteIssue = .notAKey(p)
            return
        }
        do {
            try store.store(Data(key.utf8))
        } catch let f as KeychainSecret.Failure {
            key = ""
            pasteIssue = .keychainWriteFailed(f.status)
            return
        } catch {
            key = ""
            pasteIssue = .keychainWriteFailed(nil)
            return
        }
        let masked = APIKeyShape.masked(key)
        key = ""
        hasSavedHint = true
        invalidateModelList()
        client = nil        // the next request reads the new key
        invalidateKeyStateLoad()
        keyState = .saved(masked: masked)
        keyStateKnown = true
        await verify()
    }

    /// 验证: `GET /v1/models`, then the probe on the selected model. Green only when both pass.
    public func verify() async {
        // A refused paste or failed delete from before would hide this check's result.
        pasteIssue = nil
        await loadKeyState()
        guard hasKey else { verificationResult = .noKey; return }
        verificationResult = .verifying
        await loadModels()
        // The page's forced refresh on reappearing supersedes this request without a result:
        // wait for the newest list instead.
        while let task = modelListTask { await task.value }
        guard case .ok = listing else {
            // A superseded or invalidated list: the check ends without a verdict.
            if case .failed = listing { verificationResult = listingResult } else { verificationResult = .idle }
            return
        }
        await runProbe(model: preferences.model, effort: preferences.effort)
        switch probe {
        case .ok: verificationResult = .verified(model: preferences.model)
        case .failed: verificationResult = probeResult
        default: verificationResult = .idle
        }
    }

    /// The failed check is about the key or the model itself (no key, 401/403/404), not a
    /// passing network, rate-limit or server problem: what the 文本翻译 card warns about.
    public var verificationRejectsKeyOrModel: Bool {
        func rejects(_ status: Int?) -> Bool { status.map { [401, 403, 404].contains($0) } ?? false }
        switch verificationResult {
        case .noKey: return true
        case let .httpFailure(status, _): return rejects(status)
        case let .probed(r, _, _): return !r.accepted && rejects(r.httpStatus)
        default: return false
        }
    }

    public func deleteKey() {
        do {
            try store.delete()
        } catch let f as KeychainSecret.Failure {
            pasteIssue = .deleteFailed(f.status)
            return
        } catch {
            pasteIssue = .deleteFailed(nil)
            return
        }
        invalidateKeyStateLoad()
        invalidateModelList()
        client = nil
        keyState = .none
        keyStateKnown = true
        verificationResult = .idle
        listingResult = .idle
        probeResult = .idle
        candidateResult = .idle
        probeBeforeCandidate = nil
        picker = ModelFilter.picker([], current: nil)
        listed = []
        hasSavedHint = false
        pasteIssue = nil
    }

    // MARK: models

    /// Starting a scene only resolves the current selection from this key's cached list.
    /// Refreshing the catalog belongs to a retained background task, never the startup path.
    @discardableResult
    public func prepareForSession() -> Bool {
        guard preferences.cloudConsentGiven, preferences.anyCloud else { return false }
        let previous = preferences.model
        if hasModelList {
            applyResolution(ModelFilter.resolve(selection: preferences.model, listed: listed))
            picker = ModelFilter.picker(listed, current: preferences.model)
        }
        _ = refreshModelList(force: false)
        return preferences.model != previous
    }

    /// An explicit refresh still performs a fresh request, even within the startup cooldown.
    public func loadModels() async {
        await refreshModelList(force: true)?.value
    }

    private func refreshModelList(force: Bool) -> Task<Void, Never>? {
        // The explicit settings action remains authorized on its own; only an automatic
        // refresh requires the cloud-consent preference. Revocation invalidates either kind.
        guard force || preferences.cloudConsentGiven else { return nil }
        if !force {
            if let modelListTask { return modelListTask }
            if let lastModelListAttempt, now().timeIntervalSince(lastModelListAttempt) < Self.modelListCooldown { return nil }
        }
        modelListTask?.cancel()
        modelListRevision &+= 1
        let revision = modelListRevision
        lastModelListAttempt = now()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.fetchModelList(revision: revision, requiresConsent: !force)
        }
        modelListTask = task
        return task
    }

    private func acceptsModelList(_ revision: UInt64, requiresConsent: Bool) -> Bool {
        revision == modelListRevision && (!requiresConsent || preferences.cloudConsentGiven) && !Task.isCancelled
    }

    private func fetchModelList(revision: UInt64, requiresConsent: Bool) async {
        defer { if revision == modelListRevision { modelListTask = nil } }
        await loadKeyState()
        guard acceptsModelList(revision, requiresConsent: requiresConsent) else { return }
        guard hasKey else { listingResult = .idle; return }
        listingResult = .listing
        do {
            let rows = try await catalog().list()
            guard acceptsModelList(revision, requiresConsent: requiresConsent) else { return }
            listed = rows
            hasModelList = true
            applyResolution(ModelFilter.resolve(selection: preferences.model, listed: rows))
            picker = ModelFilter.picker(rows, current: preferences.model)
            listingResult = .listed(picker.models.count)
        } catch let OpenAIModelCatalog.CatalogError.http(status, info) {
            guard acceptsModelList(revision, requiresConsent: requiresConsent) else { return }
            listingResult = .httpFailure(status: status, error: info)
        } catch OpenAIModelCatalog.CatalogError.malformed {
            guard acceptsModelList(revision, requiresConsent: requiresConsent) else { return }
            listingResult = .malformedList
        } catch {
            guard acceptsModelList(revision, requiresConsent: requiresConsent) else { return }
            listingResult = .transportFailure(error)
        }
    }

    private func invalidateModelList() {
        modelListRevision &+= 1
        modelListTask?.cancel()
        modelListTask = nil
        lastModelListAttempt = nil
        listed = []
        hasModelList = false
        listingResult = .idle
        picker = ModelFilter.picker([], current: preferences.model)
        retirement = nil
    }

    private func applyResolution(_ r: ModelFilter.Resolution) {
        switch r {
        case .keep: break
        case .fellBackToDefault(let from):
            if preferences.notifiedRetiredFrom != from { retirement = r }
            update { $0.model = ModelFilter.defaultModel; $0.effort = "none"; $0.notifiedRetiredFrom = from }
        case .defaultRetiring:
            if !preferences.notifiedDefaultRetiring { retirement = r }
            update { $0.notifiedDefaultRetiring = true }
        }
    }

    public func dismissNotice() {
        retirement = nil
    }

    /// Picking a model: probe with effort none; a model that rejects none (or is known not to
    /// support it) asks for the yellow-path confirmation instead of switching.
    public func select(model: String) async {
        guard model != preferences.model || probe == .idle else { return }
        candidateResult = .idle
        // 实时可用 measures the selected model: a candidate that is not taken leaves it as it was.
        if model != preferences.model, probeBeforeCandidate == nil { probeBeforeCandidate = probeResult }
        if ModelFilter.known[model]?.supportsEffortNone == false {
            pendingYellow = YellowConfirmation(model: model)
            return
        }
        let r = await runProbe(model: model, effort: "none")
        if let r, r.accepted {
            update { $0.model = model; $0.effort = "none" }
            probeBeforeCandidate = nil
        } else if let r, r.needsLowEffort {
            pendingYellow = YellowConfirmation(model: model)
        } else {
            rejectCandidate()
        }
    }

    /// The user confirmed the yellow path for `pendingYellow`.
    public func confirmYellow() async {
        guard let y = pendingYellow else { return }
        pendingYellow = nil
        let r = await runProbe(model: y.model, effort: "low")
        if let r, r.accepted {
            update { $0.model = y.model; $0.effort = "low" }
            probeBeforeCandidate = nil
        } else {
            rejectCandidate()
        }
    }

    public func cancelYellow() {
        pendingYellow = nil
        restoreProbe()
    }

    public func reprobe() async {
        candidateResult = .idle
        probeBeforeCandidate = nil
        await runProbe(model: preferences.model, effort: preferences.effort)
    }

    /// A candidate's own failure (404, 无响应…) is the model row's status, not 实时可用's.
    private func rejectCandidate() {
        guard probeBeforeCandidate != nil else { return }   // the selected model itself: 实时可用
        if case .probed = probeResult { candidateResult = probeResult }
        restoreProbe()
    }

    private func restoreProbe() {
        if let previous = probeBeforeCandidate { probeResult = previous }
        probeBeforeCandidate = nil
    }

    @discardableResult
    private func runProbe(model: String, effort: String) async -> OpenAIModelCatalog.ProbeResult? {
        await loadKeyState()
        guard hasKey else { probeResult = .idle; return nil }
        probeResult = .probing(model)
        let r = await catalog().probe(model: model, effort: effort,
                                      reasoningBudget: effort == "none" ? 0 : Self.yellowReasoningBudget,
                                      basePolicy: profile.speakHedgePolicy)
        probeResult = .probed(r, model: model, effort: effort)
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
