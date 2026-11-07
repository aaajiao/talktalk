// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation
import TalkTalkCore

/// What a menu row's glyph is tinted with (a problem line's words take the same colour); rows
/// without a tone keep the template glyph.
public enum StatusMenuTone: Sendable, Equatable {
    case risk, failed, warn, pending
    /// The voice capsule's own colour family (the voice row).
    case voice(VoiceTone)
    /// A recording line (§5.4): red glyph while it records, orange while it is set or the
    /// subtitle analysis saves text, as RecordingBanner; the words keep the menu's colour.
    case recording(active: Bool)
}

/// Where a problem row's action leads in Settings (§6.4 菜单问题行, §8.5): the exact page,
/// sub-page and section, which flashes once.
public enum StatusMenuDestination: Sendable, Equatable {
    /// 音频 › TalkTalk Mic: the meeting or Phone check and the default input.
    case talkTalkMic
    /// 音频 › 耳机: speaker playback.
    case playback
    /// 模型 › 语音识别, its diagram.
    case recognition
    /// 模型 › 文本翻译, its diagram.
    case translation
    /// 安装与维护 › 语音资源 › 引擎.
    case components
    /// 通用 › 使用引导… (§8.2: it lives there once onboarding is done), which re-runs the
    /// Apple speech download.
    case onboarding
    /// 隐私与诊断 › 故障检查 › 诊断录音.
    case diagnosticRecording
    /// 隐私与诊断 › 字幕分析.
    case subtitleAnalysis
}

/// What a clickable row does; the status item maps each to its action.
public enum StatusMenuCommand: Sendable, Equatable {
    /// Opens onboarding at its saved step.
    case continueOnboarding
    case quickStart(MeetingMode)
    /// 开始会议同传 while last run's input record waits (恢复输入记录).
    case resumeFromRecord
    /// Settings › 使用场景 on that scene.
    case openScene(MeetingMode)
    case open(StatusMenuDestination)
    case end
    case restoreSubtitleWindow
    case openPhone
    case stillInMeeting
    case switchBackToMic
    case restoreDefaultInput
    case toggleSubtitles
    case toggleMonitor
    case toggleSubtitleLock
    case toggleGlobalFallback
    case playAnnouncement
    case settings
    case about
    case quit
}

/// The two language submenus (对方语言 and 我的译音, §5.5).
public enum StatusMenuLanguage: Sendable, Equatable { case listen, speak }

/// One row of the menu bar menu.
public struct StatusMenuRow: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case action(StatusMenuCommand)
        /// A check item (✓ while on).
        case toggle(StatusMenuCommand, on: Bool)
        /// A submenu of the languages.
        case languages(StatusMenuLanguage)
        /// Not clickable: the session title, a problem line or an information line.
        case status
        case separator
    }

    /// Rows the status item refreshes every second while the menu stays open.
    public enum Live: Sendable, Equatable { case sessionTitle, voice, phoneDelivery }

    public var kind: Kind
    public var title: String
    public var subtitle: String?
    public var symbol: String?
    public var tone: StatusMenuTone?
    /// The tooltip: the full sentence behind a short line.
    public var help: String?
    public var bold: Bool
    /// One level in, under the problem line it fixes (§8.1).
    public var indented: Bool
    public var isEnabled: Bool
    public var keyEquivalent: String?
    public var live: Live?

    public init(_ kind: Kind, _ title: String, subtitle: String? = nil, symbol: String? = nil,
                tone: StatusMenuTone? = nil, help: String? = nil, bold: Bool = false, indented: Bool = false,
                isEnabled: Bool = true, keyEquivalent: String? = nil, live: Live? = nil) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tone = tone
        self.help = help
        self.bold = bold
        self.indented = indented
        self.isEnabled = isEnabled
        self.keyEquivalent = keyEquivalent
        self.live = live
    }

    public static let separator = StatusMenuRow(.separator, "")

    public var command: StatusMenuCommand? {
        switch kind {
        case let .action(command), let .toggle(command, _): command
        case .languages, .status, .separator: nil
        }
    }
}

