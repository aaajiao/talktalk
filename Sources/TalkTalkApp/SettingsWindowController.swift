import AppKit
import SwiftUI
import TalkTalkAudio
import TalkTalkCloudUI
import TalkTalkCore
import TalkTalkSession

/// The sections of the settings window, in the order of ARCHITECTURE.md §11 "设置".
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, meeting, subtitles, audio, voice, translation, components, glossary, privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "通用"
        case .meeting: "使用场景"
        case .subtitles: "字幕"
        case .audio: "音频"
        case .voice: "我的声音"
        case .translation: "模型"
        case .components: "组件"
        case .glossary: "术语表"
        case .privacy: "隐私与诊断"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .meeting: "person.2.wave.2"
        case .subtitles: "captions.bubble"
        case .audio: "waveform"
        case .voice: "person.wave.2"
        case .translation: "character.bubble"
        case .components: "shippingbox"
        case .glossary: "list.bullet.rectangle"
        case .privacy: "hand.raised"
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    private static let key = "ui.settingsSection"
    var modelStage: ModelSettingsStage = .recognition
    var componentsTab: ComponentsSettingsTab = .engine
    var diagnosticsTab: DiagnosticsSettingsTab = .privacy
    var subtitlePresentation: SubtitlePanel.Presentation = .meeting
    /// Settings › 字幕 preview backdrop per scene: a viewing aid, never saved (no @State: the
    /// CLT toolchain has no SwiftUIMacros plugin).
    var subtitlePreviewBackdrops: [SubtitleScene: SubtitlePreviewBackdrop] = [:]
    var selection: SettingsSection? {
        didSet {
            UserDefaults.standard.set(selection?.rawValue, forKey: Self.key)
            onSelectionChange?(selection ?? .general)
            // The return pill belongs to the page a scenario link opened; elsewhere it goes.
            if !followingLink, selection == .meeting || (returnToScene != nil && selection != returnTarget) {
                returnToScene = nil
                savedSceneScrollOffset = nil
            }
        }
    }
    @ObservationIgnored var onSelectionChange: ((SettingsSection) -> Void)?

    /// "‹ 返回 <场景>" on a page reached from a scenario's flow link (redesign §7).
    private(set) var returnToScene: MeetingMode?
    @ObservationIgnored private var returnTarget: SettingsSection?
    @ObservationIgnored private var followingLink = false
    /// The scenario page's current scroll offset, and the one to restore when coming back.
    @ObservationIgnored var sceneScrollOffset: Double = 0
    /// Scenario page view state (no @State: the CLT toolchain has no SwiftUIMacros plugin).
    var sceneScroll = ScrollPosition(edge: .top)
    var sceneHeaderCollapsed = false
    @ObservationIgnored private var savedSceneScrollOffset: Double?

    /// Opens another page from the scenario page and remembers where to come back to.
    func follow(from scene: MeetingMode, _ open: () -> Void) {
        let offset = sceneScrollOffset
        followingLink = true
        open()
        followingLink = false
        guard selection != .meeting else { return }
        returnTarget = selection
        returnToScene = scene
        savedSceneScrollOffset = offset
    }

    /// The pill's action: back to the scenario page at its previous scroll position.
    func returnToScenePage() {
        followingLink = true
        selection = .meeting
        followingLink = false
        returnToScene = nil
    }

    func dismissReturnToScene() {
        returnToScene = nil
        savedSceneScrollOffset = nil
    }

    /// The offset to restore once, after `returnToScenePage`.
    func takeSceneScrollRestore() -> Double? {
        defer { savedSceneScrollOffset = nil }
        return returnToScene == nil ? savedSceneScrollOffset : nil
    }

    func openModel(_ stage: ModelSettingsStage) {
        modelStage = stage
        selection = .translation
    }

    func openComponents(_ tab: ComponentsSettingsTab) {
        componentsTab = tab
        selection = .components
    }

    init() {
        selection = SettingsSection(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .general
    }
}

