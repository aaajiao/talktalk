// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCore
import TalkTalkSettingsUI

/// One place to distinguish speech recognition, translation and speech synthesis.
enum ModelSettingsStage: String, CaseIterable, Identifiable {
    case recognition, translation, synthesis
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recognition: String(localized: "语音识别")
        case .translation: String(localized: "文本翻译")
        case .synthesis: String(localized: "语音合成")
        }
    }
    var symbol: String {
        switch self {
        case .recognition: SubtitleTokens.SettingsIcon.recognition
        case .translation: "character.bubble"
        case .synthesis: "speaker.wave.2"
        }
    }
    var summary: String {
        switch self {
        case .recognition: String(localized: "声音 → 原文")
        case .translation: String(localized: "原文 → 译文")
        case .synthesis: String(localized: "译文 → 声音")
        }
    }
}

struct ModelSettingsView: View {
    @Bindable var state: AppState
    @Bindable var navigation: SettingsNavigation
    let translation: TranslationPage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSubpagePicker(label: String(localized: "模型处理步骤"), selection: $navigation.modelStage,
                                  pages: ModelSettingsStage.allCases, title: \.title, symbol: \.symbol,
                                  summary: \.summary)
                .padding([.horizontal, .top], 20)

            switch navigation.modelStage {
            case .recognition: recognition
            case .translation: TranslationPageView(page: translation)
            case .synthesis: synthesis
            }
        }
        .onAppear { AppUIModels.shared.engine.reload() }
    }

    private var recognition: some View {
        Form {
            Section {
                Picker("首选识别引擎", selection: $state.listenASREngine) {
                    Text("Qwen3-ASR（默认）").tag(AppState.ListenASREngine.qwen)
                    Text("Apple Speech").tag(AppState.ListenASREngine.apple)
                }
                LabeledContent("当前运行", value: state.listenASRStatus ?? String(localized: "尚未开始收听"))
            } header: { Text("听对方／看视频 · 应用声音 → 原文") }
            footer: { Text("选择立即生效；Qwen 不可用时由 Apple Speech 接管。") }

            Section {
                LabeledContent("按键翻译的识别引擎", value: String(localized: "Qwen3-ASR，Apple Speech 备用"))
            } header: { Text("我说话 · 按键翻译") }

            Section {
                LabeledContent("Qwen3-ASR", value: installedModel(role: "asr"))
                Button("管理本地模型安装") { navigation.openComponents(.engine) }
            } header: {
                HStack {
                    Text("本地识别模型")
                    InfoButton(topic: String(localized: "本地识别"), lines: [
                        String(localized: "声音在这台 Mac 上转成原文，再交给文本翻译。"),
                        String(localized: "常用中英文名称可加入术语表，帮助识别。")
                    ])
                }
            }
        }
        .formStyle(.grouped)
    }

    private var synthesis: some View {
        Form {
            Section {
                SpeechFlow(steps: [("character.bubble", String(localized: "英语／德语译文")),
                                   (SubtitleTokens.SettingsIcon.myVoice, String(localized: "合成译音")),
                                   (SubtitleTokens.SettingsIcon.talkTalkMic, "TalkTalk Mic")], links: [
                    1: .init(String(localized: "声音与试听")) { navigation.selection = .voice }
                ])
                Label("会议同传会生成译音；视频字幕只显示文字。", systemImage: "speaker.wave.2")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("译文 → 会议里的声音") }
            Section {
                LabeledContent("Qwen3-TTS 模型", value: installedModel(role: "tts"))
                LabeledContent("声音档案", value: state.voiceProfilePresent ? String(localized: "已创建") : String(localized: "尚未创建"))
            } header: {
                HStack {
                    Text("我的声音")
                    InfoButton(topic: String(localized: "我的声音"), lines: [
                        String(localized: "Qwen3-TTS 使用你录制的声音档案生成译音，模型与声音档案需要分别准备。"),
                        String(localized: "已有声音档案但克隆引擎暂不可用时，会等待恢复或停止发送该段，不会立即切换为系统声音。")
                    ])
                }
            }
            Section {
                LabeledContent("macOS 系统声音", value: String(localized: "没有声音档案时使用"))
            } header: { Text("系统声音") }
        }
        .formStyle(.grouped)
    }

    private func installedModel(role: String) -> String {
        guard let key = AppUIModels.shared.engine.record?.roles[role]?.id else { return String(localized: "未安装") }
        return EnginePins.models.first { $0.key == key }?.repo.split(separator: "/").last.map(String.init) ?? key
    }
}

/// Switching among a pane's two or three sub-pages: a native segmented control (HIG), with the
/// selected page's summary as a caption under it and every page's summary as its help.
struct SettingsSubpagePicker<Page: Hashable & Identifiable>: View {
    let label: String
    @Binding var selection: Page
    let pages: [Page]
    let title: KeyPath<Page, String>
    let symbol: KeyPath<Page, String>
    let summary: KeyPath<Page, String>

    var body: some View {
        VStack(spacing: 6) {
            Picker(label, selection: $selection) {
                ForEach(pages) { page in
                    Label(page[keyPath: title], systemImage: page[keyPath: symbol])
                        .help(page[keyPath: summary])
                        .tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(label)
            Text(verbatim: selection[keyPath: summary]).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
