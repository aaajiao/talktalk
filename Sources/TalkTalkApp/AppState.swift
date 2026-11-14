import Foundation
import Observation
import TalkTalkApple
import TalkTalkCore
import TalkTalkSession
import TalkTalkVoice

/// App-wide UI state (`AppState`; ARCHITECTURE.md, "三种使用场景"). Holds only what the menu, the settings
/// window and (later) the subtitle panel share; the meeting session owns its own pipeline state.
@MainActor
@Observable
final class AppState {
    /// Compatibility wrapper for the active scene's source; all scenes support Chinese, English, German and French.
    enum RemoteLanguage: String, CaseIterable, Identifiable {
        case zh, en, de, fr
        var id: String { rawValue }
        var title: String { lang.title }
        /// BCP-47 locale for SpeechAnalyzer / Translation.
        var localeIdentifier: String { AppleSpeechASR.localeIdentifier(lang) }
        /// The engines' language (TalkTalkCore).
        var lang: Lang {
            switch self {
            case .zh: .zh
            case .en: .en
            case .de: .de
            case .fr: .fr
            }
        }
        init?(_ lang: Lang) {
            switch lang {
            case .en: self = .en
            case .de: self = .de
            case .zh: self = .zh
            case .fr: self = .fr
            }
        }
    }

    typealias ListenASREngine = SpeechRecognitionEngine

    private enum Key {
        static let listenASREngine = "listen.asrEngine"
        static let speakASREngine = "speak.asrEngine"
        static let subtitlesVisible = "ui.subtitlesVisible"
        static let subtitleFontSize = "ui.subtitleFontSize"
        static let subtitleBackgroundOpacity = "ui.subtitleBackgroundOpacity"
        static let videoSubtitleFontSize = "ui.videoSubtitleFontSize"
        static let videoSubtitleBackgroundOpacity = "ui.videoSubtitleBackgroundOpacity"
        static let videoCaptionStyle = "ui.videoCaptionStyle"
        static let videoCaptionArrangement = "ui.videoCaptionArrangement"
        static let phoneSubtitleFontSize = "ui.phoneSubtitleFontSize"
        static let phoneSubtitleBackgroundOpacity = "ui.phoneSubtitleBackgroundOpacity"
        static let announceNewTranslations = "ui.announceNewTranslations"
        static let videoSubtitleLocked = "ui.videoSubtitleLocked"
        static let videoLongSilenceDim = "ui.videoLongSilenceDim"
        static let phonePreparedOnce = "ui.phonePreparedOnce"
    }

    private let defaults: UserDefaults
    let voiceStore: VoiceStore

