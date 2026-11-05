import Foundation
import TalkTalkCloud
import TalkTalkCore

/// Where the key lives. `KeychainSecret` in the app; an in-memory store in tests.
/// The settings page checks only existence; secret reads are reserved for the Authorization header.
public protocol APIKeyStore: Sendable {
    func exists() -> Bool
    func read() throws -> Data
    func store(_ secret: Data) throws
    func delete() throws
}

extension KeychainSecret: APIKeyStore {}

/// Persisted values of Settings › 翻译 (§11). UserDefaults only; never the key.
public struct TranslationPreferences: Sendable, Equatable {
    public static let prefix = "translation."
    public var model: String = ModelFilter.defaultModel
    /// "none" on the normal path, "low" on the yellow path (§11).
    public var effort: String = "none"
    public var speakCloudEnabled = true
    public var listenCloudEnabled = true
    public var cloudConsentGiven = false
    public var meetingReminderEnabled = true
    public var showSnapshots = false
    /// Retirement notices are shown once (§11 下线回退).
    public var notifiedRetiredFrom: String?
    public var notifiedDefaultRetiring = false

    public init() {}

    public static func load(_ d: UserDefaults) -> TranslationPreferences {
        var p = TranslationPreferences()
        func s(_ k: String) -> String? { d.string(forKey: prefix + k) }
        func b(_ k: String, _ def: Bool) -> Bool { d.object(forKey: prefix + k) == nil ? def : d.bool(forKey: prefix + k) }
        p.model = s("model") ?? p.model
        p.effort = s("effort") ?? p.effort
        p.speakCloudEnabled = b("speakCloudEnabled", true)
        p.listenCloudEnabled = b("listenCloudEnabled", true)
        p.cloudConsentGiven = b("cloudConsentGiven", false)
        p.meetingReminderEnabled = b("meetingReminderEnabled", true)
        p.showSnapshots = b("showSnapshots", false)
        p.notifiedRetiredFrom = s("notifiedRetiredFrom")
        p.notifiedDefaultRetiring = b("notifiedDefaultRetiring", false)
        return p
    }

    public func save(_ d: UserDefaults) {
        let k = Self.prefix
        d.set(model, forKey: k + "model")
        d.set(effort, forKey: k + "effort")
        d.set(speakCloudEnabled, forKey: k + "speakCloudEnabled")
        d.set(listenCloudEnabled, forKey: k + "listenCloudEnabled")
        d.set(cloudConsentGiven, forKey: k + "cloudConsentGiven")
        d.set(meetingReminderEnabled, forKey: k + "meetingReminderEnabled")
        d.set(showSnapshots, forKey: k + "showSnapshots")
        d.set(notifiedRetiredFrom, forKey: k + "notifiedRetiredFrom")
        d.set(notifiedDefaultRetiring, forKey: k + "notifiedDefaultRetiring")
    }

    /// Both directions off: no keep-warm and no connection to OpenAI (§11).
    public var anyCloud: Bool { speakCloudEnabled || listenCloudEnabled }
}

/// User-facing strings for Settings › 翻译. Pure, so the mapping is unit-tested.
public enum TranslationSettingsText {
    public static let keyPageURL = URL(string: "https://platform.openai.com/api-keys")!

    public static let cloudNotice = "要翻译的文字（你说的话、会议里对方说的话，以及最近几句上下文和术语表）会发给 OpenAI；声音、声音档案和录音不离开这台 Mac。"
    public static let keyAdvice = "建议在 OpenAI 网站单独建一个 project，给它设硬性预算上限，再在那个 project 里建 key。"
    public static let clearClipboard = "已保存。请清空剪贴板：通用剪贴板和剪贴板管理器会留副本。"

    /// Why a verification step failed (§7.7 验证). Never contains the key or `error.message`.
    public static func failure(status: Int, error: OpenAIErrorInfo?, cloud: PolicyProfile.Cloud) -> String {
        if status == 401 { return "key 无效、已撤销，或不属于任何组织（HTTP 401）。" }
        if status == 403 { return "OpenAI 拒绝了请求：你所在的国家或地区不受支持，或 key 缺少权限（HTTP 403）。" }
        if status == 404 { return "这个模型不存在或已下线（HTTP 404）。" }
        switch OpenAIErrorClassifier.classify(status: status, error: error, retryAfterS: nil, cloud: cloud) {
        case .pause: return "额度用完或预算上限已到（HTTP \(status)\(codeSuffix(error))）。云端翻译会暂停，改用 Apple 翻译。"
        case .rateLimited: return "请求太频繁，稍后再试（HTTP 429\(codeSuffix(error))）。"
        case .http5xx: return "OpenAI 暂时出错（HTTP \(status)），稍后再试。"
        default: return "OpenAI 返回 HTTP \(status)\(codeSuffix(error))。"
        }
    }

    public static func transportFailure(_ error: any Error) -> String {
        if let e = error as? OpenAIClient.ClientError, e == .noKey { return "还没有 key。" }
        return "暂时连不上 OpenAI，稍后再试。"
    }

    private static func codeSuffix(_ e: OpenAIErrorInfo?) -> String {
        if let c = e?.code { return "，\(c)" }
        if let t = e?.type { return "，\(t)" }
        return ""
    }

    /// The probe's reject reasons (§5.4) in words.
    public static func probeFailure(_ r: OpenAIModelCatalog.ProbeResult, cloud: PolicyProfile.Cloud) -> String {
        if let s = r.httpStatus, s != 200 { return failure(status: s, error: r.error, cloud: cloud) }
        if r.httpStatus == nil { return "探针没有收到响应（超时或连不上）。" }
        switch r.rejectReason {
        case .some(let reason) where reason.contains("reasoning"): return "这个模型在 effort \(r.effort) 下仍有推理 token，不能用于实时翻译。"
        case .some(let reason) where reason.contains("incomplete"): return "响应不完整（输出上限被推理用完）。"
        case .some(let reason): return "探针没通过：\(reason)。"
        case .none: return "探针没通过。"
        }
    }

    /// The cost line (§11 费用, 估). `yellow`: the model runs on effort low.
    public static func cost(for model: String, yellow: Bool) -> String {
        if let usd = ModelFilter.known[model]?.usdPerMeetingHour {
            let base = String(format: "约 $%.2f / 会议小时（估，含对冲）", usd)
            return yellow ? base + " + 推理 token" : base
        }
        return yellow ? "见 OpenAI 定价（推理 token 另计）" : "见 OpenAI 定价"
    }

    /// One probe measurement, labelled as a reference value (§11).
    public static func timing(_ r: OpenAIModelCatalog.ProbeResult) -> String {
        let first = r.firstDeltaMs.map { "\($0) ms" } ?? "—"
        let total = r.totalMs.map { "\($0) ms" } ?? "—"
        return "首个 delta \(first) · 总时长 \(total)（参考，一次测量）"
    }

    public static func retirementNotice(_ r: ModelFilter.Resolution) -> String? {
        switch r {
        case .keep: nil
        case .fellBackToDefault(let from): "所选模型 \(from) 已下线，已换回 \(ModelFilter.defaultModel)。"
        case .defaultRetiring: "默认模型 \(ModelFilter.defaultModel) 即将下线，请在这里另选一个。"
        }
    }
}
