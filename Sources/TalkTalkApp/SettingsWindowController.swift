import AppKit
import SwiftUI
import TalkTalkCloudUI

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
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
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
            SubtitleSettingsView(state: state)
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
        Form {
            if state.meetingActive || state.meetingStarting {
                Section {
                    LabeledContent("当前用途", value: state.meetingMode == .captions ? "视频字幕" : "会议同传")
                    if let app = state.meetingApp { LabeledContent("正在收听", value: app) }
                    if state.meetingStarting { ProgressView("正在准备识别与字幕…") }
                    else {
                        Button(state.meetingMode == .captions ? "停止视频字幕" : "停止会议同传") {
                            state.onToggleListening?(state.meetingMode)
                        }
                        .disabled(state.meetingStopping)
                    }
                }
            }
            Section {
                Label("会议同传", systemImage: "person.2.wave.2").font(.headline)
                Text("听对方、看双语字幕；默认传送你的原声，需要翻译时按住右⌥说中文，可夹英语。")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    Text("听对方").font(.subheadline.weight(.semibold))
                    SpeechFlow(steps: [("person.wave.2", "对方说英语／德语"), ("character.bubble", "识别与翻译"), ("captions.bubble", "原文＋中文字幕")], links: [
                        1: .init("模型设置") { navigation.openModel(.recognition) },
                        2: .init("字幕设置") { navigation.selection = .subtitles }
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
                    Text("松开后，等剩余译音播完才自动恢复原声。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("在会议应用里选 TalkTalk Mic；需要静音时，使用会议应用的静音按钮。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("开始会议同传") { state.onToggleListening?(.meeting) }
                    .disabled(state.meetingActive || state.meetingStarting || state.meetingStopping || state.onToggleListening == nil)
            }
            Section {
                Label("视频字幕", systemImage: "play.rectangle").font(.headline)
                Text("观看 YouTube 等视频时，只收听应用声音并生成字幕。")
                    .foregroundStyle(.secondary)
                SpeechFlow(steps: [("play.rectangle", "视频声音"), ("text.bubble", "识别原文"), ("captions.bubble", "中文字幕")], links: [
                    1: .init("识别设置") { navigation.openModel(.recognition) },
                    2: .init("字幕设置") { navigation.selection = .subtitles }
                ])
                Text("不启用按键说话，也不更改系统默认麦克风。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("开始视频字幕") { state.onToggleListening?(.captions) }
                    .disabled(state.meetingActive || state.meetingStarting || state.meetingStopping || state.onToggleListening == nil)
            }
            Section {
                Picker("原文语言", selection: $state.remoteLanguage) {
                    ForEach(AppState.RemoteLanguage.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("字幕翻译为", value: "中文")
                Text("英语或德语原文与中文译文同时显示。切换语言立即生效，也可从菜单直接切换。")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("听译语言") }
            Section {
                Text("在菜单 › 要听的应用中选择声音来自哪里：YouTube 选 Chrome 或 Safari，会议选 Zoom 或 Teams。")
                Text("选择浏览器会包含该浏览器其他标签页的声音。这里选择的是应用播放的声音，与你说话用的麦克风分开。")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("要听的应用") }
        }
        .formStyle(.grouped)
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