    private var meetingListenLanguages: ListenLanguageSelection
    private var phoneListenLanguages: ListenLanguageSelection
    private var videoListenLanguages: ListenLanguageSelection
    var listenLanguageMode: MeetingMode {
        meetingActive || meetingStarting || meetingStopping ? meetingMode : requestedScenario
    }
    var activeListenLanguages: ListenLanguageSelection { listenLanguages(for: listenLanguageMode) }
    var remoteLanguage: RemoteLanguage {
        get { RemoteLanguage(activeListenLanguages.source)! }
        set { setListenLanguages(activeListenLanguages.selectingSource(newValue.lang), for: listenLanguageMode) }
    }
    func listenLanguages(for mode: MeetingMode) -> ListenLanguageSelection {
        switch mode {
        case .meeting: meetingListenLanguages
        case .phone: phoneListenLanguages
        case .captions: videoListenLanguages
        }
    }
    func setListenLanguages(_ languages: ListenLanguageSelection, for mode: MeetingMode) {
        let scope: ListenLanguagePreferences.Scope = switch mode {
        case .meeting: .meeting
        case .phone: .phone
        case .captions: .video
        }
        let next = ListenLanguagePreferences.normalized(languages, for: scope)
        guard next != listenLanguages(for: mode) else { return }
        switch mode {
        case .meeting: meetingListenLanguages = next
        case .phone: phoneListenLanguages = next
        case .captions: videoListenLanguages = next
        }
        ListenLanguagePreferences.save(next, for: scope, defaults: defaults)
        onLanguagePresentationChange?()
        if mode == listenLanguageMode { onListenConfigurationChange?() }
    }
    var listenASREngine: ListenASREngine {
        didSet {
            defaults.set(listenASREngine.rawValue, forKey: Key.listenASREngine)
            let previous = EngineRecognitionPolicy.listening(preferred: oldValue, installedProfile: installedEngineProfile)
            if effectiveListenASREngine != previous { onListenConfigurationChange?() }
        }
    }
    /// The SPEAK pipeline observes its effective choice and safely rebuilds when it changes.
    /// Keeping its own key leaves the LISTEN choice and installed model roles untouched.
    var speakASREngine: SpeechRecognitionEngine {
        didSet { defaults.set(speakASREngine.rawValue, forKey: Key.speakASREngine) }
    }
    /// The active, validated installation supplied by EngineHost, never the picker’s pending
    /// choice. Applying a profile must not overwrite the user's saved recognition preference.
    var installedEngineProfile: EngineProfile? {
        didSet {
            let previous = EngineRecognitionPolicy.listening(preferred: listenASREngine, installedProfile: oldValue)
            if effectiveListenASREngine != previous { onListenConfigurationChange?() }
        }
    }
    var effectiveListenASREngine: ListenASREngine {
        EngineRecognitionPolicy.listening(preferred: listenASREngine, installedProfile: installedEngineProfile)
    }
    var effectiveSpeakASREngine: SpeechRecognitionEngine {
        EngineRecognitionPolicy.speaking(preferred: speakASREngine, installedProfile: installedEngineProfile)
    }
    /// Selected engine and actual backend may differ when Qwen falls back to Apple.
    var listenASRStatus: String?
    /// Qwen3-ASR was chosen but Apple Speech took over (the 语音识别 card's warning).
    var listenASRFallback = false
    /// Recognition stopped in this session (the pipeline could not recover, or a language switch
    /// failed), with its sentence: the menu's 字幕识别出错 line. Cleared when recognition is rebuilt.
    var listenASRFailure: String?
    @ObservationIgnored var onListenConfigurationChange: (() -> Void)?
    @ObservationIgnored var onLanguagePresentationChange: (() -> Void)?

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
    private var storedSubtitleBackgroundOpacity: Double
    var subtitleBackgroundOpacity: Double {
        get { storedSubtitleBackgroundOpacity }
        set {
            let opacity = newValue.isFinite ? min(1, max(0.35, newValue)) : 0.85
            guard opacity != storedSubtitleBackgroundOpacity else { return }
            storedSubtitleBackgroundOpacity = opacity
            defaults.set(opacity, forKey: Key.subtitleBackgroundOpacity)
            onSubtitleAppearanceChange?()
        }
    }
    private var storedVideoSubtitleFontSize: Double
    var videoSubtitleFontSize: Double {
        get { storedVideoSubtitleFontSize }
        set {
            let size = newValue.isFinite ? min(36, max(16, newValue)) : 26
            guard size != storedVideoSubtitleFontSize else { return }
            storedVideoSubtitleFontSize = size
            defaults.set(size, forKey: Key.videoSubtitleFontSize)
            onSubtitleAppearanceChange?()
        }
    }
    private var storedVideoSubtitleBackgroundOpacity: Double
    var videoSubtitleBackgroundOpacity: Double {
        get { storedVideoSubtitleBackgroundOpacity }
        set {
            let opacity = newValue.isFinite ? min(1, max(0.35, newValue)) : 0.85
            guard opacity != storedVideoSubtitleBackgroundOpacity else { return }
            storedVideoSubtitleBackgroundOpacity = opacity
            defaults.set(opacity, forKey: Key.videoSubtitleBackgroundOpacity)
            onSubtitleAppearanceChange?()
        }
    }
    /// Video caption style (redesign §6 字幕样式), stored for the video scene only. Reduce
    /// Transparency overrides it with plates at display time without changing this choice.
    var videoCaptionStyle: VideoCaptionStyle {
        didSet {
            guard videoCaptionStyle != oldValue else { return }
            defaults.set(videoCaptionStyle.rawValue, forKey: Key.videoCaptionStyle)
            onSubtitleAppearanceChange?()
        }
    }
    /// "译文在上" (§6 排版); source above translation by default.
    var videoCaptionArrangement: VideoCaptionArrangement {
        didSet {
            guard videoCaptionArrangement != oldValue else { return }
            defaults.set(videoCaptionArrangement.rawValue, forKey: Key.videoCaptionArrangement)
            onSubtitleAppearanceChange?()
        }
    }
    /// "锁定字幕位置（鼠标穿透）" (redesign §6), saved for the video scene. Set from the hover
    /// bar's ⋯ menu or the menu-bar menu; only the menu-bar menu can clear it.
    var videoSubtitleLocked: Bool {
        didSet {
            guard videoSubtitleLocked != oldValue else { return }
            defaults.set(videoSubtitleLocked, forKey: Key.videoSubtitleLocked)
            onSubtitleAppearanceChange?()
        }
    }
    /// "静默变暗" (redesign §1), on by default.
    var videoLongSilenceDim: Bool {
        didSet {
            guard videoLongSilenceDim != oldValue else { return }
            defaults.set(videoLongSilenceDim, forKey: Key.videoLongSilenceDim)
            onSubtitleAppearanceChange?()
        }
    }
    @ObservationIgnored var onSubtitleAppearanceChange: (() -> Void)?
    /// "朗读新译文（VoiceOver）" (redesign §4 无障碍): off by default; each translation final is
    /// announced at medium priority while the window is visible, drafts never.
    var announceNewTranslations: Bool {
        didSet {
            guard announceNewTranslations != oldValue else { return }
            defaults.set(announceNewTranslations, forKey: Key.announceNewTranslations)
            onSubtitleAppearanceChange?()
        }
    }

