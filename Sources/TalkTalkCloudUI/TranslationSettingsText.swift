// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation
import TalkTalkCloud
import TalkTalkCore
import TalkTalkSettingsUI

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

    func cloudEnabled(_ direction: TranslationDirection) -> Bool {
        direction == .speak ? speakCloudEnabled : listenCloudEnabled
    }

    /// The direction is set to OpenAI: consent given and its switch on (with or without a key).
    func choosesOpenAI(_ direction: TranslationDirection) -> Bool {
        cloudConsentGiven && cloudEnabled(direction)
    }
}

/// The two translation directions of 模型 › 文本翻译 (§7.9).
public enum TranslationDirection: Sendable, CaseIterable {
    /// 我说的话 → 译文 (SPEAK).
    case speak
    /// 听到的话 → 中文字幕 (LISTEN).
    case listen
}

/// What the 文本翻译 diagram draws (§7.9), from the preferences, whether a key item exists and
/// the preferences the running session started with: one source for the nodes, their switches,
/// the problem line and DataBoundary.
public struct TranslationFlowFacts: Sendable, Equatable {
    public var preferences: TranslationPreferences
    public var hasKey: Bool
    /// False until the key item's presence is known: no "无 key" before that.
    public var keyStateKnown: Bool
    /// The running session's preferences; nil while none runs.
    public var baseline: TranslationPreferences?

    public init(preferences: TranslationPreferences, hasKey: Bool, keyStateKnown: Bool,
                baseline: TranslationPreferences? = nil) {
        self.preferences = preferences
        self.hasKey = hasKey
        self.keyStateKnown = keyStateKnown
        self.baseline = baseline
    }

    /// The node names OpenAI (`network`) rather than Apple (`laptopcomputer`).
    public func choosesOpenAI(_ direction: TranslationDirection) -> Bool { preferences.choosesOpenAI(direction) }

    /// Turning an OpenAI switch on needs consent and a key (§9.1 4d).
    public var switchesEnabled: Bool { preferences.cloudConsentGiven && hasKey }

    /// A switch that is on can always be turned off (to Apple, clearing "无 key → Apple"); one
    /// that is off waits for consent and a key.
    public func switchEnabled(_ direction: TranslationDirection) -> Bool {
        switchesEnabled || choosesOpenAI(direction)
    }

    /// Text goes to OpenAI in some direction: DataBoundary's right panel is connected. The
    /// running session keeps the directions it started with, so they count until it ends; before
    /// the key item's presence is known, a direction set to OpenAI counts too (never show
    /// "未连接" while text may still leave).
    public var cloudConnected: Bool {
        guard hasKey || !keyStateKnown else { return false }
        let now = TranslationDirection.allCases.contains(where: choosesOpenAI)
        let session = baseline.map { b in TranslationDirection.allCases.contains(where: b.choosesOpenAI) } ?? false
        return now || session
    }

    /// The model or its effort changed during the running session, which keeps the one it
    /// started with: the choice waits for the next start.
    public var modelWaits: Bool {
        guard let baseline else { return false }
        return baseline.model != preferences.model || baseline.effort != preferences.effort
    }

    /// The OpenAI section shows once a direction is set to OpenAI or a key exists (§7.9).
    public var showsOpenAISection: Bool { hasKey || TranslationDirection.allCases.contains(where: choosesOpenAI) }

    /// A node's badge: OpenAI chosen without a key (warn), else a choice changed during the
    /// running session (waiting).
    public func badge(_ direction: TranslationDirection) -> SettingsProblem? {
        if choosesOpenAI(direction), keyStateKnown, !hasKey {
            return SettingsProblem(.warn, String(localized: "无 key → Apple"), help: String(localized: "没有 key 时用 Apple 翻译"))
        }
        if let baseline, baseline.choosesOpenAI(direction) != choosesOpenAI(direction) {
            return SettingsProblem(.waiting, String(localized: "下次开始生效"), help: String(localized: "本次仍按开始时的设置"))
        }
        return nil
    }