/// What the menu reads, gathered by the status item each time the menu opens.
public struct StatusMenuFacts: Sendable, Equatable {
    /// A problem's tone and short words, with the full sentence for its tooltip.
    public struct Notice: Sendable, Equatable {
        public var tone: StatusMenuTone
        public var text: String
        public var help: String?

        public init(_ tone: StatusMenuTone, _ text: String, help: String? = nil) {
            self.tone = tone
            self.text = text
            self.help = help
        }
    }

    public var onboardingNeeded = false
    /// Where unfinished onboarding stands (`OnboardingState.progress`).
    public var onboardingProgress: OnboardingProgress?
    public var phase: ScenarioRunState.Phase = .idle
    /// The session's scene (the last one while idle).
    public var mode: MeetingMode = .meeting
    /// The scene the quick start starts (`ui.lastScenario`).
    public var lastScenario: MeetingMode?
    /// The quick start scene's remembered source; nil: automatic selection.
    public var quickStartSource: String?
    /// 对方语言 and 我的译音 by name ("英语").
    public var listenLanguage = String(localized: "英语")
    public var speakLanguage = String(localized: "英语")
    public var meetingApp: String?
    public var elapsed: TimeInterval?
    /// The titlebar's voice capsule.
    public var voice: VoiceState?
    /// The phone page's context sentence (the delivery row's tooltip).
    public var phoneStatus: String?
    /// The meeting or Phone check (`ScenarioFacts.sessionCheck`), nil when it passed. Read only
    /// while a speaking session runs: 视频字幕 never uses TalkTalk Mic.
    public var micCheck: Notice?
    public var meetingHint: String?
    /// The last session ended on a failure.
    public var lastEndProblem: MeetingMode?
    /// Apple speech or translation resources are missing (§7.5 item 6).
    public var appleCheck: String?
    /// The default-input notice when it needs the user (SystemInputController.menuNotice).
    public var systemInput: Notice?
    public var switchBack = false
    public var restoreNow = false
    public var resumeFromRecord = false
    /// Qwen3-ASR was chosen but Apple Speech took over, with the backend's own words.
    public var asrFallback = false
    public var asrStatus: String?
    /// Recognition stopped: the listen pipeline could not recover, or a language switch failed.
    public var asrFailure: String?
    public var translation: ListenTranslation?
    /// The session's 我说话 direction translates with OpenAI (its text leaves this Mac).
    public var speakCloud = false
    public var offline = false
    /// A diagnostic recording runs or is set (§5.4 录音), and the subtitle analysis saves text.
    public var recording: Recording?
    public var savingSubtitleText = false
    public var subtitlesVisible = true
    public var monitor = false
    public var canPlayAnnouncement = false
    public var canRestoreWindow = false
    public var subtitleLocked = false
    public var usesGlobalFallback = false
    public var icon: MenuBarIcon = .standby
    /// The icon's facts without a line of their own (`MenuBarIcon.reasons`).
    public var iconReasons: [MenuBarIcon.Reason] = []
    public var systemInputSwitched = false
    public var meetingAvailable = true
    public var devBuild = false

    public init() {}

    /// A diagnostic recording (RecordingBanner's words).
    public enum Recording: Sendable, Equatable {
        /// Recording these tracks now ("我 · 译音 · 对方").
        case recording(tracks: String)
        /// Set for the running session (本场将录音) or the next one (下场将录音).
        case planned(thisSession: Bool)
    }

    var inSession: Bool { phase == .running || phase == .stopping }
    /// 视频字幕 has no speaking side: no 我说话, 耳机译音 or meeting check while it runs.
    var videoBusy: Bool { mode == .captions && phase != .idle }

