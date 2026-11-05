import SwiftUI
import TalkTalkCore

/// One place to distinguish speech recognition, translation and speech synthesis.
enum ModelSettingsStage: String, CaseIterable, Identifiable {
    case recognition = "语音识别", translation = "文本翻译", synthesis = "语音合成"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .recognition: "waveform"
        case .translation: "character.bubble"
        case .synthesis: "speaker.wave.2"
        }
    }
    var summary: String {
        switch self {
        case .recognition: "声音 → 原文"
        case .translation: "原文 → 译文"
        case .synthesis: "译文 → 声音"
        }
    }
}

struct ModelSettingsView: View {
    @Bindable var state: AppState
    @Bindable var navigation: SettingsNavigation
    let translation: TranslationPage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            stagePicker
            .padding([.horizontal, .top], 20)

            switch navigation.modelStage {
            case .recognition: recognition
            case .translation: TranslationPageView(page: translation)
            case .synthesis: synthesis
            }
        }
        .onAppear { AppUIModels.shared.engine.reload() }
    }

    /// The diagram and navigation share one control: the whole labeled button selects its
    /// page. Native buttons retain keyboard focus, press feedback and disabled semantics.
    private var stagePicker: some View {
        HStack(spacing: 12) {
            ForEach(ModelSettingsStage.allCases) { stage in
                SettingsTabButton(title: stage.rawValue, symbol: stage.symbol, summary: stage.summary,
                                  selected: navigation.modelStage == stage) {
                    navigation.modelStage = stage
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("模型处理步骤")
    }

    private var recognition: some View {
        Form {
            Section {
                Picker("首选识别引擎", selection: $state.listenASREngine) {
                    Text("Qwen3-ASR（默认）").tag(AppState.ListenASREngine.qwen)
                    Text("Apple Speech").tag(AppState.ListenASREngine.apple)
                }
                LabeledContent("当前运行", value: state.listenASRStatus ?? "尚未开始收听")
            } header: { Text("听对方／看视频 · 应用声音 → 原文") }
            footer: { Text("选择立即生效；Qwen 不可用时由 Apple Speech 接管。") }

            Section {
                LabeledContent("按键翻译的识别引擎", value: "Qwen3-ASR，Apple Speech 备用")
                Text("支持中文夹英语，统一生成选定的英语或德语译音。")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("我说话 · 按住右⌥ → 原文") }

            Section {
                LabeledContent("Qwen3-ASR", value: installedModel(role: "asr"))
                Button("管理本地模型安装") { navigation.openComponents(.engine) }
            } header: { Text("本地识别模型") }
            Section {
                DisclosureGroup("识别与翻译的分工") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("声音在这台 Mac 上转成原文，再交给文本翻译。Qwen3-ASR 不负责翻译或合成声音；Apple Speech 由 macOS 提供。")
                        Text("按键说话的识别与上面的听译选择独立。英文术语和单独的英文片段都会交给翻译，无需手动切换语言；常用中英文名称可加入术语表，帮助识别。")
                    }
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var synthesis: some View {
        Form {
            Section {
                SpeechFlow(steps: [("text.bubble", "英语／德语译文"), ("person.wave.2", "合成译音"), ("waveform", "TalkTalk Mic")], links: [
                    1: .init("声音与试听") { navigation.selection = .voice }
                ])
                Label("会议同传会生成译音；视频字幕只显示文字。", systemImage: "speaker.wave.2")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("译文 → 会议里的声音") }
            Section {
                LabeledContent("Qwen3-TTS 模型", value: installedModel(role: "tts"))
                LabeledContent("声音档案", value: state.voiceProfilePresent ? "已创建" : "尚未创建")
            } header: { Text("我的声音") }
            Section {
                LabeledContent("macOS 系统声音", value: "无需创建声音档案")
                Text("没有声音档案时，译音使用系统声音。")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("系统声音") }
            Section {
                DisclosureGroup("声音档案与恢复说明") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Qwen3-TTS 使用你录制的声音档案生成译音，模型与声音档案需要分别准备。")
                        Text("已有声音档案但克隆引擎暂不可用时，会等待恢复或停止发送该段，不会立即切换为系统声音。")
                    }
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func installedModel(role: String) -> String {
        guard let key = AppUIModels.shared.engine.record?.roles[role]?.id else { return "未安装" }
        return EnginePins.models.first { $0.key == key }?.repo.split(separator: "/").last.map(String.init) ?? key
    }
}