    /// The page's one problem line: warn before waiting.
    public var problem: SettingsProblem? { SettingsProblem.mostSevere(TranslationDirection.allCases.map(badge)) }

    /// The 文本翻译 card's corner (§7.8), from the facts the page draws: the page's warning
    /// ("无 key → Apple"); else `network` while text goes to OpenAI (the running session's
    /// directions count, as in DataBoundary), turned into a warning by `warning` (a failed key
    /// check, a retired model). Nothing before the key item is known (no false "无 key" on
    /// first open), when nothing leaves this Mac, or for "下次开始生效" (the page says it).
    public func cardBadge(warning: String?) -> CardBadge? {
        guard keyStateKnown else { return nil }
        if let problem, problem.status == .warn { return .status(.warn, problem.text) }
        guard cloudConnected else { return nil }
        guard let warning else { return .cloud(String(localized: "已启用 OpenAI")) }
        // The one corner shows the warning; its help and VoiceOver still say text goes to OpenAI (§5.4).
        return .status(.warn, String(localized: "\(warning) · 已启用 OpenAI"))
    }

    /// The switch's tooltip: what it does, or, while it is off and cannot be turned on, what it
    /// waits for.
    public func switchHelp(_ direction: TranslationDirection) -> String {
        if !switchEnabled(direction) {
            return preferences.cloudConsentGiven ? String(localized: "先保存 key") : String(localized: "先同意发送文字")
        }
        return direction == .speak ? String(localized: "用 OpenAI 翻译我说的话") : String(localized: "用 OpenAI 翻译听到的话")
    }
}

/// User-facing strings for Settings › 模型 › 文本翻译 (§7.9): the shortest words to show, the
/// full sentence for help. Pure, so the mapping is unit-tested.
public enum TranslationSettingsText {
    /// A result in its shortest words and, for help, the whole sentence.
    public struct Message: Sendable, Equatable {
        public let text: String
        public let detail: String?

        public init(_ text: String, detail: String? = nil) {
            self.text = text
            self.detail = detail
        }
    }

    public static let keyPageURL = URL(string: "https://platform.openai.com/api-keys")!

    public static var cloudNotice: String {
        String(localized: "要翻译的文字（你说的话、会议里对方说的话，以及最近几句上下文和术语表）会发给 OpenAI；声音、声音档案和录音不离开这台 Mac。")
    }
    public static var keyAdvice: String { String(localized: "建议单独建一个 project 并设硬性预算上限，再在其中建 key。") }
    /// After a save (§5.4: always visible).
    public static var clearClipboard: String { String(localized: "已存入钥匙串 · 请清空剪贴板") }
    public static var clearClipboardHelp: String { String(localized: "通用剪贴板和剪贴板管理器会留副本") }
    /// An existing key item: its value is never read, so there is no last four to show.
    public static let savedKeyMask = "sk-…•••"

    // MARK: checks

    static var verifying: String { String(localized: "正在验证…") }
    static var listing: String { String(localized: "正在读取…") }
    static func probing(_ model: String) -> String { String(localized: "正在测 \(model)…") }
    static func listed(_ count: Int) -> String { String(localized: "\(count) 个可选模型") }
    static var malformedList: Message { Message(String(localized: "OpenAI 出错"), detail: String(localized: "模型列表的格式看不懂。")) }
    static var noKey: Message { Message(String(localized: "无 key"), detail: String(localized: "还没有 key。")) }
    static func verified(model: String) -> Message {
        Message(String(localized: "key 可用"), detail: String(localized: "模型 \(model) 探针通过"))
    }