    /// 字幕翻译 sends each sentence to OpenAI now: its last final came from OpenAI, or fell back
    /// to Apple after the sentence was sent (late, empty, breaker probe). Not while offline or
    /// paused (key or quota), when nothing is sent.
    var listenCloud: Bool {
        guard inSession, !offline, let translation else { return false }
        switch translation {
        case .openAI: return true
        case let .appleFallback(reason): return reason != "offline" && !reason.hasPrefix("paused")
        case .appleOnly: return false
        }
    }
}

/// The menu bar menu (settings visual system §8) as rows, from what is true now. Pure: the status
/// item draws each row and maps its command to an action. A 引导未完成: its bold row first, above
/// everything; B 空闲 (also while starting, the start row replaced by 正在准备…); C 运行中 (also
/// while ending, 结束 replaced by 正在结束…); D problems inside B or C, most severe first, each a
/// tinted line with its fix one level in, after the recording lines (§5.4). There is no 更多:
/// 我的声音, 隐私与诊断, 通知 and, once onboarding is done, 使用引导 are in Settings.
public enum StatusMenu {
    public static func rows(_ f: StatusMenuFacts) -> [StatusMenuRow] {
        var rows: [StatusMenuRow] = []
        if f.onboardingNeeded {
            let title = f.onboardingProgress.map { String(localized: "继续使用引导 · \($0.text)") }
                ?? String(localized: "继续使用引导")
            rows += [StatusMenuRow(.action(.continueOnboarding), title, symbol: SubtitleTokens.MenuIcon.onboarding, bold: true),
                     .separator]
        }
        let problems = issues(f)
        rows += f.inSession ? session(f, issues: problems) : idle(f, issues: problems)
        rows += [.separator,
                 StatusMenuRow(.action(.settings), String(localized: "设置…"), symbol: SubtitleTokens.ActionIcon.settings,
                               keyEquivalent: ","),
                 StatusMenuRow(.action(.about), String(localized: "关于 TalkTalk")),
                 StatusMenuRow(.action(.quit), f.devBuild ? String(localized: "退出 TalkTalk Dev") : String(localized: "退出 TalkTalk"),
                               keyEquivalent: "q")]
        return rows
    }

    // MARK: B 空闲

    private static func idle(_ f: StatusMenuFacts, issues: [StatusMenuRow]) -> [StatusMenuRow] {
        var rows: [StatusMenuRow] = []
        if f.phase == .starting {
            rows.append(progress(f.mode, ending: false))
        } else {
            let quick = MenuQuickStart.make(last: f.lastScenario, sourceName: f.quickStartSource,
                                            remoteLanguage: f.listenLanguage)
            rows.append(StatusMenuRow(.action(.quickStart(quick.mode)), quick.title, subtitle: quick.subtitle,
                                      symbol: MenuQuickStart.symbol, help: startBlocked(f), bold: true,
                                      isEnabled: f.meetingAvailable && !f.onboardingNeeded))
        }
        // The three scenes open Settings › 使用场景 on that scene.
        rows += [MeetingMode.meeting, .phone, .captions].map { mode in
            StatusMenuRow(.action(.openScene(mode)), sceneRowTitle(mode), symbol: mode.sceneSymbol)
        }
        if f.canRestoreWindow { rows.append(restoreWindow) }
        rows.append(.separator)
        let block = recordingRows(f) + issues
        if !block.isEmpty { rows += block + [.separator] }
        return rows + languages(f) + toggles(f)
    }

    /// Why the scene's start waits (§8.2); nil when it can start.
    private static func startBlocked(_ f: StatusMenuFacts) -> String? {
        f.onboardingNeeded ? String(localized: "完成引导后可用") : nil
    }

    // MARK: C 运行中

