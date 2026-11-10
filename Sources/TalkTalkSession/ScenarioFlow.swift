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
        case .meeting: String(appLocalized: "电脑会议 · 双向同传")
        case .phone: String(appLocalized: "iPhone 号码 · 双向同传")
        case .captions: String(appLocalized: "看视频 · 双语字幕")
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

/// The idle menu's bold first item (settings visual system §8.3): the last scenario with its
/// remembered source ("开始会议同传 · Zoom", "· 自动" for automatic selection) and its language
/// pair as the native subtitle. It starts directly; the scenario page opens only on failure or
/// when a source must be chosen.
public struct MenuQuickStart: Sendable, Equatable {
    public var mode: MeetingMode
    public var title: String
    /// Gray line under it: "英语 → 中文".
    public var subtitle: String
    public static let symbol = "play.fill"

    /// `sourceName`: the remembered source's display name; nil means automatic selection.
    public static func make(last: MeetingMode?, sourceName: String?, remoteLanguage: String,
                            targetLanguage: String = String(appLocalized: "中文")) -> MenuQuickStart {
        let mode = last ?? .meeting
        let source = sourceName ?? String(appLocalized: "自动")
        let title: String = switch mode {
        case .meeting: String(appLocalized: "开始会议同传 · \(source)")
        case .phone: String(appLocalized: "准备电话同传")
        case .captions: String(appLocalized: "开始视频字幕 · \(source)")
        }
        return MenuQuickStart(mode: mode, title: title, subtitle: String(appLocalized: "\(remoteLanguage) → \(targetLanguage)"))
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

/// The scenario page's bottom bar (settings visual system §3.15): its primary button for the
/// browsed scene, locked to the session that is starting, running or stopping (§33). There is no
/// running banner: the running scene's card and the bar's left side say which one runs.
public struct ScenarioRunState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case idle, starting, running, stopping }

    public enum Action: Sendable, Equatable {
        /// 开始 (电话：准备) the browsed scene.
        case start(MeetingMode)
        /// 结束 the running scene, which is the browsed one.
        case end(MeetingMode)
        /// 准备中… or 结束中…, disabled.
        case progress(MeetingMode, ending: Bool)
        /// Another scene runs: disabled, "先结束<运行中场景>".
        case blocked(running: MeetingMode)
    }

    /// The session's scene; ignored while idle.
    public var running: MeetingMode?
    public var phase: Phase
    public var browsing: MeetingMode

    public init(running: MeetingMode?, phase: Phase, browsing: MeetingMode) {
        self.running = phase == .idle ? nil : running
        self.phase = running == nil ? .idle : phase
        self.browsing = browsing
    }

    public var action: Action {
        guard let running else { return .start(browsing) }
        switch phase {
        case .idle: return .start(browsing)
        case .starting: return .progress(running, ending: false)
        case .stopping: return .progress(running, ending: true)
        case .running: return running == browsing ? .end(running) : .blocked(running: running)
        }
    }

    /// The button's short word (§5.5): 开始 / 准备 / 结束 / 准备中… / 结束中….
    public var title: String {
        switch action {
        case let .start(mode): mode == .phone ? String(appLocalized: "准备") : String(appLocalized: "开始")
        case .end: String(appLocalized: "结束")
        case let .progress(_, ending): ending ? String(appLocalized: "结束中…") : String(appLocalized: "准备中…")
        case .blocked: browsing == .phone ? String(appLocalized: "准备") : String(appLocalized: "开始")
        }
    }

    /// nil while in progress (a spinner instead).
    public var symbol: String? {
        switch action {
        case .start, .blocked: MenuQuickStart.symbol
        case .end: SubtitleTokens.SettingsIcon.stop
        case .progress: nil
        }
    }

    /// The full action for VoiceOver, as the menu and the titlebar name it.
    public var accessibilityLabel: String {
        switch action {
        case let .start(mode): Self.startLabel(mode)
        case .blocked: Self.startLabel(browsing)
        case let .end(mode): mode.scene.endAccessibilityLabel
        case let .progress(mode, ending):
            ending ? String(appLocalized: "正在结束\(mode.scene.title)…") : String(appLocalized: "正在准备\(mode.scene.title)…")
        }
    }

    /// 结束: what the meeting or call receives afterwards; blocked: which scene to end first;
    /// 准备中… for another scene: which one prepares (the menu's words); while macOS downloads
    /// the speech assets for the start: 下载中.
    public func help(systemInputSwitched: Bool, downloadingAssets: Bool = false) -> String? {
        switch action {
        case let .end(mode): mode.scene.endHelp(systemInputSwitched: systemInputSwitched)
        case let .blocked(running): String(appLocalized: "先结束\(running.scene.title)")
        case let .progress(mode, ending):
            !ending && downloadingAssets ? String(appLocalized: "下载中") : mode != browsing ? accessibilityLabel : nil
        case .start: nil
        }
    }

