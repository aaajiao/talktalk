// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCore
import TalkTalkSession

struct MeetingMicStep: View {
    let model: OnboardingFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepTitle(number: OnboardingStep.meetingMic.number, title: "确认会议麦克风")
            OnboardingCard(title: "在会议应用中完成两步", symbol: "mic") {
                SpeechFlow(steps: [
                    ("1.circle", String(localized: "输入设备选 TalkTalk Mic")),
                    ("2.circle", String(localized: "打开麦克风测试"))
                ])
                SettingsNote("请选择 TalkTalk Mic，不要固定使用实体麦克风。")
                DisclosureGroup(String(localized: "会议输入怎么选")) {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsNote("开启默认输入切换后，也可选“与系统相同／默认”，但这条路径只在会议同传期间核验。")
                        SettingsNote("如果会议应用直接使用实体麦克风，TalkTalk 无法在按键翻译时关闭原声。")
                    }
                    .padding(.top, 6)
                }
            }
            // A neutral heading: the result row carries the state glyph.
            OnboardingCard(title: "当前检查结果", symbol: "magnifyingglass") {
                Label {
                    Text(verbatim: model.meetingMic.text)
                } icon: {
                    checkIcon
                }
                .foregroundStyle(model.meetingMic.color)
                .fixedSize(horizontal: false, vertical: true)
                SettingsNote("打开会议应用的麦克风测试后，这里会自动更新。")
            }
            OnboardingCard(title: "会议里的两个方向", symbol: "arrow.left.arrow.right") {
                Text("听对方").font(.subheadline.weight(.semibold))
                SpeechFlow(steps: [
                    ("person.wave.2", String(localized: "对方说英语／德语")),
                    ("character.bubble", String(localized: "识别与翻译")),
                    ("captions.bubble", String(localized: "原文＋中文字幕"))
                ])
                Divider()
                // The scenario page's two lanes, with the titlebar's own capsules and keycap.
                SpeakingLanes(mode: .meeting, follow: nil, navigation: nil)
            }
        }
        .onAppear { model.beginMeetingMicCheck() }
        .onDisappear { model.endMeetingMicCheck() }
    }

    /// Settings › 音频's status glyph: the physical-mic risk is the titlebar's risk glyph.
    private var checkIcon: some View { model.meetingMic.status.icon }
}

