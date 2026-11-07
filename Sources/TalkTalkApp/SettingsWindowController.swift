// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import SwiftUI
import TalkTalkAudio
import TalkTalkCloudUI
import TalkTalkCore
import TalkTalkSession
import TalkTalkSettingsUI

/// The sections of the settings window, in the order of ARCHITECTURE.md §11 "设置".
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, meeting, subtitles, audio, voice, translation, components, glossary, privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "通用")
        case .meeting: String(localized: "使用场景")
        case .subtitles: String(localized: "字幕")
        case .audio: String(localized: "音频")
        case .voice: String(localized: "我的声音")
        case .translation: String(localized: "识别与翻译")
        case .components: String(localized: "安装与维护")
        case .glossary: String(localized: "术语表")
        case .privacy: String(localized: "隐私与诊断")
        }
    }

    /// The sidebar glyph (settings visual system §4), also the menu's glyph for opening the page.
    var symbol: String {
        typealias Page = SubtitleTokens.SettingsIcon.Page
        return switch self {
        case .general: Page.general
        case .meeting: Page.scenarios
        case .subtitles: Page.subtitles
        case .audio: Page.audio
        case .voice: Page.voice
        case .translation: Page.models
        case .components: Page.components
        case .glossary: Page.glossary
        case .privacy: Page.privacy
        }
    }
}

/// The sub-page a page's card row selects (settings visual system §6.1).
enum SettingsSubpage: Hashable {
    case model(ModelSettingsStage)
    case components(ComponentsSettingsTab)
    case diagnostics(DiagnosticsSettingsTab)
}

/// Where ReturnPill leads back to (§3.13, §6.4): the page, its sub-page, the scene card and the
/// scroll position at the moment a flow link left it, with the name and icon the pill shows.
struct SettingsReturnTarget: Equatable {
    let section: SettingsSection
    let subpage: SettingsSubpage?
    let scenario: MeetingMode?
    let scrollOffset: Double
    let title: String
    let symbol: String
}

/// The window's navigation state (no @State: the CLT toolchain has no SwiftUIMacros plugin):
/// the page, each page's last sub-page (§6.2), the ReturnPill target and the page scroll.
@MainActor
@Observable
final class SettingsNavigation {
    private static let key = "ui.settingsSection"
    var modelStage: ModelSettingsStage = .recognition {
        didSet { if modelStage != oldValue { subpageChanged() } }
    }
    var componentsTab: ComponentsSettingsTab = .engine {
        didSet { if componentsTab != oldValue { subpageChanged() } }
    }
    var diagnosticsTab: DiagnosticsSettingsTab = .privacy {
        didSet { if diagnosticsTab != oldValue { subpageChanged() } }
    }
    var selection: SettingsSection? {
        didSet {
            UserDefaults.standard.set(selection?.rawValue, forKey: Self.key)
            onSelectionChange?(selection ?? .general)
            guard selection != oldValue else { return }
            // A new page starts at the top, not at the leaving page's position.
            pageScrollStorage = ScrollPosition(edge: .top)
            pageScrollOffset = 0
            // The pill belongs to the page a link opened; any other page change drops it.
            if !followingLink {
                returnTarget = nil
                pendingScrollRestore = nil
                pendingAnchor = nil
            }
        }
    }
    @ObservationIgnored var onSelectionChange: ((SettingsSection) -> Void)?
    /// The flow diagrams' flash state (§3.3).
    let flow = FlowInteraction()
    /// The section a flow link scrolls to on its target page (§6.3, §6.4), taken once by the
    /// page when it appears.
    @ObservationIgnored private var pendingAnchor: String?
    /// Counts the links that asked for an anchor: a page already on screen (a menu problem row to
    /// the shown page) takes it on the change, as a newly shown page takes it on appearing.
    private(set) var anchorRequest = 0
    /// 电话同传 › 首次连接: nil follows the default (open until a first successful prepare).
    var phoneSetupExpanded: Bool?
    /// That default as this visit of the phone scene first drew it; cleared when the visit ends,
    /// so a prepare that succeeds while the page is shown does not collapse it on screen.
    @ObservationIgnored var phoneSetupDefault: Bool?

    /// ReturnPill on a page reached through a flow link; nil after any other navigation.
    private(set) var returnTarget: SettingsReturnTarget?
    @ObservationIgnored private var followingLink = false
    @ObservationIgnored private var pendingScrollRestore: Double?

