// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation
import Speech
import TalkTalkCore
import Translation

/// Startup check item 6, "Apple 侧" (ARCHITECTURE.md): selected speech assets (installed,
/// reserved), translation availability between selected languages, and `.highFidelity` support.
/// Chinese and English are required; German/French participate only when selected.
/// Runs no process, downloads nothing, and never removes existing assets or reservations.
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

    /// Supported choices for resource pickers; readiness requirements come from the selection.
    public static let locales: [Lang] = Lang.allCases
    static let pairs: [(MTSession, String)] = MTSession.allCases.filter { !$0.isSpeak }.map {
        ($0, "\($0.direction.source.rawValue)-\($0.direction.target.rawValue)")
    }

    static func pairs(for selection: SpeechResourceSelection) -> [(MTSession, String)] {
        pairs.filter { session, _ in
            selection.languages.contains(session.direction.source) && selection.languages.contains(session.direction.target)
        }
    }

    public static func evaluate(_ r: Report, selection: SpeechResourceSelection = .init()) -> Verdict {
        guard r.transcriberAvailable else { return .unavailable([String(appLocalized: "这台 Mac 不支持系统语音识别（SpeechTranscriber）")]) }
        var problems: [String] = []
        let hasSpeech = selection.orderedLanguages.contains { r.speech[AppleSpeechASR.localeIdentifier($0)] == "installed" }
        for l in selection.orderedLanguages {
            let id = AppleSpeechASR.localeIdentifier(l)
            switch r.speech[id] {
            case "installed": if !r.reserved.contains(id) { problems.append(String(appLocalized: "\(id) 语音资源没有预留，系统可能清理它")) }
            case "downloading": problems.append(String(appLocalized: "\(id) 语音资源正在下载"))
            case "unsupported": problems.append(String(appLocalized: "\(id) 不支持语音识别"))
            default: problems.append(String(appLocalized: "\(id) 语音资源未下载"))
            }
        }
        for (_, key) in pairs(for: selection) where r.translation[key] != "installed" {
            if r.translation[key] == "supported" {
                problems.append(String(appLocalized: "\(key) 翻译语言包未下载（系统设置 › 通用 › 语言与地区 › 翻译语言）"))
            } else {
                problems.append(String(appLocalized: "\(key) 翻译语言包不可用（系统设置 › 通用 › 语言与地区 › 翻译语言）"))
            }
        }
        if !hasSpeech { return .unavailable([String(appLocalized: "所选语言的语音资源都未下载：没法生成字幕")] + problems) }
        return problems.isEmpty ? .ok : .degraded(problems)
    }

    public static func run(selection: SpeechResourceSelection = .load()) async -> Report {
        var speech: [String: String] = [:]
        for l in selection.orderedLanguages {
            let t = AppleSpeechASR.makeTranscriber(l)
            speech[AppleSpeechASR.localeIdentifier(l)] = name(await AssetInventory.status(forModules: [t]))
        }
        let reserved = await AssetInventory.reservedLocales.map { $0.identifier(.bcp47) }
        var translation: [String: String] = [:]
        if #available(macOS 26.4, *) {
            for (s, key) in pairs(for: selection) { translation[key] = await AppleTranslationMT.availability(s) }
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
    private let selection: SpeechResourceSelection

    public init(selection: SpeechResourceSelection = .load()) { self.selection = selection }

    public func run() async -> StartupCheckResult {
        Self.result(await AppleStartupCheck.run(selection: selection), selection: selection)
    }

    /// unavailable → action (no subtitles at all); degraded → notice (one language or one
    /// direction missing, the rest works).
    public static func result(_ r: AppleStartupCheck.Report, selection: SpeechResourceSelection = .init()) -> StartupCheckResult {
        var details: [String: String] = ["transcriber": r.transcriberAvailable ? "available" : "unavailable",
                                         "reserved": "\(r.reserved.count)/\(r.maxReserved)"]
        for language in selection.orderedLanguages {
            let locale = AppleSpeechASR.localeIdentifier(language)
            if let status = r.speech[locale] { details["speech.\(locale)"] = status }
        }
        for (_, key) in AppleStartupCheck.pairs(for: selection) {
            if let status = r.translation[key] { details["translation.\(key)"] = status }
        }
        switch AppleStartupCheck.evaluate(r, selection: selection) {
        case .ok:
            return StartupCheckResult(id: "apple", level: .ok, summary: String(appLocalized: "所选 Apple 语音和翻译资源齐全"), details: details)
        case let .degraded(p):
            return StartupCheckResult(id: "apple", level: .notice, summary: summary(p), details: details)
        case let .unavailable(p):
            return StartupCheckResult(id: "apple", level: .action, summary: summary(p), details: details)
        }
    }

    static func summary(_ p: [String]) -> String {
        (p.first ?? "") + (p.count > 1 ? String(appLocalized: " 等 \(p.count) 项") : "")
    }
}
