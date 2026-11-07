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
        case .translation: SubtitleTokens.SettingsIcon.translation
        case .synthesis: SubtitleTokens.SettingsIcon.speech
        }
    }
    /// The card's help and VoiceOver hint (settings visual system §3.1); the arrows between the
    /// cards draw the same steps.
    var summary: String {
        switch self {
        case .recognition: String(localized: "声音 → 原文")
        case .translation: String(localized: "原文 → 译文")
        case .synthesis: String(localized: "译文 → 声音")
        }
    }
}

/// Settings › 模型 (settings visual system §7.8–§7.10). The stage cards sit in the window's fixed
/// band (SettingsNavigationBand); each stage is its own Form and starts at the top. 语音识别 and
/// 语音合成 are a diagram, its problem line and one fact row, with no sections: the node badges
/// and links say what the removed rows said. 文本翻译 is TalkTalkCloudUI's page.
struct ModelSettingsView: View {
    @Bindable var state: AppState
    @Bindable var navigation: SettingsNavigation
    let translation: TranslationPage
    let driver: DriverComponentsPage
    var engine: EngineComponentsModel = AppUIModels.shared.engine

    private typealias Icon = SubtitleTokens.SettingsIcon

    var body: some View {
        VStack(spacing: 0) {
            switch navigation.modelStage {
            case .recognition: recognition
            case .translation: TranslationPageView(page: translation, state: state)
            case .synthesis: synthesis
            }
        }
        .settingsPageScroll(navigation, subpage: navigation.modelStage)
        .onAppear {
            engine.reload()
            // The 文本翻译 card's badge reads the model (only whether the key item exists).
            translation.load()
            // The TalkTalk Mic node's badge reads the driver, as on the scene pages.
            driver.load()
        }
    }

    /// A node link: ReturnPill on the target page leads back to this stage.
    private var links: ScenarioLinks {
        ScenarioLinks { section, subpage, anchor in navigation.open(section, subpage, anchor: anchor) }
    }

    private var recognition: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    FlowGrid.recognition(state, engine: engine, links: links)
                    if let problem = engine.recognitionProblem(state) {
                        StatusLabel(problem.text, problem.status, help: problem.help)
                    }
                    FactRow([FactChip(String(localized: "本机识别"), symbol: Icon.thisMac,
                                      help: String(localized: "声音在这台 Mac 上转成原文"))])
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }

    private var synthesis: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    FlowGrid.synthesis(state, engine: engine, driver: driver, links: links)
                    if let problem = engine.synthesisProblem {
                        StatusLabel(problem.text, problem.status, help: problem.help)
                    }
                    // Whether the other party hears a voice at all (§0.2 #10): icon + shortest words.
                    FactRow([
                        FactChip(String(localized: "会议·电话生成译音"), symbol: SubtitleTokens.SceneIcon.meeting,
                                 help: String(localized: "对方听到译音")),
                        FactChip(String(localized: "视频不生成"), symbol: Icon.noSpeech,
                                 help: String(localized: "视频字幕只显示文字"))
                    ], info: InfoButton(topic: String(localized: "合成译音"), lines: [
                        String(localized: "已有声音档案但克隆引擎暂不可用时，会等待恢复或不发送该段（未发送），不会改用系统声音。")
                    ]))
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }
}