    /// The shown page's scroll offset (written on scroll, never observed).
    @ObservationIgnored var pageScrollOffset: Double = 0
    /// The page Form's scroll position. Not observed: SwiftUI writes it back on every scroll
    /// commit, and an observed write re-renders the page, which commits and writes again — an
    /// endless layout loop that froze the settings window (8c87ba7). Programmatic scrolls go
    /// through `scrollPage(_:)`, whose observed token makes the page apply the position once.
    @ObservationIgnored private var pageScrollStorage = ScrollPosition(edge: .top)
    private(set) var pageScrollRequest = 0
    var pageScrollBinding: Binding<ScrollPosition> {
        Binding(get: { self.pageScrollStorage }, set: { self.pageScrollStorage = $0 })
    }
    func scrollPage(_ change: (inout ScrollPosition) -> Void) {
        change(&pageScrollStorage)
        pageScrollRequest &+= 1
    }

    /// A page, or a new sub-page or scene of it, appeared: at the position ReturnPill saved for
    /// it, otherwise at the top (§2: switching cards scrolls back to the top).
    func pageAppeared() {
        pageScrollOffset = 0
        guard let offset = pendingScrollRestore else {
            // A flow link's anchor: the page scrolls to that section itself (`takeAnchor`).
            if pendingAnchor == nil { scrollPage { $0.scrollTo(edge: .top) } }
            return
        }
        pendingScrollRestore = nil
        // After the first layout: an offset applies only once the content is there.
        DispatchQueue.main.async { self.scrollPage { $0.scrollTo(y: offset) } }
    }

    private func subpageChanged() {
        pageScrollStorage = ScrollPosition(edge: .top)
    }

    /// A flow link (§6.4): selects the page and its sub-page together and offers ReturnPill back
    /// to the current page, sub-page, scene (`scenario`, from 使用场景 and 字幕) and position.
    /// `anchor`: the target page scrolls to that section and flashes it.
    func open(_ section: SettingsSection, _ subpage: SettingsSubpage? = nil, scenario: MeetingMode? = nil,
              anchor: String? = nil) {
        let destination = Self.destination(section, subpage, anchor: anchor)
        pendingAnchor = destination.anchor
        if destination.anchor != nil { anchorRequest &+= 1 }
        let origin = selection ?? .general
        let label = returnLabel(origin, scenario: scenario)
        let target = SettingsReturnTarget(section: origin, subpage: self.subpage(of: origin), scenario: scenario,
                                          scrollOffset: pageScrollOffset, title: label.title, symbol: label.symbol)
        followingLink = true
        if let subpage = destination.subpage { apply(subpage) }
        selection = destination.section
        followingLink = false
        if destination.section != origin { returnTarget = target }
    }

    /// A menu problem row (§8.1, §8.5): the page, sub-page and section of a flow link, without
    /// ReturnPill (the menu is not a settings page to go back to).
    func reveal(_ section: SettingsSection, _ subpage: SettingsSubpage? = nil, anchor: String? = nil) {
        open(section, subpage, anchor: anchor)
        returnTarget = nil
    }

    /// ReturnPill's action, after the caller has put the target's scene back.
    func returnToOrigin() {
        guard let target = returnTarget else { return }
        returnTarget = nil
        let destination = Self.destination(target.section, target.subpage, anchor: nil)
        pendingScrollRestore = destination.section == target.section && target.scrollOffset > 0 ? target.scrollOffset : nil
        followingLink = true
        if let subpage = destination.subpage { apply(subpage) }
        selection = destination.section
        followingLink = false
    }

    func dismissReturn() {
        returnTarget = nil
    }

    /// The anchor the last flow link asked for, once.
    func takeAnchor() -> String? {
        defer { pendingAnchor = nil }
        return pendingAnchor
    }

    /// Opens a model sub-page without a way back (the subtitle window's settings; the menu's
    /// problem rows use `reveal`). Not a flow link, so a pill from an earlier link goes, even
    /// when 识别与翻译 is already shown. The retained synthesis id opens 我的声音.
    func openModel(_ stage: ModelSettingsStage) {
        reveal(.translation, .model(stage))
    }

