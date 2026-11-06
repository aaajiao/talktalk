// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation

/// Shared, compact visual vocabulary. Capture, processing and actual output are separate
/// facts; a Phone reader never proves that a remote person has heard the audio.
public struct SpeechStatusPresentation: Sendable, Equatable {
    public var title: String
    public var symbol: String
    public var shortcut: String?
    /// The titlebar keycap's action text: 开始翻译 / 结束 / 松开确认 / 本机试说.
    public var keyAction: String?
    public var detail: String
    public var tone: PhoneSpeechPresentation.Tone

    public init(audio: HUDModel.MeetingAudio?, phoneInputConfirmed: Bool? = nil,
                playing: Bool = false) {
        let localOnly = phoneInputConfirmed == false
        detail = phoneInputConfirmed.flatMap { audio?.phonePresentation(inputConfirmed: $0).detail }
            ?? audio?.text ?? String(localized: "正在收听所选应用，麦克风未开启。")
        // Status never uses a phone glyph (the titlebar has its own Phone button), and
        // mic.slash only means "original off" or "audio unavailable".
        switch audio {
        case .phoneReady:
            title = String(localized: "本机就绪"); symbol = SubtitleTokens.VoiceIcon.localOnly; tone = .ready
        case .original:
            title = localOnly ? String(localized: "本机就绪") : String(localized: "原声")
            symbol = localOnly ? SubtitleTokens.VoiceIcon.localOnly : SubtitleTokens.VoiceIcon.original
            tone = localOnly ? .ready : .original
        case .switching:
            title = String(localized: "切换中"); symbol = SubtitleTokens.VoiceIcon.translating; tone = .progress
        case .translating:
            title = localOnly ? String(localized: "本机收音") : String(localized: "翻译收音")
            symbol = SubtitleTokens.VoiceIcon.translating; tone = .translation
        case .draining:
            title = playing
                ? (localOnly ? String(localized: "本机译音") : String(localized: "播放译音"))
                : String(localized: "处理中")
            symbol = playing ? SubtitleTokens.VoiceIcon.playingTranslation : "ellipsis.circle"
            tone = playing ? .translation : .progress
        case .restoringOriginal:
            title = String(localized: "恢复原声"); symbol = SubtitleTokens.VoiceIcon.originalOff; tone = .progress
        case .phoneReconnecting:
            title = String(localized: "重新连接 Phone"); symbol = "arrow.clockwise"; tone = .progress
        case .unavailable:
            title = String(localized: "音频不可用"); symbol = SubtitleTokens.VoiceIcon.originalOff; tone = .unavailable
        case nil:
            title = String(localized: "收听中"); symbol = SubtitleTokens.VoiceIcon.listening; tone = .ready
        }
        let action: String? = switch audio {
        case .phoneReady, .original, .restoringOriginal, .draining:
            localOnly ? titlebarLabel("本机试说") : titlebarLabel("开始翻译")
        case .switching: titlebarLabel("松开确认")
        case .translating: titlebarLabel("结束")
        case .phoneReconnecting, .unavailable, nil: nil
        }
        keyAction = action
        shortcut = action.map { String(localized: "右⌥ \($0)") }
    }
}
