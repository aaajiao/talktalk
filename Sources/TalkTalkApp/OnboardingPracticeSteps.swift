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
            OnboardingCard(title: "当前检查结果", symbol: "checkmark.shield") {
                Label(model.meetingMic.text, systemImage: checkSymbol)
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
                Text("我说话").font(.subheadline.weight(.semibold))
                SpeechFlow(steps: [
                    ("mic", String(localized: "默认原声／按键翻译")),
                    ("waveform", "TalkTalk Mic"),
                    ("person.2.wave.2", String(localized: "会议里的对方"))
                ])
                SettingsNote("默认传原声；点按右⌥开始翻译，再点按结束发言，译音播完后恢复原声。")
            }
        }
        .onAppear { model.beginMeetingMicCheck() }
        .onDisappear { model.endMeetingMicCheck() }
    }

    private var checkSymbol: String {
        switch model.meetingMic {
        case .green: "checkmark.circle.fill"
        case .physicalMic: "exclamationmark.triangle.fill"
        case .notChecked, .nobodyReads: "circle.dashed"
        }
    }
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
                    Button { demo.stop() } label: { Label("停止", systemImage: "stop.fill") }
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
            Label("尚未播放示例", systemImage: "play.circle").foregroundStyle(.secondary)
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
            SpeechFlow(steps: [
                ("mic", String(localized: "点按右⌥开始翻译")),
                ("character.bubble", String(localized: "翻译与语音合成")),
                ("headphones", String(localized: "在耳机里听译音"))
            ])
            SettingsNote("点按后说中文，可夹英语；说完再点按右⌥结束发言，等待译音播完。原文和译文在会议窗口的“我的发言”区显示。")
            HStack {
                Button { model.beginSpeakDemo() } label: {
                    Label("开始说话测试", systemImage: "mic.fill")
                }
                .disabled(model.startSpeakDemo == nil || model.speakDemoState == .preparing || model.speakDemoState == .listening || model.speakDemoState == .played)
                if model.speakDemoState == .preparing { ProgressView().controlSize(.small) }
                if model.speakDemoState == .listening || model.speakDemoState == .played || model.speakDemoState == .preparing {
                    Button { model.endSpeakDemo() } label: { Label("停止说话测试", systemImage: "stop.fill") }
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
                                      selected: model.selectedScenarios.contains(scenario)) {
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
                SpeechFlow(steps: [
                    ("square.grid.3x1", String(localized: "先选使用场景")),
                    ("app", String(localized: "在场景里选应用与语言")),
                    ("play.circle", String(localized: "开始同传或字幕"))
                ])
            }
            OnboardingCard(title: "开会、打电话与看视频", symbol: SubtitleTokens.SceneIcon.meeting) {
                scenarioRow(.meeting, title: String(localized: "开会：开始会议同传"),
                            note: String(localized: "听对方看双语字幕；我说话默认传原声，点按右⌥开始翻译，再点按结束，译音播完后恢复原声。会议应用的输入选 TalkTalk Mic。"))
                Divider()
                scenarioRow(.phone, title: String(localized: "打电话：准备电话同传"),
                            note: String(localized: "固定使用 Mac 的 Phone 和你的 iPhone 号码。先准备同传，再拨号或接听；结束同传后恢复麦克风。"))
                Divider()
                scenarioRow(.captions, title: String(localized: "看视频：开始视频字幕"),
                            note: String(localized: "只收听应用声音，英语或德语原文与中文字幕成对显示，不使用麦克风。"))
            }
            SettingsNote("需要重新检查时，可从 设置 › 通用 重新运行引导。")
        }
    }

    /// A clickable scenario row: opens settings at that scenario.
    private func scenarioRow(_ mode: MeetingMode, title: String, note: String) -> some View {
        Button {
            model.openScenario?(mode)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: mode.sceneSymbol).font(.headline).foregroundStyle(Color.accentColor)
                    .frame(width: 22).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
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
