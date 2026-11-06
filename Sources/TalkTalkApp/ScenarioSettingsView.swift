// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import SwiftUI
import TalkTalkAudio
import TalkTalkCore
import TalkTalkSession

/// Settings › 使用场景 (redesign §7). Switching cards scrolls back to the top; scrolling up
/// collapses the cards into a 32 pt segmented control. The bottom bar stays locked to the
/// running scenario (§33) while another one is browsed, and a pinned banner says so.
struct MeetingSettingsView: View {
    @Bindable var state: AppState
    @Bindable var navigation: SettingsNavigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let modes: [MeetingMode] = [.meeting, .phone, .captions]

    private var sessionBusy: Bool { state.meetingActive || state.meetingStarting || state.meetingStopping }

    private var runState: ScenarioRunState {
        ScenarioRunState(running: sessionBusy ? state.meetingMode : nil, browsing: state.requestedScenario)
    }

    var body: some View {
        VStack(spacing: 0) {
            scenarioHeader
            if let banner = runState.banner, let running = runState.running {
                runningBanner(banner.text, returnTitle: banner.returnTitle, running: running)
            }
            Form {
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
            .id(state.requestedScenario)
            .scrollPosition($navigation.sceneScroll)
            .onScrollGeometryChange(for: Double.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, offset in
                navigation.sceneScrollOffset = offset
                let collapsed = navigation.sceneHeaderCollapsed
                let next = ScenarioHeaderCollapse.collapsed(offset: offset, wasCollapsed: collapsed)
                guard next != collapsed else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: SubtitleTokens.Motion.statusBandResize
                    .duration(reduceMotion: false))) { navigation.sceneHeaderCollapsed = next }
            }
            scenarioActionBar
        }
        .onAppear {
            state.onRefreshSources?()
            // Back from a flow link's page: the previous position; otherwise the top.
            if let offset = navigation.takeSceneScrollRestore() {
                DispatchQueue.main.async { navigation.sceneScroll.scrollTo(y: offset) }
            } else {
                navigation.sceneScroll.scrollTo(edge: .top)
                navigation.sceneHeaderCollapsed = false
            }
        }
        .onChange(of: state.requestedScenario) { _, _ in
            state.onRefreshSources?()
            navigation.sceneScroll.scrollTo(edge: .top)
            navigation.sceneHeaderCollapsed = false
        }
    }

    // MARK: header

    @ViewBuilder private var scenarioHeader: some View {
        Group {
            if navigation.sceneHeaderCollapsed {
                Picker(String(localized: "使用场景"), selection: $state.requestedScenario) {
                    ForEach(Self.modes, id: \.self) { mode in
                        Label(mode.scene.title, systemImage: mode.sceneSymbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
                // The 32 pt band is the container's; the control keeps its native height.
                .frame(height: 32)
                .padding(.horizontal, 20).padding(.vertical, 8)
            } else {
                TimelineView(.periodic(from: .now, by: sessionBusy ? 1 : 3600)) { context in
                    HStack(spacing: 12) {
                        ForEach(Self.modes, id: \.self) { mode in
                            let running = state.meetingActive && state.meetingMode == mode
                            SettingsTabButton(title: mode.scene.title, symbol: mode.sceneSymbol, summary: summary(mode),
                                              selected: state.requestedScenario == mode, running: running,
                                              runningSubtitle: running ? ScenarioRunState.cardSubtitle(
                                                elapsed: state.meetingStartedAt.map { context.date.timeIntervalSince($0) }) : nil) {
                                state.requestedScenario = mode
                            }
                        }
                    }
                }
                .padding([.horizontal, .top], 20).padding(.bottom, 12)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "使用场景"))
    }

    private func summary(_ mode: MeetingMode) -> String {
        switch mode {
        case .meeting: String(localized: "电脑会议 · 双向同传")
        case .phone: String(localized: "自己的号码 · 双向同传")
        case .captions: String(localized: "观看视频 · 双语字幕")
        }
    }

    private func runningBanner(_ text: String, returnTitle: String, running: MeetingMode) -> some View {
        HStack(spacing: 10) {
            Image(systemName: running.sceneSymbol).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(returnTitle) { state.requestedScenario = running }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
        .accessibilityElement(children: .contain)
    }

    // MARK: scenarios

    private var meetingScenario: some View {
        Section {
            HStack {
                Label("会议同传", systemImage: SubtitleTokens.SceneIcon.meeting).font(.headline)
                Spacer()
                InfoButton(topic: String(localized: "会议同传"), lines: [
                    String(localized: "在会议应用里选 TalkTalk Mic；需要静音时，使用会议应用的静音按钮。"),
                    String(localized: "点按右⌥开始翻译，说中文，可夹英语；再点按结束，译音播完后回到原声。")
                ])
            }
            Text("听对方、看双语字幕；点按右⌥把中文译给对方").foregroundStyle(.secondary)
            sourceSelection(for: .meeting)
            VStack(alignment: .leading, spacing: 12) {
                Text("听对方").font(.subheadline.weight(.semibold))
                SpeechFlow(steps: [(SubtitleTokens.SettingsIcon.remote, String(localized: "对方说英语／德语")),
                                   ("character.bubble", String(localized: "识别与翻译")),
                                   ("captions.bubble", String(localized: "原文＋中文字幕"))], links: [
                    1: FlowLink(String(localized: "模型设置")) { follow { navigation.openModel(.recognition) } },
                    2: FlowLink(String(localized: "字幕设置")) { follow { openSubtitles(.meeting) } }
                ])
                Divider()
                SpeakingLanes(mode: .meeting, follow: follow, navigation: navigation)
            }
        }
    }

    private var videoScenario: some View {
        Section {
            HStack {
                Label("视频字幕", systemImage: SubtitleTokens.SceneIcon.video).font(.headline)
                Spacer()
                InfoButton(topic: String(localized: "视频字幕"), lines: [String(localized: "不启用按键说话，也不更改系统默认麦克风。")])
            }
            Text("看视频时只收听应用声音，显示双语字幕").foregroundStyle(.secondary)
            sourceSelection(for: .captions)
            SpeechFlow(steps: [(SubtitleTokens.SceneIcon.video, String(localized: "视频声音")),
                               ("text.bubble", String(localized: "识别原文")),
                               ("captions.bubble", String(localized: "中文字幕"))], links: [
                1: FlowLink(String(localized: "识别设置")) { follow { navigation.openModel(.recognition) } },
                2: FlowLink(String(localized: "字幕设置")) { follow { openSubtitles(.video) } }
            ])
        }
    }

    private var languageSettings: some View {
        Section {
            Picker("原文语言", selection: $state.remoteLanguage) {
                ForEach(AppState.RemoteLanguage.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("字幕翻译为", value: String(localized: "中文"))
        } header: {
            HStack {
                Text("听译语言")
                InfoButton(topic: String(localized: "听译语言"), lines: [String(localized: "英语或德语原文与中文译文同时显示。切换语言立即生效，也可从菜单直接切换。")])
            }
        }
    }

    private func follow(_ open: @escaping () -> Void) {
        navigation.follow(from: state.requestedScenario, open)
    }

    private func openSubtitles(_ presentation: SubtitlePanel.Presentation) {
        navigation.subtitlePresentation = presentation
        navigation.selection = .subtitles
    }

    // MARK: source

    private var sourceChangesLocked: Bool { sessionBusy }

    private func sourceBinding(for mode: MeetingMode) -> Binding<String> {
        Binding(get: {
            mode == .meeting ? state.meetingSourceID : state.videoSourceID
        }, set: { id in
            guard !sourceChangesLocked else { return }
            if mode == .meeting { state.meetingSourceID = id } else { state.videoSourceID = id }
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
                Label("刷新", systemImage: SubtitleTokens.SettingsIcon.refresh).labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("刷新应用列表")
            .accessibilityLabel(String(localized: "刷新应用列表"))
            .disabled(state.onRefreshSources == nil)
            InfoButton(topic: String(localized: "声音来源"), lines: [
                mode == .meeting
                    ? String(localized: "自动选择正在使用麦克风的会议应用；有多个候选时会请你选择。")
                    : String(localized: "自动选择正在播放声音的应用；有多个候选时会请你选择。"),
                String(localized: "这里只选择本场景要听的应用声音，与你说话用的麦克风分开。")
            ])
        }
        if sourceChangesLocked {
            Text("来源在本次会话中保持不变。请先结束当前同传或视频字幕，再更换应用。")
                .font(.callout).foregroundStyle(.secondary)
        } else if missing {
            SettingsStatusLabel(String(localized: "请先打开 \(selectedName)，或重新选择应用；不会自动改用其他声音来源。"), .warn)
                .font(.callout)
        }
        if ScenarioSourceNote.showsBrowserNote(selectedID: selectedID) {
            Label("选择浏览器会包含它的其他标签页。", systemImage: "rectangle.on.rectangle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: action bar

    private func modeTitle(_ mode: MeetingMode) -> String { mode.scene.title }

    /// Browsing another scene during a session keeps the action attached to the running one.
    private var actionMode: MeetingMode {
        sourceChangesLocked ? state.meetingMode : state.requestedScenario
    }

    private var stopTitle: String {
        switch state.meetingMode {
        case .meeting: String(localized: "停止会议同传")
        case .phone: String(localized: "结束电话同传")
        case .captions: String(localized: "停止视频字幕")
        }
    }

    private var actionTitle: String {
        if state.meetingStopping { return String(localized: "正在结束\(modeTitle(state.meetingMode))…") }
        if state.meetingStarting { return String(localized: "正在准备\(modeTitle(state.meetingMode))…") }
        if state.meetingActive { return stopTitle }
        switch actionMode {
        case .meeting: return String(localized: "开始会议同传")
        case .phone: return String(localized: "准备电话同传")
        case .captions: return String(localized: "开始视频字幕")
        }
    }

    /// The action, not the scene (the card and title already name it): as the menu's quick start.
    private var actionSymbol: String {
        state.meetingActive ? "stop.fill" : MenuQuickStart.symbol
    }

    /// The running session's voice state, as the menu's dot: green only while the other party
    /// hears the original voice. Video listens only (neutral).
    private var runningVoice: VoiceState? {
        switch state.meetingMode {
        case .meeting: state.meetingVoice
        case .phone: state.phoneVoice
        case .captions: VoiceState.resolve(audio: nil, scene: .video)
        }
    }

    private var actionDescription: String? {
        if state.meetingStopping {
            return actionMode.supportsSpeaking
                ? String(localized: "正在结束翻译并还原麦克风。")
                : String(localized: "正在停止字幕与声音采集。")
        }
        if state.meetingStarting { return String(localized: "正在准备识别、翻译与音频，请稍候。") }
        if state.meetingActive {
            return state.meetingMode == .phone ? String(localized: "结束同传会还原麦克风；挂断请使用 Phone。") : nil
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
                    if state.meetingActive, !state.meetingStopping,
                       let line = runState.runningLine(source: state.meetingApp) {
                        let voice = runningVoice
                        HStack(spacing: 6) {
                            if let voice {
                                Circle().fill(Color(nsColor: SubtitleStyle.toneColor(voice.appearance.tone)))
                                    .frame(width: 8, height: 8)
                                    .accessibilityHidden(true)
                            }
                            Text(line).font(.callout.weight(.semibold))
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(voice?.accessibilityLabel ?? "")
                    } else {
                        Text(modeTitle(actionMode)).font(.callout.weight(.semibold))
                    }
                    if let actionDescription {
                        Text(actionDescription).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !state.subtitlesVisible { subtitlesHiddenTag }
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
                .tint(state.meetingActive ? Color.red : Color.accentColor)
                .controlSize(.large)
                .disabled(state.meetingStarting || state.meetingStopping || state.onToggleListening == nil
                          || (!state.meetingActive && !state.meetingAvailable))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The global subtitle switch is off (§7): an orange tag with a one-click way back.
    private var subtitlesHiddenTag: some View {
        HStack(spacing: 6) {
            Label("字幕已隐藏", systemImage: "eye.slash").foregroundStyle(.orange)
            Button("显示") { state.subtitlesVisible = true }.buttonStyle(.link)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.orange.opacity(0.12)))
    }
}

extension MeetingMode {
    /// The subtitle settings tab of this scenario.
    var subtitlePresentation: SubtitlePanel.Presentation {
        switch self {
        case .meeting: .meeting
        case .phone: .phone
        case .captions: .video
        }
    }
}
