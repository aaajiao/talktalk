// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation

/// Shared, compact visual vocabulary. Capture, processing and actual output are separate
/// facts; a Phone reader never proves that a remote person has heard the audio.
public struct SpeechStatusPresentation: Sendable, Equatable {
    public var title: String
    public var symbol: String
    public var shortcut: String?
    /// The titlebar keycap's action text: 开始翻译 / 完成发言 / 松开确认 / 本机试说.
    public var keyAction: String?
    /// The start glyph (`translate`) can replace `keyAction`. Finishing a turn keeps the
    /// words 完成发言 so it cannot be confused with the separate end-session stop icon.
    /// 松开确认 is a transient instruction; 本机试说 carries local-only meaning.
    /// TitlebarKey.make drops text when the capsule beside it already shows the same words.
    public var keySymbol: String?
    public var detail: String
    public var tone: PhoneSpeechPresentation.Tone

    public init(audio: HUDModel.MeetingAudio?, phoneInputConfirmed: Bool? = nil,
                playing: Bool = false) {
        let localOnly = phoneInputConfirmed == false
        detail = phoneInputConfirmed.flatMap { audio?.phonePresentation(inputConfirmed: $0).detail }
            ?? audio?.text ?? String(appLocalized: "正在收听所选应用，麦克风未开启。")
        // Status never uses a phone glyph (the titlebar has its own Phone button), and
        // mic.slash only means "original off" or "audio unavailable".
        switch audio {
        case .preparing:
            title = String(appLocalized: "准备中"); symbol = SubtitleTokens.VoiceIcon.localOnly; tone = .progress
        case .phoneReady:
            title = String(appLocalized: "本机就绪"); symbol = SubtitleTokens.VoiceIcon.localOnly; tone = .ready
        case .original:
            title = localOnly ? String(appLocalized: "本机就绪") : String(appLocalized: "原声")
            symbol = localOnly ? SubtitleTokens.VoiceIcon.localOnly : SubtitleTokens.VoiceIcon.original
            tone = localOnly ? .ready : .original
        case .switching:
            title = String(appLocalized: "切换中"); symbol = SubtitleTokens.VoiceIcon.translating; tone = .progress
        case .translating:
            title = localOnly ? String(appLocalized: "本机收音") : String(appLocalized: "翻译收音")
            symbol = SubtitleTokens.VoiceIcon.translating; tone = .translation
        case .draining:
            title = playing
                ? (localOnly ? String(appLocalized: "本机译音") : String(appLocalized: "播放译音"))
                : String(appLocalized: "处理中")
            symbol = playing ? SubtitleTokens.VoiceIcon.playingTranslation : SubtitleTokens.VoiceIcon.translating
            tone = playing ? .translation : .progress
        case .restoringOriginal:
            title = String(appLocalized: "恢复原声"); symbol = SubtitleTokens.VoiceIcon.originalOff; tone = .progress
        case .phoneReconnecting:
            title = String(appLocalized: "重新连接 Phone"); symbol = SubtitleTokens.VoiceIcon.reconnecting; tone = .progress
        case .unavailable:
            title = String(appLocalized: "音频不可用"); symbol = SubtitleTokens.VoiceIcon.originalOff; tone = .unavailable
        case nil:
            title = String(appLocalized: "收听中"); symbol = SubtitleTokens.VoiceIcon.listening; tone = .ready
        }
        let action: String? = switch audio {
        case .phoneReady, .original, .restoringOriginal, .draining:
            localOnly ? titlebarLabel("本机试说") : titlebarLabel("开始翻译")
        case .switching: titlebarLabel("松开确认")
        case .translating: titlebarLabel("完成发言")
        case .preparing, .phoneReconnecting, .unavailable, nil: nil
        }
        keyAction = action
        keySymbol = switch audio {
        case .phoneReady, .original, .restoringOriginal, .draining:
            localOnly ? nil : SubtitleTokens.VoiceIcon.startTranslation
        case .translating, .switching, .preparing, .phoneReconnecting, .unavailable, nil: nil
        }
        shortcut = action.map { String(appLocalized: "右⌥ \($0)") }
    }
}

/// The speaking gate's start-up wait (redesign §4). Until a session's audio first becomes ready
/// (feed attached, capture open, key monitor armed), the wait is normal progress: it reads
/// `.preparing` ("未发送", nothing reaches TalkTalk Mic) instead of a warn-filled "音频不可用".
/// After `graceSeconds`, or for any loss once ready, it is `.unavailable` with its reason, so a
/// start that never becomes ready still shows the fault and its 详情. The owner re-reads the
/// state at `escalatesAt`, because the gate itself reports only on events.
public struct SpeakStartupWait: Sendable, Equatable {
    public static let graceSeconds: Double = 3
    public private(set) var beganAt: Double?
    public private(set) var reachedReady = false

    public init() {}

    public mutating func begin(at now: Double) { beganAt = now; reachedReady = false }
    public mutating func reset() { beganAt = nil; reachedReady = false }

    /// Records what was reported; the first ready state ends the start-up wait for good.
    public mutating func observe(_ audio: HUDModel.MeetingAudio) {
        switch audio {
        case .original, .phoneReady, .restoringOriginal: reachedReady = true
        default: break
        }
    }

    /// A start-up wait (`reason`, e.g. 正在等待音频就绪) as the HUD should show it at `now`.
    public func waiting(reason: String, now: Double) -> HUDModel.MeetingAudio {
        guard !reachedReady, let beganAt, now - beganAt < Self.graceSeconds else { return .unavailable(reason: reason) }
        return .preparing
    }

    /// When a still-waiting start escalates to `.unavailable` by itself.
    public var escalatesAt: Double? { reachedReady ? nil : beganAt.map { $0 + Self.graceSeconds } }
}