/// Settings live in an ordinary `NSWindow` hosting SwiftUI (§11: an accessory app's SwiftUI
/// Settings scene does not come forward reliably — readread's experience). While the window is
/// open the app is a regular app (Dock icon, ⌘-Tab, key focus for text fields); when it closes
/// the app goes back to being a menu bar accessory.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let state: AppState
    let navigation = SettingsNavigation()
    let voice: MyVoiceModel
    let translation = TranslationPage()
    let glossary = GlossarySettingsModel()
    /// 组件 › 虚拟麦克风 and 通用 › 应用管理 share the same guarded maintenance owner.
    let driver = DriverComponentsPage(engine: AppUIModels.shared.engine)
    private var window: NSWindow?
    private var foregroundGeneration: UInt64 = 0

    init(state: AppState, engineHost: EngineHost) {
        self.state = state
        self.voice = MyVoiceModel(store: state.voiceStore, engineHost: engineHost,
                                  onChange: { [weak state] in state?.refreshVoiceProfile() })
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show(_ section: SettingsSection? = nil) {
        if let section { navigation.selection = section }
        let window = self.window ?? makeWindow()
        self.window = window
        voice.reload()
        foregroundGeneration &+= 1
        let generation = foregroundGeneration
        NSApp.setActivationPolicy(.regular)
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        if window.isMiniaturized { window.deminiaturize(nil) }
        bringToFront(window)
        // A status-item menu may restore the previous app's ordering as its tracking loop
        // exits. Activation and the accessory→regular transition are asynchronous too.
        // Repeat once after that turn, only for this explicit request and this live window.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.foregroundGeneration == generation,
                  self.window === window, window.isVisible, !window.isMiniaturized else { return }
            self.bringToFront(window)
        }
    }

    private func bringToFront(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Normal-level ordering is deliberate: settings must be visible now, but must not
        // remain above other apps after the user leaves it, as a floating window would.
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let view = SettingsView(state: state, navigation: navigation, voice: voice, translation: translation,
                                driver: driver, glossary: glossary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "TalkTalk"
        window.title += " 设置"
        window.identifier = NSUserInterfaceItemIdentifier("TalkTalkSettings")
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        navigation.onSelectionChange = { [weak window] section in window?.title = "\(section.title) — TalkTalk" }
        navigation.onSelectionChange?(navigation.selection ?? .general)
        let host = NSHostingView(rootView: view)
        // The window size is ours (contentMinSize below), not SwiftUI's: with the default options,
        // and even with [.minSize], wrapped text measured at a narrow width forces the window to
        // ~1200 pt tall (seen on this Mac's 1239 pt screen).
        host.sizingOptions = []
        window.contentView = host
        window.contentMinSize = NSSize(width: 820, height: 600)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 880, height: 640))
        window.center()
        window.setFrameAutosaveName("TalkTalkSettings")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        foregroundGeneration &+= 1   // a queued foreground request must not reopen this window
        // Leaving mid-take releases the microphone and drops the staging directory (§9.2 step 8).
        voice.endRecording()
        AppUIModels.shared.audio.calibration.cancel()
        AppActivation.windowWillClose(notification.object as? NSWindow)   // .accessory only if no other window
    }
}

struct SettingsView: View {
    @Bindable var state: AppState
    @Bindable var navigation: SettingsNavigation
    let voice: MyVoiceModel
    let translation: TranslationPage
    let driver: DriverComponentsPage
    let glossary: GlossarySettingsModel

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsSection.allCases, selection: $navigation.selection) { section in
                HStack(spacing: 10) {
                    Image(systemName: section.symbol)
                        .resizable().scaledToFit()
                        .frame(width: 18, height: 18)
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                    Text(section.title)
                }
                .tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            VStack(spacing: 0) {
                if let scene = navigation.returnToScene, navigation.selection != .meeting {
                    ReturnToScenePill(mode: scene, back: navigation.returnToScenePage,
                                      dismiss: navigation.dismissReturnToScene)
                }
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private var detail: some View {
        switch navigation.selection ?? .general {
        case .voice:
            MyVoiceSettingsView(model: voice)
        case .meeting:
            MeetingSettingsView(state: state, navigation: navigation)
        case .subtitles:
            SubtitleSettingsView(state: state, navigation: navigation)
        case .translation:
            ModelSettingsView(state: state, navigation: navigation, translation: translation)
        case .general:
            GeneralSettingsView(model: AppUIModels.shared.general, driver: driver)
        case .audio:
            AudioSettingsView(model: AppUIModels.shared.audio, meetingActive: state.meetingActive)
        case .components:
            ComponentsSettingsView(navigation: navigation, engine: AppUIModels.shared.engine, driver: driver)
        case .glossary:
            GlossarySettingsView(model: glossary)
        case .privacy:
            DiagnosticsView(model: PrivacySettings.shared, navigation: navigation)
        }
    }
}

struct PlaceholderSettingsView: View {
    let title: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            ForEach(lines, id: \.self) { line in
                Text(line).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(20)
    }
}

/// Settings › 翻译 is talktalk-swift's `TranslationSettingsView` (§7.7, §11). Its model reads the
/// key item's presence, so it is created when the page first appears, not when the window opens.
@MainActor
@Observable
final class TranslationPage {
    private(set) var model: TranslationSettingsModel?
    private(set) var problem: String?

    func load() {
        guard model == nil, problem == nil else { return }
        do { model = try TranslationSettingsModel.forCurrentApp() } catch {
            problem = "这个构建没有 bundle id（直接运行的二进制），翻译设置只在 TalkTalk.app / TalkTalk-Dev.app 里可用。"
        }
    }
}

struct TranslationPageView: View {
    let page: TranslationPage

    var body: some View {
        Group {
            if let model = page.model {
                TranslationSettingsView(model: model)
            } else if let problem = page.problem {
                PlaceholderSettingsView(title: "翻译", lines: [problem])
            } else {
                ProgressView()
            }
        }
        .onAppear { page.load() }
    }
}