    /// Why a start waits, for the menu's quick start and the page's 开始 alike (§8.2): onboarding
    /// first, then a self-test, speaking test or maintenance that holds the audio (the alert's
    /// sentence); nil when it can start.
    public static func startBlocked(onboardingNeeded: Bool, available: Bool) -> String? {
        if onboardingNeeded { return String(appLocalized: "完成引导后可用") }
        return available ? nil : String(appLocalized: "请先结束正在运行的自检或说话测试，或等待语音资源维护完成。")
    }

    public var isEnabled: Bool {
        switch action {
        case .start, .end: true
        case .progress, .blocked: false
        }
    }

    /// The bar's left side while a session runs: the source it listens to ("Phone" for the
    /// phone scene); nil while idle, starting or stopping.
    public func runningSource(meetingApp: String?) -> String? {
        guard phase == .running, let running else { return nil }
        if running == .phone { return "Phone" }
        guard let meetingApp, !meetingApp.isEmpty else { return running.scene.title }
        return meetingApp
    }

    private static func startLabel(_ mode: MeetingMode) -> String {
        switch mode {
        case .meeting: String(appLocalized: "开始会议同传")
        case .phone: String(appLocalized: "准备电话同传")
        case .captions: String(appLocalized: "开始视频字幕")
        }
    }
}

/// Where my voice goes on a phone call now (§7.2 实时发声行): the delivery glyph and the
/// shortest consequence, read from the titlebar's voice state. None while the other party
/// hears the original voice: the red capsule (对方能听到原声) says it, and no delivery words
/// may stand beside it that read as "it stays on this Mac".
public enum PhoneDelivery: Sendable, Equatable {
    /// 已送入 Phone: the original or translated voice reaches the call.
    case sentToPhone
    /// 仅本机 · Phone 未接收: plays on this Mac only.
    case thisMacOnly
    /// 接通后对方才能听到你.
    case waitingForCall
    /// 未发送.
    case notSent

    /// `phoneInputConfirmed`: Phone reads TalkTalk Mic. The key-down 松开确认 alone does not
    /// say where speech goes, so before Phone reads it stays on this Mac.
    public init?(_ kind: VoiceState.Kind, phoneInputConfirmed: Bool = true) {
        switch kind {
        case .remoteHearsOriginal: return nil
        case .switching: self = phoneInputConfirmed ? .sentToPhone : .thisMacOnly
        case .original, .translating, .processing, .playingTranslation: self = .sentToPhone
        case .phoneLocalTrial, .phoneLocalOnly, .localPlayback: self = .thisMacOnly
        case .phoneNotConnected: self = .waitingForCall
        case .notSent, .restoring, .unavailable, .phoneReconnecting, .listening: self = .notSent
        }
    }

    public var symbol: String {
        switch self {
        case .sentToPhone: SubtitleTokens.VoiceIcon.sentToPhone
        case .thisMacOnly: SubtitleTokens.VoiceIcon.thisMac
        case .waitingForCall, .notSent: SubtitleTokens.VoiceIcon.localOnly
        }
    }

    public var text: String {
        switch self {
        case .sentToPhone: String(appLocalized: "已送入 Phone")
        case .thisMacOnly: String(appLocalized: "仅本机 · Phone 未接收")
        case .waitingForCall: String(appLocalized: "接通后对方才能听到你")
        case .notSent: String(appLocalized: "未发送")
        }
    }
}

/// The browser tab note appears only when the chosen source is a browser (§7 文案).
public enum ScenarioSourceNote {
    public static func showsBrowserNote(selectedID: String) -> Bool {
        MeetingApp.named(selectedID)?.isBrowser == true
    }
}

/// The phone page's StepTrack (settings visual system §3.5, §7.2). ① is prepared by the bottom
/// bar's 准备 (the step has no button of its own), ② dials or answers in Phone and is dimmed until
/// ① is ready, ③ ends after hanging up.
public struct PhoneChecklist: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case pending, inProgress, done }

    public var prepare: Status
    public var dial: Status
    public var finish: Status
    /// ② is usable only after ① is ready.
    public var dialEnabled: Bool { prepare == .done }

    /// `phoneSession`: the running (or starting/stopping) session is the phone scenario.
    /// `wasReady`: this session has been ready to dial. A readiness lost later (Phone reads the
    /// physical microphone, the reader-change barrier) keeps ① done; the problem row and the
    /// Phone node say what is wrong.
    public static func make(phoneSession: Bool, starting: Bool, stopping: Bool, active: Bool,
                            readyToDial: Bool, callAudioActive: Bool,
                            wasReady: Bool = false) -> PhoneChecklist {
        guard phoneSession else { return PhoneChecklist(prepare: .pending, dial: .pending, finish: .pending) }
        let prepare: Status
        if active, readyToDial || wasReady || callAudioActive, !stopping { prepare = .done }
        else if starting || stopping || active { prepare = .inProgress }
        else { prepare = .pending }
        let dial: Status = prepare != .done ? .pending : callAudioActive ? .done : .pending
        let finish: Status = stopping ? .inProgress : .pending
        return PhoneChecklist(prepare: prepare, dial: dial, finish: finish)
    }
}