    /// Keep the old model/synthesis route usable without bringing back a third card.
    /// Synthesis now belongs to 我的声音; an old section anchor must not scroll that page.
    private static func destination(_ section: SettingsSection, _ subpage: SettingsSubpage?, anchor: String?)
        -> (section: SettingsSection, subpage: SettingsSubpage?, anchor: String?) {
        if section == .translation, subpage == .model(.synthesis) { return (.voice, nil, nil) }
        return (section, subpage, anchor)
    }

    private func subpage(of section: SettingsSection) -> SettingsSubpage? {
        switch section {
        case .translation: .model(modelStage)
        case .components: .components(componentsTab)
        case .privacy: .diagnostics(diagnosticsTab)
        case .general, .meeting, .subtitles, .audio, .voice, .glossary: nil
        }
    }

    private func apply(_ subpage: SettingsSubpage) {
        switch subpage {
        case .model(let stage): modelStage = stage
        case .components(let tab): componentsTab = tab
        case .diagnostics(let tab): diagnosticsTab = tab
        }
    }

    /// The pill names the card the link left: the scene on 使用场景, the sub-page on pages
    /// with cards, otherwise the page.
    private func returnLabel(_ origin: SettingsSection, scenario: MeetingMode?) -> (title: String, symbol: String) {
        if origin == .meeting, let scenario { return (scenario.scene.title, scenario.sceneSymbol) }
        switch subpage(of: origin) {
        case .model(let stage): return (stage.title, stage.symbol)
        case .components(let tab): return (tab.title, tab.symbol)
        case .diagnostics(let tab): return (tab.title, tab.symbol)
        case nil: return (origin.title, origin.symbol)
        }
    }

    init() {
        selection = SettingsSection(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .general
    }
}

/// The page Form's scroll (§2): bound to the navigation's unobserved position, its offset kept
/// for ReturnPill, and back at the top (or the restored position) when the page, sub-page or
/// scene appears. Apply it outside the Form's `.id(subpage)`. The request token is read here,
/// in the caller's body, so a programmatic scroll re-renders the page once and nothing else does.
extension View {
    func settingsPageScroll<Subpage: Hashable>(_ navigation: SettingsNavigation, subpage: Subpage) -> some View {
        modifier(SettingsPageScroll(navigation: navigation, request: navigation.pageScrollRequest, subpage: subpage))
    }
}

private struct SettingsPageScroll<Subpage: Hashable>: ViewModifier {
    let navigation: SettingsNavigation
    /// Unused in the body: a new value makes SwiftUI re-read the position binding.
    let request: Int
    let subpage: Subpage

    func body(content: Content) -> some View {
        content
            .scrollPosition(navigation.pageScrollBinding)
            .onScrollGeometryChange(for: Double.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, offset in
                navigation.pageScrollOffset = offset
            }
            .onAppear { navigation.pageAppeared() }
            .onChange(of: subpage) { _, _ in navigation.pageAppeared() }
    }
}

extension View {
    /// The section a flow link or a menu problem row asked for (§6.3, §8.1): once the page has
    /// laid out, scroll to it and flash it; again when the page is already shown (the request
    /// token changes). `proxy` is the page's ScrollViewReader; the section carries `.id(anchor)`.
    func settingsAnchorTarget(_ navigation: SettingsNavigation, _ proxy: ScrollViewProxy) -> some View {
        modifier(SettingsAnchorTarget(navigation: navigation, request: navigation.anchorRequest, proxy: proxy))
    }
}

private struct SettingsAnchorTarget: ViewModifier {
    let navigation: SettingsNavigation
    let request: Int
    let proxy: ScrollViewProxy

    func body(content: Content) -> some View {
        content
            .onAppear { reveal() }
            .onChange(of: request) { _, _ in reveal() }
    }