    /// Why a verification step failed (§7.7 验证). Never contains the key or `error.message`.
    public static func failure(status: Int, error: OpenAIErrorInfo?, cloud: PolicyProfile.Cloud) -> Message {
        let code = codeSuffix(error)
        if status == 401 {
            return Message(String(localized: "key 无效 · 401"), detail: String(localized: "key 无效、已撤销，或不属于任何组织（HTTP 401）。"))
        }
        if status == 403 {
            return Message(String(localized: "被拒绝 · 403"),
                           detail: String(localized: "OpenAI 拒绝了请求：你所在的国家或地区不受支持，或 key 缺少权限（HTTP 403）。"))
        }
        if status == 404 {
            return Message(String(localized: "模型不存在 · 404"), detail: String(localized: "这个模型不存在或已下线（HTTP 404）。"))
        }
        switch OpenAIErrorClassifier.classify(status: status, error: error, retryAfterS: nil, cloud: cloud) {
        case .pause:
            return Message(String(localized: "额度用完 → Apple"),
                           detail: String(localized: "额度用完或预算上限已到（HTTP \(String(status))\(code)）。云端翻译会暂停，改用 Apple 翻译。"))
        case .rateLimited:
            return Message(String(localized: "请求太频繁"), detail: String(localized: "请求太频繁，稍后再试（HTTP 429\(code)）。"))
        case .http5xx:
            return Message(String(localized: "OpenAI 出错 · \(String(status))"),
                           detail: String(localized: "OpenAI 暂时出错（HTTP \(String(status))），稍后再试。"))
        default:
            return Message(String(localized: "OpenAI 出错 · \(String(status))"),
                           detail: String(localized: "OpenAI 返回 HTTP \(String(status))\(code)。"))
        }
    }

    public static func transportFailure(_ error: any Error) -> Message {
        if let e = error as? OpenAIClient.ClientError, e == .noKey { return noKey }
        return Message(String(localized: "连不上"), detail: String(localized: "暂时连不上 OpenAI，稍后再试。"))
    }

    private static func codeSuffix(_ e: OpenAIErrorInfo?) -> String {
        if let c = e?.code { return String(localized: "，\(c)") }
        if let t = e?.type { return String(localized: "，\(t)") }
        return ""
    }

    /// The probe's reject reasons (§5.4).
    public static func probeFailure(_ r: OpenAIModelCatalog.ProbeResult, cloud: PolicyProfile.Cloud) -> Message {
        if let s = r.httpStatus, s != 200 { return failure(status: s, error: r.error, cloud: cloud) }
        if r.httpStatus == nil {
            return Message(String(localized: "无响应"), detail: String(localized: "探针没有收到响应（超时或连不上）。"))
        }
        switch r.rejectReason {
        case .some(let reason) where reason.contains("reasoning"):
            return Message(String(localized: "仍有推理 token"),
                           detail: String(localized: "这个模型在 effort \(r.effort) 下仍有推理 token，不能用于实时翻译。"))
        case .some(let reason) where reason.contains("incomplete"):
            return Message(String(localized: "响应不完整"), detail: String(localized: "响应不完整（输出上限被推理用完）。"))
        case .some(let reason):
            return Message(String(localized: "探针没通过"), detail: String(localized: "探针没通过：\(reason)。"))
        case .none:
            return Message(String(localized: "探针没通过"))
        }
    }

    /// A model that rejects effort none: only the yellow path (§11).
    static func needsLowEffort(_ model: String) -> Message {
        Message(String(localized: "会明显变慢"), detail: String(localized: "\(model) 不支持 effort none，只能走黄色路径（会明显变慢）。"))
    }

    /// One probe measurement (§11): "首字 N ms · 共 N ms"; the model, effort and "一次测量" go
    /// to help.
    public static func timing(_ r: OpenAIModelCatalog.ProbeResult, model: String, effort: String) -> Message {
        let first = r.firstDeltaMs.map { "\($0) ms" } ?? "—"
        let total = r.totalMs.map { "\($0) ms" } ?? "—"
        return Message(String(localized: "首字 \(first) · 共 \(total)"),
                       detail: String(localized: "\(model) · effort \(effort) · 一次测量"))
    }

    // MARK: key section

