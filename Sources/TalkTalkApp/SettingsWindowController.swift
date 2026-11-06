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
    var selection: SettingsSection? {
        didSet {
            UserDefaults.standard.set(selection?.rawValue, forKey: Self.key)
            onSelectionChange?(selection ?? .general)
        }
    }
    @ObservationIgnored var onSelectionChange: ((SettingsSection) -> Void)?

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
            detail
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

struct MeetingSettingsView: View {
    @Bindable var state: AppState
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                SettingsTabButton(title: String(localized: "会议同传"), symbol: SubtitleTokens.SceneIcon.meeting,
                                  summary: String(localized: "电脑会议 · 双向同传"), selected: state.requestedScenario == .meeting) {
                    state.requestedScenario = .meeting
                }
                SettingsTabButton(title: String(localized: "电话同传"), symbol: SubtitleTokens.SceneIcon.phone,
                                  summary: String(localized: "自己的号码 · 双向同传"), selected: state.requestedScenario == .phone) {
                    state.requestedScenario = .phone
                }
                SettingsTabButton(title: String(localized: "视频字幕"), symbol: SubtitleTokens.SceneIcon.video,
                                  summary: String(localized: "观看视频 · 双语字幕"), selected: state.requestedScenario == .captions) {
                    state.requestedScenario = .captions
                }
            }
            .padding([.horizontal, .top], 20)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "使用场景"))

            Form {
                if state.meetingActive || state.meetingStarting || state.meetingStopping {
                    Section {
                        LabeledContent("当前用途", value: currentModeTitle)
                        if let app = state.meetingApp { LabeledContent("正在收听", value: app) }
                        if state.meetingMode == .phone, let status = state.phoneStatus {
                            Text(status).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                switch state.requestedScenario {
                case .meeting:
                    meetingScenario
                    languageSettings
                case .phone:
                    PhoneSettingsView(state: state, navigation: navigation)
                case .captions:
                    videoScenario
                    languageSettings
                }
            }
            .formStyle(.grouped)
            scenarioActionBar
        }
        .onAppear { state.onRefreshSources?() }
        .onChange(of: state.requestedScenario) { _, _ in state.onRefreshSources?() }
    }

    private var currentModeTitle: String {
        modeTitle(state.meetingMode)
    }

    private func modeTitle(_ mode: MeetingMode) -> String {
        switch mode {
        case .meeting: String(localized: "会议同传")
        case .phone: String(localized: "电话同传")
        case .captions: String(localized: "视频字幕")
        }
    }

    private var stopTitle: String {
        switch state.meetingMode {
        case .meeting: String(localized: "停止会议同传")
        case .phone: String(localized: "结束电话同传")
        case .captions: String(localized: "停止视频字幕")
        }
    }

    /// The primary action stays visible while the scenario explanation and settings scroll.
    /// Browsing another scene during a session keeps the action attached to the running one.
    private var actionMode: MeetingMode {
        sourceChangesLocked ? state.meetingMode : state.requestedScenario
    }

    private var actionTitle: String {
        if state.meetingStopping { return String(localized: "正在结束\(currentModeTitle)…") }
        if state.meetingStarting { return String(localized: "正在准备\(currentModeTitle)…") }
        if state.meetingActive { return stopTitle }
        switch actionMode {
        case .meeting: return String(localized: "开始会议同传")
        case .phone: return String(localized: "准备电话同传")
        case .captions: return String(localized: "开始视频字幕")
        }
    }

    private var actionSymbol: String {
        if state.meetingActive { return "stop.fill" }
        switch actionMode {
        case .meeting: return "person.2.wave.2"
        case .phone: return "phone.fill"
        case .captions: return "captions.bubble"
        }
    }

    private var actionDescription: String {
        if state.meetingStopping {
            return actionMode.supportsSpeaking
                ? String(localized: "正在结束翻译并还原麦克风。")
                : String(localized: "正在停止字幕与声音采集。")
        }
        if state.meetingStarting { return String(localized: "正在准备识别、翻译与音频，请稍候。") }
        if state.meetingActive {
            if state.requestedScenario != state.meetingMode {
                return String(localized: "先结束当前场景，再开启其他场景。")
            }
            return state.meetingMode == .phone
                ? String(localized: "结束同传会还原麦克风；挂断请使用 Phone。")
                : String(localized: "当前场景正在运行，可随时在这里结束。")
        }
        switch actionMode {
        case .meeting: return String(localized: "按本场景的应用与语言设置开始双向同传。")
        case .phone: return String(localized: "先准备同传，再到 Phone 拨号或接听。")
        case .captions: return String(localized: "收听所选应用并显示字幕，不启用麦克风。")
        }
    }

    private var scenarioActionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(modeTitle(actionMode)).font(.callout.weight(.semibold))
                    Text(actionDescription).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    state.onToggleListening?(actionMode)
                } label: {
                    HStack(spacing: 8) {
                        if state.meetingStarting || state.meetingStopping {
                            ProgressView().controlSize(.small)
                            Text(actionTitle)
                        } else {
                            Label(actionTitle, systemImage: actionSymbol)
                        }
                    }
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 180, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .controlSize(.large)
                .disabled(state.meetingStarting || state.meetingStopping || state.onToggleListening == nil
                          || (!state.meetingActive && !state.meetingAvailable))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var meetingScenario: some View {
        Section {
            Label("会议同传", systemImage: "person.2.wave.2").font(.headline)
            Text("听对方、看双语字幕；默认传送你的原声。点按右⌥开始翻译，说中文，可夹英语。")
                .foregroundStyle(.secondary)
            sourceSelection(for: .meeting)
            VStack(alignment: .leading, spacing: 12) {
                Text("听对方").font(.subheadline.weight(.semibold))
                SpeechFlow(steps: [("person.wave.2", "对方说英语／德语"), ("character.bubble", "识别与翻译"), ("captions.bubble", "原文＋中文字幕")], links: [
                    1: .init("模型设置") { navigation.openModel(.recognition) },
                    2: .init("字幕设置") {
                        navigation.subtitlePresentation = .meeting
                        navigation.selection = .subtitles
                    }
                ])
                Divider()
                Text("我说话").font(.subheadline.weight(.semibold))
                Text("默认：你的原声 → TalkTalk Mic → 对方")
                    .font(.callout).foregroundStyle(.secondary)
                SpeechFlow(steps: [("mic", "中文，可夹英语"), ("character.bubble", "关闭原声并翻译"), ("speaker.wave.2", "对方听英语／德语")], links: [
                    0: .init("麦克风设置") { navigation.selection = .audio },
                    1: .init("翻译设置") { navigation.openModel(.translation) },
                    2: .init("声音与试听") { navigation.selection = .voice }
                ])
                Text("说完再点按右⌥结束发言，等剩余译音播完后自动恢复原声。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("在会议应用里选 TalkTalk Mic；需要静音时，使用会议应用的静音按钮。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var videoScenario: some View {
        Section {
            Label("视频字幕", systemImage: "play.rectangle").font(.headline)
            Text("观看 YouTube 等视频时，只收听应用声音并生成字幕。")
                .foregroundStyle(.secondary)
            sourceSelection(for: .captions)
            SpeechFlow(steps: [("play.rectangle", "视频声音"), ("text.bubble", "识别原文"), ("captions.bubble", "中文字幕")], links: [
                1: .init("识别设置") { navigation.openModel(.recognition) },
                2: .init("字幕设置") {
                    navigation.subtitlePresentation = .video
                    navigation.selection = .subtitles
                }
            ])
            Text("不启用按键说话，也不更改系统默认麦克风。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var languageSettings: some View {
        Section {
            Picker("原文语言", selection: $state.remoteLanguage) {
                ForEach(AppState.RemoteLanguage.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("字幕翻译为", value: "中文")
            Text("英语或德语原文与中文译文同时显示。切换语言立即生效，也可从菜单直接切换。")
                .font(.callout).foregroundStyle(.secondary)
        } header: { Text("听译语言") }
    }

    private var sourceChangesLocked: Bool {
        state.meetingActive || state.meetingStarting || state.meetingStopping
    }

    private func sourceBinding(for mode: MeetingMode) -> Binding<String> {
        Binding(get: {
            mode == .meeting ? state.meetingSourceID : state.videoSourceID
        }, set: { id in
            guard !sourceChangesLocked else { return }
            if mode == .meeting { state.meetingSourceID = id }
            else { state.videoSourceID = id }
        })
    }

    @ViewBuilder private func sourceSelection(for mode: MeetingMode) -> some View {
        let source = sourceBinding(for: mode)
        let selectedID = source.wrappedValue
        let choices = state.availableSources
        let missing = !selectedID.isEmpty && !choices.contains { $0.id == selectedID }
        let selectedName = MeetingApp.named(selectedID)?.name ?? selectedID
        HStack {
            Picker(mode == .meeting ? String(localized: "会议应用") : String(localized: "视频声音来源"), selection: source) {
                Text("自动选择").tag("")
                if missing {
                    Text("\(selectedName)（未就绪）").tag(selectedID)
                }
                ForEach(choices, id: \.id) { option in
                    Text(verbatim: option.name).tag(option.id)
                }
            }
            .disabled(sourceChangesLocked)
            Button { state.onRefreshSources?() } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(state.onRefreshSources == nil)
        }
        if sourceChangesLocked {
            Text("来源在本次会话中保持不变。请先结束当前同传或视频字幕，再更换应用。")
                .font(.callout).foregroundStyle(.secondary)
        } else if missing {
            Label("请先打开 \(selectedName)，或重新选择应用；不会自动改用其他声音来源。", systemImage: "exclamationmark.circle")
                .font(.callout).foregroundStyle(.orange)
        } else if selectedID.isEmpty {
            Text(mode == .meeting
                 ? String(localized: "自动选择正在使用麦克风的会议应用；有多个候选时会请你选择。")
                 : String(localized: "自动选择正在播放声音的应用；有多个候选时会请你选择。"))
                .font(.callout).foregroundStyle(.secondary)
        }
        Text("这里只选择本场景要听的应用声音，与你说话用的麦克风分开。选择浏览器会包含它的其他标签页。")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// A short, accessible diagram made from system symbols rather than decorative artwork.
struct SpeechFlow: View {
    struct Link {
        let title: String
        let action: () -> Void
        init(_ title: String, action: @escaping () -> Void) {
            self.title = title; self.action = action
        }
    }
    let steps: [(symbol: String, title: String)]
    var links: [Int: Link] = [:]
    var body: some View {
        HStack(spacing: 12) {
            ForEach(steps.indices, id: \.self) { index in
                if index > 0 { Image(systemName: "arrow.right").foregroundStyle(.tertiary).accessibilityHidden(true) }
                if let link = links[index] {
                    Button(action: link.action) { node(index, link: link) }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("\(steps[index].title)，\(link.title)")
                } else {
                    node(index, link: nil)
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: links.isEmpty ? .ignore : .contain)
        .accessibilityLabel(links.isEmpty ? steps.map(\.title).joined(separator: "，然后") : "声音处理流程")
    }

    private func node(_ index: Int, link: Link?) -> some View {
        VStack(spacing: 6) {
            Image(systemName: steps[index].symbol).font(.title2)
                .foregroundStyle(link == nil ? Color.secondary : Color.accentColor).accessibilityHidden(true)
            Text(steps[index].title).font(.callout).multilineTextAlignment(.center)
            if let link {
                HStack(spacing: 3) {
                    Text(link.title)
                    Image(systemName: "chevron.right").accessibilityHidden(true)
                }
                .font(.caption).foregroundStyle(Color.accentColor)
            }
        }
        .frame(maxWidth: .infinity, minHeight: links.isEmpty ? 0 : 72)
        .contentShape(Rectangle())
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
