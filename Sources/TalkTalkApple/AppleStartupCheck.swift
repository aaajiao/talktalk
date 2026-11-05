import Foundation
import Speech
import TalkTalkCore
import Translation

/// Startup check item 6, "Apple 侧" (ARCHITECTURE.md §7.5): speech assets for zh-CN / en-US /
/// de-DE (installed, reserved — 3 of the system's reservation slots), Translation availability
/// per direction, and whether `.highFidelity` is usable. Runs no process, downloads nothing.
/// `evaluate` is pure; the `StartupCheckItem` adapter (talktalk-m0's protocol) wraps `run`.
public enum AppleStartupCheck {
    public struct Report: Sendable, Equatable, Codable {
        public var transcriberAvailable: Bool
        /// locale id → installed / downloading / supported / unsupported
        public var speech: [String: String]
        public var reserved: [String]
        public var maxReserved: Int
        /// "en-zh" … → installed / supported / unsupported
        public var translation: [String: String]

        public init(transcriberAvailable: Bool, speech: [String: String], reserved: [String], maxReserved: Int,
                    translation: [String: String]) {
            self.transcriberAvailable = transcriberAvailable; self.speech = speech; self.reserved = reserved
            self.maxReserved = maxReserved; self.translation = translation
        }
    }

    public enum Verdict: Sendable, Equatable {
        case ok
        /// Works, with gaps the user can fix (download in onboarding step 2 / System Settings).
        case degraded([String])
        /// LISTEN cannot run.
        case unavailable([String])
    }

    public static let locales: [Lang] = [.zh, .en, .de]
    static let pairs: [(MTSession, String)] = [(.listenEnZh, "en-zh"), (.listenDeZh, "de-zh"), (.speakZhEn, "zh-en"), (.speakZhDe, "zh-de")]

    public static func evaluate(_ r: Report) -> Verdict {
        guard r.transcriberAvailable else { return .unavailable(["这台 Mac 不支持系统语音识别（SpeechTranscriber）"]) }
        var problems: [String] = []
        let en = r.speech["en-US"] == "installed", de = r.speech["de-DE"] == "installed"
        for l in locales {
            let id = AppleSpeechASR.localeIdentifier(l)
            switch r.speech[id] {
            case "installed": if !r.reserved.contains(id) { problems.append("\(id) 语音资源没有预留，系统可能清理它") }
            case "downloading": problems.append("\(id) 语音资源正在下载")
            case "unsupported": problems.append("\(id) 不支持语音识别")
            default: problems.append("\(id) 语音资源未下载")
            }
        }
        for (_, key) in pairs where r.translation[key] != "installed" {
            problems.append("\(key) 翻译语言包\(r.translation[key] == "supported" ? "未下载" : "不可用")（系统设置 › 通用 › 语言与地区 › 翻译语言）")
        }
        if !en && !de { return .unavailable(["en-US 和 de-DE 的语音资源都没有：没法生成字幕"] + problems) }
        return problems.isEmpty ? .ok : .degraded(problems)
    }

    public static func run() async -> Report {
        var speech: [String: String] = [:]
        for l in locales {
            let t = AppleSpeechASR.makeTranscriber(l)
            speech[AppleSpeechASR.localeIdentifier(l)] = name(await AssetInventory.status(forModules: [t]))
        }
        let reserved = await AssetInventory.reservedLocales.map { $0.identifier(.bcp47) }
        var translation: [String: String] = [:]
        if #available(macOS 26.4, *) {
            for (s, key) in pairs { translation[key] = await AppleTranslationMT.availability(s) }
        }
        return Report(transcriberAvailable: SpeechTranscriber.isAvailable, speech: speech, reserved: reserved,
                      maxReserved: AssetInventory.maximumReservedLocales, translation: translation)
    }

    static func name(_ s: AssetInventory.Status) -> String {
        switch s {
        case .installed: "installed"
        case .downloading: "downloading"
        case .supported: "supported"
        case .unsupported: "unsupported"
        @unknown default: "unknown"
        }
    }
}

/// §7.5 item 6 for `StartupChecker` (talktalk-m0's protocol). Status APIs only: no process, no
/// network, no prompt; the summary and details hold locale ids and status words, never a path.
public struct AppleStartupCheckItem: StartupCheckItem {
    public let id = "apple"

    public init() {}

    public func run() async -> StartupCheckResult {
        Self.result(await AppleStartupCheck.run())
    }

    /// unavailable → action (no subtitles at all); degraded → notice (one language or one
    /// direction missing, the rest works).
    public static func result(_ r: AppleStartupCheck.Report) -> StartupCheckResult {
        var details: [String: String] = ["transcriber": r.transcriberAvailable ? "available" : "unavailable",
                                         "reserved": "\(r.reserved.count)/\(r.maxReserved)"]
        for (k, v) in r.speech { details["speech.\(k)"] = v }
        for (k, v) in r.translation { details["translation.\(k)"] = v }
        switch AppleStartupCheck.evaluate(r) {
        case .ok:
            return StartupCheckResult(id: "apple", level: .ok, summary: "Apple 语音和翻译资源齐全", details: details)
        case let .degraded(p):
            return StartupCheckResult(id: "apple", level: .notice, summary: summary(p), details: details)
        case let .unavailable(p):
            return StartupCheckResult(id: "apple", level: .action, summary: summary(p), details: details)
        }
    }

    static func summary(_ p: [String]) -> String {
        (p.first ?? "") + (p.count > 1 ? " 等 \(p.count) 项" : "")
    }
}