    private static func session(_ f: StatusMenuFacts, issues: [StatusMenuRow]) -> [StatusMenuRow] {
        var rows = [StatusMenuRow(.status, MenuSessionHeader.title(mode: f.mode, source: f.meetingApp, elapsed: f.elapsed),
                                  symbol: f.mode.sceneSymbol, live: .sessionTitle)]
        // The risk line below says the same as the risk capsule, in the same glyph and colour.
        if let voice = f.voice, !(voice.kind == .remoteHearsOriginal && micRisk(f)) {
            rows.append(voiceRow(voice))
        }
        if f.mode == .phone, f.phase == .running {
            if let voice = f.voice, let delivery = PhoneDelivery(voice.kind) {
                rows.append(deliveryRow(delivery, help: f.phoneStatus))
            }
            rows.append(StatusMenuRow(.action(.openPhone), String(localized: "打开 Phone"),
                                      symbol: SubtitleTokens.VoiceIcon.openPhone))
        }
        rows += recordingRows(f) + issues
        if f.phase == .stopping {
            rows.append(progress(f.mode, ending: true))
        } else {
            rows.append(StatusMenuRow(.action(.end), f.mode.scene.endAccessibilityLabel, symbol: SubtitleTokens.VoiceIcon.end,
                                      help: f.mode.scene.endHelp(systemInputSwitched: f.systemInputSwitched)))
        }
        if f.canRestoreWindow { rows.append(restoreWindow) }
        rows += [.separator,
                 StatusMenuRow(.action(.openScene(f.mode)), String(localized: "查看当前场景…"),
                               symbol: SubtitleTokens.SettingsIcon.Page.scenarios)]
        rows += languages(f) + toggles(f)
        if f.canPlayAnnouncement, f.mode.supportsSpeaking, f.phase == .running {
            rows.append(StatusMenuRow(.action(.playAnnouncement), String(localized: "播放告知语"),
                                      symbol: SubtitleTokens.MenuIcon.announcement))
        }
        if SubtitleClickThrough.offersLock(scene: f.mode.scene, sessionActive: true) {
            rows.append(StatusMenuRow(.toggle(.toggleSubtitleLock, on: f.subtitleLocked), String(localized: "锁定字幕位置"),
                                      symbol: SubtitleTokens.VoiceIcon.locked, help: String(localized: "鼠标穿透")))
        }
        if let cloud = cloudRow(f) { rows.append(cloud) }
        if f.mode.allowsGlobalFallback {
            let on = f.usesGlobalFallback
            rows.append(StatusMenuRow(.toggle(.toggleGlobalFallback, on: on),
                                      on ? String(localized: "收听：所有应用（备用）") : String(localized: "收听所有应用（备用）"),
                                      symbol: SubtitleTokens.SettingsIcon.listen,
                                      help: String(localized: "其他应用的声音也可能被转写"), isEnabled: f.phase == .running))
        }
        return rows
    }

    /// §5.4 云端: the directions whose text leaves this Mac now, in one information line (not a
    /// problem); none while only Apple translates. A fallback line of 字幕翻译 can stand beside it.
    private static func cloudRow(_ f: StatusMenuFacts) -> StatusMenuRow? {
        let listen = f.listenCloud
        let speak = f.speakCloud && f.inSession && !f.videoBusy && !f.offline
        let line: (title: String, help: String)
        switch (listen, speak) {
        case (true, true): line = (String(localized: "翻译：OpenAI"), String(localized: "听到的和我说的话都以文字发给 OpenAI"))
        case (true, false): line = (String(localized: "字幕翻译：OpenAI"), String(localized: "听到的文字发给 OpenAI 翻译"))
        case (false, true): line = (String(localized: "我说话翻译：OpenAI"), String(localized: "我说的话以文字发给 OpenAI 翻译"))
        case (false, false): return nil
        }
        return StatusMenuRow(.status, line.title, symbol: SubtitleTokens.SettingsIcon.cloud, help: line.help)
    }