    var phoneSubtitleFontSize: Double {
        didSet {
            defaults.set(phoneSubtitleFontSize, forKey: Key.phoneSubtitleFontSize)
            onSubtitleAppearanceChange?()
        }
    }
    var phoneSubtitleBackgroundOpacity: Double {
        didSet {
            defaults.set(phoneSubtitleBackgroundOpacity, forKey: Key.phoneSubtitleBackgroundOpacity)
            onSubtitleAppearanceChange?()
        }
    }

    private var meetingSpeakLanguages: SpeakLanguageSelection {
        didSet { SpeakLanguagePreferences.save(meetingSpeakLanguages, for: .meeting, defaults: defaults) }
    }
    private var phoneSpeakLanguages: SpeakLanguageSelection {
        didSet { SpeakLanguagePreferences.save(phoneSpeakLanguages, for: .phone, defaults: defaults) }
    }
    /// A running session keeps its own scene even while the user browses another settings page.
    var speakLanguageMode: MeetingMode {
        let mode = meetingActive || meetingStarting || meetingStopping ? meetingMode : requestedScenario
        return mode == .phone ? .phone : .meeting
    }
    var speakSourceLanguage: SpeakSourceLanguage {
        get { speakLanguages(for: speakLanguageMode).source }
        set { setSpeakSource(newValue, for: speakLanguageMode) }
    }
    var speakLanguage: SpeakTargetLanguage {
        get { speakLanguages(for: speakLanguageMode).target }
        set { setSpeakTarget(newValue, for: speakLanguageMode) }
    }
    func speakLanguages(for mode: MeetingMode) -> SpeakLanguageSelection {
        mode == .phone ? phoneSpeakLanguages : meetingSpeakLanguages
    }
    func setSpeakSource(_ source: SpeakSourceLanguage, for mode: MeetingMode) {
        guard mode.supportsSpeaking else { return }
        guard source != speakLanguages(for: mode).source else { return }
        if mode == .phone { phoneSpeakLanguages = phoneSpeakLanguages.selectingSource(source) }
        else { meetingSpeakLanguages = meetingSpeakLanguages.selectingSource(source) }
        onLanguagePresentationChange?()
    }
    func setSpeakTarget(_ target: SpeakTargetLanguage, for mode: MeetingMode) {
        guard mode.supportsSpeaking else { return }
        let previous = speakLanguages(for: mode)
        let next = previous.selectingTarget(target)
        guard next != previous else { return }
        if mode == .phone { phoneSpeakLanguages = next }
        else { meetingSpeakLanguages = next }
        onLanguagePresentationChange?()
    }

