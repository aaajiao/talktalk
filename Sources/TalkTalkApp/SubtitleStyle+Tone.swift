import AppKit
import TalkTalkCore
import TalkTalkSession
import TalkTalkSettingsUI

extension SubtitleStyle {
    /// A voice-state dot outside the subtitle panel (menu, settings): the token colour for the
    /// surface it is drawn on, resolved per appearance. Here, not in TalkTalkSettingsUI:
    /// `VoiceTone` is session state.
    static func toneColor(_ tone: VoiceTone) -> NSColor {
        func token(_ role: SubtitleTokens.Color) -> NSColor {
            NSColor(name: nil) { appearance in
                let light = appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
                return nsColor(role.rgba(lightSurface: light))
            }
        }
        return switch tone {
        case .original: token(.voiceOriginal)
        case .translate: token(.voiceTranslate)
        case .warn: token(.warn)
        case .risk: token(.riskFill)
        case .neutral: .tertiaryLabelColor
        }
    }
}