    /// §5.4 录音, RecordingBanner's words: a diagnostic recording (running or set) and the
    /// subtitle analysis saving text, each with the page that controls it one level in.
    private static func recordingRows(_ f: StatusMenuFacts) -> [StatusMenuRow] {
        typealias Icon = SubtitleTokens.SettingsIcon
        var rows: [StatusMenuRow] = []
        let recording = StatusMenuRow(.action(.open(.diagnosticRecording)), String(localized: "查看诊断录音…"),
                                      symbol: Icon.recording)
        switch f.recording {
        case let .recording(tracks)?:
            rows += Issue(.recording(active: true), String(localized: "录音中：\(tracks)"), symbol: Icon.recordingActive,
                          help: String(localized: "只存这台 Mac，24 小时后删除"), fixes: [recording]).rows
        case let .planned(thisSession)?:
            rows += Issue(.recording(active: false), thisSession ? String(localized: "本场将录音") : String(localized: "下场将录音"),
                          symbol: Icon.recording, help: String(localized: "录我和译音，24 小时后删除"), fixes: [recording]).rows
        case nil:
            break
        }
        if f.savingSubtitleText {
            rows += Issue(.recording(active: false), String(localized: "正在保存字幕文字"), symbol: Icon.recording,
                          help: String(localized: "记录本次原文和译文，不录音"),
                          fixes: [StatusMenuRow(.action(.open(.subtitleAnalysis)), String(localized: "查看字幕分析…"),
                                                symbol: Icon.subtitles)]).rows
        }
        return rows
    }

    private static func voiceRow(_ voice: VoiceState) -> StatusMenuRow {
        StatusMenuRow(.status, voiceTitle(voice), symbol: voice.symbol, tone: .voice(voice.appearance.tone),
                      help: voice.detail, live: .voice)
    }

    /// "原声 · 对方可听到": the capsule's word and its shortest consequence (§8.4).
    public static func voiceTitle(_ voice: VoiceState) -> String { "\(voice.title) · \(voice.shortConsequence)" }

    private static func deliveryRow(_ delivery: PhoneDelivery, help: String?) -> StatusMenuRow {
        StatusMenuRow(.status, delivery.text, symbol: delivery.symbol, help: help, live: .phoneDelivery)
    }

    private static func progress(_ mode: MeetingMode, ending: Bool) -> StatusMenuRow {
        StatusMenuRow(.status, ending ? String(localized: "正在结束\(mode.scene.title)…") : String(localized: "正在准备\(mode.scene.title)…"),
                      symbol: MenuBarIcon.warming.symbol)
    }

    private static var restoreWindow: StatusMenuRow {
        StatusMenuRow(.action(.restoreSubtitleWindow), String(localized: "恢复字幕窗口"),
                      symbol: SubtitleTokens.MenuIcon.restoreWindow)
    }

    private static func languages(_ f: StatusMenuFacts) -> [StatusMenuRow] {
        var rows = [StatusMenuRow(.languages(.listen), String(localized: "字幕：\(f.listenLanguage) → 中文"),
                                  symbol: SubtitleTokens.MenuIcon.subtitles)]
        if !f.videoBusy {
            rows.append(StatusMenuRow(.languages(.speak), String(localized: "我说话：中文 → \(f.speakLanguage)"),
                                      symbol: SubtitleTokens.SettingsIcon.me))
        }
        return rows
    }

    private static func toggles(_ f: StatusMenuFacts) -> [StatusMenuRow] {
        var rows = [StatusMenuRow(.toggle(.toggleSubtitles, on: f.subtitlesVisible), String(localized: "显示字幕"),
                                  symbol: SubtitleTokens.MenuIcon.subtitles)]
        if !f.videoBusy {
            rows.append(StatusMenuRow(.toggle(.toggleMonitor, on: f.monitor), String(localized: "耳机译音"),
                                      symbol: SubtitleTokens.SettingsIcon.headphones))
        }
        return rows
    }

    // MARK: D 问题

    private struct Issue {
        let tone: StatusMenuTone?
        let rows: [StatusMenuRow]

        /// risk > failed > warn > pending > the rest (§8.5).
        var rank: Int {
            switch tone {
            case .risk?: 0
            case .failed?: 1
            case .warn?: 2
            case .pending?: 3
            case .voice?, .recording?, nil: 4
            }
        }