    /// A session can start now: onboarding is done and no self-test, speaking test, engine
    /// installation or maintenance holds the audio (AppDelegate keeps it in step). The menu's
    /// quick start and the scenario page's start read it alike.
    var meetingAvailable = true
    /// The quick start found several sources and opened this scene's page instead (the page's
    /// problem line and the menu's 确认应用…); cleared by choosing a source or the next start.
    var sourceChoicePending: MeetingMode?
    /// A start waits for macOS's speech-asset download (the 下载中 tooltip).
    var downloadingSpeechAssets = false
    var meetingMode: MeetingMode = .meeting
    /// Settings selection only; choosing a scene never changes a running session. Persisted
    /// as `ui.requestedScenario` (redesign §7).
    var requestedScenario: MeetingMode {
        didSet { if requestedScenario != oldValue { ScenarioPreferences.setRequested(requestedScenario, defaults: defaults) } }
    }
    /// The scenario that last started successfully, for the menu's quick start (`ui.lastScenario`).
    var lastScenario: MeetingMode? {
        didSet { if let lastScenario, lastScenario != oldValue { ScenarioPreferences.setLast(lastScenario, defaults: defaults) } }
    }
    struct SourceOption: Identifiable, Equatable {
        let id: String
        let name: String
    }
    var availableSources: [SourceOption] = []
    var meetingSourceID: String {
        didSet {
            ListeningSourcePreferences.setSource(meetingSourceID, for: .meeting, defaults: defaults)
            if sourceChoicePending == .meeting { sourceChoicePending = nil }
        }
    }
    var videoSourceID: String {
        didSet {
            ListeningSourcePreferences.setSource(videoSourceID, for: .captions, defaults: defaults)
            if sourceChoicePending == .captions { sourceChoicePending = nil }
        }
    }
    @ObservationIgnored var onRefreshSources: (() -> Void)?

    func selectedSource(for mode: MeetingMode) -> String? {
        switch mode {
        case .phone: MeetingMode.phoneAppID
        case .meeting: meetingSourceID.isEmpty ? nil : meetingSourceID
        case .captions: videoSourceID.isEmpty ? nil : videoSourceID
        }
    }

    func selectSource(_ id: String, for mode: MeetingMode) {
        switch mode {
        case .phone: break
        case .meeting: meetingSourceID = id
        case .captions: videoSourceID = id
        }
    }
    var phoneStatus: String?
    var phoneProblem: String?
    /// Feed is ready but Phone cannot read TalkTalk Mic yet (SpeakController): the actionable sentence.
    var phoneInputHint: String?
    var phoneReadyToDial = false {
        didSet {
            if phoneReadyToDial, !phonePreparedOnce { phonePreparedOnce = true }
            if phoneReadyToDial, !phoneReadyThisSession { phoneReadyThisSession = true }
        }
    }
    /// This phone session has been ready to dial; reset when the next preparation starts.
    var phoneReadyThisSession = false
    /// A phone session has been ready to dial once (`ui.phonePreparedOnce`): 首次连接 is then
    /// collapsed by default (§7.2).
    private(set) var phonePreparedOnce: Bool {
        didSet { if phonePreparedOnce != oldValue { defaults.set(phonePreparedOnce, forKey: Key.phonePreparedOnce) } }
    }
    var phoneAudioActive = false
    /// The subtitle titlebar's voice state (HUDModel.voiceState), from the real speech gate,
    /// the Phone reader and the microphone guard's raw-audio risk; never inferred from
    /// opening Phone or preparing the local engine.
    var phoneVoice: VoiceState?
    /// The same titlebar voice state for a meeting session (the scenario page's running dot).
    var meetingVoice: VoiceState?
    /// The phone page's live row popover (closed by AppDelegate when the voice state goes).
    var phoneStatusDetailsPresented = false
    @ObservationIgnored var onOpenPhone: (() -> Void)?
    @ObservationIgnored var onToggleListening: ((MeetingMode) -> Void)?
    /// True while meeting mode (LISTEN) runs (also while suspended by sleep / lock).
    var meetingActive = false
    var meetingStartedAt: Date?
    /// Name of the meeting app being listened to.
    var meetingApp: String?
    /// The current LISTEN hint (e.g. 会议当前没有声音, 会议似乎已结束).
    var meetingHint: String?
    /// Semantic identity is independent of the localized or scenario-specific display text.
    var meetingHintKind: MeetingSession.Hint?
    var meetingStarting = false
    var meetingStopping = false
    /// Includes standalone SPEAK demos and their asynchronous startup/shutdown. Mirrored by
    /// the owner so resource-maintenance controls observe the same lifetime they guard.
    var speakSessionActive = false
    /// The last session ended on a failure (menu attention line); cleared at the next start.
    var lastEndProblem: MeetingMode?
    /// The last session ended by itself (long silence, or no audio after sleep or unlock): the
    /// idle menu's neutral line; cleared at the next start.
    var lastEndAutomatic: MeetingMode?
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
    /// Compact menu presentation, derived from the same typed switcher status.
    var systemInputNotice: HUDLine?
    /// TalkTalk holds the system default input, so ending returns the physical microphone to an
    /// app that follows it: the settings 结束 button's help, as the titlebar and menu.
    var systemInputHeld = false

