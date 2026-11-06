// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation

/// Shared, compact visual vocabulary. Capture, processing and actual output are separate
/// facts; a Phone reader never proves that a remote person has heard the audio.
public struct SpeechStatusPresentation: Sendable, Equatable {
    public var title: String
    public var symbol: String
    public var shortcut: String?
    public var keyAction: String?
    public var detail: String
    public var tone: PhoneSpeechPresentation.Tone

    public init(audio: HUDModel.MeetingAudio?, phoneInputConfirmed: Bool? = nil,
                playing: Bool = false) {
        let localOnly = phoneInputConfirmed == false
        detail = phoneInputConfirmed.flatMap { audio?.phonePresentation(inputConfirmed: $0).detail }
            ?? audio?.text ?? String(localized: "正在收听所选应用，麦克风未开启。")
        switch audio {
        case .phoneReady:
            title = String(localized: "本机就绪"); symbol = "phone"; tone = .ready
            shortcut = String(localized: "右⌥ 开始翻译")
        case .original:
            title = localOnly ? String(localized: "本机就绪") : String(localized: "原声")
            symbol = localOnly ? "phone" : "mic.fill"; tone = localOnly ? .ready : .original
            shortcut = String(localized: "右⌥ 开始翻译")
        case .switching:
            title = String(localized: "切换中"); symbol = "arrow.left.arrow.right"; tone = .progress
            shortcut = String(localized: "松开右⌥")
        case .translating:
            title = localOnly ? String(localized: "本机收音") : String(localized: "翻译收音")
            symbol = "waveform"; tone = .translation
            shortcut = String(localized: "右⌥ 结束收音")
        case .draining:
            title = playing
                ? (localOnly ? String(localized: "本机译音") : String(localized: "播放译音"))
                : String(localized: "处理中")
            symbol = playing ? "speaker.wave.2.fill" : "ellipsis.circle"
            tone = playing ? .translation : .progress
            shortcut = String(localized: "右⌥ 继续翻译")
        case .restoringOriginal:
            title = String(localized: "恢复原声"); symbol = "arrow.clockwise"; tone = .progress
            shortcut = String(localized: "右⌥ 开始翻译")
        case .unavailable:
            title = String(localized: "音频不可用"); symbol = "mic.slash"; tone = .unavailable
            shortcut = nil
        case nil:
            title = String(localized: "收听中"); symbol = "ear"; tone = .ready; shortcut = nil
        }
        keyAction = switch audio {
        case .phoneReady, .original, .restoringOriginal: String(localized: "开始翻译")
        case .switching: String(localized: "松开确认")
        case .translating: String(localized: "结束收音")
        case .draining: String(localized: "继续翻译")
        case .unavailable, nil: nil
        }
    }
}