        /// A tinted line and its fixes one level in; a fix without its own tooltip takes the line's.
        init(_ tone: StatusMenuTone?, _ text: String, symbol: String?, help: String?, fixes: [StatusMenuRow]) {
            self.tone = tone
            let line = StatusMenuRow(.status, text, symbol: symbol, tone: tone, help: help == text ? nil : help)
            rows = [line] + fixes.map { fix in
                var fix = fix
                fix.indented = true
                if fix.help == nil { fix.help = line.help }
                return fix
            }
        }

        /// A problem that is its own fix (确认应用…).
        init(_ tone: StatusMenuTone?, action: StatusMenuRow) {
            self.tone = tone
            rows = [action]
        }
    }

    private static func micRisk(_ f: StatusMenuFacts) -> Bool {
        f.inSession && f.mode.supportsSpeaking && f.micCheck?.tone == .risk
    }

    private static func models(_ destination: StatusMenuDestination) -> StatusMenuRow {
        StatusMenuRow(.action(.open(destination)), String(localized: "识别与翻译…"), symbol: SubtitleTokens.SettingsIcon.Page.models)
    }

    private static var checkMicrophone: StatusMenuRow {
        StatusMenuRow(.action(.open(.talkTalkMic)), String(localized: "检查麦克风…"), symbol: SubtitleTokens.SettingsIcon.talkTalkMic)
    }

    private static var componentSettings: StatusMenuRow {
        StatusMenuRow(.action(.open(.components)), String(localized: "安装与维护…"), symbol: SubtitleTokens.SettingsIcon.Page.components)
    }

