import Foundation
import Observation
import TalkTalkApple
import TalkTalkCore
import TalkTalkSession
import TalkTalkVoice

/// App-wide UI state (ARCHITECTURE.md §13 `AppState`). Holds only what the menu, the settings
/// window and (later) the subtitle panel share; the meeting session owns its own pipeline state.
@MainActor
@Observable
final class AppState {
    /// The remote side's language, chosen per meeting and remembered (§11 菜单 "对方语言").
    enum RemoteLanguage: String, CaseIterable, Identifiable {
        case en, de
        var id: String { rawValue }
        var title: String { self == .en ? "English" : "Deutsch" }
        /// BCP-47 locale for SpeechAnalyzer / Translation.
        var localeIdentifier: String { AppleSpeechASR.localeIdentifier(lang) }
        /// The engines' language (TalkTalkCore).
        var lang: Lang {
            switch self {
            case .en: .en
            case .de: .de
            }
        }
        /// nil for zh: Chinese is never the remote side (§1).
        init?(_ lang: Lang) {
            switch lang {
            case .en: self = .en
            case .de: self = .de
            case .zh: return nil
            }
        }
    }

    enum ListenASREngine: String, CaseIterable, Identifiable {
        case qwen, apple
        var id: String { rawValue }
        var title: String { self == .qwen ? "Qwen3-ASR" : "Apple Speech" }
    }

    private enum Key {
        static let remoteLanguage = "listen.remoteLanguage"
        static let listenASREngine = "listen.asrEngine"
        static let subtitlesVisible = "ui.subtitlesVisible"
        static let subtitleFontSize = "ui.subtitleFontSize"
        static let speakLanguage = "speak.targetLanguage"
    }

    private let defaults: UserDefaults
    let voiceStore: VoiceStore

    var remoteLanguage: RemoteLanguage {
        didSet {
            defaults.set(remoteLanguage.rawValue, forKey: Key.remoteLanguage)
            if remoteLanguage != oldValue { onListenConfigurationChange?() }
        }
    }
    var listenASREngine: ListenASREngine {
        didSet {
            defaults.set(listenASREngine.rawValue, forKey: Key.listenASREngine)
            if listenASREngine != oldValue { onListenConfigurationChange?() }
        }
    }
    /// Selected engine and actual backend may differ when Qwen falls back to Apple.
    var listenASRStatus: String?
    @ObservationIgnored var onListenConfigurationChange: (() -> Void)?

    var subtitlesVisible: Bool {
        didSet {
            defaults.set(subtitlesVisible, forKey: Key.subtitlesVisible)
            if subtitlesVisible != oldValue { onSubtitleVisibilityChange?(subtitlesVisible) }
        }
    }
    @ObservationIgnored var onSubtitleVisibilityChange: ((Bool) -> Void)?

    private var storedSubtitleFontSize: Double
    var subtitleFontSize: Double {
        get { storedSubtitleFontSize }
        set {
            let size = newValue.isFinite ? min(36, max(16, newValue)) : 22
            guard size != storedSubtitleFontSize else { return }
            storedSubtitleFontSize = size
            defaults.set(size, forKey: Key.subtitleFontSize)
            onSubtitleAppearanceChange?()
        }
    }
    @ObservationIgnored var onSubtitleAppearanceChange: (() -> Void)?

    var speakLanguage: RemoteLanguage {
        didSet { defaults.set(speakLanguage.rawValue, forKey: Key.speakLanguage) }
    }

    /// Meeting mode (LISTEN) can be started from the menu.
    var meetingAvailable = true
    var meetingMode: MeetingMode = .meeting
    @ObservationIgnored var onToggleListening: ((MeetingMode) -> Void)?
    /// True while meeting mode (LISTEN) runs (also while suspended by sleep / lock).
    var meetingActive = false
    var meetingStartedAt: Date?
    /// Name of the meeting app being listened to.
    var meetingApp: String?
    /// The current LISTEN hint (e.g. 会议当前没有声音, 会议似乎已结束).
    var meetingHint: String?
    var meetingStarting = false
    var meetingStopping = false
    /// §7.5 item 6 summary when something Apple-side is missing (nil = all fine or not checked).
    var appleCheck: String?
    /// Where the running meeting's finals come from (nil: no meeting) and whether the network is
    /// down now (§11 menu line, icon).
    var listenTranslation: ListenTranslation?
    var listenOffline = false
    var listenTranslationDegraded: Bool {
        guard let t = listenTranslation else { return false }
        return t.isDegraded || listenOffline
    }
    /// SystemInputSwitcher status for the menu (nil = nothing of ours in play), and its last notice.
    var systemInput: String?

    /// Whether `voice/profile.json` exists; refreshed when the settings page saves or deletes.
    private(set) var voiceProfilePresent: Bool

    init(defaults: UserDefaults = .standard, voiceStore: VoiceStore = .product) {
        self.defaults = defaults
        self.voiceStore = voiceStore
        remoteLanguage = RemoteLanguage(rawValue: defaults.string(forKey: Key.remoteLanguage) ?? "") ?? .en
        listenASREngine = ListenASREngine(rawValue: defaults.string(forKey: Key.listenASREngine) ?? "") ?? .qwen
        speakLanguage = RemoteLanguage(rawValue: defaults.string(forKey: Key.speakLanguage) ?? "") ?? .en
        subtitlesVisible = defaults.object(forKey: Key.subtitlesVisible) as? Bool ?? true
        let savedSize = defaults.object(forKey: Key.subtitleFontSize) as? Double ?? 22
        storedSubtitleFontSize = savedSize.isFinite ? min(36, max(16, savedSize)) : 22
        voiceProfilePresent = voiceStore.hasProfile
    }

    func refreshVoiceProfile() {
        voiceProfilePresent = voiceStore.hasProfile
    }
}