    /// The rows under the key (§7.9): a refused paste alone; otherwise the check and, after a
    /// save, the clipboard reminder, which a passed check joins (its words move to the help).
    public static func keyResults(pasteProblem: SettingsProblem?, verification: TranslationSettingsModel.Check,
                                  saved: Bool) -> [SettingsProblem] {
        if let pasteProblem { return [pasteProblem] }
        let check = verification.line
        guard saved else { return check.map { [$0] } ?? [] }
        if case .ok = verification, let check {
            return [SettingsProblem(.ok, clearClipboard, help: [check.help ?? check.text, clearClipboardHelp].joined(separator: " · "))]
        }
        return (check.map { [$0] } ?? []) + [SettingsProblem(.ok, clearClipboard, help: clearClipboardHelp)]
    }

    static var consentFirst: SettingsProblem { SettingsProblem(.failed, String(localized: "请先同意发送文字")) }

    static func notAKey(_ why: String) -> SettingsProblem {
        SettingsProblem(.failed, String(localized: "不像 OpenAI key"), help: String(localized: "这不像 OpenAI key：\(why)。"))
    }

    static func keychainWriteFailed(_ status: Int32?) -> SettingsProblem {
        SettingsProblem(.failed, String(localized: "写入钥匙串失败"), help: status.map { "OSStatus \($0)" })
    }

    static func deleteFailed(_ status: Int32?) -> SettingsProblem {
        SettingsProblem(.failed, String(localized: "删除失败"), help: status.map { "OSStatus \($0)" })
    }

    // MARK: OpenAI section

    /// The model menu's item: the id, " · 默认" for the default (§7.9: the only suffix left).
    public static func choiceTitle(_ c: ModelFilter.Choice) -> String {
        c.isDefault ? String(localized: "\(c.id) · 默认") : c.id
    }

    /// The model menu's item glyph: going away, or slow (needs reasoning); nil for the rest.
    public static func choiceSymbol(_ c: ModelFilter.Choice) -> String? {
        if c.retiring { return SubtitleTokens.SettingsIcon.retiring }
        if c.known?.supportsEffortNone == false { return SubtitleTokens.SettingsIcon.slow }
        return nil
    }

    /// The model menu item as VoiceOver reads it: the glyph's meaning in words (the visible
    /// suffixes are gone, §7.9; §1.2: AX carries at least what they said).
    public static func choiceSpoken(_ c: ModelFilter.Choice) -> String {
        let title = choiceTitle(c)
        if c.retiring { return String(localized: "\(title)，即将下线") }
        if c.known?.supportsEffortNone == false { return String(localized: "\(title)，会明显变慢") }
        return title
    }

    /// The cost line (§11 费用, 估). `yellow`: the model runs on effort low.
    public static func cost(for model: String, yellow: Bool) -> String {
        if let usd = ModelFilter.known[model]?.usdPerMeetingHour {
            let amount = String(format: "%.2f", usd)
            return yellow ? String(localized: "≈ $\(amount)/小时（估）+ 推理") : String(localized: "≈ $\(amount)/小时（估）")
        }
        return String(localized: "见 OpenAI 定价")
    }

    /// The cost line's help.
    public static func costHelp(yellow: Bool) -> String {
        yellow ? String(localized: "按会议小时估，含对冲；推理另计") : String(localized: "按会议小时估，含对冲")
    }

    /// The retirement notice (§7.9): "X 已下线 → Y" or "Y 即将下线".
    public static func retirementNotice(_ r: ModelFilter.Resolution) -> String? {
        switch r {
        case .keep: nil
        case .fellBackToDefault(let from): String(localized: "\(from) 已下线 → \(ModelFilter.defaultModel)")
        case .defaultRetiring: String(localized: "\(ModelFilter.defaultModel) 即将下线")
        }
    }

    public static func retirementHelp(_ r: ModelFilter.Resolution?) -> String? {
        switch r {
        case .fellBackToDefault?: String(localized: "已换回默认模型")
        case .defaultRetiring?: String(localized: "可在这里另选一个模型")
        case .keep?, nil: nil
        }
    }
}