    /// The line of an icon fact that has none of its own (§8.1), with its sentence and fix.
    private static func issue(_ reason: MenuBarIcon.Reason) -> Issue {
        typealias Icon = SubtitleTokens.SettingsIcon
        switch reason {
        case .talkTalkMicReadWhileIdle:
            return Issue(.failed, String(localized: "有应用在读 TalkTalk Mic"), symbol: Icon.talkTalkMic,
                         help: String(localized: "未开始同传时，有应用在读 TalkTalk Mic"), fixes: [checkMicrophone])
        case .speakTranslation:
            return Issue(.warn, String(localized: "我说话翻译：Apple 备用"), symbol: SubtitleTokens.MenuIcon.degraded,
                         help: String(localized: "OpenAI 暂不可用，改用 Apple 翻译"), fixes: [models(.translation)])
        case .speaker:
            return Issue(.warn, String(localized: "正在外放 · 耳机译音已停用"), symbol: Icon.speaker,
                         help: String(localized: "停用耳机译音与原声通路，避免回声"),
                         fixes: [StatusMenuRow(.action(.open(.playback)), String(localized: "查看音频设置…"), symbol: Icon.Page.audio)])
        case .playbackUnknown:
            return Issue(.warn, String(localized: "播放设备未确认"), symbol: Icon.headphones,
                         help: String(localized: "尚未读到会议应用的播放设备"),
                         fixes: [StatusMenuRow(.action(.open(.playback)), String(localized: "查看音频设置…"), symbol: Icon.Page.audio)])
        case .systemVoice:
            return Issue(.warn, String(localized: "译音：系统声音"), symbol: Icon.speech,
                         help: String(localized: "引擎未安装，声音档案暂不能用"), fixes: [componentSettings])
        }
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private static func issues(_ f: StatusMenuFacts) -> [StatusMenuRow] {
        typealias Icon = SubtitleTokens.SettingsIcon
        var list: [Issue] = []
        var micLine = false, inputLine = false, fallbackLine = false

        // The meeting or Phone check: the risk keeps its safety words (§1.3), the rest the check's own.
        if f.inSession, f.mode.supportsSpeaking, let check = f.micCheck {
            micLine = true
            let risk = check.tone == .risk
            let symbol = switch check.tone {
            case .risk: SubtitleTokens.VoiceIcon.originalRisk
            case .failed, .warn: SubtitleTokens.MenuIcon.micUnused
            case .pending, .voice, .recording: Icon.statusPending
            }
            let help = risk ? [check.text, check.help ?? f.voice?.detail].compactMap { $0 }.joined(separator: "\n")
                            : check.help
            list.append(Issue(check.tone, risk ? String(localized: "对方能听到原声") : check.text, symbol: symbol, help: help,
                              fixes: [checkMicrophone]))
        }

        // The system default input (§8.6): TalkTalk Mic's glyph in the notice's colour.
        var inputFixes: [StatusMenuRow] = []
        if f.switchBack {
            inputFixes.append(StatusMenuRow(.action(.switchBackToMic), String(localized: "切回 TalkTalk Mic"), symbol: Icon.talkTalkMic))
        }
        if f.restoreNow {
            inputFixes.append(StatusMenuRow(.action(.restoreDefaultInput), String(localized: "还原默认输入"),
                                            symbol: SubtitleTokens.MenuIcon.restoreInput))
        }
        if f.resumeFromRecord, f.phase == .idle {
            inputFixes.append(StatusMenuRow(.action(.resumeFromRecord), String(localized: "开始会议同传"),
                                            subtitle: String(localized: "恢复输入记录"), symbol: MenuQuickStart.symbol,
                                            help: startBlocked(f), isEnabled: f.meetingAvailable && !f.onboardingNeeded))
        }
        if let notice = f.systemInput {
            inputLine = true
            inputFixes.append(StatusMenuRow(.action(.open(.talkTalkMic)), String(localized: "查看音频设置…"), symbol: Icon.Page.audio))
            list.append(Issue(notice.tone, notice.text, symbol: Icon.talkTalkMic, help: notice.help, fixes: inputFixes))
        }

        // §8.2: unfinished onboarding's row stands for missing components and Apple resources.
        if !f.onboardingNeeded, f.icon == .missing {
            list.append(Issue(.pending, MenuBarIcon.missing.statusText(mode: f.mode), symbol: Icon.Page.components,
                              help: String(localized: "本机识别或合成模型未安装"), fixes: [componentSettings]))
        }
        // 通用's 使用引导… row carries the same status and runs the download again.
        if !f.onboardingNeeded, let apple = f.appleCheck {
            list.append(Issue(.warn, String(localized: "Apple 资源待配置"), symbol: SubtitleTokens.MenuIcon.degraded, help: apple,
                              fixes: [StatusMenuRow(.action(.open(.onboarding)), String(localized: "通用设置…"),
                                                    symbol: Icon.Page.general)]))
        }

        if f.inSession, let failure = f.asrFailure {
            list.append(Issue(.failed, String(localized: "字幕识别出错"), symbol: SubtitleTokens.MenuIcon.degraded,
                              help: failure, fixes: [models(.recognition)]))
        }
        if f.inSession, f.asrFallback {
            fallbackLine = true
            list.append(Issue(.warn, String(localized: "识别：Apple 备用"), symbol: SubtitleTokens.MenuIcon.degraded,
                              help: f.asrStatus, fixes: [models(.recognition)]))
        }
        if f.inSession, let translation = f.translation, translation != .appleOnly, translation != .openAI || f.offline {
            fallbackLine = true
            list.append(Issue(.warn, String(localized: "字幕翻译：Apple 备用"), symbol: SubtitleTokens.MenuIcon.degraded,
                              help: translation.menuText(offline: f.offline), fixes: [models(.translation)]))
        }

        if f.phase == .idle, let mode = f.lastEndProblem {
            list.append(Issue(.warn, String(localized: "\(mode.scene.title)因错误已结束"), symbol: SubtitleTokens.MenuIcon.degraded,
                              help: String(localized: "字幕识别或发言链路出错，已自动结束。可重新开始。"),
                              fixes: [StatusMenuRow(.action(.openScene(mode)), sceneRowTitle(mode), symbol: mode.sceneSymbol)]))
        }

        // A listening hint keeps its titlebar chip's glyph and colour (one glyph per meaning).
        if let hint = f.meetingHint {
            let warning = MeetingSession.Hint(rawValue: hint)?.warning ?? (f.mode == .phone ? .meetingSeemsOver : nil)
            let chip = warning?.chip(scene: f.mode.scene)
            let tone: StatusMenuTone? = switch chip?.tone {
            case .risk?: .risk
            case .warn?: .warn
            default: nil
            }
            let keepsListening = hint == MeetingSession.Hint.meetingSeemsOver.rawValue || (f.mode == .phone && f.phase == .running)
            list.append(Issue(tone, hint, symbol: chip?.symbol ?? warning?.symbol, help: chip?.detail,
                              fixes: keepsListening ? [StatusMenuRow(.action(.stillInMeeting), String(localized: "继续收听"),
                                                                     symbol: SubtitleTokens.VoiceIcon.listening)] : []))
        }

        if f.phase == .running, f.mode != .phone, (f.meetingApp ?? "").isEmpty, !f.usesGlobalFallback {
            list.append(Issue(.pending, action: StatusMenuRow(.action(.openScene(f.mode)), String(localized: "确认应用…"),
                                                              symbol: SubtitleTokens.MenuIcon.audioUnconfirmed,
                                                              help: String(localized: "选择要收听的应用"))))
        }

        // The icon's facts without a line of their own: speaker playback, the system voice, …
        list += f.iconReasons.map(issue)
        let voiceReason = f.iconReasons.contains { $0 != .talkTalkMicReadWhileIdle }

        // The status item's own word, only when no line above explains its glyph.
        let explained: Bool = switch f.icon {
        case .standby, .listening, .missing: true
        case .warming: f.phase == .starting || f.phase == .stopping
        case .speaking, .passthroughOpen: f.inSession && f.voice != nil
        case .audioNeedsCheck: micLine
        case .degraded: fallbackLine || inputLine || voiceReason
        case .needsAttention: inputLine || f.iconReasons.contains(.talkTalkMicReadWhileIdle)
        case .remoteHearsOriginal: micRisk(f)
        }
        if !explained {
            let tone: StatusMenuTone? = switch f.icon {
            case .remoteHearsOriginal: .risk
            case .needsAttention: .failed
            case .degraded, .audioNeedsCheck: .warn
            default: nil
            }
            // The audio glyphs lead to the meeting check; the rest are states, not repairs.
            let help: String? = switch f.icon {
            case .remoteHearsOriginal: String(localized: "会议应用在用实体麦克风")
            case .audioNeedsCheck: String(localized: "尚未确认会议应用在用 TalkTalk Mic")
            case .needsAttention: String(localized: "音频设备需要处理")
            case .degraded: String(localized: "部分功能正在用备用方案")
            default: nil
            }
            let fixes = [.remoteHearsOriginal, .audioNeedsCheck, .needsAttention].contains(f.icon) ? [checkMicrophone] : []
            list.append(Issue(tone, f.icon.statusText(mode: f.mode), symbol: f.icon.symbol, help: help, fixes: fixes))
        }

        return list.enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .flatMap(\.element.rows)
    }

    private static func sceneRowTitle(_ mode: MeetingMode) -> String {
        switch mode {
        case .meeting: String(localized: "会议同传…")
        case .phone: String(localized: "电话同传…")
        case .captions: String(localized: "视频字幕…")
        }
    }
}

extension MeetingSession.Hint {
    /// The titlebar chip of a LISTEN hint (PTTHUD and the menu's hint line).
    public var warning: HUDModel.Warning {
        switch self {
        case .meetingSilent: .meetingSilent
        case .audioRestarting: .audioRestarting
        case .meetingSeemsOver: .meetingSeemsOver
        case .tccUnconfirmed: .tccUnconfirmed
        }
    }
}
