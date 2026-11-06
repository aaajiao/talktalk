// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation
import TalkTalkAudio
import TalkTalkCore

/// Settings, menu and onboarding flow rules (redesign §7, F1–F11). Pure: the menu, the
/// scenario page and the phone checklist render what these values say.
extension MeetingMode {
    /// The shared subtitle scene of this listening mode (titlebar, icons, titles).
    public var scene: SubtitleScene {
        switch self {
        case .meeting: .meeting
        case .phone: .phone
        case .captions: .video
        }
    }

    /// The scene's unified icon (§2 图标).
    public var sceneSymbol: String { scene.symbol }

    /// The scene card's purpose (settings visual system §3.1): only its help and VoiceOver hint;
    /// the card itself shows no summary line.
    public var sceneSummary: String {
        switch self {
        case .meeting: String(localized: "电脑会议 · 双向同传")
        case .phone: String(localized: "iPhone 号码 · 双向同传")
        case .captions: String(localized: "看视频 · 双语字幕")
        }
    }
}

/// Persisted scenario choices: the settings page's browsing selection (`ui.requestedScenario`)
/// and the last scenario that actually started (`ui.lastScenario`, for the menu quick start).
public enum ScenarioPreferences {
    public static let requestedKey = "ui.requestedScenario"
    public static let lastKey = "ui.lastScenario"

    public static func requested(defaults: UserDefaults = .standard) -> MeetingMode {
        MeetingMode(rawValue: defaults.string(forKey: requestedKey) ?? "") ?? .meeting
    }

    public static func setRequested(_ mode: MeetingMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: requestedKey)
    }

    /// nil until a session has started once.
    public static func last(defaults: UserDefaults = .standard) -> MeetingMode? {
        MeetingMode(rawValue: defaults.string(forKey: lastKey) ?? "")
    }

    public static func setLast(_ mode: MeetingMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: lastKey)
    }
}

/// The idle menu's bold first item (§7 菜单栏): the last scenario with its remembered source.
/// It starts directly; the scenario page opens only on failure or when a source must be chosen.
public struct MenuQuickStart: Sendable, Equatable {
    public var mode: MeetingMode
    public var title: String
    /// Gray line under it ("上次：会议同传 · 英语 → 中文"); nil before the first session.
    public var lastLine: String?
    public static let symbol = "play.fill"

    /// `sourceName`: the remembered source's display name; nil means automatic selection.
    public static func make(last: MeetingMode?, sourceName: String?, remoteLanguage: String) -> MenuQuickStart {
        let mode = last ?? .meeting
        let source = sourceName ?? String(localized: "自动选择")
        let title: String = switch mode {
        case .meeting: String(localized: "开始会议同传 · \(source)")
        case .phone: String(localized: "准备电话同传")
        case .captions: String(localized: "开始视频字幕 · \(source)")
        }
        let line = last.map { String(localized: "上次：\($0.scene.title) · \(remoteLanguage) → 中文") }
        return MenuQuickStart(mode: mode, title: title, lastLine: line)
    }

    /// The display name of a remembered source id; nil for automatic selection.
    public static func sourceName(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return MeetingApp.named(id)?.name ?? id
    }
}

/// The in-session menu header: "会议同传 · Zoom · 12:03".
public enum MenuSessionHeader {
    public static func title(mode: MeetingMode, source: String?, elapsed: TimeInterval?) -> String {
        var parts = [mode.scene.title]
        let shown = mode == .phone ? "Phone" : source
        if let shown, !shown.isEmpty { parts.append(shown) }
        if let elapsed { parts.append(SessionClock.elapsed(elapsed)) }
        return parts.joined(separator: " · ")
    }
}

/// The colour family of a voice-state dot outside the subtitle panel (menu, settings).
public enum VoiceTone: Sendable, Equatable {
    case original, translate, warn, risk, neutral
}

extension VoiceState.Appearance {
    public var tone: VoiceTone {
        switch self {
        case .originalFill: .original
        case .translateFill, .translateStroke: .translate
        case .warnStroke, .warnFill: .warn
        case .riskFill: .risk
        case .dimStroke, .dashed, .neutral: .neutral
        }
    }
}

/// What the scenario page says about a running session while the user browses (§7 使用场景页).
/// The action bar stays locked to the running scenario (§33).
public struct ScenarioRunState: Sendable, Equatable {
    /// nil when no session is starting, running or stopping.
    public var running: MeetingMode?
    public var browsing: MeetingMode

    public init(running: MeetingMode?, browsing: MeetingMode) {
        self.running = running
        self.browsing = browsing
    }

    /// The bottom bar's fixed left text: "正在运行：会议同传 · Zoom".
    public func runningLine(source: String?) -> String? {
        guard let running else { return nil }
        let shown = running == .phone ? "Phone" : source
        if let shown, !shown.isEmpty {
            return String(localized: "正在运行：\(running.scene.title) · \(shown)")
        }
        return String(localized: "正在运行：\(running.scene.title)")
    }

    /// The pinned banner when browsing a scenario that is not running.
    public var banner: (text: String, returnTitle: String)? {
        guard let running, running != browsing else { return nil }
        return (String(localized: "\(running.scene.title)正在运行，结束后才能开始\(browsing.scene.title)"),
                String(localized: "回到\(running.scene.title)"))
    }
}

/// The browser tab note appears only when the chosen source is a browser (§7 文案).
public enum ScenarioSourceNote {
    public static func showsBrowserNote(selectedID: String) -> Bool {
        MeetingApp.named(selectedID)?.isBrowser == true
    }
}

/// The phone page's three-step checklist (§7 电话页). ① prepares the session (the same action
/// as the bottom bar), ② dials or answers in Phone and is dimmed until ① is ready, ③ explains
/// ending after hanging up.
public struct PhoneChecklist: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case pending, inProgress, done }

    public var prepare: Status
    public var dial: Status
    public var finish: Status
    /// ② is usable only after ① is ready.
    public var dialEnabled: Bool { prepare == .done }

    /// `phoneSession`: the running (or starting/stopping) session is the phone scenario.
    public static func make(phoneSession: Bool, starting: Bool, stopping: Bool, active: Bool,
                            readyToDial: Bool, dialing: Bool, callAudioActive: Bool) -> PhoneChecklist {
        guard phoneSession else { return PhoneChecklist(prepare: .pending, dial: .pending, finish: .pending) }
        let prepare: Status
        if active, readyToDial, !stopping { prepare = .done }
        else if starting || stopping || active { prepare = .inProgress }
        else { prepare = .pending }
        let dial: Status = prepare != .done ? .pending : callAudioActive ? .done : dialing ? .inProgress : .pending
        let finish: Status = stopping ? .inProgress : .pending
        return PhoneChecklist(prepare: prepare, dial: dial, finish: finish)
    }
}