    /// After the first layout: the section has to exist before it can be scrolled to.
    private func reveal() {
        DispatchQueue.main.async {
            guard let anchor = navigation.takeAnchor() else { return }
            proxy.scrollTo(anchor, anchor: .top)
            navigation.flow.flash(anchor)
        }
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
    /// 字幕's VoiceOver switch shows only while VoiceOver runs (§7.4).
    let subtitles = SubtitleSettingsModel()
    /// 安装与维护 › TalkTalk Mic and 通用 › 完全卸载… share the guarded maintenance owner.
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

    /// A menu problem row's deep link (§8.5): the page, its sub-page and the section that
    /// scrolls into view and flashes.
    func show(_ section: SettingsSection, _ subpage: SettingsSubpage?, anchor: String?) {
        navigation.reveal(section, subpage, anchor: anchor)
        show()
    }

    func show(_ section: SettingsSection? = nil) {
        if let section {
            // An entry from the menu, HUD or onboarding, not a flow link: no pill back, even when
            // that page is already selected (the selection's own change would not clear it).
            navigation.dismissReturn()
            navigation.selection = section
        }
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
                                driver: driver, glossary: glossary, subtitles: subtitles)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("TalkTalkSettings")
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        // As macOS settings windows: the title names the pane.
        navigation.onSelectionChange = { [weak window] section in window?.title = section.title }
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
        AppUIModels.shared.audio.calibration.reset()
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
    let subtitles: SubtitleSettingsModel

    var body: some View {
        HStack(spacing: 0) {
            // Label rows: the system sizes the glyph to the Sidebar icon size setting and tints it
            // in the selected row.
            List(SettingsSection.allCases, selection: $navigation.selection) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            // The detail container's fixed slots (settings visual system §2, §7.0): Z0 ReturnPill,
            // Z1 the page's card row, Z1b 隐私与诊断's recording banner, then the page itself,
            // whose Form alone scrolls.
            VStack(spacing: 0) {
                if let target = navigation.returnTarget {
                    ReturnPill(target.title, symbol: target.symbol, back: {
                        // 使用场景 and 字幕 share the scene: going back restores the one the link left.
                        if let scenario = target.scenario { state.requestedScenario = scenario }
                        navigation.returnToOrigin()
                    }, dismiss: navigation.dismissReturn)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                }
                SettingsNavigationBand(state: state, navigation: navigation, translation: translation, driver: driver,
                                       subtitles: subtitles)
                if navigation.selection == .privacy {
                    // Z1b: the recording banner, outside the scroll view like the cards.
                    DiagnosticsBanners(model: PrivacySettings.shared, navigation: navigation)
                }
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private var detail: some View {
        switch navigation.selection ?? .general {
        case .voice:
            MyVoiceSettingsView(model: voice, navigation: navigation, driver: driver)
        case .meeting:
            MeetingSettingsView(state: state, navigation: navigation, driver: driver)
        case .subtitles:
            SubtitleSettingsView(state: state, navigation: navigation)
        case .translation:
            ModelSettingsView(state: state, navigation: navigation, translation: translation)
        case .general:
            GeneralSettingsView(model: AppUIModels.shared.general, driver: driver, navigation: navigation,
                                appleCheck: state.appleCheck)
        case .audio:
            AudioSettingsView(model: AppUIModels.shared.audio, state: state, driver: driver, navigation: navigation)
        case .components:
            ComponentsSettingsView(navigation: navigation, engine: AppUIModels.shared.engine, driver: driver)
        case .glossary:
            GlossarySettingsView(model: glossary, translation: translation)
        case .privacy:
            DiagnosticsView(model: PrivacySettings.shared, navigation: navigation, state: state,
                            translation: translation, voice: voice)
        }
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
            problem = String(localized: "这个构建没有 bundle id（直接运行的二进制），翻译设置只在 TalkTalk.app / TalkTalk-Dev.app 里可用。")
        }
    }
}

struct TranslationPageView: View {
    let page: TranslationPage
    @Bindable var state: AppState
    /// The window's flash, for the diagram a menu problem row lands on (§8.1).
    var flash: FlowInteraction? = nil

    var body: some View {
        Group {
            if let model = page.model {
                // The session's start: a switch changed while it runs waits for the next start.
                TranslationSettingsView(model: model, session: state.meetingActive ? state.meetingStartedAt : nil,
                                        languages: TranslationLanguageChips(
                                            speak: LanguageChip(state: state, speak: true, paired: true),
                                            listen: LanguageChip(state: state, speak: false, paired: true),
                                            source: SpeakSourceChip(state: state)),
                                        flash: flash)
            } else if let problem = page.problem {
                // A development binary without a bundle id (§5.2, §7.0): the reason is the help.
                ContentUnavailableView(String(localized: "此构建不可用"),
                                       systemImage: SubtitleTokens.SettingsIcon.unavailable)
                    .help(problem)
            } else {
                StatusGlyph(.busy)
                    .help(String(localized: "正在读取翻译设置"))
                    .accessibilityLabel(String(localized: "正在读取翻译设置"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { page.load() }
    }
}
