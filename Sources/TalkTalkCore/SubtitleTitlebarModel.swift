// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation

/// A titlebar capsule or problem-chip label. scripts/check-strings.sh limits the literal to
/// 10 Chinese characters (a Latin word or an interpolation counts as one); complete sentences
/// belong in the chip's detail.
public func titlebarLabel(_ key: String.LocalizationValue) -> String { String(appLocalized: key) }

/// A fading titlebar notification label, limited to 8 characters by scripts/check-strings.sh.
public func noticeLabel(_ key: String.LocalizationValue) -> String { String(appLocalized: key) }

public enum SubtitleScene: String, Sendable, Equatable, CaseIterable {
    case meeting, phone, video

    public var title: String {
        switch self {
        case .meeting: String(appLocalized: "会议同传")
        case .phone: String(appLocalized: "电话同传")
        case .video: String(appLocalized: "视频字幕")
        }
    }

    public var symbol: String {
        switch self {
        case .meeting: SubtitleTokens.SceneIcon.meeting
        case .phone: SubtitleTokens.SceneIcon.phone
        case .video: SubtitleTokens.SceneIcon.video
        }
    }

    /// Every scene ends at once, with no confirmation; the consequence is the button's help.
    public var endTitle: String { self == .video ? titlebarLabel("结束") : titlebarLabel("结束同传") }

    /// The icon-only end button's VoiceOver label and tooltip: which session ends.
    public var endAccessibilityLabel: String {
        switch self {
        case .meeting: String(appLocalized: "结束会议同传")
        case .phone: String(appLocalized: "结束电话同传")
        case .video: String(appLocalized: "结束视频字幕")
        }
    }

    /// The end button's tooltip and VoiceOver help, also the menu item's tooltip: which session
    /// ends and which local actions TalkTalk performs. Another app's input choice and what the
    /// remote participant hears cannot be observed, so neither is promised here.
    public func endHelp(systemInputSwitched: Bool) -> String {
        switch self {
        case .meeting:
            systemInputSwitched
                ? String(appLocalized: "结束会议同传：不会退出会议；TalkTalk 停止收听和译音，并还原系统麦克风")
                : String(appLocalized: "结束会议同传：不会退出会议；TalkTalk 停止收听和译音")
        case .phone:
            systemInputSwitched
                ? String(appLocalized: "结束电话同传：通话不会挂断；TalkTalk 停止收听和译音，并还原系统麦克风")
                : String(appLocalized: "结束电话同传：通话不会挂断；TalkTalk 停止收听和译音")
        case .video: String(appLocalized: "结束视频字幕：停止收听和翻译")
        }
    }
}

