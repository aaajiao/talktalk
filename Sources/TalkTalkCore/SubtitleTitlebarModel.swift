// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation

/// A titlebar capsule or problem-chip label. scripts/check-strings.sh limits the literal to
/// 10 Chinese characters (a Latin word or an interpolation counts as one); complete sentences
/// belong in the chip's detail.
public func titlebarLabel(_ key: String.LocalizationValue) -> String { String(localized: key) }

/// A fading titlebar notification label, limited to 8 characters by scripts/check-strings.sh.
public func noticeLabel(_ key: String.LocalizationValue) -> String { String(localized: key) }

public enum SubtitleScene: String, Sendable, Equatable, CaseIterable {
    case meeting, phone, video

    public var title: String {
        switch self {
        case .meeting: String(localized: "会议同传")
        case .phone: String(localized: "电话同传")
        case .video: String(localized: "视频字幕")
        }
    }

    public var symbol: String {
        switch self {
        case .meeting: SubtitleTokens.SceneIcon.meeting
        case .phone: SubtitleTokens.SceneIcon.phone
        case .video: SubtitleTokens.SceneIcon.video
        }
    }

    /// Meeting and phone confirm in a popover; video ends at once.
    public var endTitle: String { self == .video ? titlebarLabel("结束") : titlebarLabel("结束同传") }
}