    /// Whether `voice/profile.json` exists; refreshed when the settings page saves or deletes.
    private(set) var voiceProfilePresent: Bool

    init(defaults: UserDefaults = .standard, voiceStore: VoiceStore = .product) {
        self.defaults = defaults
        self.voiceStore = voiceStore
        requestedScenario = ScenarioPreferences.requested(defaults: defaults)
        lastScenario = ScenarioPreferences.last(defaults: defaults)
        meetingSourceID = ListeningSourcePreferences.source(for: .meeting, defaults: defaults) ?? ""
        videoSourceID = ListeningSourcePreferences.source(for: .captions, defaults: defaults) ?? ""
        meetingListenLanguages = ListenLanguagePreferences.load(.meeting, defaults: defaults)
        phoneListenLanguages = ListenLanguagePreferences.load(.phone, defaults: defaults)
        videoListenLanguages = ListenLanguagePreferences.load(.video, defaults: defaults)
        listenASREngine = ListenASREngine(rawValue: defaults.string(forKey: Key.listenASREngine) ?? "") ?? .qwen
        speakASREngine = SpeechRecognitionEngine(rawValue: defaults.string(forKey: Key.speakASREngine) ?? "") ?? .qwen
        meetingSpeakLanguages = SpeakLanguagePreferences.load(.meeting, defaults: defaults)
        phoneSpeakLanguages = SpeakLanguagePreferences.load(.phone, defaults: defaults)
        subtitlesVisible = defaults.object(forKey: Key.subtitlesVisible) as? Bool ?? true
        let savedSize = defaults.object(forKey: Key.subtitleFontSize) as? Double ?? 22
        storedSubtitleFontSize = savedSize.isFinite ? min(36, max(16, savedSize)) : 22
        let defaultOpacity = SubtitleOpacityControl.defaultOpacity
        let savedOpacity = defaults.object(forKey: Key.subtitleBackgroundOpacity) as? Double ?? defaultOpacity
        storedSubtitleBackgroundOpacity = savedOpacity.isFinite ? min(1, max(0.35, savedOpacity)) : defaultOpacity
        let savedVideoSize = defaults.object(forKey: Key.videoSubtitleFontSize) as? Double ?? 26
        storedVideoSubtitleFontSize = savedVideoSize.isFinite ? min(36, max(16, savedVideoSize)) : 26
        let savedVideoOpacity = defaults.object(forKey: Key.videoSubtitleBackgroundOpacity) as? Double ?? defaultOpacity
        storedVideoSubtitleBackgroundOpacity = savedVideoOpacity.isFinite ? min(1, max(0.35, savedVideoOpacity)) : defaultOpacity
        videoCaptionStyle = VideoCaptionStyle(rawValue: defaults.string(forKey: Key.videoCaptionStyle) ?? "") ?? .default
        videoCaptionArrangement = VideoCaptionArrangement(
            rawValue: defaults.string(forKey: Key.videoCaptionArrangement) ?? "") ?? .default
        announceNewTranslations = defaults.object(forKey: Key.announceNewTranslations) as? Bool ?? false
        videoSubtitleLocked = defaults.object(forKey: Key.videoSubtitleLocked) as? Bool ?? false
        videoLongSilenceDim = defaults.object(forKey: Key.videoLongSilenceDim) as? Bool ?? true
        let phoneSize = defaults.object(forKey: Key.phoneSubtitleFontSize) as? Double ?? 22
        phoneSubtitleFontSize = phoneSize.isFinite ? min(36, max(16, phoneSize)) : 22
        let phoneOpacity = defaults.object(forKey: Key.phoneSubtitleBackgroundOpacity) as? Double ?? defaultOpacity
        phoneSubtitleBackgroundOpacity = phoneOpacity.isFinite ? min(1, max(0.35, phoneOpacity)) : defaultOpacity
        phonePreparedOnce = defaults.bool(forKey: Key.phonePreparedOnce)
        voiceProfilePresent = voiceStore.hasProfile
    }

    func refreshVoiceProfile() {
        voiceProfilePresent = voiceStore.hasProfile
    }
}