/// What the voice capsule says (§3). It reads the current speaking mode directly and never
/// competes with problems; only a raw-audio risk or unavailable audio rewrite it.
public struct VoiceState: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case original, translating, processing, playingTranslation, switching, restoring
        case notSent, phoneNotConnected, phoneLocalTrial, phoneLocalOnly, phoneReconnecting
        /// No raw gate (isolated onboarding demo): translated audio plays on this Mac only.
        case localPlayback
        case remoteHearsOriginal, unavailable, listening
    }

    public enum Appearance: Sendable, Equatable {
        /// voice.original fill, dark text.
        case originalFill
        /// voice.translate fill, white text.
        case translateFill
        case translateStroke
        /// White 35% outline.
        case dimStroke
        /// White 50% dashed outline.
        case dashed
        case warnStroke
        /// risk fill, white text; never collapsible.
        case riskFill
        /// warn fill, black 85% text.
        case warnFill
        /// Read-only neutral capsule (video).
        case neutral
    }

    /// Raw-audio facts that override the capsule (meeting app reads a physical mic).
    public enum Risk: Sendable, Equatable { case remoteHearsYourVoice, meetingNotUsingMic }

    public var kind: Kind
    public var appearance: Appearance
    public var title: String
    /// Narrowest titlebar: 原声 / 译音 / 本机 / 收听; 恢复中, 未发送 and 不可用 keep their own words
    /// (never read as a local mode); the risk keeps "对方听到原声".
    public var compactTitle: String
    public var symbol: String
    /// One sentence for the details popover's top row.
    public var consequence: String
    /// The shortest consequence ("对方可听到"): after the title in the menu's voice row
    /// ("原声 · 对方可听到") and VoiceOver's label.
    public var shortConsequence: String
    /// Full explanation (tooltip, accessibilityHelp, details).
    public var detail: String
    /// One line for VoiceOver.
    public var accessibilityLabel: String
    /// Spoken once when the speaking mode changes; nil for transient states.
    public var announcement: String?
    /// The capsule opens details; video's listening capsule is read-only.
    public var opensDetails: Bool { kind != .listening }

    /// Video's listening state is a neutral, read-only status that sends nothing anywhere: the
    /// titlebar draws it as the bare `ear` glyph (tooltip and VoiceOver keep the words), not as
    /// a capsule shaped like the clickable ones. Every other state keeps its capsule and text.
    public var isStatusGlyph: Bool { kind == .listening }

    /// Mode family used to announce only real speaking-mode changes, not processing/playback
    /// toggles inside one translated turn. The unannounced 松开确认 has its own family, so the
    /// latched mode after it is still announced.
    public var announcementGroup: Int {
        switch kind {
        case .original: 0
        case .translating, .processing, .playingTranslation, .localPlayback: 1
        case .switching: 8
        case .restoring: 2
        case .notSent, .phoneNotConnected, .phoneLocalTrial, .phoneLocalOnly: 3
        case .phoneReconnecting: 4
        case .remoteHearsOriginal: 5
        case .unavailable: 6
        case .listening: 7
        }
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    public static func resolve(audio: HUDModel.MeetingAudio?, scene: SubtitleScene,
                               phoneInputConfirmed: Bool = false, playing: Bool = false,
                               pushToTalk: HUDModel.PushToTalk = .idle, risk: Risk? = nil) -> VoiceState {
        let phone = scene == .phone
        let unconfirmed = phone && !phoneInputConfirmed
        let kind: Kind
        var reason: String?
        if scene == .video {
            kind = .listening
        } else if risk != nil {
            kind = .remoteHearsOriginal
        } else if let audio {
            switch audio {
            case let .unavailable(r): kind = .unavailable; reason = r
            case .phoneReconnecting: kind = .phoneReconnecting
            // Start-up wait: the gate is closed and nothing reaches TalkTalk Mic yet.
            case .preparing: kind = .notSent
            case .phoneReady: kind = phone ? .phoneNotConnected : .notSent
            case .original: kind = unconfirmed ? .phoneLocalTrial : .original
            case .switching: kind = .switching
            case .translating:
                kind = unconfirmed ? (playing ? .phoneLocalOnly : .phoneLocalTrial) : .translating
            case .draining:
                if playing { kind = unconfirmed ? .phoneLocalOnly : .playingTranslation }
                else { kind = unconfirmed ? .phoneLocalTrial : .processing }
            case .restoringOriginal: kind = .restoring
            }
        } else {
            // No raw gate (isolated practice): report only actual capture/output. Nothing can
            // reach another person, so playback is local, never "对方听到".
            switch pushToTalk {
            case .holding: kind = unconfirmed ? .phoneLocalTrial : .translating
            case .playing: kind = unconfirmed ? .phoneLocalOnly : .localPlayback
            case .idle: kind = .notSent
            }
        }
        return make(kind, phone: phone, risk: risk, reason: reason)
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func make(_ kind: Kind, phone: Bool, risk: Risk?, reason: String?) -> VoiceState {
        let icon = SubtitleTokens.VoiceIcon.self
        let title: String, compact: String, symbol: String, appearance: Appearance
        let consequence: String, short: String
        var announcement: String?
        switch kind {
        case .original:
            title = titlebarLabel("原声"); compact = titlebarLabel("原声"); symbol = icon.original
            appearance = .originalFill
            consequence = phone ? String(appLocalized: "你的原声正在送入 Phone") : String(appLocalized: "对方听到的是你的原声")
            short = phone ? String(appLocalized: "正在送入 Phone") : String(appLocalized: "对方可听到")
            announcement = phone ? String(appLocalized: "原声已开，正在送入 Phone") : String(appLocalized: "原声已开，对方可听到")
        case .translating:
            title = titlebarLabel("译音"); compact = titlebarLabel("译音"); symbol = icon.translating
            appearance = .translateFill
            consequence = String(appLocalized: "原声已关，正在收音翻译")
            short = String(appLocalized: "原声已关，翻译中")
            announcement = String(appLocalized: "原声已关，翻译中")
        case .processing:
            title = titlebarLabel("译音"); compact = titlebarLabel("译音"); symbol = icon.translating
            appearance = .translateFill
            consequence = String(appLocalized: "原声已关，译音处理中")
            short = String(appLocalized: "原声已关，译音处理中")
            announcement = String(appLocalized: "原声已关，译音处理中")
        case .playingTranslation:
            title = titlebarLabel("译音"); compact = titlebarLabel("译音"); symbol = icon.playingTranslation
            appearance = .translateFill
            consequence = phone ? String(appLocalized: "译音正在送入 Phone") : String(appLocalized: "对方听到的是译音")
            short = phone ? String(appLocalized: "译音正在送入 Phone") : String(appLocalized: "对方听到译音")
            announcement = phone ? String(appLocalized: "译音正在送入 Phone") : String(appLocalized: "译音播放中")
        case .switching:
            title = titlebarLabel("松开确认"); compact = titlebarLabel("译音"); symbol = icon.translating
            appearance = .translateStroke
            consequence = String(appLocalized: "原声已关，松开右⌥确认")
            short = String(appLocalized: "松开右⌥确认")
        case .restoring:
            title = titlebarLabel("原声已关"); compact = titlebarLabel("恢复中"); symbol = icon.originalOff
            appearance = .dimStroke
            consequence = String(appLocalized: "现在什么都没有发出去")
            short = String(appLocalized: "正在恢复原声")
            announcement = String(appLocalized: "正在恢复原声")
        case .notSent:
            title = titlebarLabel("未发送"); compact = titlebarLabel("未发送"); symbol = icon.localOnly
            appearance = .dashed
            consequence = String(appLocalized: "现在什么都没有发出去")
            short = String(appLocalized: "对方听不到你")
            announcement = String(appLocalized: "未发送，对方听不到你")
        case .phoneNotConnected:
            title = titlebarLabel("未接入 Phone"); compact = titlebarLabel("本机"); symbol = icon.localOnly
            appearance = .dashed
            consequence = String(appLocalized: "Phone 尚未接收音频")
            short = String(appLocalized: "Phone 尚未接收音频")
            announcement = String(appLocalized: "未接入 Phone")
        case .phoneLocalTrial:
            title = titlebarLabel("本机试说"); compact = titlebarLabel("本机"); symbol = icon.thisMac
            appearance = .dashed
            consequence = String(appLocalized: "Phone 未接收，现在什么都没有发出去")
            short = String(appLocalized: "Phone 未接收")
            announcement = String(appLocalized: "本机试说，Phone 未接收")
        case .phoneLocalOnly:
            title = titlebarLabel("仅本机"); compact = titlebarLabel("本机"); symbol = icon.thisMac
            appearance = .warnStroke
            consequence = String(appLocalized: "译音只在本机播放，Phone 没有读取 TalkTalk Mic")
            short = String(appLocalized: "译音只在本机播放")
            announcement = String(appLocalized: "仅本机播放，Phone 未接收")
        case .localPlayback:
            title = titlebarLabel("本机播放"); compact = titlebarLabel("本机"); symbol = icon.thisMac
            appearance = .dimStroke
            consequence = String(appLocalized: "译音只在本机播放，没有发给任何人")
            short = String(appLocalized: "译音只在本机播放")
            announcement = String(appLocalized: "译音只在本机播放")
        case .phoneReconnecting:
            title = titlebarLabel("正在重新连接 Phone…"); compact = titlebarLabel("本机")
            symbol = icon.reconnecting; appearance = .dimStroke
            consequence = String(appLocalized: "当前发言已停止，等待 Phone")
            short = String(appLocalized: "当前发言已停止")
            announcement = String(appLocalized: "正在重新连接 Phone")
        case .remoteHearsOriginal:
            title = titlebarLabel("对方能听到原声"); compact = titlebarLabel("对方听到原声")
            symbol = icon.originalRisk
            appearance = .riskFill
            consequence = risk == .meetingNotUsingMic
                ? String(appLocalized: "会议没有使用 TalkTalk Mic，对方能听到原声")
                : String(appLocalized: "对方听到的是你的原声，按键翻译已停用")
            short = String(appLocalized: "按键翻译已停用")
            announcement = String(appLocalized: "对方能听到原声")
        case .unavailable:
            title = titlebarLabel("音频不可用"); compact = titlebarLabel("不可用"); symbol = icon.originalOff
            appearance = .warnFill
            consequence = String(appLocalized: "现在什么都没有发出去")
            short = String(appLocalized: "未发送")
            announcement = String(appLocalized: "音频不可用")
        case .listening:
            title = titlebarLabel("收听中"); compact = titlebarLabel("收听"); symbol = icon.listening
            appearance = .neutral
            consequence = String(appLocalized: "只收听所选应用，麦克风未开启")
            short = String(appLocalized: "麦克风未开启")
        }
        let detail = reason.map { String(appLocalized: "\(consequence)。\($0)") } ?? consequence
        return VoiceState(kind: kind, appearance: appearance, title: title, compactTitle: compact, symbol: symbol,
                          consequence: consequence, shortConsequence: short, detail: detail,
                          accessibilityLabel: String(appLocalized: "发声：\(title)，\(short)"),
                          announcement: announcement)
    }
}

/// One titlebar chip (§3): a problem stays until its fact clears; a notification fades.
public struct HUDChip: Sendable, Equatable {
    public enum Tone: Sendable, Equatable {
        /// risk outline: raw audio may reach the remote side.
        case risk
        /// warn outline.
        case warn
        /// White 28% outline; fades after `SubtitleTokens.noticeChipSeconds`.
        case notice
        /// Gray, persistent information (meeting silent).
        case info
    }

    public var label: String
    public var symbol: String
    public var tone: Tone
    /// Complete sentence for the popover, tooltip and accessibilityHelp.
    public var detail: String
    public var settingsDestination: HUDLine.SettingsDestination?

    public init(_ label: String, symbol: String, tone: Tone, detail: String? = nil,
                settingsDestination: HUDLine.SettingsDestination? = nil) {
        self.label = label
        self.symbol = symbol
        self.tone = tone
        self.detail = detail ?? label
        self.settingsDestination = settingsDestination
    }

    public var isProblem: Bool { tone == .risk || tone == .warn }
    public var fades: Bool { tone == .notice }

    /// Beside "仅本机": Phone has not read TalkTalk Mic, translated audio stays on this Mac.
    public static var phoneNotReceiving: HUDChip {
        HUDChip(titlebarLabel("Phone 未接收"), symbol: SubtitleTokens.VoiceIcon.thisMac, tone: .warn,
                detail: String(appLocalized: "译音只在本机播放：Phone 没有读取 TalkTalk Mic。"),
                settingsDestination: .audio)
    }
}

/// The single titlebar slot beside the capsule: problem > notification > cloud privacy.
public enum IssueSlot: Sendable, Equatable {
    case chip(HUDChip)
    /// Cloud translation is on: network icon with a blue dot until dismissed for this session.
    case cloudPrivacy

    public var chip: HUDChip? { if case let .chip(c) = self { c } else { nil } }
}

/// The right-Option keycap and its action (§3).
public struct TitlebarKey: Sendable, Equatable {
    public enum Style: Sendable, Equatable { case idle, translating, pressed }
    public var key: String
    /// The action's words: always the tooltip and VoiceOver label ("右⌥ 本机试说").
    public var action: String?
    /// Drawn after the keycap instead of `action` at every titlebar width; nil keeps the text.
    public var symbol: String?
    /// false: the capsule beside it already shows the same words, so the titlebar draws the
    /// keycap alone (one fact once); `action` stays for the tooltip and VoiceOver.
    public var drawsAction: Bool
    public var style: Style

    public init(key: String = String(appLocalized: "右⌥"), action: String?, symbol: String? = nil,
                drawsAction: Bool = true, style: Style) {
        self.key = key; self.action = action; self.symbol = symbol; self.drawsAction = drawsAction; self.style = style
    }

    /// nil when no key action applies (video, unavailable, preparing, risk, reconnecting).
    /// When the capsule already reads the action (switching "松开确认", Phone's local trial
    /// "本机试说"), the key does not repeat it: switching draws the pressed keycap alone, the
    /// local trial its start glyph.
    public static func make(_ presentation: SpeechStatusPresentation, voice: VoiceState) -> TitlebarKey? {
        guard voice.kind != .remoteHearsOriginal, voice.kind != .listening,
              let action = presentation.keyAction else { return nil }
        let style: Style = switch voice.kind {
        case .switching: .pressed
        case .translating: .translating
        default: .idle
        }
        var symbol = presentation.keySymbol
        if symbol == nil, voice.kind == .phoneLocalTrial, action == titlebarLabel("本机试说") {
            symbol = SubtitleTokens.VoiceIcon.startTranslation
        }
        return TitlebarKey(action: action, symbol: symbol, drawsAction: voice.title != action, style: style)
    }
}

/// Everything the shared titlebar draws, as static data: the live window and the settings
/// preview render the same component from this value.
public struct SubtitleTitlebarContent: Sendable, Equatable {
    /// The current listening pair; the same button opens both directions in speaking scenes.
    public var languageTitle: String?
    public var languageDetail: String?
    public var scene: SubtitleScene
    public var source: String?
    public var voice: VoiceState?
    public var issue: IssueSlot?
    public var key: TitlebarKey?
    public var showsPhone: Bool
    public var phoneEnabled: Bool
    public var showsEnd: Bool
    public var endEnabled: Bool
    /// TalkTalk holds the system default input: the end help names its restoration.
    public var endInputSwitched: Bool
    /// The video hover bar's "⋯" menu (§6), just before the end button.
    public var showsMore: Bool

    public init(scene: SubtitleScene, source: String? = nil, voice: VoiceState? = nil, issue: IssueSlot? = nil,
                key: TitlebarKey? = nil, showsPhone: Bool = false, phoneEnabled: Bool = true,
                showsEnd: Bool = false, endEnabled: Bool = true, endInputSwitched: Bool = false,
                showsMore: Bool = false, languageTitle: String? = nil, languageDetail: String? = nil) {
        self.languageTitle = languageTitle; self.languageDetail = languageDetail
        self.scene = scene; self.source = source; self.voice = voice; self.issue = issue; self.key = key
        self.showsPhone = showsPhone; self.phoneEnabled = phoneEnabled
        self.showsEnd = showsEnd; self.endEnabled = endEnabled; self.endInputSwitched = endInputSwitched
        self.showsMore = showsMore
    }

    /// Phone's source is always Phone itself.
    public var sourceTitle: String? { scene == .phone ? "Phone" : source }
    public var hasTrailingItems: Bool { languageTitle != nil || voice != nil || issue != nil || key != nil || showsPhone || showsEnd || showsMore }
}

/// Narrow-window yield order (§3): source name truncates first (the leading title takes the
/// remaining width), then key action text → Phone text → chip text → capsule title. Ending
/// the session is always an icon; the capsule itself is never hidden.
public struct TitlebarCompaction: Sendable, Equatable {
    public static let maxLevel = 4
    public var level: Int
    public var windowWidth: Double

    public init(level: Int, windowWidth: Double = .infinity) {
        self.level = min(Self.maxLevel, max(0, level))
        self.windowWidth = windowWidth
    }

    public var showsKeyAction: Bool { level < 1 && windowWidth >= SubtitleTokens.Size.keyActionMinWindowWidth }
    public var showsPhoneText: Bool { level < 2 }
    public var showsEndText: Bool { false }
    public var showsChipText: Bool { level < 3 }
    public var showsFullCapsule: Bool { level < 4 }

    /// The least compact level whose trailing group fits beside `reservedLeading` (traffic
    /// lights, scene icon and the scene title without its source).
    public static func choose(windowWidth: Double, reservedLeading: Double,
                              measure: (TitlebarCompaction) -> Double) -> TitlebarCompaction {
        for level in 0...maxLevel {
            let candidate = TitlebarCompaction(level: level, windowWidth: windowWidth)
            if reservedLeading + measure(candidate) <= windowWidth { return candidate }
        }
        return TitlebarCompaction(level: maxLevel, windowWidth: windowWidth)
    }
}