/// The 语音识别 and 语音合成 diagrams (§7.8, §7.10).
@MainActor
extension FlowGrid {
    /// 听对方: 应用声音 → 识别 ‹Qwen3-ASR ▾› (备用 Apple) → 原文; 我说话: 说中文 (右⌥) → 识别
    /// (Qwen3-ASR, 术语表 ›) → 原文.
    static func recognition(_ state: AppState, engine: EngineComponentsModel, links: ScenarioLinks) -> FlowGrid {
        typealias Icon = SubtitleTokens.SettingsIcon
        let problem = engine.recognitionProblem(state)
        let missing = engine.record?.roles["asr"] == nil
        let qwen = state.listenASREngine == .qwen
        let fellBack = state.meetingActive && state.listenASRFallback
        let manage = missing ? links.node(String(localized: "组件 · 引擎与模型"), .components, .components(.engine)) : nil
        let model = engine.modelName(role: "asr")
        let translating = VoiceState.resolve(audio: .translating, scene: .meeting, phoneInputConfirmed: true)
        let listen = FlowNode(String(localized: "识别"), glyph: .symbol(Icon.recognition),
                              badge: problem?.status, badgeReason: problem?.text, link: manage,
                              accessory: .controls { ListenASRChip(state: state) },
                              // Apple stands by for Qwen; solid once it took over.
                              satellite: qwen ? FlowSatellite(String(localized: "备用 Apple"), symbol: Icon.thisMac,
                                                              help: fellBack ? String(localized: "Apple Speech 已接管")
                                                                             : String(localized: "Qwen 不可用时接管"),
                                                              dashed: !fellBack) : nil,
                              help: qwen ? model : nil)
        let speak = FlowNode(String(localized: "识别"), glyph: .symbol(Icon.recognition),
                             badge: missing ? .pending : nil,
                             badgeReason: missing ? String(localized: "识别模型未安装") : nil,
                             link: manage,
                             accessory: .display {
                                 Text(verbatim: "Qwen3-ASR").font(.caption2).foregroundStyle(.secondary)
                             },
                             satellite: FlowSatellite(String(localized: "术语表"), symbol: Icon.glossary,
                                                      help: String(localized: "常用中英文名称帮助识别"),
                                                      link: links.node(String(localized: "术语表"), .glossary)),
                             help: [model, String(localized: "Apple Speech 备用")].compactMap { $0 }.joined(separator: " · "))
        let source = FlowNode(String(localized: "原文"), glyph: .symbol(Icon.sourceText))
        return FlowGrid(String(localized: "语音识别路径"), lanes: [
            FlowLane(String(localized: "听对方"), gutter: .symbol(Icon.listen), cells: [
                .node(FlowNode(String(localized: "应用声音"), glyph: .symbol(Icon.remote))), .node(listen), .node(source), .empty
            ]),
            FlowLane(String(localized: "我说话 · 译音"), gutter: .voice(translating), cells: [
                .node(FlowNode(String(localized: "说中文"), glyph: .symbol(Icon.me), accessory: .display {
                    Keycap(key: TitlebarKey(action: String(localized: "开始翻译"), style: .idle))
                }, help: String(localized: "可夹英语"))),
                .node(speak), .node(source), .empty
            ])
        ])
    }

    /// 译音: EN/DE 译文 → 合成译音 (我的声音 › or 系统声音) → TalkTalk Mic › → 对方听到译音.
    static func synthesis(_ state: AppState, engine: EngineComponentsModel, driver: DriverComponentsPage,
                          links: ScenarioLinks) -> FlowGrid {
        typealias Icon = SubtitleTokens.SettingsIcon
        let problem = engine.synthesisProblem
        let driverProblem = driver.driverProblem
        let translating = VoiceState.resolve(audio: .translating, scene: .meeting, phoneInputConfirmed: true)
        let voice = links.node(String(localized: "我的声音"), .voice)
        // One satellite: the profile in use, else the system voice, dashed as on the scene and
        // 我的声音 pages (§3.3: one shape per meaning); it leads to 我的声音 to record one.
        let satellite = state.voiceProfilePresent
            ? FlowSatellite(String(localized: "我的声音"), symbol: Icon.myVoice, help: String(localized: "用我的声音合成译音"),
                            link: voice)
            : FlowSatellite(String(localized: "系统声音"), symbol: Icon.speech, help: String(localized: "未录制时用系统声音"),
                            dashed: true, link: voice)
        let speech = FlowNode(String(localized: "合成译音"), glyph: .symbol(Icon.speech),
                              badge: problem?.status, badgeReason: problem?.text,
                              link: problem == nil ? nil
                                  : links.node(String(localized: "组件 · 引擎与模型"), .components, .components(.engine)),
                              satellite: satellite, help: engine.modelName(role: "tts"))
        return FlowGrid(String(localized: "语音合成路径"), lanes: [
            FlowLane(String(localized: "译音"), gutter: .voice(translating), cells: [
                .node(FlowNode(String(localized: "EN/DE 译文"), glyph: .symbol(Icon.translation))),
                .node(speech),
                .node(FlowNode("TalkTalk Mic", glyph: .symbol(Icon.talkTalkMic), badge: driverProblem?.status,
                               badgeReason: driverProblem?.text,
                               link: links.node(String(localized: "组件 · 虚拟麦克风"), .components, .components(.driver)))),
                .node(FlowNode(String(localized: "对方听到译音"), glyph: .symbol(Icon.remote)))
            ])
        ])
    }
}

/// 识别引擎 (§3.4, §7.8): Qwen3-ASR or Apple Speech, in effect at once (a running session
/// rebuilds its recognition).
private struct ListenASRChip: View {
    @Bindable var state: AppState

    var body: some View {
        let qwen = state.listenASREngine == .qwen
        let title = qwen ? "Qwen3-ASR" : "Apple Speech"
        NodeChip(title, accessibilityLabel: String(localized: "识别引擎"), help: String(localized: "\(title) · 立即生效"),
                 items: [
                     NodeChipItem("Qwen3-ASR", isOn: qwen) { state.listenASREngine = .qwen },
                     NodeChipItem("Apple Speech", isOn: !qwen) { state.listenASREngine = .apple }
                 ])
    }
}