/// What the voice capsule says (§3). It reads the current speaking mode directly and never
/// competes with problems; only a raw-audio risk or unavailable audio rewrite it.
public struct VoiceState: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case original, translating, processing, playingTranslation, switching, restoring
        case notSent, phoneNotConnected, phoneLocalTrial, phoneLocalOnly, phoneReconnecting
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
    /// Narrowest titlebar: 原声 / 译音 / 风险 / 本机.
    public var compactTitle: String
    public var symbol: String
    /// One sentence for the details popover's top row.
    public var consequence: String
    /// Full explanation (tooltip, accessibilityHelp, details).
    public var detail: String
    /// One line for VoiceOver.
    public var accessibilityLabel: String
    /// Spoken once when the speaking mode changes; nil for transient states.
    public var announcement: String?
    /// The capsule opens details; video's listening capsule is read-only.
    public var opensDetails: Bool { kind != .listening }

    /// Mode family used to announce only real speaking-mode changes, not processing/playback
    /// toggles inside one translated turn.
    public var announcementGroup: Int {
        switch kind {
        case .original: 0
        case .translating, .processing, .playingTranslation, .switching: 1
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
            // No raw gate (isolated practice): report only actual capture/output.
            switch pushToTalk {
            case .holding: kind = unconfirmed ? .phoneLocalTrial : .translating
            case .playing: kind = unconfirmed ? .phoneLocalOnly : .playingTranslation
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
            consequence = phone ? String(localized: "你的原声正在送入 Phone") : String(localized: "对方听到的是你的原声")
            short = phone ? String(localized: "正在送入 Phone") : String(localized: "对方可听到")
            announcement = phone ? String(localized: "原声已开，正在送入 Phone") : String(localized: "原声已开，对方可听到")
        case .translating:
            title = titlebarLabel("译音"); compact = titlebarLabel("译音"); symbol = icon.translating
            appearance = .translateFill
            consequence = String(localized: "原声已关，正在收音翻译")
            short = String(localized: "原声已关，翻译中")
            announcement = String(localized: "原声已关，翻译中")
        case .processing:
            title = titlebarLabel("译音"); compact = titlebarLabel("译音"); symbol = icon.translating
            appearance = .translateFill
            consequence = String(localized: "原声已关，译音处理中")
            short = String(localized: "原声已关，译音处理中")
            announcement = String(localized: "原声已关，译音处理中")
        case .playingTranslation:
            title = titlebarLabel("译音"); compact = titlebarLabel("译音"); symbol = icon.playingTranslation
            appearance = .translateFill
            consequence = phone ? String(localized: "译音正在送入 Phone") : String(localized: "对方听到的是译音")
            short = phone ? String(localized: "译音已送入 Phone") : String(localized: "对方听到译音")
            announcement = phone ? String(localized: "译音已送入 Phone") : String(localized: "译音播放中")
        case .switching:
            title = titlebarLabel("松开确认"); compact = titlebarLabel("译音"); symbol = icon.translating
            appearance = .translateStroke
            consequence = String(localized: "原声已关，松开右⌥确认")
            short = String(localized: "松开右⌥确认")
        case .restoring:
            title = titlebarLabel("原声已关"); compact = titlebarLabel("本机"); symbol = icon.originalOff
            appearance = .dimStroke
            consequence = String(localized: "现在什么都没有发出去")
            short = String(localized: "正在恢复原声")
            announcement = String(localized: "正在恢复原声")
        case .notSent:
            title = titlebarLabel("未发送"); compact = titlebarLabel("本机"); symbol = icon.localOnly
            appearance = .dashed
            consequence = String(localized: "现在什么都没有发出去")
            short = String(localized: "对方听不到你")
            announcement = String(localized: "未发送，对方听不到你")
        case .phoneNotConnected:
            title = titlebarLabel("未接入 Phone"); compact = titlebarLabel("本机"); symbol = icon.localOnly
            appearance = .dashed
            consequence = String(localized: "接通后对方才能听到你")
            short = String(localized: "接通后对方才能听到你")
            announcement = String(localized: "未接入 Phone")
        case .phoneLocalTrial:
            title = titlebarLabel("本机试说"); compact = titlebarLabel("本机"); symbol = icon.localOnly
            appearance = .dashed
            consequence = String(localized: "Phone 未接收，现在什么都没有发出去")
            short = String(localized: "Phone 未接收")
            announcement = String(localized: "本机试说，Phone 未接收")
        case .phoneLocalOnly:
            title = titlebarLabel("仅本机"); compact = titlebarLabel("本机"); symbol = icon.localOnly
            appearance = .warnStroke
            consequence = String(localized: "译音只在本机播放，Phone 没有读取 TalkTalk Mic")
            short = String(localized: "译音只在本机播放")
            announcement = String(localized: "仅本机播放，Phone 未接收")
        case .phoneReconnecting:
            title = titlebarLabel("正在重新连接 Phone…"); compact = titlebarLabel("本机")
            symbol = "arrow.clockwise"; appearance = .dimStroke
            consequence = String(localized: "当前发言已停止，等待 Phone")
            short = String(localized: "当前发言已停止")
            announcement = String(localized: "正在重新连接 Phone")
        case .remoteHearsOriginal:
            title = titlebarLabel("对方能听到原声"); compact = titlebarLabel("风险"); symbol = icon.originalRisk
            appearance = .riskFill
            consequence = risk == .meetingNotUsingMic
                ? String(localized: "会议没有使用 TalkTalk Mic，对方能听到原声")
                : String(localized: "对方听到的是你的原声，按键翻译已停用")
            short = String(localized: "按键翻译已停用")
            announcement = String(localized: "对方能听到原声")
        case .unavailable:
            title = titlebarLabel("音频不可用"); compact = titlebarLabel("本机"); symbol = icon.originalOff
            appearance = .warnFill
            consequence = String(localized: "现在什么都没有发出去")
            short = String(localized: "未发送")
            announcement = String(localized: "音频不可用")
        case .listening:
            title = titlebarLabel("收听中"); compact = titlebarLabel("收听"); symbol = icon.listening
            appearance = .neutral
            consequence = String(localized: "只收听所选应用，麦克风未开启")
            short = String(localized: "麦克风未开启")
        }
        let detail = reason.map { String(localized: "\(consequence)。\($0)") } ?? consequence
        return VoiceState(kind: kind, appearance: appearance, title: title, compactTitle: compact, symbol: symbol,
                          consequence: consequence, detail: detail,
                          accessibilityLabel: String(localized: "发声：\(title)，\(short)"),
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
    public var action: String?
    public var style: Style

    public init(key: String = String(localized: "右⌥"), action: String?, style: Style) {
        self.key = key; self.action = action; self.style = style
    }

    /// nil when no key action applies (video, unavailable, risk, reconnecting).
    public static func make(_ presentation: SpeechStatusPresentation, voice: VoiceState) -> TitlebarKey? {
        guard voice.kind != .remoteHearsOriginal, voice.kind != .listening,
              let action = presentation.keyAction else { return nil }
        let style: Style = switch voice.kind {
        case .switching: .pressed
        case .translating: .translating
        default: .idle
        }
        return TitlebarKey(action: action, style: style)
    }
}

/// Everything the shared titlebar draws, as static data: the live window and the settings
/// preview render the same component from this value.
public struct SubtitleTitlebarContent: Sendable, Equatable {
    public var scene: SubtitleScene
    public var source: String?
    public var voice: VoiceState?
    public var issue: IssueSlot?
    public var key: TitlebarKey?
    public var showsPhone: Bool
    public var phoneEnabled: Bool
    public var showsEnd: Bool
    public var endEnabled: Bool

    public init(scene: SubtitleScene, source: String? = nil, voice: VoiceState? = nil, issue: IssueSlot? = nil,
                key: TitlebarKey? = nil, showsPhone: Bool = false, phoneEnabled: Bool = true,
                showsEnd: Bool = false, endEnabled: Bool = true) {
        self.scene = scene; self.source = source; self.voice = voice; self.issue = issue; self.key = key
        self.showsPhone = showsPhone; self.phoneEnabled = phoneEnabled
        self.showsEnd = showsEnd; self.endEnabled = endEnabled
    }

    /// Phone's source is always Phone itself.
    public var sourceTitle: String? { scene == .phone ? "Phone" : source }
    public var hasTrailingItems: Bool { voice != nil || issue != nil || key != nil || showsPhone || showsEnd }
}

/// Narrow-window yield order (§3): source name truncates first (the leading title takes the
/// remaining width), then key action text → Phone text → end text → chip text → capsule
/// title. The capsule itself is never hidden.
public struct TitlebarCompaction: Sendable, Equatable {
    public static let maxLevel = 5
    public var level: Int
    public var windowWidth: Double

    public init(level: Int, windowWidth: Double = .infinity) {
        self.level = min(Self.maxLevel, max(0, level))
        self.windowWidth = windowWidth
    }

    public var showsKeyAction: Bool { level < 1 && windowWidth >= SubtitleTokens.Size.keyActionMinWindowWidth }
    public var showsPhoneText: Bool { level < 2 }
    public var showsEndText: Bool { level < 3 }
    public var showsChipText: Bool { level < 4 }
    public var showsFullCapsule: Bool { level < 5 }

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

/// The end button's confirmation (§3). Meeting and phone confirm in a popover; video ends at
/// once. The meeting text states what the meeting app receives after TalkTalk stops.
public struct SessionEndConfirmation: Sendable, Equatable {
    public var title: String
    public var message: String
    public var confirm: String
    public var cancel: String

    /// `systemInputSwitched`: TalkTalk switched the system default input to TalkTalk Mic, so a
    /// meeting app following the default goes back to the physical microphone when it ends.
    public static func make(scene: SubtitleScene, systemInputSwitched: Bool) -> SessionEndConfirmation? {
        switch scene {
        case .video:
            return nil
        case .phone:
            return .init(title: String(localized: "结束电话同传？"),
                         message: String(localized: "通话不会挂断；结束后对方将听不到你的声音。"),
                         confirm: String(localized: "结束同传"), cancel: String(localized: "取消"))
        case .meeting:
            return .init(title: String(localized: "结束会议同传？"),
                         message: systemInputSwitched
                            ? String(localized: "会议不会结束；系统麦克风还原后，会议仍会收到你的原声。")
                            : String(localized: "会议不会结束；结束后会议将听不到你的声音。"),
                         confirm: String(localized: "结束同传"), cancel: String(localized: "取消"))
        }
    }
}