struct TryItStep: View {
    let model: OnboardingFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.videoOnly {
                StepTitle(number: OnboardingStep.tryIt.number, title: "试一次视频字幕")
                listen
            } else {
                StepTitle(number: OnboardingStep.tryIt.number, title: "试一次听与说")
                listen
                speak
            }
        }
        .onDisappear { model.stopActivities() }
    }

    private var listen: some View {
        let demo = model.demo
        return OnboardingCard(title: "听 · 示例音频和双语字幕", symbol: "ear") {
            SpeechFlow(steps: [
                ("play.circle", String(localized: "英语示例")),
                ("character.bubble", String(localized: "识别与翻译")),
                ("captions.bubble", String(localized: "原文＋中文字幕"))
            ])
            SettingsNote("示例会从当前扬声器或耳机播放；原文和中文在字幕面板成对显示。")
            HStack {
                Button { model.endSpeakDemo(); demo.start() } label: {
                    Label("播放示例", systemImage: "play.fill")
                }
                .disabled(demo.phase == .preparing || demo.phase == .playing)
                if demo.phase == .preparing || demo.phase == .playing {
                    ProgressView().controlSize(.small)
                    Button { demo.stop() } label: {
                        Label("停止示例", systemImage: SubtitleTokens.VoiceIcon.stopTranslation).labelStyle(.iconOnly)
                    }
                    .help("停止示例")
                }
            }
            listenStatus
            if !demo.lines.isEmpty {
                Divider()
                Text("示例原文").font(.caption).foregroundStyle(.secondary)
                Text(verbatim: ListenDemo.sample).font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("已收到的中文译文").font(.caption).foregroundStyle(.secondary)
                Text(verbatim: demo.lines.joined(separator: " ")).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup(String(localized: "字幕和备用翻译说明")) {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsNote("云端不可用时由 Apple 翻译，句末显示“备用翻译”标记。")
                    SettingsNote("本页汇总示例原文和已收到的中文译文；逐句配对请看字幕面板。")
                }
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder private var listenStatus: some View {
        switch model.demo.phase {
        case .idle:
            // The enabled "播放示例" already says it has not played.
            EmptyView()
        case .preparing:
            Label("正在准备示例和字幕…", systemImage: "hourglass").foregroundStyle(.secondary)
        case .playing:
            Label("示例播放中，请看字幕面板", systemImage: "waveform").foregroundStyle(Color.accentColor)
        case .done:
            if model.demo.lines.isEmpty {
                Label("示例已结束，但没有收到译文", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                Label("示例已结束，已收到字幕", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var speak: some View {
        OnboardingCard(title: "说 · 点按右⌥试一句", symbol: "mic") {
            Label("先结束通话和其他 App 的麦克风测试，再戴耳机试说。", systemImage: "headphones")
                .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            // The titlebar's keycap starts the flow, as in the scenario page's translation lane.
            HStack(spacing: 8) {
                FlowNodeCard(symbol: nil, title: String(localized: "说中文，可夹英语")) {
                    Keycap(key: TitlebarKey(action: String(localized: "开始翻译"), style: .idle))
                }
                FlowArrow()
                FlowNodeCard(symbol: "character.bubble", title: String(localized: "翻译与语音合成"))
                FlowArrow()
                FlowNodeCard(symbol: SubtitleTokens.SettingsIcon.headphones, title: String(localized: "在耳机里听译音"))
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([String(localized: "点按右⌥开始翻译"), String(localized: "翻译与语音合成"),
                                 String(localized: "在耳机里听译音")].joined(separator: String(localized: "，然后")))
            SettingsNote("点按后说中文，可夹英语；说完再点按右⌥结束发言，等待译音播完。原文和译文在会议窗口的“我的发言”区显示。")
            HStack {
                Button { model.beginSpeakDemo() } label: {
                    Label("开始说话测试", systemImage: "mic.fill")
                }
                .disabled(model.startSpeakDemo == nil || model.speakDemoState == .preparing || model.speakDemoState == .listening || model.speakDemoState == .played)
                if model.speakDemoState == .preparing { ProgressView().controlSize(.small) }
                if model.speakDemoState == .listening || model.speakDemoState == .played || model.speakDemoState == .preparing {
                    Button { model.endSpeakDemo() } label: {
                        Label("停止说话测试", systemImage: SubtitleTokens.VoiceIcon.stopTranslation).labelStyle(.iconOnly)
                    }
                    .help("停止说话测试")
                }
            }
            speakStatus
            DisclosureGroup(String(localized: "正式会议的发言方式")) {
                SettingsNote("这里仅测试翻译。正式会议默认传原声，点按右⌥开始翻译，再点按结束发言；剩余译音播完后恢复原声。")
                    .padding(.top, 6)
            }
        }
    }

    @ViewBuilder private var speakStatus: some View {
        switch model.speakDemoState {
        case .idle:
            if model.startSpeakDemo == nil {
                Label("说话测试暂不可用", systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }
        case .preparing:
            Label("正在准备麦克风和耳机播放…", systemImage: "hourglass").foregroundStyle(.secondary)
        case .listening:
            Label(model.speakDemoStatus ?? String(localized: "已准备好：点按右⌥开始，说完再点按结束，等待译音。"), systemImage: "mic.fill")
                .fixedSize(horizontal: false, vertical: true)
        case .played:
            Label("已播放译文语音", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let reason):
            Label("说话测试没有完成：\(reason)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "你会用 TalkTalk 做什么？" before step 1 (redesign §7): several may be chosen; video alone
/// takes the reduced "准备视频字幕" path.
struct ScenarioChoiceStep: View {
    @Bindable var model: OnboardingFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("你会用 TalkTalk 做什么？").font(.title2.bold())
            SettingsNote("可以多选。只看视频时，引导只准备应用声音、语音识别和语音资源。")
            HStack(spacing: 12) {
                ForEach(OnboardingScenario.allCases, id: \.self) { scenario in
                    let mode = OnboardingFlowModel.mode(scenario)
                    SettingsTabButton(title: mode.scene.title, symbol: mode.sceneSymbol, summary: summary(scenario),
                                      selected: model.selectedScenarios.contains(scenario), multiSelect: true) {
                        model.toggleScenario(scenario)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "使用场景，可多选"))
        }
    }

    private func summary(_ scenario: OnboardingScenario) -> String {
        switch scenario {
        case .meeting: String(localized: "电脑会议 · 双向同传")
        case .phone: String(localized: "自己的号码 · 双向同传")
        case .video: String(localized: "观看视频 · 双语字幕")
        }
    }
}

struct DoneStep: View {
    let model: OnboardingFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("引导完成", systemImage: "flag.checkered").font(.title2.bold())
            OnboardingCard(title: "从菜单开始使用", symbol: "menubar.rectangle") {
                // The menu's own glyphs: the status item, its quick start, the scenario entries.
                SpeechFlow(steps: [
                    (SubtitleTokens.OnboardingIcon.menuBar, String(localized: "点菜单栏图标")),
                    (SubtitleTokens.OnboardingIcon.quickStart, String(localized: "开始上次的场景")),
                    (SubtitleTokens.OnboardingIcon.otherScenes, String(localized: "或选其他场景"))
                ])
            }
            OnboardingCard(title: "开会、打电话与看视频", symbol: SubtitleTokens.OnboardingIcon.otherScenes) {
                scenarioRow(.meeting, note: String(localized: "听对方看双语字幕；会议应用的输入选 TalkTalk Mic。"))
                Divider()
                scenarioRow(.phone,
                            note: String(localized: "固定使用 Mac 的 Phone 和你的 iPhone 号码。先准备同传，再拨号或接听；结束同传后恢复麦克风。"))
                Divider()
                scenarioRow(.captions,
                            note: String(localized: "只收听应用声音，英语或德语原文与中文字幕成对显示，不使用麦克风。"))
            }
            SettingsNote("需要重新检查时，可从 设置 › 通用 重新运行引导。")
        }
    }

    /// A clickable scenario row: opens settings at that scenario. The scene icon and name
    /// identify it, as in the titlebar and settings.
    private func scenarioRow(_ mode: MeetingMode, note: String) -> some View {
        Button {
            model.openScenario?(mode)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: mode.sceneSymbol).font(.headline).foregroundStyle(Color.accentColor)
                    .frame(width: 22).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.scene.title).font(.headline)
                    Text(note).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.openScenario == nil)
        .accessibilityHint(String(localized: "打开设置中的这个场景"))
    }
}
